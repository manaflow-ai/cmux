//! The rules around this Mac's install identity that are not key or Keychain calls (the app's
//! `CmuxNextCloud/Identity`): which team a `cmux auth token` mint is for, what a minted token's
//! claims say, which refusals are the service's trouble, the name of a user's install key, and
//! the origin a share install is kept by.

use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::origin;

/// A backend team id: `team_` and 20 lowercase hex digits (the owner's form).
pub fn is_team(value: &str) -> bool {
    value.len() == 25
        && value.strip_prefix("team_").is_some_and(|rest| {
            rest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// The backend's id for a Stack team (the API's `stackTeamIdFor`).
pub fn backend_team_id(stack_project_id: &str, stack_team_id: &str) -> String {
    let digest =
        Sha256::digest(format!("stack-team:{stack_project_id}:{}", stack_team_id.to_lowercase()));
    let hex: String = digest.iter().take(10).map(|b| format!("{b:02x}")).collect();
    format!("team_{hex}")
}

/// Why a token mint may not name the team it asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MintRefusal {
    /// The device is restricted to a managed team and the ask names another team, or the managed
    /// team is not the active one.
    Managed,
}

/// The backend team to mint for, from the app's team state (Stack ids): the asked team, else the
/// active team, else none (the install's own, personal team). A device restricted to a managed
/// team mints only for that team, and only while it is the active one, as every other Cloud call
/// on it.
pub fn mint_team(
    requested: Option<&str>,
    active_stack_team: Option<&str>,
    managed_stack_team: Option<&str>,
    stack_project_id: &str,
) -> Result<Option<String>, MintRefusal> {
    let backend = |team: &str| backend_team_id(stack_project_id, team);
    if let Some(managed) = managed_stack_team {
        if active_stack_team != Some(managed) {
            return Err(MintRefusal::Managed);
        }
        let only = backend(managed);
        if requested.is_some_and(|team| team != only) {
            return Err(MintRefusal::Managed);
        }
        return Ok(Some(only));
    }
    Ok(requested.map(str::to_owned).or_else(|| active_stack_team.map(backend)))
}

/// A refusal that is the service's trouble, not the account's: a 5xx or 429 status with no owner
/// code (`http_503`), or a rate limit. The caller retries those; it never reads them as "not a
/// member of the team".
pub fn is_transient(code: &str) -> bool {
    if code == "http_429" || code.contains("rate_limit") {
        return true;
    }
    code.strip_prefix("http_").is_some_and(|status| {
        status.len() == 3 && status.starts_with('5') && status.bytes().all(|b| b.is_ascii_digit())
    })
}

/// What an access token says about itself (unverified: the API verifies it).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claims {
    /// The token's `sub` (the backend user id), when non-empty.
    pub user: Option<String>,
    /// The token's `exp` in seconds since 1970, when finite and positive.
    pub expires_at: Option<f64>,
    /// The token's `team` (the backend team it was minted for), when non-empty: with no asked and
    /// no active team, `cmux auth token` mints for the install token's own team.
    pub team: Option<String>,
}

/// The claims of a three-part JWT (each part non-empty); none of a token that is not one.
pub fn claims(token: &str) -> Claims {
    let mut parts = token.split('.');
    let middle = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        // Three non-empty segments, as the old Swift parser required: `.payload.sig` or
        // `header.payload.` is not a token.
        (Some(header), Some(middle), Some(signature), None)
            if !header.is_empty() && !middle.is_empty() && !signature.is_empty() =>
        {
            Some(middle)
        }
        _ => None,
    };
    let payload = middle
        .and_then(|middle| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(middle.trim_end_matches('='))
                .ok()
        })
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
    let Some(payload) = payload else { return Claims::default() };
    Claims {
        user: payload
            .get("sub")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
        expires_at: payload
            .get("exp")
            .and_then(serde_json::Value::as_f64)
            .filter(|v| v.is_finite() && *v > 0.0),
        team: payload
            .get("team")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
    }
}

/// The Keychain account (or file name) of `user`'s install key, so two users on one Mac never
/// share or rotate each other's key: `install-key-<first 16 hex of SHA-256(user)>`.
pub fn install_key_account(user: &str) -> String {
    let digest = Sha256::digest(user.as_bytes());
    let hex: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("install-key-{hex}")
}

/// The folder prefix of a share install's store (`install-share-<host>`).
pub const SHARE_FOLDER_PREFIX: &str = "install-share-";

/// An https URL's origin and host, by which a share install is kept; none for any other scheme,
/// so a token is never minted over plain http.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareOrigin {
    pub origin: String,
    pub host: String,
    /// The folder its store lives in.
    pub folder: String,
}

/// The share origin of `url`.
pub fn share_origin(url: &str) -> Option<ShareOrigin> {
    let parts = origin::parse(url)?;
    if parts.scheme != "https" || parts.host.is_empty() {
        return None;
    }
    let origin = match parts.port {
        None => format!("https://{}", parts.host),
        Some(port) => format!("https://{}:{}", parts.host, port.parse::<u16>().ok()?),
    };
    Some(ShareOrigin {
        folder: format!("{SHARE_FOLDER_PREFIX}{}", parts.host),
        host: parts.host,
        origin,
    })
}

/// The API an earlier launch's share install folder was made for; none for any other folder.
pub fn share_folder_api(folder: &str) -> Option<String> {
    let host = folder.strip_prefix(SHARE_FOLDER_PREFIX)?;
    let api = format!("https://{host}");
    (origin::host(&api).as_deref() == Some(host)).then_some(api)
}

#[cfg(test)]
#[path = "identity_tests.rs"]
mod tests;
