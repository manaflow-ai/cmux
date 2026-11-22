//! Bind and the authenticated API client, over two small traits so tests
//! use a fake server and a memory store.

use std::collections::HashMap;

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::sender::{Answer, OpRequest};
use super::wire::{
    BIND_FILE, BOUND_FILE, Bound, DaemonInfo, INSTALL_KEY_FILE, WG_KEY_FILE, parse_bind_file,
};

/// One JSON POST: `(status, body)`, or a transport error.
pub trait Http {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String>;
}

/// The agent's files (atomic writes with a mode).
pub trait Store {
    fn read(&self, file: &str) -> Option<String>;
    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String>;
    fn remove(&mut self, file: &str);
}

/// Tests: also records each file's mode.
#[derive(Default, Debug)]
pub struct MemoryStore {
    files: HashMap<String, (String, u32)>,
}

impl MemoryStore {
    pub fn mode_of(&self, file: &str) -> Option<u32> {
        self.files.get(file).map(|(_, mode)| *mode)
    }
}

impl Store for MemoryStore {
    fn read(&self, file: &str) -> Option<String> {
        self.files.get(file).map(|(text, _)| text.clone())
    }
    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String> {
        self.files.insert(file.to_owned(), (text.to_owned(), mode));
        Ok(())
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
        if parsed["instance_id"] == instance_id
            && let Some(text) = parsed["pkcs8"].as_str()
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
        if parsed["instance_id"] == instance_id
            && let Some(public) = parsed["public_key"].as_str()
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
    let value = &answer["value"];
    if status != 200 || answer["ok"] != true || !value.is_object() {
        store.remove(BIND_FILE);
        let code = answer["error"]["code"].as_str().map_or(format!("http.{status}"), str::to_owned);
        return BindResult::Refused(code);
    }
    let text = |v: &Value| v.as_str().unwrap_or("").to_owned();
    let bound = Bound {
        machine: text(&value["machine"]),
        team: file.team,
        host: text(&value["host"]),
        epoch: value["epoch"].as_u64().unwrap_or(0),
        install: text(&value["install"]["id"]),
        user: text(&value["install"]["user"]),
        grant: text(&value["install"]["grant"]),
        env: file.env,
        api_origin: file.api_origin,
        keyset: value["keyset"].clone(),
        bound_at: now_wall_ms,
    };
    let saved = serde_json::to_string(&bound).unwrap_or_default();
    if let Err(e) = store.write(BOUND_FILE, &format!("{saved}\n"), 0o600) {
        return BindResult::Retry(format!("bound.json write: {e}"));
    }
    store.remove(BIND_FILE);
    BindResult::Bound(Box::new(bound))
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
        if status != 200 || challenge["install"] != self.bound.install.as_str() {
            return Err(format!("challenge refused: HTTP {status}"));
        }
        if challenge["message_prefix"] != expected.as_str() {
            return Err(
                "challenge message prefix names another environment or install; not signing"
                    .to_owned(),
            );
        }
        let nonce = match &challenge["nonce"] {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        let signature = self.key.sign(format!("{expected}{nonce}").as_bytes(), &self.rng)?;
        let body = json!({
            "user": self.bound.user,
            "install": self.bound.install,
            "nonce": challenge["nonce"],
            "signature": signature,
        });
        let (status, token) = self.http.post(&self.url("/v1/auth/token"), &body, None)?;
        let access = token["access_token"].as_str();
        if status != 200 || token["token_type"] != "Bearer" || access.is_none() {
            let code = token["code"].as_str().unwrap_or("");
            return Err(format!("token refused: HTTP {status} {code}"));
        }
        let access = access.unwrap_or_default().to_owned();
        let expires = token["expires_at"].as_u64().unwrap_or(0);
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

    /// One op on `/v1/ops`. A 401 or 403 drops the cached token and retries
    /// once.
    pub fn op(&mut self, request: &OpRequest, now_wall_ms: u64) -> Answer {
        let body = json!({ "op": request.op, "params": request.params });
        self.post_with_token("/v1/ops", &body, now_wall_ms)
    }
}
