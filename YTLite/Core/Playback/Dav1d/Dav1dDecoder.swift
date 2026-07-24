import CoreVideo
import Foundation

/// Thin Swift wrapper over the `Dav1dShim` C API — the only place in Swift
/// that talks to dav1d.
///
/// Not concurrency-safe: dav1d's decoder context assumes calls are
/// serialized, so every `decode(_:)` call for a given instance MUST happen
/// on the same serial queue (the sample-buffer engine's feed queue).
final class Dav1dDecoder {
    private var ctx: UnsafeMutableRawPointer?

    /// - Returns: `nil` when dav1d is unavailable — the simulator build
    ///   (no arm64 slice) or a `dav1d_open` failure. Callers must fall back
    ///   to the compressed-sample path in that case.
    init?() {
        guard let context = dav1d_shim_create() else {
            return nil
        }
        ctx = context
    }

    /// Decodes one av01 sample's raw OBU bytes.
    ///
    /// - Returns: The decoded picture as a `CVPixelBuffer`, or `nil` if this
    ///   call produced no picture (e.g. the decoder is still buffering),
    ///   the stream errored, or the chroma layout isn't 4:2:0.
    func decode(_ obu: Data) -> CVPixelBuffer? {
        guard let ctx, !obu.isEmpty else {
            return nil
        }
        return obu.withUnsafeBytes { rawBuffer -> CVPixelBuffer? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return dav1d_shim_decode(ctx, base, rawBuffer.count)
        }
    }

    deinit {
        dav1d_shim_destroy(ctx)
    }
}
