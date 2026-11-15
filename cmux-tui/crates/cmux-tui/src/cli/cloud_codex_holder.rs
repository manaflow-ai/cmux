//! `cmux cloud codex-holder`: the NEXT app's Codex access holder for its Cloud machines
//! (cmux-cloud-codex-holder, its protocol in that crate's `serve.rs`). The app starts it once
//! and talks JSON lines on its stdin and stdout; this file only wires the holder to the
//! machines' exec and file routes, the same direct-or-proxy path as `cmux cloud machine-io`
//! (`cmux_cloud_api::machine_io`),
//! with the app's Cloud credential asked per call.
//!
//! The holder's scope names the app's active team as the app keeps it: a Stack team id. The cmux
//! API Worker's `x-cmux-team` takes only its own `team_` ids (`team-select.ts`), so a route call
//! names the team as [`route_team`] maps it, by the rule every other Cloud call uses
//! (`cmux_cloud_config::identity::team_header`). The Stack id made every Codex delivery on a team
//! account fail with "x-cmux-team must name a team id": Codex on a production Cloud machine
//! started with no login, while Claude, whose transfer pins the install's team, had one (Leo's
//! NIGHTLY, 2026-11-15).

use std::io::Read as _;
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_cloud_api::machine_io::{
    Answer, Op, Request, RouteChoice, Spool, http_client, now_ms, perform, scrub,
};
use cmux_cloud_api::session::secure_origin;
use cmux_cloud_codex_holder::{App, Config, ExecResult, Machines, VmError};
use serde_json::Value;

/// `Some(exit code)` when `args` is `cloud codex-holder`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "codex-holder" {
        return None;
    }
    // A closed pipe is an error to handle, never a signal that ends the holder mid-erase.
    // SAFETY: SIG_IGN is a supported process-wide disposition for SIGPIPE.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().enable_all().build() else {
        return Some(1);
    };
    let served = runtime.block_on(cmux_cloud_codex_holder::serve(
        tokio::io::stdin(),
        tokio::io::stdout(),
        |config, app| Arc::new(MachineIo::new(config, app)) as Arc<dyn Machines>,
    ));
    runtime.shutdown_background();
    Some(if served.is_ok() { 0 } else { 1 })
}

/// A Cloud machine's routes through machine-io's own `perform`.
struct MachineIo {
    api: String,
    /// The Stack project the app signs in to (the config's `stack_project`), which maps a Stack
    /// team id to the Worker's ([`route_team`]).
    stack_project: Option<String>,
    cache_dir: Option<PathBuf>,
    app_version: Option<String>,
    app: Arc<App>,
    client: Option<reqwest::Client>,
}

/// The config line's `stack_project`, when it names one.
fn stack_project(config: &Config) -> Option<String> {
    let project = config.line.get("stack_project").and_then(Value::as_str)?.trim();
    (!project.is_empty()).then(|| project.to_owned())
}

/// The `x-cmux-team` a route call sends for the scope's `team` (module docs): a Worker `team_` id
/// as is, a Stack team id mapped with `stack_project`. With no project (an app from before it sent
/// one) the team goes as given.
fn route_team(stack_project: Option<&str>, team: Option<&str>) -> Option<String> {
    let team = team.map(str::trim).filter(|team| !team.is_empty())?;
    Some(match stack_project {
        Some(project) => cmux_cloud_config::identity::team_header(project, team),
        None => team.to_owned(),
    })
}

impl MachineIo {
    fn new(config: &Config, app: Arc<App>) -> Self {
        let text = |key: &str| config.line.get(key).and_then(Value::as_str).map(str::to_owned);
        Self {
            stack_project: stack_project(config),
            api: text("api").and_then(|api| secure_origin(api.trim()).ok()).unwrap_or_default(),
            cache_dir: text("cache_dir").map(PathBuf::from),
            app_version: text("app_version"),
            app,
            client: http_client().ok(),
        }
    }

    async fn call(
        &self,
        team: Option<&str>,
        machine: &str,
        op: Op,
        fill: impl FnOnce(&mut Request),
    ) -> Result<Answer, VmError> {
        let failure = |message: &str| VmError {
            status: 0,
            code: Some("transport".into()),
            message: message.into(),
        };
        let Some(client) = self.client.as_ref() else { return Err(failure("no HTTP client")) };
        if self.api.is_empty() {
            return Err(failure("no Cloud API origin"));
        }
        let Some(credential) = self.app.credential().await.filter(|c| !c.trim().is_empty()) else {
            return Err(VmError {
                status: 401,
                code: Some("not_signed_in".into()),
                message: "Sign in to cmux Cloud.".into(),
            });
        };
        let mut request = Request {
            api: self.api.clone(),
            credential: credential.trim().to_owned(),
            team: route_team(self.stack_project.as_deref(), team),
            machine: machine.to_owned(),
            op,
            path: None,
            data_base64: None,
            mode: None,
            command: None,
            timeout_ms: None,
            max_bytes: None,
            cache_dir: self.cache_dir.clone(),
            route: RouteChoice::Auto,
            app_version: self.app_version.clone(),
            local_only: false,
        };
        fill(&mut request);
        let (_route, answer) = perform(client, &request, now_ms).await;
        // As both machine-io entries do: a refusal never carries the credential onward.
        let answer = scrub(answer, &request.credential);
        if (200..300).contains(&answer.status) {
            return Ok(answer);
        }
        let code = answer.code.clone().or_else(|| {
            answer.body.pointer("/error/code").and_then(Value::as_str).map(str::to_owned)
        });
        let message = answer
            .body
            .pointer("/error/message")
            .and_then(Value::as_str)
            .map_or_else(|| format!("the machine route answered {}", answer.status), str::to_owned);
        Err(VmError { status: answer.status, code, message })
    }
}

fn undecodable(what: &str) -> VmError {
    VmError {
        status: 0,
        code: Some("decoding".into()),
        message: format!("the {what} answer could not be read"),
    }
}

/// A read answer's bytes: the verified file, a spooled JSON body, or the body's `dataBase64`.
fn read_bytes(answer: Answer) -> Result<Vec<u8>, VmError> {
    let body = match answer.file {
        Some(Spool::Bytes(mut file)) => {
            use std::io::Seek as _;
            let mut data = Vec::new();
            file.rewind()
                .and_then(|_| file.read_to_end(&mut data))
                .map_err(|_| undecodable("read"))?;
            return Ok(data);
        }
        Some(Spool::Json(mut file)) => {
            use std::io::Seek as _;
            let mut text = Vec::new();
            file.rewind()
                .and_then(|_| file.read_to_end(&mut text))
                .map_err(|_| undecodable("read"))?;
            serde_json::from_slice(&text).map_err(|_| undecodable("read"))?
        }
        None => answer.body,
    };
    let encoded = body
        .get("dataBase64")
        .or_else(|| body.get("data"))
        .and_then(Value::as_str)
        .ok_or_else(|| undecodable("read"))?;
    BASE64.decode(encoded).map_err(|_| undecodable("read"))
}

#[async_trait]
impl Machines for MachineIo {
    async fn exec(
        &self,
        team: Option<&str>,
        machine: &str,
        command: &str,
        timeout_ms: u64,
    ) -> Result<ExecResult, VmError> {
        let answer = self
            .call(team, machine, Op::Exec, |r| {
                r.command = Some(command.to_owned());
                r.timeout_ms = Some(timeout_ms);
            })
            .await?;
        let exit_code = answer.body.get("exitCode").and_then(Value::as_i64).unwrap_or(-1);
        let stdout =
            answer.body.get("stdout").and_then(Value::as_str).unwrap_or_default().to_owned();
        Ok(ExecResult { exit_code, stdout })
    }

    async fn read(
        &self,
        team: Option<&str>,
        machine: &str,
        path: &str,
    ) -> Result<Vec<u8>, VmError> {
        let answer = self.call(team, machine, Op::Read, |r| r.path = Some(path.to_owned())).await?;
        read_bytes(answer)
    }

    async fn write(
        &self,
        team: Option<&str>,
        machine: &str,
        path: &str,
        data: &[u8],
        mode: Option<u32>,
    ) -> Result<(), VmError> {
        self.call(team, machine, Op::Write, |r| {
            r.path = Some(path.to_owned());
            r.data_base64 = Some(BASE64.encode(data));
            r.mode = mode;
        })
        .await
        .map(drop)
    }

    async fn mkdir(&self, team: Option<&str>, machine: &str, path: &str) -> Result<(), VmError> {
        self.call(team, machine, Op::Mkdir, |r| r.path = Some(path.to_owned())).await.map(drop)
    }

    async fn remove(&self, team: Option<&str>, machine: &str, path: &str) -> Result<(), VmError> {
        self.call(team, machine, Op::Remove, |r| r.path = Some(path.to_owned())).await.map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn answer(body: Value, file: Option<Spool>) -> Answer {
        Answer { status: 200, body, code: None, file }
    }

    #[test]
    fn reads_every_answer_shape() {
        assert_eq!(
            read_bytes(answer(json!({"dataBase64": BASE64.encode("a")}), None)).unwrap(),
            b"a"
        );
        assert_eq!(read_bytes(answer(json!({"data": BASE64.encode("b")}), None)).unwrap(), b"b");
        let mut bytes = tempfile::tempfile().unwrap();
        std::io::Write::write_all(&mut bytes, b"spooled").unwrap();
        assert_eq!(
            read_bytes(answer(json!({"path": "/x"}), Some(Spool::Bytes(bytes)))).unwrap(),
            b"spooled"
        );
        let mut spooled = tempfile::tempfile().unwrap();
        std::io::Write::write_all(
            &mut spooled,
            json!({"dataBase64": BASE64.encode("j")}).to_string().as_bytes(),
        )
        .unwrap();
        assert_eq!(read_bytes(answer(Value::Null, Some(Spool::Json(spooled)))).unwrap(), b"j");
        assert!(read_bytes(answer(json!({}), None)).is_err());
    }

    /// cmux#37306 review: a refusal that echoes the credential never reaches the app's text.
    #[test]
    fn a_refusal_never_carries_the_credential() {
        let refused = Answer {
            status: 403,
            body: json!({"error": {"code": "denied", "message": "bad token secret-token-1"}}),
            code: None,
            file: None,
        };
        let text = scrub(refused, "secret-token-1").body.to_string();
        assert!(!text.contains("secret-token-1"), "{text}");
    }

    /// Leo's NIGHTLY, 2026-11-15: the scope's Stack team went out as `x-cmux-team`, the Worker
    /// refused it ("x-cmux-team must name a team id"), and Codex reached the machine with no login.
    #[test]
    fn a_route_names_the_workers_team_id() {
        let project = "project-1";
        let stack_team = "6f1c2a8e-9b1d-4c3e-8f00-0123456789ab";
        let config = Config {
            root: "/tmp/root".into(),
            user_home: "/tmp/home".into(),
            line: json!({"op": "config", "stack_project": project}),
        };
        let project = stack_project(&config);
        assert_eq!(project.as_deref(), Some("project-1"));
        let routed = route_team(project.as_deref(), Some(stack_team)).unwrap();
        assert!(cmux_cloud_config::identity::is_team(&routed), "{routed}");
        assert_eq!(routed, cmux_cloud_config::identity::backend_team_id("project-1", stack_team));
        // The personal team's Worker id goes as is; no team is the install's own.
        let personal = "team_0123456789abcdef0123";
        assert_eq!(route_team(project.as_deref(), Some(personal)).as_deref(), Some(personal));
        assert_eq!(route_team(project.as_deref(), None), None);
        assert_eq!(route_team(project.as_deref(), Some(" ")), None);
        // A config with no project (an older app) sends the team as it came.
        let older = Config { line: json!({"op": "config"}), ..config };
        assert_eq!(stack_project(&older), None);
        assert_eq!(route_team(None, Some(stack_team)).as_deref(), Some(stack_team));
    }

    #[test]
    fn only_the_codex_holder_command_runs_it() {
        assert_eq!(run_if_requested(&["cloud".into(), "machine-io".into()]), None);
        assert_eq!(run_if_requested(&["status".into()]), None);
    }
}
