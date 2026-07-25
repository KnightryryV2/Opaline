import AVFoundation

// MARK: - SampleBufferEngine + Teardown

/// `PlayerEngine.teardown()` for the sample-buffer path — split out to keep
/// `SampleBufferEngine.swift` within the file-length limit.
extension SampleBufferEngine {
    /// Stops the renderers asking for more data, parks the synchronizer, and
    /// hands off to `feedQueue` to cancel both producers' in-flight fetches
    /// and drop them (and their FIFOs — which is what actually frees the
    /// retained segment `Data` and the dav1d decode context). Safe to call
    /// from main even while a `feedQueue` drain/fetch-completion is in
    /// flight: that work either finishes against the still-alive producer or
    /// finds `videoProducer`/`audioProducer` already nil and no-ops (every
    /// feedQueue entry point — `drainVideo`/`drainAudio`/`topUp`/segment
    /// completions — already guards on those being non-nil).
    ///
    /// Idempotent: called from `VideoPlayerView.detach()`, which only ever
    /// runs on a genuinely-discarded engine (never the one saved in
    /// `savedEngineForBackground` for the video-to-video background-resume
    /// path — that path calls `rebind(engine:)` instead and never touches
    /// `detach()`), but guarded here too in case of a future second caller.
    func teardown() {
        guard !didTeardown else {
            return
        }
        didTeardown = true
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: .invalid)
        feedQueue.async { [weak self] in
            guard let self else {
                return
            }
            videoProducer?.cancellationToken.cancel()
            audioProducer?.cancellationToken.cancel()
            videoProducer = nil
            audioProducer = nil
        }
    }
}
