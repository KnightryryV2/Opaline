import CoreMedia
import Foundation

/// Wraps every sample of one fMP4 media segment (`moof`+`mdat`) into
/// `CMSampleBuffer`s ready for `AVSampleBufferDisplayLayer`/
/// `AVSampleBufferAudioRenderer` enqueueing.
///
/// Each sample gets its own `CMBlockBuffer` holding a private copy of its
/// bytes (`CMBlockBufferCreateWithMemoryBlock` + `CMBlockBufferReplaceDataBytes`)
/// — zero-copy against the segment `Data` isn't worth the lifetime
/// bookkeeping at this stage.
enum SampleBufferFactory {
    // MARK: - Type methods

    // swiftlint:disable function_parameter_count
    /// - Parameters:
    ///   - segment: The full media-segment bytes (`moof`+`mdat`).
    ///   - samples: `FMP4SampleTable.parse` output; offsets are absolute
    ///     within `segment`.
    ///   - format: From `FMP4FormatDescription.video`/`.audio`.
    ///   - segmentStart: This segment's presentation start, in seconds.
    ///   - timescale: The track timescale `FMP4Sample.duration`/`ctsOffset`
    ///     are expressed in (see `FMP4FormatDescription.trackTimescale`).
    static func make(
        segment: Data,
        samples: [FMP4Sample],
        format: CMFormatDescription,
        segmentStart: Double,
        timescale: CMTimeScale
    ) -> [CMSampleBuffer] {
        // Ticks, not a `CMTime` conversion: `segmentStart` and the sample
        // durations already share `timescale`, so multiplying directly
        // avoids an extra rounding step through `CMTimeConvertScale`.
        let tickOffset = Int64((segmentStart * Double(timescale)).rounded())
        var buffers: [CMSampleBuffer] = []
        buffers.reserveCapacity(samples.count)
        var decodeTicks = tickOffset
        for sample in samples {
            let buffer = makeSampleBuffer(
                segment: segment,
                sample: sample,
                format: format,
                decodeTicks: decodeTicks,
                timescale: timescale
            )
            if let buffer {
                buffers.append(buffer)
            }
            decodeTicks += Int64(sample.duration)
        }
        return buffers
    }

    private static func makeSampleBuffer(
        segment: Data,
        sample: FMP4Sample,
        format: CMFormatDescription,
        decodeTicks: Int64,
        timescale: CMTimeScale
    ) -> CMSampleBuffer? {
        guard
            sample.offset >= 0, sample.size >= 0,
            sample.offset + sample.size <= segment.count,
            let blockBuffer = makeBlockBuffer(segment: segment, sample: sample)
        else {
            return nil
        }
        let timing = sampleTiming(sample: sample, decodeTicks: decodeTicks, timescale: timescale)
        guard let sampleBuffer = createSampleBuffer(
            blockBuffer: blockBuffer,
            format: format,
            timing: timing,
            size: sample.size
        ) else {
            return nil
        }
        if !sample.isSync {
            markNotSync(sampleBuffer)
        }
        return sampleBuffer
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

    private static func makeBlockBuffer(segment: Data, sample: FMP4Sample) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.size,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            return nil
        }
        return copySampleBytes(segment: segment, sample: sample, into: buffer) ? buffer : nil
    }

    private static func copySampleBytes(
        segment: Data,
        sample: FMP4Sample,
        into buffer: CMBlockBuffer
    ) -> Bool {
        let range = sample.offset..<(sample.offset + sample.size)
        let bytes = segment.subdata(in: range)
        let status = bytes.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: sample.size
            )
        }
        return status == kCMBlockBufferNoErr
    }

    private static func createSampleBuffer(
        blockBuffer: CMBlockBuffer,
        format: CMFormatDescription,
        timing: CMSampleTimingInfo,
        size: Int
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = timing
        var sampleSize = size
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    /// Marks a non-keyframe video sample so the display layer doesn't treat
    /// it as decodable on its own.
    private static func markNotSync(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ) as? [NSMutableDictionary],
            let attachments = attachmentsArray.first
        else {
            return
        }
        attachments[kCMSampleAttachmentKey_NotSync as String] = kCFBooleanTrue
        attachments[kCMSampleAttachmentKey_DependsOnOthers as String] = kCFBooleanTrue
    }
}
