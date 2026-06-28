import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests view-session identity/ownership for the linked-view beta: collision-safe
/// naming, option stamping, robust parsing, and the classification predicates that
/// keep cmux from reusing/garbage-collecting a session it does not own.
@Suite struct RemoteTmuxViewSessionTests {
    private typealias VS = RemoteTmuxViewSession
    private typealias Row = RemoteTmuxViewSession.SessionRow
    private func v(_ owner: String = "o1") -> VS { VS(ownerId: owner) }

    // Build a list row string in the current format: view : owner : version : name
    private func rowString(view: String, owner: String, version: String, name: String) -> String {
        [view, owner, version, name].joined(separator: ":")
    }

    @Test func sessionNameIsPrefixedSanitizedAndHashed() {
        let s = VS(ownerId: "ab.cd ef:gh")
        #expect(s.sessionName.hasPrefix("cmux-view-ab-cd-ef-gh-"))  // sanitized fragment
        #expect(!s.sessionName.contains("."))
        #expect(!s.sessionName.contains(":"))
        #expect(!s.sessionName.contains(" "))
    }

    @Test func distinctOwnersNeverCollideEvenWhenSanitizedFragmentMatches() {
        // "a.b" and "a:b" sanitize to the same fragment but must yield distinct
        // session names (collision-resistant hash suffix).
        #expect(VS(ownerId: "a.b").sessionName != VS(ownerId: "a:b").sessionName)
        #expect(VS(ownerId: "a.b").sessionName == VS(ownerId: "a.b").sessionName) // stable
    }

    @Test func createArgvsUseExplicitSizeAndStampOwnership() {
        let s = v("o1")
        let argvs = s.createArgvs(cols: 120, rows: 40)
        #expect(argvs[0] == ["new-session", "-d", "-s", s.sessionName, "-x", "120", "-y", "40"])
        #expect(argvs.contains(["set-option", "-t", s.sessionName, "@cmux_view", "1"]))
        #expect(argvs.contains(["set-option", "-t", s.sessionName, "@cmux_view_owner", "o1"]))
        #expect(argvs.contains(["set-option", "-t", s.sessionName, "@cmux_view_version", "1"]))
        // The shared client can't size each linked window via refresh-client, so the
        // view session must run window-size manual for per-window resize-window.
        #expect(argvs.contains(["set-option", "-t", s.sessionName, "window-size", "manual"]))
    }

    @Test func parsesListRowsWithFreeTextNameLast() {
        let out = [
            rowString(view: "1", owner: "o1", version: "1", name: "cmux-view-o1-ab"),
            rowString(view: "", owner: "", version: "", name: "work"),
            rowString(view: "1", owner: "o2", version: "1", name: "cmux-view-o2-cd"),
        ].joined(separator: "\n")
        let rows = VS.parseRows(out)
        #expect(rows.count == 3)
        #expect(rows[0] == Row(name: "cmux-view-o1-ab", isView: true, owner: "o1", version: 1))
        #expect(rows[1] == Row(name: "work", isView: false, owner: "", version: nil))
        #expect(rows[2].owner == "o2")
    }

    @Test func parsingKeepsSessionNameContainingDelimiter() {
        // A `:` in the (free-text, last) name is preserved via remainder-rejoin.
        let out = rowString(view: "", owner: "", version: "", name: "we:ird:name")
        #expect(VS.parseRows(out) == [Row(name: "we:ird:name", isView: false, owner: "", version: nil)])
    }

    @Test func usesPrintableDelimiterNotControlByte() {
        // Guards the cross-host fix: the format must not embed a non-printable byte
        // (tmux's utf8_sanitize would rewrite it to `_` on non-UTF-8 clients).
        #expect(!VS.listFormat.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(VS.listFormat.contains(":"))
    }

    @Test func isAnyViewRequiresBothTagAndPrefix() {
        // tagged + prefixed → a view
        #expect(VS.isAnyView(Row(name: "cmux-view-x", isView: true, owner: "x", version: 1)))
        // tagged but NOT prefixed (a real session that copied the option) → NOT a view
        #expect(!VS.isAnyView(Row(name: "prod", isView: true, owner: "x", version: 1)))
        // prefixed but not tagged → NOT a view
        #expect(!VS.isAnyView(Row(name: "cmux-view-x", isView: false, owner: "x", version: 1)))
    }

    @Test func isOwnViewOnlyForExactOwnerNameVersionAndPrefix() {
        let s = v("o1")
        let n = s.sessionName
        #expect(s.isOwnView(Row(name: n, isView: true, owner: "o1", version: 1)))
        #expect(!s.isOwnView(Row(name: n, isView: true, owner: "o2", version: 1)))   // wrong owner
        #expect(!s.isOwnView(Row(name: n, isView: false, owner: "o1", version: 1)))  // not tagged
        #expect(!s.isOwnView(Row(name: n, isView: true, owner: "o1", version: 99)))  // wrong version
        #expect(!s.isOwnView(Row(name: "other", isView: true, owner: "o1", version: 1))) // wrong name
    }

    @Test func staleViewIsOnlyOurOwnPrefixedNonCurrent() {
        let s = v("o1")
        // our owner, prefixed, old version → stale
        #expect(s.isOwnStaleView(Row(name: "cmux-view-o1-old", isView: true, owner: "o1", version: 0)))
        // our current view → NOT stale
        #expect(!s.isOwnStaleView(Row(name: s.sessionName, isView: true, owner: "o1", version: 1)))
        // a NON-prefixed real session with our owner+option copied → NEVER collectible
        #expect(!s.isOwnStaleView(Row(name: "prod", isView: true, owner: "o1", version: 0)))
        // another owner's view → never ours to collect
        #expect(!s.isOwnStaleView(Row(name: "cmux-view-o2", isView: true, owner: "o2", version: 0)))
    }

    @Test func foreignViewDetection() {
        #expect(VS.isForeignView(Row(name: "cmux-view-o2", isView: true, owner: "o2", version: 1), ownerId: "o1"))
        #expect(!VS.isForeignView(Row(name: "cmux-view-o1", isView: true, owner: "o1", version: 1), ownerId: "o1"))
        // a non-prefixed session is never a foreign view even if tagged
        #expect(!VS.isForeignView(Row(name: "prod", isView: true, owner: "o2", version: 1), ownerId: "o1"))
        // a normal session is never foreign-view
        #expect(!VS.isForeignView(Row(name: "work", isView: false, owner: "", version: nil), ownerId: "o1"))
    }
}
