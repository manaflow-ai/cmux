//! A single-use key per machine, minted on the person's own Mac from their admin credential (a
//! Tailscale OAuth client or a Headscale API key), so only that short-lived key reaches the
//! machine. The long-lived credential stays on the Mac. Pure: the HTTP calls are values the
//! caller sends ([`Call`]), and the answers are parsed here.
//!
//! Every minted key is single-use, pre-authorized and expires in [`KEY_TTL_SECS`]; ephemeral is
//! the caller's choice (the join's `--ephemeral`).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::Secret;

/// How long a minted key may wait for its one join.
pub const KEY_TTL_SECS: u64 = 600;
/// Tailscale's API.
pub const TAILSCALE_API: &str = "https://api.tailscale.com";

/// Where the key comes from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MintSource {
    /// A Tailscale OAuth client (`tskey-client-<id>-<secret>`) with the `auth_keys` scope.
    TailscaleOauth { client_secret: Secret },
    /// A Headscale API key (`headscale apikeys create`) for `server`; keys belong to `user` (its id).
    Headscale { server: String, api_key: Secret, user: String },
}

/// What the minted key allows.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MintSpec {
    #[serde(default)]
    pub ephemeral: bool,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// One HTTP request to send. Debug never prints a secret ([`Secret`] redacts).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    pub url: String,
    pub bearer: Option<Secret>,
    /// `application/x-www-form-urlencoded` fields.
    pub form: Vec<(&'static str, Secret)>,
    /// A JSON body.
    pub json: Option<Value>,
}

/// Why a mint did not give a key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MintError(pub String);

/// The client id in `tskey-client-<id>-<secret>`.
pub fn oauth_client_id(client_secret: &Secret) -> Result<String, MintError> {
    let parts: Vec<&str> = client_secret.expose().split('-').collect();
    match parts.as_slice() {
        ["tskey", "client", id, secret, ..] if !id.is_empty() && !secret.is_empty() => {
            Ok((*id).to_owned())
        }
        _ => Err(MintError("an OAuth client secret looks like tskey-client-ID-SECRET".to_owned())),
    }
}

/// Step one for Tailscale: trade the OAuth client for an access token.
pub fn tailscale_token_call(client_secret: &Secret) -> Result<Call, MintError> {
    let id = oauth_client_id(client_secret)?;
    Ok(Call {
        url: format!("{TAILSCALE_API}/api/v2/oauth/token"),
        bearer: None,
        form: vec![
            ("client_id", Secret::new(id)),
            ("client_secret", client_secret.clone()),
            ("grant_type", Secret::new("client_credentials")),
        ],
        json: None,
    })
}

/// The access token in the token call's answer.
pub fn parse_token(body: &str) -> Result<Secret, MintError> {
    field(body, &["access_token"], "the Tailscale token answer")
}

/// Step two for Tailscale: a single-use, pre-authorized key with `spec`'s tags.
pub fn tailscale_key_call(access_token: &Secret, spec: &MintSpec) -> Call {
    Call {
        url: format!("{TAILSCALE_API}/api/v2/tailnet/-/keys"),
        bearer: Some(access_token.clone()),
        form: Vec::new(),
        json: Some(json!({
            "capabilities": {"devices": {"create": {
                "reusable": false,
                "ephemeral": spec.ephemeral,
                "preauthorized": true,
                "tags": spec.tags,
            }}},
            "expirySeconds": KEY_TTL_SECS,
            "description": "cmux machine join",
        })),
    }
}

/// The key in Tailscale's key answer.
pub fn parse_tailscale_key(body: &str) -> Result<Secret, MintError> {
    let key = field(body, &["key"], "the Tailscale key answer")?;
    if !key.expose().starts_with("tskey-auth-") {
        return Err(MintError("Tailscale answered with something that is not an auth key".into()));
    }
    Ok(key)
}

/// Headscale's one call: a single-use pre-auth key for `user`, expiring [`KEY_TTL_SECS`] after
/// `now_unix`.
pub fn headscale_key_call(
    server: &str,
    api_key: &Secret,
    user: &str,
    spec: &MintSpec,
    now_unix: u64,
) -> Call {
    Call {
        url: format!("{}/api/v1/preauthkey", server.trim_end_matches('/')),
        bearer: Some(api_key.clone()),
        form: Vec::new(),
        json: Some(json!({
            "user": user,
            "reusable": false,
            "ephemeral": spec.ephemeral,
            "expiration": rfc3339(now_unix + KEY_TTL_SECS),
            "aclTags": spec.tags,
        })),
    }
}

/// The key in Headscale's answer.
pub fn parse_headscale_key(body: &str) -> Result<Secret, MintError> {
    field(body, &["preAuthKey", "key"], "the Headscale answer")
}

/// Checks a source before any call: the Headscale server is https (or http with `allow_http`),
/// the user id is digits, the Tailscale secret has its shape, and Tailscale gets tags. Answers the
/// spec with each tag in its `tag:NAME` form.
pub fn check_source(
    source: &MintSource,
    spec: &MintSpec,
    allow_http: bool,
) -> Result<MintSpec, MintError> {
    match source {
        MintSource::TailscaleOauth { client_secret } => {
            oauth_client_id(client_secret)?;
            if spec.tags.is_empty() {
                return Err(MintError(
                    "a key from an OAuth client needs --tag (Tailscale tags every such machine)"
                        .into(),
                ));
            }
        }
        MintSource::Headscale { server, api_key, user } => {
            let https = server.starts_with("https://");
            if !https && !(allow_http && server.starts_with("http://")) {
                return Err(MintError(
                    "the Headscale server must be https:// (or http:// with --allow-http)".into(),
                ));
            }
            if api_key.expose().is_empty() || api_key.expose().chars().any(char::is_whitespace) {
                return Err(MintError("the Headscale API key is empty or has spaces".into()));
            }
            if user.is_empty() || !user.chars().all(|c| c.is_ascii_digit()) {
                return Err(MintError(
                    "--headscale-user takes the user's id (headscale users list)".into(),
                ));
            }
        }
    }
    let tags = spec
        .tags
        .iter()
        .map(|t| crate::check_tag(t).map_err(|e| MintError(e.0)))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(MintSpec { ephemeral: spec.ephemeral, tags })
}

fn field(body: &str, path: &[&str], what: &str) -> Result<Secret, MintError> {
    let value: Value =
        serde_json::from_str(body).map_err(|_| MintError(format!("{what} is not JSON")))?;
    let found = path.iter().try_fold(&value, |v, k| v.get(k)).and_then(Value::as_str);
    match found {
        Some(text) if !text.is_empty() => Ok(Secret::new(text)),
        _ => Err(MintError(format!("{what} has no {}", path.join(".")))),
    }
}

/// `YYYY-MM-DDTHH:MM:SSZ` for unix seconds.
pub fn rfc3339(unix: u64) -> String {
    let days = i64::try_from(unix / 86_400).unwrap_or(i64::MAX / 2);
    let secs = unix % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60
    )
}

#[cfg(test)]
#[path = "mint_tests.rs"]
mod tests;
