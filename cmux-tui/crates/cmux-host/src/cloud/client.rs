//! Bind and the authenticated API client, over two small traits so tests
//! use a fake server and a memory store.

use crate::json::JsonField;
use std::collections::HashMap;

use cmux_server::cloud_http::RequestDeadline;

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde::Deserialize;
use serde_json::{Value, json};

use super::sender::{Answer, OpRequest};
use super::wire::{
    BIND_FILE, BIND_UNANSWERED_FILE, BOUND_FILE, Bound, DaemonInfo, INSTALL_KEY_FILE, VM_KIND_FILE,
    WG_KEY_FILE, parse_bind_file,
};

/// JSON HTTP operations: `(status, body)`, or a transport error.
pub trait Http {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String>;
    /// A POST with no body (the carrier ticket route refuses any body).
    /// Transports opt in; the default refuses.
    fn post_empty(&self, _url: &str, _bearer: Option<&str>) -> Result<(u16, Value), String> {
        Err("empty-body Cloud transport unavailable".into())
    }

    /// A raw GET (`body=None`) or JSON POST bounded by one continuous budget, no redirects.
    /// Transports opt in; the default refuses.
    fn request_with_deadline(
        &self,
        _url: &str,
        _body: Option<&Value>,
        _bearer: Option<&str>,
        _deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        Err("continuous Cloud transport unavailable".into())
    }

    /// [`Http::request_with_deadline`] with the response's `Retry-After`.
    /// A transport without headers answers none.
    fn request_with_headers(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<cmux_server::cloud_http::Response, String> {
        self.request_with_deadline(url, body, bearer, deadline).map(|(status, bytes)| {
            cmux_server::cloud_http::Response { status, retry_after: None, bytes }
        })
    }

    /// Optional for POST-only test transports; production implements both methods.
    fn get(&self, _url: &str, _bearer: Option<&str>) -> Result<(u16, Value), String> {
        Err("GET is not supported by this transport".to_owned())
    }

    /// Drops any pooled connection, so the next request dials a fresh one (after a pause, a pooled connection is
    /// dead and nothing says so). A transport with no pool does nothing.
    fn reset(&self) {}

    /// A transport like this one with a pool of its own, so a request on it
    /// never waits for one in flight here (a request from before a pause).
    /// `None` when the transport cannot make one.
    fn fresh(&self) -> Option<Self>
    where
        Self: Sized,
    {
        None
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
    /// A 4xx after an unanswered try of the same token, while the token may
    /// still live, is a `Retry` instead (see [`bind_machine`]).
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
/// `daemon_noise_key` (the session host's Noise static public key,
/// `daemon_noise_key.rs`) is sent only when given: a bind with a `carrier`
/// section. That section is kept as `carrier.json` (0600,
/// `carrier_entry.rs`) before `bound.json`; a bind without one leaves any
/// existing `carrier.json` as it is.
/// The bind as the Cloud role makes it: the updater's connect hold first, so
/// the machine's first link is never cut by an update's restart, then the
/// request. A person's machine from this bind on, and the supervisor's
/// `Bound` (an instance id change) does not cover a bind of the same machine.
/// The hold is the state dir's restart gate (`updater/gate.rs`), which every
/// flip and restart goes through in whichever process runs it: either the
/// flip sees this hold, or a restart was queued first and this answers None
/// with `bind.json` left for the restarted service.
#[allow(clippy::too_many_arguments)]
pub fn hold_then_bind(
    paths: &crate::config::Paths,
    store: &mut dyn Store,
    http: &dyn Http,
    key: &InstallKey,
    wg_public_key: &str,
    daemon: &DaemonInfo,
    daemon_noise_key: Option<&str>,
    now_wall_ms: u64,
) -> Option<BindResult> {
    #[cfg(unix)]
    if !crate::updater::gate::hold_connects(
        paths,
        now_wall_ms,
        crate::updater::gate::HoldKind::Connect,
    ) {
        return None;
    }
    #[cfg(not(unix))]
    let _ = paths;
    Some(bind_machine(store, http, key, wg_public_key, daemon, daemon_noise_key, now_wall_ms))
}

pub fn bind_machine(
    store: &mut dyn Store,
    http: &dyn Http,
    key: &InstallKey,
    wg_public_key: &str,
    daemon: &DaemonInfo,
    daemon_noise_key: Option<&str>,
    now_wall_ms: u64,
) -> BindResult {
    let Some(text) = store.read(BIND_FILE) else { return BindResult::None };
    let file = match parse_bind_file(&text) {
        Ok(file) => file,
        Err(why) => {
            store.remove(BIND_FILE);
            store.remove(BIND_UNANSWERED_FILE);
            return BindResult::Invalid(why);
        }
    };
    let mut body = json!({
        "team": file.team,
        "machine": file.machine,
        "bind_token": file.bind_token,
        "wg_public_key": wg_public_key,
        "daemon": daemon.to_json(),
        "install_public_jwk": key.public_jwk(),
    });
    if let (Some(noise_key), Some(fields)) = (daemon_noise_key, body.as_object_mut()) {
        fields.insert("daemon_noise_key".to_owned(), json!(noise_key));
    }
    let (status, answer) =
        match http.post(&format!("{}/v1/cloud/bind", file.api_origin), &body, None) {
            Ok(answer) => answer,
            Err(e) => {
                note_unanswered(store, &file.bind_token, now_wall_ms);
                return BindResult::Retry(e);
            }
        };
    if status >= 500 || status == 429 {
        note_unanswered(store, &file.bind_token, now_wall_ms);
        return BindResult::Retry(format!("HTTP {status}"));
    }
    let value = answer.field("value");
    if status != 200 || *answer.field("ok") != true || !value.is_object() {
        let code = answer
            .field("error")
            .field("code")
            .as_str()
            .map_or(format!("http.{status}"), str::to_owned);
        // An earlier try may have reached the platform and spent the token
        // with only its answer lost; this refusal may then be the replay
        // racing that bind's commit (hq#7542). Removing bind.json here would
        // leave the machine never bound, so keep it while the token can live.
        if unanswered_since(store, &file.bind_token)
            .is_some_and(|at| now_wall_ms.saturating_sub(at) < BIND_TOKEN_LIFE_MS)
        {
            return BindResult::Retry(format!("refused {code} after an unanswered try"));
        }
        store.remove(BIND_FILE);
        store.remove(BIND_UNANSWERED_FILE);
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
    // The carrier goes down before bound.json, so a bound machine never
    // lacks the route its bind sent; the session host respawns on it.
    if let Some(route) = file.carrier {
        let carrier = crate::carrier_entry::CarrierFile {
            route,
            team: bound.team.clone(),
            issuer: bound.env.grant_issuer(),
            keyset: bound.keyset.clone(),
        };
        let text = format!("{}\n", carrier.to_json());
        if let Err(e) = store.write(crate::carrier_entry::CARRIER_FILE, &text, 0o600) {
            return BindResult::Retry(format!("carrier.json write: {e}"));
        }
    }
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
    store.remove(BIND_UNANSWERED_FILE);
    BindResult::Bound(Box::new(bound))
}

/// How long a bind token can live: it expires 15 minutes after the machine
/// runs, which is before any try of it was sent.
const BIND_TOKEN_LIFE_MS: u64 = super::daemon_noise_key::WAIT_DEADLINE_MS;

fn token_digest(token: &str) -> String {
    use base64::Engine as _;
    use sha2::Digest as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(token.as_bytes()))
}

/// Records the first unanswered try of `token`; a later one keeps that time.
/// Best effort: without the record a later refusal is final, as before.
fn note_unanswered(store: &mut dyn Store, token: &str, now_wall_ms: u64) {
    if unanswered_since(store, token).is_some() {
        return;
    }
    let text = json!({ "token": token_digest(token), "at": now_wall_ms });
    let _ = store.write(BIND_UNANSWERED_FILE, &format!("{text}\n"), 0o600);
}

/// When a try of `token` first went unanswered, if one did.
fn unanswered_since(store: &dyn Store, token: &str) -> Option<u64> {
    let saved: Value = serde_json::from_str(&store.read(BIND_UNANSWERED_FILE)?).ok()?;
    if saved.get("token")?.as_str()? != token_digest(token) {
        return None;
    }
    saved.get("at")?.as_u64()
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

    /// The next request (a bearer mint included) goes on a fresh connection: see [`Http::reset`].
    pub fn reset_transport(&self) {
        self.http.reset();
    }

    /// A client for the same machine, key and bearer on a transport of its
    /// own ([`Http::fresh`]), for a request that must not wait for one in
    /// flight on this client.
    pub fn fresh(&self) -> Option<CloudClient<H>> {
        let http = self.http.fresh()?;
        let key = InstallKey::from_pkcs8(self.key.pkcs8(), &self.rng).ok()?;
        let mut client = CloudClient::new(http, self.bound.clone(), key);
        client.cached = self.cached.clone();
        Some(client)
    }

    pub(super) fn url(&self, path: &str) -> String {
        format!("{}{path}", self.bound.api_origin)
    }

    /// A bearer token, cached until one minute before it expires.
    /// `now_wall_ms` is wall-clock time (the server's `expires_at` is).
    pub fn token(&mut self, now_wall_ms: u64) -> Result<String, String> {
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
        let (status, challenge): (_, Challenge) = self.auth_post("/v1/auth/challenge", &ids)?;
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
        let (status, token): (_, Token) = self.auth_post("/v1/auth/token", &body)?;
        // A team SSH binding (team_ssh::sync::client_bound) records no grant,
        // so it pins user, install and team only.
        let grant_ok = self.bound.grant.is_empty() || token.grant == self.bound.grant;
        if status != 200
            || token.token_type != "Bearer"
            || token.user != self.bound.user
            || token.install != self.bound.install
            || !grant_ok
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
    ) -> Result<(u16, T), String> {
        let malformed = || "Cloud authentication unavailable".to_owned();
        let (status, value) =
            self.http.post(&self.url(path), body, None).map_err(|_| malformed())?;
        Ok((status, serde_json::from_value(value).map_err(|_| malformed())?))
    }

    /// A bounded GET with the response's `Retry-After` (the carrier keyset fetch): only to the
    /// bound environment's own API origin, and at most 1 MiB.
    pub(super) fn request_with_headers(
        &self,
        path: &str,
        deadline: &RequestDeadline,
    ) -> Result<cmux_server::cloud_http::Response, String> {
        if self.bound.api_origin != self.bound.env.api_origin() || deadline.remaining().is_none() {
            return Err("bounded Cloud request unavailable".into());
        }
        let response = self
            .http
            .request_with_headers(&self.url(path), None, None, deadline)
            .map_err(|_| "bounded Cloud request unavailable".to_owned())?;
        if response.bytes.len() > 1024 * 1024 || deadline.remaining().is_none() {
            return Err("bounded Cloud response unavailable".into());
        }
        Ok(response)
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

    /// One authenticated POST to `path` with no request body.
    fn post_empty_with_token(&mut self, path: &str, now_wall_ms: u64) -> Answer {
        let url = self.url(path);
        let send = |client: &mut Self| -> Option<(u16, Value)> {
            let token = client.token(now_wall_ms).ok()?;
            client.http.post_empty(&url, Some(&token)).ok()
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

    /// The person's connected GitHub account (`GET /v1/me/github` as this
    /// machine), checked so the reply never holds a token.
    /// A relay Register ticket for this machine's carrier slot
    /// (`carrier_ticket.rs`): the machine names itself; the caller nothing.
    pub fn carrier_ticket(&mut self, now_wall_ms: u64) -> Value {
        let path = super::carrier_ticket::path(&self.bound.machine);
        let answer = self.post_empty_with_token(&path, now_wall_ms);
        super::carrier_ticket::reply_for(&answer)
    }

    pub fn github_status(&mut self, now_wall_ms: u64) -> Value {
        let answer = self.github_repos_get(super::github_status::STATUS_PATH, now_wall_ms);
        super::github_status::reply_for(&answer)
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
