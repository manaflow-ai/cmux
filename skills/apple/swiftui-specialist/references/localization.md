# String Catalogs

Most projects localize through String Catalogs (`.xcstrings`). Each build syncs new strings from code into the catalog, but the catalog file must already exist — Xcode does not create one automatically. If a project already uses `.strings` or `.stringsdict` files, add new strings to the existing files rather than asking the user to migrate.

A project can use multiple String Catalogs and route strings to a specific one with the `tableName` parameter — useful when it makes sense to keep groups of strings separate (e.g., per feature or module).

```swift
Text("Explore", tableName: "Navigation",
     comment: "Tab bar item title for the Explore screen.")
```

# Bundle for Swift Packages and Frameworks

Apps, app extensions, and XPC services are their own main bundle, so the `bundle` parameter can be omitted. Frameworks and Swift packages need an explicit `bundle`; without one, SwiftUI looks up strings from `Bundle.main` and the lookup fails silently — the string appears unlocalized at runtime.

```swift
// AVOID: Inside a framework or Swift package, this searches the app's catalog.
Text("Save to Favorites")
```

```swift
// PREFER: #bundle resolves to the current target's bundle.
Text("Save to Favorites", bundle: #bundle,
     comment: "Button to bookmark a recipe.")
```

`#bundle` is the preferred form; `Bundle.module` and `Bundle(for: MyClass.self)` work but are older patterns.

# SwiftUI Views Localize String Literals Automatically

SwiftUI initializers that accept `LocalizedStringKey` (e.g., `Text`, `Button`, `.navigationTitle`) automatically treat string literals as localization keys. Do not wrap literals in `NSLocalizedString`, `String(localized:)`, or `LocalizedStringResource`.

```swift
// AVOID: Text already treats literals as LocalizedStringKey; wrapping
// also resolves the string eagerly, ignoring \.locale overrides.
Text(NSLocalizedString("start_workout", comment: ""))
Text(String(localized: "start_workout"))
```

```swift
// PREFER: Pass the string literal directly.
Text("start_workout")
```

Both opaque keys (`"start_workout"`) and natural-language strings (`"Start Workout"`) work as `LocalizedStringKey` values. Choose whichever convention the project uses consistently — with opaque keys, the source-language text is set in the String Catalog directly, not at the call site.

Use `Text(verbatim:)` to opt out of localization for a string literal — most often a debug label that interpolates a runtime value (e.g., `Text(verbatim: "Session: \(sessionID)")`), where the literal would otherwise be treated as a localization key. When the argument is already a `String` variable, `Text(value)` calls the `StringProtocol` overload and skips localization on its own — no `verbatim:` needed.

# Localizing Variables and Custom Types

When a `String` variable is passed to `Text`, the `StringProtocol` overload runs and the string is NOT localized. Wrapping the variable in `LocalizedStringKey(_:)` at the call site does not help either — Xcode cannot extract a literal from a runtime value, so the entry never lands in the catalog. To localize a value chosen from a known set of keys, model the set with a type that exposes `LocalizedStringResource`:

```swift
enum Category {
    case appetizers, mains, desserts
    var name: LocalizedStringResource {
        switch self {
        case .appetizers: "Appetizers"
        case .mains: "Mains"
        case .desserts: "Desserts"
        }
    }
}

Text(category.name)
```

When a view or view model exposes user-facing text, type the property as `LocalizedStringKey` or `LocalizedStringResource` instead of `String`. Every SwiftUI view that takes localized text accepts both, so deferring resolution costs nothing at the display site and preserves locale and bundle context end-to-end.

```swift
// AVOID: String properties lose localization context.
struct SectionHeader {
    let title: String
}
```

```swift
// PREFER: LocalizedStringResource keeps the string localizable.
struct SectionHeader {
    let title: LocalizedStringResource
}
```

# String Interpolation vs Concatenation

String interpolation preserves `LocalizedStringKey` and produces a format string in the catalog (e.g., `"Welcome, %@"`). Concatenation with `+` produces a `String` — the result is not localized.

```swift
// AVOID: + produces String, not LocalizedStringKey. Not localized.
Text("Error: " + statusMessage)
```

```swift
// PREFER: Interpolation preserves LocalizedStringKey.
Text("Error: \(statusMessage)")
```

Never glue separately localized fragments to form a sentence — word order varies across languages.

```swift
// AVOID: Sentence assembly breaks in languages with different word order.
Text(String(localized: "Created by")) + Text(" ") + Text(authorName)
```

```swift
// PREFER: A single string lets translators rearrange the structure.
Text("Created by \(authorName)")
```

# Casing

Bake the desired case into the string itself rather than transforming case at runtime via `.textCase(_:)`, `.localizedUppercase`, or `.localizedCapitalized`. A runtime transform forces the same casing decision across all translations, leaving translators no way to adjust per language.

```swift
// AVOID: forces the same casing on every translation.
Text("Section Header").textCase(.uppercase)

// PREFER: provide the desired case in the string itself.
Text("SECTION HEADER")
```

This applies to localized strings. Strings the user typed in should display as-is; you don't know what casing they intended. If a transform is unavoidable, prefer `.localizedUppercase` / `.localizedCapitalized`, which honor the user's locale (Turkish dotted/dotless I, German ß, etc.).

# Formatting Dates, Numbers, and Currencies

Use `Text`'s `format` parameter or `.formatted()` instead of `DateFormatter` or `NumberFormatter` with hardcoded format strings. Format styles adapt to the user's locale; hardcoded format strings do not. These overloads localize through the format style — they're not a bypass of localization, and the value itself doesn't produce a catalog entry. When the value is interpolated into a localized literal (e.g., `"Total: \(price, format: ...)"`), the surrounding literal still accepts a `comment:` as usual.

```swift
// AVOID: Hardcoded format does not adapt to locale.
let formatter = DateFormatter()
formatter.dateFormat = "MM/dd/yyyy"
Text(formatter.string(from: workout.date))
```

```swift
// PREFER: Format styles adapt to the user's locale automatically.
Text(workout.date, format: .dateTime.month().day().year())
```

Date field components (`.month()`, `.day()`, `.year()`) enable which fields appear; the locale determines output order — the chain order doesn't lock layout.

```swift
// AVOID: Hardcoded currency formatting.
Text("$\(product.price, specifier: "%.2f")")
```

```swift
// PREFER
Text(product.price, format: .currency(code: store.currencyCode))
```

For lists of strings, `Array.formatted()` inserts locale-correct separators and conjunctions instead of a hardcoded `joined(separator: ", ")`.

```swift
// AVOID
Text("Order: \(items.joined(separator: ", "))")
```

```swift
// PREFER
Text("Order: \(items.formatted())")
```

When `DateFormatter` is genuinely unavoidable, use `setLocalizedDateFormatFromTemplate(_:)` rather than assigning `dateFormat` directly — the template reorders fields per locale.

# Layout for Localization

Use `.leading` and `.trailing` instead of `.left` and `.right` — they flip for right-to-left locales; `.left` and `.right` don't.

```swift
// AVOID: .left does not flip for RTL languages.
Text(recipe.title)
    .frame(maxWidth: .infinity, alignment: .left)
```

```swift
// PREFER: .leading flips to the trailing edge in RTL locales.
Text(recipe.title)
    .frame(maxWidth: .infinity, alignment: .leading)
```

Do not hardcode frame widths or heights for text — translations vary in length and scripts vary in height. Use `ViewThatFits` when a layout might not fit longer translations.

```swift
// PREFER: ViewThatFits picks the first layout that fits.
ViewThatFits {
    HStack { actionButtons }
    VStack { actionButtons }
}
```

Use SwiftUI's text styles instead of fixed point sizes. Text styles let line height adapt per script; fixed point sizes can clip glyphs in tall scripts.

```swift
// AVOID: fixed point size locks line height.
Text("Welcome").font(.system(size: 17))

// PREFER: text styles let line height adapt per script.
Text("Welcome").font(.body)
```

# Reading the Current Locale

Use `@Environment(\.locale)` instead of `Locale.current` for locale-dependent logic in views — the environment respects preview overrides and per-view injection; `Locale.current` does not.

# String(localized:) Outside SwiftUI Views

When you need a localized `String` outside of SwiftUI views, use `String(localized:)`, not `NSLocalizedString`.

```swift
// AVOID
let title = NSLocalizedString("activity_summary", comment: "Dashboard header")
```

```swift
// PREFER
let title = String(localized: "activity_summary", comment: "Dashboard header")
```

Do not interpolate inside `NSLocalizedString` — Xcode extracts keys from literal strings at build time and cannot extract interpolated values. Use `String(localized:)` with interpolation instead; Xcode extracts the format string (e.g., `"reminder_body %@"`) and treats interpolated values as runtime arguments.

Prefer `String(localized:)` over `String(format:)` and `String.localizedStringWithFormat`. `String(format:)` always renders digits as 0–9 regardless of locale and is unsuitable for user-facing text; `String.localizedStringWithFormat` works when paired with `NSLocalizedString`, but `String(localized:)` is the modern API and the right default.

# LocalizedStringResource for Non-View Types

When a non-view type carries a user-facing string — a model object, a tip, a queued notification — use `LocalizedStringResource` instead of `String`. The string is resolved at display time, not creation time, so it honors the locale active when the value actually renders. Whenever a `String` would otherwise be passed between view models, modules, or into a view, `LocalizedStringResource` is the right type. Apply this when designing new types or changing user-facing text — don't sweep through existing `String` properties as part of unrelated edits.

```swift
// AVOID: Resolving at creation time loses the ability to display
// in a different locale later.
struct Tip {
    let headline: String
}
let tip = Tip(headline: String(localized: "Tip of the Day"))
```

```swift
// PREFER: LocalizedStringResource defers resolution to display time.
struct Tip {
    let headline: LocalizedStringResource
}
let tip = Tip(headline: "Tip of the Day")
```

# Comments for Translators

Add a `comment` describing the UI element and its purpose, especially for ambiguous strings. For interpolated strings, describe each placeholder by position — translators don't see Swift variable names.

```swift
// AVOID: "Edit" could be a noun or a verb — different translations.
Text("Edit")
```

```swift
// PREFER
Text("Edit", comment: "Toolbar button that enters editing mode for the list.")
```

```swift
// PREFER: refer to placeholders by position, not by Swift name.
Text("Completed \(count) of \(total)",
     comment: "Progress label — the first variable is finished items, the second is the total.")
```

Comments can also live in the String Catalog (per-string Comment field), equivalent to passing `comment:` at the call site — keep one source of truth per string.
