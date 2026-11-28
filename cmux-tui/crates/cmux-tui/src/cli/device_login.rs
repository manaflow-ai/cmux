//! `cmux login` with no cmux app to answer (an SSH box, a container, CI), or `cmux login --device`:
//! sign in by link and print a personal API token (RFD 0183 piece 9).
//!
//! 1. Stack's CLI login, the one `cmux_cloud_config::cli_sign_in` describes and `cmux-autocloud
//!    login` runs: fetch cmux.com's CLI config, mint a login code, print the confirm link (any
//!    device, a phone works), poll until it is confirmed, trade the refresh token for an access
//!    token.
//! 2. `POST /v1/tokens` on the cmux platform with that access token (cmux-platform#2278 accepts a
//!    person's Stack session there): a `cmux_pat_` token named for this host, every scope, 90 days.
//! 3. Print it: `export CMUX_TOKEN=…` on stdout (so `eval "$(cmux login)"` works), the bare token
//!    with `--quiet`, one object with `--json`. The link and notes go to stderr.
//!
//! The Stack session itself is never saved: the token is the one credential that leaves.

use std::time::{Duration, Instant};

use cmux_cloud_config::cli_sign_in::{self, HttpCall, Polled, Project, Started, Tokens};
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::OutputMode;
use super::api_tokens::{Failure, SCOPES, TOKEN_PREFIX};

pub(super) const USAGE: &str = "\
Usage: cmux login [--device] [--name NAME] [--team TEAM] [--platform URL]

With no cmux app running (or with --device), sign in by link and print a personal API token:
open the link it prints on any device, confirm, and it prints `export CMUX_TOKEN=cmux_pat_…`.
  eval \"$(cmux login)\"          sign this shell in
  cmux login --quiet             only the token
  cmux login --json              {ok, token, name, platform, expiresAt}

  --device         sign in by link even when a cmux app answers (else `cmux login` is `cmux vm sign-in`)
  --name NAME      the token's name (default: cmux login on HOST)
  --team TEAM      mint it for this team (x-cmux-team)
  --platform URL   the cmux platform (default: production; or CMUX_PLATFORM_URL)
CMUX_CLI_CONFIG_URL names the sign-in config (default https://cmux.com/api/cli/config).
Revoke it with `cmux token revoke NAME`.";

const DEFAULT_CONFIG_URL: &str = "https://cmux.com/api/cli/config";
const EXPIRY_DAYS: u32 = 90;
const TIMEOUT: Duration = Duration::from_secs(30);
/// Stack's code lives `LOGIN_EXPIRES_IN_MS`; stop polling a minute after, whatever Stack says.
const POLL_BOUND: Duration = Duration::from_millis(cli_sign_in::LOGIN_EXPIRES_IN_MS + 60_000);

#[derive(Debug, Default, Clone, PartialEq)]
pub(super) struct Options {
    pub device: bool,
    pub help: bool,
    pub name: Option<String>,
    pub team: Option<String>,
    pub platform: Option<String>,
}

/// `cmux [globals] login [ours…]`: Some when this module answers it — `--device`, or no app
/// answers the control socket. Everything else (`logout`, an app is up, a flag we don't know)
/// stays `cmux vm sign-in`'s.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let (verb, rest) = command.split_first()?;
    if verb != "login" {
        return None;
    }
    let options = parse(rest).ok()?;
    if !options.device && super::pane_context::app_reachable(global.app_socket.as_deref()) {
        return None;
    }
    if options.help {
        println!("{USAGE}");
        return Some(0);
    }
    let env = |key: &str| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    let host = super::chief::caller::host_name();
    let mut notice = |line: &str| eprintln!("{line}");
    let output = global.output;
    Some(match execute(&options, &env, host.as_deref(), cli_sign_in_interval(), &mut notice) {
        Ok(minted) => print_minted(&minted, output),
        Err(failure) => {
            match output {
                OutputMode::Json | OutputMode::JsonLines => println!("{}", failure.json()),
                OutputMode::Human | OutputMode::Quiet => eprintln!("cmux: {}", failure.message),
            }
            failure.exit
        }
    })
}

fn cli_sign_in_interval() -> Duration {
    Duration::from_millis(cli_sign_in::POLL_INTERVAL_MS)
}

/// The words after `login`; Err on anything else, so `vm sign-in` keeps its own flags.
pub(super) fn parse(rest: &[String]) -> Result<Options, String> {
    let mut options = Options::default();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |name: &str| {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match flag {
            "--device" => options.device = true,
            "-h" | "--help" => options.help = true,
            "--name" => options.name = Some(value("--name")?),
            "--team" => options.team = Some(value("--team")?),
            "--platform" => options.platform = Some(value("--platform")?),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(options)
}

/// The token's name: `--name`, else `cmux login on HOST`.
pub(super) fn token_name(options: &Options, host: Option<&str>) -> String {
    if let Some(name) = &options.name {
        return name.clone();
    }
    let host: String = host
        .map(str::trim)
        .filter(|h| !h.is_empty())
        .unwrap_or("this machine")
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect();
    format!("cmux login on {host}")
}

/// A URL a sign-in may go to: https, or http only on this machine (a local stack, a test).
fn checked_url(raw: &str, what: &str) -> Result<reqwest::Url, Failure> {
    let url = reqwest::Url::parse(raw.trim())
        .map_err(|_| usage(format!("{what} is not a URL: {raw}")))?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err(usage(format!("{what} is not https: a sign-in never goes over plain http")));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(usage(format!("{what} carries a user or password")));
    }
    Ok(url)
}

fn failure(code: &str, message: impl Into<String>) -> Failure {
    Failure { code: code.into(), message: message.into(), retryable: false, exit: 1 }
}

fn usage(message: String) -> Failure {
    Failure { exit: 2, ..failure("cli.invalid_args", message) }
}

/// What a sign-in minted.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Minted {
    pub token: String,
    pub name: String,
    pub platform: String,
    pub expires_at: Option<String>,
}

/// The whole flow. `notice` gets the lines a person reads (the link, waiting); `interval` is the
/// poll pace (Stack's two seconds; tests go faster).
pub(super) fn execute(
    options: &Options,
    env: &dyn Fn(&str) -> Option<String>,
    host: Option<&str>,
    interval: Duration,
    notice: &mut dyn FnMut(&str),
) -> Result<Minted, Failure> {
    let config_url = env("CMUX_CLI_CONFIG_URL").unwrap_or_else(|| DEFAULT_CONFIG_URL.to_owned());
    let config_url = checked_url(&config_url, "the sign-in config URL")?;
    let named = options
        .platform
        .clone()
        .or_else(|| env("CMUX_PLATFORM_URL").or_else(|| env("CMUX_PLATFORM_ORIGIN")))
        .unwrap_or_else(|| cmux_cloud_environment::PRODUCTION_PLATFORM.to_owned());
    let platform = super::cloud_client_session::secure_origin(named.trim())
        .map_err(|m| usage(m.replace("the cmux API", "the cmux platform")))?;
    let http = Http::new()?;
    let (project, web) = http.config(config_url)?;
    let access = http.stack_login(&project, &web, interval, POLL_BOUND, notice)?;
    let name = token_name(options, host);
    let body = http.mint(&platform, &access, options.team.as_deref(), &name)?;
    let token = body.get("token").and_then(Value::as_str).unwrap_or_default().to_owned();
    let expires_at = body
        .get("tokenInfo")
        .and_then(|info| info.get("expiresAt"))
        .or_else(|| body.get("expiresAt"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    Ok(Minted { token, name, platform, expires_at })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliConfig {
    auth: CliAuth,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliAuth {
    api_url: String,
    project_id: String,
    publishable_client_key: String,
    confirm_url: String,
}

pub(super) struct Http {
    client: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

impl Http {
    pub(super) fn new() -> Result<Self, Failure> {
        let internal = |e: &dyn std::fmt::Display| failure("internal", e.to_string());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| internal(&e))?;
        let space = cmux_build_space::headers().map_err(|e| internal(&e))?;
        // Through the egress gate (docs/privacy.md): cmux.com, Stack Auth and the platform.
        let client = cmux_egress::client_builder("cmux_tui::cli::device_login")
            .default_headers(space)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(TIMEOUT)
            .build()
            .map_err(|e| internal(&e))?;
        Ok(Self { client, runtime })
    }

    fn send(&self, call: &HttpCall) -> Result<(u16, String), String> {
        let method =
            reqwest::Method::from_bytes(call.method.as_bytes()).map_err(|e| e.to_string())?;
        let mut request = self.client.request(method, &call.url).body(call.body.clone());
        for (key, value) in &call.headers {
            request = request.header(key, value);
        }
        self.runtime.block_on(async {
            let response = request.send().await.map_err(|e| e.without_url().to_string())?;
            let status = response.status().as_u16();
            Ok((status, response.text().await.unwrap_or_default()))
        })
    }

    /// cmux.com's CLI config: the Stack project, and the web origin its confirm page lives on.
    fn config(&self, url: reqwest::Url) -> Result<(Project, String), Failure> {
        let unreachable = |why: String| Failure {
            retryable: true,
            ..failure(
                "auth.unreachable",
                format!("could not read the sign-in config at {url}: {why}"),
            )
        };
        let (status, body) = self
            .send(&HttpCall {
                method: "GET".into(),
                url: url.to_string(),
                headers: vec![],
                body: String::new(),
            })
            .map_err(unreachable)?;
        if !(200..300).contains(&status) {
            return Err(unreachable(format!("it answered {status}")));
        }
        let config: CliConfig = serde_json::from_str(&body).map_err(|_| {
            failure("auth.invalid_config", format!("the sign-in config at {url} is not one"))
        })?;
        let stack = checked_url(&config.auth.api_url, "the sign-in config's Stack URL")?;
        let web = checked_url(&config.auth.confirm_url, "the sign-in config's confirm URL")?;
        let project = Project {
            stack_base_url: stack.as_str().trim_end_matches('/').to_owned(),
            project_id: config.auth.project_id,
            publishable_client_key: config.auth.publishable_client_key,
        };
        Ok((project, web.origin().ascii_serialization()))
    }

    /// Stack's CLI login, start to access token.
    pub(super) fn stack_login(
        &self,
        project: &Project,
        web: &str,
        interval: Duration,
        bound: Duration,
        notice: &mut dyn FnMut(&str),
    ) -> Result<Zeroizing<String>, Failure> {
        let ended = |reason: String| {
            failure(
                "auth.sign_in_ended",
                format!("the sign-in ended ({reason}): run `cmux login` again"),
            )
        };
        let (status, body) =
            self.send(&cli_sign_in::start_request(project)).map_err(|why| Failure {
                retryable: true,
                ..failure("auth.unreachable", format!("Stack Auth did not answer: {why}"))
            })?;
        let (polling_code, confirm_url) = match cli_sign_in::read_start(status, &body, web) {
            Started::Started { polling_code, confirm_url, .. } => {
                (Zeroizing::new(polling_code), confirm_url)
            }
            Started::Refused { reason } => {
                return Err(failure(
                    "auth.refused",
                    format!("Stack Auth refused the sign-in ({reason})"),
                ));
            }
        };
        notice(&format!(
            "Open this link on any device and confirm:\n\n  {confirm_url}\n\nWaiting…"
        ));
        let deadline = Instant::now() + bound;
        let refresh = loop {
            if Instant::now() >= deadline {
                return Err(ended("nobody confirmed the link in time".into()));
            }
            std::thread::sleep(interval);
            // A bad link or a 429: keep polling until the code expires.
            let Ok((status, body)) = self.send(&cli_sign_in::poll_request(project, &polling_code))
            else {
                continue;
            };
            match cli_sign_in::read_poll(status, &body) {
                Polled::Waiting | Polled::Retry { .. } => {}
                Polled::SignedIn { refresh_token } => break Zeroizing::new(refresh_token),
                Polled::Ended { reason } => return Err(ended(reason)),
            }
        };
        let (status, body) =
            self.send(&cli_sign_in::token_request(project, &refresh)).map_err(|why| Failure {
                retryable: true,
                ..failure("auth.unreachable", format!("Stack Auth did not answer: {why}"))
            })?;
        match cli_sign_in::read_token(status, &body, &refresh) {
            Tokens::Tokens { access_token, .. } => Ok(Zeroizing::new(access_token)),
            Tokens::Refused { reason } => Err(failure(
                "auth.refused",
                format!("Stack Auth did not issue a session ({reason})"),
            )),
        }
    }

    /// `POST /v1/tokens` with the person's Stack session: the token's whole answer.
    pub(super) fn mint(
        &self,
        platform: &str,
        access: &str,
        team: Option<&str>,
        name: &str,
    ) -> Result<Value, Failure> {
        let body = json!({"name": name, "scopes": SCOPES, "expiresInDays": EXPIRY_DAYS});
        let mut headers = vec![
            ("authorization".to_owned(), format!("Bearer {access}")),
            ("accept".to_owned(), "application/json".to_owned()),
            ("content-type".to_owned(), "application/json".to_owned()),
        ];
        if let Some(team) = team {
            headers.push(("x-cmux-team".to_owned(), team.to_owned()));
        }
        let call = HttpCall {
            method: "POST".into(),
            url: format!("{}/v1/tokens", platform.trim_end_matches('/')),
            headers,
            body: body.to_string(),
        };
        let (status, text) = self.send(&call).map_err(|why| Failure {
            retryable: true,
            ..failure("api.unreachable", format!("the cmux platform did not answer: {why}"))
        })?;
        let answer: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if !(200..300).contains(&status) {
            return Err(super::api_tokens::refusal(status, &answer));
        }
        let token = answer.get("token").and_then(Value::as_str).unwrap_or_default();
        if !token.starts_with(TOKEN_PREFIX) {
            return Err(failure(
                "api.invalid_response",
                "the platform answered without a cmux_pat_ token",
            ));
        }
        Ok(answer)
    }
}

/// `export CMUX_TOKEN=…`, quoted when the token holds anything a shell would read.
pub(super) fn export_line(token: &str) -> String {
    let plain = token.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'));
    if plain {
        format!("export CMUX_TOKEN={token}")
    } else {
        format!("export CMUX_TOKEN='{}'", token.replace('\'', "'\\''"))
    }
}

pub(super) fn json_answer(minted: &Minted) -> Value {
    json!({
        "ok": true,
        "token": minted.token,
        "name": minted.name,
        "platform": minted.platform,
        "expiresAt": minted.expires_at,
    })
}

fn print_minted(minted: &Minted, output: OutputMode) -> i32 {
    match output {
        OutputMode::Json | OutputMode::JsonLines => println!("{}", json_answer(minted)),
        OutputMode::Quiet => println!("{}", minted.token),
        OutputMode::Human => {
            println!("{}", export_line(&minted.token));
            eprintln!(
                "Signed in: made the API token \"{}\" (expires {}). Store it now: it is not shown again.\n\
                 Run the export line above to sign this shell in; `cmux token revoke` ends it.",
                minted.name,
                minted
                    .expires_at
                    .as_deref()
                    .map(|d| d.get(..10).unwrap_or(d))
                    .unwrap_or("in 90 days"),
            );
        }
    }
    0
}

#[cfg(test)]
#[path = "device_login_tests.rs"]
mod tests;
