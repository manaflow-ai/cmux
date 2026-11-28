//! Dotted settings keys and their key paths (Swift `CmuxConfigFile.keyPath`).

/// Keys under `shortcuts` that are not action ids
/// (Swift `CmuxConfigSnapshot.reservedShortcutKeys`).
pub const RESERVED_SHORTCUT_KEYS: [&str; 4] =
    ["bindings", "tiers", "when", "showModifierHoldHints"];

/// Splits a dotted settings path. Action ids contain dots
/// (`tabGroup.create`), so everything after `shortcuts.bindings.`,
/// `shortcuts.when.`, or a direct `shortcuts.` action key is one key.
pub fn key_path(dotted: &str) -> Vec<String> {
    let trimmed = crate::text::trim_whitespaces(dotted);
    if trimmed.is_empty() {
        return Vec::new();
    }
    for prefix in ["shortcuts.bindings.", "shortcuts.when."] {
        if let Some(rest) = trimmed.strip_prefix(prefix) {
            let mut path: Vec<String> = split_nonempty(prefix);
            if !rest.is_empty() {
                path.push(rest.to_string());
            }
            return path;
        }
    }
    if let Some(rest) = trimmed.strip_prefix("shortcuts.") {
        let head = rest.split('.').find(|part| !part.is_empty()).unwrap_or(rest);
        if RESERVED_SHORTCUT_KEYS.contains(&head) {
            let mut path = vec!["shortcuts".to_string()];
            path.extend(split_nonempty(rest));
            return path;
        }
        return vec!["shortcuts".to_string(), rest.to_string()];
    }
    trimmed.split('.').map(str::to_string).collect()
}

/// The dotted key of a path, as diagnostics, events and the CLI print it.
pub fn dotted<S: AsRef<str>>(path: &[S]) -> String {
    path.iter().map(AsRef::as_ref).collect::<Vec<_>>().join(".")
}

/// Swift `split(separator:)`: empty pieces are dropped.
fn split_nonempty(text: &str) -> Vec<String> {
    text.split('.').filter(|part| !part.is_empty()).map(str::to_string).collect()
}
