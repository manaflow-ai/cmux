import Foundation

/// The spike's scripts (JS/), shared with the Chromium bench (chromium/bench.py reads the same files).
public enum SpikeJS {
    public static let isolatedWorld = load("isolated-world")
    public static let isolatedProbe = load("isolated-probe")
    public static let pageSpy = load("page-spy")
    public static let benchPage = load("bench-page")

    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "JS"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("missing spike script \(name).js") }
        return text
    }
}
