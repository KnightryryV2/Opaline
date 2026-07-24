import CoreMedia
import CoreVideo
import Foundation

/// Wraps every av01 sample of one fMP4 media segment into `CMSampleBuffer`s
/// ready for `AVSampleBufferDisplayLayer` enqueueing, decoding each sample
/// to a `CVPixelBuffer` via dav1d first (unlike `SampleBufferFactory`, which
/// hands VideoToolbox-decodable formats straight through as compressed
/// samples).
///
/// Timing scheme mirrors `SampleBufferFactory` exactly: cumulative
/// `decodeTicks` from `segmentStart`, presentation = decode + `ctsOffset`.
enum Av01SampleBufferFactory {
    // MARK: - Type methods

    // swiftlint:disable function_parameter_count
    /// - Parameters:
    ///   - segment: The full media-segment bytes (`moof`+`mdat`); a
    ///     sample's bytes are raw OBUs, fed to `decoder` as-is.
    ///   - samples: `FMP4SampleTable.parse` output; offsets are absolute
    ///     within `segment`.
    ///   - decoder: MUST only be driven from one serial queue (see
    ///     `Dav1dDecoder`); this call decodes every sample synchronously,
    ///     in order, on whatever queue it's called from.
    ///   - segmentStart: This segment's presentation start, in seconds.
    ///   - timescale: The track timescale `FMP4Sample.duration`/`ctsOffset`
    ///     are expressed in.
    static func make(
        segment: Data,
        samples: [FMP4Sample],
        decoder: Dav1dDecoder,
        segmentStart: Double,
        timescale: CMTimeScale
    ) -> [CMSampleBuffer] {
        // Same non-CMTimeConvertScale reasoning as SampleBufferFactory:
        // segmentStart and the sample durations already share timescale.
        let tickOffset = Int64((segmentStart * Double(timescale)).rounded())
        var buffers: [CMSampleBuffer] = []
        buffers.reserveCapacity(samples.count)
        var decodeTicks = tickOffset
        for sample in samples {
            if let buffer = makeSampleBuffer(
                segment: segment,
                sample: sample,
                decoder: decoder,
                decodeTicks: decodeTicks,
                timescale: timescale
            ) {
                buffers.append(buffer)
            }
            // Advance regardless of decode success so later samples' timing
            // stays aligned with the segment's real presentation clock.
            decodeTicks += Int64(sample.duration)
        }
        return buffers
    }

    private static func makeSampleBuffer(
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
        let obu = segment.subdata(in: sample.offset..<(sample.offset + sample.size))
        guard let pixelBuffer = decoder.decode(obu) else {
            AppLog.log("Av01SampleBufferFactory", "decode produced no picture, skipping sample")
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
