//! Sign-in with no callback: the app asks Stack for a login code, opens cmux.com's confirmation page for it in
//! the browser, and polls Stack until the person confirms. No URL scheme carries the session back, so cmux.com
//! has nothing to allowlist: a dev build, a `cmux app try` copy and a shipped build all sign in the same way
//! (Leo, 2026-11-21: "do the proper callback/not need it? idk. that's the whole point").
//!
//! It is the login the `cr` CLI already uses against the same Stack project: `POST /auth/cli` mints a
//! `polling_code` (kept by the app) and a `login_code` (put in the confirmation URL), `/handler/cli-auth-confirm`
//! on cmux.com binds the login code to the signed-in browser's account, and `POST /auth/cli/poll` answers
//! `waiting` until then and the session's refresh token once. One refresh then gives the access token.
//!
//! Pure, like the rest of this crate: the app runs each [`HttpCall`], hands the status and body back, and acts
//! on the answer. Measured against api.stack-auth.com on 2026-11-21: start 200 with `polling_code`,
//! `login_code`, `expires_at`; poll 200 `{"status":"waiting"}`; an unknown polling code 400
//! `INVALID_POLLING_CODE`; refresh with an unknown token 401 `REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::encode_component;

/// How long the app waits between polls.
pub const POLL_INTERVAL_MS: u64 = 2_000;

/// How long a login code lives. Long enough to sign in (or create an account) in the browser, short enough
/// that an abandoned code dies soon.
pub const LOGIN_EXPIRES_IN_MS: u64 = 15 * 60 * 1_000;

/// The Stack project a build signs in to (the configuration's `stackBaseURL`, `stackProjectID` and
/// `stackPublishableClientKey`).
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub stack_base_url: String,
    pub project_id: String,
    pub publishable_client_key: String,
}

/// One HTTP request for the app to send.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpCall {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// What the start's answer means.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Started {
    /// Open `confirm_url` in the browser and poll with `polling_code`.
    #[serde(rename_all = "camelCase")]
    Started { polling_code: String, confirm_url: String, expires_at: String },
    #[serde(rename_all = "camelCase")]
    Refused { reason: String },
}

/// What one poll's answer means.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Polled {
    /// Not confirmed yet: poll again after [`POLL_INTERVAL_MS`].
    Waiting,
    /// Confirmed: run [`token_request`] with this refresh token.
    #[serde(rename_all = "camelCase")]
    SignedIn { refresh_token: String },
    /// The code died (expired, already used, unknown): the sign-in is over; start a new one.
    #[serde(rename_all = "camelCase")]
    Ended { reason: String },
    /// Stack refused this poll (rate limit, an outage): poll again later, the code may still be good.
    #[serde(rename_all = "camelCase")]
    Retry { reason: String },
}

/// What the refresh's answer means.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Tokens {
    /// Seed the token store with this pair, as the callback would have.
    #[serde(rename_all = "camelCase")]
    Tokens { access_token: String, refresh_token: String },
    #[serde(rename_all = "camelCase")]
    Refused { reason: String },
}

fn api(project: &Project, path: &str) -> String {
    let base = project.stack_base_url.trim_end_matches('/');
    let base = base.strip_suffix("/api/v1").unwrap_or(base);
    format!("{base}/api/v1{path}")
}

fn headers(project: &Project) -> Vec<(String, String)> {
    vec![
        ("content-type".to_owned(), "application/json".to_owned()),
        ("x-stack-access-type".to_owned(), "client".to_owned()),
        ("x-stack-project-id".to_owned(), project.project_id.clone()),
        ("x-stack-publishable-client-key".to_owned(), project.publishable_client_key.clone()),
    ]
}

/// The request that mints a login code.
pub fn start_request(project: &Project) -> HttpCall {
    HttpCall {
        method: "POST".to_owned(),
        url: api(project, "/auth/cli"),
        headers: headers(project),
        body: serde_json::json!({ "expires_in_millis": LOGIN_EXPIRES_IN_MS }).to_string(),
    }
}

/// The page the person confirms the login on: cmux.com's, so the browser's existing session signs it in.
pub fn confirm_url(auth_web_origin: &str, login_code: &str) -> String {
    format!(
        "{}/handler/cli-auth-confirm?login_code={}",
        auth_web_origin.trim_end_matches('/'),
        encode_component(login_code)
    )
}

fn non_empty(value: &Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned)
}

fn refusal(status: u16, body: &Value) -> String {
    match non_empty(body, "code") {
        Some(code) => format!("{status} {code}"),
        None => format!("{status}"),
    }
}

/// Reads the start's answer; `auth_web_origin` is cmux.com's origin for this build.
pub fn read_start(status: u16, body: &str, auth_web_origin: &str) -> Started {
    let body: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    if !(200..300).contains(&status) {
        return Started::Refused { reason: refusal(status, &body) };
    }
    match (non_empty(&body, "polling_code"), non_empty(&body, "login_code")) {
        (Some(polling_code), Some(login_code)) => Started::Started {
            polling_code,
            confirm_url: confirm_url(auth_web_origin, &login_code),
            expires_at: non_empty(&body, "expires_at").unwrap_or_default(),
        },
        _ => Started::Refused { reason: format!("{status} no login code") },
    }
}

/// The request that asks whether the login was confirmed.
pub fn poll_request(project: &Project, polling_code: &str) -> HttpCall {
    HttpCall {
        method: "POST".to_owned(),
        url: api(project, "/auth/cli/poll"),
        headers: headers(project),
        body: serde_json::json!({ "polling_code": polling_code }).to_string(),
    }
}

/// Reads one poll's answer.
pub fn read_poll(status: u16, body: &str) -> Polled {
    let body: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    if (200..300).contains(&status) {
        return match non_empty(&body, "status").as_deref() {
            Some("waiting") | Some("pending") => Polled::Waiting,
            Some("success") => match non_empty(&body, "refresh_token") {
                Some(refresh_token) => Polled::SignedIn { refresh_token },
                None => Polled::Ended { reason: "confirmed without a session".to_owned() },
            },
            Some(other) => Polled::Ended { reason: other.to_owned() },
            None => Polled::Retry { reason: format!("{status} no status") },
        };
    }
    // A code Stack no longer knows will never confirm; anything else (429, 5xx) may pass.
    if (400..500).contains(&status) && status != 408 && status != 429 {
        return Polled::Ended { reason: refusal(status, &body) };
    }
    Polled::Retry { reason: refusal(status, &body) }
}

/// The request that turns the confirmed refresh token into an access token.
pub fn token_request(project: &Project, refresh_token: &str) -> HttpCall {
    let mut headers = headers(project);
    headers.push(("x-stack-refresh-token".to_owned(), refresh_token.to_owned()));
    HttpCall {
        method: "POST".to_owned(),
        url: api(project, "/auth/sessions/current/refresh"),
        headers,
        body: "{}".to_owned(),
    }
}

/// Reads the refresh's answer for the `refresh_token` the poll returned.
pub fn read_token(status: u16, body: &str, refresh_token: &str) -> Tokens {
    let body: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    if !(200..300).contains(&status) {
        return Tokens::Refused { reason: refusal(status, &body) };
    }
    match non_empty(&body, "access_token") {
        Some(access_token) => Tokens::Tokens {
            access_token,
            refresh_token: non_empty(&body, "refresh_token")
                .unwrap_or_else(|| refresh_token.to_owned()),
        },
        None => Tokens::Refused { reason: format!("{status} no access token") },
    }
}

#[cfg(test)]
#[path = "cli_sign_in_tests.rs"]
mod tests;
