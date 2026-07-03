import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7273.
///
/// macOS Tahoe offers the Messages one-time-code AutoFill pill over any focused
/// NSTextInputClient unless the app opts out. cmux terminal surfaces implement
/// NSTextInputClient (GhosttyNSView) and never adopt a one-time-code content
/// type, so the built app bundle must ship Apple's documented opt-out key
/// `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` to keep the pill from
/// targeting terminals. This suite runs hosted in the app, so `Bundle.main` is
/// the built cmux app bundle and this asserts the processed Info.plist of the
/// actual product, not the checked-in source file.
@Suite struct MessagesOneTimeCodeAutoFillOptOutTests {
    @Test func builtAppBundleRequiresContentTypeForOneTimeCodeAutoFill() {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac"
        ) as? Bool
        #expect(value == true)
    }
}
