import Foundation
import Testing

/// Regression coverage for the macOS privacy usage-description keys cmux must
/// declare in its app `Info.plist`.
///
/// cmux is a host for arbitrary CLI programs. macOS gates TCC access (Calendar,
/// Reminders, Contacts, Photos, etc.) on the presence of a purpose string in the
/// hosting app's `Info.plist`. Because cmux is non-sandboxed (hardened runtime
/// only), the purpose string alone is what makes the permission dialog appear;
/// with no string, the OS silently denies access to a hosted program (e.g.
/// `icalBuddy`) and cmux never shows up in System Settings > Privacy.
///
/// This suite locks in the required keys so a key cannot be dropped without a
/// failing test. The cmuxTests target's `TEST_HOST`/`BUNDLE_LOADER` point at the
/// built cmux app, so `Bundle.main` resolves the app's `Info.plist`.
@Suite struct InfoPlistPrivacyKeysTests {
    /// Every usage-description key cmux must ship. The first four predate this
    /// suite; the remainder were added to reach parity with Ghostty (another
    /// non-sandboxed terminal host) plus the macOS 14+ full-access variants that
    /// the EventKit read path requires.
    static let requiredUsageDescriptionKeys = [
        // Pre-existing keys.
        "NSMicrophoneUsageDescription",
        "NSCameraUsageDescription",
        "NSBluetoothAlwaysUsageDescription",
        "NSAppleEventsUsageDescription",
        // Added for hosted-program TCC parity.
        "NSCalendarsUsageDescription",
        "NSCalendarsFullAccessUsageDescription",
        "NSRemindersUsageDescription",
        "NSRemindersFullAccessUsageDescription",
        "NSContactsUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSLocationUsageDescription",
        "NSLocalNetworkUsageDescription",
        "NSAudioCaptureUsageDescription",
        "NSMotionUsageDescription",
        "NSSpeechRecognitionUsageDescription",
        "NSSystemAdministrationUsageDescription",
    ]

    @Test(arguments: InfoPlistPrivacyKeysTests.requiredUsageDescriptionKeys)
    func usageDescriptionIsPresentAndNonEmpty(_ key: String) throws {
        let value = Bundle.main.object(forInfoDictionaryKey: key)
        let string = try #require(
            value as? String,
            "Info.plist is missing required usage-description key \(key)"
        )
        #expect(
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Usage-description string for \(key) must not be empty"
        )
    }
}
