import Darwin
import Foundation

/// A fresh process is essential: app-host tests have already initialized the
/// process identity before any assertion can exercise the cold once guard.
@main
enum IdentityColdStartFixture {
    @MainActor
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let requestedHome = environment["CMUX_IDENTITY_FIXTURE_HOME"],
              let fixedHome = environment["CFFIXED_USER_HOME"],
              let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            fail("fixture home metadata is missing")
        }
        let home = canonicalPath(requestedHome)
        let foundationHome = canonicalPath(NSHomeDirectory())
        emit([
            "event": "fixture-home-preflight",
            "expected_home": home,
            "foundation_home": foundationHome,
            "fixed_home": canonicalPath(fixedHome),
            "application_support": canonicalPath(support.path)
        ])
        guard foundationHome == home, canonicalPath(fixedHome) == home else {
            fail("fixture must have a private Foundation home")
        }
        guard canonicalPath(support.path).hasPrefix(home + "/") else {
            fail("application support escaped the fixture home")
        }
        guard let expectedBundleID = environment["CMUX_IDENTITY_FIXTURE_BUNDLE_ID"],
              expectedBundleID.hasPrefix("com.cmuxterm.fixture.identity."),
              Bundle.main.bundleIdentifier == expectedBundleID else {
            fail("fixture must have its own preference domain")
        }
        let directory = support.appendingPathComponent("cmux", isDirectory: true)
        let sharedURL = directory.appendingPathComponent("mobile-host-device-id")
        guard !FileManager.default.fileExists(atPath: sharedURL.path),
              UserDefaults.standard.object(forKey: "mobileHost.deviceID") == nil else {
            fail("fixture identity was not cold; refusing to mutate it")
        }

        let mode = CommandLine.arguments.dropFirst().first ?? "fresh"
        var expected: String?
        if mode == "shared-winner" {
            expected = "3d56c547-271c-47d8-84f6-5c79c9394a37"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try expected!.uppercased().write(to: sharedURL, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(
                "175dff61-cabe-4076-b5ac-f5c1c04b62fa",
                forKey: "mobileHost.deviceID"
            )
        } else if mode != "fresh" {
            fail("unknown fixture mode")
        }

        let probe = IdentityNotificationProbe(sharedURL: sharedURL, expected: expected)
        probe.observe()
        await MobileHostIdentity.prewarm()
        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<16 {
                group.addTask { MobileHostIdentity.deviceID() }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        probe.finish(values: values)
    }

    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func fail(_ message: String) -> Never {
        emit(["error": message])
        exit(1)
    }
}
