//! `cmux inference gateway`: the one place a team's subscription login lives.
//!
//! Leo, 2026-11-07: "Build cmux inference gateway once, so the same code runs
//! on either. [...] Either way, VMs stop holding tokens, which was the main
//! gain."
//!
//! The gateway dials out to the cmux backend and holds one WebSocket
//! (`cmux.inference-gateway/1`, cmux-platform `InferenceGateway.ts`), so it
//! needs no inbound port. A Cloud machine's model call (Codex's
//! `/v1/responses`, Claude Code's `/v1/messages`) reaches the backend through
//! the machine's coderouter edge, comes down that socket, and is answered here
//! from a login only this process holds:
//!
//! cmux runs the gateway (a tiny machine per person or team, or the person's
//! own Mac mini or SR2); the subscription proxy behind it is the person's own
//! choice and responsibility, so nothing is picked by default:
//! - `--upstream URL`: the person's own subscription proxy (CLIProxyAPI, or
//!   their own router), which holds the login and refreshes it.
//! - `--codex-auth PATH`: opt in to letting the gateway itself hold a Codex
//!   login (`codex login` with `CODEX_HOME` at the gateway's own folder). It
//!   sends the call to ChatGPT's Codex backend and refreshes the token,
//!   writing the rotated refresh token back to that file.
//!
//! It runs the same on a gateway machine, a Mac mini or SR2. The backend's
//! token for this socket comes from `--token-file` (read again on every
//! connect), `--token-command` (run again on every connect), or
//! `CMUX_CLOUD_ACCESS_TOKEN`; by default it runs `cmux auth token`, the
//! signed-in app's short-lived token. Nothing here logs a token, a header
//! value or a body: one line per call names the machine, the path, the status
//! and the time.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::sync::{Mutex, mpsc};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use super::cloud_client_session::secure_origin;

const PROTOCOL: &str = "cmux.inference-gateway/1";
const CONNECT_PATH: &str = "/v1/cloud/inference-gateway/connect";
/// The person's own gateway: it serves every machine they created, in any team (a shared chat spends its owner's login).
const PERSONAL_CONNECT_PATH: &str = "/v1/cloud/inference-gateway/personal/connect";
/// The exact text the backend's runtime answers without waking the object.
const PING: &str = r#"{"v":1,"t":"ping"}"#;
const PING_EVERY: Duration = Duration::from_secs(20);
/// Nothing heard for this long (the API answers every ping with a pong): the path is dead, so redial.
const SILENT_FOR: Duration = Duration::from_secs(70);
/// Calls this gateway takes at once (the API's own cap per team); one more is answered busy.
const MAX_CALLS: usize = 32;
/// All calls' request bodies held at once, from the first body frame until the provider call ends.
const MAX_HELD_BYTES: usize = 64 * 1024 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
/// The backend refuses a frame over 1 MiB; answer chunks stay well under it once base64'd.
const CHUNK_BYTES: usize = 192 * 1024;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
/// Answer frames queued for the socket at most (each at most about 256 KiB once base64'd).
const OUT_FRAMES: usize = 32;
/// A provider call may take minutes before its first byte (a long reasoning turn).
const UPSTREAM_HEADERS_TIMEOUT: Duration = Duration::from_secs(600);
/// A provider answer that sends nothing for this long is given up, and its call's slot freed.
const UPSTREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(300);
const CODEX_BACKEND: &str = "https://chatgpt.com/backend-api/codex";
const CODEX_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const CODEX_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
/// An access token this close to its expiry is refreshed before a call.
const REFRESH_SKEW_S: u64 = 300;
/// Request headers a call carries upstream; the backend already dropped the guest's.
const PASS_HEADERS: &[&str] = &[
    "accept",
    "content-type",
    "openai-beta",
    "session_id",
    "user-agent",
    "anthropic-version",
    "anthropic-beta",
];
/// Answer headers sent back; the backend keeps an allowlist of its own.
const ANSWER_HEADERS: &[&str] = &[
    "content-type",
    "openai-model",
    "openai-processing-ms",
    "x-request-id",
    "request-id",
    "retry-after",
    "x-codex-primary-used-percent",
    "x-codex-secondary-used-percent",
    "x-codex-primary-reset-after-seconds",
    "x-codex-secondary-reset-after-seconds",
    "anthropic-ratelimit-unified-status",
];

const HELP: &str = "\
cmux inference gateway: hold your subscription login in one place and serve
your Cloud machines' model calls from it. Machines never get the token.

Usage:
  cmux inference gateway [--api URL] [--team TEAM] [--personal]
                         (--upstream URL [--upstream-key-file PATH] | --codex-auth PATH)
                         [--token-file PATH | --token-command CMD]

  --api URL              the cmux API origin (or CMUX_CLOUD_API_URL)
  --team TEAM            the team whose machines it serves (default: the token's)
  --personal             serve your own machines in every team instead (your own
                         gateway; turn it on with `cmux inference gateway mode
                         gateway --personal`). A shared chat spends its owner's login.
  --upstream URL         your own subscription proxy (CLIProxyAPI or your own
                         router) that holds your login: calls go to URL + the
                         call's path. Running it is your choice and yours to keep.
  --upstream-key-file P  the proxy's own API key, sent as a bearer
  --codex-auth PATH      or opt in to the gateway holding a Codex login itself
                         and refreshing it. Make one with: CODEX_HOME=DIR codex login

One of --upstream or --codex-auth is required: cmux picks no proxy for you.
  --token-file PATH      a cmux access token, read again on every connect
  --token-command CMD    a command that prints one, run again on every connect
                         (default: cmux auth token; or CMUX_CLOUD_ACCESS_TOKEN)

The team's machines use the gateway once the team is in gateway mode
(`cmux inference gateway mode gateway`). State and routing, with --json:
{admin}  cmux inference route --machine vm_... [--agent claude|codex] [--json]

Setup on a Freestyle VM, a Mac mini or an SR2 box: docs/inference-gateway.md in cmux-tui.
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum TokenSource {
    File(PathBuf),
    Command(String),
    Env,
    App,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Upstream {
    Codex { auth: PathBuf },
    Proxy { base: String, key_file: Option<PathBuf> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Options {
    pub api: String,
    pub team: Option<String>,
    /// Serve the person's own gateway (`user:<id>`) rather than the team's.
    pub personal: bool,
    pub token: TokenSource,
    pub upstream: Upstream,
}

fn help() -> String {
    HELP.replace("{admin}", super::inference_gateway_admin::ADMIN_HELP)
}

/// `Some(exit code)` when `args` is `inference gateway …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        print!("{}", help());
        return Some(0);
    }
    // `status` and `mode`: the gateway's state, as one JSON object with --json (inference_gateway_admin.rs).
    if rest.first().is_some_and(|w| w == "status" || w == "mode") {
        return Some(super::inference_gateway_admin::run_words(
            rest,
            global.output == super::OutputMode::Json,
        ));
    }
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    match parse(rest, &env) {
        Ok(options) => Some(run(options)),
        Err(error) => {
            eprintln!("cmux inference gateway: {error}\n\n{}", help());
            Some(2)
        }
    }
}

/// `Some(args after "inference gateway")`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    match command_args {
        [a, b, rest @ ..] if a == "inference" && b == "gateway" => Some(rest),
        _ => None,
    }
}

pub(super) fn parse(
    rest: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Options, String> {
    let mut api = None;
    let mut team = None;
    let mut personal = false;
    let mut codex_auth = None;
    let mut upstream = None;
    let mut key_file = None;
    let mut token = None;
    let mut args = rest.iter();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| args.next().cloned())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--api" => api = Some(value()?),
            "--team" => team = Some(value()?),
            "--personal" if inline.is_none() => personal = true,
            "--codex-auth" => codex_auth = Some(PathBuf::from(value()?)),
            "--upstream" => upstream = Some(value()?),
            "--upstream-key-file" => key_file = Some(PathBuf::from(value()?)),
            "--token-file" => set_token(&mut token, TokenSource::File(PathBuf::from(value()?)))?,
            "--token-command" => set_token(&mut token, TokenSource::Command(value()?))?,
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }
    let api = api
        .or_else(|| env("CMUX_CLOUD_API_URL"))
        .ok_or("--api (or CMUX_CLOUD_API_URL) names the cmux API")?;
    let api = secure_origin(&api)?;
    let upstream = match (codex_auth, upstream) {
        (Some(_), Some(_)) => {
            return Err("--codex-auth and --upstream are two different gateways; pick one".into());
        }
        (None, Some(base)) => {
            let url =
                reqwest::Url::parse(&base).map_err(|_| "--upstream is not a URL".to_owned())?;
            if !matches!(url.scheme(), "http" | "https")
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err("--upstream must be an http(s) URL with no query or fragment".into());
            }
            // The URL is logged; a key goes in --upstream-key-file, never in the URL.
            if !url.username().is_empty() || url.password().is_some() {
                return Err(
                    "--upstream takes no user or password; put the key in --upstream-key-file"
                        .into(),
                );
            }
            // Plain http only stays on this computer or a private network (a LAN, a tailnet), and a key only
            // goes over it to this computer.
            match (url.scheme(), plain_http_reach(&url)) {
                ("https", _) | ("http", Reach::Loopback) => {}
                ("http", Reach::Private) if key_file.is_none() => {}
                ("http", Reach::Private) => {
                    return Err(
                        "--upstream-key-file goes over https, or plain http to this computer"
                            .into(),
                    );
                }
                _ => {
                    return Err("--upstream must be https, or plain http to this computer or a private network".into());
                }
            }
            Upstream::Proxy { base: base.trim_end_matches('/').to_owned(), key_file }
        }
        (Some(auth), None) => {
            if key_file.is_some() {
                return Err("--upstream-key-file goes with --upstream".into());
            }
            Upstream::Codex { auth }
        }
        (None, None) => {
            return Err(
                "name your subscription proxy with --upstream URL (or opt in to --codex-auth PATH); cmux picks none for you"
                    .into(),
            );
        }
    };
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    Ok(Options { api, team, personal, token, upstream })
}

#[derive(Debug, PartialEq)]
enum Reach {
    Loopback,
    Private,
    Public,
}

/// Where a plain-http upstream's traffic travels: this computer, a private network (RFC 1918, a tailnet's 100.64/10 or
/// `*.ts.net`, IPv6 ULA), or the open internet.
fn plain_http_reach(url: &reqwest::Url) -> Reach {
    use std::net::IpAddr;
    let ip = match url.host() {
        Some(url::Host::Ipv4(ip)) => IpAddr::V4(ip),
        Some(url::Host::Ipv6(ip)) => IpAddr::V6(ip),
        Some(url::Host::Domain(name)) => {
            let name = name.to_ascii_lowercase();
            return if name == "localhost" {
                Reach::Loopback
            } else if name.ends_with(".ts.net") {
                Reach::Private
            } else {
                Reach::Public
            };
        }
        None => return Reach::Public,
    };
    if ip.is_loopback() {
        return Reach::Loopback;
    }
    let private = match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            v4.is_private() || (a == 100 && (64..128).contains(&b))
        }
        IpAddr::V6(v6) => (v6.segments()[0] & 0xfe00) == 0xfc00,
    };
    if private { Reach::Private } else { Reach::Public }
}

/// A request path as the log shows it: no query, and nothing but plain path characters.
fn log_path(path: &str) -> String {
    let path = path.split(['?', '#']).next().unwrap_or_default();
    printable(path)
}

/// A value for a log line: only letters, digits and `/_.:-`, at most 120 of them, so no value can forge a line.
fn printable(value: &str) -> String {
    value.chars().filter(|c| c.is_ascii_alphanumeric() || "/_.:-".contains(*c)).take(120).collect()
}

fn set_token(slot: &mut Option<TokenSource>, source: TokenSource) -> Result<(), String> {
    if slot.replace(source).is_some() {
        return Err("--token-file and --token-command: pick one".into());
    }
    Ok(())
}

fn log(line: &str) {
    let mut err = std::io::stderr().lock();
    let _ = writeln!(err, "cmux inference gateway: {line}");
}

fn run(options: Options) -> i32 {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            log(&format!("cannot start: {error}"));
            return 1;
        }
    };
    runtime.block_on(serve(options))
}

/// The backend's token for one connect, from the configured source.
pub(super) async fn backend_token(
    source: &TokenSource,
    team: Option<&str>,
) -> Result<String, String> {
    let raw = match source {
        TokenSource::Env => std::env::var("CMUX_CLOUD_ACCESS_TOKEN").unwrap_or_default(),
        TokenSource::File(path) => tokio::fs::read_to_string(path)
            .await
            .map_err(|e| format!("cannot read the token file: {e}"))?,
        TokenSource::Command(cmd) => command_output("/bin/sh", &["-c", cmd]).await?,
        TokenSource::App => {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            // An install token acts only for the team it was minted for: mint it for the gateway's team.
            let mut args = vec!["auth", "token"];
            if let Some(team) = team {
                args.extend(["--team", team]);
            }
            command_output(&exe.to_string_lossy(), &args).await?
        }
    };
    let token = raw.trim();
    // `cmux auth token --json` and friends: take its access_token.
    let token = match serde_json::from_str::<Value>(token) {
        Ok(Value::Object(o)) => {
            o.get("access_token").and_then(Value::as_str).unwrap_or_default().to_owned()
        }
        _ => token.to_owned(),
    };
    if token.is_empty() || token.contains(char::is_whitespace) {
        return Err(
            "no cmux access token (sign in to cmux, or pass --token-file or --token-command)"
                .into(),
        );
    }
    Ok(token)
}

/// The model paths a machine may call, the same list as the cmux-platform Worker's `GATEWAY_CALL_PATH`.
const PROXY_PATHS: &[&str] = &[
    "/v1/responses",
    "/v1/responses/compact",
    "/v1/models",
    "/v1/messages",
    "/v1/messages/count_tokens",
    "/v1/chat/completions",
];

/// The proxy's URL for a call's path, or `None` for a path the gateway does not serve. The Worker already refuses
/// other paths; checking again here means a path such as `@other.host/x` can never carry the proxy's key elsewhere.
/// An OpenAI-style base that already ends in `/v1` takes the path without its own `/v1`, so
/// `--upstream http://host/v1` and `--upstream http://host` reach the same place.
fn proxy_url(base: &str, path: &str) -> Option<String> {
    let route = path.split_once('?').map_or(path, |(route, _)| route);
    if !PROXY_PATHS.contains(&route) {
        return None;
    }
    Some(match path.strip_prefix("/v1/") {
        Some(rest) if base.ends_with("/v1") => format!("{base}/{rest}"),
        _ => format!("{base}{path}"),
    })
}

async fn command_output(program: &str, args: &[&str]) -> Result<String, String> {
    let (program, args) =
        (program.to_owned(), args.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>());
    // A token is far smaller than a pipe's buffer, so the child never blocks on its output while we wait.
    let out = tokio::task::spawn_blocking(move || {
        let mut child = cmux_process::Command::new(&program)
            .args(&args)
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null())
            .spawn()
            .map_err(|e| format!("cannot run the token command: {e}"))?;
        if child.wait_timeout(Duration::from_secs(40)).map_err(|e| e.to_string())?.is_none() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("the token command timed out".to_owned());
        }
        child.wait_with_output().map_err(|e| format!("cannot run the token command: {e}"))
    })
    .await
    .map_err(|_| "the token command did not finish".to_owned())??;
    if !out.status.success() {
        return Err(format!("the token command failed ({})", out.status));
    }
    String::from_utf8(out.stdout).map_err(|_| "the token command printed non-UTF-8".into())
}

/// Why a socket ended.
#[derive(Debug, PartialEq, Eq)]
enum Ended {
    /// Another gateway took the team's socket, or the team un-named this machine: stop.
    Stop(String),
    /// The backend refused the connect (a bad token or no access).
    Refused(u16),
    /// The socket closed or broke: dial again.
    Closed(String),
}

async fn serve(options: Options) -> i32 {
    let http = match reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(15))
        .user_agent(concat!("cmux-inference-gateway/", env!("CARGO_PKG_VERSION")))
        .build()
    {
        Ok(http) => http,
        Err(error) => {
            log(&format!("cannot make an HTTP client: {error}"));
            return 1;
        }
    };
    let upstream = Arc::new(Provider::new(options.upstream.clone(), http));
    if let Err(error) = upstream.check().await {
        log(&error);
        return 2;
    }
    let mut backoff = Duration::from_secs(1);
    let mut refusals = 0u32;
    loop {
        let started = Instant::now();
        let ended = match backend_token(&options.token, options.team.as_deref()).await {
            Ok(token) => session(&options, &token, upstream.clone()).await,
            Err(error) => Ended::Closed(error),
        };
        match ended {
            Ended::Stop(reason) => {
                log(&format!("stopped: {reason}"));
                return 3;
            }
            Ended::Refused(status) => {
                refusals += 1;
                log(&format!("the cmux API refused the gateway (HTTP {status})"));
                if status == 403 || refusals >= 5 {
                    return 2;
                }
            }
            Ended::Closed(reason) => {
                refusals = 0;
                log(&format!("disconnected ({reason}); dialing again"));
            }
        }
        // A socket that lived a while (the backend's 10-minute re-check) dials again at once.
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_millis(200);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).clamp(Duration::from_secs(1), Duration::from_secs(30));
    }
}

/// A call being received: its head, then its body.
struct Pending {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

async fn session(options: &Options, token: &str, upstream: Arc<Provider>) -> Ended {
    let path = if options.personal { PERSONAL_CONNECT_PATH } else { CONNECT_PATH };
    let url = format!("{}{path}", options.api.replacen("http", "ws", 1));
    let mut request = match url.into_client_request() {
        Ok(r) => r,
        Err(e) => return Ended::Stop(format!("bad API URL: {e}")),
    };
    let Ok(mut bearer) = HeaderValue::from_str(&format!("Bearer {token}")) else {
        return Ended::Closed("the token is not a valid header value".into());
    };
    bearer.set_sensitive(true);
    request.headers_mut().insert("authorization", bearer);
    if let Some(team) = options.team.as_deref().and_then(|t| HeaderValue::from_str(t).ok()) {
        request.headers_mut().insert("x-cmux-team", team);
    }
    // No Sec-WebSocket-Protocol: the backend (InferenceGateway.ts) negotiates none, and tungstenite refuses a
    // handshake whose offered protocol the server does not echo. The version is checked on its `hello` frame below.
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let connect = tokio_tungstenite::connect_async_with_config(request, Some(config), false);
    let stream = match tokio::time::timeout(HANDSHAKE_TIMEOUT, connect).await {
        Err(_) => return Ended::Closed("handshake timed out".into()),
        Ok(Err(tokio_tungstenite::tungstenite::Error::Http(response))) => {
            return Ended::Refused(response.status().as_u16());
        }
        Ok(Err(e)) => return Ended::Closed(e.to_string()),
        Ok(Ok((stream, _))) => stream,
    };
    let (mut sink, mut source) = stream.split();
    // Bounded: a slow socket holds back the provider streams (backpressure) instead of piling their chunks in memory.
    let (tx, mut rx) = mpsc::channel::<String>(OUT_FRAMES);
    let writer = tokio::spawn(async move {
        let mut ping = tokio::time::interval(PING_EVERY);
        ping.tick().await;
        loop {
            tokio::select! {
                frame = rx.recv() => match frame {
                    Some(text) => if sink.send(Message::Text(text.into())).await.is_err() { break },
                    None => break,
                },
                _ = ping.tick() => if sink.send(Message::Text(PING.into())).await.is_err() { break },
            }
        }
        let _ = sink.close().await;
    });
    let mut pending: HashMap<String, Pending> = HashMap::new();
    // Each running call's task and the body bytes it holds.
    let mut running: HashMap<String, (tokio::task::AbortHandle, usize)> = HashMap::new();
    let mut held = 0usize;
    let (done_tx, mut done_rx) = mpsc::unbounded_channel::<String>();
    let mut heard = tokio::time::Instant::now();
    let mut watch = tokio::time::interval(Duration::from_secs(10));
    let ended = loop {
        let message = tokio::select! {
            m = source.next() => m,
            Some(id) = done_rx.recv() => {
                if let Some((_, bytes)) = running.remove(&id) {
                    held -= bytes;
                }
                continue
            }
            _ = watch.tick() => {
                if heard.elapsed() > SILENT_FOR {
                    break Ended::Closed(format!("nothing heard for {} s", SILENT_FOR.as_secs()));
                }
                continue
            }
        };
        heard = tokio::time::Instant::now();
        let text = match message {
            None => break Ended::Closed("the socket ended".into()),
            Some(Err(e)) => break Ended::Closed(e.to_string()),
            Some(Ok(Message::Text(text))) => text.to_string(),
            Some(Ok(Message::Close(frame))) => {
                let reason = frame.map(|f| f.reason.to_string()).unwrap_or_default();
                break match reason.as_str() {
                    "replaced" => Ended::Stop(if options.personal {
                        "another gateway of yours took over (it serves your machines now)".into()
                    } else {
                        "another gateway took over this team's socket".into()
                    }),
                    "unnamed" => {
                        Ended::Stop("the team no longer names this machine as its gateway".into())
                    }
                    "" => Ended::Closed("closed".into()),
                    other => Ended::Closed(other.to_owned()),
                };
            }
            Some(Ok(_)) => continue,
        };
        let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
        let id = frame.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
        match frame.get("t").and_then(Value::as_str) {
            Some("hello") => {
                if frame.get("protocol").and_then(Value::as_str) != Some(PROTOCOL) {
                    break Ended::Stop(format!(
                        "the cmux API speaks another gateway protocol than this CLI's {PROTOCOL}; run the cmux CLI that ships with your cmux app"
                    ));
                }
                log(&format!(
                    "connected to {}; serving {}",
                    options.api,
                    if options.personal { "your own machines" } else { "the team's machines" }
                ));
            }
            Some("request") if !id.is_empty() => {
                if pending.len() + running.len() >= MAX_CALLS {
                    let busy = error_frame(
                        &id,
                        "inference.gateway_busy",
                        "the gateway is at its call limit; retry",
                    );
                    send(&tx, &busy).await;
                    continue;
                }
                let headers = frame
                    .get("headers")
                    .and_then(Value::as_object)
                    .map(|h| {
                        h.iter()
                            .filter_map(|(k, v)| {
                                Some((k.to_ascii_lowercase(), v.as_str()?.to_owned()))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                pending.insert(
                    id,
                    Pending {
                        method: frame
                            .get("method")
                            .and_then(Value::as_str)
                            .unwrap_or("POST")
                            .to_owned(),
                        path: frame
                            .get("path")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        headers,
                        body: Vec::new(),
                    },
                );
            }
            Some("body") => {
                let Some(call) = pending.get_mut(&id) else { continue };
                let chunk = frame
                    .get("data")
                    .and_then(Value::as_str)
                    .and_then(|d| base64::engine::general_purpose::STANDARD.decode(d).ok());
                match chunk {
                    Some(bytes)
                        if call.body.len() + bytes.len() <= MAX_BODY_BYTES
                            && held + bytes.len() <= MAX_HELD_BYTES =>
                    {
                        held += bytes.len();
                        call.body.extend(bytes);
                    }
                    _ => {
                        if let Some(call) = pending.remove(&id) {
                            held -= call.body.len();
                        }
                        send(
                            &tx,
                            &error_frame(
                                &id,
                                "inference.bad_request",
                                "the request body did not arrive whole",
                            ),
                        )
                        .await;
                    }
                }
            }
            Some("body_end") => {
                let Some(call) = pending.remove(&id) else { continue };
                let bytes = call.body.len();
                let (tx, done, upstream) = (tx.clone(), done_tx.clone(), upstream.clone());
                let key = id.clone();
                let task = tokio::spawn(async move {
                    answer(&upstream, &key, call, &tx).await;
                    let _ = done.send(key);
                });
                running.insert(id, (task.abort_handle(), bytes));
            }
            Some("cancel") => {
                if let Some(call) = pending.remove(&id) {
                    held -= call.body.len();
                }
                if let Some((task, bytes)) = running.remove(&id) {
                    task.abort();
                    held -= bytes;
                }
            }
            _ => {}
        }
    };
    for (task, _) in running.values() {
        task.abort();
    }
    drop(tx);
    let _ = writer.await;
    ended
}

/// Queues a frame for the socket, waiting while the queue is full; a closed socket drops it.
async fn send(tx: &mpsc::Sender<String>, frame: &Value) {
    let _ = tx.send(frame.to_string()).await;
}

fn error_frame(id: &str, code: &str, message: &str) -> Value {
    json!({"v": 1, "t": "error", "id": id, "code": code, "message": message})
}

/// One call: to the provider, and its answer back down the socket as it streams.
async fn answer(upstream: &Provider, id: &str, call: Pending, tx: &mpsc::Sender<String>) {
    let started = Instant::now();
    let machine = call
        .headers
        .iter()
        .find(|(k, _)| k == "x-cmux-machine")
        .map(|(_, v)| printable(v))
        .unwrap_or_else(|| "-".into());
    let path = log_path(&call.path);
    let response = match upstream.call(&call).await {
        Ok(response) => response,
        Err((code, message)) => {
            log(&format!(
                "{machine} {} {path} -> {code} ({} ms)",
                printable(&call.method),
                started.elapsed().as_millis()
            ));
            return send(tx, &error_frame(id, code, &message)).await;
        }
    };
    let status = response.status().as_u16();
    let mut headers = serde_json::Map::new();
    for name in ANSWER_HEADERS {
        if let Some(v) = response.headers().get(*name).and_then(|v| v.to_str().ok()) {
            headers.insert((*name).to_owned(), Value::String(v.to_owned()));
        }
    }
    send(tx, &json!({"v": 1, "t": "head", "id": id, "status": status, "headers": headers})).await;
    let mut body = response.bytes_stream();
    loop {
        let chunk = match tokio::time::timeout(UPSTREAM_IDLE_TIMEOUT, body.next()).await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(_) => {
                log(&format!(
                    "{machine} {} {path} -> {status}, stalled ({} ms)",
                    printable(&call.method),
                    started.elapsed().as_millis()
                ));
                let stalled = error_frame(
                    id,
                    "inference.upstream_stalled",
                    "the provider's answer sent nothing for 5 minutes",
                );
                return send(tx, &stalled).await;
            }
        };
        match chunk {
            Ok(bytes) => {
                for part in bytes.chunks(CHUNK_BYTES) {
                    let data = base64::engine::general_purpose::STANDARD.encode(part);
                    send(tx, &json!({"v": 1, "t": "data", "id": id, "data": data})).await;
                }
            }
            Err(_) => {
                log(&format!(
                    "{machine} {} {path} -> {status}, stream broke ({} ms)",
                    printable(&call.method),
                    started.elapsed().as_millis()
                ));
                return send(
                    tx,
                    &error_frame(
                        id,
                        "inference.upstream_broken",
                        "the provider's answer broke off",
                    ),
                )
                .await;
            }
        }
    }
    log(&format!(
        "{machine} {} {path} -> {status} ({} ms)",
        printable(&call.method),
        started.elapsed().as_millis()
    ));
    send(tx, &json!({"v": 1, "t": "end", "id": id})).await;
}

/// The login this gateway holds, and how a call reaches the provider with it.
struct Provider {
    upstream: Upstream,
    http: reqwest::Client,
    /// The Codex login, loaded on first use and kept current across refreshes.
    codex: Mutex<Option<CodexLogin>>,
}

#[derive(Clone)]
struct CodexLogin {
    access: String,
    refresh: String,
    account: String,
    /// The access token's expiry (unix seconds), from its own claim.
    expires: u64,
}

type CallError = (&'static str, String);

impl Provider {
    fn new(upstream: Upstream, http: reqwest::Client) -> Self {
        Self { upstream, http, codex: Mutex::new(None) }
    }

    /// Fails at start when the login cannot be read, so a mistake shows before any machine calls.
    async fn check(&self) -> Result<(), String> {
        match &self.upstream {
            Upstream::Codex { auth } => {
                let login = read_codex_login(auth).await?;
                log(&format!("holding the Codex login in {}", auth.display()));
                *self.codex.lock().await = Some(login);
                Ok(())
            }
            Upstream::Proxy { base, key_file } => {
                if let Some(path) = key_file {
                    read_key(path).await?;
                }
                log(&format!("sending calls to the subscription proxy at {base}"));
                Ok(())
            }
        }
    }

    async fn call(&self, call: &Pending) -> Result<reqwest::Response, CallError> {
        match &self.upstream {
            Upstream::Proxy { base, key_file } => {
                let key = match key_file {
                    Some(path) => {
                        Some(read_key(path).await.map_err(|e| ("inference.gateway_config", e))?)
                    }
                    None => None,
                };
                let url = proxy_url(base, &call.path).ok_or((
                    "inference.not_found",
                    format!("the inference gateway serves no {}", log_path(&call.path)),
                ))?;
                self.send(&url, call, key.as_deref(), &[]).await
            }
            Upstream::Codex { auth } => {
                let url = codex_url(&call.path).ok_or((
                    "inference.unsupported_path",
                    format!("a Codex login does not serve {}", call.path),
                ))?;
                let login = self.codex_login(auth, false).await?;
                let account = [
                    ("chatgpt-account-id", login.account.as_str()),
                    ("originator", "codex_cli_rs"),
                ];
                let response = self.send(&url, call, Some(&login.access), &account).await?;
                if response.status() != reqwest::StatusCode::UNAUTHORIZED {
                    return Ok(response);
                }
                // The token was revoked or rotated under us: refresh once and send again.
                let login = self.codex_login(auth, true).await?;
                let account = [
                    ("chatgpt-account-id", login.account.as_str()),
                    ("originator", "codex_cli_rs"),
                ];
                self.send(&url, call, Some(&login.access), &account).await
            }
        }
    }

    async fn send(
        &self,
        url: &str,
        call: &Pending,
        bearer: Option<&str>,
        extra: &[(&str, &str)],
    ) -> Result<reqwest::Response, CallError> {
        let method = reqwest::Method::from_bytes(call.method.as_bytes())
            .map_err(|_| ("inference.bad_request", "bad method".to_owned()))?;
        let mut request = self.http.request(method, url);
        for (name, value) in &call.headers {
            if PASS_HEADERS.contains(&name.as_str()) {
                request = request.header(name, value);
            }
        }
        if let Some(bearer) = bearer {
            let mut value = HeaderValue::from_str(&format!("Bearer {bearer}")).map_err(|_| {
                ("inference.gateway_config", "the login is not a valid header value".to_owned())
            })?;
            value.set_sensitive(true);
            request = request.header(reqwest::header::AUTHORIZATION, value);
        }
        for (name, value) in extra {
            request = request.header(*name, *value);
        }
        if !call.body.is_empty() {
            request = request.body(call.body.clone());
        }
        match tokio::time::timeout(UPSTREAM_HEADERS_TIMEOUT, request.send()).await {
            Err(_) => Err((
                "inference.upstream_timeout",
                "the provider did not answer in 10 minutes".into(),
            )),
            Ok(Err(e)) if e.is_connect() => Err((
                "inference.upstream_unreachable",
                "the gateway could not reach the provider".into(),
            )),
            Ok(Err(_)) => Err(("inference.upstream_failed", "the provider call failed".into())),
            Ok(Ok(response)) => Ok(response),
        }
    }

    /// The current Codex login, refreshed when it is near expiry or `force`d (a 401).
    async fn codex_login(&self, auth: &Path, force: bool) -> Result<CodexLogin, CallError> {
        let mut slot = self.codex.lock().await;
        let mut login = match slot.clone() {
            Some(login) => login,
            None => read_codex_login(auth).await.map_err(|e| ("inference.gateway_login", e))?,
        };
        if force || login.expires <= now_s() + REFRESH_SKEW_S {
            // Another holder (the person's own Codex on this host) may have refreshed the file since: take theirs.
            if let Ok(on_disk) = read_codex_login(auth).await
                && on_disk.refresh != login.refresh
                && on_disk.expires > now_s() + REFRESH_SKEW_S
            {
                login = on_disk;
            } else {
                login = refresh_codex(&self.http, auth, &login)
                    .await
                    .map_err(|e| ("inference.gateway_login", e))?;
                log("refreshed the Codex login");
            }
        }
        *slot = Some(login.clone());
        Ok(login)
    }
}

/// The ChatGPT Codex backend URL for a call's path (`/v1/models?client_version=…` keeps its query).
pub(super) fn codex_url(path: &str) -> Option<String> {
    let (route, query) = path.split_once('?').map_or((path, None), |(r, q)| (r, Some(q)));
    let target = match route {
        "/v1/responses" => "/responses",
        "/v1/responses/compact" => "/responses/compact",
        "/v1/models" => "/models",
        _ => return None,
    };
    Some(match query {
        Some(q) => format!("{CODEX_BACKEND}{target}?{q}"),
        None => format!("{CODEX_BACKEND}{target}"),
    })
}

async fn read_key(path: &Path) -> Result<String, String> {
    let key = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| format!("cannot read the upstream key file: {e}"))?;
    let key = key.trim().to_owned();
    if key.is_empty() || key.contains(char::is_whitespace) {
        return Err("the upstream key file holds no key".into());
    }
    Ok(key)
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// A JWT's `exp`, unverified: only to know when to refresh our own token.
pub(super) fn jwt_exp(token: &str) -> Option<u64> {
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice::<Value>(&bytes).ok()?.get("exp")?.as_u64()
}

pub(super) fn parse_codex_login(text: &str) -> Result<CodexLoginView, String> {
    let file: Value =
        serde_json::from_str(text).map_err(|_| "the Codex login file is not JSON".to_owned())?;
    let tokens = file.get("tokens").and_then(Value::as_object).ok_or(
        "the Codex login file has no ChatGPT sign-in (run `codex login` with CODEX_HOME at the gateway's folder)",
    )?;
    let field = |k: &str| {
        tokens.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_owned)
    };
    let access = field("access_token").ok_or("the Codex login has no access token")?;
    let refresh = field("refresh_token").ok_or("the Codex login has no refresh token")?;
    let account = field("account_id").ok_or("the Codex login has no account id")?;
    let expires = jwt_exp(&access).unwrap_or(0);
    Ok(CodexLoginView { access, refresh, account, expires })
}

/// The fields the gateway uses from a Codex login file (tests read it too).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct CodexLoginView {
    pub access: String,
    pub refresh: String,
    pub account: String,
    pub expires: u64,
}

async fn read_codex_login(path: &Path) -> Result<CodexLogin, String> {
    let text = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| format!("cannot read the Codex login at {}: {e}", path.display()))?;
    let v = parse_codex_login(&text)?;
    Ok(CodexLogin { access: v.access, refresh: v.refresh, account: v.account, expires: v.expires })
}

/// Refreshes the login with OpenAI and writes the rotated tokens back, atomically, keeping every other field.
async fn refresh_codex(
    http: &reqwest::Client,
    path: &Path,
    login: &CodexLogin,
) -> Result<CodexLogin, String> {
    let response = http
        .post(CODEX_TOKEN_URL)
        .timeout(Duration::from_secs(20))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", login.refresh.as_str()),
            ("client_id", CODEX_CLIENT_ID),
        ])
        .send()
        .await
        .map_err(|_| "the Codex login refresh could not reach OpenAI".to_owned())?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        return Err(format!(
            "OpenAI refused the Codex login refresh (HTTP {}); sign in again with `codex login`",
            status.as_u16()
        ));
    }
    let text = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| format!("cannot read the Codex login: {e}"))?;
    // Another holder rotated the file while this refresh was in flight: theirs is the newer login, keep it.
    if let Ok(on_disk) = parse_codex_login(&text)
        && on_disk.refresh != login.refresh
    {
        return Ok(CodexLogin {
            access: on_disk.access,
            refresh: on_disk.refresh,
            account: on_disk.account,
            expires: on_disk.expires,
        });
    }
    let (updated, login) = apply_refresh(&text, &body, now_s())?;
    write_private(path, updated.as_bytes()).await?;
    Ok(login)
}

/// The login file with a refresh's answer applied, and the login it now holds. Pure, for the tests.
fn apply_refresh(text: &str, answer: &Value, now: u64) -> Result<(String, CodexLogin), String> {
    let mut file: Value =
        serde_json::from_str(text).map_err(|_| "the Codex login file is not JSON".to_owned())?;
    let access = answer
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or("the refresh answer has no access token")?;
    let tokens = file
        .get_mut("tokens")
        .and_then(Value::as_object_mut)
        .ok_or("the Codex login file has no tokens")?;
    tokens.insert("access_token".into(), Value::String(access.to_owned()));
    for key in ["refresh_token", "id_token"] {
        if let Some(v) = answer.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()) {
            tokens.insert(key.into(), Value::String(v.to_owned()));
        }
    }
    if let Some(o) = file.as_object_mut() {
        o.insert("last_refresh".into(), Value::String(rfc3339(now)));
    }
    let text = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
    let v = parse_codex_login(&text)?;
    let expires = if v.expires > 0 {
        v.expires
    } else {
        now + answer.get("expires_in").and_then(Value::as_u64).unwrap_or(3600)
    };
    Ok((text, CodexLogin { access: v.access, refresh: v.refresh, account: v.account, expires }))
}

/// Writes `bytes` to `path` through a 0600 temporary in the same folder and a rename.
async fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("the Codex login has no folder")?.to_owned();
    let path = path.to_owned();
    let bytes = bytes.to_vec();
    tokio::task::spawn_blocking(move || -> Result<(), String> {
        let mut tmp = tempfile::Builder::new()
            .prefix(".auth.json.")
            .permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600))
            .tempfile_in(&dir)
            .map_err(|e| format!("cannot write the Codex login: {e}"))?;
        tmp.write_all(&bytes).map_err(|e| format!("cannot write the Codex login: {e}"))?;
        tmp.as_file().sync_all().map_err(|e| format!("cannot write the Codex login: {e}"))?;
        tmp.persist(&path).map_err(|e| format!("cannot write the Codex login: {e}"))?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// `YYYY-MM-DDTHH:MM:SSZ` for unix seconds (Howard Hinnant's civil-from-days).
fn rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem / 60 % 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }
    fn no_env(_: &str) -> Option<String> {
        None
    }
    fn jwt(exp: u64) -> String {
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("{{\"exp\":{exp}}}"));
        format!("e30.{payload}.sig")
    }

    /// A one-shot fake subscription proxy: records the request it got and answers `reply` (raw HTTP).
    async fn fake_upstream(reply: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut got = Vec::new();
            let mut buf = [0u8; 4096];
            // Headers, then the declared body.
            loop {
                let n = sock.read(&mut buf).await.unwrap();
                got.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&got).to_string();
                if let Some((head, body)) = text.split_once("\r\n\r\n") {
                    let len = head
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if body.len() >= len {
                        break;
                    }
                }
                if n == 0 {
                    break;
                }
            }
            sock.write_all(reply.as_bytes()).await.unwrap();
            sock.shutdown().await.unwrap();
            String::from_utf8_lossy(&got).to_string()
        });
        (base, task)
    }

    fn test_client() -> reqwest::Client {
        let _ = rustls::crypto::ring::default_provider().install_default();
        reqwest::Client::new()
    }

    fn pending(path: &str, body: &str) -> Pending {
        Pending {
            method: "POST".into(),
            path: path.into(),
            headers: vec![
                ("content-type".into(), "application/json".into()),
                ("x-cmux-machine".into(), "vm_abcdefghij0123456789".into()),
                ("anthropic-version".into(), "2023-06-01".into()),
            ],
            body: body.as_bytes().to_vec(),
        }
    }

    async fn frames(rx: &mut mpsc::Receiver<String>) -> Vec<Value> {
        let mut out = Vec::new();
        while let Some(f) = rx.recv().await {
            let v: Value = serde_json::from_str(&f).unwrap();
            let last = matches!(v["t"].as_str(), Some("end" | "error"));
            out.push(v);
            if last {
                break;
            }
        }
        out
    }

    #[tokio::test]
    async fn forwards_a_call_to_the_proxy_and_streams_its_answer_as_frames() {
        let (base, upstream) = fake_upstream(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nset-cookie: s=1\r\nretry-after: 3\r\nconnection: close\r\n\r\nevent: a\ndata: 1\n\nevent: b\ndata: 2\n\n",
        )
        .await;
        let dir = std::env::temp_dir().join(format!("cmux-gw-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let key = dir.join("key");
        std::fs::write(&key, "proxy-key\n").unwrap();
        let provider = Provider::new(
            Upstream::Proxy { base: format!("{base}/v1"), key_file: Some(key) },
            test_client(),
        );
        let (tx, mut rx) = mpsc::channel(32);
        answer(&provider, "c1", pending("/v1/messages", r#"{"model":"m"}"#), &tx).await;
        let got = frames(&mut rx).await;
        assert_eq!(got[0]["t"], "head");
        assert_eq!(got[0]["status"], 200);
        assert_eq!(got[0]["headers"]["content-type"], "text/event-stream");
        assert_eq!(got[0]["headers"]["retry-after"], "3");
        assert!(got[0]["headers"].get("set-cookie").is_none());
        let body: Vec<u8> = got[1..got.len() - 1]
            .iter()
            .flat_map(|f| {
                base64::engine::general_purpose::STANDARD
                    .decode(f["data"].as_str().unwrap())
                    .unwrap()
            })
            .collect();
        assert_eq!(String::from_utf8(body).unwrap(), "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n");
        assert_eq!(got.last().unwrap()["t"], "end");
        let request = upstream.await.unwrap();
        let lower = request.to_ascii_lowercase();
        // `--upstream http://host/v1` and the call's `/v1/messages` reach `/v1/messages` once.
        assert!(request.starts_with("POST /v1/messages HTTP/1.1"), "{request}");
        assert!(lower.contains("authorization: bearer proxy-key"));
        assert!(lower.contains("anthropic-version: 2023-06-01"));
        // The backend's routing header stays here.
        assert!(!lower.contains("x-cmux-machine"));
        assert!(request.ends_with(r#"{"model":"m"}"#));
    }

    #[tokio::test]
    async fn an_unreachable_proxy_ends_the_call_with_a_typed_error() {
        // A port nothing listens on: bind, then drop it.
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let provider = Provider::new(
            Upstream::Proxy { base: format!("http://127.0.0.1:{port}"), key_file: None },
            test_client(),
        );
        let (tx, mut rx) = mpsc::channel(4);
        answer(&provider, "c2", pending("/v1/responses", "{}"), &tx).await;
        let got = frames(&mut rx).await;
        assert_eq!(got.len(), 1);
        assert_eq!(got[0]["t"], "error");
        assert_eq!(got[0]["code"], "inference.upstream_unreachable");
    }

    #[test]
    fn personal_selects_the_owner_gateway() {
        let base = ["--api", "https://api.cmux.dev", "--upstream", "http://127.0.0.1:8317"];
        let team = parse(&args(&base), &no_env).unwrap();
        assert!(!team.personal);
        let mut with = base.to_vec();
        with.push("--personal");
        assert!(parse(&args(&with), &no_env).unwrap().personal);
        assert_eq!(PERSONAL_CONNECT_PATH, "/v1/cloud/inference-gateway/personal/connect");
        assert!(help().contains("cmux inference gateway status [--personal] [--json]"));
    }

    #[test]
    fn splits_only_inference_gateway() {
        assert_eq!(
            split(&args(&["inference", "gateway", "--api", "x"])),
            Some(&args(&["--api", "x"])[..])
        );
        assert_eq!(split(&args(&["inference"])), None);
        assert_eq!(split(&args(&["cloud", "gateway"])), None);
    }

    #[test]
    fn parses_a_codex_gateway_and_a_proxy_gateway() {
        let env = |k: &str| (k == "HOME").then(|| "/home/p".to_owned());
        // No proxy is picked for the person: one of the two is required, even with a ~/.codex login on the host.
        assert!(parse(&args(&["--api", "https://api.cmux.dev"]), &env).is_err());
        let o = parse(
            &args(&[
                "--api",
                "https://api.cmux.dev",
                "--team",
                "team_1",
                "--codex-auth",
                "/g/auth.json",
            ]),
            &env,
        )
        .unwrap();
        assert_eq!(o.api, "https://api.cmux.dev");
        assert_eq!(o.team.as_deref(), Some("team_1"));
        assert_eq!(o.upstream, Upstream::Codex { auth: PathBuf::from("/g/auth.json") });
        assert_eq!(o.token, TokenSource::App);
        let o = parse(
            &args(&[
                "--api=https://api.cmux.dev",
                "--upstream",
                "http://127.0.0.1:8317/",
                "--token-file",
                "/t",
            ]),
            &no_env,
        )
        .unwrap();
        assert_eq!(
            o.upstream,
            Upstream::Proxy { base: "http://127.0.0.1:8317".into(), key_file: None }
        );
        assert_eq!(o.token, TokenSource::File(PathBuf::from("/t")));
    }

    #[test]
    fn refuses_plain_http_to_the_api_and_two_upstreams() {
        assert!(parse(&args(&["--api", "http://api.cmux.dev"]), &no_env).is_err());
        assert!(
            parse(
                &args(&["--api", "https://a.dev", "--codex-auth", "/a", "--upstream", "http://b"]),
                &no_env
            )
            .is_err()
        );
        assert!(
            parse(
                &args(&["--api", "https://a.dev", "--token-file", "/a", "--token-command", "x"]),
                &no_env
            )
            .is_err()
        );
        assert!(parse(&args(&["--codex-auth", "/a"]), &no_env).is_err());
        // A credential in the URL would be logged with it.
        assert!(
            parse(
                &args(&["--api", "https://a.dev", "--upstream", "https://u:secret@b.dev"]),
                &no_env
            )
            .is_err()
        );
        assert!(
            parse(&args(&["--api", "https://a.dev", "--upstream", "https://u@b.dev"]), &no_env)
                .is_err()
        );
        assert!(
            parse(
                &args(&[
                    "--api",
                    "https://a.dev",
                    "--upstream-key-file",
                    "/k",
                    "--codex-auth",
                    "/a"
                ]),
                &no_env
            )
            .is_err()
        );
    }

    #[test]
    fn plain_http_stays_on_this_computer_or_a_private_network() {
        let parse_up = |up: &str, key: bool| {
            let mut a = vec!["--api", "https://a.dev", "--upstream", up];
            if key {
                a.extend(["--upstream-key-file", "/k"]);
            }
            parse(&args(&a), &no_env).map(|_| ())
        };
        assert!(parse_up("http://127.0.0.1:8317", true).is_ok());
        assert!(parse_up("http://localhost:8317/v1", true).is_ok());
        assert!(parse_up("http://100.89.225.106:31415/v1", false).is_ok());
        assert!(parse_up("http://192.168.1.4:8317", false).is_ok());
        assert!(parse_up("http://sr.tail1234.ts.net:31415", false).is_ok());
        assert!(parse_up("http://100.89.225.106:31415/v1", true).is_err());
        assert!(parse_up("http://proxy.example.com", false).is_err());
        assert!(parse_up("http://8.8.8.8", false).is_err());
        assert!(parse_up("https://proxy.example.com/v1", true).is_ok());
    }

    #[test]
    fn logs_show_no_query_and_no_control_characters() {
        assert_eq!(log_path("/v1/responses?api_key=secret"), "/v1/responses");
        assert_eq!(log_path("/v1/models\nfake line"), "/v1/modelsfakeline");
        assert_eq!(printable("vm_abc\r\n x"), "vm_abcx");
    }

    #[test]
    fn joins_a_proxy_base_with_or_without_v1() {
        assert_eq!(proxy_url("http://h:1", "/v1/responses").unwrap(), "http://h:1/v1/responses");
        assert_eq!(proxy_url("http://h:1/v1", "/v1/responses").unwrap(), "http://h:1/v1/responses");
        assert_eq!(
            proxy_url("http://h:1/api", "/v1/models?x=1").unwrap(),
            "http://h:1/api/v1/models?x=1"
        );
    }

    #[test]
    fn a_proxy_serves_only_the_workers_model_paths() {
        for path in [
            "/v1/responses",
            "/v1/responses?x=1",
            "/v1/responses/compact",
            "/v1/models",
            "/v1/messages",
            "/v1/messages/count_tokens",
            "/v1/chat/completions",
        ] {
            assert!(proxy_url("https://h", path).is_some(), "{path}");
        }
        for path in [
            "@evil.example/x",
            "/admin",
            "",
            "/v1/responses/../admin",
            "/v1/responsesx",
            "/v1/models/x",
            "/v1/responses#x",
            "//evil.example/v1/responses",
        ] {
            assert!(proxy_url("https://h", path).is_none(), "{path}");
        }
    }

    #[test]
    fn refuses_an_upstream_with_a_fragment() {
        let parse_up = |up: &str| {
            parse(&args(&["--api", "https://a.dev", "--upstream", up]), &no_env).map(|_| ())
        };
        assert!(parse_up("https://h#f").is_err());
        assert!(parse_up("https://h/v1#").is_err());
        assert!(parse_up("https://h/v1").is_ok());
    }

    #[test]
    fn maps_codex_paths_to_the_chatgpt_backend() {
        assert_eq!(
            codex_url("/v1/responses").as_deref(),
            Some("https://chatgpt.com/backend-api/codex/responses")
        );
        assert_eq!(
            codex_url("/v1/models?client_version=0.99").as_deref(),
            Some("https://chatgpt.com/backend-api/codex/models?client_version=0.99")
        );
        assert_eq!(codex_url("/v1/messages"), None);
    }

    #[test]
    fn reads_a_codex_login_and_applies_a_refresh_keeping_other_fields() {
        let text = json!({
            "OPENAI_API_KEY": null,
            "tokens": {"access_token": jwt(1000), "refresh_token": "r1", "id_token": "i1", "account_id": "acct"},
            "last_refresh": "old",
        })
        .to_string();
        let v = parse_codex_login(&text).unwrap();
        assert_eq!((v.refresh.as_str(), v.account.as_str(), v.expires), ("r1", "acct", 1000));
        let (updated, login) = apply_refresh(
            &text,
            &json!({"access_token": jwt(5000), "refresh_token": "r2"}),
            1_762_490_000,
        )
        .unwrap();
        assert_eq!((login.refresh.as_str(), login.expires), ("r2", 5000));
        let file: Value = serde_json::from_str(&updated).unwrap();
        assert_eq!(file["tokens"]["id_token"], "i1");
        assert_eq!(file["tokens"]["account_id"], "acct");
        assert_eq!(file["last_refresh"], "2025-11-07T04:33:20Z");
        assert!(file.get("OPENAI_API_KEY").is_some());
        assert!(apply_refresh(&text, &json!({}), 0).is_err());
    }

    #[test]
    fn a_login_without_chatgpt_tokens_is_refused() {
        assert!(parse_codex_login(r#"{"OPENAI_API_KEY":"sk-x"}"#).is_err());
        assert!(parse_codex_login("nope").is_err());
    }

    #[test]
    fn formats_utc_times() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }
}
