//! A browser profile's own proxy (#24432): the record's network identity.
//! `{scheme, host, port, bypass?}` with scheme `http`, `https` or `socks5`.
//! The record never holds a secret: a username or password (as a field or
//! as `user:pass@` in the host) is refused, so credentials never reach the
//! records, `list-personal`, exports, CLI output or logs. An upstream that
//! needs them goes behind a local relay (`127.0.0.1:PORT`) the profile
//! points at.

use serde_json::{Map, Value, json};

/// The schemes both engines speak.
pub const PROXY_SCHEMES: [&str; 3] = ["http", "https", "socks5"];

/// The refusal for a proxy with credentials. It never repeats the value.
pub const CREDENTIALS_REFUSED: &str = "bad request: a browser profile proxy stores no \
     credentials; run a local relay that adds them (127.0.0.1:PORT) and point the profile at it";

const MAX_BYPASS: usize = 64;

/// The stored form of `value`, or why it is refused.
pub fn validate_browser_profile_proxy(value: &Value) -> anyhow::Result<Value> {
    let object = value.as_object().ok_or_else(|| {
        anyhow::anyhow!("bad request: proxy must be an object {{scheme, host, port, bypass?}}")
    })?;
    for key in object.keys() {
        match key.as_str() {
            "scheme" | "host" | "port" | "bypass" => {}
            "username" | "user" | "password" | "pass" | "credentials" | "auth" => {
                anyhow::bail!(CREDENTIALS_REFUSED)
            }
            other => anyhow::bail!("bad request: proxy has an unknown field {other}"),
        }
    }
    let scheme = object.get("scheme").and_then(Value::as_str).unwrap_or_default();
    anyhow::ensure!(
        PROXY_SCHEMES.contains(&scheme),
        "bad request: proxy scheme must be http, https or socks5"
    );
    let host = object.get("host").and_then(Value::as_str).unwrap_or_default();
    anyhow::ensure!(!host.contains('@'), CREDENTIALS_REFUSED);
    anyhow::ensure!(valid_host(host), "bad request: proxy host must be a host name or IP address");
    let port = object.get("port").and_then(Value::as_u64).unwrap_or(0);
    anyhow::ensure!((1..=65_535).contains(&port), "bad request: proxy port must be 1-65535");
    let mut stored = Map::new();
    stored.insert("scheme".into(), json!(scheme));
    stored.insert("host".into(), json!(host));
    stored.insert("port".into(), json!(port));
    if let Some(bypass) = object.get("bypass") {
        let rules = bypass
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("bad request: proxy bypass must be a list of hosts"))?;
        anyhow::ensure!(
            rules.len() <= MAX_BYPASS,
            "bad request: at most {MAX_BYPASS} bypass rules"
        );
        let rules = rules
            .iter()
            .map(|rule| {
                rule.as_str().filter(|rule| valid_rule(rule)).map(str::to_owned).ok_or_else(|| {
                    anyhow::anyhow!("bad request: a proxy bypass rule must be a host pattern")
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        if !rules.is_empty() {
            stored.insert("bypass".into(), json!(rules));
        }
    }
    Ok(Value::Object(stored))
}

/// A host name, an IPv4 address or a bare IPv6 address: no space,
/// separator, scheme or path, at most 253 bytes.
fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ':'))
        && (host.starts_with("::") || !host.starts_with(['.', '-', ':']))
}

/// A Chromium bypass rule: a host pattern (`*.corp.test`, `10.0.0.0/8`, `<local>`).
fn valid_rule(rule: &str) -> bool {
    !rule.is_empty()
        && rule.len() <= 253
        && rule.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '.' | '-' | '_' | ':' | '*' | '/' | '<' | '>' | '[' | ']')
        })
}
