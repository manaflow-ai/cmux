import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV

final class CuaDriverBinaryResolverTests: XCTestCase {
    func testResolutionOrder() {
        let resolver = CuaDriverBinaryResolver()
        let setting = URL(fileURLWithPath: "/tmp/setting-cua-driver")
        let env = URL(fileURLWithPath: "/tmp/env-cua-driver")
        let bundle = URL(fileURLWithPath: "/tmp/bundle-cua-driver")
        let existing = Set([
            setting.standardizedFileURL,
            env.standardizedFileURL,
            bundle.standardizedFileURL,
            CuaDriverBinaryResolver.applicationsURL.standardizedFileURL,
        ])

        let resolution = resolver.resolve(
            settingValue: setting.path,
            environment: [CuaDriverBinaryResolver.environmentKey: env.path],
            bundleHelperURL: bundle,
            fileExists: { existing.contains($0.standardizedFileURL) }
        )

        XCTAssertEqual(resolution?.url, setting.standardizedFileURL)
        XCTAssertEqual(resolution?.source, .setting)
    }

    func testEnvironmentBeatsBundleAndApplicationsWhenSettingIsEmpty() {
        let resolver = CuaDriverBinaryResolver()
        let env = URL(fileURLWithPath: "/tmp/env-cua-driver")
        let bundle = URL(fileURLWithPath: "/tmp/bundle-cua-driver")
        let existing = Set([
            env.standardizedFileURL,
            bundle.standardizedFileURL,
            CuaDriverBinaryResolver.applicationsURL.standardizedFileURL,
        ])

        let resolution = resolver.resolve(
            settingValue: "",
            environment: [CuaDriverBinaryResolver.environmentKey: env.path],
            bundleHelperURL: bundle,
            fileExists: { existing.contains($0.standardizedFileURL) }
        )

        XCTAssertEqual(resolution?.url, env.standardizedFileURL)
        XCTAssertEqual(resolution?.source, .environment)
    }

    func testBundleBeatsApplicationsWhenSettingAndEnvironmentAreMissing() {
        let resolver = CuaDriverBinaryResolver()
        let setting = URL(fileURLWithPath: "/tmp/missing-setting-cua-driver")
        let env = URL(fileURLWithPath: "/tmp/missing-env-cua-driver")
        let bundle = URL(fileURLWithPath: "/tmp/bundle-cua-driver")
        let existing = Set([
            bundle.standardizedFileURL,
            CuaDriverBinaryResolver.applicationsURL.standardizedFileURL,
        ])

        let resolution = resolver.resolve(
            settingValue: setting.path,
            environment: [CuaDriverBinaryResolver.environmentKey: env.path],
            bundleHelperURL: bundle,
            fileExists: { existing.contains($0.standardizedFileURL) }
        )

        XCTAssertEqual(resolution?.url, bundle.standardizedFileURL)
        XCTAssertEqual(resolution?.source, .bundleHelper)
    }

    func testApplicationsFallback() {
        let resolver = CuaDriverBinaryResolver()
        let bundle = URL(fileURLWithPath: "/tmp/missing-bundle-cua-driver")

        let resolution = resolver.resolve(
            settingValue: "",
            environment: [:],
            bundleHelperURL: bundle,
            fileExists: { $0.standardizedFileURL == CuaDriverBinaryResolver.applicationsURL.standardizedFileURL }
        )

        XCTAssertEqual(resolution?.url, CuaDriverBinaryResolver.applicationsURL.standardizedFileURL)
        XCTAssertEqual(resolution?.source, .applications)
    }

    func testNilWhenNoCandidateExists() {
        let resolver = CuaDriverBinaryResolver()

        let resolution = resolver.resolve(
            settingValue: "",
            environment: [:],
            bundleHelperURL: URL(fileURLWithPath: "/tmp/missing-bundle-cua-driver"),
            fileExists: { _ in false }
        )

        XCTAssertNil(resolution)
    }
}
#endif
