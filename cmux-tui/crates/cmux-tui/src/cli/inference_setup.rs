//! `cmux inference setup --machine vm_…`: how a Cloud machine's Codex reaches a model, chosen and checked.
//!
//! Leo, 2026-11-07: "we want to be able to have you do that AUTOMATICALLY. that's our cloud product. [...] an
//! alternate, slightly less ergo route but still ok is just like... well we just help the user go through the
//! login and they enter the confirmation on their own computer and such."
//!
//! Two paths, in that order:
//! - **gateway** (automatic): the team's `cmux inference gateway` serves the machine's model calls; the machine
//!   holds no login. Setup reads the team's gateway state and checks the path with one real call from the machine
//!   (`GET https://coderouter.cmux.internal/v1/models`, which the edge sends to the gateway and the gateway to the
//!   provider).
//! - **device** (the fallback, offered when the gateway path is not ready, or chosen with `--path device`): the
//!   machine runs the provider's own sign-in, `codex login --device-auth`. Setup shows its link and one-time code;
//!   the person approves on their own computer, and the machine then holds its own login, made on it. No token is
//!   copied, and Codex refreshes it there. Owner machines only, as the image's own-login rule (`agent-auth.sh`).
//!
//! Every step on the machine is one exec as its work user through the cmux API (`cloud machine-io`'s route).
//! Nothing here prints or logs a token; the device code is the provider's one-time code, shown to the person.

use std::io::Write as _;
use std::time::Duration;

use serde_json::Value;

use super::cloud_client_session::{secure_origin, valid_machine};
use super::cloud_machine_io::{Op, Request, RouteChoice, perform};
use super::inference_gateway::{TokenSource, backend_token};

const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
/// How long the person has to approve the device login (Codex's code lives 15 minutes).
const DEVICE_WAIT: Duration = Duration::from_secs(15 * 60);
const POLL: Duration = Duration::from_secs(3);
const LOG: &str = "$HOME/.cache/cmux/inference-login-codex.log";

const HELP: &str = "\
cmux inference setup: choose and check how a Cloud machine's Codex reaches a model.

Usage:
  cmux inference setup --machine vm_... [--path auto|gateway|device]
                       [--api URL] [--team TEAM] [--token-file PATH | --token-command CMD]

  --path auto     (default) use the team's gateway when it answers; otherwise
                  offer a device login on the machine
  --path gateway  only check the gateway path (the machine holds no login)
  --path device   sign in on the machine itself: it runs `codex login --device-auth`,
                  you approve on your own computer, and the machine keeps its own login
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PathChoice {
    Auto,
    Gateway,
    Device,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Options {
    pub api: String,
    pub team: Option<String>,
    pub machine: String,
    pub path: PathChoice,
    pub token: TokenSource,
}

/// `Some(exit code)` when `args` is `inference setup …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let rest = match command_args.as_slice() {
        [a, b, rest @ ..] if a == "inference" && b == "setup" => rest,
        _ => return None,
    };
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        print!("{HELP}");
        return Some(0);
    }
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    match parse(rest, &env) {
        Ok(options) => Some(run(options)),
        Err(error) => {
            eprintln!("cmux inference setup: {error}\n\n{HELP}");
            Some(2)
        }
    }
}

pub(super) fn parse(
    rest: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Options, String> {
    let (mut api, mut team, mut machine, mut path, mut token) =
        (None, None, None, PathChoice::Auto, None);
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
            "--machine" => machine = Some(value()?),
            "--path" => {
                path = match value()?.as_str() {
                    "auto" => PathChoice::Auto,
                    "gateway" => PathChoice::Gateway,
                    "device" => PathChoice::Device,
                    other => return Err(format!("--path {other}: one of auto, gateway, device")),
                }
            }
            "--token-file" | "--token-command" => {
                let v = value()?;
                let source = if flag == "--token-file" {
                    TokenSource::File(v.into())
                } else {
                    TokenSource::Command(v)
                };
                if token.replace(source).is_some() {
                    return Err("--token-file and --token-command: pick one".into());
                }
            }
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }
    let machine = machine.ok_or("--machine names the Cloud machine (vm_...)")?;
    if !valid_machine(&machine) {
        return Err("--machine must be a machine id (vm_ and 20 letters or digits)".into());
    }
    let api = api
        .or_else(|| env("CMUX_CLOUD_API_URL"))
        .ok_or("--api (or CMUX_CLOUD_API_URL) names the cmux API")?;
    let api = secure_origin(&api)?;
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    Ok(Options { api, team, machine, path, token })
}

fn say(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

fn run(options: Options) -> i32 {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("cmux inference setup: {e}");
            return 1;
        }
    };
    runtime.block_on(async {
        match setup(&options).await {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("cmux inference setup: {error}");
                1
            }
        }
    })
}

struct Machine<'a> {
    http: reqwest::Client,
    options: &'a Options,
    token: String,
}

impl Machine<'_> {
    /// One command on the machine as its work user: its exit code and output.
    async fn exec(&self, command: &str, timeout_ms: u64) -> Result<(i64, String), String> {
        let request = Request {
            api: self.options.api.clone(),
            credential: self.token.clone(),
            team: self.options.team.clone(),
            machine: self.options.machine.clone(),
            op: Op::Exec,
            path: None,
            data_base64: None,
            mode: None,
            command: Some(command.to_owned()),
            timeout_ms: Some(timeout_ms),
            cache_dir: None,
            route: RouteChoice::Auto,
            app_version: None,
        };
        let (_, answer) = perform(&self.http, &request, now_ms).await;
        if !(200..300).contains(&answer.status) {
            let message = answer.body["error"]["message"].as_str().unwrap_or("no answer");
            return Err(format!(
                "the machine did not run the step (HTTP {}: {message})",
                answer.status
            ));
        }
        let code = answer.body["exitCode"].as_i64().unwrap_or(-1);
        Ok((code, answer.body["stdout"].as_str().unwrap_or_default().to_owned()))
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

async fn setup(options: &Options) -> Result<(), String> {
    let token = backend_token(&options.token, options.team.as_deref()).await?;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let machine = Machine { http, options, token };
    if options.path != PathChoice::Device {
        match gateway(&machine).await {
            Ok(()) => return Ok(()),
            Err(reason) if options.path == PathChoice::Gateway => return Err(reason),
            Err(reason) => say(&format!(
                "The gateway path is not ready: {reason}\nOffering a device login instead."
            )),
        }
    }
    device(&machine).await
}

/// The gateway path: the team's state, then one real call from the machine through it.
async fn gateway(machine: &Machine<'_>) -> Result<(), String> {
    let o = machine.options;
    let mut request = machine
        .http
        .get(format!("{}/v1/cloud/inference-gateway", o.api))
        .bearer_auth(&machine.token);
    if let Some(team) = &o.team {
        request = request.header("x-cmux-team", team);
    }
    let state: Value = request
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "the cmux API did not answer".to_owned())?
        .json()
        .await
        .map_err(|_| "the cmux API's answer was not JSON".to_owned())?;
    let gw = &state["gateway"];
    if gw["mode"] != "gateway" {
        return Err("this team is not in gateway mode (PUT /v1/cloud/inference-gateway {\"mode\":\"gateway\"})".into());
    }
    if gw["online"] != true {
        return Err("no `cmux inference gateway` is online for this team".into());
    }
    let kind = gw["kind"].as_str().unwrap_or("unknown");
    // The machine's own call: the edge steers it to the gateway, which answers from the person's proxy or login.
    let probe = format!(
        "curl -sS -o /dev/null -w '%{{http_code}}' --max-time 60 -H 'authorization: Bearer {PLACEHOLDER}' \
         'https://coderouter.cmux.internal/v1/models?client_version=0.0.0'"
    );
    let (_, status) = machine.exec(&probe, 90_000).await?;
    let status = status.trim();
    if status != "200" {
        return Err(format!("the machine's model call through the gateway answered HTTP {status}"));
    }
    let holds = machine.exec(login_present(), 30_000).await?.0 == 0;
    say(&format!(
        "Path: gateway ({}). The machine's model call went machine -> edge -> cmux -> gateway -> provider and answered 200.",
        if kind == "machine" { "the team's gateway machine" } else { "a person's own computer" }
    ));
    say(if holds {
        "Note: this machine also has its own Codex login (~/.codex/auth.json); its own-login mode uses that instead."
    } else {
        "This machine holds no Codex login."
    });
    Ok(())
}

fn login_present() -> &'static str {
    "test -s \"$HOME/.codex/auth.json\" && grep -q '\"refresh_token\"' \"$HOME/.codex/auth.json\""
}

/// The device path: the machine runs Codex's own device sign-in; the person approves on their computer.
async fn device(machine: &Machine<'_>) -> Result<(), String> {
    // The image's own-login rule: an owner machine only (a team machine's Unix user is every member's).
    let (code, kind) =
        machine.exec("cat /etc/cmux/vm-kind 2>/dev/null || echo owner", 30_000).await?;
    if code != 0 || kind.trim() != "owner" {
        return Err("a device login goes only on your own machine, not a team machine".into());
    }
    let start = format!(
        "mkdir -p \"$HOME/.cache/cmux\" && unset CODEX_HOME OPENAI_API_KEY OPENAI_BASE_URL; \
         c=/usr/local/libexec/cmux-codex-real; [ -x \"$c\" ] || c=$(command -v codex); \
         [ -n \"$c\" ] || {{ echo no-codex; exit 3; }}; \
         nohup \"$c\" login --device-auth > {LOG} 2>&1 < /dev/null & echo $! > \"$HOME/.cache/cmux/inference-login-codex.pid\""
    );
    let (code, out) = machine.exec(&start, 30_000).await?;
    if code != 0 {
        return Err(if out.contains("no-codex") {
            "this machine has no Codex installed".into()
        } else {
            format!("the machine could not start Codex's sign-in (exit {code})")
        });
    }
    let read_log = format!("cat {LOG} 2>/dev/null");
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    let (url, user_code) = loop {
        let (_, log) = machine.exec(&read_log, 30_000).await?;
        if let Some(found) = device_prompt(&log) {
            break found;
        }
        if std::time::Instant::now() > deadline {
            return Err("Codex's sign-in on the machine printed no link and code".into());
        }
        tokio::time::sleep(POLL).await;
    };
    say(&format!(
        "Sign in to Codex for this machine:\n  1. Open {url} on your own computer\n  2. Enter the code {user_code}\nWaiting for you to approve (up to 15 minutes)..."
    ));
    let done = format!(
        "p=$(cat \"$HOME/.cache/cmux/inference-login-codex.pid\" 2>/dev/null); \
         if {login}; then echo signed-in; elif [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null; then echo waiting; else echo ended; fi",
        login = login_present()
    );
    let deadline = std::time::Instant::now() + DEVICE_WAIT;
    loop {
        tokio::time::sleep(POLL).await;
        let (_, state) = machine.exec(&done, 30_000).await?;
        match state.trim() {
            "signed-in" => break,
            "ended" => {
                return Err(
                    "Codex's sign-in on the machine ended without a login; run setup again".into()
                );
            }
            _ if std::time::Instant::now() > deadline => {
                return Err("the sign-in was not approved in 15 minutes; run setup again".into());
            }
            _ => {}
        }
    }
    // Codex on the image uses its own login only in own mode (agent-auth.sh): set it, as the login installer does.
    let own = "d=\"$HOME/.config/cmux/agent-auth\"; mkdir -p \"$d\" && chmod 700 \"$d\" && \
               printf 'own\\n' > \"$d/codex.tmp\" && chmod 600 \"$d/codex.tmp\" && mv \"$d/codex.tmp\" \"$d/codex\"";
    let (code, _) = machine.exec(own, 30_000).await?;
    if code != 0 {
        return Err(
            "signed in, but the machine's Codex could not be switched to its own login".into()
        );
    }
    say(
        "Path: device login. This machine signed in to Codex itself and keeps its own login; no token was copied.",
    );
    Ok(())
}

/// The link and one-time code in Codex's device sign-in output, once both are printed. Pure, for the tests.
pub(super) fn device_prompt(log: &str) -> Option<(String, String)> {
    let plain = strip_ansi(log);
    let url = plain
        .split_whitespace()
        .find(|w| w.starts_with("https://"))?
        .trim_end_matches(['.', ',', ')'])
        .to_owned();
    let code = plain.split_whitespace().find(|w| is_device_code(w))?.to_owned();
    Some((url, code))
}

/// `XXXX-XXXX` (letters and digits, 4 to 5 each side), the shape of a device code.
fn is_device_code(word: &str) -> bool {
    let Some((a, b)) = word.split_once('-') else { return false };
    let part = |s: &str| {
        (4..=5).contains(&s.len())
            && s.bytes().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
    };
    part(a) && part(b)
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for n in chars.by_ref() {
                    if n.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn parses_the_machine_and_path() {
        let none = |_: &str| None;
        let o = parse(
            &args(&[
                "--machine",
                "vm_abcdefghij0123456789",
                "--api",
                "https://api.cmux.dev",
                "--path",
                "device",
            ]),
            &none,
        )
        .unwrap();
        assert_eq!((o.path, o.machine.as_str()), (PathChoice::Device, "vm_abcdefghij0123456789"));
        assert_eq!(o.token, TokenSource::App);
        assert!(parse(&args(&["--api", "https://a.dev"]), &none).is_err());
        assert!(parse(&args(&["--machine", "vm_x", "--api", "https://a.dev"]), &none).is_err());
        assert!(
            parse(
                &args(&[
                    "--machine",
                    "vm_abcdefghij0123456789",
                    "--api",
                    "https://a.dev",
                    "--path",
                    "x"
                ]),
                &none
            )
            .is_err()
        );
    }

    #[test]
    fn finds_codex_device_link_and_code() {
        let log = "Welcome to Codex\n\nFollow these steps to sign in with ChatGPT using device code authorization:\n\n\
                   1. Open this link in your browser and sign in to your account\n   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m\n\n\
                   2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m\n   \u{1b}[94mABCD-EF12\u{1b}[0m\n";
        assert_eq!(
            device_prompt(log),
            Some(("https://auth.openai.com/codex/device".to_owned(), "ABCD-EF12".to_owned()))
        );
        assert_eq!(device_prompt("starting...\n"), None);
        assert_eq!(device_prompt("https://auth.openai.com/codex/device\n"), None);
    }
}
