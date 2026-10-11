import SwiftUI

extension View {
    /// Plain text input: no autocapitalization, no autocorrection (iOS).
    @ViewBuilder
    func mobilePlainTextInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    /// Email-address keyboard + content type, no autocapitalize/correct (iOS).
    @ViewBuilder
    func mobileEmailTextInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    /// Alphanumeric one-time-code field with SMS autofill content type (iOS).
    @ViewBuilder
    func mobileOneTimeCodeInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.asciiCapable)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

}
