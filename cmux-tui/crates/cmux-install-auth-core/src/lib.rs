//! The install principal's rules shared by the cmux Mac app and the phones, in Rust: the
//! public JWK of the install key, the challenge the install will sign, the minted token's
//! checks, and the `/v1/ops` bodies and replies of `user.ensure`, `install.register` and
//! `install.revoke`. The Mac reaches them over cmux-layout-reducer-ffi's JSON channel (the
//! `install_auth_*` ops, [`ops`]) and the phones over uniffi (cmux-mobile-ffi
//! `install_auth_json`). It was the logic of the Swift package
//! Packages/Shared/CmuxInstallAuthCore (RFD 0213, plans/cmux-next/mobile-rust-core.md slice 1).
//!
//! Sans-I/O: the platform keeps the HTTP transport, the Secure Enclave or Keystore signer
//! (the private key never enters Rust), the record's Keychain storage and the one-mint-at-a-
//! time cache; every decision about what goes on the wire and whether an answer is trusted
//! is here.

pub mod ops;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;

/// Refresh this long (ms) before the token expires.
pub const REFRESH_MARGIN_MS: f64 = 60_000.0;
/// Never trust a token longer than this (ms; device clock skew).
pub const MAXIMUM_LIFETIME_MS: f64 = 540_000.0;
/// The header the owner's version gate reads (token mint and wire connects).
pub const CLIENT_VERSION_HEADER: &str = "x-cmux-client-version";

/// Why an install step failed. Never carries a token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InstallAuthError {
    InvalidPublicKey,
    NoSession,
    Refused {
        code: String,
    },
    /// The owner sent a challenge this client will not sign.
    UnexpectedChallenge,
    /// `user.ensure` answered for a different Stack user than the session's.
    UserMismatch,
    /// The request to `path` got no HTTP answer; `url_error_code` is the
    /// transport's `URLError` code when it threw one (-1001: timed out).
    Transport {
        path: String,
        #[serde(default)]
        url_error_code: Option<i64>,
    },
    MalformedReply,
    /// The team requires a newer app (`updates.minimumVersion`). Not an
    /// install problem: the key and record stay.
    ClientTooOld {
        #[serde(default)]
        minimum_version: Option<String>,
    },
}

impl InstallAuthError {
    fn refused(code: impl Into<String>) -> Self {
        Self::Refused { code: code.into() }
    }

    /// What a log line or a relay answer says of a failed mint: the step and its code.
    pub fn description(&self) -> String {
        match self {
            Self::InvalidPublicKey => "the install key is not a P-256 point".into(),
            Self::NoSession => "no sign-in session to register the install with".into(),
            Self::Refused { code } => format!("the cmux API refused the install token request ({code})"),
            Self::UnexpectedChallenge => "the cmux API sent a challenge this install will not sign".into(),
            Self::UserMismatch => "the cmux API answered for another user".into(),
            Self::Transport { path, url_error_code } => match url_error_code {
                Some(code) => format!("POST {path} got no answer (URLError {code})"),
                None => format!("POST {path} got no answer"),
            },
            Self::MalformedReply => "the cmux API answered the install token request with no token".into(),
            Self::ClientTooOld { minimum_version } => match minimum_version {
                Some(minimum) => format!("this cmux is too old for the team (needs {minimum})"),
                None => "this cmux is too old for the team".into(),
            },
        }
    }
}

/// base64url without padding (RFC 4648 section 5).
pub fn base64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes base64url with or without padding.
pub fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    let mut base: String = text.chars().map(|c| match c {
        '-' => '+',
        '_' => '/',
        c => c,
    }).collect();
    while base.len() % 4 != 0 {
        base.push('=');
    }
    STANDARD.decode(base).ok()
}

/// The public JWK the owner stores for the install, from the uncompressed
/// point (X9.63: 0x04 || x || y, 65 bytes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicJwk {
    pub x: String,
    pub y: String,
}

impl PublicJwk {
    pub fn from_x963(x963: &[u8]) -> Result<Self, InstallAuthError> {
        if x963.len() != 65 || x963[0] != 0x04 {
            return Err(InstallAuthError::InvalidPublicKey);
        }
        Ok(Self { x: base64url(&x963[1..33]), y: base64url(&x963[33..65]) })
    }

    pub fn json(&self) -> Value {
        serde_json::json!({"crv": "P-256", "kty": "EC", "x": self.x, "y": self.y})
    }
}

/// The key's register thumbprint: the first 16 bytes of sha256(x963), hex.
pub fn thumbprint(x963: &[u8]) -> String {
    Sha256::digest(x963)[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// What an install registers as (user.ts defaultInstallClasses: a register
/// may narrow the kind's classes, never widen them).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstallProfile {
    pub kind: String,
    pub name: String,
    pub platform: String,
    pub op_classes: Vec<String>,
    /// The device name when the system gives none.
    pub fallback_device_name: String,
}

impl InstallProfile {
    fn new(kind: &str, name: &str, platform: &str, classes: &[&str], fallback: &str) -> Self {
        Self {
            kind: kind.into(),
            name: name.into(),
            platform: platform.into(),
            op_classes: classes.iter().map(|c| (*c).into()).collect(),
            fallback_device_name: fallback.into(),
        }
    }

    /// The iPhone app. L14-1: never `execute` (no terminal input, code or CUA
    /// acts from a stolen phone token); `cloud-link` lets it mint Cloud link tokens.
    pub fn ios() -> Self {
        Self::new("ios", "cmux iOS", "ios", &["read", "mutate-own", "cloud-link"], "iPhone")
    }

    /// The cmux Mac app (cx-wb5.64): the phone grant plus `mutate-shared`;
    /// never `execute`. The server caps a mac register to this set.
    pub fn mac() -> Self {
        Self::new("mac", "cmux", "macos", &["read", "mutate-own", "mutate-shared", "cloud-link"], "Mac")
    }

    pub fn named(kind: &str) -> Option<Self> {
        match kind {
            "ios" => Some(Self::ios()),
            "mac" => Some(Self::mac()),
            _ => None,
        }
    }
}

/// 1 to 80 UTF-16 units (the owner's display-name limit), cut on a character.
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
    if result.is_empty() { fallback.into() } else { result }
}

/// The headers every request carries.
pub fn headers(client_version: Option<&str>) -> Map<String, Value> {
    let mut headers = Map::new();
    if let Some(version) = client_version.filter(|v| !v.is_empty()) {
        headers.insert(CLIENT_VERSION_HEADER.into(), Value::from(version));
    }
    headers
}

/// A team id: `team_` and 20 lowercase hex digits.
pub fn is_team(value: &str) -> bool {
    value.len() == 25
        && value.starts_with("team_")
        && value[5..].bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A challenge nonce: 16 to 128 ASCII letters, digits, `-` and `_`.
pub fn is_nonce(value: &str) -> bool {
    (16..=128).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The environment a challenge prefix names, when it is exactly the expected
/// environment/install/team context; nothing else may be signed.
pub fn environment_in_prefix(prefix: &str, install: &str, team: Option<&str>) -> Option<String> {
    let head = if team.is_none() { "cmux-auth-v1\n" } else { "cmux-auth-team-v1\n" };
    let tail = match team {
        Some(team) => format!("\n{install}\n{team}\n"),
        None => format!("\n{install}\n"),
    };
    let name = prefix.strip_prefix(head)?.strip_suffix(tail.as_str())?;
    let first = name.bytes().next()?;
    (name.len() <= 32
        && first.is_ascii_lowercase()
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
    .then(|| name.to_string())
}

/// A JWT's claims (payload read only; the owner verifies the signature).
pub fn claims(token: &str) -> Option<Map<String, Value>> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    match serde_json::from_slice(&base64url_decode(parts[1])?).ok()? {
        Value::Object(claims) => Some(claims),
        _ => None,
    }
}

/// The `iss` claim of a JWT.
pub fn issuer(token: &str) -> Option<String> {
    claims(token)?.get("iss")?.as_str().map(str::to_string)
}

/// A JSON object with its keys sorted at every level (Swift's `.sortedKeys`).
pub fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

fn body(value: Value) -> String {
    sorted(value).to_string()
}

/// The `POST /v1/ops` body of an install op (origin `cli`).
pub fn op_body(op: &str, params: Value, idempotency_key: &str) -> String {
    body(serde_json::json!({"op": op, "params": params, "idempotency_key": idempotency_key, "origin": "cli"}))
}

/// The `install.register` op for this key, keyed by (user, key) so a lost
/// reply is replayed, never a second install.
pub fn register_op(
    x963: &[u8],
    profile: &InstallProfile,
    device_name: &str,
    user: &str,
) -> Result<String, InstallAuthError> {
    let jwk = PublicJwk::from_x963(x963)?;
    let params = serde_json::json!({
        "public_jwk": jwk.json(),
        "kind": profile.kind,
        "name": profile.name,
        "device_name": display_name(device_name, &profile.fallback_device_name),
        "platform": profile.platform,
        // Never `execute` for ios or mac (InstallProfile).
        "op_classes": profile.op_classes,
    });
    Ok(op_body("install.register", params, &format!("install-register-{user}-{}", thumbprint(x963))))
}

/// The `install.revoke` op (sign-out, L14-2).
pub fn revoke_op(install: &str) -> String {
    op_body("install.revoke", serde_json::json!({"install": install}), &format!("install-revoke-{install}"))
}

/// The `/v1/auth/challenge` body.
pub fn challenge_request(user: &str, install: &str, team: Option<&str>) -> String {
    let mut request = serde_json::json!({"user": user, "install": install});
    if let Some(team) = team {
        request["team"] = Value::from(team);
    }
    body(request)
}

/// The `/v1/auth/token` body.
pub fn token_request(user: &str, install: &str, nonce: &str, signature: &[u8]) -> String {
    body(serde_json::json!({"user": user, "install": install, "nonce": nonce, "signature": base64url(signature)}))
}

/// One HTTP answer as the reply object, or the error it means.
pub fn http_reply(status: u16, data: &[u8]) -> Result<Map<String, Value>, InstallAuthError> {
    let Ok(Value::Object(reply)) = serde_json::from_slice::<Value>(data) else {
        return Err(if status == 200 {
            InstallAuthError::MalformedReply
        } else {
            InstallAuthError::refused(format!("http_{status}"))
        });
    };
    if !(200..300).contains(&status) {
        let code = reply.get("code").and_then(Value::as_str);
        if code == Some("client.too_old") {
            let minimum_version = reply.get("minimum_version").and_then(Value::as_str).map(str::to_string);
            return Err(InstallAuthError::ClientTooOld { minimum_version });
        }
        return Err(InstallAuthError::refused(code.map_or_else(|| format!("http_{status}"), str::to_string)));
    }
    Ok(reply)
}

/// An op reply's `value`, or the refusal it carries.
pub fn op_reply(reply: &Map<String, Value>) -> Result<Map<String, Value>, InstallAuthError> {
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = reply.get("error").and_then(Value::as_object);
        let message = error.and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or("");
        if message.contains("already registered") {
            return Err(InstallAuthError::refused("key.already_registered"));
        }
        let code = error.and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("unknown");
        return Err(InstallAuthError::refused(code));
    }
    match reply.get("value") {
        Some(Value::Object(value)) => Ok(value.clone()),
        _ => Err(InstallAuthError::MalformedReply),
    }
}

fn string<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

/// The backend user id from `user.ensure`'s value, checked against the session's Stack user.
pub fn ensured_user(value: &Map<String, Value>, stack_user: &str) -> Result<String, InstallAuthError> {
    let id = string(value, "id").ok_or(InstallAuthError::MalformedReply)?;
    if string(value, "stack_user_id") != Some(stack_user) {
        return Err(InstallAuthError::UserMismatch);
    }
    Ok(id.into())
}

/// The install id from `install.register`'s value.
pub fn registered_install(value: &Map<String, Value>) -> Result<String, InstallAuthError> {
    string(value, "id").map(str::to_string).ok_or(InstallAuthError::MalformedReply)
}

/// What the install keeps between launches (never the token).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstallRecord {
    pub user: String,
    pub install: String,
}

/// A challenge this install will sign: the learned environment and the exact bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignableChallenge {
    pub environment: String,
    pub message: String,
    pub nonce: String,
}

/// Checks the `/v1/auth/challenge` reply. `learned` is the environment this
/// client already trusts (once learned it never changes).
pub fn check_challenge(
    reply: &Map<String, Value>,
    record: &InstallRecord,
    team: Option<&str>,
    learned: Option<&str>,
) -> Result<SignableChallenge, InstallAuthError> {
    // Team selection belongs to the signed challenge: a bad team id is never asked for.
    if team.is_some_and(|team| !is_team(team)) {
        return Err(InstallAuthError::UnexpectedChallenge);
    }
    let (Some(nonce), Some(prefix)) = (string(reply, "nonce"), string(reply, "message_prefix")) else {
        return Err(InstallAuthError::UnexpectedChallenge);
    };
    let Some(named) = environment_in_prefix(prefix, &record.install, team).filter(|_| is_nonce(nonce)) else {
        return Err(InstallAuthError::UnexpectedChallenge);
    };
    if learned.is_some_and(|learned| learned != named) {
        return Err(InstallAuthError::UnexpectedChallenge);
    }
    Ok(SignableChallenge { environment: named, message: format!("{prefix}{nonce}"), nonce: nonce.into() })
}

/// A minted token this client may use, and until when (ms since 1970).
#[derive(Debug, Clone, PartialEq)]
pub struct MintedToken {
    pub token: String,
    pub expires_at_ms: f64,
}

/// Checks the `/v1/auth/token` reply: the issuer names the challenge's
/// environment, and a team token names the requested team, user, install and
/// grant both in the reply and in its claims, for the API audience, with no
/// agent or VM claims. The expiry is capped at [`MAXIMUM_LIFETIME_MS`].
pub fn check_token(
    reply: &Map<String, Value>,
    record: &InstallRecord,
    team: Option<&str>,
    environment: &str,
    now_ms: f64,
) -> Result<MintedToken, InstallAuthError> {
    let token = string(reply, "access_token").ok_or(InstallAuthError::MalformedReply)?;
    if issuer(token).as_deref() != Some(format!("https://cmux-api/{environment}").as_str()) {
        return Err(InstallAuthError::UnexpectedChallenge);
    }
    if let Some(team) = team {
        let claims = claims(token).unwrap_or_default();
        let grant = string(reply, "grant").filter(|grant| !grant.is_empty());
        let ok = grant.is_some()
            && string(reply, "team") == Some(team)
            && string(reply, "user") == Some(record.user.as_str())
            && string(reply, "install") == Some(record.install.as_str())
            && string(&claims, "team") == Some(team)
            && string(&claims, "sub") == Some(record.user.as_str())
            && string(&claims, "inst") == Some(record.install.as_str())
            && string(&claims, "grant") == grant
            && string(&claims, "aud") == Some("api")
            && ["agt", "vm", "tvm"].iter().all(|key| !claims.contains_key(*key));
        if !ok {
            return Err(InstallAuthError::UnexpectedChallenge);
        }
    }
    let cap = now_ms + MAXIMUM_LIFETIME_MS;
    let stated = reply.get("expires_at").and_then(Value::as_f64).unwrap_or(cap);
    Ok(MintedToken { token: token.into(), expires_at_ms: stated.min(cap) })
}

/// Whether a cached token is still good to hand out.
pub fn token_is_fresh(expires_at_ms: f64, now_ms: f64) -> bool {
    expires_at_ms - now_ms > REFRESH_MARGIN_MS
}

/// What to do when a mint was refused: only the personal sign-in path
/// recovers a revoked install (rotate the key, forget the record, mint again,
/// once); a team refusal keeps the key and record.
pub fn recovers_by_rotating(error: &InstallAuthError, team: Option<&str>) -> bool {
    team.is_none() && *error == InstallAuthError::refused("auth.forbidden")
}

/// Whether a refused register means the owner holds this key for an install
/// whose record was lost (a reinstall): rotate and register again, once.
pub fn register_retries_with_new_key(error: &InstallAuthError, attempt: u32) -> bool {
    attempt == 1 && *error == InstallAuthError::refused("key.already_registered")
}
