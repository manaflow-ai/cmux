import CmuxFoundation
import Sentry
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies that ``SentryEventScrubber`` routes every sensitive Sentry field
/// through the scrubber while leaving grouping-relevant fields intact.
@Suite struct SentryEventScrubberTests {
    /// A scrubber bound to a fixed home directory so path redaction is deterministic.
    private let scrubber = SentryEventScrubber(scrubber: SentryScrubber(homeDirectory: "/Users/lawrence"))

    @Test func scrubsFormattedOnlyMessageExceptionAndTransaction() {
        let event = Event()
        // `capture(message:)` sets only `formatted`, leaving the template nil.
        // The scrubber must catch the rendered text, not just the template.
        event.message = SentryMessage(formatted: "boom for lawrence@cmux.com")
        event.transaction = "open /Users/lawrence/secret.txt"

        let exception = Exception(value: "failed at /Users/buildbot/app.swift", type: "NSRangeException")
        event.exceptions = [exception]

        let scrubbed = scrubber.scrub(event)

        #expect(scrubbed.message?.formatted == "boom for <redacted-email>")
        #expect(scrubbed.transaction == "open /Users/<redacted>/secret.txt")
        // Exception value is redacted; the type is preserved for grouping.
        #expect(scrubbed.exceptions?.first?.value == "failed at /Users/<redacted>/app.swift")
        #expect(scrubbed.exceptions?.first?.type == "NSRangeException")
    }

    @Test func scrubsContextDictionaries() {
        let event = Event()
        // Mirrors scope.setContext(value:key:): cmux puts cwd / path data here.
        event.context = [
            "ui": ["cwd": "/Users/lawrence/dev/cmux", "action": "open"],
            "auth": ["token": "abcdef0123456789secretvalue"],
        ]

        let scrubbed = scrubber.scrub(event)
        #expect(scrubbed.context?["ui"]?["cwd"] as? String == "/Users/<redacted>/dev/cmux")
        #expect(scrubbed.context?["ui"]?["action"] as? String == "open")
        #expect(scrubbed.context?["auth"]?["token"] as? String == "<redacted-secret>")
    }

    @Test func scrubsStackFramePathsButKeepsSymbols() {
        let event = Event()
        let frame = Frame()
        frame.fileName = "/Users/buildbot/work/cmux/Sources/AppDelegate.swift"
        frame.function = "applicationDidFinishLaunching(_:)"
        frame.package = "/Users/buildbot/Library/Developer/Xcode/DerivedData/cmux/Build/cmux.app"
        frame.lineNumber = 1325

        let stack = SentryStacktrace(frames: [frame], registers: [:])
        let exception = Exception(value: "x", type: "T")
        exception.stacktrace = stack
        event.exceptions = [exception]

        let outFrame = scrubber.scrub(event).exceptions?.first?.stacktrace?.frames.first
        #expect(outFrame?.fileName == "/Users/<redacted>/work/cmux/Sources/AppDelegate.swift")
        #expect(outFrame?.package?.hasPrefix("/Users/<redacted>/") == true)
        // Grouping-relevant symbol metadata is untouched.
        #expect(outFrame?.function == "applicationDidFinishLaunching(_:)")
        #expect(outFrame?.lineNumber == 1325)
    }

    @Test func scrubsThreadStackFrames() {
        let event = Event()
        let frame = Frame()
        frame.fileName = "/Users/runner/main.swift"
        let thread = SentryThread(threadId: 0)
        thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.threads = [thread]

        let outFrame = scrubber.scrub(event).threads?.first?.stacktrace?.frames.first
        #expect(outFrame?.fileName == "/Users/<redacted>/main.swift")
    }

    @Test func scrubsRequestUrlAndUser() {
        let event = Event()
        let request = SentryRequest()
        request.url = "https://api.example.com/v1"
        request.queryString = "token=supersecretvalue12345&page=2"
        request.cookies = "session=abcdefghijklmnopqrstuv"
        event.request = request

        let user = User()
        user.email = "lawrence@cmux.com"
        user.username = "lawrence"
        user.ipAddress = "203.0.113.7"
        event.user = user

        let scrubbed = scrubber.scrub(event)
        #expect(scrubbed.request?.queryString == "token=<redacted-secret>&page=2")
        #expect(scrubbed.request?.url == "https://api.example.com/v1")
        #expect(scrubbed.user?.email == "<redacted-email>")
        #expect(scrubbed.user?.username == "lawrence")
        // IP is always dropped.
        #expect(scrubbed.user?.ipAddress == nil)
    }

    @Test func scrubsExtraAndTags() {
        let event = Event()
        event.extra = ["cwd": "/Users/lawrence/dev", "n": 3]
        event.tags = ["path": "/Users/lawrence/x", "kind": "warning"]

        let scrubbed = scrubber.scrub(event)
        #expect(scrubbed.extra?["cwd"] as? String == "/Users/<redacted>/dev")
        #expect(scrubbed.extra?["n"] as? Int == 3)
        #expect(scrubbed.tags?["path"] == "/Users/<redacted>/x")
        #expect(scrubbed.tags?["kind"] == "warning")
    }

    @Test func scrubsBreadcrumbMessageAndData() {
        let breadcrumb = Breadcrumb(level: .info, category: "ui")
        breadcrumb.message = "ran in /Users/lawrence/proj with token=abcdef0123456789zz"
        breadcrumb.data = ["url": "https://x.com/?password=hunter2hunter2hunter2"]

        let scrubbed = scrubber.scrub(breadcrumb)
        #expect(scrubbed.message == "ran in /Users/<redacted>/proj with token=<redacted-secret>")
        #expect(scrubbed.data?["url"] as? String == "https://x.com/?password=<redacted-secret>")
    }

    @Test func preservesEventWithNothingSensitive() {
        let event = Event()
        event.message = SentryMessage(formatted: "Index out of range")
        let exception = Exception(value: "fatal error: Index out of range", type: "EXC_BAD_INSTRUCTION")
        event.exceptions = [exception]

        let scrubbed = scrubber.scrub(event)
        #expect(scrubbed.message?.formatted == "Index out of range")
        #expect(scrubbed.exceptions?.first?.value == "fatal error: Index out of range")
        #expect(scrubbed.exceptions?.first?.type == "EXC_BAD_INSTRUCTION")
    }
}
