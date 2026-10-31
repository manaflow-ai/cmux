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
            expires_at: text("expiresAt")
                .filter(|at| parse_rfc3339(at).is_some())
                .ok_or_else(|| {
                    CliError::unexpected("the agent key response had no readable expiry")
                })?,
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

    /// For `token status`: how it reads and the exit code. As in resolution
    /// (config.rs), a token without a readable expiry is refused like an
    /// expired one.
    pub fn status(&self, now_unix: i64) -> (&'static str, i32) {
        match self.seconds_left(now_unix) {
            Some(left) if left > 0 => ("is", crate::exit::OK),
            Some(_) => ("expired", crate::exit::UNAUTHENTICATED),
            None => (
                "is refused (no readable expiry)",
                crate::exit::UNAUTHENTICATED,
            ),
        }
    }

    /// The service this key was minted at: the only one it is ever sent to.
    pub fn issuer(&self) -> String {
        self.base_url
            .clone()
            .unwrap_or_else(|| cmux_vm_client::DEFAULT_BASE_URL.to_owned())
    }

    /// The issuer, refusing a base URL from a flag or the environment that
    /// names another service: that would send this key there (and a revoke
    /// answered 401/404 by it would drop the only local copy of a live key).
    pub fn issuer_for(&self, requested: Option<&str>) -> Result<String, CliError> {
        let issuer = self.issuer();
        match requested {
            Some(url) if url.trim_end_matches('/') != issuer.trim_end_matches('/') => {
                Err(CliError::usage(format!(
                    "the stored VM token {} belongs to {issuer}, not {url}; unset --base-url / CMUX_VM_BASE_URL, or set CMUX_VM_API_KEY to use another service",
                    self.key_id
                )))
            }
            _ => Ok(issuer),
        }
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

/// What the store holds.
pub enum Stored {
    Token(StoredToken),
    /// Something that is not a token (bad JSON, not text): nothing can
    /// revoke its key, and `token revoke` removes it ([`remove_unreadable`]).
    Unreadable,
}

/// What the store holds, if anything. `Err` when the store itself cannot be
/// read (the Keychain refuses, the file is unsafe or unreadable).
pub fn read_stored(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<Stored>, String> {
    let Some(bytes) = platform::read(env)? else {
        return Ok(None);
    };
    Ok(Some(
        serde_json::from_slice(&bytes).map_or(Stored::Unreadable, Stored::Token),
    ))
}

/// The stored token, if any. A store that cannot be read is an error, so a
/// broken store never silently falls back to another credential.
pub fn load(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<StoredToken>, String> {
    match read_stored(env)? {
        None => Ok(None),
        Some(Stored::Token(token)) => Ok(Some(token)),
        Some(Stored::Unreadable) => Err(unreadable_message()),
    }
}

/// The error for a stored token that cannot be read, naming the recovery
/// that works: `token revoke` removes it (it cannot revoke a key it cannot
/// read, which ends at its expiry).
pub fn unreadable_message() -> String {
    format!(
        "the stored VM token is unreadable; run `{} token revoke` to remove it (its key cannot be revoked without it: it expires within its TTL, at most 24h, which deletes its VMs)",
        crate::error::program()
    )
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

    pub fn read(_env: &dyn Fn(&str) -> Option<String>) -> Result<Option<Vec<u8>>, String> {
        match get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => Ok(Some(bytes)),
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

    pub fn read(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<Vec<u8>>, String> {
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
                    "{} is readable by other users; refusing it: chmod 600 it, then run `{} token revoke` if someone else may have read the key",
                    path.display(),
                    crate::error::program()
                ));
            }
        }
        #[cfg(not(unix))]
        let _ = meta;
        std::fs::read(&path)
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
    let scale: u64 = match unit {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86_400,
        _ => {
            return Err(CliError::usage(format!(
                "invalid --ttl {text:?}: use s, m, h or d"
            )));
        }
    };
    // An overflowing product is out of range, never a wrapped small one.
    let seconds = value.saturating_mul(scale);
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

/// Where `token create` and `revoke` serialize this user's changes to the
/// store ([`lock_path_for`] with the account's home on macOS). On macOS it
/// fails closed: without the account's home it never falls back to the
/// environment, which would split the lock again.
fn create_lock_path(
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<std::path::PathBuf>, CliError> {
    if cfg!(target_os = "macos") {
        let home = account_home().ok_or_else(|| {
            CliError::unexpected(
                "cannot find this user's home directory in the user database, so the VM token store cannot be locked",
            )
        })?;
        Ok(lock_path_for(Some(&home), env))
    } else {
        Ok(lock_path_for(None, env))
    }
}

/// The store lock. The file store is locked beside its file: both follow
/// XDG_CONFIG_HOME or HOME, so another environment is another store. On
/// macOS the token is one login Keychain item per user, so the lock follows
/// the account instead (`account_home`, from the user database): two creates
/// of one user with different HOME or XDG_CONFIG_HOME would otherwise take
/// different locks, both mint, and one overwrite the other's stored key,
/// leaving it live with nothing able to revoke it (#29705). In the usual
/// environment it is the same file as before.
fn lock_path_for(
    account_home: Option<&std::path::Path>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<std::path::PathBuf> {
    let base = match account_home {
        Some(home) => home.join(".config"),
        None => env("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(std::path::PathBuf::from)
            .or_else(|| {
                env("HOME")
                    .filter(|v| !v.is_empty())
                    .map(|home| std::path::PathBuf::from(home).join(".config"))
            })?,
    };
    Some(base.join("cmux").join("vm-token.lock"))
}

/// This user's home from the user database (getpwuid), never the
/// environment. `None` when there is no entry or it is not absolute.
#[cfg(target_os = "macos")]
fn account_home() -> Option<std::path::PathBuf> {
    nix::unistd::User::from_uid(nix::unistd::geteuid())
        .ok()
        .flatten()
        .map(|user| user.dir)
        .filter(|dir| dir.is_absolute())
}

/// The file store follows the environment, and so does its lock
/// ([`create_lock_path`] does not ask for the account's home here).
#[cfg(not(target_os = "macos"))]
fn account_home() -> Option<std::path::PathBuf> {
    None
}

/// The start of every `token create`: takes this user's create lock and
/// checks the store under it ([`refuse_if_one_is_stored`]). Hold the lock
/// until the new key is stored (or revoked), so two concurrent creates cannot
/// both mint and leave one key stored nowhere. `None` when there is no
/// config directory to lock in.
pub fn begin_create(
    env: &dyn Fn(&str) -> Option<String>,
    now_unix: i64,
) -> Result<Option<std::fs::File>, CliError> {
    let lock = lock_store(env)?;
    refuse_if_one_is_stored(env, now_unix)?;
    Ok(lock)
}

/// This user's lock on the token store, held while a create or a revoke
/// reads and changes it. `None` when there is no config directory.
fn lock_store(env: &dyn Fn(&str) -> Option<String>) -> Result<Option<std::fs::File>, CliError> {
    Ok(match create_lock_path(env)? {
        Some(path) => {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| {
                    CliError::unexpected(format!("cannot create {}: {e}", dir.display()))
                })?;
            }
            let mut options = std::fs::OpenOptions::new();
            options.create(true).truncate(false).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let file = options.open(&path).map_err(|e| {
                CliError::unexpected(format!("cannot open {}: {e}", path.display()))
            })?;
            file.lock().map_err(|e| {
                CliError::unexpected(format!("cannot lock {}: {e}", path.display()))
            })?;
            Some(file)
        }
        None => None,
    })
}

/// `token create` refuses while a token that may be live is stored: storing a
/// new one would leave that key live and billable with nothing able to revoke
/// it, and revoking it here would delete VMs another process may be using. An
/// expired token (already dead on the server) or none at all is no obstacle;
/// a store that cannot be read is replaced, since nothing could revoke from it.
pub fn refuse_if_one_is_stored(
    env: &dyn Fn(&str) -> Option<String>,
    now_unix: i64,
) -> Result<(), CliError> {
    match load(env) {
        // Only a token known to have expired is dead on the server; one whose
        // expiry cannot be read may still be live, so it is revoked first too.
        Ok(Some(token)) if token.seconds_left(now_unix).is_none_or(|left| left > 0) => {
            Err(CliError::conflict(format!(
                "the VM token {} is already stored (expires {}): to replace it, run `{p} token revoke` (which deletes its VMs) and then `{p} token create`",
                token.key_id,
                token.expires_at,
                p = crate::error::program()
            )))
        }
        _ => Ok(()),
    }
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
    let _lock = begin_create(env, now_unix())?;
    // The service takes no idempotency key for agent keys, so a create is
    // never retried: a lost answer leaves at most one key nobody holds, with
    // no VMs, that expires within its --ttl.
    let created = fetch_body(client.agents_create_agent_key(None, &body))
        .await
        .map_err(|error| {
            if error.status().is_none_or(|status| status >= 500) {
                error.with_recovery("if the service issued a key, it was never shown, has no VMs and expires within its --ttl")
            } else {
                error
            }
        })?;
    match keep(&created, team_id, base_url, env) {
        Ok(token) => report(&token, "stored", json_output, out),
        Err(error) => Err(revoke_unkept(client, &created, error).await),
    }
}

/// Reads and stores a freshly minted key, replacing any earlier one.
fn keep(
    created: &[u8],
    team_id: Option<String>,
    base_url: Option<String>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<StoredToken, CliError> {
    let token = StoredToken::from_created(created, team_id, base_url)?;
    save(&token, env).map_err(CliError::unexpected)?;
    Ok(token)
}

/// Revokes a key that was minted but cannot be kept (unreadable or not
/// stored), so it never outlives the command that made it.
async fn revoke_unkept(client: &Client, created: &[u8], error: CliError) -> CliError {
    let id = serde_json::from_slice::<Value>(created)
        .ok()
        .and_then(|created| created["id"].as_str().map(str::to_owned));
    let Some(id) = id else {
        return error.with_recovery("the service's answer named no key to revoke; any key it issued expires within its --ttl");
    };
    match call(client.agents_revoke_agent_key(&id, None)).await {
        Ok(_) => error.with_recovery(&format!(
            "the new key {id} was revoked, since it could not be kept"
        )),
        Err(_) => error.with_recovery(&format!(
            "the new key {id} could not be revoked; it was never shown and expires within its --ttl"
        )),
    }
}

/// Stores a key the cmux app minted and prints its public facts. A key that
/// cannot be kept (an unreadable answer, a failed store) revokes itself, since
/// an agent key may revoke itself, so it never outlives the command that made
/// it. Shared with the cmux CLI, whose app mints the key with the signed-in
/// session; nothing here holds that session.
pub async fn keep_minted(
    created: &[u8],
    team_id: Option<String>,
    base_url: Option<String>,
    env: &dyn Fn(&str) -> Option<String>,
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    let error = match keep(created, team_id.clone(), base_url.clone(), env) {
        Ok(token) => return report(&token, "stored", json_output, out),
        Err(error) => error,
    };
    let key = serde_json::from_slice::<Value>(created)
        .ok()
        .and_then(|created| created["key"].as_str().map(str::to_owned));
    let Some(key) = key else {
        return Err(error.with_recovery(
            "the app's answer held no key to revoke it with; any key it issued was never shown and expires within its --ttl",
        ));
    };
    // The issuer the app named, so the new key goes nowhere but where it
    // was minted (CMUX_VM_BASE_URL only when the app names none).
    let base_url = base_url
        .or_else(|| env("CMUX_VM_BASE_URL").filter(|url| !url.is_empty()))
        .unwrap_or_else(|| cmux_vm_client::DEFAULT_BASE_URL.to_owned());
    match cmux_vm_client::authenticated_raw_client(
        &base_url,
        &key,
        team_id.as_deref(),
        concat!("cmux-vm/", env!("CARGO_PKG_VERSION")),
    ) {
        Ok(client) => Err(revoke_unkept(&client, created, error).await),
        Err(_) => Err(error.with_recovery(
            "the new key could not be revoked; it was never shown and expires within its --ttl",
        )),
    }
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
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    match call(client.agents_revoke_agent_key(&token.key_id, None)).await {
        Ok(_) => {}
        // Already gone (expired, revoked elsewhere): only the local copy is left.
        Err(error) if matches!(error.status(), Some(401 | 404)) => {}
        Err(error) => return Err(error),
    }
    // Under the store lock, remove the local copy only if it is still this
    // key: a create may have stored a new one while the revoke was in flight.
    let _lock = lock_store(env)?;
    let still_stored = load(env)
        .ok()
        .flatten()
        .is_some_and(|stored| stored.key_id == token.key_id);
    if still_stored {
        remove(env).map_err(CliError::unexpected)?;
    }
    let text = if json_output {
        json!({ "id": token.key_id, "revoked": true, "removed": still_stored }).to_string()
    } else if still_stored {
        format!("token {} revoked and removed", token.key_id)
    } else {
        format!(
            "token {} revoked; the stored token is a newer one and was kept",
            token.key_id
        )
    };
    writeln!(out, "{text}").map_err(|e| CliError::unexpected(format!("write output: {e}")))
}

/// `token revoke` when the stored token cannot be read: its key cannot be
/// revoked without it, so only the local copy is removed (the key expires
/// within its TTL). Under the store lock, and only while it is still
/// unreadable: a create may have stored a new token meanwhile.
pub fn remove_unreadable(
    env: &dyn Fn(&str) -> Option<String>,
    json_output: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    let _lock = lock_store(env)?;
    let removed = matches!(read_stored(env), Ok(Some(Stored::Unreadable)))
        && remove(env).map_err(CliError::unexpected)?;
    let text = if json_output {
        json!({ "id": null, "revoked": false, "removed": removed }).to_string()
    } else if removed {
        "the stored VM token could not be read, so it was removed without revoking its key; that key expires within its TTL (at most 24h), which deletes its VMs".to_owned()
    } else {
        "the stored VM token was replaced meanwhile and was kept".to_owned()
    };
    writeln!(out, "{text}").map_err(|e| CliError::unexpected(format!("write output: {e}")))
}

/// Seconds since the Unix epoch for exactly `YYYY-MM-DDTHH:MM:SS[.fff]Z`
/// (years 0000 to 9999, so nothing here can overflow); anything else, an
/// impossible date or time included, is `None`.
pub fn parse_rfc3339(text: &str) -> Option<i64> {
    let text = text.strip_suffix('Z')?;
    let (main, fraction) = match text.split_once('.') {
        Some((main, fraction)) => (main, Some(fraction)),
        None => (text, None),
    };
    if fraction.is_some_and(|f| f.is_empty() || !f.bytes().all(|b| b.is_ascii_digit())) {
        return None;
    }
    let bytes = main.as_bytes();
    if bytes.len() != 19
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| {
        let part = main.get(range)?;
        if !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        part.parse::<i64>().ok()
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return None,
    };
    if !(1..=month_days).contains(&day)
        || !(0..24).contains(&hour)
        || !(0..60).contains(&minute)
        || !(0..=60).contains(&second)
    {
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
        // 307445734561825862 minutes wraps to 104 seconds in a u64.
        assert!(parse_ttl("307445734561825862m").is_err());
        assert!(parse_ttl("99999999999999999999").is_err());
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
    fn a_stored_key_goes_only_to_its_issuer() {
        let mut token = StoredToken {
            key: "k".into(),
            key_id: "vmk_x".into(),
            expires_at: "2099-01-01T00:00:00Z".into(),
            team_id: None,
            base_url: None,
            scopes: Vec::new(),
            max_vms: None,
            max_usd_per_hour: None,
        };
        assert_eq!(token.issuer_for(None).unwrap(), "https://vm.cmux.dev");
        assert_eq!(
            token.issuer_for(Some("https://vm.cmux.dev/")).unwrap(),
            "https://vm.cmux.dev"
        );
        assert!(token.issuer_for(Some("https://evil.example")).is_err());
        token.base_url = Some("https://vm-staging.cmux.dev".into());
        assert_eq!(
            token.issuer_for(None).unwrap(),
            "https://vm-staging.cmux.dev"
        );
        assert!(token.issuer_for(Some("https://vm.cmux.dev")).is_err());
    }

    #[test]
    fn expiries_must_be_real_times() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339("2024-02-29T23:59:59.500Z"),
            Some(1_709_251_199)
        );
        for bad in [
            "99999999999999-01-01T00:00:00Z",
            "+2026-10-29T08:00:00Z",
            "2026-1-29T08:00:00Z",
            "2026-10-29T08:00:00.Z",
            "2026-10-29T08:00:00.5xZ",
            "2026-10-29T08:00:00",
            "2026-02-31T00:00:00Z",
            "2025-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-10-29T24:00:00Z",
            "2026-10-29T25:99:99Z",
            "2026-10-29T08:60:00Z",
            "2026-10-29T08:00:61Z",
            "2026-13-01T00:00:00Z",
            "2026-10-00T00:00:00Z",
        ] {
            assert_eq!(parse_rfc3339(bad), None, "{bad}");
        }
    }

    #[test]
    fn status_refuses_an_unreadable_expiry_like_an_expired_one() {
        let mut token = StoredToken {
            key: "k".into(),
            key_id: "vmk_x".into(),
            expires_at: "2026-10-29T08:00:00Z".into(),
            team_id: None,
            base_url: None,
            scopes: Vec::new(),
            max_vms: None,
            max_usd_per_hour: None,
        };
        let at = parse_rfc3339(&token.expires_at).unwrap();
        assert_eq!(token.status(at - 60), ("is", crate::exit::OK));
        assert_eq!(token.status(at), ("expired", crate::exit::UNAUTHENTICATED));
        token.expires_at = "never".into();
        assert_eq!(token.status(at - 60).1, crate::exit::UNAUTHENTICATED);
        token.expires_at = String::new();
        assert_eq!(token.status(at - 60).1, crate::exit::UNAUTHENTICATED);
    }

    // The file store; macOS keeps the token in the login Keychain.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn create_refuses_while_a_usable_token_is_stored() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-one-token-{}", std::process::id()));
        let xdg = dir.to_string_lossy().into_owned();
        let env = |name: &str| (name == "XDG_CONFIG_HOME").then(|| xdg.clone());
        assert!(refuse_if_one_is_stored(&env, 0).is_ok());
        let mut token = StoredToken {
            key: "cmuxvm_sk_SECRET".into(),
            key_id: "vmk_live".into(),
            expires_at: "2099-01-01T00:00:00Z".into(),
            team_id: None,
            base_url: None,
            scopes: Vec::new(),
            max_vms: None,
            max_usd_per_hour: None,
        };
        save(&token, &env).unwrap();
        let refused = refuse_if_one_is_stored(&env, now_unix()).unwrap_err();
        assert_eq!(refused.exit_code(), crate::exit::CONFLICT);
        assert!(refused.message().contains("vmk_live"));
        assert!(refused.message().contains("token revoke"));
        assert!(!refused.message().contains("SECRET"));
        // One whose expiry cannot be read may be live: refused too.
        token.expires_at = "2026-02-31T25:99:99Z".into();
        save(&token, &env).unwrap();
        assert!(refuse_if_one_is_stored(&env, now_unix()).is_err());
        // An expired token is dead on the server: a new one may replace it.
        token.expires_at = "2001-01-01T00:00:00Z".into();
        save(&token, &env).unwrap();
        assert!(refuse_if_one_is_stored(&env, now_unix()).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn one_create_at_a_time() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-create-lock-{}", std::process::id()));
        let xdg = dir.to_string_lossy().into_owned();
        let env = |name: &str| (name == "XDG_CONFIG_HOME").then(|| xdg.clone());
        let held = begin_create(&env, 0).unwrap().expect("a lock file");
        let other = std::fs::File::open(create_lock_path(&env).unwrap().unwrap()).unwrap();
        assert!(matches!(
            other.try_lock(),
            Err(std::fs::TryLockError::WouldBlock)
        ));
        drop(held);
        // Blocking: a process another test forks in this instant briefly
        // shares the closed descriptor (until its exec), so the lock may
        // outlive `drop` by that long; a create waits the same way.
        other.lock().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// On macOS the token is one login Keychain item per user, so the lock
    /// is the account's, whatever HOME or XDG_CONFIG_HOME say (#29705).
    #[test]
    fn the_lock_follows_the_account_not_the_environment() {
        let home = std::path::Path::new("/Users/someone");
        let xdg = |name: &str| (name == "XDG_CONFIG_HOME").then(|| "/tmp/a".to_owned());
        let other_home = |name: &str| (name == "HOME").then(|| "/tmp/b".to_owned());
        let lock = Some(home.join(".config").join("cmux").join("vm-token.lock"));
        assert_eq!(lock_path_for(Some(home), &xdg), lock);
        assert_eq!(lock_path_for(Some(home), &other_home), lock);
        assert_eq!(lock_path_for(Some(home), &|_| None), lock);
        // The file store (no Keychain) is locked beside the file it keeps.
        assert_eq!(
            lock_path_for(None, &xdg),
            Some(std::path::PathBuf::from("/tmp/a/cmux/vm-token.lock"))
        );
        assert_eq!(
            lock_path_for(None, &other_home),
            Some(std::path::PathBuf::from(
                "/tmp/b/.config/cmux/vm-token.lock"
            ))
        );
        assert_eq!(lock_path_for(None, &|_| None), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn two_environments_of_one_user_share_the_macos_lock() {
        let a = |name: &str| (name == "XDG_CONFIG_HOME").then(|| "/tmp/a".to_owned());
        let b = |name: &str| (name == "HOME").then(|| "/tmp/b".to_owned());
        let a = create_lock_path(&a).unwrap();
        assert!(a.is_some());
        assert_eq!(a, create_lock_path(&b).unwrap());
    }

    // The file store; macOS keeps the token in the login Keychain.
    #[cfg(not(target_os = "macos"))]
    #[tokio::test]
    async fn revoke_json_is_one_json_object() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .and(path("/v1/agent-keys/vmk_x"))
            .respond_with(ResponseTemplate::new(204))
            .expect(2)
            .mount(&server)
            .await;
        let dir = std::env::temp_dir().join(format!("cmux-vm-revoke-json-{}", std::process::id()));
        let xdg = dir.to_string_lossy().into_owned();
        let env = |name: &str| (name == "XDG_CONFIG_HOME").then(|| xdg.clone());
        let token = StoredToken {
            key: "cmuxvm_sk_SECRET".into(),
            key_id: "vmk_x".into(),
            expires_at: "2099-01-01T00:00:00Z".into(),
            team_id: None,
            base_url: None,
            scopes: Vec::new(),
            max_vms: None,
            max_usd_per_hour: None,
        };
        save(&token, &env).unwrap();
        let client =
            cmux_vm_client::authenticated_raw_client(&server.uri(), &token.key, None, "test")
                .unwrap();
        let mut out = Vec::new();
        revoke(&client, &token, &env, true, &mut out).await.unwrap();
        let printed: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(
            printed,
            json!({"id": "vmk_x", "revoked": true, "removed": true})
        );
        assert_eq!(load(&env).unwrap(), None);
        // A token a create stored while the revoke was in flight stays.
        let newer = StoredToken {
            key_id: "vmk_newer".into(),
            ..token.clone()
        };
        save(&newer, &env).unwrap();
        let mut out = Vec::new();
        revoke(&client, &token, &env, true, &mut out).await.unwrap();
        let printed: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(printed["removed"], json!(false));
        assert_eq!(load(&env).unwrap(), Some(newer));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_app_minted_key_that_cannot_be_kept_revokes_itself() {
        use wiremock::matchers::{header, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        let id = "vmk_0123456789abcdefghjkmnpqrs";
        Mock::given(method("DELETE"))
            .and(path(format!("/v1/agent-keys/{id}")))
            .and(header("authorization", "Bearer cmuxvm_sk_SECRETSECRET"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        // No readable expiry: refused before anything is stored.
        let created = format!(
            r#"{{"id":"{id}","key":"cmuxvm_sk_SECRETSECRET","scopes":["vm:read"],"expiresAt":"soon"}}"#
        );
        // The app names the issuer; CMUX_VM_BASE_URL points elsewhere and
        // must never see the key.
        let env =
            |name: &str| (name == "CMUX_VM_BASE_URL").then(|| "http://127.0.0.1:9".to_owned());
        let mut out = Vec::new();
        let error = keep_minted(
            created.as_bytes(),
            None,
            Some(server.uri()),
            &env,
            false,
            &mut out,
        )
        .await
        .unwrap_err();
        assert!(
            error.message().contains("no readable expiry"),
            "{}",
            error.message()
        );
        assert!(
            error
                .message()
                .contains(&format!("the new key {id} was revoked")),
            "{}",
            error.message()
        );
        assert!(!error.message().contains("SECRET"));
        assert!(out.is_empty());

        // An answer with no key has nothing to revoke with, and says so.
        let error = keep_minted(br#"{"id":"vmk_x"}"#, None, None, &env, false, &mut out)
            .await
            .unwrap_err();
        assert!(
            error.message().contains("held no key"),
            "{}",
            error.message()
        );
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
