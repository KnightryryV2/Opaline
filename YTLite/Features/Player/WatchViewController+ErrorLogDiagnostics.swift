import AVKit

// MARK: - AVPlayerItem Error Log Diagnostics

extension WatchViewController {
    /// Dumps every AVPlayerItemErrorLogEvent on the item — the `uri` field
    /// names the exact URL AVFoundation refused, which the top-level FAILED
    /// log doesn't capture. Called eagerly on `.failed` status since an
    /// immediate resource-loader rejection (e.g. -1002 unsupported URL) may
    /// not always trigger a separate AVPlayerItemNewErrorLogEntry notification.
    func logErrorLogEvents(_ item: AVPlayerItem) {
        guard let events = item.errorLog()?.events,
              !events.isEmpty
        else {
            AppLog.player("player error log: empty")
            return
        }
        for (index, event) in events.enumerated() {
            AppLog.player(
                "player error log[\(index)]:"
                    + " domain=\(event.errorDomain),"
                    + " code=\(event.errorStatusCode),"
                    + " comment=\(event.errorComment ?? "nil"),"
                    + " uri=\(event.uri ?? "nil")"
            )
        }
    }
}
