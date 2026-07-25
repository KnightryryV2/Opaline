import CoreMedia
import CoreVideo
import Foundation

/// Turns av01 samples into `CMSampleBuffer`s for `AVSampleBufferDisplayLayer`,
/// decoding each sample to a `CVPixelBuffer` via dav1d (unlike
/// `SampleBufferFactory`, which hands VideoToolbox-decodable formats straight
/// through as compressed samples).
///
/// Split into two halves that run at different times, on purpose: the FIFO
/// must hold *compressed* OBU bytes, never decoded pixel buffers, 10s of
/// which would be a 900 MB+ memory bomb at 1080p (see `TrackProducer.
/// PendingSample`). So `planDecodeTicks` runs at fetch time (cheap, no
/// decode) to compute each sample's timing, and `makeSampleBuffer` — the
/// actual dav1d call — runs lazily in `TrackProducer.dequeue()`, a handful of
/// frames ahead of the renderer.
///
/// Timing scheme mirrors `SampleBufferFactory` exactly: cumulative
/// `decodeTicks` from `segmentStart`, presentation = decode + `ctsOffset`.
enum Av01SampleBufferFactory {
    // MARK: - Type methods

    /// Computes each sample's cumulative `decodeTicks` without decoding
    /// anything — the fetch-time half of this factory. Same arithmetic as
    /// `SampleBufferFactory.make`: ticks (not `CMTimeConvertScale`) because
    /// `segmentStart` and the sample durations already share `timescale`.
    ///
    /// - Returns: One entry per input sample, same order, pairing it with
    ///   the decode-time tick its `CMSampleBuffer` will need.
    static func planDecodeTicks(
        samples: [FMP4Sample],
        segmentStart: Double,
        timescale: CMTimeScale
    ) -> [(sample: FMP4Sample, decodeTicks: Int64)] {
        let tickOffset = Int64((segmentStart * Double(timescale)).rounded())
        var planned: [(sample: FMP4Sample, decodeTicks: Int64)] = []
        planned.reserveCapacity(samples.count)
        var decodeTicks = tickOffset
        for sample in samples {
            planned.append((sample, decodeTicks))
            decodeTicks += Int64(sample.duration)
        }
        return planned
    }

    // swiftlint:disable function_parameter_count
    /// Decodes one sample via dav1d and wraps the resulting picture into a
    /// `CMSampleBuffer`. Called from `TrackProducer.dequeue()`, on demand —
    /// never ahead of what the renderer is about to consume.
    ///
    /// - Parameters:
    ///   - segment: The full media-segment bytes (`moof`+`mdat`) this sample
    ///     came from; its bytes are raw OBUs, fed to `decoder` as-is.
    ///   - decoder: MUST only be driven from one serial queue (see
    ///     `Dav1dDecoder`) — `dequeue()` is feedQueue-only, which satisfies
    ///     that.
    ///   - decodeTicks: From `planDecodeTicks`.
    ///   - timescale: The track timescale `FMP4Sample.duration`/`ctsOffset`
    ///     are expressed in.
    static func makeSampleBuffer(
        segment: Data,
        sample: FMP4Sample,
        decoder: Dav1dDecoder,
        decodeTicks: Int64,
        timescale: CMTimeScale
    ) -> CMSampleBuffer? {
        guard
            sample.offset >= 0, sample.size >= 0,
            sample.offset + sample.size <= segment.count
        else {
            return nil
        }
        // `decoder.decode` logs the failure reason itself (rate-limited,
        // see `Dav1dDecoder`) — nothing more to report here.
        let obu = segment.subdata(in: sample.offset..<(sample.offset + sample.size))
        guard let pixelBuffer = decoder.decode(obu) else {
            return nil
        }
        guard let format = formatDescription(for: pixelBuffer) else {
            return nil
        }
        let timing = sampleTiming(sample: sample, decodeTicks: decodeTicks, timescale: timescale)
        return createSampleBuffer(pixelBuffer: pixelBuffer, format: format, timing: timing)
    }
    // swiftlint:enable function_parameter_count

    private static func sampleTiming(
        sample: FMP4Sample,
        decodeTicks: Int64,
        timescale: CMTimeScale
    ) -> CMSampleTimingInfo {
        let presentationTicks = decodeTicks + Int64(sample.ctsOffset)
        return CMSampleTimingInfo(
            duration: CMTime(value: Int64(sample.duration), timescale: timescale),
            presentationTimeStamp: CMTime(value: presentationTicks, timescale: timescale),
            decodeTimeStamp: CMTime(value: decodeTicks, timescale: timescale)
        )
    }

    private static func createSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        format: CMVideoFormatDescription,
        timing: CMSampleTimingInfo
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = timing
        // dav1d already decoded the picture, so the "ready" variant fits:
        // no makeDataReadyCallback/refcon needed (unlike
        // CMSampleBufferCreateForImageBuffer, for data that isn't ready yet).
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    /// Builds a format description straight from the decoded pixel buffer.
    /// Created per-sample rather than cached+reused across a segment: av01
    /// resolution is expected constant within a rendition, and
    /// `CMVideoFormatDescriptionCreateForImageBuffer` is cheap (no
    /// parameter-set parsing, unlike H.264) — the extra calls aren't worth
    /// the staleness bookkeeping `CMVideoFormatDescriptionMatchesImageBuffer`
    /// would need if dimensions ever did change mid-segment.
    private static func formatDescription(
        for pixelBuffer: CVPixelBuffer
    ) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }
}
