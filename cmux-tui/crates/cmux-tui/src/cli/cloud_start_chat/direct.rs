//! `cloud start-chat` with no cmux app: the headless route (Leo, 2026-11-25: "hurry up and fix your
//! own blockers to be using autocloud and having it go auto"). A lane VM, a CI job or any machine
//! with no signed-in app used to answer `cloud.signed_out` or `app.not_found`, because every step
//! of a start is an app control verb (`cloud list-machines`, `cloud start-session`, `cloud exec`).
//!
//! [`Route::choose`] takes this route exactly where `cloud machine-auth` takes its own direct one
//! (cloud_machine_auth.rs): `CMUX_CLOUD_ACCESS_TOKEN` is set and no `--app-socket` names an app.
//! Everything else, a person's start from the app's CLI included, stays on the app route.
//!
//! The run itself is unchanged ([`super::run`]); [`DirectRunner`] answers the three app verbs from
//! the cmux API instead, in the same shapes the app answers them:
//!
//! - `cloud list-machines --json`: `cloud.machine.list` (every page), as the app's list
//!   (`account.signed_in`, `loaded`, `machines[].{machine_id,title,status,host}`, `creating: []`);
//! - `cloud start-session (--name N | --target machine:ID) --agent A [--model M] [--cwd C]`: the
//!   machine of that name made (`cloud.machine.create`, one idempotency key for the call's
//!   retries) or started when paused (`cloud.machine.start`), waited on until it runs with a host,
//!   then the chat started on it (`acp new` as the machine's work user, or with the caller's
//!   `CLAUDE_CODE_OAUTH_TOKEN` as its launch credential, cloud_journey.rs) and answered as
//!   `{machine_id, machine_name, session_id, host}`;
//! - `cloud exec --target machine:ID --command CMD --json`: the machine's client session exec (or
//!   the cmux API's exec route on a provider with none), as `machine access exec` runs it.
//!
//! The machine's lifecycle takes the same route, so a lane VM pauses, resumes and deletes what it
//! started with no app ([`run_if_requested`]): `cloud pause-machine|resume-machine|kill-machine
//! --target machine:ID` (`vm:ID` too; kill needs `--yes`) answered from `cloud.machine.pause`,
//! `cloud.machine.start` and `cloud.machine.delete` as `{machine_id, machine_name, status}` (kill:
//! `{machine_id, deleted: true}`), and `cloud list-machines` as above. A message to a chat already
//! running on a machine (`cmux chat send|read|wait SESSION`) runs its exec here too.
//!
//! Auth: `CMUX_CLOUD_ACCESS_TOKEN` (a cmux session's access token: `cmux-autocloud login`'s, or the
//! agent test account's in CI) in the team `CMUX_CLOUD_TEAM` (absent: the session's personal team),
//! on `CMUX_CLOUD_API_URL`. The credential goes only in request headers and is redacted from every
//! answer; nothing is kept. Revoking the session ends the route.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GUEST_PRELUDE, GlobalArgs, Ran, Runner, link_wait};

/// Which route a start takes (the same rule as `cloud_machine_auth::Route::choose`).
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Route {
    App,
    Direct,
}

impl Route {
    pub(in crate::cli) fn choose(
        global: &GlobalArgs,
        env: impl Fn(&str) -> Option<String>,
    ) -> Self {
        match super::super::cloud_machine_auth::Route::choose(global, env) {
            super::super::cloud_machine_auth::Route::App => Self::App,
            super::super::cloud_machine_auth::Route::Direct { .. } => Self::Direct,
        }
    }
}

/// A machine as the platform lists it: what a start reads.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Row {
    pub id: String,
    pub name: Option<String>,
    pub status: String,
    pub host: Option<String>,
}

impl Row {
    fn listed(&self) -> Value {
        json!({
            "machine_id": self.id,
            "title": self.name,
            "status": self.status,
            "host": self.host,
        })
    }
}

/// The cmux API calls the headless route makes; [`Api`] is the real one, tests fake it.
pub(super) trait Cloud {
    fn list(&mut self) -> Result<Vec<Row>, Value>;
    fn get(&mut self, machine: &str) -> Result<Row, Value>;
    fn create(&mut self, name: &str, key: &str) -> Result<Row, Value>;
    fn start(&mut self, machine: &str, key: &str) -> Result<Row, Value>;
    fn pause(&mut self, machine: &str, key: &str) -> Result<Row, Value>;
    /// Deleted, or already gone.
    fn delete(&mut self, machine: &str, key: &str) -> Result<(), Value>;
    /// `{stdout, stderr, exit_code}`, the credential redacted.
    fn exec(&mut self, machine: &str, command: &str, timeout_ms: u64) -> Result<Value, Value>;
    fn team(&self) -> Option<String>;
    /// How the last [`Cloud::create`] got its machine ([`spare_origin`]), when the platform said.
    fn last_create(&self) -> Option<Value> {
        None
    }
    fn new_key(&mut self) -> String {
        cmux_cloud_client::client_key()
    }
    /// The caller's model connection for `agent`, given to the chat at its start (never written to
    /// the machine): the environment variable's name and value.
    fn launch_credential(&self, agent: &str) -> Option<(String, String)> {
        let _ = agent;
        None
    }
}

/// How long a start waits for its machine to run with a host.
const RUNNING_BUDGET: Duration = Duration::from_secs(300);
const RUNNING_POLL: Duration = Duration::from_secs(2);
/// `cloud exec`'s own bound on the machine when the step names none.
const EXEC_TIMEOUT_MS: u64 = 120_000;

/// [`Runner`] whose app verbs are answered by `cloud`, and the rest by `inner`.
pub(super) struct DirectRunner<'a> {
    pub inner: &'a mut dyn Runner,
    pub cloud: &'a mut dyn Cloud,
}

fn answered(result: Value) -> Ran {
    Ran {
        code: 0,
        stdout: json!({"ok": true, "result": result}).to_string(),
        stderr: String::new(),
    }
}

fn refused(error: Value) -> Ran {
    Ran { code: 1, stdout: String::new(), stderr: error.to_string() }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({"code": code, "message": message.into(), "retryable": false})
}

/// The machine `--target machine:ID` (or `vm:ID`, or a bare ID) names.
fn target<'w>(args: &'w [String], verb: &str) -> Result<&'w str, Value> {
    let Some(target) = flag(args, "--target") else {
        return Err(error("usage.invalid", format!("cloud {verb} needs --target machine:ID")));
    };
    let id =
        target.strip_prefix("machine:").or_else(|| target.strip_prefix("vm:")).unwrap_or(target);
    if id.is_empty() || id.contains(':') {
        return Err(error("usage.invalid", format!("cloud {verb} takes --target machine:ID")));
    }
    Ok(id)
}

fn lifecycle(row: &Row) -> Value {
    json!({
        "machine_id": row.id,
        "machine_name": row.name,
        "status": row.status,
        "route": "direct",
    })
}

fn flag<'w>(args: &'w [String], name: &str) -> Option<&'w str> {
    args.iter().position(|word| word == name).and_then(|at| args.get(at + 1)).map(String::as_str)
}

impl DirectRunner<'_> {
    fn list_machines(&mut self) -> Ran {
        match self.cloud.list() {
            Ok(rows) => answered(json!({
                "account": {"signed_in": true, "team": self.cloud.team(), "route": "direct"},
                "loaded": true,
                "machines": rows.iter().map(Row::listed).collect::<Vec<_>>(),
                "creating": [],
            })),
            Err(error) => refused(error),
        }
    }

    fn cloud_exec(&mut self, args: &[String]) -> Ran {
        let (Some(target), Some(command)) = (flag(args, "--target"), flag(args, "--command"))
        else {
            return refused(error("usage.invalid", "cloud exec needs --target and --command"));
        };
        let Some(machine) = target.strip_prefix("machine:").or_else(|| target.strip_prefix("vm:"))
        else {
            return refused(error(
                "usage.invalid",
                "cloud exec takes --target machine:ID or vm:ID",
            ));
        };
        match self.cloud.exec(machine, command, EXEC_TIMEOUT_MS) {
            Ok(answer) => answered(answer),
            Err(error) => refused(error),
        }
    }

    fn pause_machine(&mut self, args: &[String]) -> Ran {
        let id = match target(args, "pause-machine") {
            Ok(id) => id,
            Err(error) => return refused(error),
        };
        let key = self.cloud.new_key();
        match self.cloud.pause(id, &key) {
            Ok(row) => answered(lifecycle(&row)),
            // Already paused (or pausing): answer what it is now.
            Err(e) if at(&e, "code") == "cloud.machine.not_running" => match self.cloud.get(id) {
                Ok(row) => answered(lifecycle(&row)),
                Err(error) => refused(error),
            },
            Err(error) => refused(error),
        }
    }

    fn resume_machine(&mut self, args: &[String]) -> Ran {
        let id = match target(args, "resume-machine") {
            Ok(id) => id,
            Err(error) => return refused(error),
        };
        let key = self.cloud.new_key();
        match self.cloud.start(id, &key) {
            Ok(row) => answered(lifecycle(&row)),
            // Already running (or starting): answer what it is now.
            Err(e) if at(&e, "code") == "cloud.machine.not_paused" => match self.cloud.get(id) {
                Ok(row) => answered(lifecycle(&row)),
                Err(error) => refused(error),
            },
            Err(error) => refused(error),
        }
    }

    fn kill_machine(&mut self, args: &[String]) -> Ran {
        let id = match target(args, "kill-machine") {
            Ok(id) => id,
            Err(error) => return refused(error),
        };
        if !args.iter().any(|word| matches!(word.as_str(), "--yes" | "-y" | "--confirm")) {
            return refused(error(
                "usage.invalid",
                format!("cloud kill-machine deletes vm:{id} and its disk: add --yes"),
            ));
        }
        let key = self.cloud.new_key();
        match self.cloud.delete(id, &key) {
            Ok(()) => answered(json!({"machine_id": id, "deleted": true, "route": "direct"})),
            Err(error) => refused(error),
        }
    }

    /// The machine `--name` or `--target` names, made or started, once it runs with a host.
    /// Also how the machine came: `{"from": "existing"}`, or a create's [`spare_origin`].
    fn machine(&mut self, args: &[String]) -> Result<(Row, Value), Value> {
        let existing = json!({"from": "existing"});
        let (row, origin) = if let Some(target) = flag(args, "--target") {
            let id = target
                .strip_prefix("machine:")
                .or_else(|| target.strip_prefix("vm:"))
                .unwrap_or(target);
            (self.cloud.get(id)?, existing)
        } else if let Some(name) = flag(args, "--name") {
            let found =
                self.cloud.list()?.into_iter().find(|row| row.name.as_deref() == Some(name));
            match found {
                Some(row) => (row, existing),
                None => {
                    let key = self.cloud.new_key();
                    let row = self.cloud.create(name, &key)?;
                    let origin =
                        self.cloud.last_create().unwrap_or_else(|| json!({"from": "unknown"}));
                    (row, origin)
                }
            }
        } else {
            return Err(error("usage.invalid", "cloud start-session needs --name or --target"));
        };
        Ok((self.running(row)?, origin))
    }

    fn running(&mut self, mut row: Row) -> Result<Row, Value> {
        let began = self.inner.now();
        let start_key = self.cloud.new_key();
        loop {
            match row.status.as_str() {
                "running" if row.host.is_some() => return Ok(row),
                "failed" | "deleting" => {
                    return Err(json!({
                        "code": "cloud.start_failed",
                        "message": format!("machine {} is {}", row.id, row.status),
                        "retryable": false,
                        "details": {"machine_id": row.id},
                    }));
                }
                "paused" => match self.cloud.start(&row.id, &start_key) {
                    Ok(started) => row = started,
                    // Started by someone else between the read and the start: read it again.
                    Err(e) if at(&e, "code") == "cloud.machine.not_paused" => {}
                    Err(e) => return Err(e),
                },
                _ => {}
            }
            if self.inner.now().saturating_duration_since(began) > RUNNING_BUDGET {
                return Err(json!({
                    "code": "cloud.start_pending",
                    "message": format!(
                        "machine {} is not running within {} s (last {}): run the same command again",
                        row.id,
                        RUNNING_BUDGET.as_secs(),
                        row.status
                    ),
                    "retryable": true,
                    "details": {"machine_id": row.id},
                }));
            }
            self.inner.pause(RUNNING_POLL);
            row = self.cloud.get(&row.id)?;
        }
    }

    fn start_session(&mut self, args: &[String]) -> Ran {
        if flag(args, "--from-folder").is_some() {
            return refused(error(
                "cloud.direct_unsupported",
                "--from-folder copies a folder of this computer through the cmux app; with \
                 CMUX_CLOUD_ACCESS_TOKEN (no app) use --cwd on the machine",
            ));
        }
        let agent = flag(args, "--agent").unwrap_or("claude");
        let (row, origin) = match self.machine(args) {
            Ok(made) => made,
            Err(error) => return refused(error),
        };
        let session = format!("chat-{}", &self.cloud.new_key().replace('-', "")[..12]);
        let program = start_program(
            &session,
            agent,
            flag(args, "--model"),
            flag(args, "--cwd"),
            self.cloud.launch_credential(agent),
        );
        let ran = match self.cloud.exec(&row.id, &program, EXEC_TIMEOUT_MS) {
            Ok(ran) => ran,
            Err(error) => return refused(error),
        };
        let stdout = at(&ran, "stdout");
        let Some(id) = stdout.lines().find_map(|line| line.strip_prefix("@@session ")) else {
            let stderr = at(&ran, "stderr");
            let said = if stdout.trim().is_empty() { stderr } else { stdout };
            let tail: String =
                said.chars().rev().take(600).collect::<Vec<_>>().into_iter().rev().collect();
            return refused(json!({
                "code": "cloud.agent_start_failed",
                "message": format!("the {agent} chat did not start on machine {}: {}", row.id, tail.trim()),
                "retryable": false,
                "details": {"machine_id": row.id},
            }));
        };
        let id = id.trim();
        let id = if id.is_empty() || id == "None" { session.as_str() } else { id };
        answered(json!({
            "machine_id": row.id,
            "machine_name": row.name,
            "session_id": id,
            "host": row.host,
            "workspace_id": Value::Null,
            "tab_id": Value::Null,
            "route": "direct",
            "machine_origin": origin,
        }))
    }
}

fn at<'v>(value: &'v Value, key: &str) -> &'v str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// The guest program that starts the chat `session` and prints `@@session ID`.
pub(super) fn start_program(
    session: &str,
    agent: &str,
    model: Option<&str>,
    cwd: Option<&str>,
    credential: Option<(String, String)>,
) -> String {
    if let Some((name, value)) = credential {
        return format!(
            "{GUEST_PRELUDE}{}",
            super::super::cloud_journey::launch_credential_program_in(
                session, agent, &name, &value, cwd
            )
        );
    }
    let harness = match model {
        Some(model) => format!("{agent}/{model}"),
        None => agent.to_owned(),
    };
    let q = super::shell_quote;
    let cwd = cwd.map(|cwd| format!(" --cwd {}", q(cwd))).unwrap_or_default();
    format!(
        "{GUEST_PRELUDE}cd \"$HOME\" 2>/dev/null || cd /; out=$(\"$c\" acp new --machine local --name {} -m {}{cwd} --detach </dev/null 2>&1); \
         s=$?; if [ $s -eq 0 ]; then echo \"@@session {}\"; else printf '%s\\n' \"$out\"; echo \"@@exit $s\"; fi",
        q(session),
        q(&harness),
        session,
    )
}

impl Runner for DirectRunner<'_> {
    fn cmux(&mut self, args: &[String]) -> Ran {
        match (args.first().map(String::as_str), args.get(1).map(String::as_str)) {
            (Some("cloud"), Some("list-machines")) => self.list_machines(),
            (Some("cloud"), Some("start-session")) => self.start_session(args),
            (Some("cloud"), Some("exec")) => self.cloud_exec(args),
            (Some("cloud"), Some("pause-machine")) => self.pause_machine(args),
            (Some("cloud"), Some("resume-machine")) => self.resume_machine(args),
            (Some("cloud"), Some("kill-machine")) => self.kill_machine(args),
            _ => self.inner.cmux(args),
        }
    }
    fn cmux_by(&mut self, args: &[String], until: Instant) -> Ran {
        match (args.first().map(String::as_str), args.get(1).map(String::as_str)) {
            (
                Some("cloud"),
                Some(
                    "list-machines" | "start-session" | "exec" | "pause-machine" | "resume-machine"
                    | "kill-machine",
                ),
            ) => self.cmux(args),
            _ => self.inner.cmux_by(args, until),
        }
    }
    fn pause(&mut self, duration: Duration) {
        self.inner.pause(duration);
    }
    fn now(&mut self) -> Instant {
        self.inner.now()
    }
    fn fresh_name(&mut self) -> String {
        self.inner.fresh_name()
    }
    fn say(&mut self, line: &str) {
        self.inner.say(line);
    }
    fn stage(&mut self, name: &str) {
        self.inner.stage(name);
    }
    /// No app answers on this route.
    fn app(&mut self, _: &str, _: Value, _: Duration) -> Option<Result<Value, Value>> {
        None
    }
    fn until(&mut self) -> Option<Instant> {
        self.inner.until()
    }
    fn observe(
        &mut self,
        _socket: &str,
        _surface: u64,
        _after: u64,
        _wait: Duration,
    ) -> Result<Value, link_wait::Failure> {
        Err(link_wait::Failure::Link("no app link on the direct route".into()))
    }
    fn send_link(
        &mut self,
        _socket: &str,
        _surface: u64,
        _prompt_id: &str,
        _text: &str,
        _wait: Duration,
    ) -> Result<Value, link_wait::SendFailure> {
        Err(link_wait::SendFailure::NotSent("no app link on the direct route".into()))
    }
    fn estimate(&mut self, folder: &str) -> Value {
        self.inner.estimate(folder)
    }
}

/// The real cmux API: wire ops for the machines, the client session (or exec route) for exec.
pub(super) struct Api {
    runtime: tokio::runtime::Runtime,
    http: reqwest::Client,
    base: String,
    exec_client: reqwest::Client,
    scope: cmux_cloud_client::machine::Scope,
    credential: String,
    team: Option<String>,
    sessions: HashMap<String, (cmux_cloud_api::session::Session, Instant)>,
    /// Machines on a provider with no client sessions: the exec route.
    route_only: Vec<String>,
    /// The last create's [`spare_origin`].
    last_create: Option<Value>,
}

/// A client session is minted for this long and reused for most of it.
const SESSION_TTL_S: u64 = 900;
const SESSION_REUSE: Duration = Duration::from_secs(600);

fn api_error(error: cmux_cloud_client::ApiError) -> Value {
    json!({
        "code": error.code.unwrap_or_else(|| "cloud.unreachable".to_owned()),
        "message": format!("cmux: {}", error.message),
        "retryable": error.retryable,
    })
}

/// How a create's answer says its machine came (the platform's `spare_path` and `claim`, CloudCore withSpareAnswer):
/// `from` is `spare` (a warm spare: `path` running or resumed), `fresh` (made new: `fallback` says why no spare), or
/// `unknown` (the answer names no claim: a replayed create, or a caller the platform hands no spare).
pub(super) fn spare_origin(answer: &Value) -> Value {
    let claim = answer.get("claim");
    let path = claim
        .and_then(|c| c.get("path"))
        .or_else(|| answer.get("spare_path"))
        .and_then(Value::as_str);
    let from = match path {
        Some("running" | "resumed") => "spare",
        Some("created") => "fresh",
        _ => "unknown",
    };
    let fallback = claim
        .and_then(|c| c.get("fallback"))
        .filter(|v| !v.is_null())
        .or_else(|| answer.get("spare_fallback").filter(|v| !v.is_null()));
    let mut origin = json!({"from": from});
    if let Some(path) = path {
        origin["path"] = json!(path);
    }
    if let Some(fallback) = fallback {
        origin["fallback"] = fallback.clone();
    }
    if let Some(ms) = claim.and_then(|c| c.get("ms")).filter(|v| v.is_number()) {
        origin["claim_ms"] = ms.clone();
    }
    origin
}

/// cloud.machine.create read whole: the generated result keeps only `machine`, and the claim fields
/// ([`spare_origin`]) ride beside it.
struct CreateWhole;

impl cmux_cloud_wire::Op for CreateWhole {
    const NAME: &'static str = <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::NAME;
    const CLASS: cmux_cloud_wire::WireClass =
        <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::CLASS;
    const IDEMPOTENCY: cmux_cloud_wire::WireIdempotency =
        <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::IDEMPOTENCY;
    const OWNER: &'static str =
        <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::OWNER;
    const RISK: &'static str = <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::RISK;
    const PRINCIPALS: &'static [cmux_cloud_wire::WirePrincipal] =
        <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::PRINCIPALS;
    type Params = cmux_cloud_wire::CloudMachineCreateParams;
    type Result = Value;
    type Error = <cmux_cloud_wire::CloudMachineCreateOp as cmux_cloud_wire::Op>::Error;
}

fn row_of(machine: cmux_cloud_wire::CloudMachine) -> Row {
    Row {
        id: machine.id,
        name: machine.name,
        status: machine.status.as_str().to_owned(),
        host: machine.host,
    }
}

impl Api {
    /// From `CMUX_CLOUD_API_URL`, `CMUX_CLOUD_ACCESS_TOKEN` and `CMUX_CLOUD_TEAM` (`env`).
    pub(super) fn from_env(env: impl Fn(&str) -> Option<String>) -> Result<Self, Value> {
        let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
        let usage = |message: String| error("usage.invalid", message);
        let api = set("CMUX_CLOUD_API_URL").ok_or_else(|| {
            usage(
                "CMUX_CLOUD_ACCESS_TOKEN is set: name its cmux API with CMUX_CLOUD_API_URL".into(),
            )
        })?;
        let api = cmux_cloud_api::session::secure_origin(&api).map_err(usage)?;
        let credential = set("CMUX_CLOUD_ACCESS_TOKEN")
            .ok_or_else(|| usage("no CMUX_CLOUD_ACCESS_TOKEN".into()))?;
        let team = set("CMUX_CLOUD_TEAM");
        let _ = rustls::crypto::ring::default_provider().install_default();
        let ua = concat!("cmux/", env!("CARGO_PKG_VERSION"), " start-chat-direct");
        let (base, http) = cmux_cloud_client::http(
            &api,
            Some(&credential),
            team.as_deref(),
            ua,
            Duration::from_secs(60),
        )
        .map_err(|e| usage(e.to_string()))?;
        let exec_client = cmux_egress::client_builder("cmux_tui::cli::cloud_start_chat::direct")
            .default_headers(cmux_build_space::headers().map_err(|e| usage(e.to_string()))?)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(ua)
            .build()
            .map_err(|e| usage(e.to_string()))?;
        let scope = cmux_cloud_client::machine::Scope::new(&api, team.as_deref())
            .map_err(|e| usage(e.to_string()))?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| error("cloud.unreachable", e.to_string()))?;
        Ok(Self {
            runtime,
            http,
            base,
            exec_client,
            scope,
            credential,
            team,
            sessions: HashMap::new(),
            route_only: Vec::new(),
            last_create: None,
        })
    }

    fn call<O: cmux_cloud_wire::Op>(
        &self,
        params: O::Params,
        key: Option<&str>,
    ) -> Result<O::Result, Value> {
        // A same-key retry of an answer lost on the way never makes a second machine.
        for attempt in 0..3 {
            let answer = self.runtime.block_on(cmux_cloud_client::ops::call::<O>(
                &self.http,
                &self.base,
                params.clone(),
                key,
                None,
            ));
            match answer.and_then(cmux_cloud_client::ops::Answer::into_result) {
                Ok(value) => return Ok(value),
                Err(e) if e.retryable && attempt < 2 => {
                    let wait = e.retry_after.unwrap_or(Duration::from_secs(3));
                    std::thread::sleep(wait.min(Duration::from_secs(20)));
                }
                Err(e) => return Err(api_error(e)),
            }
        }
        Err(error("cloud.unreachable", "cmux: the cmux API did not answer"))
    }
}

impl Cloud for Api {
    fn list(&mut self) -> Result<Vec<Row>, Value> {
        use cmux_cloud_wire::{CloudMachineListOp, CloudMachineListParams};
        let mut rows = Vec::new();
        let mut cursor = None;
        for _ in 0..20 {
            let page = self.call::<CloudMachineListOp>(
                CloudMachineListParams { cursor: cursor.take(), limit: Some(100) },
                None,
            )?;
            rows.extend(page.machines.into_iter().map(row_of));
            match page.next_cursor {
                Some(next) if !next.is_empty() => cursor = Some(next),
                _ => break,
            }
        }
        Ok(rows)
    }

    fn get(&mut self, machine: &str) -> Result<Row, Value> {
        use cmux_cloud_wire::{CloudMachineGetOp, CloudMachineGetParams};
        self.call::<CloudMachineGetOp>(CloudMachineGetParams { machine: machine.to_owned() }, None)
            .map(row_of)
    }

    fn create(&mut self, name: &str, key: &str) -> Result<Row, Value> {
        use cmux_cloud_wire::{CloudMachineCreateParams, CloudMachineSize};
        let (cpu, memory_mb, disk_mb) = super::super::cloud_journey::start_size_from_env();
        let params = CloudMachineCreateParams {
            name: Some(name.to_owned()),
            size: CloudMachineSize {
                cpu: Some(cpu),
                memory_mb: Some(memory_mb),
                disk_mb: Some(disk_mb),
            },
            image: None,
            from_snapshot: None,
            origin: None,
            ttl_seconds: None,
        };
        let whole = self.call::<CreateWhole>(params, Some(key))?;
        self.last_create = Some(spare_origin(&whole));
        let machine = whole.get("machine").cloned().unwrap_or(Value::Null);
        serde_json::from_value::<cmux_cloud_wire::CloudMachine>(machine).map(row_of).map_err(|e| {
            error("cloud.bad_answer", format!("cmux: the create's machine did not parse: {e}"))
        })
    }

    fn start(&mut self, machine: &str, key: &str) -> Result<Row, Value> {
        use cmux_cloud_wire::{CloudMachineStartOp, CloudMachineStartParams};
        self.call::<CloudMachineStartOp>(
            CloudMachineStartParams { machine: machine.to_owned() },
            Some(key),
        )
        .map(|started| row_of(started.machine))
    }

    fn pause(&mut self, machine: &str, key: &str) -> Result<Row, Value> {
        use cmux_cloud_wire::{CloudMachinePauseOp, CloudMachinePauseParams};
        self.call::<CloudMachinePauseOp>(
            CloudMachinePauseParams { machine: machine.to_owned() },
            Some(key),
        )
        .map(|paused| row_of(paused.machine))
    }

    fn delete(&mut self, machine: &str, key: &str) -> Result<(), Value> {
        use cmux_cloud_wire::{CloudMachineDeleteOp, CloudMachineDeleteParams};
        match self.call::<CloudMachineDeleteOp>(
            CloudMachineDeleteParams { machine: machine.to_owned() },
            Some(key),
        ) {
            Ok(_) => Ok(()),
            // A retry whose first delete landed, or a machine already gone: deleted either way.
            Err(e) if at(&e, "code") == "cloud.machine.not_found" => Ok(()),
            Err(e) => Err(e),
        }
    }

    fn exec(&mut self, machine: &str, command: &str, timeout_ms: u64) -> Result<Value, Value> {
        use cmux_cloud_api::session::{mint_session, redact};
        let handle =
            self.scope.machine(machine).map_err(|e| error("usage.invalid", e.to_string()))?;
        let fail = |message: String| error("cloud.exec_failed", format!("cmux: {message}"));
        let direct = self.route_only.iter().any(|id| id == machine);
        let stale = self.sessions.get(machine).is_none_or(|(_, at)| at.elapsed() > SESSION_REUSE);
        if !direct && stale {
            match self.runtime.block_on(mint_session(
                &self.exec_client,
                &self.scope,
                &self.credential,
                &handle,
                Some(SESSION_TTL_S),
            )) {
                Ok(session) => {
                    self.sessions.insert(machine.to_owned(), (session, Instant::now()));
                }
                Err(refusal) if refusal.code == "cloud.provider.unsupported" => {
                    self.route_only.push(machine.to_owned());
                }
                Err(refusal) => {
                    return Err(
                        json!({"code": refusal.code, "message": format!("cmux: {}", refusal.message), "retryable": false}),
                    );
                }
            }
        }
        let route_only = self.route_only.iter().any(|id| id == machine);
        let session = self.sessions.get(machine).map(|(s, _)| s).filter(|_| !route_only);
        let answer = match session {
            Some(session) => self.runtime.block_on(super::super::cloud_client_session::exec(
                &self.exec_client,
                session,
                command,
                timeout_ms,
            )),
            _ => self.runtime.block_on(super::super::cloud_client_session::exec_route(
                &self.exec_client,
                &self.scope,
                &self.credential,
                &handle,
                command,
                timeout_ms,
            )),
        }
        .map_err(fail)?;
        let token = session.map(|s| s.token.as_str()).unwrap_or("");
        Ok(json!({
            "machine_id": machine,
            "exit_code": answer.exit_code,
            "stdout": redact(&answer.stdout, token, &self.credential),
            "stderr": redact(&answer.stderr, token, &self.credential),
        }))
    }

    fn last_create(&self) -> Option<Value> {
        self.last_create.clone()
    }
    fn team(&self) -> Option<String> {
        self.team.clone()
    }

    fn launch_credential(&self, agent: &str) -> Option<(String, String)> {
        let name = match agent {
            "claude" => "CLAUDE_CODE_OAUTH_TOKEN",
            _ => return None,
        };
        std::env::var(name)
            .ok()
            .map(|v| v.trim().to_owned())
            .filter(|v| !v.is_empty())
            .map(|v| (name.to_owned(), v))
    }
}

/// `cloud list-machines|pause-machine|resume-machine|kill-machine` on the direct route
/// ([`Route::choose`]): answered by the cmux API and printed as the app prints them. `None` leaves
/// every other command, and every command on the app route, where it went before.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::super::parse_globals(args).ok()?;
    let [cloud, verb, ..] = command_args.as_slice() else { return None };
    if cloud != "cloud"
        || !matches!(
            verb.as_str(),
            "list-machines" | "pause-machine" | "resume-machine" | "kill-machine"
        )
    {
        return None;
    }
    if command_args.iter().any(|word| word == "--help" || word == "-h") {
        return None;
    }
    if Route::choose(&global, |key| std::env::var(key).ok()) != Route::Direct {
        return None;
    }
    let mut api = match Api::from_env(|key| std::env::var(key).ok()) {
        Ok(api) => api,
        Err(error) => return Some(super::super::wire::print_local_error(&error, global.output, 2)),
    };
    let mut inner = super::SelfRunner::new(&global);
    let ran = DirectRunner { inner: &mut inner, cloud: &mut api }.cmux(&command_args);
    Some(match super::step_result(&ran) {
        Ok(answer) => super::super::wire::print_local_success(&answer, global.output),
        Err(error) => super::super::wire::print_local_error(&error, global.output, 1),
    })
}

/// Runs `body` on the route [`Route::choose`] takes: the app's verbs, or the cmux API's.
pub(super) fn on_route(
    global: &GlobalArgs,
    runner: &mut dyn Runner,
    body: impl FnOnce(&mut dyn Runner) -> super::Outcome,
) -> super::Outcome {
    match Route::choose(global, |key| std::env::var(key).ok()) {
        Route::App => body(runner),
        Route::Direct => match Api::from_env(|key| std::env::var(key).ok()) {
            Ok(mut api) => body(&mut DirectRunner { inner: runner, cloud: &mut api }),
            Err(error) => super::Outcome::Failed { error, exit: 2 },
        },
    }
}
