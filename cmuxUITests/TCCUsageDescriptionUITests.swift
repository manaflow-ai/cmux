import Foundation
import XCTest

final class TCCUsageDescriptionUITests: XCTestCase {
    func testBuiltAppDeclaresUsageDescriptionsForTerminalDescendants() throws {
        let appBundle = try XCTUnwrap(Bundle(url: builtAppBundleURL()))
        let requiredKeys = [
            "NSAppBundlesUsageDescription",
            "NSAppDataUsageDescription",
            "NSAppleEventsUsageDescription",
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
            "NSFileProviderDomainUsageDescription",
            "NSNetworkVolumesUsageDescription",
            "NSRemovableVolumesUsageDescription",
            "NSAudioCaptureUsageDescription",
            "NSBluetoothAlwaysUsageDescription",
            "NSCalendarsUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSCalendarsWriteOnlyAccessUsageDescription",
            "NSCameraUsageDescription",
            "NSContactsUsageDescription",
            "NSRemindersUsageDescription",
            "NSRemindersFullAccessUsageDescription",
            "NSLocationUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSSystemAdministrationUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSMotionUsageDescription"
        ]

        for key in requiredKeys {
            let description = try XCTUnwrap(
                appBundle.object(forInfoDictionaryKey: key) as? String,
                "Built app is missing \(key)"
            )
            XCTAssertFalse(
                description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Built app has an empty \(key)"
            )
        }
    }

    func testBuiltAppOptsOutOfSecurityCodeAutoFill() throws {
        let appBundle = try XCTUnwrap(Bundle(url: builtAppBundleURL()))
        XCTAssertEqual(
            appBundle.object(forInfoDictionaryKey: "NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac") as? Bool,
            true
        )
    }

    private func builtAppBundleURL() throws -> URL {
        let testBundle = Bundle(for: Self.self)
        let productsDirectory = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appCandidates = try FileManager.default.contentsOfDirectory(
            at: productsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "app" }
        let cmuxCandidates = appCandidates.filter { url in
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return false }
            return bundleIdentifier == "com.cmuxterm.app" || bundleIdentifier == "com.cmuxterm.app.debug"
        }

        guard cmuxCandidates.count == 1, let appURL = cmuxCandidates.first else {
            let candidates = appCandidates.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw NSError(
                domain: "TCCUsageDescriptionUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Expected one built cmux app in \(productsDirectory.path); candidates: [\(candidates)]"
                ]
            )
        }

        return appURL
    }
}
