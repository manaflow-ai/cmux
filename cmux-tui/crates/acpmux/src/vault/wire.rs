//! The hub's answer to `GET /v1/vault/machine`, read without I/O.
//!
//! Only `env` is read. A `harnessCredentials` list (an older hub shape) is
//! never decoded: the vault never carries a Claude or ChatGPT subscription
//! login. Every value stays in a [`Zeroizing`] buffer, and no `Debug`,
//! error or code here ever holds one.

use base64::Engine as _;
use serde_json::Value;
use std::collections::BTreeMap;
use zeroize::Zeroizing;

/// The machine's vault route on the hub origin.
pub const MACHINE_PATH: &str = "/v1/vault/machine";
/// The query that tells the hub this machine runs the egress proxy: without
/// it a proxy entry is `withheld` (an older machine would put the value in
/// the agent env).
pub const DELIVERY_QUERY: &str = "delivery=proxy.v1";
/// The 403 code of a machine whose person has not granted it the vault.
pub const NOT_GRANTED: &str = "vault.not_granted";
/// Largest value accepted, in bytes (the machine.env reader's limit).
pub const MAX_VALUE_BYTES: usize = 131_072;
/// Most entries one answer may carry.
pub const MAX_ENTRIES: usize = 512;
/// Linux's limit on one `NAME=value` string in a new process's environment,
/// its terminator included (`MAX_ARG_STRLEN`, 32 pages): a longer one fails
/// every spawn with E2BIG.
pub const MAX_ENV_STRING_BYTES: usize = 131_072;
/// Most bytes the vault's `NAME=value` strings may take together: they share
/// the exec argument space (`ARG_MAX`, 1 MiB on macOS) with the agent's own
/// environment and argv. Entries past it (by name) are refused.
pub const MAX_VAULT_ENV_BYTES: usize = 262_144;

/// The bytes `NAME=value` takes in a new process's environment.
pub fn env_string_bytes(name: &str, value: &str) -> usize {
    name.len().saturating_add(value.len()).saturating_add(2)
}

/// One env entry of the answer. `value` is `None` for a revoked entry.
pub struct EnvItem {
    pub name: String,
    pub revision: u64,
    pub value: Option<Zeroizing<String>>,
    /// `Some(allowed hosts)` for `delivery: proxy`: agents get the
    /// placeholder and the egress proxy puts the value only into requests to
    /// these hosts. `None` for `delivery: env` (or a hub that predates
    /// delivery): the value itself goes in the agent env.
    pub proxy: Option<Vec<String>>,
}

impl std::fmt::Debug for EnvItem {
    /// Never the value.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = if self.value.is_some() { "active" } else { "revoked" };
        let delivery = if self.proxy.is_some() { "proxy" } else { "env" };
        write!(f, "EnvItem({} r{} {state} {delivery})", self.name, self.revision)
    }
}

/// What one pull learned.
#[derive(Debug)]
pub enum Answer {
    /// 200: the vault's env entries for this machine. `refused` counts entries
    /// that were malformed or whose names this machine never sets.
    Granted { env: Vec<EnvItem>, refused: usize },
    /// 403 `vault.not_granted`: the person has not shared the vault with this
    /// machine. Not an error for the pull.
    NotGranted,
    /// 401: the machine credential is revoked.
    Revoked,
    /// 404: this hub has no vault yet.
    Off,
    /// A network error, 429 or 5xx: retry with backoff. The code only.
    Retry(String),
    /// Any other answer. The code only.
    Refused(String),
}

/// Reads one answer. `body` is the raw response body.
pub fn parse(status: u16, body: &[u8]) -> Answer {
    let json: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    match status {
        200 => {}
        401 => return Answer::Revoked,
        403 if error_code(&json).as_deref() == Some(NOT_GRANTED) => return Answer::NotGranted,
        404 => return Answer::Off,
        429 | 500..=599 => return Answer::Retry(format!("http.{status}")),
        _ => {
            return Answer::Refused(error_code(&json).unwrap_or_else(|| format!("http.{status}")));
        }
    }
    let Some(items) = json.get("env").and_then(Value::as_array) else {
        return Answer::Refused("vault.malformed".to_owned());
    };
    if items.len() > MAX_ENTRIES {
        return Answer::Refused("vault.too_many".to_owned());
    }
    let mut refused = 0usize;
    let mut by_name: BTreeMap<String, EnvItem> = BTreeMap::new();
    for item in items {
        let Some(entry) = env_item(item) else {
            refused = refused.saturating_add(1);
            continue;
        };
        // One entry per name: the newest revision wins.
        match by_name.get(&entry.name) {
            Some(have) if have.revision >= entry.revision => {}
            _ => {
                by_name.insert(entry.name.clone(), entry);
            }
        }
    }
    // What a spawn can carry: each string under the per-string limit, and
    // all of them within the vault's share of the exec space. A refused
    // entry is not delivered, so a stored older value of it is removed.
    let mut total = 0usize;
    let mut env = Vec::with_capacity(by_name.len());
    for entry in by_name.into_values() {
        if let Some(value) = &entry.value {
            let bytes = env_string_bytes(&entry.name, value);
            if bytes > MAX_ENV_STRING_BYTES || total.saturating_add(bytes) > MAX_VAULT_ENV_BYTES {
                refused = refused.saturating_add(1);
                continue;
            }
            total = total.saturating_add(bytes);
        }
        env.push(entry);
    }
    Answer::Granted { env, refused }
}

fn env_item(item: &Value) -> Option<EnvItem> {
    let name = item.get("name")?.as_str()?;
    let revision = item.get("revision")?.as_u64()?;
    if !crate::login_env::machine_env_name_allowed(name) || super::REFUSED_NAMES.contains(&name) {
        return None;
    }
    // `withheld` (a proxy entry for a machine that did not ask for them) and
    // any other state are not delivered.
    let value = match item.get("state")?.as_str()? {
        "revoked" => None,
        "active" => Some(decode_value(item.get("valueBase64")?.as_str()?)?),
        _ => return None,
    };
    let proxy = match item.get("delivery") {
        None | Some(Value::Null) => None,
        Some(Value::String(d)) if d == "env" => None,
        Some(Value::String(d)) if d == "proxy" => Some(allowed_hosts(item.get("allowedHosts"))),
        Some(_) => return None,
    };
    Some(EnvItem { name: name.to_owned(), revision, value, proxy })
}

/// Most allowed hosts one entry may carry.
pub const MAX_HOSTS: usize = 16;

/// The valid, distinct host patterns of `allowedHosts`, in order (at most
/// [`MAX_HOSTS`]); anything else is dropped, so a malformed host only
/// narrows where the value can go.
fn allowed_hosts(list: Option<&Value>) -> Vec<String> {
    let mut hosts: Vec<String> = Vec::new();
    for host in list.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
        if let Some(pattern) = cmux_vault_egress::HostPattern::parse(host) {
            let text = pattern.to_string();
            if !hosts.contains(&text) && hosts.len() < MAX_HOSTS {
                hosts.push(text);
            }
        }
    }
    hosts
}

/// Base64 (standard, padded or not) of UTF-8 with no NUL, at most
/// [`MAX_VALUE_BYTES`].
fn decode_value(text: &str) -> Option<Zeroizing<String>> {
    if text.len() > MAX_VALUE_BYTES.div_ceil(3).saturating_mul(4).saturating_add(4) {
        return None;
    }
    let engine = base64::engine::general_purpose::GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        base64::engine::GeneralPurposeConfig::new()
            .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent),
    );
    let bytes = Zeroizing::new(engine.decode(text).ok()?);
    if bytes.len() > MAX_VALUE_BYTES || bytes.contains(&0) {
        return None;
    }
    let text = std::str::from_utf8(&bytes).ok()?;
    Some(Zeroizing::new(text.to_owned()))
}

/// `error.code` or `code`, when it is a short code (never free text).
fn error_code(body: &Value) -> Option<String> {
    let code = body
        .get("error")
        .and_then(|e| e.get("code"))
        .and_then(Value::as_str)
        .or_else(|| body.get("code").and_then(Value::as_str))?;
    let short = code.len() <= 64
        && code.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    short.then(|| code.to_owned())
}
