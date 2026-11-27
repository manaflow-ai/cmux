//! The install principal's token mint and revoke as a step machine, moved from the Mac's Swift
//! `InstallAuthClient` (CmuxInstallAuthCore): events in, one effect out. The app keeps the
//! I/O (the HTTP exchange, the Secure Enclave signer, the Stack session, the Keychain record,
//! the one shared in-flight mint and its cancellation); every rule of the exchange is here:
//! which request comes next, what each answer must say, which refusals recover and how long a
//! token is trusted.
//!
//! A mint: `user.ensure` and `install.register` when there is no record (the Stack session's),
//! then `/v1/auth/challenge`, the signature over `message_prefix + nonce`, `/v1/auth/token`.
//! Only the exact expected environment, install and team context is signed. A personal mint
//! refused `auth.forbidden` (a revoked install) rotates the key, forgets the record and mints
//! once more; a register refused because the key is already held rotates once.
//!
//! The app asks it over the app FFI (`cloud_identity_install_auth_step`).

use std::collections::BTreeMap;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};
use unicode_segmentation::UnicodeSegmentation as _;

/// Refresh this long before the token expires, in milliseconds.
pub const REFRESH_MARGIN_MS: f64 = 60_000.0;
/// Never trust a token longer than this (device clock skew), in milliseconds.
pub const MAXIMUM_LIFETIME_MS: f64 = 540_000.0;
/// The header the owner's version gate reads (token mint and wire connects).
pub const CLIENT_VERSION_HEADER: &str = "x-cmux-client-version";

/// What the install keeps between launches (never the token).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub user: String,
    pub install: String,
}

/// What an install registers as: its kind, display name, platform and the op classes it asks
/// for (never `execute` for ios or mac), and the device name when the system gives none.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub kind: String,
    pub name: String,
    pub platform: String,
    pub op_classes: Vec<String>,
    pub fallback_device_name: String,
}

impl Profile {
    /// The iPhone app: never `execute`; `cloud-link` lets it mint Cloud link tokens.
    #[must_use]
    pub fn ios() -> Self {
        Self::new("ios", "cmux iOS", "ios", &["read", "mutate-own", "cloud-link"], "iPhone")
    }

    /// The cmux Mac app: the phone grant plus `mutate-shared`; never `execute`.
    #[must_use]
    pub fn mac() -> Self {
        Self::new(
            "mac",
            "cmux",
            "macos",
            &["read", "mutate-own", "mutate-shared", "cloud-link"],
            "Mac",
        )
    }

    fn new(kind: &str, name: &str, platform: &str, classes: &[&str], fallback: &str) -> Self {
        Self {
            kind: kind.into(),
            name: name.into(),
            platform: platform.into(),
            op_classes: classes.iter().map(|class| (*class).to_owned()).collect(),
            fallback_device_name: fallback.into(),
        }
    }
}

/// Why a mint or revoke failed. Never carries a token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "error", rename_all = "snake_case")]
pub enum Error {
    InvalidPublicKey,
    NoSession,
    Refused {
        code: String,
    },
    /// The owner sent a challenge (or a token) this client will not sign (or keep).
    UnexpectedChallenge,
    /// `user.ensure` answered for a different Stack user than the session's.
    UserMismatch,
    /// The request to `path` got no HTTP answer; `url_error_code` is the transport's
    /// `URLError` code when it threw one.
    Transport {
        path: String,
        url_error_code: Option<i64>,
    },
    MalformedReply,
    /// The team requires a newer app; the key and record stay.
    ClientTooOld {
        minimum_version: Option<String>,
    },
}

impl Error {
    fn refused(code: impl Into<String>) -> Self {
        Self::Refused { code: code.into() }
    }
}

/// What the app does next.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Effect {
    /// Read the Stack session token; answer [`Event::Session`].
    SessionToken,
    /// Read the install key's uncompressed public point; answer [`Event::PublicKey`].
    PublicKey,
    /// Sign `message` (UTF-8) with the install key; answer [`Event::Signature`].
    Sign {
        message: String,
    },
    /// Replace the install key; answer [`Event::Rotated`].
    Rotate,
    /// POST `body` (JSON) to `path` of the API Worker; answer [`Event::Http`] or
    /// [`Event::TransportError`].
    Post {
        path: String,
        body: String,
        bearer: Option<String>,
        headers: BTreeMap<String, String>,
    },
    /// Keep (or forget, `null`) the record; answer [`Event::Saved`].
    SaveRecord {
        record: Option<Record>,
    },
    /// Minted: keep the token until `expires_at_ms` and the learned environment.
    Done {
        token: String,
        environment: String,
        expires_at_ms: f64,
    },
    /// Revoke finished. `revoked`: the owner revoked the install, so the app forgets the
    /// token and the record and rotates the key; false when there was no record.
    Revoked {
        revoked: bool,
    },
    Fail(Error),
}

/// What the app answers an effect with, or how it starts the machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    Start(Start),
    Session {
        token: String,
    },
    /// Standard base64 of the X9.63 point.
    PublicKey {
        x963: String,
    },
    /// Standard base64 of the signer's signature (raw r||s or DER), sent as is.
    Signature {
        signature: String,
    },
    Rotated,
    Saved,
    Http {
        status: u16,
        body: String,
    },
    TransportError {
        url_error_code: Option<i64>,
    },
}

/// One client's fixed facts and its current record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Start {
    /// `mint` or `revoke`.
    pub mode: Mode,
    pub stack_user: String,
    #[serde(default)]
    pub team: Option<String>,
    /// The environment this client already learned or was pinned to.
    #[serde(default)]
    pub environment: Option<String>,
    pub device_name: String,
    pub profile: Profile,
    #[serde(default)]
    pub client_version: Option<String>,
    #[serde(default)]
    pub record: Option<Record>,
    pub has_session: bool,
    /// Fresh ids for the `user.ensure` idempotency keys: one per attempt (a recovered mint
    /// registers again).
    pub fresh_ids: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Mint,
    Revoke,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Session,
    UserEnsure,
    PublicKey,
    Register,
    RotateForRegister,
    RotateForRecovery,
    SaveRecord,
    ForgetRecord,
    Challenge,
    Signing,
    Token,
    Revoke,
    Over,
}

/// The machine's state between steps; the app keeps it opaque.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    start: Start,
    phase: Phase,
    recovered: bool,
    attempts: u8,
    session: Option<String>,
    user_id: Option<String>,
    nonce: Option<String>,
    prefix: Option<String>,
    named: Option<String>,
}

/// One step: the next state and the effect to perform. `state` is `None` only for
/// [`Event::Start`]. An event the phase does not expect fails closed with
/// [`Error::MalformedReply`].
#[must_use]
pub fn step(state: Option<State>, event: Event, now_ms: f64) -> (Option<State>, Effect) {
    match (state, event) {
        (_, Event::Start(start)) => {
            let mut state = State {
                start,
                phase: Phase::Over,
                recovered: false,
                attempts: 0,
                session: None,
                user_id: None,
                nonce: None,
                prefix: None,
                named: None,
            };
            let effect = match state.start.mode {
                Mode::Mint => state.begin_mint(),
                Mode::Revoke => state.begin_revoke(),
            };
            state.finish(effect)
        }
        (Some(mut state), event) => {
            let effect = state.on(event, now_ms);
            state.finish(effect)
        }
        (None, _) => (None, Effect::Fail(Error::MalformedReply)),
    }
}

impl State {
    fn finish(mut self, effect: Result<Effect, Error>) -> (Option<State>, Effect) {
        let effect = match effect {
            Ok(effect) => effect,
            Err(error) => self.recover(error),
        };
        if matches!(effect, Effect::Fail(_) | Effect::Done { .. } | Effect::Revoked { .. }) {
            self.phase = Phase::Over;
        }
        (Some(self), effect)
    }

    /// The personal sign-in path recovers a revoked install once. A team refusal preserves
    /// the key and record.
    fn recover(&mut self, error: Error) -> Effect {
        let forbidden = error == Error::refused("auth.forbidden");
        if forbidden
            && self.start.mode == Mode::Mint
            && self.start.team.is_none()
            && !self.recovered
        {
            self.recovered = true;
            self.phase = Phase::RotateForRecovery;
            return Effect::Rotate;
        }
        Effect::Fail(error)
    }

    fn begin_mint(&mut self) -> Result<Effect, Error> {
        if self.start.team.as_deref().is_some_and(|team| !crate::identity::is_team(team)) {
            return Err(Error::UnexpectedChallenge);
        }
        if self.start.record.is_some() {
            return Ok(self.challenge());
        }
        self.ask_session()
    }

    fn begin_revoke(&mut self) -> Result<Effect, Error> {
        if self.start.record.is_none() {
            return Ok(Effect::Revoked { revoked: false });
        }
        self.ask_session()
    }

    fn ask_session(&mut self) -> Result<Effect, Error> {
        if !self.start.has_session {
            return Err(Error::NoSession);
        }
        self.phase = Phase::Session;
        Ok(Effect::SessionToken)
    }

    fn on(&mut self, event: Event, now_ms: f64) -> Result<Effect, Error> {
        match (self.phase, event) {
            (Phase::Session, Event::Session { token }) => {
                self.session = Some(token);
                if self.start.mode == Mode::Revoke {
                    let install = self.record()?.install;
                    self.phase = Phase::Revoke;
                    return Ok(self.op(
                        "install.revoke",
                        json!({ "install": install }),
                        &format!("install-revoke-{install}"),
                    ));
                }
                let id = self
                    .start
                    .fresh_ids
                    .get(usize::from(self.recovered))
                    .or(self.start.fresh_ids.first())
                    .cloned()
                    .unwrap_or_default();
                self.phase = Phase::UserEnsure;
                Ok(self.op("user.ensure", json!({}), &format!("user-ensure-{id}")))
            }
            (Phase::UserEnsure, Event::Http { status, body }) => {
                let user = op_value(reply(status, &body)?)?;
                let id = user.get("id").and_then(Value::as_str).ok_or(Error::MalformedReply)?;
                if user.get("stack_user_id").and_then(Value::as_str) != Some(&self.start.stack_user)
                {
                    return Err(Error::UserMismatch);
                }
                self.user_id = Some(id.to_owned());
                self.attempts = 1;
                self.phase = Phase::PublicKey;
                Ok(Effect::PublicKey)
            }
            (Phase::PublicKey, Event::PublicKey { x963 }) => {
                let x963 = STANDARD.decode(x963).map_err(|_| Error::InvalidPublicKey)?;
                let jwk = public_jwk(&x963)?;
                let digest = Sha256::digest(&x963);
                let thumbprint = hex(digest.get(..16).ok_or(Error::InvalidPublicKey)?);
                let user = self.user_id.clone().unwrap_or_default();
                let profile = &self.start.profile;
                let params = json!({
                    "public_jwk": jwk,
                    "kind": profile.kind,
                    "name": profile.name,
                    "device_name": display_name(&self.start.device_name, &profile.fallback_device_name),
                    "platform": profile.platform,
                    "op_classes": profile.op_classes,
                });
                self.phase = Phase::Register;
                // Keyed by (user, key): a lost reply is replayed, never a second install.
                Ok(self.op(
                    "install.register",
                    params,
                    &format!("install-register-{user}-{thumbprint}"),
                ))
            }
            (Phase::Register, Event::Http { status, body }) => {
                match reply(status, &body).and_then(op_value) {
                    Err(error)
                        if error == Error::refused("key.already_registered")
                            && self.attempts == 1 =>
                    {
                        // The owner holds this key for an install whose record was lost (a
                        // reinstall): start over with a new key.
                        self.attempts = 2;
                        self.phase = Phase::RotateForRegister;
                        Ok(Effect::Rotate)
                    }
                    Err(error) => Err(error),
                    Ok(install) => {
                        let install = install
                            .get("id")
                            .and_then(Value::as_str)
                            .ok_or(Error::MalformedReply)?;
                        let record = Record {
                            user: self.user_id.clone().unwrap_or_default(),
                            install: install.to_owned(),
                        };
                        self.start.record = Some(record.clone());
                        self.phase = Phase::SaveRecord;
                        Ok(Effect::SaveRecord { record: Some(record) })
                    }
                }
            }
            (Phase::RotateForRegister, Event::Rotated) => {
                self.phase = Phase::PublicKey;
                Ok(Effect::PublicKey)
            }
            (Phase::RotateForRecovery, Event::Rotated) => {
                self.start.record = None;
                self.phase = Phase::ForgetRecord;
                Ok(Effect::SaveRecord { record: None })
            }
            (Phase::SaveRecord, Event::Saved) => Ok(self.challenge()),
            (Phase::ForgetRecord, Event::Saved) => self.begin_mint(),
            (Phase::Challenge, Event::Http { status, body }) => {
                let challenge = reply(status, &body)?;
                let install = self.record()?.install;
                let nonce = challenge.get("nonce").and_then(Value::as_str);
                let prefix = challenge.get("message_prefix").and_then(Value::as_str);
                let (Some(nonce), Some(prefix)) = (nonce, prefix) else {
                    return Err(Error::UnexpectedChallenge);
                };
                let named = environment_in_prefix(prefix, &install, self.start.team.as_deref())
                    .filter(|_| is_nonce(nonce))
                    .ok_or(Error::UnexpectedChallenge)?;
                // Once learned, the environment never changes for this client.
                if self.start.environment.as_ref().is_some_and(|known| *known != named) {
                    return Err(Error::UnexpectedChallenge);
                }
                let message = format!("{prefix}{nonce}");
                self.nonce = Some(nonce.to_owned());
                self.prefix = Some(prefix.to_owned());
                self.named = Some(named);
                self.phase = Phase::Signing;
                Ok(Effect::Sign { message })
            }
            (Phase::Signing, Event::Signature { signature }) => {
                let raw = STANDARD.decode(signature).map_err(|_| Error::MalformedReply)?;
                let record = self.record()?;
                self.phase = Phase::Token;
                Ok(self.post(
                    "/v1/auth/token",
                    &json!({
                        "user": record.user, "install": record.install,
                        "nonce": self.nonce, "signature": URL_SAFE_NO_PAD.encode(raw),
                    }),
                    None,
                ))
            }
            (Phase::Token, Event::Http { status, body }) => {
                let answer = reply(status, &body)?;
                let token = answer
                    .get("access_token")
                    .and_then(Value::as_str)
                    .ok_or(Error::MalformedReply)?;
                let named = self.named.clone().unwrap_or_default();
                let claims = claims(token);
                let issuer = claims.as_ref().and_then(|c| c.get("iss")).and_then(Value::as_str);
                if issuer != Some(&format!("https://cmux-api/{named}")) {
                    return Err(Error::UnexpectedChallenge);
                }
                if let Some(team) = &self.start.team {
                    let record = self.record()?;
                    if !team_token_matches(&answer, claims.as_ref(), team, &record) {
                        return Err(Error::UnexpectedChallenge);
                    }
                }
                let cap = now_ms + MAXIMUM_LIFETIME_MS;
                let stated = answer.get("expires_at").and_then(Value::as_f64).unwrap_or(cap);
                Ok(Effect::Done {
                    token: token.to_owned(),
                    environment: named,
                    expires_at_ms: stated.min(cap),
                })
            }
            (Phase::Revoke, Event::Http { status, body }) => {
                op_value(reply(status, &body)?)?;
                Ok(Effect::Revoked { revoked: true })
            }
            (phase, Event::TransportError { url_error_code })
                if matches!(
                    phase,
                    Phase::UserEnsure
                        | Phase::Register
                        | Phase::Challenge
                        | Phase::Token
                        | Phase::Revoke
                ) =>
            {
                let path = if matches!(phase, Phase::Challenge) {
                    "/v1/auth/challenge"
                } else if matches!(phase, Phase::Token) {
                    "/v1/auth/token"
                } else {
                    "/v1/ops"
                };
                Err(Error::Transport { path: path.to_owned(), url_error_code })
            }
            _ => Err(Error::MalformedReply),
        }
    }

    fn record(&self) -> Result<Record, Error> {
        self.start.record.clone().ok_or(Error::MalformedReply)
    }

    fn challenge(&mut self) -> Effect {
        let record = self
            .start
            .record
            .clone()
            .unwrap_or(Record { user: String::new(), install: String::new() });
        let mut request = Map::new();
        request.insert("user".into(), record.user.into());
        request.insert("install".into(), record.install.into());
        if let Some(team) = &self.start.team {
            request.insert("team".into(), team.clone().into());
        }
        self.phase = Phase::Challenge;
        self.post("/v1/auth/challenge", &Value::Object(request), None)
    }

    fn op(&self, name: &str, params: Value, key: &str) -> Effect {
        self.post(
            "/v1/ops",
            &json!({ "op": name, "params": params, "idempotency_key": key, "origin": "cli" }),
            self.session.clone(),
        )
    }

    fn post(&self, path: &str, body: &Value, bearer: Option<String>) -> Effect {
        Effect::Post {
            path: path.to_owned(),
            body: sorted_json(body),
            bearer,
            headers: headers(self.start.client_version.as_deref()),
        }
    }
}

/// The headers every request carries.
#[must_use]
pub fn headers(client_version: Option<&str>) -> BTreeMap<String, String> {
    client_version
        .filter(|version| !version.is_empty())
        .map(|version| BTreeMap::from([(CLIENT_VERSION_HEADER.to_owned(), version.to_owned())]))
        .unwrap_or_default()
}

/// An HTTP answer: a JSON object on a 2xx; otherwise the refusal it names.
fn reply(status: u16, body: &str) -> Result<Map<String, Value>, Error> {
    let Ok(Value::Object(reply)) = serde_json::from_str::<Value>(body) else {
        return Err(if status == 200 {
            Error::MalformedReply
        } else {
            Error::refused(format!("http_{status}"))
        });
    };
    if !(200..300).contains(&status) {
        let code = reply.get("code").and_then(Value::as_str);
        if code == Some("client.too_old") {
            return Err(Error::ClientTooOld {
                minimum_version: reply
                    .get("minimum_version")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            });
        }
        return Err(Error::refused(code.map_or_else(|| format!("http_{status}"), str::to_owned)));
    }
    Ok(reply)
}

/// A `/v1/ops` answer's value. A domain refusal is HTTP 200 with `ok: false`.
fn op_value(reply: Map<String, Value>) -> Result<Map<String, Value>, Error> {
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = reply.get("error");
        let field = |name: &str| error.and_then(|e| e.get(name)).and_then(Value::as_str);
        if field("message").is_some_and(|message| message.contains("already registered")) {
            return Err(Error::refused("key.already_registered"));
        }
        return Err(Error::refused(field("code").unwrap_or("unknown")));
    }
    match reply.get("value") {
        Some(Value::Object(value)) => Ok(value.clone()),
        _ => Err(Error::MalformedReply),
    }
}

/// The public JWK the owner stores for the install.
///
/// # Errors
///
/// [`Error::InvalidPublicKey`] unless `x963` is 65 bytes starting `0x04`.
pub fn public_jwk(x963: &[u8]) -> Result<Value, Error> {
    if x963.len() != 65 || x963.first() != Some(&0x04) {
        return Err(Error::InvalidPublicKey);
    }
    let x = x963.get(1..33).ok_or(Error::InvalidPublicKey)?;
    let y = x963.get(33..65).ok_or(Error::InvalidPublicKey)?;
    Ok(json!({
        "kty": "EC", "crv": "P-256",
        "x": URL_SAFE_NO_PAD.encode(x),
        "y": URL_SAFE_NO_PAD.encode(y),
    }))
}

/// The environment a challenge prefix names: `cmux-auth-v1\n<env>\n<install>\n`, or
/// `cmux-auth-team-v1\n<env>\n<install>\n<team>\n` for a team. The name is 1 to 32 of
/// lowercase ASCII letters, digits and `-`, starting with a letter.
#[must_use]
pub fn environment_in_prefix(prefix: &str, install: &str, team: Option<&str>) -> Option<String> {
    let head = if team.is_none() { "cmux-auth-v1\n" } else { "cmux-auth-team-v1\n" };
    let tail = format!("\n{install}\n{}", team.map(|team| format!("{team}\n")).unwrap_or_default());
    if prefix.len() <= head.len() + tail.len() {
        return None;
    }
    let name = prefix.strip_prefix(head)?.strip_suffix(tail.as_str())?;
    let mut chars = name.chars();
    let first = chars.next()?;
    let valid = name.chars().count() <= 32
        && first.is_ascii_lowercase()
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    valid.then(|| name.to_owned())
}

/// 16 to 128 of ASCII letters, digits, `-` and `_`.
#[must_use]
pub fn is_nonce(value: &str) -> bool {
    (16..=128).contains(&value.chars().count())
        && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// 1 to 80 UTF-16 units (the owner's display-name limit), cut on a character boundary;
/// `fallback` when nothing is left.
#[must_use]
pub fn display_name(name: &str, fallback: &str) -> String {
    let mut result = String::new();
    let mut units = 0;
    for character in name.graphemes(true) {
        let width = character.encode_utf16().count();
        if units + width > 80 {
            break;
        }
        units += width;
        result.push_str(character);
    }
    if result.is_empty() { fallback.to_owned() } else { result }
}

/// A JWT's payload claims (read only; the owner verifies the token).
fn claims(token: &str) -> Option<Map<String, Value>> {
    let parts: Vec<&str> = token.split('.').collect();
    let [_, payload, _] = parts.as_slice() else {
        return None;
    };
    let mut base: String = payload.replace('-', "+").replace('_', "/");
    while base.len() % 4 != 0 {
        base.push('=');
    }
    match serde_json::from_slice(&STANDARD.decode(base).ok()?).ok()? {
        Value::Object(claims) => Some(claims),
        _ => None,
    }
}

/// A team token names exactly this team, user, install and grant, for the API, with no
/// agent or machine claims.
fn team_token_matches(
    answer: &Map<String, Value>,
    claims: Option<&Map<String, Value>>,
    team: &str,
    record: &Record,
) -> bool {
    let text = |map: Option<&Map<String, Value>>, name: &str| {
        map.and_then(|m| m.get(name)).and_then(Value::as_str).map(str::to_owned)
    };
    let Some(grant) = text(Some(answer), "grant").filter(|grant| !grant.is_empty()) else {
        return false;
    };
    let absent = |name: &str| claims.is_some_and(|c| !c.contains_key(name));
    text(Some(answer), "team").as_deref() == Some(team)
        && text(Some(answer), "user").as_deref() == Some(record.user.as_str())
        && text(Some(answer), "install").as_deref() == Some(record.install.as_str())
        && text(claims, "team").as_deref() == Some(team)
        && text(claims, "sub").as_deref() == Some(record.user.as_str())
        && text(claims, "inst").as_deref() == Some(record.install.as_str())
        && text(claims, "grant").as_deref() == Some(grant.as_str())
        && text(claims, "aud").as_deref() == Some("api")
        && absent("agt")
        && absent("vm")
        && absent("tvm")
}

/// JSON with every object's keys sorted, as the Swift client sent it.
fn sorted_json(value: &Value) -> String {
    fn sort(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let sorted: BTreeMap<&String, Value> =
                    map.iter().map(|(key, value)| (key, sort(value))).collect();
                Value::Object(sorted.into_iter().map(|(k, v)| (k.clone(), v)).collect())
            }
            Value::Array(items) => Value::Array(items.iter().map(sort).collect()),
            other => other.clone(),
        }
    }
    sort(value).to_string()
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

#[cfg(test)]
#[path = "install_auth_tests.rs"]
mod tests;
