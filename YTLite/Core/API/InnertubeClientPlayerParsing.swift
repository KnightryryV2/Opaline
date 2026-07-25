// swiftlint:disable file_length
import Foundation

extension InnertubeClient {
    /// - Parameter allowsSoftwareAV1: Whether this response's client has a
    ///   software-AV1 route (only android_vr does — see
    ///   `DirectPlaybackClient.allowsSoftwareAV1`). Deliberately has no
    ///   default: admitting av01 for a client that can only hand it to
    ///   AVPlayer is exactly the black-screen bug this parameter exists to
    ///   prevent, so every caller must state which side it is on.
    static func parseDirectPlaybackInfo(
        _ json: [String: Any],
        allowsSoftwareAV1: Bool
    ) -> DirectPlaybackInfo? {
        guard let sd = json["streamingData"]
            as? [String: Any]
        else {
            return nil
        }
        let formats = sd["formats"]
            as? [[String: Any]] ?? []
        let adaptive = sd["adaptiveFormats"]
            as? [[String: Any]] ?? []
        logAV01Formats(adaptive)
        let selected = selectFormats(
            formats: formats,
            adaptive: adaptive,
            allowsSoftwareAV1: allowsSoftwareAV1
        )
        return assemblePlayback(
            json: json,
            streamingData: sd,
            selected: selected,
            adaptive: adaptive,
            allowsSoftwareAV1: allowsSoftwareAV1
        )
    }

    static func fmtDirectURL(
        _ format: [String: Any]
    ) -> URL? {
        guard let val = format["url"] as? String,
              !val.isEmpty
        else {
            return nil
        }
        return URL(string: val)
    }

    static func fmtURLString(
        _ format: [String: Any]
    ) -> String? {
        let url = format["url"] as? String
        return url?.isEmpty == false ? url : nil
    }

    static func fmtMimeType(
        _ format: [String: Any]
    ) -> String {
        format["mimeType"] as? String ?? ""
    }

    static func fmtHeight(
        _ format: [String: Any]
    ) -> Int { format["height"] as? Int ?? 0 }

    static func fmtBitrate(
        _ format: [String: Any]
    ) -> Int { format["bitrate"] as? Int ?? 0 }

    static func fmtItag(
        _ format: [String: Any]
    ) -> Int? { format["itag"] as? Int }

    /// At equal height, av01 normally loses to avc1's higher bitrate — which
    /// is exactly backwards while Debug Toggle B ("Force AV1 for 360-1080p")
    /// is on, since the whole point of that toggle is to exercise dav1d at
    /// resolutions hardware already reaches. `AV1Support.isForceAV1LowRes`
    /// is `false` whenever the toggle is off, so this tiebreak is inert
    /// (byte-for-byte the old bitrate-only comparison) for every other case,
    /// including `filterVideoCandidates`'s reuse of this function where the
    /// candidate pool is avc1-only.
    static func heightBitrateLess(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        let leftHeight = fmtHeight(lhs)
        let rightHeight = fmtHeight(rhs)
        if leftHeight == rightHeight {
            if AV1Support.isForceAV1LowRes {
                let leftIsAV1 = fmtMimeType(lhs).contains("av01")
                let rightIsAV1 = fmtMimeType(rhs).contains("av01")
                if leftIsAV1 != rightIsAV1 {
                    return rightIsAV1
                }
            }
            return fmtBitrate(lhs)
                < fmtBitrate(rhs)
        }
        return leftHeight < rightHeight
    }
}

// MARK: - Format Selection & DASH Builders

private extension InnertubeClient {
    static func selectFormats(
        formats: [[String: Any]],
        adaptive: [[String: Any]],
        allowsSoftwareAV1: Bool
    ) -> SelectedFmts {
        let progressive = formats
            .filter {
                fmtDirectURL($0) != nil
                    && fmtMimeType($0)
                        .contains("video/mp4")
            }
            .max {
                fmtBitrate($0) < fmtBitrate($1)
            }
        let video = selectBestVideo(
            from: adaptive,
            maxHeight: VideoQualityStore.maxHeight,
            allowsSoftwareAV1: allowsSoftwareAV1
        )
        return SelectedFmts(
            progressive: progressive,
            video: video,
            audio: selectBestAudio(from: adaptive)
        )
    }

    /// Best audio/mp4 stream, preferring the ORIGINAL track (id suffix
    /// ".4" / `acont=original`). Dubbed videos ship several itag-140
    /// variants whose bitrates differ by a few bits — a plain max-bitrate
    /// pick lands on a dub. `audioIsDefault` is NOT the original: it marks
    /// the track matching the request's `hl` (a Russian video fetched with
    /// `hl=en` flags the English AI dub as default), so it's only the
    /// fallback when no ".4" track exists.
    static func selectBestAudio(
        from adaptive: [[String: Any]]
    ) -> [String: Any]? {
        let pool = adaptive.filter {
            fmtDirectURL($0) != nil
                && fmtMimeType($0)
                    .contains("audio/mp4")
        }
        let originals = pool.filter {
            (($0["audioTrack"] as? [String: Any])?["id"]
                as? String)?.hasSuffix(".4") == true
        }
        let defaults = pool.filter {
            ((($0["audioTrack"] as? [String: Any])?["audioIsDefault"])
                as? Bool) == true
        }
        let preferred = originals.isEmpty
            ? (defaults.isEmpty ? pool : defaults)
            : originals
        return preferred.max {
            fmtBitrate($0) < fmtBitrate($1)
        }
    }

    /// avc1 everywhere; av01 additionally wherever `AV1Support` admits it —
    /// unconditionally on hardware-AV1 devices, only above 1080p on the
    /// software-only (dav1d) path, unless Debug Toggle B lifts that floor.
    /// With both Debug toggles off this is byte-for-byte the pre-AV1-work
    /// ladder: avc1-only, capped at 1080p, on anything without hardware AV1.
    /// `allowsSoftwareAV1` further restricts the software branch to clients
    /// whose build path actually has a software-decode route (android_vr) —
    /// see `AV1Support.isAV01Admitted(atHeight:allowsSoftwareAV1:)`.
    static func fmtIsPlayableVideo(
        _ fmt: [String: Any],
        allowsSoftwareAV1: Bool
    ) -> Bool {
        let mime = fmtMimeType(fmt)
        guard mime.contains("video/mp4") else {
            return false
        }
        guard mime.contains("av01") else {
            return mime.contains("avc1")
        }
        return AV1Support.isAV01Admitted(
            atHeight: fmtHeight(fmt),
            allowsSoftwareAV1: allowsSoftwareAV1
        )
    }

    static func selectBestVideo(
        from adaptive: [[String: Any]],
        maxHeight: Int?,
        allowsSoftwareAV1: Bool
    ) -> [String: Any]? {
        adaptive
            .filter { fmt in
                fmtDirectURL(fmt) != nil
                    && fmtIsPlayableVideo(fmt, allowsSoftwareAV1: allowsSoftwareAV1)
                    && fmtHeight(fmt) > 0
                    && maxHeight.map {
                        fmtHeight(fmt) <= $0
                    } ?? true
            }
            .max { heightBitrateLess($0, $1) }
    }

    static func buildSabrInfo(
        _ fmt: [String: Any]
    ) -> SabrFormatInfo? {
        guard let tag = fmtItag(fmt)
        else {
            return nil
        }
        let audioTrack = fmt["audioTrack"]
            as? [String: Any]
        let xtags = fmt["xtags"] as? String
        let isDrc = (fmt["isDrc"] as? Bool)
            ?? (xtags?.contains("drc=1") == true)
        return SabrFormatInfo(
            itag: tag,
            lastModified:
                (fmt["lastModified"] as? String)
                ?? (fmt["lmt"] as? String),
            xtags: xtags,
            audioTrackId: audioTrack?["id"] as? String,
            isDrc: isDrc,
            mimeType: fmt["mimeType"] as? String,
            bitrate: fmt["bitrate"] as? Int,
            width: fmt["width"] as? Int,
            height: fmt["height"] as? Int
        )
    }

    static func buildDashInfo(
        _ fmt: [String: Any]
    ) -> DashFormatInfo? {
        let initRange = fmt["initRange"]
            as? [String: Any]
        let indexRange = fmt["indexRange"]
            as? [String: Any]
        guard let url = fmtDirectURL(fmt),
              let tag = fmtItag(fmt),
              let initEnd = intVal(initRange?["end"]),
              let indexStart = intVal(indexRange?["start"]),
              let indexEnd = intVal(indexRange?["end"]),
              let contentLength = (fmt["contentLength"]
                  as? String).flatMap(Int64.init)
        else {
            return nil
        }
        return makeDashInfo(
            url: url,
            itag: tag,
            fmt: fmt,
            clen: contentLength,
            iEnd: initEnd,
            xSt: indexStart,
            xEnd: indexEnd
        )
    }

    // swiftlint:disable function_parameter_count
    static func makeDashInfo(
        url: URL,
        itag: Int,
        fmt: [String: Any],
        clen: Int64,
        iEnd: Int,
        xSt: Int,
        xEnd: Int
    ) -> DashFormatInfo {
        let track = fmt["audioTrack"]
            as? [String: Any]
        return DashFormatInfo(
            url: url,
            itag: itag,
            mimeType: fmtMimeType(fmt),
            codecs: extractCodecs(
                from: fmtMimeType(fmt)
            ),
            bitrate: fmtBitrate(fmt),
            contentLength: clen,
            initRangeEnd: iEnd,
            indexRangeStart: xSt,
            indexRangeEnd: xEnd,
            width: fmt["width"] as? Int,
            height: fmt["height"] as? Int,
            fps: fmt["fps"] as? Int,
            qualityLabel: fmt["qualityLabel"] as? String,
            sigChallenge: fmt[sigChallengeKey] as? String,
            sigParam: fmt[sigParamKey] as? String,
            audioTrackId: track?["id"] as? String,
            audioTrackName: track?["displayName"]
                as? String,
            audioIsDefault:
                (track?["audioIsDefault"] as? Bool)
                    ?? false
        )
    }
    // swiftlint:enable function_parameter_count

    static func intVal(_ value: Any?) -> Int? {
        if let str = value as? String {
            return Int(str)
        }
        return value as? Int
    }

    static func extractCodecs(
        from mime: String
    ) -> String {
        guard let start = mime.range(
            of: "codecs=\""
        ),
              let end = mime[start.upperBound...]
                  .range(of: "\"")
        else {
            return ""
        }
        return String(
            mime[
                start.upperBound..<end.lowerBound
            ]
        )
    }

    /// Best audio/mp4 format per distinct audio track (dub). Dubbed videos
    /// ship each language at several bitrates — keep the top one per track
    /// id. Videos without track metadata produce an empty list (no picker).
    static func buildAllDashAudio(
        from adaptive: [[String: Any]]
    ) -> [DashFormatInfo] {
        var bestPerTrack: [String: DashFormatInfo] = [:]
        adaptive
            .filter {
                fmtDirectURL($0) != nil
                    && fmtMimeType($0).contains("audio/mp4")
            }
            .compactMap(buildDashInfo)
            .forEach { format in
                guard let trackId = format.audioTrackId else {
                    return
                }
                if let seen = bestPerTrack[trackId],
                   seen.bitrate >= format.bitrate {
                    return
                }
                bestPerTrack[trackId] = format
            }
        // Only one distinct track = nothing to switch between.
        guard bestPerTrack.count > 1 else {
            return []
        }
        return bestPerTrack.values.sorted { lhs, rhs in
            if lhs.audioIsOriginal != rhs.audioIsOriginal {
                return lhs.audioIsOriginal
            }
            return (lhs.audioTrackName ?? "")
                < (rhs.audioTrackName ?? "")
        }
    }

    static func buildAllDashVideo(
        from adaptive: [[String: Any]],
        allowsSoftwareAV1: Bool
    ) -> [DashFormatInfo] {
        adaptive
            .filter {
                fmtDirectURL($0) != nil
                    && fmtIsPlayableVideo($0, allowsSoftwareAV1: allowsSoftwareAV1)
                    && fmtHeight($0) > 0
            }
            .compactMap(buildDashInfo)
            .sorted { lhs, rhs in
                let lh = lhs.height ?? 0
                let rh = rhs.height ?? 0
                if lh == rh {
                    // Same tiebreak as `heightBitrateLess`: while Toggle B is
                    // on, put av01 first so `AndroidVRSource.qualities(from:)`
                    // — which dedupes by label and keeps the first entry per
                    // height — keeps av01 rather than the higher-bitrate
                    // avc1 twin. Inert (bitrate-only) when the toggle is off.
                    if AV1Support.isForceAV1LowRes {
                        let lhsIsAV1 = lhs.codecs.contains("av01")
                        let rhsIsAV1 = rhs.codecs.contains("av01")
                        if lhsIsAV1 != rhsIsAV1 {
                            return lhsIsAV1
                        }
                    }
                    return lhs.bitrate > rhs.bitrate
                }
                return lh > rh
            }
    }

    /// One-time diagnostic: android_vr's Phase 0 spike only ever confirmed
    /// av01 at 1440p/2160p plus a 1080p rung (itag 699) — it's unknown
    /// whether this client offers av01 at 720p/480p/360p at all, which caps
    /// what Toggle B can ever reach. Only logs while the software path is
    /// actually in use (Toggle A), so normal users never pay for it.
    static func logAV01Formats(_ adaptive: [[String: Any]]) {
        guard AV1Support.isForceSoftwareDecoder else {
            return
        }
        let av01 = adaptive.filter { fmtMimeType($0).contains("av01") }
        guard !av01.isEmpty else {
            AppLog.innertube("AV1 probe: response has no av01 formats")
            return
        }
        let lines = av01.map { fmt -> String in
            let itag = fmtItag(fmt) ?? -1
            let height = fmtHeight(fmt)
            let fps = fmt["fps"] as? Int ?? 0
            let codecs = extractCodecs(from: fmtMimeType(fmt))
            return "itag=\(itag) height=\(height) fps=\(fps) codec=\(codecs)"
        }
        AppLog.innertube("AV1 probe: av01 formats = [\(lines.joined(separator: "; "))]")
    }
}

// MARK: - Playback Assembly

private extension InnertubeClient {
    // swiftlint:disable:next function_parameter_count
    static func assemblePlayback(
        json: [String: Any],
        streamingData sd: [String: Any],
        selected: SelectedFmts,
        adaptive: [[String: Any]],
        allowsSoftwareAV1: Bool
    ) -> DirectPlaybackInfo? {
        let dashVideo = selected.video.flatMap(buildDashInfo)
        let dashAudio = selected.audio.flatMap(buildDashInfo)
        logDashSelection(video: dashVideo, audio: dashAudio)
        let urls = extractURLs(
            sd: sd, selected: selected
        )
        guard urls.hasAny
        else {
            return nil
        }
        let config = extractPlayerConfig(json: json)
        let allDash = buildAllDashVideo(
            from: adaptive,
            allowsSoftwareAV1: allowsSoftwareAV1
        )
        let allAudio = buildAllDashAudio(
            from: adaptive
        )
        let duration = extractDuration(selected: selected)
        return buildPlaybackPart1(
            urls: urls,
            cfg: config,
            sel: selected,
            dV: dashVideo,
            dA: dashAudio,
            allDash: allDash,
            allAudio: allAudio,
            dur: duration,
            json: json
        )
    }

    // swiftlint:disable function_parameter_count
    // swiftlint:disable function_body_length
    static func buildPlaybackPart1(
        urls: PlaybackURLs,
        cfg: PlayerCfg,
        sel: SelectedFmts,
        dV: DashFormatInfo?,
        dA: DashFormatInfo?,
        allDash: [DashFormatInfo],
        allAudio: [DashFormatInfo],
        dur: Double?,
        json: [String: Any]
    ) -> DirectPlaybackInfo {
        let vLabel = (sel.video?[
            "qualityLabel"
        ] as? String) ?? (sel.progressive?[
            "qualityLabel"
        ] as? String)
        let visitorData = (json["responseContext"]
            as? [String: Any])?["visitorData"]
            as? String
        let trackingURLs = extractWatchtimeURLs(json)
        let captions = extractCaptionTracks(json)
        return DirectPlaybackInfo(
            hlsManifestURL: urls.hls,
            dashManifestURL: urls.dash,
            progressiveURL: urls.progressive,
            videoURL: urls.video,
            audioURL: urls.audio,
            serverAbrStreamingURL: urls.sabr,
            videoPlaybackUstreamerConfig:
                cfg.playbackConfig,
            onesieUstreamerConfig:
                cfg.onesieConfig,
            sabrVideoFormat: sel.video
                .flatMap(buildSabrInfo),
            sabrAudioFormat: sel.audio
                .flatMap(buildSabrInfo),
            videoItag: sel.video
                .flatMap(fmtItag)
                ?? sel.progressive
                    .flatMap(fmtItag),
            audioItag: sel.audio
                .flatMap(fmtItag),
            qualityLabel: vLabel,
            visitorData: visitorData,
            hasPlaybackUstreamerConfig:
                cfg.hasPlaybackConfig,
            dashVideoFormat: dV,
            dashAudioFormat: dA,
            allDashVideoFormats: allDash,
            allDashAudioFormats: allAudio,
            duration: dur,
            playbackTrackingURLs: trackingURLs,
            captionTracks: captions
        )
    }
    // swiftlint:enable function_body_length
    // swiftlint:enable function_parameter_count

    static func extractURLs(
        sd: [String: Any],
        selected sel: SelectedFmts
    ) -> PlaybackURLs {
        PlaybackURLs(
            hls: (sd["hlsManifestUrl"]
                as? String).flatMap(
                    URL.init(string:)
                ),
            dash: (sd["dashManifestUrl"]
                as? String).flatMap(
                    URL.init(string:)
                ),
            progressive: sel.progressive
                .flatMap(fmtDirectURL),
            video: sel.video
                .flatMap(fmtDirectURL),
            audio: sel.audio
                .flatMap(fmtDirectURL),
            sabr: (sd["serverAbrStreamingUrl"]
                as? String).flatMap(
                    URL.init(string:)
                )
        )
    }

    static func extractPlayerConfig(
        json: [String: Any]
    ) -> PlayerCfg {
        let pc = json["playerConfig"]
            as? [String: Any]
        let mc = pc?["mediaCommonConfig"]
            as? [String: Any]
        let rc = mc?[
            "mediaUstreamerRequestConfig"
        ] as? [String: Any]
        let vp = rc?[
            "videoPlaybackUstreamerConfig"
        ] as? String
        let oc = rc?[
            "onesieUstreamerConfig"
        ] as? String
        return PlayerCfg(
            playbackConfig: vp,
            onesieConfig: oc,
            hasPlaybackConfig:
                vp?.isEmpty == false
        )
    }

    static func extractDuration(
        selected sel: SelectedFmts
    ) -> Double? {
        let key = "approxDurationMs"
        let ms = (sel.video?[key] as? String)
            ?? (sel.audio?[key] as? String)
        return ms.flatMap(Double.init)
            .map { $0 / 1_000.0 }
    }

    static func logDashSelection(
        video: DashFormatInfo?,
        audio: DashFormatInfo?
    ) {
        if let dv = video {
            logDashFormat("video", dv)
        }
        if let da = audio {
            logDashFormat("audio", da)
        }
    }

    static func logDashFormat(
        _ label: String,
        _ df: DashFormatInfo
    ) {
        AppLog.innertube(
            "DASH \(label): itag=\(df.itag)"
                + " init=0-\(df.initRangeEnd)"
                + " index=\(df.indexRangeStart)"
                + "-\(df.indexRangeEnd)"
                + " clen=\(df.contentLength)"
                + " codecs=\(df.codecs)"
        )
    }
}

// MARK: - Supporting Types

extension InnertubeClient {
    struct SelectedFmts {
        let progressive: [String: Any]?
        let video: [String: Any]?
        let audio: [String: Any]?
    }

    struct PlayerCfg {
        let playbackConfig: String?
        let onesieConfig: String?
        let hasPlaybackConfig: Bool
    }

    struct PlaybackURLs {
        let hls: URL?
        let dash: URL?
        let progressive: URL?
        let video: URL?
        let audio: URL?
        let sabr: URL?
        var hasAny: Bool {
            hls != nil || dash != nil
                || progressive != nil
                || (video != nil && audio != nil)
                || sabr != nil
        }
    }

    static func extractWatchtimeURLs(
        _ json: [String: Any]
    ) -> WatchtimeURLs? {
        let pt = json["playbackTracking"]
            as? [String: Any]
        if pt == nil {
            let ps = (json["playabilityStatus"]
                as? [String: Any])?["status"]
                ?? "nil"
            AppLog.innertube(
                "watchtimeURLs: no playbackTracking"
                    + " playabilityStatus=\(ps)"
            )
        }
        guard let pbURL = (pt?["videostatsPlaybackUrl"]
            as? [String: Any])?["baseUrl"] as? String,
              let wtURL = (pt?["videostatsWatchtimeUrl"]
            as? [String: Any])?["baseUrl"] as? String
        else {
            return nil
        }
        let dur = extractDurationFromJSON(json)
        return WatchtimeURLs(
            playbackURL: pbURL,
            watchtimeURL: wtURL,
            duration: dur
        )
    }

    static func extractDurationFromJSON(
        _ json: [String: Any]
    ) -> Double? {
        let sd = json["streamingData"]
            as? [String: Any]
        let fmts = (sd?["formats"]
            as? [[String: Any]] ?? [])
            + (sd?["adaptiveFormats"]
                as? [[String: Any]] ?? [])
        return fmts
            .compactMap {
                ($0["approxDurationMs"] as? String)
                    .flatMap(Double.init)
            }
            .first
            .map { $0 / 1_000.0 }
    }
}
