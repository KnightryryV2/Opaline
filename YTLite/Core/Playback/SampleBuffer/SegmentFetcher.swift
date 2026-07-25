import Foundation
import QuartzCore

/// Bounded byte-range downloads over the app's `HTTPTransport` abstraction.
/// Feeds the sample-buffer playback engine with individual fMP4 segments
/// resolved by `MediaSegmentIndex`. All networking goes through
/// `HTTPTransport` — this type never touches `URLSession` directly.
///
/// Bounds every attempt with a timeout and retries a bounded number of times
/// with a short backoff: the underlying `URLSession` (`.shared`, no custom
/// config) uses a 60s `timeoutIntervalForRequest` that *resets on any
/// received byte*, so a connection that trickles a few bytes every 50s can
/// hang for minutes with no failure ever reported — exactly the "twitches
/// forward once, then freezes again" pattern seen on device. A stalled
/// segment must not be terminal for the rest of playback.
final class SegmentFetcher {
    /// Bundles one fetch's fixed inputs so retry helpers stay under
    /// SwiftLint's function-parameter-count limit.
    private struct FetchContext {
        let url: URL
        let headers: [String: String]
        let range: ClosedRange<Int64>
        let cancellationToken: CancellationToken?
        let completion: (Data?) -> Void
    }

    /// Per-attempt timeout. Generous for a few-hundred-KB fMP4 segment on any
    /// network worth playing on, and short enough that a stall is retried
    /// long before the render synchronizer's free-running clock (see
    /// `SampleBufferEngine+Starvation.swift`) has drifted far from reality.
    private static let requestTimeout: TimeInterval = 15
    /// Retries after the first attempt — 3 tries total before the caller sees
    /// failure (`TrackProducer.failOnce`).
    private static let maxRetries = 2
    /// Backoff between retries. Short: a stalled attempt already cost up to
    /// `requestTimeout` seconds, no point compounding that with a long sleep.
    private static let retryDelay: TimeInterval = 1

    private let transport: HTTPTransport

    init(transport: HTTPTransport = ServiceContainer.mediaTransport) {
        self.transport = transport
    }

    // GETs `url` with `Range: bytes=<range.lowerBound>-<range.upperBound>`
    // (inclusive). Success is a 200 or 206 response; a transport failure or
    // other status code retries up to `maxRetries` times before completing
    // with `nil`. The completion runs on whichever queue the underlying
    // transport calls back on.
    // swiftlint:disable:next function_parameter_count
    func fetch(
        url: URL,
        headers: [String: String],
        range: ClosedRange<Int64>,
        cancellationToken: CancellationToken?,
        completion: @escaping (Data?) -> Void
    ) {
        performAttempt(
            1,
            FetchContext(
                url: url,
                headers: headers,
                range: range,
                cancellationToken: cancellationToken,
                completion: completion
            )
        )
    }

    private func performAttempt(_ attempt: Int, _ context: FetchContext) {
        var allHeaders = context.headers
        let range = context.range
        allHeaders[HTTPHeader.range] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        let request = HTTPRequest(
            method: .get,
            url: context.url,
            headers: allHeaders,
            timeout: Self.requestTimeout
        )
        let start = CACurrentMediaTime()
        // Strong `self` on purpose: an in-flight fetch MUST reach its
        // completion. Callers don't necessarily hold the fetcher — the SIDX
        // fetch in `AndroidVRSource+SampleBuffer` builds a local one whose
        // only references are these in-flight closures — so a `[weak self]`
        // here deallocates the fetcher the moment the call returns and the
        // completion is silently never called: no data, no failure, no log,
        // playback simply never starts. Cancellation is the caller's lever
        // (`cancellationToken`), not deallocation. No cycle: the transport
        // releases this closure once the request finishes.
        transport.send(
            request,
            cancellationToken: context.cancellationToken
        ) { result in
            let elapsedMs = (CACurrentMediaTime() - start) * 1_000
            self.handle(result: result, elapsedMs: elapsedMs, attempt: attempt, context: context)
        }
    }

    private func handle(
        result: Result<HTTPResponse, Error>,
        elapsedMs: Double,
        attempt: Int,
        context: FetchContext
    ) {
        switch result {
        case let .success(response):
            guard response.status == 200 || response.status == 206 else {
                let reason = "status \(response.status)"
                log(reason, elapsedMs: elapsedMs, attempt: attempt, url: context.url)
                retryOrGiveUp(attempt: attempt, context: context)
                return
            }
            AppLog.log(
                "SampleBuffer",
                "segment fetch done: \(context.url.lastPathComponent) "
                    + "\(response.data.count)B in \(String(format: "%.0f", elapsedMs))ms"
                    + (attempt > 1 ? " (attempt \(attempt))" : "")
            )
            context.completion(response.data)
        case let .failure(error):
            let reason = error.localizedDescription
            log(reason, elapsedMs: elapsedMs, attempt: attempt, url: context.url)
            retryOrGiveUp(attempt: attempt, context: context)
        }
    }

    private func log(_ reason: String, elapsedMs: Double, attempt: Int, url: URL) {
        AppLog.log(
            "SampleBuffer",
            "segment fetch failed: \(reason) for \(url.lastPathComponent) "
                + "(\(String(format: "%.0f", elapsedMs))ms, attempt \(attempt))"
        )
    }

    private func retryOrGiveUp(attempt: Int, context: FetchContext) {
        // A cancelled fetch never calls back — matches URLSessionTransport's
        // own cancellation contract (see `isCancelled` there).
        if context.cancellationToken?.isCancelled == true {
            return
        }
        let name = context.url.lastPathComponent
        guard attempt <= Self.maxRetries else {
            AppLog.log("SampleBuffer", "segment fetch giving up after \(attempt) attempts: \(name)")
            context.completion(nil)
            return
        }
        AppLog.log(
            "SampleBuffer",
            "segment fetch retrying (\(attempt + 1)/\(Self.maxRetries + 1)): \(name)"
        )
        let queue = DispatchQueue.global(qos: .userInitiated)
        // Strong `self` for the same reason as in `performAttempt`: dropping
        // the fetcher between attempts would strand the completion.
        queue.asyncAfter(deadline: .now() + Self.retryDelay) {
            self.performAttempt(attempt + 1, context)
        }
    }
}
