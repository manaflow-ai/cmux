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
mod tests {
    use super::*;
    use serde_json::json;

    static GENERAL_SOURCE: &str = include_str!("../../../../schemas/settings/source/general.json");
    static SETTINGS_WINDOW_STRINGS: &str = include_str!(
        "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/Localizable.xcstrings"
    );

    fn system(preferred: &[&str]) -> &'static str {
        resolve(None, preferred)
    }

    #[test]
    fn a_shipped_setting_wins_over_the_system() {
        assert_eq!(resolve(Some("ja"), &["en_US.UTF-8"]), "ja");
        assert_eq!(resolve(Some("zh-Hant"), &["zh-CN"]), "zh-Hant");
        assert_eq!(resolve(Some("pt-BR"), &[]), "pt-BR");
    }

    #[test]
    fn system_and_invalid_settings_follow_the_system() {
        for setting in [None, Some(SYSTEM), Some("xx"), Some(""), Some("JA"), Some("ja_JP")] {
            assert_eq!(resolve(setting, &["de-DE"]), "de", "{setting:?}");
            assert_eq!(resolve(setting, &[]), "en", "{setting:?}");
        }
    }

    #[test]
    fn exact_and_base_language_matches() {
        assert_eq!(system(&["fr"]), "fr");
        assert_eq!(system(&["fr-CA"]), "fr");
        assert_eq!(system(&["pt-BR"]), "pt-BR");
        assert_eq!(system(&["zh-Hans"]), "zh-Hans");
        assert_eq!(system(&["KO-kr"]), "ko");
    }

    #[test]
    fn posix_tags_drop_codeset_and_modifier() {
        assert_eq!(system(&["ja_JP.UTF-8"]), "ja");
        assert_eq!(system(&["uk_UA.UTF-8@euro"]), "uk");
        assert_eq!(system(&["de_DE@euro"]), "de");
        assert_eq!(system(&["pt_BR.UTF-8"]), "pt-BR");
        assert_eq!(system(&["C"]), "en");
        assert_eq!(system(&["C.UTF-8"]), "en");
        assert_eq!(system(&["POSIX"]), "en");
        assert_eq!(system(&[""]), "en");
    }

    #[test]
    fn chinese_picks_the_script() {
        assert_eq!(system(&["zh"]), "zh-Hans");
        assert_eq!(system(&["zh-CN"]), "zh-Hans");
        assert_eq!(system(&["zh_SG"]), "zh-Hans");
        assert_eq!(system(&["zh-TW"]), "zh-Hant");
        assert_eq!(system(&["zh-HK"]), "zh-Hant");
        assert_eq!(system(&["zh_MO.UTF-8"]), "zh-Hant");
        assert_eq!(system(&["zh-Hant-TW"]), "zh-Hant");
        assert_eq!(system(&["zh-hant"]), "zh-Hant");
    }

    #[test]
    fn portuguese_and_norwegian_map_to_the_shipped_variant() {
        assert_eq!(system(&["pt"]), "pt-BR");
        assert_eq!(system(&["pt-PT"]), "pt-BR");
        assert_eq!(system(&["no"]), "nb");
        assert_eq!(system(&["nn"]), "nb");
        assert_eq!(system(&["nn_NO.UTF-8"]), "nb");
        assert_eq!(system(&["nb-NO"]), "nb");
    }

    #[test]
    fn first_match_wins_else_english() {
        assert_eq!(system(&["xx", "sw", "ja-JP", "de"]), "ja");
        assert_eq!(system(&["de", "ja"]), "de");
        assert_eq!(system(&["xx", "sw"]), "en");
    }

    #[test]
    fn from_settings_reads_only_shipped_codes() {
        assert_eq!(from_settings(&json!({"app": {"language": "ja"}})), Some("ja"));
        assert_eq!(from_settings(&json!({"app": {"language": "zh-Hans"}})), Some("zh-Hans"));
        assert_eq!(from_settings(&json!({"app": {"language": "system"}})), None);
        assert_eq!(from_settings(&json!({"app": {"language": "klingon"}})), None);
        assert_eq!(from_settings(&json!({"app": {"language": 3}})), None);
        assert_eq!(from_settings(&json!({"app": {}})), None);
        assert_eq!(from_settings(&json!({})), None);
        assert_eq!(from_settings(&json!([])), None);
    }

    #[test]
    fn the_setting_row_lists_system_and_every_shipped_locale() {
        let source: Value = serde_json::from_str(GENERAL_SOURCE).expect("general.json parses");
        let row = source["lists"]
            .as_array()
            .expect("lists")
            .iter()
            .flat_map(|list| list["rows"].as_array().into_iter().flatten())
            .find(|row| row["key"] == "app.language")
            .expect("app.language row");
        assert_eq!(row["kind"], "choice");
        assert_eq!(row["default"], SYSTEM);
        let choices = row["choices"].as_array().expect("choices");
        let values: Vec<&str> =
            choices.iter().map(|c| c["value"].as_str().expect("value")).collect();
        let expected: Vec<&str> =
            std::iter::once(SYSTEM).chain(SHIPPED.iter().map(|(code, _)| *code)).collect();
        assert_eq!(values, expected);
        let titles: Vec<&str> =
            choices[1..].iter().map(|c| c["title"]["text"].as_str().expect("title")).collect();
        let endonyms: Vec<&str> = SHIPPED.iter().map(|(_, name)| *name).collect();
        assert_eq!(titles, endonyms);
        for choice in &choices[1..] {
            assert!(choice["title"]["key"].is_null(), "endonyms are not translated: {choice}");
        }
    }

    #[test]
    fn shipped_matches_the_settings_window_catalog() {
        let catalog: Value =
            serde_json::from_str(SETTINGS_WINDOW_STRINGS).expect("Localizable.xcstrings parses");
        let mut locales = std::collections::BTreeSet::new();
        if let Some(source) = catalog["sourceLanguage"].as_str() {
            locales.insert(source.to_string());
        }
        for entry in catalog["strings"].as_object().expect("strings").values() {
            if let Some(localizations) = entry["localizations"].as_object() {
                locales.extend(localizations.keys().cloned());
            }
        }
        let shipped: std::collections::BTreeSet<String> =
            SHIPPED.iter().map(|(code, _)| code.to_string()).collect();
        assert_eq!(shipped, locales);
    }
}
