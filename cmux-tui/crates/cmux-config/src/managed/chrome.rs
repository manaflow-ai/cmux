//! Chrome enterprise policies cmux honors (Swift `ChromePolicyDocument`,
//! `ChromePolicyManagedPreferenceReader.chromePolicies`,
//! `ManagedPreferences(chromePolicy:)`).

use serde_json::{Map, Value, json};

pub const CHROME_DOMAIN: &str = "com.google.Chrome";
pub const CMUX_DOMAIN: &str = "com.manaflow.cmux.browser";
pub const HONOR_KEY: &str = "HonorChromePolicy";

/// Mandatory and recommended Chrome policies, by Chrome's policy names.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Document {
    pub mandatory: Map<String, Value>,
    pub recommended: Map<String, Value>,
}

impl Document {
    pub fn from_json(value: &Value) -> Document {
        let part =
            |key: &str| value.get(key).and_then(Value::as_object).cloned().unwrap_or_default();
        Document { mandatory: part("mandatory"), recommended: part("recommended") }
    }

    pub fn to_json(&self) -> Value {
        json!({ "mandatory": self.mandatory, "recommended": self.recommended })
    }

    /// This document with `other`'s values on top, key by key in each level.
    pub fn overlaid(mut self, other: &Document) -> Document {
        self.mandatory.extend(other.mandatory.clone());
        self.recommended.extend(other.recommended.clone());
        self
    }
}

/// The domain Chromium reads natively: Chrome's, unless the cmux browser
/// domain forces `HonorChromePolicy` to false.
pub fn native_policy_domain(cmux_browser: &Document) -> Option<&'static str> {
    (cmux_browser.mandatory.get(HONOR_KEY).and_then(Value::as_bool) != Some(false))
        .then_some(CHROME_DOMAIN)
}

/// The merged policies cmux applies: the browser domain over Chrome's.
pub fn merged(chrome: &Document, cmux_browser: &Document) -> Document {
    let mut own = cmux_browser.clone();
    let honor = own.mandatory.remove(HONOR_KEY).and_then(|v| v.as_bool()) != Some(false);
    own.recommended.remove(HONOR_KEY);
    let mut base = if honor { chrome.clone() } else { Document::default() };
    base.mandatory.remove(HONOR_KEY);
    base.recommended.remove(HONOR_KEY);
    base.overlaid(&own)
}

/// Swift `CharacterSet.whitespaces`: spaces and tabs (Unicode space separators).
fn trim_whitespaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c == '\t'
            || (c.is_whitespace()
                && !matches!(
                    c,
                    '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
                ))
    })
}

/// The RFC 3986 scheme of `text`, lowercased.
fn scheme(text: &str) -> Option<String> {
    let colon = text.find(':')?;
    let candidate = &text[..colon];
    let mut chars = candidate.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
    .then(|| candidate.to_ascii_lowercase())
}

fn is_web_scheme(text: &str) -> bool {
    matches!(scheme(text).as_deref(), Some("http" | "https"))
}

/// Whether `text` is an address `URL(string:)` takes: no space or control character.
fn url_like(text: &str) -> bool {
    !text.is_empty() && !text.chars().any(|c| c.is_whitespace() || c.is_control())
}

/// The cmux.json keys one level of Chrome policies sets.
pub fn settings(policies: &Map<String, Value>) -> Map<String, Value> {
    let mut settings = Map::new();
    let string = |key: &str| policies.get(key).and_then(Value::as_str).map(trim_whitespaces);
    let search = string("DefaultSearchProviderSearchURL");
    if policies.get("DefaultSearchProviderEnabled").and_then(Value::as_bool) != Some(false)
        && let Some(search) = search
        && search.contains("{searchTerms}")
        && url_like(&search.replace("{searchTerms}", "q"))
        && is_web_scheme(search)
    {
        settings.insert("browser.searchEngine".into(), json!("custom"));
        settings.insert("browser.customSearchEngine.search".into(), json!(search));
        let suggest = string("DefaultSearchProviderSuggestURL").unwrap_or_default();
        let suggest = if suggest.contains("{searchTerms}") { suggest } else { "" };
        settings.insert("browser.customSearchEngine.suggest".into(), json!(suggest));
    }
    if let Some(page) = policies.get("NewTabPageLocation").and_then(Value::as_str)
        && crate::schema::new_tab_page_url_is_valid(page)
    {
        let trimmed = trim_whitespaces(page);
        let url = if scheme(trimmed).is_some() {
            trimmed.to_string()
        } else {
            format!("https://{trimmed}")
        };
        if is_web_scheme(&url) {
            settings.insert("browser.newTabPage".into(), json!(url));
        }
    }
    if let Some(enabled) = policies.get("PasswordManagerEnabled").and_then(Value::as_bool) {
        settings.insert("browser.passwords.offerToSave".into(), json!(enabled));
        settings.insert("browser.passwords.generate".into(), json!(enabled));
    }
    settings
}

/// The cmux managed values the document stands for: `(forced, recommended)`.
/// `URLBlocklist`, `URLAllowlist` and `ExtensionInstallForcelist` count only
/// when mandatory, and stay policy keys under their Chrome names.
pub fn managed_values(document: &Document) -> (Map<String, Value>, Map<String, Value>) {
    let mut forced = settings(&document.mandatory);
    let recommended = settings(&document.recommended);
    for key in ["URLBlocklist", "URLAllowlist", "ExtensionInstallForcelist"] {
        let Some(items) = document.mandatory.get(key).and_then(Value::as_array) else { continue };
        let strings: Vec<Value> = items
            .iter()
            .filter_map(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(|s| json!(s))
            .collect();
        if !strings.is_empty() {
            forced.insert(key.to_string(), Value::Array(strings));
        }
    }
    (forced, recommended)
}

#[cfg(test)]
#[path = "chrome_tests.rs"]
mod tests;
