//! A scoped key minted by another of the person's machines, over the acpmux peer link: a Linux
//! agent asks the Mac whose Keychain holds a provider's bootstrap token, and gets back one
//! narrowly scoped, expiring key. The bootstrap never leaves the Mac.
//!
//! ```text
//! cmux keys mint cloudflare-r2 --via MAC ...   (Linux, this machine, A)
//!   -> _acpmux/keys_mint on A's unix socket
//!   -> the peer link to MAC (its peer token or A's device credential)
//!   -> _acpmux/keys_mint on MAC, served as Origin::Peer
//!   -> MAC's own `cmux keys mint ... --reply-to-machine A` (cli/key_broker.rs), which reads the
//!      bootstrap from MAC's Keychain, mints, and prints the new key's pair on a pipe to this daemon
//!   -> the reply: the key's id, scope, expiry and its two values, nothing else ([`reply`])
//! ```
//!
//! Who may ask is Computer Use's rule (`computer_use_relay::admit`): the local unix socket sends an
//! ask on to a named peer and never mints here; a peer that proved its peer token or a `client`
//! device credential mints here; the Web listener, the app pane, a phone and a read-only machine are
//! refused. An ask carries only the key's scope (kind, bucket, access, ttl, account, bucket setup),
//! each checked here and again by the CLI: never a store, a path, a command or a machine to hop on
//! to. The minting machine's audit records the key as delivered to the asking machine.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::Conn;
use super::computer_use_relay::{Admission, admit, device_record};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// How long the minting machine's CLI may take: a few Cloudflare calls, retried while a fresh
/// token propagates (cli/key_broker.rs `with_fresh_token`, at most about a minute).
const MINT_LIMIT: Duration = Duration::from_secs(150);

/// The fields of the CLI's answer a reply may carry. Anything else the CLI printed stays on the
/// minting machine.
const RECORD_FIELDS: &[&str] = &[
    "id",
    "provider",
    "account",
    "kind",
    "bucket",
    "access",
    "created_at",
    "expires_at",
    "expires_at_s",
];
/// The values of a minted R2 key: its S3 pair.
const VALUE_NAMES: &[&str] = &["ACCESS_KEY_ID", "SECRET_ACCESS_KEY"];

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The checked scope of one ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MintAsk {
    pub machine: Option<String>,
    pub bucket: String,
    pub write: bool,
    pub ttl: String,
    pub account: Option<String>,
    pub create_bucket: bool,
    pub expire_objects_days: Option<u32>,
}

pub(super) fn parse(params: &Value) -> Result<MintAsk, RpcError> {
    let bad = |what: &str| refused("invalid_arguments", format!("{what} is not valid"));
    let allowed = [
        "machine",
        "kind",
        "bucket",
        "access",
        "ttl",
        "account",
        "create_bucket",
        "expire_objects_days",
    ];
    let Some(map) = params.as_object() else { return Err(bad("the ask")) };
    if let Some(other) = map.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Err(refused(
            "keys_remote_denied",
            format!("an ask carries only a key's scope, not {other:?}"),
        ));
    }
    if params["kind"].as_str() != Some("cloudflare-r2") {
        return Err(refused("invalid_arguments", "kind must be cloudflare-r2"));
    }
    let bucket = params["bucket"].as_str().unwrap_or_default();
    if !(3..=63).contains(&bucket.len())
        || !bucket.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        || bucket.starts_with('-')
        || bucket.ends_with('-')
    {
        return Err(bad("bucket"));
    }
    let write = match params["access"].as_str() {
        Some("rw") => true,
        Some("ro") => false,
        _ => return Err(refused("invalid_arguments", "access must be rw or ro")),
    };
    let ttl = params["ttl"].as_str().unwrap_or("90d");
    let (number, unit) = ttl.split_at(ttl.len().saturating_sub(1));
    if number.is_empty()
        || number.len() > 6
        || !number.chars().all(|c| c.is_ascii_digit())
        || !matches!(unit, "d" | "h" | "m")
    {
        return Err(bad("ttl"));
    }
    let account = match &params["account"] {
        Value::Null => None,
        Value::String(a) if a.len() == 32 && a.chars().all(|c| c.is_ascii_hexdigit()) => {
            Some(a.to_ascii_lowercase())
        }
        _ => return Err(bad("account")),
    };
    let create_bucket = match &params["create_bucket"] {
        Value::Null => false,
        Value::Bool(b) => *b,
        _ => return Err(bad("create_bucket")),
    };
    let expire_objects_days = match &params["expire_objects_days"] {
        Value::Null => None,
        v => Some(
            v.as_u64()
                .filter(|d| (1..=3650).contains(d))
                .map(|d| d as u32)
                .ok_or_else(|| bad("expire_objects_days"))?,
        ),
    };
    let machine = match &params["machine"] {
        Value::Null => None,
        Value::String(m) if !m.is_empty() && m.len() <= 256 && !m.chars().any(char::is_control) => {
            Some(m.clone())
        }
        _ => return Err(bad("machine")),
    };
    Ok(MintAsk {
        machine,
        bucket: bucket.to_owned(),
        write,
        ttl: ttl.to_owned(),
        account,
        create_bucket,
        expire_objects_days,
    })
}

impl MintAsk {
    /// The ask as the next hop gets it: the scope only, no machine.
    pub(super) fn onward(&self) -> Value {
        let mut ask = Map::new();
        ask.insert("kind".to_owned(), json!("cloudflare-r2"));
        ask.insert("bucket".to_owned(), json!(self.bucket));
        ask.insert("access".to_owned(), json!(if self.write { "rw" } else { "ro" }));
        ask.insert("ttl".to_owned(), json!(self.ttl));
        if let Some(account) = &self.account {
            ask.insert("account".to_owned(), json!(account));
        }
        if self.create_bucket {
            ask.insert("create_bucket".to_owned(), json!(true));
        }
        if let Some(days) = self.expire_objects_days {
            ask.insert("expire_objects_days".to_owned(), json!(days));
        }
        Value::Object(ask)
    }

    /// The minting machine's CLI words: `cmux --json keys mint cloudflare-r2 ...`, built from the
    /// checked scope alone, replying to `machine` instead of storing.
    pub(super) fn argv(&self, machine: &str) -> Vec<String> {
        let mut argv: Vec<String> =
            ["--json", "keys", "mint", "cloudflare-r2", "--bucket"].map(str::to_owned).into();
        argv.push(self.bucket.clone());
        argv.push(if self.write { "--rw" } else { "--ro" }.to_owned());
        argv.extend(["--ttl".to_owned(), self.ttl.clone()]);
        if let Some(account) = &self.account {
            argv.extend(["--account".to_owned(), account.clone()]);
        }
        if self.create_bucket {
            argv.push("--create-bucket".to_owned());
        }
        if let Some(days) = self.expire_objects_days {
            argv.extend(["--expire-objects-days".to_owned(), days.to_string()]);
        }
        argv.extend(["--reply-to-machine".to_owned(), machine.to_owned()]);
        argv
    }
}

/// The reply from the CLI's answer: the minted key's listed fields and its two values, and
/// nothing else the answer held. `None` when the answer has no whole key.
pub(super) fn reply(answer: &Value) -> Option<Value> {
    let minted = answer.get("minted")?.as_object()?;
    let mut record = Map::new();
    for field in RECORD_FIELDS {
        if let Some(v) = minted.get(*field) {
            record.insert((*field).to_owned(), v.clone());
        }
    }
    record.get("id")?.as_str()?;
    let values = answer.get("values")?.as_object()?;
    let mut kept = Map::new();
    for name in VALUE_NAMES {
        kept.insert((*name).to_owned(), json!(values.get(*name)?.as_str()?));
    }
    Some(json!({"minted": Value::Object(record), "values": Value::Object(kept)}))
}

/// The CLI that mints: the app's bundled `cmux` (`CMUX_BUNDLED_CLI_PATH`), else the one beside
/// this daemon, else `cmux` on PATH.
fn cmux_cli() -> std::path::PathBuf {
    let bundled = std::env::var_os(crate::login_env::BUNDLED_CLI_ENV)
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute() && p.is_file());
    let sibling = || {
        let exe = std::env::current_exe().ok()?;
        let path = exe.parent()?.join("cmux");
        path.is_file().then_some(path)
    };
    bundled.or_else(sibling).unwrap_or_else(|| "cmux".into())
}

/// Runs the minting CLI with its stdout on a pipe (the pair is in it: never a file, never a
/// log), killed past [`MINT_LIMIT`]. Its answer, or the refusal it printed.
fn run_cli(argv: &[String]) -> Result<Value, RpcError> {
    use std::io::Read as _;
    let mut child = cmux_process::Command::new(cmux_cli())
        .args(argv)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .map_err(|e| refused("keys_unavailable", format!("cannot run cmux keys here: {e}")))?;
    let mut stdout = child.stdout.take().ok_or_else(|| RpcError::internal("no stdout"))?;
    // The answer is a few hundred bytes, far under a pipe's buffer, so the child never waits on
    // this read; one that did would run past the limit and be killed.
    let status = match child.wait_timeout(MINT_LIMIT) {
        Ok(Some(status)) => status,
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(refused("unreachable", "cmux keys mint ran past its time here"));
        }
    };
    let mut out = zeroize::Zeroizing::new(Vec::new());
    stdout
        .read_to_end(&mut out)
        .map_err(|e| RpcError::internal(format!("cannot read cmux keys mint's answer: {e}")))?;
    let answer: Value = serde_json::from_slice(&out).unwrap_or(Value::Null);
    if !status.success() {
        // The CLI's refusal names no value (key_broker.rs), so its message goes back as it is.
        let message = answer
            .pointer("/error/message")
            .or_else(|| answer.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("cmux keys mint failed here");
        return Err(refused("keys_refused", message.chars().take(600).collect::<String>()));
    }
    Ok(answer)
}

/// `_acpmux/keys_mint`.
pub(super) async fn mint(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let device = device_record(hub, conn.device.as_deref());
    let ask = parse(params)?;
    match admit(conn.origin, conn.auth, device.as_ref()) {
        Admission::Refused(why) => Err(refused("keys_remote_denied", why)),
        Admission::Forward => {
            let Some(machine) = &ask.machine else {
                return Err(refused(
                    "invalid_arguments",
                    "name the machine that holds the provider; on this one, run cmux keys mint",
                ));
            };
            let peer = hub.peer_by_name(machine).ok_or_else(|| {
                refused(
                    "unknown_machine",
                    format!("no machine named {machine:?}; see acpmux machine ls"),
                )
            })?;
            let answer = super::peer_targeted::request(&peer, method::MUX_KEYS_MINT, ask.onward())
                .await
                .map_err(link_error)?;
            // The next hop's reply, held to the same fields again.
            reply(&answer)
                .ok_or_else(|| refused("keys_refused", "the machine answered without a whole key"))
        }
        Admission::Run { machine } => {
            if ask.machine.is_some() {
                return Err(refused("keys_remote_denied", "a key is minted on one machine only"));
            }
            if crate::cli::cloud_join::require_joined_consent("control").is_err() {
                return Err(refused(
                    "keys_consent_required",
                    "this machine needs its person's control consent before another machine may mint keys here",
                ));
            }
            let argv = ask.argv(&machine);
            let answer = tokio::task::spawn_blocking(move || run_cli(&argv))
                .await
                .map_err(|e| RpcError::internal(format!("the mint stopped: {e}")))??;
            reply(&answer).ok_or_else(|| {
                refused("keys_refused", "cmux keys mint answered without a whole key")
            })
        }
    }
}

/// An RpcError from the peer link, with `code: unreachable` when the ask should be retried.
fn link_error(e: RpcError) -> RpcError {
    if e.data.as_ref().and_then(|d| d.get("code")).is_some_and(Value::is_string) {
        return e;
    }
    let message = e.message.clone();
    let data = json!({"code": "unreachable", "link": e.data});
    RpcError::new(e.code, message).with_data(data)
}

#[cfg(test)]
#[path = "keys_relay_tests.rs"]
mod tests;
