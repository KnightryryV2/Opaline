import AVFoundation

// MARK: - SampleBufferEngine + Starvation

/// Starvation → `state` bookkeeping for `SampleBufferEngine`, split out of
/// `SampleBufferEngine+Feed.swift` to keep that file within the file-length
/// limit. `setVideoStarving`/`setAudioStarving` are called from
/// `drainVideo()`/`drainAudio()` there.
extension SampleBufferEngine {
    /// How long a track must stay starving before `updateClockForStarvation()`
    /// actually parks the clock — absorbs a momentary one-frame FIFO gap
    /// that clears before the debounce fires, so it never touches the
    /// synchronizer. Short enough a real stall still freezes the picture
    /// almost immediately.
    static let starvationDebounceSeconds: Double = 0.3

    func setVideoStarving(_ starving: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyVideoStarving(starving)
        }
    }

    func setAudioStarving(_ starving: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyAudioStarving(starving)
        }
    }

    /// Parks or resumes the synchronizer clock based on `videoStarvingFeed`/
    /// `audioStarvingFeed`. `AVSampleBufferRenderSynchronizer` slaves its
    /// timebase to the audio renderer but *free-runs* on wall-clock time
    /// while that renderer has no data (the plan's Phase 2 "hard-won
    /// lessons") — so a stalled fetch doesn't just freeze the picture, it
    /// leaves `currentTime` climbing on nothing, which corrupts watchtime
    /// pings and the saved resume position. Parking at the synchronizer's own
    /// current time (not a segment boundary) freezes it exactly where
    /// playback actually got to; resuming goes through the same
    /// `startClockIfPrerolled` anchor-and-preroll path a fresh play()/seek()
    /// uses, so recovery can't fast-forward video or drop audio as "late" —
    /// no parallel clock-state machine. Never touches `desiredRate`, so
    /// `state` reads `.waiting` (not `.paused`) while parked.
    ///
    /// `videoStarvingFeed`/`audioStarvingFeed` flip on every drain call (many
    /// times a second) whenever a track's FIFO happens to be empty for that
    /// one call — a single frame landing un-starves a track for one drain
    /// without the buffered lead actually recovering. Two guards keep that
    /// from flapping the synchronizer's rate: parking only commits after
    /// `starvationDebounceSeconds` of continuous starvation
    /// (`parkClockIfStillStarving`), and resuming
    /// (`startClockIfPrerolled`) requires `minResumeLeadSeconds` of buffered
    /// lead on both tracks, not just one enqueued frame. Call only on
    /// `feedQueue`.
    func updateClockForStarvation() {
        guard videoStarvingFeed || audioStarvingFeed else {
            pendingParkWorkItem?.cancel()
            pendingParkWorkItem = nil
            startClockIfPrerolled()
            return
        }
        guard clockRunning, pendingParkWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.parkClockIfStillStarving()
        }
        pendingParkWorkItem = workItem
        feedQueue.asyncAfter(
            deadline: .now() + Self.starvationDebounceSeconds,
            execute: workItem
        )
    }

    /// Whether `producer` has buffered at least `minResumeLeadSeconds` past
    /// `anchorSeconds` — generalises the old "one frame enqueued" preroll
    /// check `startClockIfPrerolled` used to use, so a single frame can't
    /// flip the clock back on right before the FIFO re-starves. `nil`/at-end
    /// producers never block, so a track that will never buffer further
    /// can't wedge the clock. Called from `startClockIfPrerolled`
    /// (`SampleBufferEngine.swift`); internal since `private` doesn't cross
    /// files.
    func hasSufficientLead(_ producer: TrackProducer?) -> Bool {
        guard let producer, !producer.isAtEnd else {
            return true
        }
        return producer.frontierSeconds - anchorSeconds >= SampleBufferEngine.minResumeLeadSeconds
    }

    /// Fires after `starvationDebounceSeconds` of continuous starvation —
    /// re-checks (the FIFO may have recovered while the debounce was
    /// pending) before actually parking, so this is the single edge-triggered
    /// "SB clock parked" log line per real stall.
    private func parkClockIfStillStarving() {
        pendingParkWorkItem = nil
        guard clockRunning, videoStarvingFeed || audioStarvingFeed else {
            return
        }
        clockRunning = false
        anchorSeconds = synchronizer.currentTime().seconds
        // Plain `rate = 0`, not `setRate(0, time: .invalid)`: the two-argument
        // form is specified for *retiming* the timebase, and feeding it an
        // invalid time is undefined rather than "keep the current time". Here
        // the position must stay exactly where it is — `anchorSeconds` above
        // already captured it for the resume.
        synchronizer.rate = 0
        AppLog.player("SB clock parked at \(String(format: "%.1f", anchorSeconds))s (starving)")
    }

    /// Logs only the starving/recovered transition, not every drain call —
    /// `drainVideo()`/`drainAudio()` run on every `requestMediaDataWhenReady`
    /// callback (many times a second in steady state), so logging the level
    /// instead of the edge would flood the log like per-frame logging would.
    func logStarvingEdge(kind: TrackProducer.Kind, wasStarving: Bool, isStarving: Bool) {
        guard wasStarving != isStarving else {
            return
        }
        let recovered = "SB \(kind) recovered from starving"
        AppLog.player(isStarving ? "SB \(kind) starving, FIFO empty" : recovered)
    }

    private func applyVideoStarving(_ starving: Bool) {
        guard videoStarving != starving else {
            return
        }
        videoStarving = starving
        updateState()
    }

    private func applyAudioStarving(_ starving: Bool) {
        guard audioStarving != starving else {
            return
        }
        audioStarving = starving
        updateState()
    }
}
