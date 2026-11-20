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

use super::cloud_client_session::secure_origin;
use super::inference_gateway::{TokenSource, backend_token};
use cmux_cloud_api::machine_io::{Op, Request, RouteChoice, perform};
use cmux_cloud_api::session::valid_machine;

const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
/// How long the person has to approve the device login (Codex's code lives 15 minutes).
const DEVICE_WAIT: Duration = Duration::from_secs(15 * 60);
// timeout: not a deadline: the pace of polls over exec (no push); each loop has its deadline.
const POLL: Duration = Duration::from_secs(3);
const LOG: &str = "$HOME/.cache/cmux/inference-login-codex.log";

const HELP: &str = "\
cmux inference setup: choose and check how a Cloud machine's Codex reaches a model.

Usage:
  cmux inference setup --machine vm_... [--path auto|gateway|device]
                       [--gateway-machine vm_... --upstream URL [--upstream-key-file PATH]]
                       [--api URL] [--team TEAM] [--token-file PATH | --token-command CMD]

  --gateway-machine, --upstream
                  first make that machine the team's gateway machine, in front of
                  your own subscription proxy at URL (CLIProxyAPI or your own router,
                  reachable from that machine). Running the proxy is yours.

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
    /// Make this machine the team's gateway machine first, in front of the person's own proxy.
    pub gateway: Option<GatewayMachine>,
}

/// `--gateway-machine vm_… --upstream URL [--upstream-key-file PATH]`: the person's proxy runs on (or is reachable
/// from) that machine; it is theirs to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GatewayMachine {
    pub machine: String,
    pub upstream: String,
    pub key_file: Option<String>,
}

/// `Some(exit code)` when `args` is `inference setup …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let rest = setup_args(args)?;
    let rest = rest.as_slice();
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

/// The arguments after `inference setup`, or None for another command. `--machine` here is setup's own (the chat
/// machine), not the global option that routes a command to a daemon, so the action form of the global scan keeps it.
fn setup_args(args: &[String]) -> Option<Vec<String>> {
    let (_global, command_args) = super::parse_action_globals(args).ok()?;
    match command_args.as_slice() {
        [a, b, rest @ ..] if a == "inference" && b == "setup" => Some(rest.to_vec()),
        _ => None,
    }
}

pub(super) fn parse(
    rest: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Options, String> {
    let (mut api, mut team, mut machine, mut path, mut token) =
        (None, None, None, PathChoice::Auto, None);
    let (mut gateway_machine, mut upstream, mut key_file): (
        Option<String>,
        Option<String>,
        Option<String>,
    ) = (None, None, None);
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
            "--gateway-machine" => gateway_machine = Some(value()?),
            "--upstream" => upstream = Some(value()?),
            "--upstream-key-file" => key_file = Some(value()?),
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
    // The team goes into the gateway machine's command line (make_gateway), so it is an id and nothing else.
    if team.as_deref().is_some_and(|t| {
        t.is_empty() || !t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    }) {
        return Err("--team must be a team id (letters, digits, _ and -)".into());
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
    let gateway = match (gateway_machine, upstream) {
        (None, None) if key_file.is_none() => None,
        (Some(m), Some(u)) => {
            if !valid_machine(&m) {
                return Err("--gateway-machine must be a machine id".into());
            }
            let url = reqwest::Url::parse(&u).map_err(|_| "--upstream is not a URL".to_owned())?;
            if !matches!(url.scheme(), "http" | "https") || url.query().is_some() || u.contains(['\'', '"', ' ']) {
                return Err("--upstream must be an http(s) URL with no query".into());
            }
            if !url.username().is_empty() || url.password().is_some() {
                return Err("--upstream takes no user or password; put the key in --upstream-key-file".into());
            }
            if key_file.as_deref().is_some_and(|k| !k.starts_with('/') || k.contains(['\'', '"', ' '])) {
                return Err("--upstream-key-file must be an absolute path on the gateway machine".into());
            }
            Some(GatewayMachine { machine: m, upstream: u, key_file })
        }
        _ => return Err("--gateway-machine and --upstream go together (your proxy, reachable from that machine)".into()),
    };
    Ok(Options { api, team, machine, path, token, gateway })
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
        self.exec_on(&self.options.machine, command, timeout_ms).await
    }

    /// One command on `machine` (the chat machine, or the gateway machine) as its work user.
    async fn exec_on(
        &self,
        machine: &str,
        command: &str,
        timeout_ms: u64,
    ) -> Result<(i64, String), String> {
        let request = Request {
            api: self.options.api.clone(),
            credential: self.token.clone(),
            team: self.options.team.clone(),
            machine: machine.to_owned(),
            op: Op::Exec,
            path: None,
            data_base64: None,
            mode: None,
            command: Some(command.to_owned()),
            timeout_ms: Some(timeout_ms),
            cache_dir: None,
            route: RouteChoice::Auto,
            app_version: None,
            local_only: false,
            max_bytes: None,
        };
        let (_, answer) = perform(&self.http, &request, now_ms).await;
        if !(200..300).contains(&answer.status) {
            // Only the error's code: its message is the server's (or a proxy's) text and could echo a credential.
            let code: String = answer
                .body
                .pointer("/error/code")
                .and_then(Value::as_str)
                .unwrap_or("no answer")
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || "._-".contains(*c))
                .take(80)
                .collect();
            return Err(format!(
                "the machine did not run the step (HTTP {}: {code})",
                answer.status
            ));
        }
        let code = answer.body.get("exitCode").and_then(Value::as_i64).unwrap_or(-1);
        let stdout = answer.body.get("stdout").and_then(Value::as_str).unwrap_or_default();
        Ok((code, stdout.to_owned()))
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
    if let Some(gw) = &options.gateway {
        // Naming a gateway machine asks for the gateway path: it either works end to end or the team's routing goes
        // back to what it was. No device login is offered in its place.
        let before = make_gateway(&machine, gw).await?;
        let checked = gateway(&machine).await;
        if checked.is_err() {
            undo_gateway(&machine, gw, &before).await;
        }
        return checked;
    }
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

/// Names `gw.machine` as the team's gateway machine and starts `cmux inference gateway` there, in front of the
/// person's own proxy, on the machine's own short-lived token (cmux-host `gateway_token.rs`). Then waits for it.
/// On any failure after the naming, the team's earlier mode and machine come back and the gateway machine's opt-in
/// marker goes, so no machine is left routed to a gateway that never came up.
async fn make_gateway(machine: &Machine<'_>, gw: &GatewayMachine) -> Result<Before, String> {
    let state = gateway_state(machine).await?;
    let before = Before {
        mode: state.get("mode").and_then(Value::as_str).unwrap_or("off").to_owned(),
        machine: state.get("machine").and_then(Value::as_str).map(str::to_owned),
    };
    put_gateway(machine, "gateway", Some(&gw.machine)).await?;
    match start_gateway(machine, gw).await {
        Ok(()) => Ok(before),
        Err(e) => {
            undo_gateway(machine, gw, &before).await;
            Err(e)
        }
    }
}

/// The team's gateway mode and machine before setup named a new one.
struct Before {
    mode: String,
    machine: Option<String>,
}

/// Stops the gateway on `gw.machine`, removes its opt-in marker, and gives the team its earlier mode and machine.
async fn undo_gateway(machine: &Machine<'_>, gw: &GatewayMachine, before: &Before) {
    let undo = "p=\"$HOME/.cache/cmux/inference-gateway.pid\"; [ -f \"$p\" ] && kill \"$(cat \"$p\")\" 2>/dev/null; \
                rm -f \"$HOME/.config/cmux/inference-gateway/enabled\" \"$p\"";
    let _ = machine.exec_on(&gw.machine, undo, 30_000).await;
    if put_gateway(machine, &before.mode, before.machine.as_deref()).await.is_err() {
        say(&format!(
            "Could not set the team's gateway back to {}; run `cmux inference setup` again.",
            before.mode
        ));
    }
}

/// The team's gateway state (`gateway` in GET /v1/cloud/inference-gateway).
async fn gateway_state(machine: &Machine<'_>) -> Result<Value, String> {
    let o = machine.options;
    let mut request = machine
        .http
        .get(format!("{}/v1/cloud/inference-gateway", o.api))
        .bearer_auth(&machine.token);
    if let Some(team) = &o.team {
        request = request.header("x-cmux-team", team);
    }
    let v: Value = request
        // timeout: a stuck API call is an error: setup's, or one failed check of the start wait.
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "the cmux API did not answer".to_owned())?
        .json()
        .await
        .map_err(|_| "the cmux API's answer was not JSON".to_owned())?;
    Ok(v.get("gateway").cloned().unwrap_or(Value::Null))
}

async fn put_gateway(machine: &Machine<'_>, mode: &str, gw: Option<&str>) -> Result<(), String> {
    let o = machine.options;
    let mut request = machine
        .http
        .put(format!("{}/v1/cloud/inference-gateway", o.api))
        .bearer_auth(&machine.token)
        .json(&serde_json::json!({"mode": mode, "machine": gw}));
    if let Some(team) = &o.team {
        request = request.header("x-cmux-team", team);
    }
    let status = request
        // timeout: an API call that never answers fails setup with an error.
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "the cmux API did not answer".to_owned())?
        .status();
    if !status.is_success() {
        return Err(format!(
            "the cmux API refused to set the team's gateway (HTTP {})",
            status.as_u16()
        ));
    }
    Ok(())
}

async fn start_gateway(machine: &Machine<'_>, gw: &GatewayMachine) -> Result<(), String> {
    let o = machine.options;
    let mut key =
        gw.key_file.as_deref().map(|k| format!(" --upstream-key-file '{k}'")).unwrap_or_default();
    // The gateway serves the team setup named, not the token's default one (an id: parse).
    if let Some(team) = &o.team {
        key.push_str(&format!(" --team '{team}'"));
    }
    // The values were checked to hold no quote or space (parse).
    let start = format!(
        "set -e; d=\"$HOME/.config/cmux/inference-gateway\"; mkdir -p \"$d\" \"$HOME/.cache/cmux\"; chmod 700 \"$d\"; \
         touch \"$d/enabled\"; for i in $(seq 1 90); do [ -s {TOKEN_FILE} ] && break; sleep 1; done; \
         [ -s {TOKEN_FILE} ] || {{ echo no-token; exit 4; }}; \
         p=\"$HOME/.cache/cmux/inference-gateway.pid\"; [ -f \"$p\" ] && kill \"$(cat \"$p\")\" 2>/dev/null || true; \
         c=$(command -v cmux || command -v cmux-tui); \
         nohup \"$c\" inference gateway --api '{api}' --upstream '{up}'{key} --token-file {TOKEN_FILE} \
           > \"$HOME/.cache/cmux/inference-gateway.log\" 2>&1 < /dev/null & echo $! > \"$p\"",
        api = o.api,
        up = gw.upstream,
    );
    let (code, out) = machine.exec_on(&gw.machine, &start, 120_000).await?;
    if code != 0 {
        return Err(if out.contains("no-token") {
            "the gateway machine did not get its gateway token (its cmux-host may be too old)"
                .into()
        } else {
            format!("the gateway machine could not start the gateway (exit {code})")
        });
    }
    say(&format!("Started the inference gateway on {} in front of {}.", gw.machine, gw.upstream));
    // Wait until the gateway's socket is up.
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if gateway_state(machine).await.is_ok_and(|g| g.get("online") == Some(&Value::Bool(true))) {
            return Ok(());
        }
    }
    let (_, log) = machine
        .exec_on(
            &gw.machine,
            "tail -n 5 \"$HOME/.cache/cmux/inference-gateway.log\" 2>/dev/null",
            30_000,
        )
        .await
        .unwrap_or((0, String::new()));
    Err(format!("the gateway did not come online; its last lines:\n{log}"))
}

const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

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
        // timeout: an API call that never answers fails setup with an error.
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "the cmux API did not answer".to_owned())?
        .json()
        .await
        .map_err(|_| "the cmux API's answer was not JSON".to_owned())?;
    let field = |name: &str| state.get("gateway").and_then(|g| g.get(name));
    if field("mode").and_then(Value::as_str) != Some("gateway") {
        return Err("this team is not in gateway mode (PUT /v1/cloud/inference-gateway {\"mode\":\"gateway\"})".into());
    }
    if field("online").and_then(Value::as_bool) != Some(true) {
        return Err("no `cmux inference gateway` is online for this team".into());
    }
    let kind = field("kind").and_then(Value::as_str).unwrap_or("unknown");
    // The machine's own call: the edge steers it to the gateway, which answers from the person's proxy or login.
    // Its status comes first; then the answer's header lines (every hop's, and trailers after the body), its first
    // bytes and curl's own error, so a refusal names the hop that made it (the machine's proxy, the edge, cmux or the
    // gateway).
    let mark = probe_mark();
    let probe = probe_command(&mark);
    let (_, out) = machine.exec(&probe, 90_000).await?;
    let status = out.lines().next().unwrap_or("").trim();
    if status != "200" {
        return Err(format!(
            "the machine's model call through the gateway answered HTTP {status}\n{}",
            shown_answer(&out, &mark)
        ));
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

/// The gateway probe run on the machine; `mark` starts its marker lines (probe_mark). Headers and body are written
/// apart (`-D`, `-o`) and printed after a marker line holding a nonce the answer cannot know, so no body line or
/// trailer passes for the other. The raw headers hold credentials until shown_answer filters them, so all three files
/// live in a private directory (mktemp -d, umask 077) that a trap removes however the shell ends.
fn probe_command(mark: &str) -> String {
    format!(
        "umask 077; d=$(mktemp -d) || exit 1; trap 'rm -rf \"$d\"' 0; trap 'exit 1' 1 2 13 15; \
         code=$(curl -sS -D \"$d/headers\" -o \"$d/body\" -w '%{{http_code}}' --max-time 60 \
         -H 'authorization: Bearer {PLACEHOLDER}' \
         'https://coderouter.cmux.internal/v1/models?client_version=0.0.0' 2>\"$d/error\"); \
         echo \"$code\"; echo '{mark}headers'; head -c {PROBE_HEADERS_READ} \"$d/headers\"; echo; echo '{mark}body'; \
         head -c {PROBE_EXCERPT} \"$d/body\"; echo; echo '{mark}error'; head -c 300 \"$d/error\""
    )
}

/// How much of the probe's answer comes back to name a refusal: of the header lines once filtered, and of the body.
const PROBE_EXCERPT: usize = 1500;

/// How much of the header lines is read for filtering: a long cookie, dropped, never takes the room of the headers
/// after it (a hop's `server`, the next hop's status line).
const PROBE_HEADERS_READ: usize = 16 * 1024;

/// The start of the probe's marker lines: random per probe, so neither the answer nor a hop can write one.
fn probe_mark() -> String {
    use std::hash::BuildHasher;
    format!("@@probe-{:016x}-", std::collections::hash_map::RandomState::new().hash_one(now_ms()))
}

/// The probe's output (`mark` the start of its marker lines) as it may be printed. Every line of the header part (each
/// hop's headers, and trailers after the body) is a header: one that can carry a credential (a cookie, an
/// authorization, a token) is dropped with its folded continuation lines, and so is one with no name. The body and
/// curl's error are shown as they are. Control characters other than line breaks are left out. The header lines kept
/// are held to PROBE_EXCERPT bytes, after filtering, and a line says when more were left out.
fn shown_answer(out: &str, mark: &str) -> String {
    let secret = |name: &str| {
        let name = name.trim().to_ascii_lowercase();
        ["cookie", "authorization", "token", "secret", "key"].iter().any(|s| name.contains(s))
    };
    let (mut part, mut dropping) = ("", false);
    let (mut header_bytes, mut headers_cut) = (0, false);
    let mut shown = Vec::new();
    for line in out.lines().skip(1) {
        if let Some(next) = line.strip_prefix(mark) {
            if part == "headers" && headers_cut {
                shown.push("[more header lines not shown]".to_owned());
            }
            (part, dropping) = (next, false);
            continue;
        }
        if part == "headers" {
            if line.starts_with("HTTP/") || line.trim_end_matches('\r').is_empty() {
                // A hop's status line, or the empty line that ends a hop's headers or comes before trailers.
                dropping = false;
            } else if line.starts_with([' ', '\t']) {
                // A folded header goes on with the one before it, a line of only whitespace too.
                if dropping {
                    continue;
                }
            } else {
                dropping = line.split_once(':').is_none_or(|(name, _)| secret(name));
                if dropping {
                    continue;
                }
            }
        } else if part != "body" && part != "error" {
            // Nothing comes before the first marker; anything else would be unlooked at.
            continue;
        }
        let line = line.chars().filter(|c| !c.is_control()).collect::<String>();
        if part == "headers" {
            header_bytes += line.len() + 1;
            if header_bytes > PROBE_EXCERPT {
                headers_cut = true;
                continue;
            }
        }
        shown.push(line);
    }
    shown.join("\n").trim().to_owned()
}

fn login_present() -> &'static str {
    "test -s \"$HOME/.codex/auth.json\" && grep -q '\"refresh_token\"' \"$HOME/.codex/auth.json\""
}

/// The device path: the machine runs Codex's own device sign-in; the person approves on their computer.
async fn device(machine: &Machine<'_>) -> Result<(), String> {
    // The image's own-login rule: an owner machine only (a team machine's Unix user is every member's). A machine
    // that does not say which it is counts as a team machine, as the image's own rule does.
    let (code, kind) =
        machine.exec("cat /etc/cmux/vm-kind 2>/dev/null || echo team", 30_000).await?;
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
                    "Codex's sign-in on the machine ended without a login; run setup again".into(),
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

    /// What the probe prints: its status, then the header file, the body and curl's error after their markers.
    fn probe_out(mark: &str, headers: &str, body: &str) -> String {
        format!("403\n{mark}headers\n{headers}\n{mark}body\n{body}\n{mark}error\n")
    }

    #[test]
    fn a_refused_probe_shows_its_answer_without_credentials() {
        let mark = probe_mark();
        let headers = "HTTP/1.1 403 Forbidden\r\nserver: edge-proxy\r\nset-cookie: sid=abc\r\nAuthorization: Bearer x\r\n\
                       x-api-key: k\r\ncontent-type: text/plain\r\n\r\n";
        let shown = shown_answer(
            &probe_out(&mark, headers, "host not allowed: coderouter\u{1b}[0m"),
            &mark,
        );
        assert_eq!(
            shown,
            "HTTP/1.1 403 Forbidden\nserver: edge-proxy\ncontent-type: text/plain\n\n\nhost not allowed: coderouter[0m"
        );
        assert!(
            !shown.contains("sid=") && !shown.contains("Bearer") && !shown.contains("x-api-key")
        );
        // A body line that merely mentions a key word is kept: only header lines are matched.
        let shown = shown_answer(&probe_out(&mark, "", "the token you sent: none"), &mark);
        assert_eq!(shown, "the token you sent: none");
    }

    #[test]
    fn a_folded_credential_header_is_dropped_with_its_continuations() {
        let mark = probe_mark();
        let headers = "HTTP/1.1 200 Connection established\r\nproxy-agent: p\r\n\r\n\
                       HTTP/1.1 403 Forbidden\r\nSet-Cookie:\r\n\tsid=abc\r\n  more=def\r\nx-trace: t1\r\n\
                       \tcontinued\r\nAuthorization:\r\n Bearer zzz\r\n\r\n";
        let shown = shown_answer(&probe_out(&mark, headers, "  indented body line"), &mark);
        assert_eq!(
            shown,
            "HTTP/1.1 200 Connection established\nproxy-agent: p\n\nHTTP/1.1 403 Forbidden\nx-trace: t1\ncontinued\n\n\n  indented body line"
        );
        assert!(!shown.contains("sid=") && !shown.contains("more=") && !shown.contains("zzz"));
    }

    #[test]
    fn a_whitespace_only_continuation_keeps_the_header_it_folds() {
        // A continuation of only whitespace neither ends the headers nor the dropped header it goes on with.
        let mark = probe_mark();
        let headers = "HTTP/1.1 403 Forbidden\r\nSet-Cookie:\r\n \r\n sid=private-session\r\n\
                       Authorization: Bearer private-token\r\nserver: edge\r\n\t\r\n\r\n";
        let shown = shown_answer(&probe_out(&mark, headers, "refused"), &mark);
        assert!(!shown.contains("private-session") && !shown.contains("private-token"), "{shown}");
        assert_eq!(shown, "HTTP/1.1 403 Forbidden\nserver: edge\n\n\n\nrefused");
    }

    #[test]
    fn trailers_after_the_body_are_filtered_as_headers() {
        // curl writes a chunked answer's trailers to the header file after an empty line (checked with curl 8.5).
        let mark = probe_mark();
        let headers = "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\nserver: edge\r\n\r\n\
                       Set-Cookie: sid=trailer-secret\r\n continued-secret\r\nX-Api-Key: trailer-key\r\nx-hop: gw\r\n";
        let shown = shown_answer(&probe_out(&mark, headers, "refused"), &mark);
        for secret in ["trailer-secret", "continued-secret", "trailer-key"] {
            assert!(!shown.contains(secret), "{shown}");
        }
        assert!(
            shown.contains("server: edge")
                && shown.contains("x-hop: gw")
                && shown.ends_with("refused")
        );
    }

    #[test]
    fn a_long_dropped_cookie_leaves_room_for_the_headers_after_it() {
        // The excerpt holds the headers kept, not the raw ones: a cookie past the whole budget is dropped and the next
        // hop's status and server still show; headers past the budget are cut with a line that says so.
        let mark = probe_mark();
        let cookie = "x".repeat(PROBE_EXCERPT * 2);
        let headers = format!(
            "HTTP/1.1 200 Connection established\r\nSet-Cookie: sid={cookie}\r\n\r\n\
             HTTP/1.1 403 Forbidden\r\nserver: the-refusing-hop\r\n\r\n"
        );
        let shown = shown_answer(&probe_out(&mark, &headers, "refused"), &mark);
        assert!(
            shown.contains("HTTP/1.1 403 Forbidden\nserver: the-refusing-hop")
                && !shown.contains("sid="),
            "{shown}"
        );
        assert!(!shown.contains("not shown"), "{shown}");
        let many = "x-hop: value\r\n".repeat(200);
        let shown = shown_answer(
            &probe_out(&mark, &format!("HTTP/1.1 403 Forbidden\r\n{many}"), "refused"),
            &mark,
        );
        let header_part = shown.split("[more header lines not shown]").next().unwrap_or("");
        assert!(
            header_part.len() <= PROBE_EXCERPT && shown.contains("[more header lines not shown]"),
            "{shown}"
        );
        assert!(shown.ends_with("refused"), "{shown}");
    }

    #[test]
    fn a_body_cannot_pass_for_the_header_part() {
        // The marker's nonce is new each probe, so a body that writes a marker line of its own stays body, and nothing
        // in the body is read as headers; an answer written before the first marker is never shown.
        let mark = probe_mark();
        assert_ne!(mark, probe_mark());
        let body = "@@probe-0000000000000000-headers\nSet-Cookie: kept-as-body";
        let shown = shown_answer(
            &format!("403\nstray-before-marker\n{}", &probe_out(&mark, "", body)[4..]),
            &mark,
        );
        assert!(
            shown.contains("Set-Cookie: kept-as-body") && !shown.contains("stray-before-marker"),
            "{shown}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_raw_headers_stay_private_and_are_removed() {
        // A stand-in curl, first on PATH: it writes a credential header and records, while the request runs, who may
        // read the probe's directory and its header file. After the probe, the directory is gone.
        use std::os::unix::fs::PermissionsExt;
        let bin = std::env::temp_dir().join(format!("probe-test-{}", std::process::id()));
        std::fs::create_dir_all(&bin).unwrap();
        let log = bin.join("log");
        let curl = bin.join("curl");
        std::fs::write(
            &curl,
            "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in -D) h=$2; shift;; -o) b=$2; shift;; esac; shift; done\n\
             printf 'HTTP/1.1 403 Forbidden\\r\\nSet-Cookie: sid=raw-secret\\r\\nserver: edge\\r\\n\\r\\n' > \"$h\"\n\
             printf 'refused' > \"$b\"\n\
             { dirname \"$h\"; ls -ld \"$(dirname \"$h\")\" \"$h\"; } > \"$PROBE_LOG\"\nprintf 403\n",
        )
        .unwrap();
        std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mark = probe_mark();
        let out = cmux_process::Command::new("sh")
            .arg("-c")
            .arg(probe_command(&mark))
            .env("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default()))
            .env("PROBE_LOG", &log)
            .output()
            .unwrap();
        let out = String::from_utf8_lossy(&out.stdout).into_owned();
        let seen = std::fs::read_to_string(&log).unwrap();
        std::fs::remove_dir_all(&bin).unwrap();
        let mut lines = seen.lines();
        let dir = lines.next().unwrap();
        let modes: Vec<&str> = lines.map(|l| l.split_whitespace().next().unwrap_or("")).collect();
        assert_eq!(modes, ["drwx------", "-rw-------"], "{seen}");
        assert!(!std::path::Path::new(dir).exists(), "{dir} was left behind");
        assert!(out.starts_with("403\n"), "{out}");
        let shown = shown_answer(&out, &mark);
        assert!(
            !shown.contains("raw-secret")
                && shown.contains("server: edge")
                && shown.contains("refused"),
            "{shown}"
        );
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
        assert_eq!(o.gateway, None);
        let o = parse(
            &args(&[
                "--machine",
                "vm_abcdefghij0123456789",
                "--api",
                "https://api.cmux.dev",
                "--gateway-machine",
                "vm_gateway0000000000000",
                "--upstream",
                "http://127.0.0.1:8317",
            ]),
            &none,
        )
        .unwrap();
        assert_eq!(o.gateway.map(|g| g.upstream), Some("http://127.0.0.1:8317".to_owned()));
        let quoted = [
            "--machine",
            "vm_abcdefghij0123456789",
            "--api",
            "https://a.dev",
            "--gateway-machine",
            "vm_gateway0000000000000",
            "--upstream",
            "http://x/'y",
        ];
        assert!(parse(&args(&quoted), &none).is_err());
        let userinfo = quoted.map(|a| if a == "http://x/'y" { "https://u:secret@x" } else { a });
        assert!(parse(&args(&userinfo), &none).is_err());
        assert!(
            parse(
                &args(&[
                    "--machine",
                    "vm_abcdefghij0123456789",
                    "--api",
                    "https://a.dev",
                    "--upstream",
                    "http://x"
                ]),
                &none
            )
            .is_err()
        );
        assert!(parse(&args(&["--api", "https://a.dev"]), &none).is_err());
        // Through the dispatch, --machine stays setup's own: the global scan once took it (gateway-e2e run 42363310378).
        let rest = setup_args(&args(&[
            "inference",
            "setup",
            "--machine",
            "vm_0123456789abcdefghij",
            "--api",
            "https://a.dev",
        ]))
        .expect("inference setup");
        assert_eq!(rest, args(&["--machine", "vm_0123456789abcdefghij", "--api", "https://a.dev"]));
        assert!(parse(&rest, &none).is_ok());
        assert!(
            setup_args(&args(&["inference", "gateway", "--machine", "vm_0123456789abcdefghij"]))
                .is_none()
        );
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
