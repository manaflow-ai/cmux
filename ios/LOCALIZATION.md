# cmux iOS localization

cmux iOS supports these languages:

- English (`en`)
- German (`de`)
- French (`fr`)
- Arabic (`ar`)
- Spanish (`es`)
- Traditional Chinese (`zh-Hant`)
- Simplified Chinese (`zh-Hans`)
- Korean (`ko`)
- Japanese (`ja`)

User-facing labels, navigation titles, buttons, menus, alerts, accessibility labels, and help text must use `String(localized:)` or SwiftUI's localized-string initializers. Add new keys to the relevant `Localizable.xcstrings` catalog and provide every supported locale before merging.
