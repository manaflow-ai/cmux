//! `cmux cloud journey`: the Cloud journey's core on the shipped Rust client (cmuxterm-hq
//! `plans/cloud/ARCHITECTURE-2026-11.md` M1b, "gate runs the shipped client"). One headless run
//! signs in, makes a machine, waits for it to run, starts a Claude chat on it, reads the first
//! reply and deletes the machine, with every call through this binary's own Cloud code:
//! `cmux_cloud_client::ops` (`cloud.machine.create|get|delete`), the client session and machine exec
//! route `cmux machine access exec` uses (cloud_client_session.rs), the fs/write route, and
//! `cmux-stack-auth`'s password sign-in.
//!
//! The steps carry the names scripts/cmux-next/cloud-journey.ts gives them (`create machine`,
//! `running (status)`, `first exec`, `pass Claude login`, `start agent (claude)`, `send chat`, `reply`,
//! `delete`), and `--out DIR` writes the same `journey.json` and `summary.md`, so
//! cloud-journey-ci.sh, its `--compare` and a reader of the job summary take either driver's run.
//! The rest of the TS journey (listed, pause and resume, carrier dial, later turns, daemon restart,
//! the clean-room probe, gateway and GitHub legs) is not here yet; the gate runs both.
//!
//! Auth: `CMUX_CLOUD_ACCESS_TOKEN` (with `CMUX_CLOUD_API_URL` or `--backend`), else the agent test
//! account's `CMUX_DOGFOOD_STACK_EMAIL` and `CMUX_DOGFOOD_STACK_PASSWORD` (Stack password sign-in on the
//! backend's Stack project). The chat's model connection is `CLAUDE_CODE_OAUTH_TOKEN`, given to the agent
//! at its start (`session/new` `_meta.acpmux.credentials`, cmux#40159), never written onto the machine.
//! `--model-stub FILE` (tests/fixtures/model-stub/model_stub.py) runs that stub on the machine's loopback
//! instead and passes a made-up login: the reply must carry the stub's nonce and its tool's output.
//! Secrets go only in headers and on stdin of a guest program; every detail is scrubbed of them.

use std::io::Write as _;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_cloud_api::session::{ExecAnswer, Session, mint_session, redact};
use cmux_cloud_client::machine::{Machine, Scope};
use cmux_cloud_client::ops::{self, Answer};
use cmux_cloud_wire::{
    CloudMachineCreateOp, CloudMachineCreateParams, CloudMachineDeleteOp, CloudMachineDeleteParams,
    CloudMachineGetOp, CloudMachineGetParams, CloudMachineSize, CloudMachineStatus,
};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

#[path = "cloud_journey/repo.rs"]
mod repo;

pub(super) const USAGE: &str = "\
usage: cmux cloud journey [--backend staging|prod|dev|preview-N | --api URL] [--team TEAM_ID]
                          [--model-stub FILE] [--prompt TEXT] [--chat-timeout SECONDS]
                          [--out DIR] [--json]
                          [--repo SPEC [--machine-config FILE]] [--keep]

The Cloud journey's core, headless, on this binary's own Cloud client: sign in,
create machine, running, first exec, pass Claude login, start agent (claude),
send chat, reply, delete. Each step prints PASS/FAIL/SKIP with its time; --out
DIR writes journey.json and summary.md as scripts/cmux-next/cloud-journey.ts
does. The machine is deleted at the end, pass or fail. Exit 0 only when no step
failed.

Auth: CMUX_CLOUD_ACCESS_TOKEN (and CMUX_CLOUD_API_URL or --backend), else
CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the agent test
account). The chat's model connection is CLAUDE_CODE_OAUTH_TOKEN; --model-stub
FILE runs that model stub on the machine instead, with a made-up login.

--repo SPEC (OWNER/NAME, a GitHub or https git URL, #REF) is a moved project's
journey (cmux migrate): after the first exec the machine clones it and applies
its machine config (--machine-config FILE, else the checkout's own
.cmux/machine.toml) as the app's start does, and the chat starts in the
checkout. --keep leaves the machine running at the end (its id is in the
delete step) instead of deleting it.
";

/// The shipped app's chat start size (cloud-journey.ts `CHAT_START_SIZE`, the platform's CHAT_START_SHAPE).
const CHAT_START_SIZE: (i64, i64, i64) = (4, 16_384, 65_536);
const RUNNING_BUDGET: Duration = Duration::from_secs(300);
const DEFAULT_CHAT_BUDGET: Duration = Duration::from_secs(300);
const DEFAULT_PROMPT: &str = "Reply with one short sentence that names the planet you are on.";
/// A client session lives this long; one older than [`SESSION_REUSE`] is minted again.
const SESSION_TTL_S: u64 = 900;
const SESSION_REUSE: Duration = Duration::from_secs(600);
/// The guest's own cmux-tui (cloud-journey.ts `GUEST`).
const GUEST: &str = "export HOME=\"${HOME:-/home/cmux}\"; cd \"$HOME\" 2>/dev/null || cd /; c=cmux-tui; [ -x \"$HOME/.cmux/bin/cmux-tui\" ] && c=\"$HOME/.cmux/bin/cmux-tui\"; ";
const STUB_FILE: &str = "/home/cmux/.cmux/journey-model-stub.py";
const STUB_SCRIPT: &str = "/home/cmux/.cmux/journey-model-stub.json";
const STUB_READY: &str = "/home/cmux/.cmux/journey-model-stub.ready";
const STUB_LOG: &str = "/home/cmux/.cmux/journey-model-stub.log";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Args {
    pub backend: String,
    pub api: Option<String>,
    pub team: Option<String>,
    pub model_stub: Option<PathBuf>,
    pub prompt: String,
    pub chat_budget: Duration,
    pub out: Option<PathBuf>,
    /// `--repo`: the moved project's repository (repo.rs).
    pub repo: Option<String>,
    pub machine_config: Option<PathBuf>,
    /// `--keep`: the machine is the migrated project's, so it stays.
    pub keep: bool,
}

/// `Some(exit code)` when `args` is `cloud journey …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != "journey" {
        return None;
    }
    if rest.iter().any(|w| w == "-h" || w == "--help" || w == "help") {
        print!("{USAGE}");
        return Some(0);
    }
    match parse(rest) {
        Ok(parsed) => Some(run(&global, &parsed)),
        Err(message) => Some(super::app::failure(
            "usage.invalid",
            &format!("cmux: {message}\n{USAGE}"),
            global.output,
            2,
        )),
    }
}

pub(super) fn parse(words: &[String]) -> Result<Args, String> {
    let mut args = Args {
        backend: String::new(),
        api: None,
        team: None,
        model_stub: None,
        prompt: DEFAULT_PROMPT.to_owned(),
        chat_budget: DEFAULT_CHAT_BUDGET,
        out: None,
        repo: None,
        machine_config: None,
        keep: false,
    };
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{word} needs a value"));
        match word.as_str() {
            "--backend" => args.backend = value()?,
            "--api" => args.api = Some(value()?),
            "--team" => args.team = Some(value()?),
            "--model-stub" => args.model_stub = Some(PathBuf::from(value()?)),
            "--prompt" => args.prompt = value()?,
            "--chat-timeout" => {
                let raw = value()?;
                let seconds: u64 =
                    raw.parse().map_err(|_| format!("--chat-timeout takes seconds, not {raw}"))?;
                args.chat_budget = Duration::from_secs(seconds.clamp(10, 3600));
            }
            "--out" => args.out = Some(PathBuf::from(value()?)),
            "--repo" => {
                let spec = value()?;
                repo::parse_repo(&spec)?;
                args.repo = Some(spec);
            }
            "--machine-config" => args.machine_config = Some(PathBuf::from(value()?)),
            "--keep" => args.keep = true,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    if args.machine_config.is_some() && args.repo.is_none() {
        return Err("--machine-config needs --repo SPEC".to_owned());
    }
    Ok(args)
}

/// A backend name's owner API and Stack project (cloud-journey.ts `resolveBackend`).
pub(super) fn resolve_backend(name: &str) -> Result<(String, &'static str, &'static str), String> {
    use cmux_cloud_environment as env;
    let dev = (env::DEVELOPMENT_STACK_PROJECT, env::DEVELOPMENT_STACK_CLIENT_KEY);
    let (api, stack) = match name {
        "staging" => (env::STAGING_API.to_owned(), dev),
        "prod" | "production" => {
            (env::PRODUCTION_API.to_owned(), (env::PRODUCTION_STACK_PROJECT, ""))
        }
        "dev" | "development" => (env::DEVELOPMENT_API.to_owned(), dev),
        _ => match name.strip_prefix("preview-") {
            Some(tag)
                if !tag.is_empty()
                    && tag.len() <= 41
                    && tag
                        .bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') =>
            {
                (format!("https://cmux-api-preview-{tag}.debussy.workers.dev"), dev)
            }
            _ => {
                return Err(format!(
                    "--backend {name}: one of staging, prod, dev, preview-N (or --api URL)"
                ));
            }
        },
    };
    Ok((api, stack.0, stack.1))
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Status {
    Pass,
    Fail,
    Skip,
}

#[derive(Debug, Clone, serde::Serialize)]
pub(super) struct Step {
    pub step: String,
    pub status: Status,
    pub ms: u64,
    pub detail: String,
}

/// The run's steps, written to `--out` after each one (cloud-journey.ts `Journey`).
struct Journey {
    backend: Value,
    /// In the TS journey's order: the summary prints it as given.
    meta: Vec<(&'static str, String)>,
    out: Option<PathBuf>,
    secrets: Vec<String>,
    steps: Vec<Step>,
    quiet: bool,
}

impl Journey {
    fn record(&mut self, step: &str, status: Status, started: Instant, detail: &str) {
        let mut detail = detail.to_owned();
        for secret in &self.secrets {
            detail = redact(&detail, secret, "");
        }
        let detail: String = detail.chars().take(1000).collect();
        let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        if !self.quiet {
            let word = match status {
                Status::Pass => "PASS",
                Status::Fail => "FAIL",
                Status::Skip => "SKIP",
            };
            println!("{word:<4} {step} {ms} ms :: {detail}");
        }
        self.steps.push(Step { step: step.to_owned(), status, ms, detail });
        self.flush();
    }

    fn pass(&mut self, step: &str, started: Instant, detail: &str) {
        self.record(step, Status::Pass, started, detail);
    }

    fn fail(&mut self, step: &str, started: Instant, detail: &str) {
        self.record(step, Status::Fail, started, detail);
    }

    fn json(&self) -> Value {
        let meta: serde_json::Map<String, Value> =
            self.meta.iter().map(|(k, v)| ((*k).to_owned(), Value::from(v.as_str()))).collect();
        json!({ "backend": self.backend, "meta": meta, "steps": self.steps })
    }

    fn flush(&self) {
        let Some(dir) = &self.out else { return };
        let _ = std::fs::create_dir_all(dir);
        let _ = std::fs::write(dir.join("journey.json"), format!("{:#}\n", self.json()));
        let name = self.backend.get("name").and_then(Value::as_str).unwrap_or("");
        let api = self.backend.get("api").and_then(Value::as_str).unwrap_or("");
        let _ = std::fs::write(
            dir.join("summary.md"),
            summary_markdown(name, api, &self.meta, &self.steps),
        );
    }
}

/// The steps a person's chat waits on, create to agent running (cloud-journey.ts `READY_STEPS`).
fn ready_ms(steps: &[Step]) -> Option<u64> {
    let ready: [fn(&str) -> bool; 5] = [
        |s| s == "create machine",
        |s| s == "running (status)",
        |s| s == "first exec",
        |s| s == "pass Claude login" || s == "pass Codex login",
        |s| s.starts_with("start agent ("),
    ];
    ready.iter().try_fold(0u64, |total, is| {
        let step = steps.iter().find(|s| is(&s.step))?;
        (step.status == Status::Pass).then(|| total.saturating_add(step.ms))
    })
}

/// cloud-journey.ts `summaryMarkdown`, line for line.
pub(super) fn summary_markdown(
    name: &str,
    api: &str,
    meta: &[(&str, String)],
    steps: &[Step],
) -> String {
    let failed = steps.iter().any(|s| s.status == Status::Fail);
    let total: u64 = steps.iter().map(|s| s.ms).sum();
    let ready = ready_ms(steps)
        .map(|ms| format!("; create machine to agent running {:.1} s", ms as f64 / 1000.0))
        .unwrap_or_default();
    let mut lines = vec![format!(
        "{}: Cloud journey on `{name}` ({api}), {:.1} s{ready}",
        if failed { "FAIL" } else { "PASS" },
        total as f64 / 1000.0
    )];
    let extra: Vec<String> = meta.iter().map(|(k, v)| format!("{k}: {v}")).collect();
    lines.push(if extra.is_empty() { String::new() } else { format!("\n{}", extra.join(", ")) });
    lines.push(String::new());
    lines.push("| result | step | ms | detail |".to_owned());
    lines.push("|---|---|---:|---|".to_owned());
    for s in steps {
        let result = match s.status {
            Status::Pass => "pass",
            Status::Fail => "**FAIL**",
            Status::Skip => "skip",
        };
        let detail: String =
            s.detail.replace('|', "\\|").replace('\n', " ").chars().take(1000).collect();
        lines.push(format!("| {result} | {} | {} | {detail} |", s.step, s.ms));
    }
    lines.push(String::new());
    lines.join("\n")
}

/// Single-quoted for a POSIX shell.
pub(super) fn shq(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// The guest program that starts `session` with the person's model connection as its launch
/// credential: `session/new` on the machine's acpmux socket with `_meta.acpmux.credentials`
/// (cloud-journey.ts `launchCredentialStartProgram`). The value is in the heredoc, on stdin, never
/// on a command line. It looks for the socket where that program does: `ACPMUX_SOCKET`, the cmux
/// daemon's acpmux home (`~/.cmux/acpmux`), then acpmux's own default home, where a machine's
/// `acpmux.service` listens (cmux-host `cloud/role.rs` `acpmux_home`). Without the last the start
/// answered "no acpmux socket" on staging machines the TypeScript journey started agents on
/// (backend runs 45306859441, 45310842160, 45312889044).
pub(super) fn launch_credential_program(
    session: &str,
    harness: &str,
    name: &str,
    value: &str,
) -> String {
    launch_credential_program_in(session, harness, name, value, None)
}

/// [`launch_credential_program`] with the chat's folder: `cwd` (a moved project's checkout), else
/// the machine user's home.
pub(super) fn launch_credential_program_in(
    session: &str,
    harness: &str,
    name: &str,
    value: &str,
    cwd: Option<&str>,
) -> String {
    let cwd = serde_json::to_string(cwd.unwrap_or("")).unwrap_or_else(|_| "\"\"".into());
    let params = json!({
        "mcpServers": [],
        "_meta": { "acpmux": { "name": session, "harness": harness, "credentials": { "env": { name: value } } } },
    });
    let params = serde_json::to_string(&params.to_string()).unwrap_or_default();
    // acpmux's own home under the machine user's home, from acpmux's resolver, not a literal.
    let own = acpmux::config::default_home_in(std::path::Path::new(""));
    let own = own.to_string_lossy();
    format!(
        r#"python3 -I - <<'CMUX_JOURNEY_START'
import json, os, socket, sys
params = json.loads({params})
home = os.environ.get('HOME') or '/home/cmux'
params['cwd'] = {cwd} or home
paths = [p for p in (os.environ.get('ACPMUX_SOCKET'), home + '/.cmux/acpmux/acpmux.sock', home + '/{own}/acpmux.sock') if p]
def call(f, s, i, method, p):
    s.sendall((json.dumps({{'jsonrpc': '2.0', 'id': i, 'method': method, 'params': p}}) + '\n').encode())
    while True:
        line = f.readline()
        if not line:
            raise RuntimeError(method + ': the daemon closed the connection')
        m = json.loads(line)
        if m.get('id') == i:
            if m.get('error'):
                raise RuntimeError(method + ': ' + json.dumps(m['error'])[:400])
            return m.get('result')
errors = []
for path in paths:
    if not os.path.exists(path):
        continue
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(110)
        s.connect(path)
        f = s.makefile('r')
        call(f, s, 1, 'initialize', {{'protocolVersion': 1, 'clientCapabilities': {{}}, 'clientInfo': {{'name': 'cmux-cloud-journey', 'version': '1'}}}})
        r = call(f, s, 2, 'session/new', params)
        print('@@session ' + str((r or {{}}).get('sessionId')))
        sys.exit(0)
    except Exception as e:
        errors.append(path + ': ' + str(e))
print('@@nostart ' + ('; '.join(errors) or 'no acpmux socket at ' + ', '.join(paths)))
sys.exit(1)
CMUX_JOURNEY_START"#
    )
}

/// The stub's turn script: one shell tool call, then a reply naming the nonce and the tool's output
/// (cloud-journey.ts `JOURNEY_STUB_SCRIPT`'s steps).
fn stub_script() -> Value {
    json!({
        "version": 1,
        "steps": [
            { "shell": "printf '%s-%s\\n' {{nonce}} tool" },
            { "text": "Stub reply {{nonce}}. The tool printed {{result.0}}." },
        ],
    })
}

/// What a stub reply must carry: the nonce and the tool's output, so the tool ran and came back.
pub(super) fn stub_reply_ok(reply: &str, nonce: &str) -> bool {
    reply.contains(&format!("Stub reply {nonce}. The tool printed {nonce}-tool"))
}

fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    if getrandom::fill(&mut buf).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        return format!("{nanos:x}").chars().rev().take(bytes * 2).collect();
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// `jr-` and the start time in base 36, as cloud-journey.ts tags a run (its leaked-machine sweep reads it).
fn run_tag() -> String {
    let mut ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let mut out = Vec::new();
    while ms > 0 {
        out.extend(u32::try_from(ms % 36).ok().and_then(|d| char::from_digit(d, 36)));
        ms /= 36;
    }
    format!("jr-{}", out.iter().rev().collect::<String>())
}

/// One machine's exec, through a client session minted once and reused, or through the cmux API's
/// exec route on a provider with no client sessions (cloud_client_session.rs's two routes).
struct Exec<'a> {
    client: &'a reqwest::Client,
    scope: &'a Scope,
    credential: &'a str,
    machine: Machine,
    session: Option<(Session, Instant)>,
    direct: bool,
}

impl Exec<'_> {
    /// Writes `data` to `path` on the machine over the Cloud file API (`/fs/write`).
    async fn write(&self, path: &str, data: &[u8], mode: u32) -> Result<(), String> {
        use base64::Engine as _;
        let url = self.scope.route(&self.machine, "/fs/write").map_err(|e| e.to_string())?;
        let mut request = self
            .client
            .post(url)
            .bearer_auth(self.credential)
            .timeout(Duration::from_secs(60))
            .json(&json!({ "path": path, "dataBase64": base64::engine::general_purpose::STANDARD.encode(data), "mode": mode }));
        if let Some(team) = self.scope.team() {
            request = request.header(cmux_cloud_client::TEAM_HEADER, team);
        }
        let response =
            request.send().await.map_err(|e| format!("fs/write {path}: {}", e.without_url()))?;
        let status = response.status();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() || body.get("ok") == Some(&Value::Bool(false)) {
            let code = body.pointer("/error/code").and_then(Value::as_str).unwrap_or("");
            return Err(format!("fs/write {path}: HTTP {} {code}", status.as_u16()));
        }
        Ok(())
    }

    async fn run(&mut self, command: &str, timeout_ms: u64) -> Result<ExecAnswer, String> {
        if !self.direct && self.session.as_ref().is_none_or(|(_, at)| at.elapsed() > SESSION_REUSE)
        {
            match mint_session(
                self.client,
                self.scope,
                self.credential,
                &self.machine,
                Some(SESSION_TTL_S),
            )
            .await
            {
                Ok(session) => self.session = Some((session, Instant::now())),
                Err(refusal) if refusal.code == "cloud.provider.unsupported" => self.direct = true,
                Err(refusal) => return Err(refusal.message),
            }
        }
        let answer = match &self.session {
            Some((session, _)) if !self.direct => {
                super::cloud_client_session::exec(self.client, session, command, timeout_ms).await?
            }
            _ => {
                super::cloud_client_session::exec_route(
                    self.client,
                    self.scope,
                    self.credential,
                    &self.machine,
                    command,
                    timeout_ms,
                )
                .await?
            }
        };
        let token = self.session.as_ref().map(|(s, _)| s.token.as_str()).unwrap_or("");
        Ok(ExecAnswer {
            exit_code: answer.exit_code,
            stdout: redact(&answer.stdout, token, self.credential),
            stderr: redact(&answer.stderr, token, self.credential),
        })
    }
}

fn tail(text: &str, n: usize) -> String {
    let mut chars: Vec<char> = text.chars().rev().take(n).collect();
    chars.reverse();
    chars.into_iter().collect()
}

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())
}

pub(super) fn run(global: &GlobalArgs, args: &Args) -> i32 {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            return super::app::failure(
                "journey.runtime",
                &format!("cmux: {error}"),
                global.output,
                1,
            );
        }
    };
    match runtime.block_on(journey(global, args)) {
        Ok(code) => code,
        Err(message) => {
            super::app::failure("journey.setup", &format!("cmux: {message}"), global.output, 1)
        }
    }
}

async fn journey(global: &GlobalArgs, args: &Args) -> Result<i32, String> {
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let (backend_api, stack_project, stack_key) = match (&args.api, args.backend.as_str()) {
        (Some(api), _) => (
            api.clone(),
            cmux_cloud_environment::DEVELOPMENT_STACK_PROJECT,
            cmux_cloud_environment::DEVELOPMENT_STACK_CLIENT_KEY,
        ),
        (None, "") => match env_nonempty("CMUX_CLOUD_API_URL") {
            Some(api) => (
                api,
                cmux_cloud_environment::DEVELOPMENT_STACK_PROJECT,
                cmux_cloud_environment::DEVELOPMENT_STACK_CLIENT_KEY,
            ),
            None => {
                return Err(
                    "name the backend with --backend NAME, --api URL or CMUX_CLOUD_API_URL".into(),
                );
            }
        },
        (None, name) => resolve_backend(name)?,
    };
    let api = cmux_cloud_api::session::secure_origin(backend_api.trim())?;
    let name = if args.backend.is_empty() { "custom".to_owned() } else { args.backend.clone() };
    let stub_nonce = random_hex(6);
    let login = match &args.model_stub {
        Some(_) => format!("sk-ant-oat01-journeystub-{}", random_hex(24)),
        None => env_nonempty("CLAUDE_CODE_OAUTH_TOKEN").unwrap_or_default(),
    };
    let tag = run_tag();
    let mut j = Journey {
        backend: json!({ "name": name, "api": api, "stack": if stack_project == cmux_cloud_environment::PRODUCTION_STACK_PROJECT { "prod" } else { "dev" } }),
        meta: vec![
            ("tag", tag.clone()),
            ("team", args.team.clone().unwrap_or_else(|| "(personal)".into())),
            ("agent", "claude".into()),
            (
                "driver",
                concat!("cmux cloud journey (Rust, cmux-tui ", env!("CARGO_PKG_VERSION"), ")")
                    .into(),
            ),
            (
                "model",
                if args.model_stub.is_some() { "stub (on the machine)" } else { "real" }.into(),
            ),
        ],
        out: args.out.clone(),
        secrets: vec![login.clone()],
        steps: Vec::new(),
        quiet: json_out,
    };
    if login.is_empty() {
        j.secrets.clear();
    }

    // Sign in: the caller's credential, else the agent test account's password.
    let bearer = match env_nonempty("CMUX_CLOUD_ACCESS_TOKEN") {
        Some(token) => token,
        None => {
            let t0 = Instant::now();
            let (Some(email), Some(password)) = (
                env_nonempty("CMUX_DOGFOOD_STACK_EMAIL"),
                env_nonempty("CMUX_DOGFOOD_STACK_PASSWORD"),
            ) else {
                j.fail(
                    "sign in (agent test account)",
                    t0,
                    "no CMUX_CLOUD_ACCESS_TOKEN and no CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD",
                );
                return Ok(finish(&j, json_out));
            };
            j.secrets.push(password.clone());
            let signed = async {
                let stack = cmux_stack_auth::StackClient::new(cmux_stack_auth::StackConfig::new(
                    cmux_cloud_environment::STACK_ORIGIN,
                    stack_project,
                    stack_key,
                ))
                .map_err(|e| e.to_string())?;
                let session = stack
                    .sign_in_with_password(&email, &password)
                    .await
                    .map_err(|e| e.to_string())?;
                session
                    .access_token
                    .ok_or_else(|| "the sign-in answered no access token".to_owned())
            }
            .await;
            match signed {
                Ok(token) => {
                    j.pass(
                        "sign in (agent test account)",
                        t0,
                        "Stack password sign-in (cmux-stack-auth)",
                    );
                    token
                }
                Err(error) => {
                    j.fail("sign in (agent test account)", t0, &error);
                    return Ok(finish(&j, json_out));
                }
            }
        }
    };
    j.secrets.push(bearer.clone());

    let ua = concat!("cmux/", env!("CARGO_PKG_VERSION"), " cloud-journey");
    let (base, http) = cmux_cloud_client::http(
        &api,
        Some(&bearer),
        args.team.as_deref(),
        ua,
        Duration::from_secs(120),
    )
    .map_err(|e| e.to_string())?;
    let exec_client = cmux_egress::client_builder("cmux_tui::cli::cloud_journey")
        .default_headers(cmux_build_space::headers().map_err(|e| e.to_string())?)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(ua)
        .build()
        .map_err(|e| e.to_string())?;
    let scope = Scope::new(&api, args.team.as_deref()).map_err(|e| e.to_string())?;

    // create machine
    let t0 = Instant::now();
    let machine_name = format!("cloud journey auto {tag}");
    let create_key = cmux_cloud_client::client_key();
    let params = CloudMachineCreateParams {
        name: Some(machine_name.clone()),
        size: CloudMachineSize {
            cpu: Some(CHAT_START_SIZE.0),
            memory_mb: Some(CHAT_START_SIZE.1),
            disk_mb: Some(CHAT_START_SIZE.2),
        },
        image: None,
        from_snapshot: None,
        origin: None,
        ttl_seconds: None,
    };
    let mut created = None;
    for attempt in 0..3 {
        // The same key on each retry: a lost answer never makes a second machine.
        let answer = ops::call::<CloudMachineCreateOp>(
            &http,
            &base,
            params.clone(),
            Some(&create_key),
            None,
        )
        .await
        .and_then(Answer::into_result);
        match answer {
            Ok(value) => {
                created = Some(value.machine);
                break;
            }
            Err(error) if error.retryable && attempt < 2 => {
                tokio::time::sleep(
                    error
                        .retry_after
                        .unwrap_or(Duration::from_secs(3))
                        .min(Duration::from_secs(20)),
                )
                .await;
            }
            Err(error) => {
                j.fail(
                    "create machine",
                    t0,
                    &format!("{} {}", error.code.unwrap_or_default(), error.message),
                );
                break;
            }
        }
    }
    let Some(machine) = created else {
        j.record("delete", Status::Skip, Instant::now(), "no machine was made");
        return Ok(finish(&j, json_out));
    };
    let machine_id = machine.id.clone();
    j.pass("create machine", t0, &format!("{machine_id} status {}", machine.status.as_str()));

    // A failed step is recorded; the machine is deleted either way.
    let _ = chat_steps(
        &mut j,
        &http,
        &base,
        &exec_client,
        &scope,
        &bearer,
        &machine_id,
        args,
        &login,
        &stub_nonce,
    )
    .await;

    // delete, pass or fail; --keep leaves a moved project's machine running.
    let t0 = Instant::now();
    if args.keep {
        j.record("delete", Status::Skip, t0, &format!("kept: machine {machine_id} (--keep)"));
        return Ok(finish(&j, json_out));
    }
    let delete_key = cmux_cloud_client::client_key();
    let mut deleted = Err(String::new());
    for attempt in 0..4 {
        let params = CloudMachineDeleteParams { machine: machine_id.clone() };
        match ops::call::<CloudMachineDeleteOp>(&http, &base, params, Some(&delete_key), None)
            .await
            .and_then(Answer::into_result)
        {
            Ok(_) => {
                deleted = Ok(());
                break;
            }
            Err(error) if error.code.as_deref() == Some("cloud.machine.not_found") => {
                deleted = Ok(());
                break;
            }
            Err(error) if error.retryable && attempt < 3 => {
                deleted = Err(format!("{} {}", error.code.unwrap_or_default(), error.message));
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
            Err(error) => {
                deleted = Err(format!("{} {}", error.code.unwrap_or_default(), error.message));
                break;
            }
        }
    }
    match deleted {
        Ok(()) => j.pass("delete", t0, &machine_id),
        Err(error) => j.fail("delete", t0, &format!("{machine_id}: {error}")),
    }
    Ok(finish(&j, json_out))
}

/// running, first exec, the model stub, pass login, start agent, send chat, reply. Stops at the
/// first failed step; the caller deletes the machine either way.
#[allow(clippy::too_many_arguments)]
async fn chat_steps(
    j: &mut Journey,
    http: &reqwest::Client,
    base: &str,
    exec_client: &reqwest::Client,
    scope: &Scope,
    bearer: &str,
    machine_id: &str,
    args: &Args,
    login: &str,
    nonce: &str,
) -> Result<(), ()> {
    // running (status)
    let t0 = Instant::now();
    let mut last: String;
    loop {
        let params = CloudMachineGetParams { machine: machine_id.to_owned() };
        match ops::call::<CloudMachineGetOp>(http, base, params, None, None)
            .await
            .and_then(Answer::into_result)
        {
            Ok(m) if m.status == CloudMachineStatus::Running && m.host.is_some() => {
                let daemon = m.image.daemon_version.unwrap_or_else(|| "?".into());
                j.pass(
                    "running (status)",
                    t0,
                    &format!("host {}, daemon {daemon}", m.host.unwrap_or_default()),
                );
                break;
            }
            Ok(m) if m.status == CloudMachineStatus::Failed => {
                j.fail("running (status)", t0, &format!("failed: {:?}", m.error));
                return Err(());
            }
            Ok(m) => last = m.status.as_str().to_owned(),
            Err(error) if error.retryable => last = format!("{} (retrying)", error.message),
            Err(error) => {
                j.fail(
                    "running (status)",
                    t0,
                    &format!("{} {}", error.code.unwrap_or_default(), error.message),
                );
                return Err(());
            }
        }
        if t0.elapsed() > RUNNING_BUDGET {
            j.fail(
                "running (status)",
                t0,
                &format!("not running within {} s; last {last}", RUNNING_BUDGET.as_secs()),
            );
            return Err(());
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    let machine = scope.machine(machine_id).map_err(|_| ())?;
    let mut exec = Exec {
        client: exec_client,
        scope,
        credential: bearer,
        machine,
        session: None,
        direct: false,
    };

    // first exec
    let t0 = Instant::now();
    let probe = "echo journey-ok; uname -m; echo cpu=$(nproc) mem_mib=$(free -m | awk '/^Mem:/{print $2}') disk_mib=$(df -BM --output=size / | tail -1 | tr -dc 0-9)";
    match exec.run(probe, 60_000).await {
        Ok(r) if r.exit_code == 0 && r.stdout.contains("journey-ok") => {
            let detail = r.stdout.trim().replace('\n', " ");
            let route = if exec.direct { "exec route" } else { "client session" };
            j.pass("first exec", t0, &format!("{detail} ({route})"));
        }
        Ok(r) => {
            j.fail(
                "first exec",
                t0,
                &format!("exit {} {} {}", r.exit_code, tail(&r.stdout, 200), tail(&r.stderr, 200)),
            );
            return Err(());
        }
        Err(error) => {
            j.fail("first exec", t0, &error);
            return Err(());
        }
    }

    // clone repo, machine config: a moved project's journey (repo.rs).
    let mut checkout = None;
    if let Some(spec) = &args.repo {
        let t0 = Instant::now();
        let parsed = match repo::parse_repo(spec) {
            Ok(parsed) => parsed,
            Err(error) => {
                j.fail("clone repo", t0, &error);
                return Err(());
            }
        };
        let config = match &args.machine_config {
            Some(path) => match std::fs::read(path) {
                Ok(bytes) if bytes.len() <= cmux_cloud_start_core::machine_config::MAX_BYTES => {
                    Some(bytes)
                }
                Ok(_) => {
                    j.fail("machine config", t0, &format!("{} is over 64 KiB", path.display()));
                    return Err(());
                }
                Err(error) => {
                    j.fail("machine config", t0, &format!("{}: {error}", path.display()));
                    return Err(());
                }
            },
            None => None,
        };
        checkout = Some(repo::repo_steps(j, &mut exec, &parsed, config.as_deref()).await?);
    }

    // model stub on the machine
    if let Some(stub) = &args.model_stub {
        let t0 = Instant::now();
        match start_stub(&mut exec, stub, nonce).await {
            Ok(port) => j.pass(
                "model stub on the machine",
                t0,
                &format!("the shared model stub at 127.0.0.1:{port}, nonce {nonce}, one shell tool round trip (claude)"),
            ),
            Err(error) => {
                j.fail("model stub on the machine", t0, &error);
                return Err(());
            }
        }
    }

    // pass Claude login: the person's model connection, given to the agent at its start.
    let t0 = Instant::now();
    if !login.starts_with("sk-ant-oat01-") {
        j.fail(
            "pass Claude login",
            t0,
            "CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login",
        );
        return Err(());
    }
    let own = exec
        .run(". /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login claude && echo own-login", 60_000)
        .await
        .map(|r| r.stdout.contains("own-login"))
        .unwrap_or(false);
    let held = if own {
        "the machine also holds a Claude login of its own"
    } else {
        "the machine holds none"
    };
    j.pass(
        "pass Claude login",
        t0,
        &format!(
            "the person's model connection, given to the agent at its start (cmux#40159); {held}"
        ),
    );

    // start agent (claude)
    let tag = j
        .meta
        .iter()
        .find(|(k, _)| *k == "tag")
        .map_or_else(|| "jr".to_owned(), |(_, v)| v.clone());
    let session = format!("journey-{tag}");
    let t0 = Instant::now();
    let program = format!(
        "{GUEST}{}",
        launch_credential_program_in(
            &session,
            "claude",
            "CLAUDE_CODE_OAUTH_TOKEN",
            login,
            checkout.as_deref()
        )
    );
    match exec.run(&program, 120_000).await {
        Ok(r) if r.exit_code == 0 && r.stdout.contains("@@session ") => {
            j.pass(
                "start agent (claude)",
                t0,
                &format!(
                    "session {session}, on the person's model connection (its launch credential)"
                ),
            );
        }
        Ok(r) => {
            let out = if r.stdout.trim().is_empty() { r.stderr } else { r.stdout };
            j.fail("start agent (claude)", t0, &tail(&out, 400));
            return Err(());
        }
        Err(error) => {
            j.fail("start agent (claude)", t0, &error);
            return Err(());
        }
    }

    // send chat
    let t0 = Instant::now();
    let send = format!(
        "{GUEST}printf '%s' {} | \"$c\" acp send --no-wait {} - 2>&1; echo \"@@exit $?\"",
        shq(&args.prompt),
        shq(&session)
    );
    match exec.run(&send, 60_000).await {
        Ok(r) if r.stdout.contains("@@exit 0") => {
            let shown: String = args.prompt.chars().take(80).collect();
            j.pass("send chat", t0, &shown);
        }
        Ok(r) => {
            j.fail("send chat", t0, &tail(&format!("{}{}", r.stdout, r.stderr), 400));
            return Err(());
        }
        Err(error) => {
            j.fail("send chat", t0, &error);
            return Err(());
        }
    }

    // reply
    let t0 = Instant::now();
    let wait = format!(
        "{GUEST}\"$c\" acp wait {s} --timeout 20 >/dev/null 2>&1; echo \"@@wait $?\"; \"$c\" acp last {s} 2>&1; echo \"@@lastexit $?\"",
        s = shq(&session)
    );
    let mut last = String::new();
    let outcome = loop {
        if t0.elapsed() > args.chat_budget {
            break Err(format!(
                "no reply within {} s; last: {}",
                args.chat_budget.as_secs(),
                tail(&last, 300)
            ));
        }
        let r = match exec.run(&wait, 45_000).await {
            Ok(r) => r,
            Err(error) => break Err(error),
        };
        let code = r
            .stdout
            .split("@@wait ")
            .nth(1)
            .and_then(|s| s.split_whitespace().next())
            .map(str::to_owned);
        last = r
            .stdout
            .split_once("@@wait ")
            .map(|(_, rest)| rest.split_once('\n').map(|(_, body)| body).unwrap_or(""))
            .unwrap_or("")
            .rsplit_once("@@lastexit")
            .map(|(body, _)| body)
            .unwrap_or("")
            .trim()
            .to_owned();
        match code.as_deref() {
            Some("0") if !last.is_empty() => break Ok(last.clone()),
            Some("2") => {
                break Err(format!("the agent waits on a permission: {}", tail(&last, 200)));
            }
            Some("0" | "3") | None => {}
            Some(other) => break Err(format!("acp wait exit {other}: {}", tail(&last, 300))),
        }
    };
    match outcome {
        Ok(reply) if args.model_stub.is_some() && !stub_reply_ok(&reply, nonce) => {
            j.fail(
                "reply",
                t0,
                &format!(
                    "the reply does not carry the stub's nonce {nonce} and the tool output: {}",
                    tail(&reply, 200)
                ),
            );
            Err(())
        }
        Ok(reply) => {
            let shown: String = reply.chars().take(280).collect();
            j.pass("reply", t0, &shown);
            Ok(())
        }
        Err(error) => {
            j.fail("reply", t0, &error);
            Err(())
        }
    }
}

/// Writes the stub and its script to the machine (fs/write), starts it on a free loopback port and
/// points Claude Code's settings there. Answers the port.
async fn start_stub(
    exec: &mut Exec<'_>,
    stub: &std::path::Path,
    nonce: &str,
) -> Result<String, String> {
    let program =
        std::fs::read(stub).map_err(|e| format!("--model-stub {}: {e}", stub.display()))?;
    let script = stub_script().to_string().into_bytes();
    for (path, data) in [(STUB_FILE, program), (STUB_SCRIPT, script)] {
        exec.write(path, &data, 0o644).await?;
    }
    let point = "python3 - \"$port\" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.parent.mkdir(parents=True, exist_ok=True)\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY";
    let (log, ready, file, script) =
        (shq(STUB_LOG), shq(STUB_READY), shq(STUB_FILE), shq(STUB_SCRIPT));
    let command = format!(
        "rm -f {log} {ready}; (nohup python3 {file} --port 0 --script {script} --nonce {n} --log {log} --ready-file {ready} >{log}.out 2>&1 &); \
         for i in $(seq 50); do [ -s {ready} ] && break; sleep 0.2; done; \
         port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"port\"])' {ready} 2>/dev/null); \
         [ -n \"$port\" ] && curl -fsS -m 2 \"http://127.0.0.1:$port/__stub/info\" | grep -q {n} || {{ echo stub-down; tail -5 {log}.out; exit 1; }}; \
         echo \"@@port $port\"; {point}",
        n = shq(nonce)
    );
    let r = exec.run(&command, 60_000).await?;
    if !r.stdout.contains("stub-ready") {
        return Err(format!(
            "exit {} {} {}",
            r.exit_code,
            tail(&r.stdout, 200),
            tail(&r.stderr, 200)
        ));
    }
    Ok(r.stdout
        .split("@@port ")
        .nth(1)
        .and_then(|s| s.split_whitespace().next())
        .unwrap_or("?")
        .to_owned())
}

/// Prints the run (its JSON with `--json`) and answers the exit code: 0 only when no step failed.
fn finish(j: &Journey, json_out: bool) -> i32 {
    j.flush();
    let failed = j.steps.iter().any(|s| s.status == Status::Fail);
    if json_out {
        let mut value = j.json();
        if let Some(fields) = value.as_object_mut() {
            fields.insert("ok".to_owned(), json!(!failed));
            fields.insert("ready_ms".to_owned(), json!(ready_ms(&j.steps)));
        }
        let _ = writeln!(std::io::stdout(), "{value}");
    } else {
        let name = j.backend.get("name").and_then(Value::as_str).unwrap_or("");
        let api = j.backend.get("api").and_then(Value::as_str).unwrap_or("");
        let head = summary_markdown(name, api, &j.meta, &j.steps);
        println!("{}", head.lines().next().unwrap_or(""));
    }
    i32::from(failed)
}

#[cfg(test)]
#[path = "cloud_journey_tests.rs"]
mod tests;
