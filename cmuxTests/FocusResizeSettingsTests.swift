import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FocusResizeSettingsTests: XCTestCase {
    private let enabledKey = FocusResizeSettings.enabledKey
    private let ratioKey = FocusResizeSettings.ratioKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: ratioKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: ratioKey)
        super.tearDown()
    }

    // MARK: - isEnabled()

    func testIsEnabledDefaultsToFalse() {
        XCTAssertFalse(FocusResizeSettings.isEnabled())
    }

    func testIsEnabledReflectsStoredValue() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        XCTAssertTrue(FocusResizeSettings.isEnabled())

        UserDefaults.standard.set(false, forKey: enabledKey)
        XCTAssertFalse(FocusResizeSettings.isEnabled())
    }

    // MARK: - ratio()

    func testRatioDefaultsTo075() {
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.75, accuracy: 0.001)
    }

    func testRatioReflectsStoredValue() {
        UserDefaults.standard.set(0.6, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.6, accuracy: 0.001)
    }

    func testRatioClampsValueBelowMinimum() {
        UserDefaults.standard.set(0.3, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.5, accuracy: 0.001)

        UserDefaults.standard.set(0.0, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.5, accuracy: 0.001)

        UserDefaults.standard.set(-1.0, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.5, accuracy: 0.001)
    }

    func testRatioClampsValueAboveMaximum() {
        UserDefaults.standard.set(0.95, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.9, accuracy: 0.001)

        UserDefaults.standard.set(1.0, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.9, accuracy: 0.001)

        UserDefaults.standard.set(5.0, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.9, accuracy: 0.001)
    }

    func testRatioAcceptsBoundaryValues() {
        UserDefaults.standard.set(0.5, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.5, accuracy: 0.001)

        UserDefaults.standard.set(0.9, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.9, accuracy: 0.001)
    }

    func testRatioReadsFloatBackedNSNumber() {
        // Simulates what `defaults write ... -float 0.8` produces: a Float-backed NSNumber.
        // The old `object(forKey:) as? Double` would fail this cast and return the default.
        let floatValue: Float = 0.8
        UserDefaults.standard.set(floatValue, forKey: ratioKey)
        XCTAssertEqual(FocusResizeSettings.ratio(), 0.8, accuracy: 0.001)
    }
}
