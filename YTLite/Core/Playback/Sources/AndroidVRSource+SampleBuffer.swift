import Foundation

// MARK: - AndroidVRSource + SampleBuffer engine (debug)

/// Debug-only path that plays an avc1 DASH stream through the software
/// `SampleBufferEngine` instead of the generated-HLS/AVPlayer path. The engine
/// still feeds compressed H.264 that `AVSampleBufferDisplayLayer` decodes via
/// VideoToolbox — no dav1d yet — so this exists to validate the demux / clock /
/// sync / seek / buffering pipeline end-to-end before AV1 decode lands.
extension AndroidVRSource {
    /// Carries one track's resolved URL + format + headers to the SIDX fetch.
    private struct TrackRequest {
        let url: URL
        let format: DashFormatInfo
        let headers: [String: String]
    }

    /// av01 always needs this engine — AVPlayer can't decode it without
    /// hardware, and a hardware-capable device never reaches here in the
    /// first place (it takes the cheaper, device-verified generated-HLS/
    /// AVPlayer route instead) — *unless* Debug Toggle A
    /// (`AV1Support.isForceSoftwareDecoder`) is on, in which case av01
    /// routes through dav1d even on hardware-AV1 devices, so the software
    /// decoder can be validated independently of hardware availability. See
    /// `AV1Support.isSoftwareDecodeRoute`. avc1 stays gated behind the
    /// hidden `forceSampleBufferEngine` debug flag, unrelated to AV1.
    static func shouldUseSampleBuffer(video: DashFormatInfo) -> Bool {
        if video.codecs.hasPrefix("av01") {
            return AV1Support.isSoftwareDecodeRoute
        }
        guard UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.Debug.forceSampleBufferEngine
        ) else {
            return false
        }
        return video.codecs.hasPrefix("avc1") && (video.height ?? 0) <= 1_080
    }

    private static func makeIndex(
        format: DashFormatInfo,
        data: Data?
    ) -> MediaSegmentIndex? {
        guard let data, let segments = HLSGenerator.parseSidx(data: data) else {
            return nil
        }
        // MediaSegmentIndex's timescale arg is cosmetic — SidxSegment
        // durations already arrive in seconds.
        return MediaSegmentIndex(
            segments: segments,
            timescale: 1,
            initRangeEnd: Int64(format.initRangeEnd),
            indexRangeEnd: Int64(format.indexRangeEnd)
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func finish(
        info: DirectPlaybackInfo,
        video: TrackRequest,
        audio: TrackRequest,
        videoIndex: MediaSegmentIndex?,
        audioIndex: MediaSegmentIndex?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let videoIndex, let audioIndex else {
            completion(.failure(AndroidVRSource.noStreamError))
            return
        }
        let videoTrack = SampleBufferTrack(
            url: video.url,
            headers: video.headers,
            index: videoIndex,
            isAV1: video.format.codecs.hasPrefix("av01")
        )
        let audioTrack = SampleBufferTrack(
            url: audio.url,
            headers: audio.headers,
            index: audioIndex,
            isAV1: false
        )
        let engine = SampleBufferEngine(
            video: videoTrack,
            audio: audioTrack,
            durationSeconds: info.duration ?? videoIndex.totalDuration
        )
        completion(.success(PreparedPlayback(
            engine: engine,
            captions: info.captionTracks,
            duration: info.duration
        )))
    }

    /// Fetches + parses both tracks' SIDX (reusing `HLSGenerator.parseSidx`),
    /// builds a `MediaSegmentIndex` each, and hands both tracks to a
    /// `SampleBufferEngine` wrapped in an engine-backed `PreparedPlayback`.
    func buildSampleBuffer(
        info: DirectPlaybackInfo,
        video: DashFormatInfo,
        audio: DashFormatInfo,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let headers = client.streamHeaders(visitorData: info.visitorData)
        let videoReq = TrackRequest(
            url: client.directURL(baseURL: video.url, poToken: nil),
            format: video,
            headers: headers
        )
        let audioReq = TrackRequest(
            url: client.directURL(baseURL: audio.url, poToken: nil),
            format: audio,
            headers: headers
        )
        let fetcher = SegmentFetcher()
        let group = DispatchGroup()
        var videoIndex: MediaSegmentIndex?
        var audioIndex: MediaSegmentIndex?
        group.enter()
        fetchIndex(videoReq, fetcher: fetcher) { videoIndex = $0; group.leave() }
        group.enter()
        fetchIndex(audioReq, fetcher: fetcher) { audioIndex = $0; group.leave() }
        group.notify(queue: .global(qos: .userInitiated)) {
            Self.finish(
                info: info,
                video: videoReq,
                audio: audioReq,
                videoIndex: videoIndex,
                audioIndex: audioIndex,
                completion: completion
            )
        }
    }

    private func fetchIndex(
        _ request: TrackRequest,
        fetcher: SegmentFetcher,
        completion: @escaping (MediaSegmentIndex?) -> Void
    ) {
        let format = request.format
        let range = Int64(format.indexRangeStart)...Int64(format.indexRangeEnd)
        fetcher.fetch(
            url: request.url,
            headers: request.headers,
            range: range,
            cancellationToken: nil
        ) { data in
            completion(Self.makeIndex(format: format, data: data))
        }
    }
}
