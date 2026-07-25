import Foundation

// MARK: - Generated-HLS build

extension MWebSource {
    /// The DASH pair with `n` already solved into the URLs (pot injected later).
    struct SolvedStreams {
        let video: DashFormatInfo
        let audio: DashFormatInfo
        var videoURL: URL
        var audioURL: URL
    }

    /// Builds generated-HLS and hands it straight to AVPlayer — unlike
    /// `AndroidVRSource`, mweb has no sample-buffer/dav1d fallback, so av01
    /// must never reach here on a device without hardware AV1 decode (see
    /// `DirectPlaybackClient.allowsSoftwareAV1`).
    func buildGeneratedHLS(
        info: DirectPlaybackInfo,
        streams: SolvedStreams,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let videoURL = client.directURL(baseURL: streams.videoURL, poToken: poToken)
        AppLog.player(
            "mwebSource: build pot=\(Self.hasQuery(videoURL, "pot")) rqh=1 ready"
        )
        let input = HLSPlaybackBuilder.BuildInput(
            videoURL: videoURL,
            audioURL: client.directURL(baseURL: streams.audioURL, poToken: poToken),
            videoFormat: streams.video,
            audioFormat: streams.audio,
            headers: client.streamHeaders(visitorData: visitorData ?? info.visitorData)
        )
        HLSPlaybackBuilder.build(input: input) { result in
            guard let result else {
                completion(.failure(Self.noStreamError))
                return
            }
            completion(.success(
                PreparedPlayback(
                    item: result.playerItem,
                    resourceLoader: result.loader,
                    captions: info.captionTracks,
                    duration: info.duration
                )
            ))
        }
    }
}
