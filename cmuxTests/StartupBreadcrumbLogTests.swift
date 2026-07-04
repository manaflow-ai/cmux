import Foundation
import CmuxFoundation
import Sentry
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct StartupBreadcrumbLogTests {
    @Test func stableBundleIdentifierIsEnabledAndDisableEnvWins() {
        #expect(StartupBreadcrumbLog.isEnabled(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app"
        ))
        #expect(!StartupBreadcrumbLog.isEnabled(
            environment: ["CMUX_DISABLE_STARTUP_BREADCRUMBS": "1"],
            bundleIdentifier: "com.cmuxterm.app"
        ))
    }

    @Test func appendWithoutBundleIdentifierWritesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("startup-unknown.log")

        StartupBreadcrumbLog.append(
            "disabled.test",
            configuration: StartupBreadcrumbLog.Configuration(
                environment: [:],
                bundleIdentifier: nil,
                appVersion: "1.0",
                build: "1",
                pid: 123,
                logURL: logURL,
                now: Date(timeIntervalSince1970: 0),
                fileManager: .default
            )
        )

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test func appendRotatesOversizedLogToSingleSibling() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("startup-com.cmuxterm.app.log")
        let rotatedURL = StartupBreadcrumbLog.rotatedLogURL(for: logURL)
        try Data(repeating: 0x61, count: StartupBreadcrumbLog.maximumLogBytes)
            .write(to: logURL)

        StartupBreadcrumbLog.append(
            "rotation.test",
            configuration: configuration(logURL: logURL)
        )

        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        let current = try String(contentsOf: logURL, encoding: .utf8)
        #expect(current.contains("\"event\":\"rotation.test\""))
        let currentSize = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber
        #expect((currentSize?.intValue ?? StartupBreadcrumbLog.maximumLogBytes) < StartupBreadcrumbLog.maximumLogBytes)
    }

    @Test func crashEventReceivesScrubbedStartupLogTail() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("startup-com.cmuxterm.app.log")
        try """
        {"event":"app.init.begin","path":"/Users/lawrence/secret.txt","email":"lawrence@cmux.com"}
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let event = Event()
        event.level = .fatal
        let scrubber = SentryEventScrubber(scrubber: SentryScrubber(homeDirectory: "/Users/lawrence"))

        let scrubbed = scrubber.scrub(StartupBreadcrumbLog.attachTailIfCrash(to: event, logURL: logURL))
        let startupContext = try #require(scrubbed.context?["startup_log"])
        let tail = try #require(startupContext["tail"] as? String)

        #expect(tail.contains("app.init.begin"))
        #expect(tail.contains("/Users/<redacted>/secret.txt"))
        #expect(tail.contains("<redacted-email>"))
    }

    @Test func nonCrashEventDoesNotReceiveStartupLogTail() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("startup-com.cmuxterm.app.log")
        try #"{"event":"app.init.begin"}"#.write(to: logURL, atomically: true, encoding: .utf8)

        let event = Event()
        event.level = .error

        let out = StartupBreadcrumbLog.attachTailIfCrash(to: event, logURL: logURL)
        #expect(out.context?["startup_log"] == nil)
    }

    private func configuration(logURL: URL) -> StartupBreadcrumbLog.Configuration {
        StartupBreadcrumbLog.Configuration(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            appVersion: "1.0",
            build: "1",
            pid: 123,
            logURL: logURL,
            now: Date(timeIntervalSince1970: 0),
            fileManager: .default
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-startup-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
