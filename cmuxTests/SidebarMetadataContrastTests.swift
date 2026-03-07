import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarMetadataContrastTests: XCTestCase {

    // MARK: - Dark mode

    func testDarkModeDimColorGetsBrightnessFloor() {
        let (h, s, b) = MetadataColorContrast.adjustedHSB(h: 0.0, s: 0.5, b: 0.1, isDark: true)
        XCTAssertEqual(b, 0.6, accuracy: 0.001, "Dark dim color should be raised to brightness 0.6")
        XCTAssertEqual(s, 0.5, accuracy: 0.001, "Saturation below cap should be unchanged")
        XCTAssertEqual(h, 0.0, accuracy: 0.001)
    }

    func testDarkModeHighSaturationGetsCapped() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.5, s: 0.95, b: 0.62, isDark: true)
        XCTAssertEqual(s, 0.7, accuracy: 0.001, "High saturation should be capped at 0.7")
        XCTAssertEqual(b, 0.62, accuracy: 0.001, "Brightness above floor should be unchanged")
    }

    func testDarkModeBothDimAndHighSaturation() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.0, s: 0.95, b: 0.1, isDark: true)
        XCTAssertEqual(s, 0.7, accuracy: 0.001)
        XCTAssertEqual(b, 0.6, accuracy: 0.001)
    }

    func testDarkModeNormalColorUnchanged() {
        let (h, s, b) = MetadataColorContrast.adjustedHSB(h: 0.3, s: 0.5, b: 0.7, isDark: true)
        XCTAssertEqual(h, 0.3, accuracy: 0.001)
        XCTAssertEqual(s, 0.5, accuracy: 0.001)
        XCTAssertEqual(b, 0.7, accuracy: 0.001, "Color within range should pass through unchanged")
    }

    // MARK: - Light mode

    func testLightModeBrightColorGetsCeiling() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.16, s: 1.0, b: 1.0, isDark: false)
        XCTAssertEqual(b, 0.65, accuracy: 0.001, "Bright color should be capped at 0.65")
        XCTAssertEqual(s, 1.0, accuracy: 0.001, "Saturation should be unchanged in light mode")
    }

    func testLightModeNearBlackGetsFloor() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.0, s: 0.0, b: 0.04, isDark: false)
        XCTAssertEqual(b, 0.25, accuracy: 0.001, "Near-black should be raised to 0.25")
        XCTAssertEqual(s, 0.0, accuracy: 0.001)
    }

    func testLightModeNormalColorUnchanged() {
        let (h, s, b) = MetadataColorContrast.adjustedHSB(h: 0.6, s: 0.5, b: 0.5, isDark: false)
        XCTAssertEqual(h, 0.6, accuracy: 0.001)
        XCTAssertEqual(s, 0.5, accuracy: 0.001)
        XCTAssertEqual(b, 0.5, accuracy: 0.001, "Mid-range color should pass through unchanged")
    }

    // MARK: - Boundary

    func testDarkModeBrightnessExactlyAtFloor() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.0, s: 0.5, b: 0.6, isDark: true)
        XCTAssertEqual(b, 0.6, accuracy: 0.001, "Exactly at floor should be unchanged")
        XCTAssertEqual(s, 0.5, accuracy: 0.001)
    }

    func testDarkModeSaturationExactlyAtCap() {
        let (_, s, b) = MetadataColorContrast.adjustedHSB(h: 0.0, s: 0.7, b: 0.8, isDark: true)
        XCTAssertEqual(s, 0.7, accuracy: 0.001, "Exactly at cap should be unchanged")
        XCTAssertEqual(b, 0.8, accuracy: 0.001)
    }
}
