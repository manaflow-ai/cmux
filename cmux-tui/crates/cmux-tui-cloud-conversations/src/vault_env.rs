//! `vault-env`: the person's own vault (cmux-platform `/v1/vault/env` and `/v1/vault/grants`)
//! for Settings › Environment, through the same Cloud transport and install token as
//! `cloud-environment` (RFD 0222 (c)1, hq#37585). The CLI's twin is `cmux machine vault`.
//!
//! Only these named routes are exposed; the page supplies neither a URL nor headers. A reply
//! carries names, revisions, times, delivery policy and grants, never a value or a fingerprint.
//! `set` takes its value on the request; this module base64s and fingerprints it here and wipes
//! every copy once the request is sent.

use base64::Engine as _;
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};
use zeroize::Zeroize as _;

use super::{CloudConversations, CloudError};

/// The largest value, in bytes (cmux-platform `MAX_ENV_VALUE_BYTES`).
const MAX_VALUE_BYTES: usize = 16_384;
/// At most this many allowed hosts per entry (cmux-platform `MAX_ALLOWED_HOSTS`).
const MAX_HOSTS: usize = 16;
const ENV_PATH: &str = "/v1/vault/env";
const GRANTS_PATH: &str = "/v1/vault/grants";

fn invalid() -> CloudError {
    rejected("vault.invalid", "Invalid vault request. Check the fields.")
}

fn rejected(code: &str, message: &str) -> CloudError {
    CloudError::Rejected { code: code.into(), message: message.into(), retryable: false }
}

/// Zeroes every string in `value` (a request that carried a secret's value).
pub fn wipe(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(items) => items.iter_mut().for_each(wipe),
        Value::Object(fields) => fields.values_mut().for_each(wipe),
        _ => {}
    }
}

/// Claude's and Codex's API keys: reserved for repo files, but the vault takes them (proxy only).
const MODEL_KEYS: [&str; 3] = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY"];

// The machine's own names (cmux-platform `RESERVED_ENV_NAMES`, cli/cloud_secret.rs `valid_name`).
#[rustfmt::skip]
const RESERVED: &[&str] = &[
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PWD", "OLDPWD", "TERM",
    "BASH", "BASHOPTS", "BASHPID", "CDPATH", "COLUMNS", "DIRSTACK", "EPOCHREALTIME", "EPOCHSECONDS", "EUID", "EXECIGNORE",
    "FCEDIT", "FIGNORE", "FUNCNAME", "FUNCNEST", "GLOBIGNORE", "GROUPS", "HOSTFILE", "HOSTNAME", "HOSTTYPE", "IGNOREEOF",
    "INPUTRC", "LINENO", "LINES", "MACHTYPE", "MAIL", "MAILCHECK", "MAILPATH", "OPTARG", "OPTERR", "OPTIND", "OSTYPE",
    "PIPESTATUS", "POSIXLY_CORRECT", "PPID", "RANDOM", "REPLY", "SECONDS", "SHELLOPTS", "SHLVL", "SRANDOM", "TIMEFORMAT",
    "TMOUT", "TMPDIR", "UID", "_", "PS0", "PS1", "PS2", "PS3", "PS4", "HISTCMD", "HISTCONTROL", "HISTFILE", "HISTFILESIZE",
    "HISTIGNORE", "HISTSIZE", "HISTTIMEFORMAT", "LANG", "LANGUAGE", "TZ", "TZDIR", "NLSPATH",
    "ZDOTDIR", "FPATH", "MODULE_PATH", "PROMPT", "PROMPT2", "PROMPT3", "PROMPT4", "RPROMPT", "RPROMPT2", "RPS1",
    "RPS2", "NULLCMD", "READNULLCMD", "HISTCHARS", "WATCHFMT", "PERIOD", "KEYTIMEOUT", "SAVEHIST", "STTY",
    "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "PYTHONSAFEPATH",
    "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL",
    "GOOGLE_GEMINI_BASE_URL", "GROK_MODELS_BASE_URL", "GROK_MODELS_LIST_URL", "GROK_XAI_API_BASE_URL",
];
const RESERVED_PREFIXES: &[&str] =
    &["LD_", "DYLD_", "CMUX_", "BASH_", "COMP_", "PROMPT_", "READLINE_", "COPROC", "LC_", "ZSH_"];

/// Whether the vault stores `name` (cmux-platform `validEnvName`).
pub fn name_ok(name: &str) -> bool {
    let shaped = (1..=128).contains(&name.len())
        && name.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    if !shaped {
        return false;
    }
    if MODEL_KEYS.contains(&name) {
        return true;
    }
    let upper = name.to_ascii_uppercase();
    !RESERVED.contains(&upper.as_str()) && !RESERVED_PREFIXES.iter().any(|p| upper.starts_with(p))
}

/// A name that reads as a key (cmux-platform Secrets.ts `keyShapedName`): its value must not be
/// a plain variable every agent can read, so `env` delivery is refused for it.
pub fn key_shaped(name: &str) -> bool {
    const SUFFIXES: [&str; 9] = [
        "API_KEY",
        "APIKEY",
        "TOKEN",
        "SECRET",
        "SECRET_KEY",
        "ACCESS_KEY",
        "PRIVATE_KEY",
        "PASSWORD",
        "PASSWD",
    ];
    let upper = name.to_ascii_uppercase();
    SUFFIXES.iter().any(|suffix| {
        upper.strip_suffix(suffix).is_some_and(|rest| rest.is_empty() || rest.ends_with('_'))
    })
}

/// A lowercase DNS name, optionally `*.` and `:port` (cmux-platform `ALLOWED_HOST`, the CLI's
/// `policy::host_ok`).
fn host_ok(host: &str) -> bool {
    let label = |l: &str| {
        (1..=63).contains(&l.len())
            && l.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    };
    let (name, port) = match host.split_once(':') {
        Some((name, port)) => (name, Some(port)),
        None => (host, None),
    };
    if let Some(port) = port
        && !((1..=5).contains(&port.len())
            && !port.starts_with('0')
            && port.parse::<u32>().is_ok_and(|p| p <= 65535))
    {
        return false;
    }
    let name = name.strip_prefix("*.").unwrap_or(name);
    let Some((labels, last)) = name.rsplit_once('.') else { return false };
    host.len() <= 260
        && labels.split('.').all(|l| label(l) && !l.starts_with('-') && !l.ends_with('-'))
        && last.starts_with(|c: char| c.is_ascii_lowercase())
        && label(last)
}

fn checked_name(params: &Map<String, Value>) -> Result<&str, CloudError> {
    let name = params.get("name").and_then(Value::as_str).ok_or_else(invalid)?;
    if !name_ok(name) {
        return Err(rejected(
            "vault.invalid_name",
            "Not an env var name: [A-Za-z_][A-Za-z0-9_]*, and not PATH, HOME, LD_*, CMUX_* or another the machine owns.",
        ));
    }
    Ok(name)
}

/// The request's `{delivery?, allowedHosts?}`, checked, as the platform takes them; `None` when
/// it names neither.
fn policy(params: &Map<String, Value>, name: &str) -> Result<Option<Map<String, Value>>, CloudError> {
    let mut out = Map::new();
    match params.get("delivery") {
        None => {}
        Some(Value::String(d)) if d == "proxy" || d == "env" => {
            if d == "env" && key_shaped(name) {
                return Err(rejected(
                    "vault.key_shaped_variable",
                    "This name looks like a key, so it can't be a plain variable: make it a secret sent to the host it is for.",
                ));
            }
            if d == "env" && MODEL_KEYS.contains(&name) {
                return Err(rejected(
                    "vault.model_key_proxy_only",
                    "A Claude or Codex API key reaches machines only as a secret for its hosts.",
                ));
            }
            out.insert("delivery".into(), d.clone().into());
        }
        Some(_) => return Err(invalid()),
    }
    if let Some(hosts) = params.get("allowedHosts") {
        let hosts = hosts.as_array().ok_or_else(invalid)?;
        if hosts.len() > MAX_HOSTS || !hosts.iter().all(|h| h.as_str().is_some_and(host_ok)) {
            return Err(rejected(
                "vault.invalid_hosts",
                "Give hosts as DNS names like api.github.com or *.example.com, at most 16.",
            ));
        }
        out.insert("allowedHosts".into(), Value::Array(hosts.clone()));
    }
    Ok((!out.is_empty()).then_some(out))
}

fn only(params: &Map<String, Value>, allowed: &[&str]) -> Result<(), CloudError> {
    if params.keys().all(|key| allowed.contains(&key.as_str())) { Ok(()) } else { Err(invalid()) }
}

impl CloudConversations {
    pub fn vault_env(
        &self,
        action: &str,
        parameters: &Value,
        origin: &str,
        access_token: &str,
    ) -> Result<Value, CloudError> {
        let base = url::Url::parse(origin).map_err(|_| invalid())?;
        if !super::platform::accepts_environment_origin(&base)
            || access_token.is_empty()
            || access_token.len() > 8192
        {
            return Err(invalid());
        }
        let send = |method: &str, path: &str, body: &Value| {
            self.backend()
                .platform(
                    method,
                    &format!("{}{path}", origin.trim_end_matches('/')),
                    access_token,
                    body,
                )
                .map_err(|_| CloudError::Unavailable("Your vault could not be reached.".into()))
        };
        let params = parameters.as_object().ok_or_else(invalid)?;
        let reply = match action {
            "list" if params.is_empty() => send("GET", ENV_PATH, &Value::Null)?,
            "grants" if params.is_empty() => send("GET", GRANTS_PATH, &Value::Null)?,
            "set" => {
                only(params, &["name", "value", "delivery", "allowedHosts"])?;
                let name = checked_name(params)?;
                let policy = policy(params, name)?;
                let value = params.get("value").and_then(Value::as_str).ok_or_else(invalid)?;
                if value.is_empty() || value.len() > MAX_VALUE_BYTES || value.contains('\0') {
                    return Err(rejected(
                        "vault.invalid_value",
                        "The value must be 1 to 16384 bytes with no NUL byte.",
                    ));
                }
                let mut fingerprint = String::with_capacity(64);
                for byte in Sha256::digest(value.as_bytes()) {
                    fingerprint.push_str(&format!("{byte:02x}"));
                }
                let mut body = json!({
                    "valueBase64": base64::engine::general_purpose::STANDARD.encode(value.as_bytes()),
                    "fingerprint": fingerprint,
                });
                fingerprint.zeroize();
                if let (Some(policy), Some(fields)) = (policy, body.as_object_mut()) {
                    fields.extend(policy);
                }
                let sent = send("PUT", &format!("{ENV_PATH}/{name}"), &body);
                wipe(&mut body);
                sent?
            }
            "policy" => {
                only(params, &["name", "delivery", "allowedHosts"])?;
                let name = checked_name(params)?;
                let policy = policy(params, name)?.ok_or_else(invalid)?;
                send("PUT", &format!("{ENV_PATH}/{name}/policy"), &Value::Object(policy))?
            }
            "rm" => {
                only(params, &["name"])?;
                // A name the vault holds but no longer delivers (a base URL) can still be removed.
                let name = params.get("name").and_then(Value::as_str).ok_or_else(invalid)?;
                if !(name_ok(name)
                    || ["OPENAI_BASE_URL", "ANTHROPIC_BASE_URL"]
                        .iter()
                        .any(|n| n.eq_ignore_ascii_case(name)))
                {
                    return Err(invalid());
                }
                send("DELETE", &format!("{ENV_PATH}/{name}"), &Value::Null)?
            }
            _ => return Err(invalid()),
        };
        super::environments::refused(&reply)?;
        Ok(match action {
            "list" => json!({ "entries": entries(&reply.body) }),
            "grants" => json!({ "grants": grants(&reply.body) }),
            _ => written(&reply.body),
        })
    }
}

fn string_list(value: Option<&Value>, ok: impl Fn(&str) -> bool) -> Vec<Value> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items.iter().filter_map(Value::as_str).filter(|s| ok(s)).map(Value::from).collect()
        })
        .unwrap_or_default()
}

/// `{name, revision, updatedAt, delivery, allowedHosts}` of each listed entry; any other field
/// (a value, a fingerprint) is dropped.
fn entries(body: &Value) -> Vec<Value> {
    let Some(rows) = body.get("entries").and_then(Value::as_array) else { return Vec::new() };
    rows.iter()
        .filter_map(|row| {
            let name = row.get("name")?.as_str()?;
            (name.len() <= 128 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
                .then_some(())?;
            Some(json!({
                "name": name,
                "revision": row.get("revision").and_then(Value::as_u64),
                "updatedAt": row.get("updatedAt").and_then(Value::as_i64),
                // A hub that sends no delivery predates the egress proxy: env.
                "delivery": match row.get("delivery").and_then(Value::as_str) {
                    Some("proxy") => "proxy",
                    _ => "env",
                },
                "allowedHosts": string_list(row.get("allowedHosts"), host_ok),
                "keyShaped": key_shaped(name),
            }))
        })
        .collect()
}

/// `{kind, id, entries?, expiresAt, grantedAt}` of each grant.
fn grants(body: &Value) -> Vec<Value> {
    let Some(rows) = body.get("grants").and_then(Value::as_array) else { return Vec::new() };
    rows.iter()
        .filter_map(|row| {
            let kind = row.get("kind")?.as_str().filter(|k| *k == "joined" || *k == "cloud")?;
            let id = row.get("id")?.as_str().filter(|id| (1..=256).contains(&id.len()))?;
            let mut grant = json!({
                "kind": kind,
                "id": id,
                "expiresAt": row.get("expiresAt").and_then(Value::as_i64).unwrap_or(0),
                "grantedAt": row.get("grantedAt").and_then(Value::as_i64),
            });
            if row.get("entries").is_some_and(Value::is_array)
                && let Some(fields) = grant.as_object_mut()
            {
                fields.insert("entries".into(), string_list(row.get("entries"), name_ok).into());
            }
            Some(grant)
        })
        .collect()
}

/// A write, policy or removal answer: `{name, revision, delivery?, allowedHosts?, warning?}`.
fn written(body: &Value) -> Value {
    let mut out = Map::new();
    for key in ["name", "warning", "delivery"] {
        if let Some(text) = body.get(key).and_then(Value::as_str) {
            out.insert(key.into(), text.chars().take(1024).collect::<String>().into());
        }
    }
    if let Some(revision) = body.get("revision").and_then(Value::as_u64) {
        out.insert("revision".into(), revision.into());
    }
    if body.get("allowedHosts").is_some() {
        out.insert("allowedHosts".into(), string_list(body.get("allowedHosts"), host_ok).into());
    }
    Value::Object(out)
}

#[cfg(test)]
#[path = "vault_env_tests.rs"]
mod tests;
