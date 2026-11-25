//! Sign-in for `enable` and `share on` when no `--stack-token-file` is given: the Stack Auth
//! CLI login the `coderouter` CLI uses (coderouter/src/control_plane.rs), over `net.rs`.
//!
//! 1. `GET https://cmux.com/api/cli/config`: the cmux web deployment's Stack API URL, project
//!    and confirmation page (the project the device hub accepts).
//! 2. `POST <stack>/auth/cli` → `polling_code`, `login_code`; the person opens the
//!    confirmation page with `login_code` in any browser (this machine's, or another one).
//! 3. `POST <stack>/auth/cli/poll {polling_code}` until `success` with a refresh token.
//! 4. `POST <stack>/auth/sessions/current/refresh` → the access token `enable` sends to the
//!    hub once. Neither token is stored: the hub anchors the device for 30 days after that.

use crate::Res;
use cmux_hub_host::net::{self, Url};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

/// The cmux web deployment's CLI sign-in configuration (also what `coderouter login` reads).
pub const CONFIG_URL: &str = "https://cmux.com/api/cli/config";
/// How long the person has to confirm in the browser (the login code's lifetime).
pub const LOGIN_WITHIN: Duration = Duration::from_secs(15 * 60);
pub const POLL_EVERY: Duration = Duration::from_secs(2);

/// The sign-in service as the web deployment names it.
#[derive(Debug, Clone, PartialEq)]
pub struct AuthConfig {
    /// The Stack API base, e.g. `https://api.stack-auth.com/api/v1`.
    pub api_url: String,
    pub project_id: String,
    /// Absent when the project needs none: then no key header is sent.
    pub publishable_client_key: Option<String>,
    /// The confirmation page that takes `login_code`.
    pub confirm_url: String,
}

/// The access token from `token_file` (this user's 0600 file, or `-` for stdin), or without
/// one from a browser sign-in. Neither is stored.
pub fn access_token(token_file: Option<&str>) -> Res<String> {
    access_token_or(token_file, || sign_in(CONFIG_URL, POLL_EVERY, LOGIN_WITHIN, announce))
}

fn access_token_or(token_file: Option<&str>, sign_in: impl FnOnce() -> Res<String>) -> Res<String> {
    let Some(path) = token_file else {
        return sign_in();
    };
    let text = if path == "-" {
        let mut text = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin().lock(), &mut text)?;
        text
    } else {
        let bytes = cmux_hub_host::identity::read_private(std::path::Path::new(path))?
            .ok_or_else(|| format!("{path} does not exist"))?;
        String::from_utf8(bytes).map_err(|_| format!("{path} is not text"))?
    };
    let token = text.trim().to_owned();
    if token.is_empty() || token.contains(char::is_whitespace) {
        return Err("the access token file must hold one token".into());
    }
    Ok(token)
}

/// Signs in through the browser: shows the confirmation link with `show`, waits for it, and
/// returns a Stack access token.
pub fn sign_in(
    config_url: &str,
    poll_every: Duration,
    within: Duration,
    show: impl FnOnce(&str),
) -> Res<String> {
    sign_in_keeping_refresh(config_url, poll_every, within, show).map(|(access, _)| access)
}

/// [`sign_in`], also returning the refresh token, for a viewer that keeps it (`cmux-rd
/// view`: the hub refuses a viewer's sessions to a device-key session, so each run needs an
/// account session, and a kept refresh token spares the person a browser sign-in per run).
pub fn sign_in_keeping_refresh(
    config_url: &str,
    poll_every: Duration,
    within: Duration,
    show: impl FnOnce(&str),
) -> Res<(String, String)> {
    let config = load_config(config_url)?;
    let started = stack_post(
        &config,
        "/auth/cli",
        &[],
        &json!({ "expires_in_millis": within.as_millis() as u64 }),
    )?;
    let polling_code = text_field(&started, "polling_code")?;
    let login_code = text_field(&started, "login_code")?;
    show(&confirmation_url(&config.confirm_url, &login_code)?);
    let refresh_token = wait_for_confirmation(&config, &polling_code, poll_every, within)?;
    let access = access_from_refresh(&config, &refresh_token)?;
    Ok((access, refresh_token))
}

/// A fresh access token from a kept refresh token (`cmux-rd view` keeps one).
#[cfg(all(feature = "openh264", target_os = "linux"))]
pub fn refresh(config_url: &str, refresh_token: &str) -> Res<String> {
    access_from_refresh(&load_config(config_url)?, refresh_token)
}

fn access_from_refresh(config: &AuthConfig, refresh_token: &str) -> Res<String> {
    let tokens = stack_post(
        config,
        "/auth/sessions/current/refresh",
        &[("x-stack-refresh-token".to_owned(), header_safe(refresh_token)?)],
        &json!({}),
    )?;
    text_field(&tokens, "access_token")
}

/// Prints the link and opens it in this desktop's browser when there is a display.
pub fn announce(url: &str) {
    println!(
        "Sign in to share this desktop. Open this link in a browser (on this machine or any other):\n  {}\nWaiting for the sign-in (up to {} minutes)...",
        cmux_hub_host::printable(url),
        LOGIN_WITHIN.as_secs() / 60
    );
    let has_display = ["DISPLAY", "WAYLAND_DISPLAY"]
        .iter()
        .any(|v| std::env::var_os(v).is_some_and(|d| !d.is_empty()));
    if !has_display {
        return;
    }
    let opened = cmux_process::Command::new("xdg-open")
        .arg(url)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn();
    if let Ok(mut child) = opened {
        // xdg-open may exec the browser itself: ending it would close the page the person
        // is signing in on. It is reaped when this command exits.
        child.detach("xdg-open hands the sign-in link to the person's browser");
    }
}

/// The deployment's configuration, checked: both URLs are HTTPS (or loopback) and every
/// value that becomes a header is one header-safe token.
pub fn load_config(config_url: &str) -> Res<AuthConfig> {
    let response = net::request("GET", &Url::parse(config_url)?, &[], None)?;
    let value: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    if !(200..300).contains(&response.status) {
        return Err(format!(
            "the sign-in configuration is unavailable ({}): {}",
            response.status,
            detail(&value)
        )
        .into());
    }
    let auth = value.get("auth").ok_or("the sign-in configuration has no auth section")?;
    let config = AuthConfig {
        api_url: text_field(auth, "apiUrl")?,
        project_id: text_field(auth, "projectId")?,
        publishable_client_key: auth
            .get("publishableClientKey")
            .and_then(Value::as_str)
            .filter(|k| !k.is_empty())
            .map(header_safe)
            .transpose()?,
        confirm_url: text_field(auth, "confirmUrl")?,
    };
    Url::parse(&config.api_url)?;
    Url::parse(&config.confirm_url)?;
    Ok(config)
}

/// `confirm` with `login_code` added to its query.
pub fn confirmation_url(confirm: &str, login_code: &str) -> Res<String> {
    if confirm.contains('#') {
        return Err("the confirmation URL has a fragment".into());
    }
    let joiner = if confirm.contains('?') { '&' } else { '?' };
    Ok(format!("{confirm}{joiner}login_code={}", query_escape(login_code)))
}

/// Polls until the person confirmed; the refresh token.
fn wait_for_confirmation(
    config: &AuthConfig,
    polling_code: &str,
    poll_every: Duration,
    within: Duration,
) -> Res<String> {
    let deadline = Instant::now() + within;
    loop {
        let poll =
            stack_post(config, "/auth/cli/poll", &[], &json!({ "polling_code": polling_code }))?;
        match poll.get("status").and_then(Value::as_str) {
            Some("waiting") => {}
            Some("success") => return text_field(&poll, "refresh_token"),
            Some(status @ ("expired" | "used")) => {
                return Err(format!("the sign-in link is {status}; run the command again").into())
            }
            other => {
                return Err(format!(
                    "the sign-in service answered an unknown status {}",
                    cmux_hub_host::printable(&format!("{other:?}"))
                )
                .into())
            }
        }
        if Instant::now() + poll_every >= deadline {
            return Err(format!(
                "the sign-in was not confirmed within {} s; run the command again",
                within.as_secs()
            )
            .into());
        }
        std::thread::sleep(poll_every);
    }
}

/// One JSON `POST` to the Stack API as a client of `config`'s project.
fn stack_post(
    config: &AuthConfig,
    path: &str,
    extra: &[(String, String)],
    body: &Value,
) -> Res<Value> {
    let url = Url::join(&config.api_url, path)?;
    let mut headers = vec![
        ("x-stack-project-id".to_owned(), config.project_id.clone()),
        ("x-stack-access-type".to_owned(), "client".to_owned()),
    ];
    if let Some(key) = &config.publishable_client_key {
        headers.push(("x-stack-publishable-client-key".to_owned(), key.clone()));
    }
    headers.extend_from_slice(extra);
    let response = net::request("POST", &url, &headers, Some(&serde_json::to_vec(body)?))?;
    let value: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    if !(200..300).contains(&response.status) {
        return Err(format!(
            "the sign-in service refused {path} ({}): {}",
            response.status,
            detail(&value)
        )
        .into());
    }
    Ok(value)
}

/// A non-empty string field that is safe as a header value or URL part.
fn text_field(value: &Value, key: &str) -> Res<String> {
    let text = value
        .get(key)
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("the sign-in service's answer has no {key}"))?;
    header_safe(text).map_err(|_| format!("the sign-in service's {key} is malformed").into())
}

/// One token of visible ASCII: never splits or extends an HTTP header.
fn header_safe(text: &str) -> Res<String> {
    if text.bytes().all(|b| b.is_ascii_graphic()) {
        Ok(text.to_owned())
    } else {
        Err("the sign-in configuration holds a malformed value".into())
    }
}

/// The service's error text, for the person.
fn detail(value: &Value) -> String {
    let text = ["error", "message", "code"]
        .iter()
        .find_map(|k| value.get(k).and_then(Value::as_str))
        .unwrap_or("no detail");
    cmux_hub_host::printable(&text.chars().take(200).collect::<String>())
}

/// RFC 3986 query escaping (unreserved characters stay).
fn query_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
#[path = "stack_login_tests.rs"]
pub(super) mod tests;
