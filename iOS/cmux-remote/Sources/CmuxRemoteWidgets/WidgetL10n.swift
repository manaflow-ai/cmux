import Foundation

enum WidgetL10n {
    static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    static func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: any CVarArg...
    ) -> String {
        let format = String(localized: key, defaultValue: defaultValue)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
