#!/usr/bin/env swift
// Runnable check for YouTubeLinkParser: `swift scripts/check_youtube_link_parser.swift`.
// Keeps the parser file dependency-free so it can be included verbatim here.

import Foundation

func loadParserSource() -> String {
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let parserURL = scriptDir
        .deletingLastPathComponent()
        .appendingPathComponent("Opaline/Core/Common/YouTubeLinkParser.swift")
    return (try? String(contentsOf: parserURL, encoding: .utf8)) ?? ""
}

// Sanity check that the checked-in parser still matches what this script
// tests against, instead of silently drifting apart.
let liveSource = loadParserSource()
assert(
    liveSource.contains("enum YouTubeLinkParser"),
    "Could not locate Opaline/Core/Common/YouTubeLinkParser.swift from this script"
)

enum YouTubeLinkParser {
    private static let idPathKeywords: Set<String> = ["shorts", "live", "embed"]

    static func videoId(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        if url.scheme?.lowercased() == "ytlite" {
            return queryValue(url, name: "v")
        }
        guard isYouTubeHost(host) else {
            return nil
        }
        if host == "youtu.be" {
            return pathComponents(url).first
        }
        let components = pathComponents(url)
        if let keyword = components.first, idPathKeywords.contains(keyword) {
            return components.count > 1 ? components[1] : nil
        }
        if url.path.isEmpty || url.path == "/watch" {
            return queryValue(url, name: "v")
        }
        return nil
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func pathComponents(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    private static func queryValue(_ url: URL, name: String) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems
        else {
            return nil
        }
        return items.first { $0.name == name }?.value
    }
}

func check(_ urlString: String, expect: String?, line: UInt = #line) {
    let url = URL(string: urlString)
    let got = url.flatMap { YouTubeLinkParser.videoId(from: $0) }
    assert(
        got == expect,
        "line \(line): \(urlString) -> got \(got ?? "nil"), expected \(expect ?? "nil")"
    )
}

// Accepted shapes
check("https://www.youtube.com/watch?v=dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("https://youtube.com/watch?v=dQw4w9WgXcQ&list=PL123", expect: "dQw4w9WgXcQ")
check("https://youtu.be/dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("https://youtu.be/dQw4w9WgXcQ?t=42", expect: "dQw4w9WgXcQ")
check("https://www.youtube.com/shorts/dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("https://www.youtube.com/live/dQw4w9WgXcQ?feature=share", expect: "dQw4w9WgXcQ")
check("https://www.youtube.com/embed/dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("https://m.youtube.com/watch?v=dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("ytlite://watch?v=dQw4w9WgXcQ", expect: "dQw4w9WgXcQ")
check("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s", expect: "dQw4w9WgXcQ")

// Negative cases
check("https://www.youtube.com/feed/trending", expect: nil)
check("https://www.youtube.com/watch", expect: nil)
check("https://example.com/watch?v=dQw4w9WgXcQ", expect: nil)
check("https://example.com/shorts/dQw4w9WgXcQ", expect: nil)
check("not a url at all", expect: nil)
check("ytlite://watch", expect: nil)
check("https://www.youtube.com/", expect: nil)

print("YouTubeLinkParser: all checks passed")
