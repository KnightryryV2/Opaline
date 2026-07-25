import CoreMedia
import CoreVideo
import Foundation

/// A decoded-but-dropped picture's dimensions/bit depth, bundled into one
/// struct (rather than two associated values) so `Dav1dDecoder.DecodeFailure
/// .unsupportedLayout` stays under SwiftLint's 1-value-per-case cap. File
/// scope, not nested in `DecodeFailure`, to stay under the 1-level nesting
/// cap (`DecodeFailure` is already nested one level inside `Dav1dDecoder`).
struct Dav1dFrameInfo {
    let dimensions: CMVideoDimensions
    let bitDepth: Int32
}

/// Thin Swift wrapper over the `Dav1dShim` C API — the only place in Swift
/// that talks to dav1d.
///
/// Not concurrency-safe: dav1d's decoder context assumes calls are
/// serialized, so every `decode(_:)` call for a given instance MUST happen
/// on the same serial queue (the sample-buffer engine's feed queue).
final class Dav1dDecoder {
    /// Why `decode(_:)` produced no picture, mirroring `dav1d_shim_status_t`
    /// minus the always-successful/always-caller-bug cases (`.ok` folds into
    /// the `CVPixelBuffer?` return value; `.invalidArgs` can't happen past
    /// the `ctx`/`obu.isEmpty` guard in `decode(_:)`).
    enum DecodeFailure {
        /// `dav1d_send_data()` errored; `code` is dav1d's negative errno.
        case sendError(Int32)
        /// Sample consumed, no picture ready yet — expected during warm-up.
        case noPictureYet
        /// `dav1d_get_picture()` errored; `code` is dav1d's negative errno.
        case getPictureError(Int32)
        /// Decoded, but chroma layout/bit depth isn't 8/10-bit 4:2:0.
        case unsupportedLayout(Dav1dFrameInfo)
        /// Decoded, but `CVPixelBufferCreate` failed (likely memory
        /// pressure at large frame sizes).
        case allocFailed(CMVideoDimensions)

        var reason: String {
            switch self {
            case .sendError(let code):
                return "send-data error \(code)"
            case .noPictureYet:
                return "no picture yet (warm-up)"
            case .getPictureError(let code):
                return "get-picture error \(code)"
            case .unsupportedLayout(let info):
                let size = "\(info.dimensions.width)x\(info.dimensions.height)"
                return "unsupported layout \(size) bpc=\(info.bitDepth)"
            case .allocFailed(let dimensions):
                return "pixel buffer alloc failed \(dimensions.width)x\(dimensions.height)"
            }
        }

        /// Bridges the C out-param into this enum. `nil` for `.ok` (caller
        /// already has the picture) and `.invalidArgs` (a caller bug that
        /// `decode(_:)`'s own guard prevents from reaching the shim).
        init?(_ result: dav1d_shim_decode_result_t) {
            switch result.status {
            case DAV1D_SHIM_STATUS_OK, DAV1D_SHIM_STATUS_INVALID_ARGS:
                return nil
            case DAV1D_SHIM_STATUS_SEND_ERROR:
                self = .sendError(result.errorCode)
            case DAV1D_SHIM_STATUS_NO_PICTURE_YET:
                self = .noPictureYet
            case DAV1D_SHIM_STATUS_GET_PICTURE_ERROR:
                self = .getPictureError(result.errorCode)
            case DAV1D_SHIM_STATUS_UNSUPPORTED_LAYOUT:
                let dimensions = CMVideoDimensions(width: result.width, height: result.height)
                let info = Dav1dFrameInfo(dimensions: dimensions, bitDepth: result.bitDepth)
                self = .unsupportedLayout(info)
            case DAV1D_SHIM_STATUS_ALLOC_FAILED:
                self = .allocFailed(CMVideoDimensions(width: result.width, height: result.height))
            default:
                return nil
            }
        }
    }

    /// CICP (AV1/H.273) codepoint -> readable name, used only for the
    /// once-per-instance color log in `logColorInfoOnce`. Not exhaustive —
    /// just the values `Dav1dShim.c`'s color mapping actually branches on;
    /// anything else prints as `other(N)`.
    private static let primariesNames: [UInt8: String] = [
        1: "BT.709", 2: "unspecified", 9: "BT.2020"
    ]
    private static let transferNames: [UInt8: String] = [
        1: "BT.709", 2: "unspecified", 13: "sRGB", 14: "BT.2020-10bit", 15: "BT.2020-12bit",
        16: "PQ", 18: "HLG"
    ]
    private static let matrixNames: [UInt8: String] = [
        1: "BT.709", 2: "unspecified", 5: "BT.470BG", 6: "BT.601",
        9: "BT.2020-NCL", 10: "BT.2020-CL"
    ]

    private var ctx: UnsafeMutableRawPointer?
    /// Reasons already logged once — see `decode(_:)`. feedQueue-confined,
    /// same as every other member here.
    private var loggedReasons: Set<String> = []
    /// Whether the resolved color description (see `logColorInfoOnce`) has
    /// already been logged for this decoder instance. feedQueue-confined.
    private var loggedColorInfo = false

    /// - Returns: `nil` when dav1d is unavailable — the simulator build
    ///   (no arm64 slice) or a `dav1d_open` failure. Callers must fall back
    ///   to the compressed-sample path in that case.
    init?() {
        guard let context = dav1d_shim_create() else {
            return nil
        }
        ctx = context
    }

    private static func cicpName(_ value: UInt8, table: [UInt8: String]) -> String {
        table[value] ?? "other(\(value))"
    }

    /// Decodes one av01 sample's raw OBU bytes, logging the failure reason
    /// (via `AppLog`) the first time each distinct reason occurs for this
    /// decoder instance — never per frame, since a persistent failure would
    /// otherwise log at the stream's frame rate forever.
    ///
    /// - Returns: The decoded picture as a `CVPixelBuffer`, or `nil` on
    ///   failure (see `DecodeFailure` for why, folded into the log line).
    func decode(_ obu: Data) -> CVPixelBuffer? {
        guard let ctx, !obu.isEmpty else {
            return nil
        }
        var result = dav1d_shim_decode_result_t(
            status: DAV1D_SHIM_STATUS_INVALID_ARGS,
            errorCode: 0,
            width: 0,
            height: 0,
            bitDepth: 0,
            colorPrimaries: 0,
            transferCharacteristics: 0,
            matrixCoefficients: 0,
            colorRangeFull: 0
        )
        let pixelBuffer = obu.withUnsafeBytes { rawBuffer -> CVPixelBuffer? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return dav1d_shim_decode(ctx, base, rawBuffer.count, &result)
        }
        if let pixelBuffer {
            logColorInfoOnce(result)
            return pixelBuffer
        }
        logFailureOnce(result)
        return nil
    }

    private func logFailureOnce(_ result: dav1d_shim_decode_result_t) {
        guard let failure = DecodeFailure(result) else {
            return
        }
        let reason = failure.reason
        guard !loggedReasons.contains(reason) else {
            return
        }
        loggedReasons.insert(reason)
        AppLog.log("Dav1dDecoder", "decode produced no picture: \(reason)")
    }

    /// Logs the color description resolved from the first decoded picture's
    /// AV1 sequence header — once per decoder instance (one dav1d decoder per
    /// playback), not per frame, so a device run confirms what the pixel
    /// buffers were actually tagged with without spamming the log at frame
    /// rate.
    private func logColorInfoOnce(_ result: dav1d_shim_decode_result_t) {
        guard !loggedColorInfo else {
            return
        }
        loggedColorInfo = true
        let range = result.colorRangeFull != 0 ? "full" : "video"
        let primaries = Self.cicpName(result.colorPrimaries, table: Self.primariesNames)
        let transfer = Self.cicpName(result.transferCharacteristics, table: Self.transferNames)
        let matrix = Self.cicpName(result.matrixCoefficients, table: Self.matrixNames)
        AppLog.log(
            "Dav1dDecoder",
            "color: primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) range=\(range)"
        )
    }

    /// Drops dav1d's internal picture queue and reference frames after a
    /// seek/discontinuity — without this, the next `decode(_:)` call can
    /// return a picture decoded from the pre-seek stream position. Same
    /// serial-queue constraint as `decode(_:)`: call only from the sample-
    /// buffer engine's feed queue.
    func flush() {
        dav1d_shim_flush(ctx)
    }

    deinit {
        dav1d_shim_destroy(ctx)
    }
}
