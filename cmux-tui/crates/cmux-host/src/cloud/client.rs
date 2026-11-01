//! Bind and the authenticated API client, over two small traits so tests
//! use a fake server and a memory store.

use crate::json::JsonField;
use std::collections::HashMap;
use std::time::Instant;

use cmux_server::cloud_http::RequestDeadline;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde::Deserialize;
use serde_json::{Value, json};

use super::sender::{Answer, OpRequest};
use super::wire::{
    BIND_FILE, BOUND_FILE, Bound, DaemonInfo, INSTALL_KEY_FILE, VM_KIND_FILE, WG_KEY_FILE,
    parse_bind_file,
};

/// JSON HTTP operations: `(status, body)`, or a transport error.
pub trait Http {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String>;

    /// Raw, bounded, no-redirect GET (`body=None`) or JSON POST. All calls
    /// in a receiving-policy read share this absolute deadline. Older
    /// transports cannot silently opt into this security-sensitive path.
    fn request_until(
        &self,
        _url: &str,
        _body: Option<&Value>,
        _bearer: Option<&str>,
        _deadline: Instant,
    ) -> Result<(u16, Vec<u8>), String> {
        Err("bounded Cloud transport unavailable".into())
    }

    /// Explicit continuous budget. Legacy transports must opt in rather than
    /// silently inheriting an active-clock timeout for original VM authority.
    fn request_with_deadline(
        &self,
        _url: &str,
        _body: Option<&Value>,
        _bearer: Option<&str>,
        _deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        Err("continuous Cloud transport unavailable".into())
    }

    /// Optional for POST-only test transports; production implements both methods.
    fn get(&self, _url: &str, _bearer: Option<&str>) -> Result<(u16, Value), String> {
        Err("GET is not supported by this transport".to_owned())
    }
}

#[derive(Deserialize)]
struct Challenge {
    install: String,
    nonce: String,
    message_prefix: String,
}

#[derive(Deserialize)]
struct Token {
    access_token: String,
    token_type: String,
    expires_at: u64,
    user: String,
    install: String,
    grant: String,
    team: String,
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
    // The new identity IPC stays unavailable if the receipt cannot be saved.
    // Do not retry a spent bind token or disturb the ordinary bound machine.
    if crate::identity::record(store, &bound.machine, key).is_err() {
        store.remove(crate::identity::RECEIPT);
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

    pub(super) fn url(&self, path: &str) -> String {
        format!("{}{path}", self.bound.api_origin)
    }

    /// A bearer token, cached until one minute before it expires.
    /// `now_wall_ms` is wall-clock time (the server's `expires_at` is).
    pub fn token(&mut self, now_wall_ms: u64) -> Result<String, String> {
        self.token_until(now_wall_ms, None)
    }

    pub(super) fn token_until(
        &mut self,
        now_wall_ms: u64,
        deadline: Option<&RequestDeadline>,
    ) -> Result<String, String> {
        if deadline.is_some_and(|budget| budget.remaining().is_none()) {
            return Err("bounded Cloud authentication unavailable".into());
        }
        if self.bound.api_origin != self.bound.env.api_origin() {
            self.cached = None;
            return Err("Cloud origin differs from the original environment".into());
        }
        if let Some((token, expires)) = &self.cached
            && expires.saturating_sub(60_000) > now_wall_ms
        {
            return Ok(token.clone());
        }
        let ids = json!({ "user": self.bound.user, "install": self.bound.install });
        let (status, challenge): (_, Challenge) =
            self.auth_post("/v1/auth/challenge", &ids, deadline)?;
        let expected = format!(
            "cmux-auth-v1\n{}\n{}\n",
            self.bound.env.auth_environment(),
            self.bound.install
        );
        if status != 200 || challenge.install != self.bound.install {
            return Err(format!("challenge refused: HTTP {status}"));
        }
        if challenge.message_prefix != expected {
            return Err(
                "challenge message prefix names another environment or install; not signing"
                    .to_owned(),
            );
        }
        let nonce = challenge.nonce;
        if nonce.is_empty() || nonce.len() > 256 || nonce.bytes().any(|b| !b.is_ascii_graphic()) {
            return Err("invalid Cloud challenge".into());
        }
        let signature = self.key.sign(format!("{expected}{nonce}").as_bytes(), &self.rng)?;
        let body = json!({
            "user": self.bound.user,
            "install": self.bound.install,
            "nonce": nonce,
            "signature": signature,
        });
        let (status, token): (_, Token) = self.auth_post("/v1/auth/token", &body, deadline)?;
        if status != 200
            || token.token_type != "Bearer"
            || token.user != self.bound.user
            || token.install != self.bound.install
            || token.grant != self.bound.grant
            || token.team != self.bound.team
            || token.access_token.is_empty()
            || token.access_token.len() > 8192
            || token.access_token.bytes().any(|b| !b.is_ascii_graphic())
            || token.expires_at == 0
            || token.expires_at > 9_007_199_254_740_991
        {
            self.cached = None;
            return Err("Cloud token differs from the original enrollment".into());
        }
        let access = token.access_token;
        self.cached = Some((access.clone(), token.expires_at));
        Ok(access)
    }

    fn auth_post<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        body: &Value,
        deadline: Option<&RequestDeadline>,
    ) -> Result<(u16, T), String> {
        let malformed = || "Cloud authentication unavailable".to_owned();
        if let Some(deadline) = deadline {
            let (status, bytes) = self.request_until(path, Some(body), None, deadline)?;
            Ok((status, serde_json::from_slice(&bytes).map_err(|_| malformed())?))
        } else {
            let (status, value) =
                self.http.post(&self.url(path), body, None).map_err(|_| malformed())?;
            Ok((status, serde_json::from_value(value).map_err(|_| malformed())?))
        }
    }

    pub(super) fn request_until(
        &self,
        path: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        if self.bound.api_origin != self.bound.env.api_origin() || deadline.remaining().is_none() {
            return Err("bounded Cloud request unavailable".into());
        }
        let result = self
            .http
            .request_with_deadline(&self.url(path), body, bearer, deadline)
            .map_err(|_| "bounded Cloud request unavailable".to_owned())?;
        if result.1.len() > 1024 * 1024 || deadline.remaining().is_none() {
            return Err("bounded Cloud response unavailable".into());
        }
        Ok(result)
    }

    pub(super) fn install_public_jwk(&self) -> Value {
        self.key.public_jwk()
    }

    pub(super) fn clear_token(&mut self) {
        self.cached = None;
    }

    /// Drops the cached bearer (another origin refused it), so the next
    /// [`CloudClient::token`] asks for a new one.
    pub fn forget_token(&mut self) {
        self.cached = None;
    }

    /// One read on `/v1/read` (`{op, params}`), with the same token
    /// handling as [`CloudClient::op`].
    pub fn read(&mut self, op: &str, params: &Value, now_wall_ms: u64) -> Answer {
        if op == "cloud.vm.network_policy" {
            return Answer::Transport;
        }
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

    /// A connector read against the environment's platform, authenticated as
    /// this machine. Neither origin nor team is taken from the socket caller.
    fn github_repos_get(&mut self, path: &str, now_wall_ms: u64) -> Answer {
        let url = format!("{}{}", self.bound.env.platform_origin(), path);
        let send = |client: &mut Self| -> Option<(u16, Value)> {
            let token = client.token(now_wall_ms).ok()?;
            client.http.get(&url, Some(&token)).ok()
        };
        let Some((mut status, mut body)) = send(self) else { return Answer::Transport };
        if status == 401 {
            self.cached = None;
            let Some(again) = send(self) else { return Answer::Transport };
            (status, body) = again;
        }
        Answer::Http { status, body }
    }

    pub fn github_repos(&mut self, ask: &super::github_repos::ReposAsk, now_wall_ms: u64) -> Value {
        let team = self.bound.team.clone();
        super::github_repos::answer(ask, &team, |path| self.github_repos_get(path, now_wall_ms))
    }

    /// A GitHub token for this machine (`POST /v1/integrations/github/token`
    /// as its `vm` install, the machine's team).
    pub fn github_token(&mut self, ask: &super::github::TokenAsk, now_wall_ms: u64) -> Answer {
        let body = ask.api_body(&self.bound.team);
        self.post_as_install(super::github::TOKEN_PATH, &body, now_wall_ms)
    }

    /// A hand-off report for one of this machine's sessions (`POST
    /// /v1/handoffs/<id>/report` as its `vm` install). The hand-off is named
    /// from the install's user and the session, as the store names it.
    pub fn handoff_report(
        &mut self,
        report: &super::handoff::HandoffReport,
        now_wall_ms: u64,
    ) -> (String, Answer) {
        let id = super::handoff::handoff_id(&self.bound.user, &report.session);
        let answer = self.post_as_install(
            &super::handoff::report_path(&id),
            &report.api_body(),
            now_wall_ms,
        );
        (id, answer)
    }

    /// One POST as the `vm` install. Only a 401 or an `auth.*` 403 drops the
    /// cached bearer and retries once: a `policy.denied` is the answer, not
    /// a stale bearer.
    fn post_as_install(&mut self, path: &str, body: &Value, now_wall_ms: u64) -> Answer {
        let url = self.url(path);
        let send = |client: &mut Self| -> Option<(u16, Value)> {
            let token = client.token(now_wall_ms).ok()?;
            client.http.post(&url, body, Some(&token)).ok()
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
