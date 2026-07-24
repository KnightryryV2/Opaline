import VideoToolbox

/// Runtime probe: does VideoToolbox on this device decode VP9 and/or AV1?
/// YouTube serves resolutions above 1080p only as VP9 or AV1. `AV1Support`
/// already gates av01 behind an iOS-version + hardware check; this probe
/// additionally measures VP9, which VT never exposes a public constant for
/// before iOS 14 — M-series silicon shares the same VP9 decode block VT
/// reports on macOS, so a pass here could unlock >1080p at zero binary
/// cost. See `docs/plans/av1-software-decode.md`, Phase 0 spike 1.
enum CodecCapabilityProbe {
    private struct Codec {
        let name: String
        let fourCC: CMVideoCodecType
    }

    private static let codecs: [Codec] = [
        Codec(name: "vp09", fourCC: 0x7670_3039),
        Codec(name: "av01", fourCC: 0x6176_3031)
    ]

    /// Logs hardware-decode support and a real session-creation attempt for
    /// each codec. Guaranteed to run its body exactly once per process
    /// (static-let token) and never on the calling thread.
    private static let probeOnce: Void = {
        for codec in codecs {
            probe(codec)
        }
        probeDav1d()
    }()

    /// Logs the linked dav1d version (nil on the simulator, where dav1d has no
    /// slice). Also anchors the static library into the link.
    private static func probeDav1d() {
        guard let version = dav1d_shim_version() else {
            AppLog.log("VT probe", "dav1d: not linked")
            return
        }
        AppLog.log("VT probe", "dav1d \(String(cString: version))")
    }

    static func logOnce() {
        DispatchQueue.global(qos: .utility).async {
            _ = probeOnce
        }
    }

    private static func probe(_ codec: Codec) {
        let hwSupported = VTIsHardwareDecodeSupported(codec.fourCC)
        let createStatus = attemptSessionCreate(codecType: codec.fourCC)
        AppLog.log(
            "VT probe",
            "\(codec.name): hw=\(hwSupported) create=\(createStatus)"
        )
    }

    private static func attemptSessionCreate(codecType: CMVideoCodecType) -> OSStatus {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: codecType,
            width: 3_840,
            height: 2_160,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let description = formatDescription else {
            return formatStatus
        }
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        return sessionStatus
    }
}
