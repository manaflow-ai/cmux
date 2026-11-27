// Stand-ins for the app's CrashGuard and localization, so the Swift parser builds alone
// (parity dumper only; see run.sh).
import Foundation

enum CrashGuard {
    static func fault(_ message: @autoclosure () -> String, fileID: StaticString = #fileID, line: UInt = #line) {}
}

enum MessagesLabLocalization {
    static func string(_ key: String, _ english: String) -> String { english }
}

extension Collection {
    subscript(checked index: Index, fileID: StaticString = #fileID, line: UInt = #line) -> Element? {
        guard index >= startIndex, index < endIndex else { return nil }
        return self[index]
    }

    func checkedIndex(_ index: Index, fileID: StaticString = #fileID, line: UInt = #line) -> Index? {
        guard index >= startIndex, index < endIndex else { return nil }
        return index
    }

    func slice(_ lower: Index, _ upper: Index, fileID: StaticString = #fileID, line: UInt = #line) -> SubSequence {
        let lo = Swift.min(Swift.max(lower, startIndex), endIndex)
        let hi = Swift.min(Swift.max(upper, lo), endIndex)
        return self[lo..<hi]
    }

    func slice(from lower: Index, fileID: StaticString = #fileID, line: UInt = #line) -> SubSequence {
        slice(lower, endIndex, fileID: fileID, line: line)
    }
}

extension MutableCollection {
    mutating func update(at index: Index, fileID: StaticString = #fileID, line: UInt = #line, _ body: (inout Element) -> Void) {
        guard let i = checkedIndex(index, fileID: fileID, line: line) else { return }
        body(&self[i])
    }
}

/// The Rust crate's DefaultPolicy rule after the scheme check (URL(string:) is the app's).
func parityAllows(_ s: String) -> Bool {
    if s.unicodeScalars.count > 8192 { return false }
    guard let colon = s.firstIndex(of: ":") else { return false }
    let scheme = s[s.startIndex..<colon].lowercased()
    let rest = s[s.index(after: colon)...]
    switch scheme {
    case "http", "https":
        guard rest.hasPrefix("//") else { return false }
        let after = rest.dropFirst(2)
        var host = after.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        host = host.components(separatedBy: "@").last ?? ""
        host = host.components(separatedBy: ":").first ?? ""
        return !host.isEmpty
    case "mailto": return !rest.isEmpty
    default: return false
    }
}
