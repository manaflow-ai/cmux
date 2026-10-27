//! Bind and the authenticated API client, over two small traits so tests
//! use a fake server and a memory store.

use crate::json::JsonField;
use std::collections::HashMap;

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::sender::{Answer, OpRequest};
use super::wire::{
    BIND_FILE, BOUND_FILE, Bound, DaemonInfo, INSTALL_KEY_FILE, VM_KIND_FILE, WG_KEY_FILE,
    parse_bind_file,
};

/// One JSON POST: `(status, body)`, or a transport error.
pub trait Http {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String>;
}

/// The agent's files (atomic writes with a mode).
pub trait Store {
    fn read(&self, file: &str) -> Option<String>;
    /// Whether an entry named `file` exists, readable or not. `Err` for any
    /// failure other than "not found".
    fn present(&self, file: &str) -> Result<bool, String>;
    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String>;
    /// Writes `file` only if no entry of that name exists, in one atomic step:
    /// `Ok(false)` when one does, which is then left as it is.
    fn create_new(&mut self, file: &str, text: &str, mode: u32) -> Result<bool, String>;
    fn remove(&mut self, file: &str);
}

/// Tests: also records each file's mode.
#[derive(Default, Debug)]
pub struct MemoryStore {
    files: HashMap<String, (String, u32)>,
    unreadable: std::collections::HashSet<String>,
}

impl MemoryStore {
    pub fn mode_of(&self, file: &str) -> Option<u32> {
        self.files.get(file).map(|(_, mode)| *mode)
    }

    /// Makes `file` fail to read or stat, as a permission or I/O error would.
    pub fn make_unreadable(&mut self, file: &str) {
        self.unreadable.insert(file.to_owned());
    }
}

impl Store for MemoryStore {
    fn read(&self, file: &str) -> Option<String> {
        if self.unreadable.contains(file) {
            return None;
        }
        self.files.get(file).map(|(text, _)| text.clone())
    }
    fn present(&self, file: &str) -> Result<bool, String> {
        if self.unreadable.contains(file) {
            return Err(format!("{file}: unreadable"));
        }
        Ok(self.files.contains_key(file))
    }
    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String> {
        self.files.insert(file.to_owned(), (text.to_owned(), mode));
        Ok(())
    }
    fn create_new(&mut self, file: &str, text: &str, mode: u32) -> Result<bool, String> {
        if self.unreadable.contains(file) || self.files.contains_key(file) {
            return Ok(false);
        }
        self.write(file, text, mode).map(|()| true)
    }
    fn remove(&mut self, file: &str) {
        self.files.remove(file);
    }
}

/// The install key and whether it was made now (a new instance id).
pub struct LoadedKey {
    pub key: InstallKey,
    pub rotated: bool,
}

/// The machine's install key, one per clone: a new metadata instance id
/// makes a new key. Stored 0600 as `{instance_id, pkcs8}` (base64url).
pub fn ensure_install_key(
    store: &mut dyn Store,
    instance_id: &str,
    rng: &SystemRandom,
) -> Result<LoadedKey, String> {
    if let Some(saved) = store.read(INSTALL_KEY_FILE) {
        let parsed: Value = serde_json::from_str(&saved).unwrap_or(Value::Null);
        if *parsed.field("instance_id") == instance_id
            && let Some(text) = parsed.field("pkcs8").as_str()
            && let Ok(key) = InstallKey::from_pkcs8_base64url(text, rng)
        {
            return Ok(LoadedKey { key, rotated: false });
        }
    }
    let key = InstallKey::generate(rng)?;
    let text = json!({ "instance_id": instance_id, "pkcs8": key.pkcs8_base64url() });
    store.write(INSTALL_KEY_FILE, &format!("{text}\n"), 0o600)?;
    Ok(LoadedKey { key, rotated: true })
}

/// The per-clone WireGuard key: kept for the same instance id, else made
/// by `generate` (`(private, public)`, base64) and stored 0600.
pub fn ensure_wg_key(
    store: &mut dyn Store,
    instance_id: &str,
    generate: impl FnOnce() -> Result<(String, String), String>,
) -> Result<String, String> {
    if let Some(saved) = store.read(WG_KEY_FILE) {
        let parsed: Value = serde_json::from_str(&saved).unwrap_or(Value::Null);
        if *parsed.field("instance_id") == instance_id
            && let Some(public) = parsed.field("public_key").as_str()
        {
            return Ok(public.to_owned());
        }
    }
    let (private, public) = generate()?;
    let text = json!({ "instance_id": instance_id, "private_key": private, "public_key": public });
    store.write(WG_KEY_FILE, &format!("{text}\n"), 0o600)?;
    Ok(public)
}

#[derive(Clone, Debug, PartialEq)]
pub enum BindResult {
    /// No `bind.json`.
    None,
    Bound(Box<Bound>),
    /// A final 4xx answer: the token is spent or invalid; `bind.json` is gone.
    Refused(String),
    /// `bind.json` did not parse; it is gone.
    Invalid(String),
    /// A network error, 429 or 5xx: `bind.json` stays for a retry.
    Retry(String),
}

impl BindResult {
    pub fn describe(&self) -> String {
        match self {
            BindResult::None => "none".to_owned(),
            BindResult::Bound(b) => format!("bound machine={} epoch={}", b.machine, b.epoch),
            BindResult::Refused(code) => format!("refused {code}"),
            BindResult::Invalid(why) => format!("invalid {why}"),
            BindResult::Retry(why) => format!("retry {why}"),
        }
    }
}

/// Spends `bind.json`'s one-time token: `POST {api_origin}/v1/cloud/bind`
/// with no bearer. `bound.json` (0600) is written before `bind.json` goes.
pub fn bind_machine(
    store: &mut dyn Store,
    http: &dyn Http,
    key: &InstallKey,
    wg_public_key: &str,
    daemon: &DaemonInfo,
    now_wall_ms: u64,
) -> BindResult {
    let Some(text) = store.read(BIND_FILE) else { return BindResult::None };
    let file = match parse_bind_file(&text) {
        Ok(file) => file,
        Err(why) => {
            store.remove(BIND_FILE);
            return BindResult::Invalid(why);
        }
    };
    let body = json!({
        "team": file.team,
        "machine": file.machine,
        "bind_token": file.bind_token,
        "wg_public_key": wg_public_key,
        "daemon": daemon.to_json(),
        "install_public_jwk": key.public_jwk(),
    });
    let (status, answer) =
        match http.post(&format!("{}/v1/cloud/bind", file.api_origin), &body, None) {
            Ok(answer) => answer,
            Err(e) => return BindResult::Retry(e),
        };
    if status >= 500 || status == 429 {
        return BindResult::Retry(format!("HTTP {status}"));
    }
    let value = answer.field("value");
    if status != 200 || *answer.field("ok") != true || !value.is_object() {
        store.remove(BIND_FILE);
        let code = answer
            .field("error")
            .field("code")
            .as_str()
            .map_or(format!("http.{status}"), str::to_owned);
        return BindResult::Refused(code);
    }
    let text = |v: &Value| v.as_str().unwrap_or("").to_owned();
    let bound = Bound {
        machine: text(value.field("machine")),
        team: file.team,
        host: text(value.field("host")),
        epoch: value.field("epoch").as_u64().unwrap_or(0),
        install: text(value.field("install").field("id")),
        user: text(value.field("install").field("user")),
        grant: text(value.field("install").field("grant")),
        env: file.env,
        api_origin: file.api_origin,
        keyset: value.field("keyset").clone(),
        bound_at: now_wall_ms,
    };
    let saved = serde_json::to_string(&bound).unwrap_or_default();
    if let Err(e) = store.write(BOUND_FILE, &format!("{saved}\n"), 0o600) {
        return BindResult::Retry(format!("bound.json write: {e}"));
    }
    // Best effort: the token is spent, so a retry would be refused and lose
    // bind.json. The agent tries again (and logs a failure) once bound and at
    // every restart (role.rs); each try keeps a record that is already there.
    let _ = record_owner_kind(store);
    store.remove(BIND_FILE);
    BindResult::Bound(Box::new(bound))
}

/// Records this machine as an owner VM ([`VM_KIND_FILE`]) when nothing has
/// recorded its kind yet and it is not a team VM (a team enroll or binding on
/// disk). The record is informational; acpmux no longer trusts it.
///
/// An existing record, whatever it holds and even if it cannot be read, is
/// kept: the Cloud backend writes the kind it assigned at create (web
/// services/vms/guestVmKind.ts), and the devbox's cmux-vm-kind-sync writes
/// the kind it fetched. A check that fails for any reason but "not found"
/// writes nothing. The write itself is a link that fails if a record appeared
/// after the check, so a writer that lands in between is never replaced.
pub fn record_owner_kind(store: &mut dyn Store) -> Result<(), String> {
    use crate::team_ssh::enroll::{TEAM_BOUND_FILE, TEAM_ENROLL_FILE};
    for file in [VM_KIND_FILE, TEAM_ENROLL_FILE, TEAM_BOUND_FILE] {
        if store.present(file)? {
            return Ok(());
        }
    }
    store.create_new(VM_KIND_FILE, "owner\n", 0o644).map(|_| ())
}

/// Tokens through `/v1/auth/challenge` + `/v1/auth/token` (signing the
/// server's prefix + nonce after checking the prefix names this
/// environment and install), then ops on `/v1/ops`.
pub struct CloudClient<H: Http> {
    http: H,
    bound: Bound,
    key: InstallKey,
    rng: SystemRandom,
    cached: Option<(String, u64)>,
}

impl<H: Http> CloudClient<H> {
    pub fn new(http: H, bound: Bound, key: InstallKey) -> CloudClient<H> {
        CloudClient { http, bound, key, rng: SystemRandom::new(), cached: None }
    }

    pub fn bound(&self) -> &Bound {
        &self.bound
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.bound.api_origin)
    }

    /// A bearer token, cached until one minute before it expires.
    /// `now_wall_ms` is wall-clock time (the server's `expires_at` is).
    pub fn token(&mut self, now_wall_ms: u64) -> Result<String, String> {
        if let Some((token, expires)) = &self.cached
            && expires.saturating_sub(60_000) > now_wall_ms
        {
            return Ok(token.clone());
        }
        let ids = json!({ "user": self.bound.user, "install": self.bound.install });
        let (status, challenge) = self.http.post(&self.url("/v1/auth/challenge"), &ids, None)?;
        let expected = format!(
            "cmux-auth-v1\n{}\n{}\n",
            self.bound.env.auth_environment(),
            self.bound.install
        );
        if status != 200 || *challenge.field("install") != self.bound.install.as_str() {
            return Err(format!("challenge refused: HTTP {status}"));
        }
        if *challenge.field("message_prefix") != expected.as_str() {
            return Err(
                "challenge message prefix names another environment or install; not signing"
                    .to_owned(),
            );
        }
        let nonce = match challenge.field("nonce") {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        let signature = self.key.sign(format!("{expected}{nonce}").as_bytes(), &self.rng)?;
        let body = json!({
            "user": self.bound.user,
            "install": self.bound.install,
            "nonce": challenge.field("nonce"),
            "signature": signature,
        });
        let (status, token) = self.http.post(&self.url("/v1/auth/token"), &body, None)?;
        let access = token.field("access_token").as_str();
        if status != 200 || *token.field("token_type") != "Bearer" || access.is_none() {
            let code = token.field("code").as_str().unwrap_or("");
            return Err(format!("token refused: HTTP {status} {code}"));
        }
        let access = access.unwrap_or_default().to_owned();
        let expires = token.field("expires_at").as_u64().unwrap_or(0);
        self.cached = Some((access.clone(), expires));
        Ok(access)
    }

    /// One read on `/v1/read` (`{op, params}`), with the same token
    /// handling as [`CloudClient::op`].
    pub fn read(&mut self, op: &str, params: &Value, now_wall_ms: u64) -> Answer {
        self.post_with_token("/v1/read", &json!({ "op": op, "params": params }), now_wall_ms)
    }

    fn post_with_token(&mut self, path: &str, body: &Value, now_wall_ms: u64) -> Answer {
        let url = self.url(path);
        let send = |client: &mut Self| -> Option<(u16, Value)> {
            let token = client.token(now_wall_ms).ok()?;
            client.http.post(&url, body, Some(&token)).ok()
        };
        let Some((mut status, mut answer)) = send(self) else { return Answer::Transport };
        if status == 401 || status == 403 {
            self.cached = None;
            let Some(again) = send(self) else { return Answer::Transport };
            (status, answer) = again;
        }
        Answer::Http { status, body: answer }
    }

    /// One JSON POST to `path` with the bearer token, the same token
    /// handling as [`CloudClient::op`] (the trajectory routes, `trajectory.rs`).
    pub fn post_json(&mut self, path: &str, body: &Value, now_wall_ms: u64) -> Answer {
        self.post_with_token(path, body, now_wall_ms)
    }

    /// A GitHub token for this machine (`POST /v1/integrations/github/token`
    /// as its `vm` install, the machine's team). Only a 401 or an `auth.*`
    /// 403 drops the cached bearer and retries once: a `policy.denied` is
    /// the answer, not a stale bearer.
    pub fn github_token(&mut self, ask: &super::github::TokenAsk, now_wall_ms: u64) -> Answer {
        let url = self.url(super::github::TOKEN_PATH);
        let body = ask.api_body(&self.bound.team);
        let send = |client: &mut Self| -> Option<(u16, Value)> {
            let token = client.token(now_wall_ms).ok()?;
            client.http.post(&url, &body, Some(&token)).ok()
        };
        let Some((mut status, mut answer)) = send(self) else { return Answer::Transport };
        let stale = status == 401
            || (status == 403
                && answer
                    .field("error")
                    .field("code")
                    .as_str()
                    .is_some_and(|c| c.starts_with("auth.")));
        if stale {
            self.cached = None;
            let Some(again) = send(self) else { return Answer::Transport };
            (status, answer) = again;
        }
        Answer::Http { status, body: answer }
    }

    /// One op on `/v1/ops`. A 401 or 403 drops the cached token and retries
    /// once.
    pub fn op(&mut self, request: &OpRequest, now_wall_ms: u64) -> Answer {
        let body = json!({ "op": request.op, "params": request.params });
        self.post_with_token("/v1/ops", &body, now_wall_ms)
    }
}
