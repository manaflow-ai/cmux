import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Viewer themes and terminal-authored OSC state have separate ownership.
@Suite
struct CloudRemoteColorOwnershipTests {
    @Test
    func nativeHandshakeRequestsAuthoredColorState() throws {
        let commands = CloudTuiManualIOCommand()
        let wire = try #require(commands.line(commands.setClientInfo(name: "native", kind: "terminal")))
        let request = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let capabilities = try #require(request["capabilities"] as? [String])
        #expect(capabilities.contains("terminal-color-overrides-v1"))
    }

    @Test(arguments: ["vt-state", "resized", "output", "colors-changed"])
    func sharedDefaultsDoNotRecolorTheViewer(event: String) throws {
        let before = try colors(event: event, foreground: "#d0d0d0", background: "#202020")
        let after = try colors(event: event, foreground: "#202020", background: "#ffffff")

        #expect(before.isEmpty)
        #expect(after.isEmpty)
        #expect(after.oscDelta(from: before).isEmpty)
        // A fresh renderer or rebind must also retain its own light/dark theme.
        #expect(after.oscBytes.isEmpty)
    }

    @Test
    func applicationOverridesSurviveOtherViewersAndResetToLocalDefaults() throws {
        let authored = ["fg": "#d0d0d0", "bg": "#202020", "cursor": "#112233"]
        let before = try colors(
            event: "vt-state", foreground: "#d0d0d0", background: "#202020",
            overrides: authored, palette: ["4": "#445566"]
        )
        let after = try colors(
            event: "colors-changed", foreground: "#d0d0d0", background: "#202020",
            overrides: authored, palette: ["4": "#445566"]
        )
        #expect(after == before)
        #expect(after.foreground == "#d0d0d0")
        #expect(after.background == "#202020")
        #expect(after.cursor == "#112233")
        #expect(after.palette == [4: "#445566"])
        #expect(after.oscDelta(from: before).isEmpty)

        let reset = try colors(event: "colors-changed", foreground: "#202020", background: "#ffffff")
        #expect(String(decoding: reset.oscDelta(from: after), as: UTF8.self) ==
            "\u{1B}]110\u{1B}\\\u{1B}]111\u{1B}\\\u{1B}]112\u{1B}\\\u{1B}]104;4\u{1B}\\")
        #expect(reset.oscBytes.isEmpty)
    }

    @Test
    func repeatedClientUpdatesNeverAccumulateViewerColorOverrides() throws {
        let events = ["vt-state", "resized", "output", "colors-changed"]
        var previous = CloudTuiRemoteColors()
        var liveColorBytes = 0
        var restoredColorBytes = 0
        for index in 0..<256 {
            let next = try colors(
                event: events[index % events.count],
                foreground: index.isMultiple(of: 2) ? "#d0d0d0" : "#202020",
                background: index.isMultiple(of: 2) ? "#202020" : "#ffffff"
            )
            liveColorBytes += next.oscDelta(from: previous).count
            restoredColorBytes += next.oscBytes.count
            previous = next
        }
        #expect(liveColorBytes == 0)
        #expect(restoredColorBytes == 0)
        #expect(previous.isEmpty)
    }

    private func colors(
        event: String,
        foreground: String,
        background: String,
        overrides: [String: String] = [:],
        palette: [String: String] = [:]
    ) throws -> CloudTuiRemoteColors {
        let sidecar: [String: Any] = [
            "fg": foreground, "bg": background, "cursor": overrides["cursor"] ?? "#abcdef",
            "overrides": overrides, "palette": palette
        ]
        var payload: [String: Any] = [
            "event": event, "surface": 155, "cols": 40, "rows": 8,
            "data": Data("shell".utf8).base64EncodedString()
        ]
        if event == "colors-changed" {
            payload.merge(sidecar) { _, value in value }
        } else {
            payload["colors"] = sidecar
        }
        let frame = try #require(CloudTuiManualIOFrameDecoder().decode(
            JSONSerialization.data(withJSONObject: payload)
        ))
        switch frame {
        case let .snapshot(_, _, _, _, colors), let .resized(_, _, _, _, colors), let .output(_, _, colors):
            return try #require(colors)
        case let .colorsChanged(_, colors):
            return colors
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }
}
