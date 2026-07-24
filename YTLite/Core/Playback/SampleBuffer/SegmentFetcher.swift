import Foundation

/// Bounded byte-range downloads over the app's `HTTPTransport` abstraction.
/// Feeds the sample-buffer playback engine with individual fMP4 segments
/// resolved by `MediaSegmentIndex`. All networking goes through
/// `HTTPTransport` — this type never touches `URLSession` directly.
final class SegmentFetcher {
    private let transport: HTTPTransport

    init(transport: HTTPTransport = ServiceContainer.mediaTransport) {
        self.transport = transport
    }

    // GETs `url` with `Range: bytes=<range.lowerBound>-<range.upperBound>`
    // (inclusive). Success is a 200 or 206 response; any transport failure
    // or other status code completes with `nil`. The completion runs on
    // whichever queue the underlying transport calls back on.
    // swiftlint:disable:next function_parameter_count
    func fetch(
        url: URL,
        headers: [String: String],
        range: ClosedRange<Int64>,
        cancellationToken: CancellationToken?,
        completion: @escaping (Data?) -> Void
    ) {
        var allHeaders = headers
        allHeaders[HTTPHeader.range] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        let request = HTTPRequest(method: .get, url: url, headers: allHeaders)
        transport.send(request, cancellationToken: cancellationToken) { result in
            self.handle(result: result, url: url, completion: completion)
        }
    }

    private func handle(
        result: Result<HTTPResponse, Error>,
        url: URL,
        completion: (Data?) -> Void
    ) {
        switch result {
        case let .success(response):
            guard response.status == 200 || response.status == 206 else {
                AppLog.log(
                    "SampleBuffer",
                    "segment fetch: status \(response.status) for \(url.lastPathComponent)"
                )
                completion(nil)
                return
            }
            completion(response.data)
        case let .failure(error):
            AppLog.log(
                "SampleBuffer",
                "segment fetch failed: \(error.localizedDescription)"
            )
            completion(nil)
        }
    }
}
