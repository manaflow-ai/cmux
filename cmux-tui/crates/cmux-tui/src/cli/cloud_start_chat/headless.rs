//! A Cloud chat from the CLI with no cmux app: the same steps (`cloud start-chat`, `cmux chat send|read|wait
//! --on vm:`), answered from the cmux API directly with this machine's own login instead of the app.
//!
//! [`HeadlessRunner`] is a second [`Runner`]: each step's app verb (`cloud list-machines`, `cloud start-session`,
//! `cloud exec`, `cloud pause-machine`, `cloud resume-machine`, `cloud kill-machine`) is answered in-process
//! ([`answer`]) in the app's own JSON shape, so every step, check and answer above it is the app path's. It is
//! picked only when no app answers on its socket and a login is there ([`runner_for`]); with an app the steps run
//! as before. `cmux cloud list-machines|pause-machine|resume-machine` with no app are answered the same way
//! ([`run_if_requested`]).
//!
//! The login: `--cloud-token-file PATH` (start-chat and those three verbs), else `CMUX_CLOUD_ACCESS_TOKEN`
//! (crate::cli::joined_machine_credential). The cmux API: `--cloud-api URL`, else `CMUX_CLOUD_API_URL`, else
//! production; `--team` or `CMUX_CLOUD_TEAM` for a team. The login travels only in a request header
//! (`cmux_cloud_client::http`, cloud_client_session.rs), never in an argument list, a URL, an error or a log
//! line, and every exec's output is scrubbed of it.
//!
//! Machines are made, read, paused, resumed and deleted with `cmux_cloud_client::ops`
//! (`cloud.machine.list|create|get|pause|start|delete`), and a command on one runs through the client session or
//! machine exec route `cmux machine access exec` uses. The chat's agent starts on the machine's acpmux with
//! `session/new` (cloud_journey.rs `session_start_program`), on the machine's own model connection.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, Ran, Runner, SelfRunner};

/// The cmux API's origin when none is named (the app's own default backend).
const DEFAULT_API: &str = cmux_cloud_environment::PRODUCTION_API;
const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";
/// The shipped app's chat start size (cloud_journey.rs `CHAT_START_SIZE`).
const CHAT_START_SIZE: (i64, i64, i64) = (4, 16_384, 65_536);
/// How long a start waits for its machine to run (the app's connect budget and more).
const RUNNING_BUDGET: Duration = Duration::from_secs(300);
const RUNNING_POLL: Duration = Duration::from_secs(2);
/// One exec's own limit unless the step names one: the app's `cloud exec` stops after 25 s too.
const EXEC_TIMEOUT_MS: u64 = 30_000;
/// The agent start's exec limit: `session/new` waits for the harness to come up.
const START_TIMEOUT_MS: u64 = 120_000;
/// The verbs answered with no app; any other step answers [`UNSUPPORTED`].
pub(super) const VERBS: &[&str] =
    &["list-machines", "start-session", "exec", "pause-machine", "resume-machine", "kill-machine"];
const UNSUPPORTED: &str = "cloud.headless_unsupported";

/// One Cloud machine as the steps read it (the app's `cloud list-machines` row).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Row {
    pub id: String,
    pub name: Option<String>,
    /// `cloud.machine` status, as the wire spells it (`running`, `paused`, `failed`…).
    pub status: String,
    /// The machine has a host: a running one with a host takes commands.
    pub host: bool,
    pub created_at: i64,
    pub keep: Option<bool>,
}

impl Row {
    fn json(&self) -> Value {
        let mut row = json!({
            "machine_id": self.id,
            "title": self.name,
            "name": self.name,
            "status": self.status,
            "created_at": self.created_at,
        });
        if let (Some(keep), Some(object)) = (self.keep, row.as_object_mut()) {
            object.insert("keep".to_owned(), json!(keep));
        }
        row
    }
}

/// What one command printed on a machine.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Executed {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// The cmux API calls the answers need; an error is the API's refusal as `{code, message, retryable}`.
pub(super) trait Api {
    fn list(&mut self) -> Result<Vec<Row>, Value>;
    fn create(&mut self, name: &str) -> Result<Row, Value>;
    fn get(&mut self, id: &str) -> Result<Row, Value>;
    fn pause(&mut self, id: &str) -> Result<Row, Value>;
    fn resume(&mut self, id: &str) -> Result<Row, Value>;
    fn delete(&mut self, id: &str) -> Result<(), Value>;
    fn exec(&mut self, id: &str, command: &str, timeout_ms: u64) -> Result<Executed, Value>;
}

/// The login and backend flags a headless run takes (`--cloud-token-file`, `--cloud-api`, `--team`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Login {
    pub token_file: Option<PathBuf>,
    pub api: Option<String>,
    pub team: Option<String>,
}

/// `words` without the login flags, and the flags. A flag with no value is left for the command's own parse.
pub(super) fn take_login(words: &[String]) -> (Vec<String>, Login) {
    let mut login = Login::default();
    let mut rest = Vec::with_capacity(words.len());
    let mut iter = words.iter().peekable();
    while let Some(word) = iter.next() {
        if word == "--" {
            rest.push(word.clone());
            rest.extend(iter.by_ref().cloned());
            break;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let slot = match flag {
            "--cloud-token-file" => 0,
            "--cloud-api" => 1,
            "--team" => 2,
            _ => {
                rest.push(word.clone());
                continue;
            }
        };
        let Some(value) = inline.or_else(|| iter.next().cloned()) else {
            rest.push(word.clone());
            continue;
        };
        match slot {
            0 => login.token_file = Some(PathBuf::from(value)),
            1 => login.api = Some(value),
            _ => login.team = Some(value),
        }
    }
    (rest, login)
}

/// The runner a start or a send runs on: the app's ([`SelfRunner`]) whenever an app answers on its socket or no
/// login is there (unchanged), else [`HeadlessRunner`] on this machine's own login. Err: the login or the API
/// could not be read, as the error object to print.
pub(super) fn runner_for(global: &GlobalArgs, login: &Login) -> Result<Box<dyn Runner>, Value> {
    if super::super::app::connect_command(global).is_ok() {
        return Ok(Box::new(SelfRunner::new(global)));
    }
    let credential = match super::super::joined_machine_credential(login.token_file.clone(), false)
    {
        Ok(Some(credential)) => credential,
        Ok(None) => return Ok(Box::new(SelfRunner::new(global))),
        Err(message) => return Err(not_signed_in(&message)),
    };
    let api = CmuxApi::new(login, credential)?;
    Ok(Box::new(HeadlessRunner::new(Box::new(api), global.output)))
}

/// The refusal for a login that could not be read: what to do next, never the login or its path.
fn not_signed_in(reason: &str) -> Value {
    json!({
        "code": "cloud.signed_out",
        "message": format!(
            "not signed in: {reason}. Start the cmux app, or give this machine's cmux login with \
             CMUX_CLOUD_ACCESS_TOKEN or --cloud-token-file PATH, then run this command again"
        ),
        "details": {"sign_in": "cmux login"},
        "retryable": false,
    })
}

/// `Some(exit code)` for `cloud list-machines|pause-machine|resume-machine` when no app answers and a login is
/// there: the same answer the app prints. `None` leaves the command to the app path, as before.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::super::parse_globals(args).ok()?;
    let [cloud, verb, ..] = command_args.as_slice() else { return None };
    if cloud != "cloud"
        || !matches!(verb.as_str(), "list-machines" | "pause-machine" | "resume-machine")
    {
        return None;
    }
    if super::super::app::connect_command(&global).is_ok() {
        return None;
    }
    let (words, login) = take_login(&command_args);
    let credential =
        super::super::joined_machine_credential(login.token_file.clone(), false).ok().flatten()?;
    let mut api = match CmuxApi::new(&login, credential) {
        Ok(api) => api,
        Err(error) => return Some(super::super::wire::print_local_error(&error, global.output, 1)),
    };
    let ran = answer(&mut api, &words, &mut |duration| std::thread::sleep(duration));
    Some(print_ran(&ran, global.output))
}

fn print_ran(ran: &Ran, output: OutputMode) -> i32 {
    match super::step_result(ran) {
        Ok(value) => super::super::wire::print_local_success(&value, output),
        Err(error) => super::super::wire::print_local_error(&error, output, ran.code.max(1)),
    }
}

/// The steps' runner with no app: every step's app verb answered from `api` ([`answer`]).
pub(super) struct HeadlessRunner {
    api: Box<dyn Api>,
    output: OutputMode,
}

impl HeadlessRunner {
    pub(super) fn new(api: Box<dyn Api>, output: OutputMode) -> Self {
        Self { api, output }
    }
}

impl Runner for HeadlessRunner {
    fn cmux(&mut self, args: &[String]) -> Ran {
        answer(self.api.as_mut(), args, &mut |duration| std::thread::sleep(duration))
    }

    fn pause(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn now(&mut self) -> Instant {
        Instant::now()
    }

    fn fresh_name(&mut self) -> String {
        super::fresh_machine_name()
    }

    fn say(&mut self, line: &str) {
        match self.output {
            OutputMode::Human => eprintln!("{line}"),
            _ => eprintln!("{}", json!({"progress": line})),
        }
    }

    /// No folder is copied with no app (`--from-folder` answers [`UNSUPPORTED`]): nothing to estimate.
    fn estimate(&mut self, _folder: &str) -> Value {
        Value::Null
    }
}

/// The value after `flag` in `args`.
fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|word| word == name).and_then(|at| args.get(at + 1)).map(String::as_str)
}

fn done(value: Value) -> Ran {
    Ran { code: 0, stdout: json!({"result": value}).to_string(), stderr: String::new() }
}

fn refused(error: Value) -> Ran {
    Ran { code: 1, stdout: String::new(), stderr: error.to_string() }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({"code": code, "message": message.into(), "retryable": false})
}

/// One step's app verb (`cloud VERB …`), answered from `api` in the app's shape; `pause` waits between reads.
pub(super) fn answer(api: &mut dyn Api, args: &[String], pause: &mut dyn FnMut(Duration)) -> Ran {
    let verb = match args {
        [cloud, verb, ..] if cloud == "cloud" => verb.as_str(),
        _ => "",
    };
    let target = flag(args, "--target").map(|t| t.strip_prefix("machine:").unwrap_or(t).to_owned());
    let result = match (verb, target) {
        ("list-machines", _) => api.list().map(|rows| {
            json!({
                "account": {"signed_in": true, "via": "cmux-api"},
                "loaded": true,
                "machines": rows.iter().map(Row::json).collect::<Vec<_>>(),
                "creating": [],
            })
        }),
        ("start-session", target) => start_session(api, args, target, pause),
        ("exec", Some(id)) => match flag(args, "--command") {
            Some(command) => api.exec(&id, command, EXEC_TIMEOUT_MS).map(|ran| {
                json!({"machine_id": id, "exit_code": ran.exit_code, "stdout": ran.stdout,
                       "stderr": ran.stderr})
            }),
            None => Err(error("usage.invalid", "cloud exec needs --command")),
        },
        ("pause-machine", Some(id)) => api.pause(&id).map(|row| status(&row)),
        ("resume-machine", Some(id)) => api.resume(&id).map(|row| status(&row)),
        ("kill-machine", Some(id)) => {
            api.delete(&id).map(|()| json!({"machine_id": id, "deleted": true}))
        }
        (verb, None) if VERBS.contains(&verb) => {
            Err(error("usage.invalid", format!("cloud {verb} needs --target machine:ID")))
        }
        _ => Err(error(
            UNSUPPORTED,
            format!(
                "`cmux cloud {verb}` needs the cmux app; with no app this machine's login runs `cloud {}`. \
                 Start the cmux app for the rest",
                VERBS.join("`, `cloud ")
            ),
        )),
    };
    match result {
        Ok(value) => done(value),
        Err(error) => refused(error),
    }
}

fn status(row: &Row) -> Value {
    json!({"machine_id": row.id, "machine_name": row.name, "status": row.status})
}

/// `cloud start-session (--name N | --target machine:ID) --agent A [--model M] [--cwd D]`: the machine (made when
/// no machine has the name), running, and a new chat session on its acpmux; the app's answer's ids.
fn start_session(
    api: &mut dyn Api,
    args: &[String],
    target: Option<String>,
    pause: &mut dyn FnMut(Duration),
) -> Result<Value, Value> {
    if args.iter().any(|word| word == "--from-folder") {
        return Err(error(
            UNSUPPORTED,
            "--from-folder copies a folder through the cmux app: start the app, or start the chat with --cwd",
        ));
    }
    let agent = flag(args, "--agent").unwrap_or("claude");
    let mut row = match (target, flag(args, "--name")) {
        (Some(id), _) => api.get(&id)?,
        (None, Some(name)) => {
            let listed = api.list()?;
            match listed.into_iter().find(|row| row.name.as_deref() == Some(name)) {
                Some(row) => row,
                None => api.create(name)?,
            }
        }
        (None, None) => {
            return Err(error("usage.invalid", "cloud start-session needs --name or --target"));
        }
    };
    if row.status == "paused" {
        row = api.resume(&row.id)?;
    }
    let began = Instant::now();
    while !(row.status == "running" && row.host) {
        if row.status == "failed" {
            return Err(json!({"code": "cloud.machine.failed",
                              "message": format!("machine {} failed to start", row.id),
                              "details": {"machine_id": row.id}, "retryable": false}));
        }
        if began.elapsed() > RUNNING_BUDGET {
            return Ok(json!({"pending": true, "machine_id": row.id, "machine_name": row.name,
                             "status": row.status}));
        }
        pause(RUNNING_POLL);
        row = api.get(&row.id)?;
    }
    let id: String = uuid::Uuid::new_v4().simple().to_string().chars().take(12).collect();
    let name = format!("cloud-{id}");
    let program = format!(
        "{}{}",
        super::GUEST_PRELUDE,
        super::super::cloud_journey::session_start_program(
            &name,
            agent,
            flag(args, "--model"),
            flag(args, "--cwd"),
        )
    );
    let ran = api.exec(&row.id, &program, START_TIMEOUT_MS)?;
    let session = ran
        .stdout
        .lines()
        .find_map(|line| line.trim().strip_prefix("@@session "))
        .map(str::trim)
        .filter(|id| !id.is_empty() && *id != "None");
    let Some(session) = session else {
        let said = if ran.stdout.trim().is_empty() { &ran.stderr } else { &ran.stdout };
        let said: String =
            said.trim().chars().rev().take(400).collect::<Vec<_>>().into_iter().rev().collect();
        return Err(json!({"code": "unavailable",
                          "message": format!("machine {} is running but its agent did not start: {said}", row.id),
                          "details": {"machine_id": row.id}, "retryable": true}));
    };
    Ok(json!({
        "machine_id": row.id,
        "machine_name": row.name,
        "session_id": session,
        "workspace_id": Value::Null,
        "tab_id": Value::Null,
        "host": Value::Null,
        "via": "cmux-api",
    }))
}

/// The cmux API on this machine's own login (`cmux_cloud_client::ops` and the exec routes of
/// cloud_client_session.rs).
pub(super) struct CmuxApi {
    runtime: tokio::runtime::Runtime,
    base: String,
    http: reqwest::Client,
    exec_client: reqwest::Client,
    scope: cmux_cloud_client::machine::Scope,
    credential: String,
    /// A client session per machine, minted once and reused; `None`: the provider has none (the exec route).
    sessions: HashMap<String, Option<(cmux_cloud_api::session::Session, Instant)>>,
}

/// How long a minted client session is reused (cloud_journey.rs mints one for 900 s).
const SESSION_REUSE: Duration = Duration::from_secs(600);
const SESSION_TTL_S: u64 = 900;

impl CmuxApi {
    pub(super) fn new(login: &Login, credential: String) -> Result<Self, Value> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let env = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        let api =
            login.api.clone().or_else(|| env(API_ENV)).unwrap_or_else(|| DEFAULT_API.to_owned());
        let api = cmux_cloud_api::session::secure_origin(api.trim())
            .map_err(|message| error("usage.invalid", message))?;
        let team = login.team.clone().or_else(|| env(TEAM_ENV));
        let credential = credential.trim().to_owned();
        if credential.is_empty() {
            return Err(not_signed_in("the cmux login is empty"));
        }
        let fail = |message: String| error("internal", message);
        let ua = concat!("cmux/", env!("CARGO_PKG_VERSION"), " cloud-headless");
        let (base, http) = cmux_cloud_client::http(
            &api,
            Some(&credential),
            team.as_deref(),
            ua,
            Duration::from_secs(120),
        )
        .map_err(|e| fail(e.to_string()))?;
        let exec_client = reqwest::Client::builder()
            .default_headers(cmux_build_space::headers().map_err(|e| fail(e.to_string()))?)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(ua)
            .build()
            .map_err(|e| fail(e.to_string()))?;
        let scope = cmux_cloud_client::machine::Scope::new(&api, team.as_deref())
            .map_err(|e| fail(e.to_string()))?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| fail(e.to_string()))?;
        Ok(Self { runtime, base, http, exec_client, scope, credential, sessions: HashMap::new() })
    }

    /// One op, retried with the same idempotency key on a retryable refusal (a lost answer never acts twice).
    fn call<Op: cmux_cloud_wire::Op>(
        &self,
        params: Op::Params,
        mutation: bool,
    ) -> Result<Op::Result, Value> {
        let key = mutation.then(cmux_cloud_client::client_key);
        let mut attempt = 0;
        loop {
            let answer = self
                .runtime
                .block_on(cmux_cloud_client::ops::call::<Op>(
                    &self.http,
                    &self.base,
                    params.clone(),
                    key.as_deref(),
                    None,
                ))
                .and_then(cmux_cloud_client::ops::Answer::into_result);
            match answer {
                Ok(value) => return Ok(value),
                Err(refusal) if refusal.retryable && attempt < 2 => {
                    attempt += 1;
                    std::thread::sleep(
                        refusal
                            .retry_after
                            .unwrap_or(Duration::from_secs(3))
                            .min(Duration::from_secs(20)),
                    );
                }
                Err(refusal) => {
                    let code = refusal.code.unwrap_or_else(|| "cloud.api_failed".to_owned());
                    let message =
                        cmux_cloud_api::session::redact(&refusal.message, "", &self.credential);
                    let code = if code == "auth.unauthenticated" {
                        "cloud.signed_out".to_owned()
                    } else {
                        code
                    };
                    return Err(
                        json!({"code": code, "message": message, "retryable": refusal.retryable}),
                    );
                }
            }
        }
    }
}

fn row(machine: cmux_cloud_wire::CloudMachine) -> Row {
    Row {
        status: machine.status.as_str().to_owned(),
        host: machine.host.is_some(),
        id: machine.id,
        name: machine.name,
        created_at: machine.created_at,
        keep: machine.keep,
    }
}

impl Api for CmuxApi {
    fn list(&mut self) -> Result<Vec<Row>, Value> {
        let mut rows = Vec::new();
        let mut cursor = None;
        loop {
            let params = cmux_cloud_wire::CloudMachineListParams { cursor, limit: None };
            let page = self.call::<cmux_cloud_wire::CloudMachineListOp>(params, false)?;
            rows.extend(page.machines.into_iter().map(row));
            match page.next_cursor {
                Some(next) if !next.is_empty() => cursor = Some(next),
                _ => return Ok(rows),
            }
        }
    }

    fn create(&mut self, name: &str) -> Result<Row, Value> {
        let params = cmux_cloud_wire::CloudMachineCreateParams {
            name: Some(name.to_owned()),
            size: cmux_cloud_wire::CloudMachineSize {
                cpu: Some(CHAT_START_SIZE.0),
                memory_mb: Some(CHAT_START_SIZE.1),
                disk_mb: Some(CHAT_START_SIZE.2),
            },
            image: None,
            from_snapshot: None,
            origin: None,
            ttl_seconds: None,
        };
        self.call::<cmux_cloud_wire::CloudMachineCreateOp>(params, true)
            .map(|made| row(made.machine))
    }

    fn get(&mut self, id: &str) -> Result<Row, Value> {
        let params = cmux_cloud_wire::CloudMachineGetParams { machine: id.to_owned() };
        self.call::<cmux_cloud_wire::CloudMachineGetOp>(params, false).map(row)
    }

    fn pause(&mut self, id: &str) -> Result<Row, Value> {
        let params = cmux_cloud_wire::CloudMachinePauseParams { machine: id.to_owned() };
        self.call::<cmux_cloud_wire::CloudMachinePauseOp>(params, true)
            .map(|done| row(done.machine))
    }

    fn resume(&mut self, id: &str) -> Result<Row, Value> {
        let params = cmux_cloud_wire::CloudMachineStartParams { machine: id.to_owned() };
        self.call::<cmux_cloud_wire::CloudMachineStartOp>(params, true)
            .map(|done| row(done.machine))
    }

    fn delete(&mut self, id: &str) -> Result<(), Value> {
        let params = cmux_cloud_wire::CloudMachineDeleteParams { machine: id.to_owned() };
        match self.call::<cmux_cloud_wire::CloudMachineDeleteOp>(params, true) {
            Ok(_) => Ok(()),
            Err(refused)
                if refused.get("code").and_then(Value::as_str)
                    == Some("cloud.machine.not_found") =>
            {
                Ok(())
            }
            Err(refused) => Err(refused),
        }
    }

    fn exec(&mut self, id: &str, command: &str, timeout_ms: u64) -> Result<Executed, Value> {
        use cmux_cloud_api::session::{mint_session, redact};
        let machine = self.scope.machine(id).map_err(|e| error("usage.invalid", e.to_string()))?;
        let fresh = match self.sessions.get(id) {
            None => true,
            Some(None) => false,
            Some(Some((_, at))) => at.elapsed() > SESSION_REUSE,
        };
        if fresh {
            let minted = self.runtime.block_on(mint_session(
                &self.exec_client,
                &self.scope,
                &self.credential,
                &machine,
                Some(SESSION_TTL_S),
            ));
            match minted {
                Ok(session) => {
                    self.sessions.insert(id.to_owned(), Some((session, Instant::now())));
                }
                Err(refusal) if refusal.code == "cloud.provider.unsupported" => {
                    self.sessions.insert(id.to_owned(), None);
                }
                Err(refusal) => {
                    let message = redact(&refusal.message, "", &self.credential);
                    return Err(
                        json!({"code": refusal.code, "message": message, "retryable": false}),
                    );
                }
            }
        }
        let session = self.sessions.get(id).and_then(Option::as_ref).map(|(session, _)| session);
        let answer = match session {
            Some(session) => self.runtime.block_on(super::super::cloud_client_session::exec(
                &self.exec_client,
                session,
                command,
                timeout_ms,
            )),
            None => self.runtime.block_on(super::super::cloud_client_session::exec_route(
                &self.exec_client,
                &self.scope,
                &self.credential,
                &machine,
                command,
                timeout_ms,
            )),
        };
        let token = session.map(|s| s.token.clone()).unwrap_or_default();
        let answer = answer.map_err(|message| {
            error("cloud.exec_failed", redact(&message, &token, &self.credential))
        })?;
        Ok(Executed {
            exit_code: answer.exit_code,
            stdout: redact(&answer.stdout, &token, &self.credential),
            stderr: redact(&answer.stderr, &token, &self.credential),
        })
    }
}

#[cfg(test)]
#[path = "headless_tests.rs"]
mod tests;
