//! `cmux carrier secrets --machine <vm_id> [--deadline-ms N]`: secrets and
//! harness logins sealed to a Cloud machine's daemon and sent over its
//! carrier session (design/cloud-carrier.md, item 5).
//!
//! The app (CloudSealedDelivery.swift) only forwards: it reads the values
//! from the Mac's Keychain and writes one JSON request on stdin, never in
//! argv or the environment:
//!
//! ```json
//! {"api": "https://…", "credential": "…", "team": "team_…"?,
//!  "op": "replace-machine-secrets", "values": [{"name": "NAME", "value": "…"}]}
//! {"api": "https://…", "credential": "…",
//!  "op": "install-harness-login", "harness": "claude", "login_base64": "…",
//!  "allow_team_guest": false}
//! ```
//!
//! This dials the carrier (one deadline), asks the daemon for `secrets-v1`,
//! seals each value with HPKE to the daemon key the session pinned (the
//! carrier answer's `daemon_key`) for this machine id, sends the request and
//! prints one JSON line on stdout:
//! `{"ok": true, "count": N}` | `{"ok": true, "installed": "claude"}` |
//! `{"ok": false, "error_code": C, "refusal"?: R, "retryable": B}`.
//! `error_code` is a dial step (`ticket`, `relay`, `parked_timeout`,
//! `handshake`), `bad_request`, `unsupported` (a daemon without
//! `secrets-v1`), `unpinned` (the platform named no daemon key), `refused` (the daemon's fixed `refusal` code, such as
//! `bad-name`, `replay` or `not-ready`) or `transport`. No value, credential
//! or daemon text other than those codes is ever printed. Exit 0 on `ok`.

use std::io::Read as _;
use std::io::Write as _;
use std::sync::Arc;

use base64::Engine as _;
use cmux_remote::client::WorkspaceClient;
use cmux_remote_protocol::{RemoteCapability, WorkspaceRequest, WorkspaceResponse};
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::contract::{self, DEFAULT_DEADLINE, Failure};
use super::{answer, client, noise_key};

/// The most stdin read: 256 values of at most 16 KiB, with room for JSON.
const MAX_REQUEST_BYTES: usize = 8 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SecretsArgs {
    pub machine: String,
    pub deadline: std::time::Duration,
}

/// `secrets --machine vm_… [--deadline-ms N]`, each once, nothing else.
pub(super) fn parse(args: &[String]) -> Option<SecretsArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "secrets" {
        return None;
    }
    let (mut machine, mut deadline) = (None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine" => &mut machine,
            "--deadline-ms" => &mut deadline,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    let machine = machine.filter(|m| contract::valid_machine(m))?;
    let deadline = match deadline {
        Some(text) => contract::parse_deadline(&text)?,
        None => DEFAULT_DEADLINE,
    };
    Some(SecretsArgs { machine, deadline })
}

/// A string moved, not copied, into a buffer that is wiped when dropped.
fn zeroizing<'de, D: serde::Deserializer<'de>>(input: D) -> Result<Zeroizing<String>, D::Error> {
    String::deserialize(input).map(Zeroizing::new)
}

#[derive(Deserialize)]
struct NamedValue {
    name: String,
    #[serde(deserialize_with = "zeroizing")]
    value: Zeroizing<String>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum Op {
    ReplaceMachineSecrets {
        values: Vec<NamedValue>,
    },
    InstallHarnessLogin {
        harness: String,
        #[serde(deserialize_with = "zeroizing")]
        login_base64: Zeroizing<String>,
        #[serde(default)]
        allow_team_guest: bool,
    },
}

#[derive(Deserialize)]
struct Request {
    api: String,
    #[serde(deserialize_with = "zeroizing")]
    credential: Zeroizing<String>,
    /// The machine's team (`team_…`), sent as `x-cmux-team`; none: the person's own.
    #[serde(default)]
    team: Option<String>,
    #[serde(flatten)]
    op: Op,
}

/// The one answer line.
fn failure(code: &str, refusal: Option<&str>, retryable: bool) -> Value {
    let mut line = serde_json::Map::new();
    line.insert("ok".into(), json!(false));
    line.insert("error_code".into(), json!(code));
    if let Some(refusal) = refusal {
        line.insert("refusal".into(), json!(refusal));
    }
    line.insert("retryable".into(), json!(retryable));
    Value::Object(line)
}

/// The daemon's refusal (`secret-refused`, message `"<code>: <name>"`) as its
/// fixed code alone; anything else is `transport`.
fn answer_for(result: Result<WorkspaceResponse, cmux_remote_protocol::RpcError>) -> Value {
    match result {
        Ok(WorkspaceResponse::MachineSecretsReplaced { count }) => {
            json!({ "ok": true, "count": count })
        }
        Ok(WorkspaceResponse::HarnessLoginInstalled { name }) => {
            json!({ "ok": true, "installed": name })
        }
        Ok(_) => failure("transport", None, false),
        Err(error) if error.code == "secret-refused" => {
            let code = error.message.split(':').next().unwrap_or_default();
            let fixed =
                code.len() <= 32 && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'-');
            failure("refused", fixed.then_some(code), error.retryable)
        }
        Err(error) if error.code == "unsupported" => failure("unsupported", None, false),
        Err(error) => failure("transport", None, error.retryable),
    }
}

/// Seal `op` to `daemon_key` for `machine`.
fn sealed(daemon_key: &[u8; 32], machine: &str, op: Op) -> Result<WorkspaceRequest, Value> {
    let sealing = |_| failure("bad_request", None, false);
    match op {
        Op::ReplaceMachineSecrets { values } => {
            let values: Vec<_> = values.into_iter().map(|v| (v.name, v.value)).collect();
            cmux_remote::secrets::request::replace_machine_secrets(daemon_key, machine, &values)
                .map_err(sealing)
        }
        Op::InstallHarnessLogin { harness, login_base64, allow_team_guest } => {
            let login = Zeroizing::new(
                base64::engine::general_purpose::STANDARD
                    .decode(login_base64.trim().as_bytes())
                    .map_err(|_| failure("bad_request", None, false))?,
            );
            cmux_remote::secrets::request::install_harness_login(
                daemon_key,
                machine,
                &harness,
                &login,
                allow_team_guest,
            )
            .map_err(sealing)
        }
    }
}

fn print(line: &Value) -> i32 {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
    if line["ok"] == json!(true) { 0 } else { 1 }
}

fn read_request() -> Result<Request, Value> {
    let mut bytes = Zeroizing::new(Vec::new());
    std::io::stdin()
        .lock()
        .take(MAX_REQUEST_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failure("bad_request", None, false))?;
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err(failure("bad_request", None, false));
    }
    serde_json::from_slice(&bytes).map_err(|_| failure("bad_request", None, false))
}

/// `cmux carrier secrets …`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    let Some(args) = parse(args) else {
        return print(&failure("bad_request", None, false));
    };
    let request = match read_request() {
        Ok(request) => request,
        Err(line) => return print(&line),
    };
    let dial_failed = |failure: &Failure| {
        print(&self::failure(failure.step.error_code(), None, failure.retryable))
    };
    let source = match crate::cli::secure_cloud_origin(request.api.trim())
        .map_err(|why| Failure::fatal(contract::Step::Ticket, why))
        .and_then(|api| {
            if request.team.as_deref().is_some_and(|team| !contract::valid_team(team)) {
                return Err(Failure::fatal(contract::Step::Ticket, "the team is not a team id"));
            }
            answer::HttpSource::new(
                api,
                answer::Credential::Value(request.credential.clone()),
                request.team.clone(),
            )
            .map_err(|why| Failure::fatal(contract::Step::Ticket, why))
        }) {
        Ok(source) => Arc::new(source),
        Err(failure) => return dial_failed(&failure),
    };
    let identity = match noise_key::device_identity() {
        Ok(identity) => identity,
        Err(why) => return dial_failed(&Failure::fatal(contract::Step::Handshake, why)),
    };
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().enable_all().build() else {
        return print(&failure("transport", None, true));
    };
    let machine = args.machine.clone();
    let line = runtime.block_on(async move {
        let plan = client::DialPlan {
            machine: machine.clone(),
            source,
            identity,
            deadline: tokio::time::Instant::now() + args.deadline,
            // Route lines carry the machine id, the step and the time: no value.
            log: Arc::new(|line| {
                let mut stderr = std::io::stderr().lock();
                let _ = stderr.write_all(line.as_bytes());
            }),
        };
        let dialed = match client::dial(&plan, |ceiling| {
            cmux_remote::connection::ReconnectPolicy::default().retry_delay(ceiling)
        })
        .await
        {
            Ok(dialed) => dialed,
            Err(failure) => {
                return self::failure(failure.step.error_code(), None, failure.retryable);
            }
        };
        let line = send(&dialed, &machine, request.op).await;
        dialed.multiplexer.shutdown().await;
        let _ = dialed.connection.close().await;
        line
    });
    runtime.shutdown_timeout(super::STDIO_SHUTDOWN_TIMEOUT);
    print(&line)
}

async fn send(dialed: &client::Dialed, machine: &str, op: Op) -> Value {
    let Ok(workspace) = WorkspaceClient::connect(dialed.multiplexer.clone()).await else {
        return failure("transport", None, true);
    };
    match workspace.request(WorkspaceRequest::Capabilities).await {
        Ok(WorkspaceResponse::Capabilities { capabilities })
            if capabilities.contains(&RemoteCapability::SecretsV1) => {}
        Ok(_) => return failure("unsupported", None, false),
        Err(error) => return failure("transport", None, error.retryable),
    }
    // The key this session's handshake proved, pinned to the carrier
    // answer's `daemon_key`: only that daemon can open what follows. A
    // session the platform named no key for is never sent a value.
    let Some(daemon_key) =
        pinned_key(dialed.pinned_daemon_key, dialed.connection.daemon_public_key())
    else {
        return failure("unpinned", None, false);
    };
    let request = match sealed(&daemon_key, machine, op) {
        Ok(request) => request,
        Err(line) => return line,
    };
    answer_for(workspace.request(request).await)
}

/// The key to seal to: the platform's, and only when the handshake proved it.
fn pinned_key(named: Option<[u8; 32]>, proved: [u8; 32]) -> Option<[u8; 32]> {
    named.filter(|named| *named == proved)
}

#[cfg(test)]
#[path = "secrets_tests.rs"]
mod tests;
