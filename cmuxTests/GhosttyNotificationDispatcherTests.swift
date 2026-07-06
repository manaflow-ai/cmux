import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GhosttyDefaultBackgroundNotificationDispatcherTests {
    @Test
    func signalCoalescesBurstToLatestBackground() throws {
        let dark = try #require(NSColor(hex: "#272822"))
        let light = try #require(NSColor(hex: "#FDF6E3"))
        var postedUserInfos: [[AnyHashable: Any]] = []
        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0,
            postNotification: { userInfo in
                postedUserInfos.append(userInfo)
            }
        )

        signal(dispatcher, backgroundColor: dark, opacity: 0.95, eventId: 1, source: "test.dark")
        signal(dispatcher, backgroundColor: light, opacity: 0.75, eventId: 2, source: "test.light")
        #expect(postedUserInfos.isEmpty)

        drainMainQueue()
        #expect(postedUserInfos.count == 1)
        #expect((postedUserInfos[0][GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() == "#FDF6E3")
        #expect(abs((postedOpacity(from: postedUserInfos[0][GhosttyNotificationKey.backgroundOpacity]) ?? -1) - 0.75) < 0.0001)
        #expect((postedUserInfos[0][GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value == 2)
        #expect(postedUserInfos[0][GhosttyNotificationKey.backgroundSource] as? String == "test.light")
    }

    @Test
    func signalAcrossSeparateBurstsPostsMultipleNotifications() throws {
        let dark = try #require(NSColor(hex: "#272822"))
        let light = try #require(NSColor(hex: "#FDF6E3"))
        var postedHexes: [String] = []
        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0,
            postNotification: { userInfo in
                postedHexes.append((userInfo[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil")
            }
        )

        signal(dispatcher, backgroundColor: dark, opacity: 1.0, eventId: 1, source: "test.dark")
        drainMainQueue()
        signal(dispatcher, backgroundColor: light, opacity: 1.0, eventId: 2, source: "test.light")
        drainMainQueue()
        #expect(postedHexes == ["#272822", "#FDF6E3"])
    }

    private func signal(
        _ dispatcher: GhosttyDefaultBackgroundNotificationDispatcher,
        backgroundColor: NSColor,
        opacity: Double,
        eventId: UInt64,
        source: String
    ) {
        dispatcher.signal(
            backgroundColor: backgroundColor,
            opacity: opacity,
            eventId: eventId,
            source: source,
            foregroundColor: backgroundColor,
            cursorColor: backgroundColor,
            cursorTextColor: backgroundColor,
            selectionBackground: backgroundColor,
            selectionForeground: backgroundColor
        )
    }

    private func postedOpacity(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        Issue.record("Expected background opacity payload")
        return nil
    }
}
