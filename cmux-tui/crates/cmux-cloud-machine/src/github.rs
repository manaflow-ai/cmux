//! Whether a Cloud machine's git can borrow GitHub through the cmux GitHub App (`cmux github
//! setup` on the machine: a git credential helper that asks cmux for a short-lived, one-repo
//! token each time, and stores none). Read from the API Worker's own check,
//! `GET /v1/integrations/github/status`, which says whether this deployment has the App and
//! which team connection the person would use.

use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubApp {
    /// The App is configured and the team has an active connection.
    Ready,
    /// No usable connection for this team (the token endpoint's `integration.not_found`), or one
    /// that needs to be connected again.
    NotConnected,
    /// This deployment has no cmux GitHub App.
    NotConfigured,
    /// The check did not answer (signed out, offline, or the Worker could not check).
    Unknown,
}

/// The status route's answer (`status`, `body`): `{configured, app_slug, allowed?, connection:
/// {status, …} | null}`, else `{error: {code, message}}`.
pub fn status(status: u16, body: &[u8]) -> GitHubApp {
    let object = serde_json::from_slice::<Value>(body).ok().filter(Value::is_object);
    let Some(object) = object.filter(|_| (200..300).contains(&status)) else {
        let code = serde_json::from_slice::<Value>(body)
            .ok()
            .and_then(|body| body.get("error")?.get("code")?.as_str().map(str::to_owned));
        return if code.as_deref() == Some("integration.not_found") {
            GitHubApp::NotConnected
        } else {
            GitHubApp::Unknown
        };
    };
    let Some(configured) = object.get("configured").and_then(Value::as_bool) else {
        return GitHubApp::Unknown;
    };
    if !configured {
        return GitHubApp::NotConfigured;
    }
    // A configured deployment names its App; an answer that does not is not this route's.
    if object.get("app_slug").and_then(Value::as_str).is_none_or(|slug| slug.trim().is_empty()) {
        return GitHubApp::Unknown;
    }
    // The team policy disallows GitHub: the App mints nothing, so the helper must not replace the
    // machine's own sign-in. An older Worker that does not say is allowed, as before.
    if object.get("allowed").and_then(Value::as_bool) == Some(false) {
        return GitHubApp::Unknown;
    }
    let active = object
        .get("connection")
        .and_then(|connection| connection.get("status"))
        .and_then(Value::as_str)
        == Some("active");
    if active { GitHubApp::Ready } else { GitHubApp::NotConnected }
}

/// The route's path for `team` (a `team_…` id); None for anything else, so no other text reaches
/// the URL.
pub fn path(team: &str) -> Option<String> {
    let id = team.strip_prefix("team_")?;
    let valid = (1..=120).contains(&id.len())
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-');
    valid.then(|| format!("/v1/integrations/github/status?team={team}"))
}

#[cfg(test)]
mod tests;
