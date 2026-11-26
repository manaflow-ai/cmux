//! The `app.language` setting: the locales cmux ships and the one place that
//! picks the language from the setting and the system's preferred languages.

use serde_json::Value;

/// The `app.language` value that follows the system's language order.
pub const SYSTEM: &str = "system";

/// Every locale cmux ships, as Apple localization codes with their endonyms,
/// in the order of the setting's choices.
pub const SHIPPED: &[(&str, &str)] = &[
    ("en", "English"),
    ("ar", "العربية"),
    ("bs", "Bosanski"),
    ("da", "Dansk"),
    ("de", "Deutsch"),
    ("es", "Español"),
    ("fr", "Français"),
    ("it", "Italiano"),
    ("nb", "Norsk bokmål"),
    ("pl", "Polski"),
    ("pt-BR", "Português (Brasil)"),
    ("tr", "Türkçe"),
    ("vi", "Tiếng Việt"),
    ("ru", "Русский"),
    ("uk", "Українська"),
    ("th", "ไทย"),
    ("km", "ខ្មែរ"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("zh-Hans", "简体中文"),
    ("zh-Hant", "繁體中文"),
];

/// The shipped code equal to `code`, as a static string.
fn shipped(code: &str) -> Option<&'static str> {
    SHIPPED.iter().map(|(shipped, _)| *shipped).find(|shipped| *shipped == code)
}

/// The shipped code equal to `code` ignoring ASCII case.
fn shipped_ignoring_case(code: &str) -> Option<&'static str> {
    SHIPPED.iter().map(|(shipped, _)| *shipped).find(|shipped| shipped.eq_ignore_ascii_case(code))
}

/// The language cmux shows: `setting` when it is a shipped code, else the
/// first of `preferred` (BCP 47 or POSIX locale tags) that matches a shipped
/// locale, else English. Matches `resolveLanguage` in
/// webviews/src/pages/shared/i18n.ts.
pub fn resolve(setting: Option<&str>, preferred: &[&str]) -> &'static str {
    if let Some(code) = setting.and_then(shipped) {
        return code;
    }
    preferred.iter().find_map(|tag| negotiate(tag)).unwrap_or("en")
}

/// The shipped locale for one preferred-language tag, if any.
fn negotiate(raw: &str) -> Option<&'static str> {
    // POSIX `ja_JP.UTF-8` or `sr_RS@latin`: drop the codeset and modifier.
    let tag = raw.split(['.', '@']).next().unwrap_or_default().trim().replace('_', "-");
    if tag.is_empty() {
        return None;
    }
    if let Some(code) = shipped_ignoring_case(&tag) {
        return Some(code);
    }
    let mut parts = tag.split('-');
    let base = parts.next().unwrap_or_default().to_ascii_lowercase();
    match base.as_str() {
        "zh" => {
            let traditional = parts.any(|part| {
                ["hant", "tw", "hk", "mo"].iter().any(|t| part.eq_ignore_ascii_case(t))
            });
            shipped(if traditional { "zh-Hant" } else { "zh-Hans" })
        }
        "pt" => shipped("pt-BR"),
        "no" | "nn" | "nb" => shipped("nb"),
        _ => shipped(&base),
    }
}

/// The shipped code `app.language` names in a settings document, or `None`
/// when it is unset, `"system"` or not a shipped locale.
pub fn from_settings(root: &Value) -> Option<&'static str> {
    crate::value::value_at(root, &["app", "language"][..]).and_then(Value::as_str).and_then(shipped)
}

#[cfg(test)]
#[path = "language_tests.rs"]
mod tests;
