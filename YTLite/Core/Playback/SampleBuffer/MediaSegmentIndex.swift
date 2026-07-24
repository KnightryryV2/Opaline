import Foundation

/// Immutable byte/time index derived from an already-parsed `sidx` box.
///
/// `SidxSegment.offset`/`.size` are relative to the first byte of media
/// data, which begins at `indexRangeEnd + 1` (one past the end of the
/// `sidx` box itself). This type resolves those relative values into
/// absolute byte ranges in the source file and precomputes cumulative
/// start times so lookups are O(1) — bar `segmentIndex(forTime:)`, a short
/// linear scan (segment counts run in the hundreds).
///
/// Out-of-range `at index:` lookups are clamped into `0..<segmentCount`
/// rather than trapping.
struct MediaSegmentIndex {
    // MARK: - Instance properties

    /// Byte range of the init segment (`ftyp`/`moov`): `0...initRangeEnd`.
    let initRange: ClosedRange<Int64>
    let segmentCount: Int
    /// Sum of all segment durations, in seconds.
    let totalDuration: Double

    private let byteRanges: [ClosedRange<Int64>]
    private let startTimes: [Double]
    private let durations: [Double]

    // MARK: - Initializers

    /// - Parameters:
    ///   - segments: Parsed sidx references (offset/size relative to the
    ///     start of media data; duration already resolved to seconds).
    ///   - timescale: The sidx timescale, kept for traceability — segment
    ///     durations already arrive in seconds so it isn't otherwise
    ///     needed here.
    ///   - initRangeEnd: Last byte (inclusive) of the init segment.
    ///   - indexRangeEnd: Last byte (inclusive) of the `sidx` box itself;
    ///     the first media segment starts at `indexRangeEnd + 1`.
    init(
        segments: [SidxSegment],
        timescale: UInt32,
        initRangeEnd: Int64,
        indexRangeEnd: Int64
    ) {
        self.initRange = 0...max(initRangeEnd, 0)
        let dataStart = indexRangeEnd + 1
        var ranges: [ClosedRange<Int64>] = []
        var starts: [Double] = []
        var durs: [Double] = []
        var elapsed: Double = 0
        for segment in segments {
            let low = dataStart + segment.offset
            let high = low + max(segment.size - 1, 0)
            ranges.append(low...high)
            starts.append(elapsed)
            durs.append(segment.duration)
            elapsed += segment.duration
        }
        self.byteRanges = ranges
        self.startTimes = starts
        self.durations = durs
        self.segmentCount = segments.count
        self.totalDuration = elapsed
    }

    // MARK: - Instance methods

    /// Absolute byte range for segment `index`, clamped to a valid index.
    func byteRange(at index: Int) -> ClosedRange<Int64> {
        guard segmentCount > 0 else {
            return 0...0
        }
        return byteRanges[clampedIndex(index)]
    }

    /// Start time in seconds for segment `index`, clamped to a valid index.
    func startTime(at index: Int) -> Double {
        guard segmentCount > 0 else {
            return 0
        }
        return startTimes[clampedIndex(index)]
    }

    /// Duration in seconds for segment `index`, clamped to a valid index.
    func duration(at index: Int) -> Double {
        guard segmentCount > 0 else {
            return 0
        }
        return durations[clampedIndex(index)]
    }

    /// Index of the segment containing `seconds`, clamped to
    /// `0..<segmentCount` (or `0` when there are no segments).
    func segmentIndex(forTime seconds: Double) -> Int {
        guard segmentCount > 0 else {
            return 0
        }
        let found = startTimes.indices.last { startTimes[$0] <= seconds }
        return found ?? 0
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), segmentCount - 1)
    }
}
