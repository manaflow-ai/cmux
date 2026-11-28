//! `models.*`: the rules of Settings > Models (Swift `SettingsModels`,
//! cmux-tui/docs/model-connections.md) that need no daemon: which acpmux
//! connections the page draws and how, and what a pasted key or token is.
//! The Swift side keeps the daemon calls, the Keychain and the tasks.
//! - `models.connections` `{connections}` answers `{connections}`: each
//!   acpmux `Connection` as the page's `ModelConnection` (camelCase); one
//!   with no id or an unknown kind is left out.
//! - `models.secret` `{secret, provider?}` answers `{clean, oneWord, apiKey,
//!   claudeToken, kind, providerKnown}`: `clean` is the secret with every
//!   space, line break and invisible space taken out; the checks read
//!   `clean`, except `kind`, which reads the secret as given.

use serde_json::{Map, Value, json};

use super::{OpError, string};

/// acpmux's connection kinds the page draws.
pub const KINDS: &[&str] = &[
    "codex-login",
    "claude-login",
    "subscription",
    "native-login",
    "chatgpt-plan",
    "claude-token",
    "grok-plan",
    "copilot-plan",
    "kimi-plan",
    "api-key",
    "endpoint",
];

/// The API-key providers the page offers.
pub const PROVIDERS: &[&str] =
    &["openai", "anthropic", "openrouter", "google", "vertex-express", "xai"];

/// The longest key or token, in UTF-8 bytes.
pub const KEY_LIMIT: usize = 16_384;

/// A Claude setup token's prefix (`claude setup-token`).
pub const CLAUDE_TOKEN_PREFIX: &str = "sk-ant-oat";

/// Zero-width space, non-joiner, joiner, word joiner and BOM: not whitespace
/// to Unicode, but a paste adds them.
const INVISIBLE_SPACES: &[char] = &['\u{200B}', '\u{200C}', '\u{200D}', '\u{2060}', '\u{FEFF}'];

/// Runs a `models.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "models.connections" => {
            let items = request.get("connections").and_then(Value::as_array);
            let rows: Vec<Value> = items.into_iter().flatten().filter_map(connection).collect();
            Ok(json!({ "connections": rows }))
        }
        "models.secret" => string(request, "secret").map(|secret| {
            let provider = request.get("provider").and_then(Value::as_str);
            secret_facts(secret, provider)
        }),
        _ => return None,
    })
}

/// What a pasted secret is (`models.secret`).
pub fn secret_facts(secret: &str, provider: Option<&str>) -> Value {
    let clean = without_whitespace(secret);
    json!({
        "clean": clean,
        "oneWord": is_one_word(&clean),
        "apiKey": is_model_api_key(&clean),
        "claudeToken": is_claude_token(&clean),
        "kind": kind_of(secret),
        "providerKnown": provider.is_some_and(|p| PROVIDERS.contains(&p)),
    })
}

/// `secret` with every Unicode whitespace character and invisible space
/// taken out. A key or setup token never holds whitespace, so a pasted one
/// loses only what the copy added.
pub fn without_whitespace(secret: &str) -> String {
    secret.chars().filter(|c| !c.is_whitespace() && !INVISIBLE_SPACES.contains(c)).collect()
}

/// One line of printable ASCII with no spaces, as a key or token is; the
/// Keychain line must not break.
pub fn is_one_word(secret: &str) -> bool {
    !secret.is_empty()
        && secret.len() <= KEY_LIMIT
        && secret.chars().all(|c| ('\u{21}'..='\u{7E}').contains(&c))
}

/// A one-word secret that is not a Claude setup token.
pub fn is_model_api_key(key: &str) -> bool {
    is_one_word(key) && !key.starts_with(CLAUDE_TOKEN_PREFIX)
}

/// Whether `token` reads as a Claude setup token: `sk-ant-oat`, two digits,
/// a dash, then base64url (letters, digits, `-`, `_`), as webviews'
/// `claudeSetupToken.ts` checks it.
pub fn is_claude_token(token: &str) -> bool {
    let Some(rest) = token.strip_prefix(CLAUDE_TOKEN_PREFIX) else { return false };
    if token.len() > KEY_LIMIT {
        return false;
    }
    let rest = rest.as_bytes();
    rest.len() > 3
        && rest[0].is_ascii_digit()
        && rest[1].is_ascii_digit()
        && rest[2] == b'-'
        && rest[3..].iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
}

/// A Claude setup token or a sign-in file is a subscription (`oauth`);
/// anything else an API key (`api_key`).
pub fn kind_of(key: &str) -> &'static str {
    if key.starts_with(CLAUDE_TOKEN_PREFIX) || key.starts_with('{') { "oauth" } else { "api_key" }
}

/// One acpmux `Connection` as the page's `ModelConnection`. `servesCloud`:
/// whether it can serve a Cloud chat (Revision 2: the Mac CLI logins do not).
pub fn connection(value: &Value) -> Option<Value> {
    let id = value.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())?;
    let kind = value.get("kind").and_then(Value::as_str).filter(|kind| KINDS.contains(kind))?;
    let text = |key: &str| value.get(key).and_then(Value::as_str).map_or(Value::Null, |s| json!(s));
    let flag = |key: &str| value.get(key).and_then(Value::as_bool);
    let strings = |key: &str, camel: &str| {
        let items = value
            .get(key)
            .and_then(Value::as_array)
            .or_else(|| value.get(camel).and_then(Value::as_array));
        Value::Array(items.into_iter().flatten().filter(|item| item.is_string()).cloned().collect())
    };
    let provider = value
        .get("provider")
        .and_then(Value::as_str)
        .filter(|provider| {
            matches!(kind, "endpoint" | "grok-plan" | "copilot-plan" | "kimi-plan")
                || PROVIDERS.contains(provider)
                || (kind == "native-login" && matches!(*provider, "gemini" | "grok" | "cursor"))
        })
        .unwrap_or(if matches!(kind, "claude-login" | "claude-token") {
            "anthropic"
        } else {
            "openai"
        });
    let serves_cloud = flag("serves_cloud").or_else(|| flag("servesCloud")).unwrap_or(false);
    let mut row = Map::new();
    row.insert("id".into(), json!(id));
    row.insert("kind".into(), json!(kind));
    row.insert("provider".into(), json!(provider));
    row.insert("credentialInstance".into(), text("credential_instance"));
    row.insert("keyRevision".into(), text("key_revision"));
    row.insert("families".into(), strings("families", "families"));
    row.insert("label".into(), json!(value.get("label").and_then(Value::as_str).unwrap_or(id)));
    row.insert("email".into(), text("email"));
    row.insert("plan".into(), text("plan"));
    row.insert(
        "signedIn".into(),
        json!(flag("signed_in").or_else(|| flag("signedIn")).unwrap_or(false)),
    );
    row.insert("signInReason".into(), text("sign_in_reason"));
    row.insert("enabled".into(), json!(flag("enabled").unwrap_or(false)));
    row.insert("defaultFor".into(), strings("default_for", "defaultFor"));
    row.insert("servesCloud".into(), json!(serves_cloud));
    row.insert("canServeCloud".into(), json!(flag("can_serve_cloud").unwrap_or(serves_cloud)));
    let cloud_families =
        value.get("cloud_families").cloned().unwrap_or_else(|| strings("families", "families"));
    row.insert("cloudFamilies".into(), cloud_families);
    row.insert("canCheckAccess".into(), json!(flag("can_check_access").unwrap_or(false)));
    row.insert("canReplaceKey".into(), json!(flag("can_replace_key").unwrap_or(false)));
    row.insert("endpoint".into(), value.get("endpoint").cloned().unwrap_or(Value::Null));
    row.insert("launchHarness".into(), text("launch_harness"));
    row.insert("expiresAt".into(), value.get("expires_at").cloned().unwrap_or(Value::Null));
    Some(Value::Object(row))
}

#[cfg(test)]
#[path = "models_tests.rs"]
mod tests;
