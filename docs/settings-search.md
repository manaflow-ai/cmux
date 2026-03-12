# Settings Search

The Settings window has a search field in the title bar. Typing filters the visible sections in real time.

## How it works

### Sections

Settings are grouped into six sections: **App**, **Workspace Colors**, **Automation**, **Browser**, **Keyboard Shortcuts**, and **Reset**. Each section is shown or hidden as a unit based on whether the query matches any of its terms.

### Matching

Matching is case-insensitive substring search against a list of terms derived from the section's UI labels:

```swift
func settingsSectionMatches(query: String, terms: [String]) -> Bool {
    guard !query.isEmpty else { return true }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return terms.contains { $0.lowercased().contains(q) }
}
```

An empty query shows all sections. Whitespace-only queries are treated the same as empty.

### Search terms

Each `SettingsSection` case exposes a `searchTerms: [String]` property populated with the same `String(localized:defaultValue:)` calls used to render the UI labels. This means:

- Search terms update automatically when a new setting row is added (just add its label to the array).
- Search works in every supported language — when the app language is Japanese the terms resolve to Japanese, so typing in Japanese finds the right section.
- The **Keyboard Shortcuts** section includes all `KeyboardShortcutSettings.Action` labels dynamically, so every shortcut action name is searchable without manual maintenance.

### Debounce

The search field binds to `searchQuery` on every keystroke, but `sectionVisible` reads `debouncedSearchQuery`, which trails by 200 ms. Each keystroke cancels the previous pending update via a `Task`:

```swift
searchDebounceTask?.cancel()
searchDebounceTask = Task {
    try? await Task.sleep(for: .milliseconds(200))
    guard !Task.isCancelled else { return }
    debouncedSearchQuery = newValue
}
```

This keeps the text field responsive while avoiding a full re-render of the settings content on every character.

## Adding a new setting to search

When you add a new row to a settings section, add its label key to the corresponding `SettingsSection.searchTerms` array:

```swift
case .app:
    return [
        // existing terms…
        String(localized: "settings.app.myNewSetting", defaultValue: "My New Setting"),
    ]
```

No other changes are needed — the section visibility logic picks it up automatically.

## Files

| File | Role |
|------|------|
| `Sources/cmuxApp.swift` — `settingsSectionMatches` | Pure matching function |
| `Sources/cmuxApp.swift` — `SettingsSection` | Section → search terms mapping |
| `Sources/cmuxApp.swift` — `SettingsView` | Debounce state, `sectionVisible`, UI |
| `cmuxTests/SettingsSearchTests.swift` | Unit tests for matching logic and term coverage |
