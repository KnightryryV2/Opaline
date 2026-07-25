import AVFoundation

// MARK: - SampleBufferEngine + Seek

extension SampleBufferEngine {
    /// Seeks by flushing both renderers and re-enqueuing from the keyframe at
    /// the start of the segment containing `time`.
    ///
    /// avc1 DASH segments begin on a keyframe (SAP=1), so seek granularity is
    /// the segment boundary — the clock lands on that boundary (typically a
    /// few seconds' resolution), not the exact requested time, and the
    /// tolerances are ignored for the same reason. Everything runs on
    /// `feedQueue` so the flush + producer reset are serialized against the
    /// drain/prefetch loop; only `completion` hops to main.
    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completion: ((Bool) -> Void)?
    ) {
        let requested = time.seconds.isFinite ? time.seconds : 0
        let seconds = max(0, min(requested, duration.seconds))
        feedQueue.async { [weak self] in
            self?.performSeek(toSeconds: seconds, completion: completion)
        }
    }

    private func performSeek(
        toSeconds seconds: Double,
        completion: ((Bool) -> Void)?
    ) {
        guard let videoProducer, let audioProducer else {
            finishSeek(completion, success: false)
            return
        }
        let videoIndex = videoTrack.index.segmentIndex(forTime: seconds)
        let audioIndex = audioTrack.index.segmentIndex(forTime: seconds)
        displayLayer.flush()
        audioRenderer.flush()
        // reset() bumps each producer's generation, invalidating any fetch
        // still in flight from the old position (see TrackProducer.reset).
        videoProducer.reset(toSegmentIndex: videoIndex)
        audioProducer.reset(toSegmentIndex: audioIndex)
        // Video segment start is the master timeline, matching the frames the
        // display layer will render from the new keyframe. Park the clock
        // there at rate 0 and re-preroll: the feeder restarts it via
        // startClockIfPrerolled once the new position has buffered a lead, so
        // a seek on a slow device doesn't fast-forward or drop audio either.
        let anchor = videoTrack.index.startTime(at: videoIndex)
        anchorSeconds = anchor
        clockRunning = false
        videoEnqueuedAny = false
        // A starvation park may already be pending from just before the seek;
        // it would no-op against the now-parked clock anyway (see
        // `parkClockIfStillStarving`'s `clockRunning` guard), but cancelling
        // lets a fresh one be scheduled immediately if the new position
        // starves too, instead of waiting out the old debounce window.
        pendingParkWorkItem?.cancel()
        pendingParkWorkItem = nil
        synchronizer.setRate(
            0,
            time: CMTime(seconds: anchor, preferredTimescale: 600)
        )
        resumeFeeding()
        startClockIfPrerolled()
        finishSeek(completion, success: true)
    }

    private func finishSeek(_ completion: ((Bool) -> Void)?, success: Bool) {
        guard let completion else {
            return
        }
        DispatchQueue.main.async {
            completion(success)
        }
    }
}
