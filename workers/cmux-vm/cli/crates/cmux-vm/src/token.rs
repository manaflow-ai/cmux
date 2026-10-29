//! The stored VM agent token: `cmux-vm token create|status|revoke`.
//!
//! A token is a cmux VM agent key (`POST /v1/agent-keys`, src/api/agents.ts):
//! it holds at most `vm:read`, `vm:write` and `vm:exec`, reaches only the VMs
//! it creates (label `cmux.agent=<its id>`), has a VM count and an estimated
//! USD/h budget, and expires within 24 hours. Revoking it, or its expiry,
//! deletes its VMs. It cannot mint keys, read files, open terminals, change
//! networks, take snapshots or reach anything else of the team.
//!
//! It is minted by a credential that is not itself an agent key: a signed-in
//! person's session (the cmux app does this for `cmux vm token create`) or a
//! team API key with `vm:write`. The secret is stored once, never printed: in
//! the login Keychain on macOS (generic password, service [`SERVICE`]), else in
//! `$XDG_CONFIG_HOME/cmux/vm-token.json` with mode 0600. Every later `cmux vm`
//! call, from any process, reads it from there when `CMUX_VM_API_KEY` is unset
//! (config.rs).

use std::io::Write;

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::CliError;
use crate::{call, fetch_body, request_body};

/// The Keychain service (macOS) the token is stored under.
pub const SERVICE: &str = "com.cmux.vm.agent-token";
#[cfg(target_os = "macos")]
const ACCOUNT: &str = "default";
/// The file the token is stored in where there is no Keychain.
#[cfg(not(target_os = "macos"))]
const FILE_NAME: &str = "vm-token.json";

pub const DEFAULT_TTL_SECONDS: u64 = 8 * 3600;
pub const MAX_TTL_SECONDS: u64 = 24 * 3600;
pub const DEFAULT_MAX_VMS: u32 = 3;
pub const DEFAULT_MAX_USD_PER_HOUR: f64 = 2.0;

/// A stored token. `key` is the secret; nothing prints it.
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoredToken {
    pub key: String,
    pub key_id: String,
    pub expires_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default)]
    pub max_vms: Option<u32>,
    #[serde(default)]
    pub max_usd_per_hour: Option<f64>,
}

impl std::fmt::Debug for StoredToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredToken")
            .field("key", &"<redacted>")
            .field("key_id", &self.key_id)
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

impl StoredToken {
    /// From a `CreatedAgentKey` response body.
    pub fn from_created(
        body: &[u8],
        team_id: Option<String>,
        base_url: Option<String>,
    ) -> Result<Self, CliError> {
        let created: Value = serde_json::from_slice(body)
            .map_err(|_| CliError::unexpected("the agent key response was not JSON"))?;
        let text = |name: &str| created[name].as_str().map(str::to_owned);
        Ok(Self {
            key: text("key")
                .ok_or_else(|| CliError::unexpected("the agent key response had no key"))?,
            key_id: text("id")
                .ok_or_else(|| CliError::unexpected("the agent key response had no id"))?,
            expires_at: text("expiresAt").unwrap_or_default(),
            team_id,
            base_url,
            scopes: created["scopes"]
                .as_array()
                .map(|scopes| {
                    scopes
                        .iter()
                        .filter_map(|s| s.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default(),
            max_vms: created["maxVms"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok()),
            max_usd_per_hour: created["maxUsdPerHour"].as_f64(),
        })
    }

    /// Seconds until it expires (negative once expired); `None` when the
    /// expiry cannot be read.
    pub fn seconds_left(&self, now_unix: i64) -> Option<i64> {
        parse_rfc3339(&self.expires_at).map(|at| at - now_unix)
    }

    /// The public facts, for output: never the key.
    pub fn public(&self) -> Value {
        json!({
            "id": self.key_id,
            "expiresAt": self.expires_at,
            "scopes": self.scopes,
            "maxVms": self.max_vms,
            "maxUsdPerHour": self.max_usd_per_hour,
            "teamId": self.team_id,
            "store": store_name(),
        })
    }
}

pub fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

/// Where tokens are kept on this system, for messages.
pub fn store_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "login Keychain"
    } else {
        "~/.config/cmux/vm-token.json (mode 0600)"
    }
}

/// The stored token, if any. A store that cannot be read is an error, so a
/// broken store never silently falls back to another credential.
pub fn load(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<StoredToken>, String> {
    let Some(text) = platform::read(env)? else {
        return Ok(None);
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|_| "the stored VM token is unreadable; run `cmux vm token revoke`".to_owned())
}

pub fn save(token: &StoredToken, env: &dyn Fn(&str) -> Option<String>) -> Result<(), String> {
    let text = serde_json::to_string(token).map_err(|e| format!("encode the token: {e}"))?;
    platform::write(&text, env)
}

/// Removes the stored token; `Ok(false)` when there was none.
pub fn remove(env: &dyn Fn(&str) -> Option<String>) -> Result<bool, String> {
    platform::delete(env)
}

#[cfg(target_os = "macos")]
mod platform {
    use security_framework::passwords::{
        delete_generic_password, get_generic_password, set_generic_password,
    };

    use super::{ACCOUNT, SERVICE};

    /// errSecItemNotFound.
    const NOT_FOUND: i32 = -25300;

    pub fn read(_env: &dyn Fn(&str) -> Option<String>) -> Result<Option<String>, String> {
        match get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| "the stored VM token is not text".to_owned()),
            Err(error) if error.code() == NOT_FOUND => Ok(None),
            Err(error) => Err(format!(
                "cannot read the VM token from the login Keychain: {error}"
            )),
        }
    }

    pub fn write(text: &str, _env: &dyn Fn(&str) -> Option<String>) -> Result<(), String> {
        set_generic_password(SERVICE, ACCOUNT, text.as_bytes())
            .map_err(|error| format!("cannot store the VM token in the login Keychain: {error}"))
    }

    pub fn delete(_env: &dyn Fn(&str) -> Option<String>) -> Result<bool, String> {
        match delete_generic_password(SERVICE, ACCOUNT) {
            Ok(()) => Ok(true),
            Err(error) if error.code() == NOT_FOUND => Ok(false),
            Err(error) => Err(format!(
                "cannot remove the VM token from the login Keychain: {error}"
            )),
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use std::path::PathBuf;

    use super::FILE_NAME;

    fn path(env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
        let base = env("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                env("HOME")
                    .filter(|v| !v.is_empty())
                    .map(|home| PathBuf::from(home).join(".config"))
            })?;
        Some(base.join("cmux").join(FILE_NAME))
    }

    pub fn read(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<String>, String> {
        let Some(path) = path(env) else {
            return Ok(None);
        };
        let meta = match std::fs::metadata(&path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if meta.permissions().mode() & 0o077 != 0 {
                return Err(format!(
                    "{} is readable by other users; refusing it (chmod 600 it or revoke the token)",
                    path.display()
                ));
            }
        }
        #[cfg(not(unix))]
        let _ = meta;
        std::fs::read_to_string(&path)
            .map(Some)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))
    }

    pub fn write(text: &str, env: &dyn Fn(&str) -> Option<String>) -> Result<(), String> {
        let path = path(env).ok_or("no HOME or XDG_CONFIG_HOME to store the VM token in")?;
        let dir = path.parent().ok_or("no directory for the VM token")?;
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        let temp = dir.join(format!(".{FILE_NAME}.{}", std::process::id()));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp)
            .map_err(|e| format!("cannot write {}: {e}", temp.display()))?;
        let written =
            std::io::Write::write_all(&mut file, text.as_bytes()).and_then(|()| file.sync_all());
        drop(file);
        if let Err(e) = written.and_then(|()| std::fs::rename(&temp, &path)) {
            let _ = std::fs::remove_file(&temp);
            return Err(format!("cannot write {}: {e}", path.display()));
        }
        Ok(())
    }

    pub fn delete(env: &dyn Fn(&str) -> Option<String>) -> Result<bool, String> {
        let Some(path) = path(env) else {
            return Ok(false);
        };
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(format!("cannot remove {}: {e}", path.display())),
        }
    }
}

#[derive(Subcommand, Debug)]
pub enum TokenCommand {
    /// Mint a VM-only agent token with this credential and store it (never printed)
    Create(TokenCreateArgs),
    /// Show the stored token's id, scopes, budget and expiry (never the secret)
    Status,
    /// Revoke the stored token (its VMs are deleted) and remove it
    Revoke,
}

#[derive(Args, Debug)]
pub struct TokenCreateArgs {
    /// Name shown in the team's key list and audit log
    #[arg(long, default_value = "cmux vm token")]
    pub name: String,
    /// Lifetime: seconds, or a number with s, m, h or d (at most 24h) [default: 8h]
    #[arg(long, value_name = "DURATION")]
    pub ttl: Option<String>,
    /// Most VMs the token may have at once (1-20)
    #[arg(long, default_value_t = DEFAULT_MAX_VMS, value_parser = clap::value_parser!(u32).range(1..=20))]
    pub max_vms: u32,
    /// Estimated USD per hour its VMs may cost together (at most 50)
    #[arg(long, default_value_t = DEFAULT_MAX_USD_PER_HOUR)]
    pub max_usd_per_hour: f64,
}

/// `5h`, `30m`, `90s`, `1d` or plain seconds.
pub fn parse_ttl(text: &str) -> Result<u64, CliError> {
    let text = text.trim();
    let (number, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((at, _)) => text.split_at(at),
        None => (text, "s"),
    };
    let value: u64 = number
        .parse()
        .map_err(|_| CliError::usage(format!("invalid --ttl {text:?}")))?;
    let seconds = match unit {
        "s" => value,
        "m" => value * 60,
        "h" => value * 3600,
        "d" => value * 86_400,
        _ => {
            return Err(CliError::usage(format!(
                "invalid --ttl {text:?}: use s, m, h or d"
            )));
        }
    };
    if !(60..=MAX_TTL_SECONDS).contains(&seconds) {
        return Err(CliError::usage("--ttl must be between 1m and 24h"));
    }
    Ok(seconds)
}

/// The agent-key request body for `create`.
pub fn create_body(args: &TokenCreateArgs) -> Result<Value, CliError> {
    let ttl = args
        .ttl
        .as_deref()
        .map(parse_ttl)
        .transpose()?
        .unwrap_or(DEFAULT_TTL_SECONDS);
    if !(args.max_usd_per_hour > 0.0 && args.max_usd_per_hour <= 50.0) {
        return Err(CliError::usage(
            "--max-usd-per-hour must be above 0 and at most 50",
        ));
    }
    Ok(json!({
        "name": args.name,
        "scopes": ["vm:read", "vm:write", "vm:exec"],
        "ttlSeconds": ttl,
        "maxVms": args.max_vms,
        "maxUsdPerHour": args.max_usd_per_hour,
    }))
}

/// `token create`: mint with `client` (which must not hold an agent key) and store.
pub async fn create(
    client: &Client,
    args: &TokenCreateArgs,
    team_id: Option<String>,
    base_url: Option<String>,
    env: &dyn Fn(&str) -> Option<String>,
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    let body: types::CreateAgentKeyRequest = request_body(create_body(args)?)?;
    let created = fetch_body(client.agents_create_agent_key(None, &body)).await?;
    let token = StoredToken::from_created(&created, team_id, base_url)?;
    store_and_report(&token, env, json_output, out)
}

/// Stores a freshly minted token, replacing any earlier one, and prints its
/// public facts. Shared with the cmux CLI, whose app mints the key.
pub fn store_and_report(
    token: &StoredToken,
    env: &dyn Fn(&str) -> Option<String>,
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    save(token, env).map_err(CliError::unexpected)?;
    report(token, "stored", json_output, out)
}

pub fn report(
    token: &StoredToken,
    verb: &str,
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    let text = if json_output {
        serde_json::to_string_pretty(&token.public()).unwrap_or_default()
    } else {
        let budget = match (token.max_vms, token.max_usd_per_hour) {
            (Some(vms), Some(usd)) => format!("at most {vms} VMs and ${usd}/h"),
            _ => "the team's limits".to_owned(),
        };
        format!(
            "token {} {verb} in the {}\nscopes    {}\nbudget    {budget}\nexpires   {}\nAny process of this user can now run `cmux vm run`; `cmux vm token revoke` ends it and deletes its VMs.",
            token.key_id,
            store_name(),
            token.scopes.join(","),
            token.expires_at,
        )
    };
    writeln!(out, "{text}").map_err(|e| CliError::unexpected(format!("write output: {e}")))
}

/// `token revoke`: the token revokes itself (the service then deletes its VMs).
pub async fn revoke(
    client: &Client,
    token: &StoredToken,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    match call(client.agents_revoke_agent_key(&token.key_id, None)).await {
        Ok(_) => {}
        // Already gone (expired, revoked elsewhere): only the local copy is left.
        Err(error) if matches!(error.status(), Some(401 | 404)) => {}
        Err(error) => return Err(error),
    }
    remove(env).map_err(CliError::unexpected)?;
    writeln!(out, "token {} revoked and removed", token.key_id)
        .map_err(|e| CliError::unexpected(format!("write output: {e}")))
}

/// Seconds since the Unix epoch for `YYYY-MM-DDTHH:MM:SS[.fff]Z`.
pub fn parse_rfc3339(text: &str) -> Option<i64> {
    let text = text.strip_suffix('Z')?;
    let (date, time) = text.split_once('T')?;
    let mut date = date.split('-').map(|part| part.parse::<i64>().ok());
    let (year, month, day) = (date.next()??, date.next()??, date.next()??);
    let time = time.split('.').next()?;
    let mut time = time.split(':').map(|part| part.parse::<i64>().ok());
    let (hour, minute, second) = (time.next()??, time.next()??, time.next()??);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Days from civil (Howard Hinnant).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttl_accepts_units_within_a_day() {
        assert_eq!(parse_ttl("8h").unwrap(), 8 * 3600);
        assert_eq!(parse_ttl("30m").unwrap(), 1800);
        assert_eq!(parse_ttl("90").unwrap(), 90);
        assert_eq!(parse_ttl("1d").unwrap(), 86_400);
        assert!(parse_ttl("25h").is_err());
        assert!(parse_ttl("10s").is_err());
        assert!(parse_ttl("1w").is_err());
    }

    #[test]
    fn the_request_holds_only_vm_scopes() {
        let args = TokenCreateArgs {
            name: "t".into(),
            ttl: None,
            max_vms: 3,
            max_usd_per_hour: 2.0,
        };
        let body = create_body(&args).unwrap();
        assert_eq!(body["scopes"], json!(["vm:read", "vm:write", "vm:exec"]));
        assert_eq!(body["ttlSeconds"], json!(DEFAULT_TTL_SECONDS));
    }

    #[test]
    fn public_facts_and_debug_never_show_the_key() {
        let created = br#"{"id":"vmk_0123456789abcdefghjkmnpqrs","name":"t","key":"cmuxvm_sk_SECRETSECRET","scopes":["vm:read"],"labels":{},"createdAt":"2026-10-29T00:00:00.000Z","expiresAt":"2026-10-29T08:00:00.000Z","maxVms":3,"maxUsdPerHour":2}"#;
        let token = StoredToken::from_created(created, Some("team".into()), None).unwrap();
        assert_eq!(token.key, "cmuxvm_sk_SECRETSECRET");
        assert!(!token.public().to_string().contains("SECRET"));
        assert!(!format!("{token:?}").contains("SECRET"));
        let mut out = Vec::new();
        report(&token, "stored", false, &mut out).unwrap();
        report(&token, "stored", true, &mut out).unwrap();
        assert!(!String::from_utf8(out).unwrap().contains("SECRET"));
    }

    #[test]
    fn rfc3339_parses_to_unix_seconds() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339("2026-10-29T08:00:00.000Z"),
            Some(1_793_260_800)
        );
        assert_eq!(parse_rfc3339("2026-10-29 08:00:00"), None);
    }
}
