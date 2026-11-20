//! Keys from any provider: an agent stores a key it has, then enters it where it is needed, and
//! never sees, prints or logs the value (Leo, 2026-11-15: "can you do the keys without cloudflare?
//! ... as an app feature letting agents safely write keys and store them or enter them into
//! whatever").
//!
//!     cmux keys put NAME [--purpose TEXT] [--hosts H,H] [--ttl 90d] [--replace]   value on stdin
//!     cmux keys generate NAME [--bytes 32] [--format base64url|hex|alnum] [...put flags]
//!     cmux keys request NAME --purpose TEXT [--hosts H,H] [--ttl 90d] [--timeout 15m]
//!     cmux keys use NAME[=VAR] [NAME --env VAR]... [--no-mask] -- CMD [ARGS...]
//!     cmux keys write NAME --to TARGET [--to TARGET]...
//!     cmux keys fill NAME [--tab TAB] --selector CSS [--type]
//!     cmux keys rm NAME                                          (or cmux keys revoke NAME)
//!
//! - **Where a value lives.** The OS secret store (the login Keychain on a Mac, the Secret Service
//!   on Linux), item `key.NAME` of the store the machine vault uses (`acpmux::vault::store`). There
//!   is no file or memory fallback: a machine with no OS store refuses. The audit
//!   (`~/.config/cmux/keys.json`, 0600) gets one record per key: its name, purpose, the hosts it is
//!   for, who stored it and who asked, when it expires, every place a copy was written (`stores`)
//!   and every place it was entered (`uses`). Never a value.
//! - **How a value comes in.** stdin only (a pipe from the provider's CLI or API, or a no-echo
//!   prompt at a terminal), `generate` (the OS random source), or the person: `request` asks the
//!   cmux app, which shows the ask in Settings > Keys with a secure field, and stores what the
//!   person pastes with `put`, never through a chat.
//! - **How a value goes out.** Only by reference, by this process: `use` puts it in a command's
//!   env and masks it in what the command prints; `write` copies it into a
//!   GitHub secret, a cloud secret, the machine vault, a 0600 file, a JSON or TOML field or an env
//!   file; `fill` types it into a field of a cmux browser tab, refusing a page outside the key's
//!   hosts. The `keys_fill` MCP tool also types it into a desktop app through Computer Use. A
//!   reply names the key and the target, never the value.
//!
//! This keeps values out of transcripts, logs and a model's context. It is not a wall against an
//! agent that sets out to read the value: a command it runs with `use` gets the value, and the OS
//! store answers any process of this user.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{
    AuditLock, Paths, Sinks, Store, UsageError, now_secs, read_audit, requester, rfc3339,
    write_audit,
};

mod exec;
mod files;
mod fill;
mod parse;

#[cfg(test)]
use exec::Masker;
#[cfg(test)]
use files::set_env_line;
use fill::*;

pub(in crate::cli) use exec::{mask_json, mask_text, run_use};
pub(in crate::cli) use files::write;
pub(in crate::cli) use fill::fill;
pub(in crate::cli) use parse::{parse, valid_name};

/// The OS store item of key `NAME`: `key.NAME` (an env name has no dot, so it never meets a
/// machine vault entry or a kept key).
pub(in crate::cli) fn item(name: &str) -> String {
    format!("key.{name}")
}

/// A value short enough to occur by chance in ordinary output is no secret, and masking it
/// would garble that output.
pub(in crate::cli) const MIN_VALUE_CHARS: usize = 8;
pub(in crate::cli) const MAX_VALUE_BYTES: usize = 64 * 1024;
/// What every masked occurrence of a value prints as.
pub(in crate::cli) const MASK: &str = "<concealed by cmux keys>";
/// The most `uses` one record keeps; the oldest goes first.
const MAX_USES: usize = 32;
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const MAX_REQUEST_TIMEOUT: Duration = Duration::from_secs(24 * 3_600);
const MAX_PURPOSE_CHARS: usize = 300;

pub(super) const USAGE: &str = "cmux keys put NAME [--purpose TEXT] [--hosts H,H] [--ttl 90d] [--replace]   (value on stdin)\n       \
cmux keys generate NAME [--bytes 32] [--format base64url|hex|alnum] [--purpose TEXT] [--hosts H,H] [--ttl 90d]\n       \
cmux keys request NAME --purpose TEXT [--hosts H,H] [--ttl 90d] [--timeout 15m]   (asks the person in the cmux app)\n       \
cmux keys use NAME[=VAR] [NAME --env VAR]... [--no-mask] -- CMD [ARGS...]\n       \
cmux keys write NAME --to TARGET...   TARGET: gh-secret:OWNER/REPO[@ENV]:SECRET, keychain:[OWNER/REPO:]SECRET, vault:VAR,\n                                         file:PATH, json:PATH#a.b, toml:PATH#a.b or env-file:PATH#VAR\n       \
cmux keys fill NAME [--tab TAB] --selector CSS [--type]\n       \
cmux keys rm NAME";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Put {
    pub name: String,
    pub purpose: Option<String>,
    pub hosts: Vec<String>,
    pub ttl: Option<Duration>,
    pub replace: bool,
    /// The agent that asked the person for it (`request`, recorded by the app).
    pub asked_by: Option<String>,
    /// The person pasted it in the app (`--from-person`, which only the app passes).
    pub from_person: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::cli) enum Format {
    Base64Url,
    Hex,
    Alnum,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Use {
    /// `(key name, env var)` pairs.
    pub keys: Vec<(String, String)>,
    pub mask: bool,
    pub argv: Vec<String>,
}

/// Where `write` copies a value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Target {
    /// A GitHub secret, a cloud secret or a machine vault entry; the store's prefix is the exact
    /// name.
    Store(Store),
    File(PathBuf),
    Json(PathBuf, Vec<String>),
    Toml(PathBuf, Vec<String>),
    EnvFile(PathBuf, String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Fill {
    pub name: String,
    pub tab: Option<String>,
    pub selector: String,
    /// Type key by key (`browser.page.type`) instead of setting the field (`browser.page.fill`).
    pub typing: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Local {
    Put(Put),
    Generate { put: Put, bytes: usize, format: Format },
    Request { put: Put, timeout: Duration },
    Use(Use),
    Write { name: String, targets: Vec<Target> },
    Fill(Fill),
}

/// The OS secret store. A trait so tests keep values in a map.
pub(in crate::cli) trait KeyVault {
    fn put(&self, item: &str, value: &str) -> Result<(), String>;
    fn get(&self, item: &str) -> Result<Option<Zeroizing<String>>, String>;
    fn delete(&self, item: &str) -> Result<(), String>;
}

/// The machine vault's OS store (`acpmux::vault::store::OsStore`): the login Keychain or the
/// Secret Service.
pub(in crate::cli) struct OsVault;

impl OsVault {
    fn store() -> Result<acpmux::vault::store::OsStore, String> {
        use acpmux::vault::store::SecretStore as _;
        let store = acpmux::vault::store::OsStore;
        if !store.available() {
            return Err("this machine has no OS secret store (a Mac's login Keychain, or the Secret Service with secret-tool on Linux): cmux keys keeps values nowhere else".into());
        }
        Ok(store)
    }
}

impl KeyVault for OsVault {
    fn put(&self, item: &str, value: &str) -> Result<(), String> {
        use acpmux::vault::store::SecretStore as _;
        Self::store()?
            .put(item, value)
            .map_err(|code| format!("the OS secret store refused: {code}"))
    }
    fn get(&self, item: &str) -> Result<Option<Zeroizing<String>>, String> {
        use acpmux::vault::store::SecretStore as _;
        Self::store()?.get(item).map_err(|code| format!("the OS secret store refused: {code}"))
    }
    fn delete(&self, item: &str) -> Result<(), String> {
        use acpmux::vault::store::SecretStore as _;
        Self::store()?.delete(item).map_err(|code| format!("the OS secret store refused: {code}"))
    }
}

/// The running cmux app's control socket. A trait so tests answer for the app.
pub(in crate::cli) trait App {
    /// `deadline: None` answers within the control plane's read timeout.
    fn call(
        &self,
        method: &str,
        params: Value,
        deadline: Option<Instant>,
    ) -> Result<Result<Value, Value>, String>;
}

pub(in crate::cli) struct LiveApp<'a>(pub &'a crate::cli::GlobalArgs);

impl App for LiveApp<'_> {
    fn call(
        &self,
        method: &str,
        params: Value,
        deadline: Option<Instant>,
    ) -> Result<Result<Value, Value>, String> {
        let mut stream = crate::cli::app::connect_command(self.0).map_err(|error| {
            error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the cmux app is not reachable")
                .to_owned()
        })?;
        match deadline {
            Some(deadline) => {
                crate::cli::app::request_by(&mut stream, method, params, None, Some(deadline))
            }
            None => {
                crate::cli::app::request(&mut stream, method, params, crate::cli::app::READ_TIMEOUT)
            }
        }
    }
}

fn check_value(value: &str) -> Result<(), String> {
    if value.chars().count() < MIN_VALUE_CHARS {
        return Err(format!(
            "the value is shorter than {MIN_VALUE_CHARS} characters: a key that short is not one, and masking it would garble output"
        ));
    }
    if value.len() > MAX_VALUE_BYTES {
        return Err(format!("the value is longer than {} KiB", MAX_VALUE_BYTES / 1024));
    }
    if value.contains('\0') {
        return Err("the value has a NUL byte: no env var or field can carry it".into());
    }
    Ok(())
}

/// A random value from the OS random source.
fn generate(bytes: usize, format: Format) -> Result<Zeroizing<String>, String> {
    use base64::Engine as _;
    let mut raw = Zeroizing::new(vec![0u8; bytes]);
    getrandom::fill(raw.as_mut_slice()).map_err(|e| format!("the OS random source failed: {e}"))?;
    Ok(Zeroizing::new(match format {
        Format::Base64Url => base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&*raw),
        Format::Hex => raw.iter().map(|b| format!("{b:02x}")).collect(),
        Format::Alnum => {
            // Rejection sampling: 62 symbols, so bytes of 248 and up are drawn again (no bias).
            const ALPHABET: &[u8] =
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
            let mut out = String::with_capacity(bytes);
            let mut pool = Zeroizing::new(vec![0u8; 64]);
            while out.len() < bytes {
                getrandom::fill(pool.as_mut_slice())
                    .map_err(|e| format!("the OS random source failed: {e}"))?;
                for &b in pool.iter().filter(|&&b| b < 248) {
                    if out.len() == bytes {
                        break;
                    }
                    if let Some(&symbol) = ALPHABET.get(usize::from(b % 62)) {
                        out.push(char::from(symbol));
                    }
                }
            }
            out
        }
    }))
}

pub(in crate::cli) fn is_local(record: &Value) -> bool {
    record.get("provider").and_then(Value::as_str) == Some("local")
}

/// The record's state now: `revoked`, `expired` or `live`.
pub(super) fn state(record: &Value, now: u64) -> &'static str {
    if record.get("revoked_at").is_some_and(|v| !v.is_null()) {
        "revoked"
    } else if record.get("expires_at_s").and_then(Value::as_u64).is_some_and(|at| at <= now) {
        "expired"
    } else {
        "live"
    }
}

/// What `ls` adds to every record so a list (the CLI's, Settings > Keys) reads them all alike.
pub(super) fn listed(record: &mut Value, now: u64) {
    let state = state(record, now);
    let Some(fields) = record.as_object_mut() else { return };
    fields.insert("state".into(), json!(state));
    if !fields.contains_key("label") {
        let label = match (fields.get("kind").and_then(Value::as_str), fields.get("name")) {
            (Some("r2"), _) => format!(
                "R2 {} ({})",
                fields.get("bucket").and_then(Value::as_str).unwrap_or("?"),
                fields.get("access").and_then(Value::as_str).unwrap_or("?")
            ),
            (_, Some(Value::String(name))) => name.clone(),
            _ => fields.get("id").and_then(Value::as_str).unwrap_or("?").to_owned(),
        };
        fields.insert("label".into(), json!(label));
    }
    for (key, default) in [
        ("source", json!(fields.get("provider").cloned().unwrap_or(Value::Null))),
        ("purpose", Value::Null),
        ("hosts", json!([])),
        ("stores", json!([])),
        ("uses", json!([])),
        ("asked_by", Value::Null),
        ("expires_at", Value::Null),
    ] {
        fields.entry(key).or_insert(default);
    }
}

/// Field `key` of `value`, or null: a read that cannot panic.
pub(in crate::cli) fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    value.get(key).unwrap_or(&NULL)
}

/// Sets field `key` of an object; anything that is not an object is left as it is.
pub(in crate::cli) fn set(value: &mut Value, key: &str, to: Value) {
    if let Some(fields) = value.as_object_mut() {
        fields.insert(key.to_owned(), to);
    }
}

/// The hosts a key is scoped to (none: any).
pub(in crate::cli) fn hosts_of(record: &Value) -> Vec<String> {
    field(record, "hosts")
        .as_array()
        .map(|h| h.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

pub(in crate::cli) fn array_mut<'a>(value: &'a mut Value, key: &str) -> Option<&'a mut Vec<Value>> {
    value.get_mut(key).and_then(Value::as_array_mut)
}

fn find_local<'a>(audit: &'a mut Value, name: &str) -> Option<&'a mut Value> {
    array_mut(audit, "keys")?
        .iter_mut()
        .find(|k| is_local(k) && k.get("name").and_then(Value::as_str) == Some(name))
}

/// Stores `value` under `put.name` and records it. `source`: stdin, generated or person.
fn store(
    paths: &Paths,
    vault: &dyn KeyVault,
    put: &Put,
    value: &str,
    source: &str,
) -> Result<Value, String> {
    check_value(value)?;
    let _lock = AuditLock::take(&paths.audit)?;
    let mut audit = read_audit(&paths.audit)?;
    let now = now_secs();
    if let Some(old) = find_local(&mut audit, &put.name)
        && state(old, now) == "live"
        && !put.replace
    {
        return Err(format!(
            "a key {} is already stored: give --replace to store a new value under that name, or pick another name",
            put.name
        ));
    }
    vault.put(&item(&put.name), value)?;
    let expires = put.ttl.map(|ttl| now + ttl.as_secs());
    let mut record = json!({
        "id": put.name,
        "name": put.name,
        "label": put.name,
        "provider": "local",
        "kind": "secret",
        "source": source,
        "purpose": put.purpose,
        "hosts": put.hosts,
        "created_at": rfc3339(now),
        "expires_at": expires.map(rfc3339),
        "expires_at_s": expires,
        "stores": [],
        "uses": [],
        "by": requester(),
        "asked_by": put.asked_by,
        "revoked_at": Value::Null,
    });
    let keys = array_mut(&mut audit, "keys").ok_or("bad audit")?;
    if let Some(index) = keys
        .iter()
        .position(|k| is_local(k) && k.get("name").and_then(Value::as_str) == Some(&put.name))
    {
        // A new value: copies written from the old one are listed until written again.
        let old = keys.remove(index);
        set(&mut record, "replaced_at", json!(rfc3339(now)));
        set(&mut record, "stale_stores", old.get("stores").cloned().unwrap_or(json!([])));
    }
    keys.push(record.clone());
    write_audit(&paths.audit, &audit)
        .map_err(|e| format!("{} is stored, but the audit was not written: {e}", put.name))?;
    listed(&mut record, now);
    Ok(record)
}

/// The live record and value of key `name`.
pub(in crate::cli) fn value_of(
    paths: &Paths,
    vault: &dyn KeyVault,
    name: &str,
) -> Result<(Value, Zeroizing<String>), String> {
    let mut audit = read_audit(&paths.audit)?;
    let record = find_local(&mut audit, name)
        .ok_or_else(|| format!("no key {name}: cmux keys put {name} (value on stdin), or cmux keys request {name} --purpose TEXT"))?
        .clone();
    match state(&record, now_secs()) {
        "revoked" => return Err(format!("key {name} was removed: put it again")),
        "expired" => {
            return Err(format!(
                "key {name} expired at {}: store a fresh value with cmux keys put {name} --replace",
                field(&record, "expires_at").as_str().unwrap_or("?")
            ));
        }
        _ => {}
    }
    let value = vault.get(&item(name))?.ok_or_else(|| {
        format!("key {name} is in the audit but its value is gone from the OS secret store: put it again with --replace")
    })?;
    Ok((record, value))
}

/// Notes that key `name` was entered at `target` (`uses`), or copied there (`stores`).
pub(in crate::cli) fn record(
    paths: &Paths,
    name: &str,
    target: &str,
    copy: bool,
) -> Result<(), String> {
    let _lock = AuditLock::take(&paths.audit)?;
    let mut audit = read_audit(&paths.audit)?;
    let now = now_secs();
    let Some(key) = find_local(&mut audit, name) else { return Ok(()) };
    if copy {
        let stores = array_mut(key, "stores").ok_or("bad audit record")?;
        if !stores.iter().any(|s| s == target) {
            stores.push(json!(target));
        }
        if let Some(stale) = key.get_mut("stale_stores").and_then(Value::as_array_mut) {
            stale.retain(|s| s != target);
        }
    }
    if !key.get("uses").is_some_and(Value::is_array) {
        set(key, "uses", json!([]));
    }
    let uses = array_mut(key, "uses").ok_or("bad audit record")?;
    match uses.iter_mut().find(|u| field(u, "target") == target) {
        Some(found) => {
            let count = field(found, "count").as_u64().unwrap_or(0).saturating_add(1);
            set(found, "count", json!(count));
            set(found, "last_used_at", json!(rfc3339(now)));
            set(found, "by", json!(requester()));
        }
        None => uses.push(
            json!({"target": target, "count": 1, "last_used_at": rfc3339(now), "by": requester()}),
        ),
    }
    if uses.len() > MAX_USES {
        uses.sort_by(|a, b| {
            field(b, "last_used_at").as_str().cmp(&field(a, "last_used_at").as_str())
        });
        uses.truncate(MAX_USES);
    }
    write_audit(&paths.audit, &audit)
}

/// Removes key `name`: its value leaves the OS store; the record stays, as revoked.
pub(super) fn revoke(paths: &Paths, vault: &dyn KeyVault, name: &str) -> Result<Value, String> {
    let _lock = AuditLock::take(&paths.audit)?;
    let mut audit = read_audit(&paths.audit)?;
    let key =
        find_local(&mut audit, name).ok_or_else(|| format!("no key {name} (cmux keys ls)"))?;
    vault.delete(&item(name))?;
    set(key, "revoked_at", json!(rfc3339(now_secs())));
    let stores = field(key, "stores").clone();
    write_audit(&paths.audit, &audit)?;
    Ok(json!({
        "removed": name,
        "copies_still_live": stores,
        "next": "the copies under copies_still_live hold the value still: rotate it at its provider",
    }))
}

/// Asks the person, in the cmux app, for key `put.name`; the app stores what they paste with
/// `cmux keys put --from-person` and answers once it is stored.
fn request(paths: &Paths, app: &dyn App, put: &Put, timeout: Duration) -> Result<Value, String> {
    let params = json!({
        "name": put.name,
        "purpose": put.purpose,
        "hosts": put.hosts,
        "ttl": put.ttl.map(|ttl| format!("{}m", ttl.as_secs() / 60)),
        "replace": put.replace,
        "requester": requester(),
    });
    let answer = app.call("keys.request", params, Some(Instant::now() + timeout))?;
    match answer {
        Ok(_) => {}
        Err(error) => {
            let code = error.get("code").and_then(Value::as_str).unwrap_or("");
            return Err(match code {
                "declined" => format!("the person declined to give {}", put.name),
                "cancelled" => format!("the ask for {} was replaced or cancelled", put.name),
                "timeout" => format!("no answer to the ask for {} within the timeout", put.name),
                "method_not_found" | "unknown_method" => {
                    format!(
                        "this cmux app shows no key asks: have the person run `cmux keys put {}` in a terminal and paste the key there",
                        put.name
                    )
                }
                _ => refusal("keys.request", &error),
            });
        }
    }
    let mut audit = read_audit(&paths.audit)?;
    let mut record = find_local(&mut audit, &put.name)
        .filter(|record| state(record, now_secs()) == "live")
        .cloned()
        .ok_or_else(|| format!("the app answered, but no live key {} is in the audit", put.name))?;
    listed(&mut record, now_secs());
    Ok(json!({"stored": record}))
}

/// Runs a command other than `use`.
pub(in crate::cli) fn run(
    command: Local,
    paths: &Paths,
    vault: &dyn KeyVault,
    sinks: &dyn Sinks,
    app: &dyn App,
    read: &dyn Fn(&str) -> Result<Zeroizing<String>, String>,
) -> Result<Value, String> {
    match command {
        Local::Put(put) => {
            let value = read(&put.name)?;
            let source = if put.from_person { "person" } else { "stdin" };
            store(paths, vault, &put, &value, source).map(|record| json!({"stored": record}))
        }
        Local::Generate { put, bytes, format } => {
            let value = generate(bytes, format)?;
            store(paths, vault, &put, &value, "generated").map(|record| json!({"stored": record}))
        }
        Local::Request { put, timeout } => request(paths, app, &put, timeout),
        Local::Write { name, targets } => write(paths, vault, sinks, &name, &targets),
        Local::Fill(spec) => fill(paths, vault, app, &spec),
        Local::Use(_) => Err("use runs a command: run_use".into()),
    }
}

#[cfg(test)]
#[path = "local_tests.rs"]
pub(in crate::cli) mod tests;
