//! `cmux carrier secrets --machine <vm_id> [--deadline-ms N]`: secrets
//! sealed to a Cloud machine's daemon and sent over its carrier session
//! (design/cloud-carrier.md, item 5).
//!
//! The app (CloudSealedDelivery.swift) only forwards: it reads the values
//! from the Mac's Keychain and writes one JSON request on stdin, never in
//! argv or the environment:
//!
//! ```json
//! {"api": "https://…", "credential": "…", "team"?: "team_…",
//!  "op": "replace-machine-secrets", "values": [{"name": "NAME", "value": "…"}]}
//! ```
//!
//! `team` names the machine's team, as `cmux carrier dial --team` does.
//!
//! Two more ops carry the person's own git login (`git-host-tokens-v1`;
//! Leo, 2026-11-25: "Convienient beats all. Just make good ui for it so
//! people flow."), each sealed on its own with purpose `git-host`:
//! - `{"op": "use-github-login"}`: this Mac's own `gh` login for github.com,
//!   read here from gh (`gh auth token`, with every GitHub token variable
//!   removed from its env so only gh's own keyring or hosts file answers),
//!   never passed in by the app; the answer names its `login`.
//!   No gh login here: `error_code` `no_gh_login`.
//! - `{"op": "replace-git-host-token", "host": H, "token"?: T}`: a token the
//!   app holds for host `H`; without `token`, the machine's token for `H` is
//!   removed (`forget`).
//!
//! This dials the carrier (one deadline), asks the daemon for `secrets-v1`,
//! seals each value with HPKE, with the time it was sealed, to the daemon key
//! the session's handshake was pinned to (the carrier answer's `daemon_key`)
//! for this machine id, sends the request and prints one JSON line on stdout:
//! `{"ok": true, "count": N}` |
//! `{"ok": true, "host": H, "present": B, "login"?: L}` (the git host ops below) |
//! `{"ok": false, "error_code": C, "refusal"?: R, "retryable": B}`.
//! `error_code` is a dial step (`ticket`, `relay`, `parked_timeout`,
//! `handshake`), `timeout` (the deadline passed after the dial), `bad_request`, `unsupported` (a daemon without
//! `secrets-v1`), `refused` (with `refusal`, one of the daemon's
//! `REFUSAL_CODES` such as `bad-name`, `replay`, `stale` or the retryable
//! `busy`; no `refusal` for any other message) or `transport`. No value, credential
//! or daemon text other than those codes is ever printed. Exit 0 on `ok`.

use std::io::Read as _;
use std::io::Write as _;
use std::sync::Arc;

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

fn zeroizing_opt<'de, D: serde::Deserializer<'de>>(
    input: D,
) -> Result<Option<Zeroizing<String>>, D::Error> {
    Option::<String>::deserialize(input).map(|value| value.map(Zeroizing::new))
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum Op {
    ReplaceMachineSecrets {
        values: Vec<NamedValue>,
    },
    ReplaceGitHostToken {
        host: String,
        #[serde(default, deserialize_with = "zeroizing_opt")]
        token: Option<Zeroizing<String>>,
    },
    UseGithubLogin {},
}

/// The host `use-github-login` writes.
const GITHUB_HOST: &str = "github.com";
/// How long `gh` may take to answer its token or its login.
const GH_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

/// One gh run for github.com with only gh's own login: every token variable
/// removed, no prompt. Its stdout's first line, when it exits 0 in time.
fn gh_line(args: &[&str]) -> Option<Zeroizing<String>> {
    let gh = std::env::var_os("CMUX_GH").filter(|v| !v.is_empty()).unwrap_or_else(|| "gh".into());
    let mut child = cmux_process::Command::new(gh)
        .args(args)
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .env_remove("GH_ENTERPRISE_TOKEN")
        .env_remove("GITHUB_ENTERPRISE_TOKEN")
        .env_remove("GH_HOST")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    // The Child is owned here: a drop past the wait ends gh with it.
    match child.wait_timeout(GH_WAIT) {
        Ok(Some(status)) if status.success() => {}
        _ => return None,
    }
    let mut out = Zeroizing::new(String::new());
    child.stdout.take()?.take(64 * 1024).read_to_string(&mut out).ok()?;
    let line = out.lines().next().unwrap_or_default().trim();
    (!line.is_empty()).then(|| Zeroizing::new(line.to_owned()))
}

/// This Mac's own gh login for github.com: its token and its login name.
fn own_github_login() -> Option<(Zeroizing<String>, Option<String>)> {
    let token = gh_line(&["auth", "token", "--hostname", GITHUB_HOST])?;
    if !cmux_remote::secrets::files::is_git_host_token(&token) {
        return None;
    }
    let login = gh_line(&["api", "user", "--hostname", GITHUB_HOST, "--jq", ".login"])
        .map(|login| login.to_string())
        .filter(|login| is_github_login(login));
    Some((token, login))
}

/// A GitHub login as GitHub allows it: 1 to 39 letters, digits and inner dashes.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn is_github_login(login: &str) -> bool {
    let bytes = login.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 39
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-')
        && bytes[0] != b'-'
        && bytes[bytes.len() - 1] != b'-'
}

#[derive(Deserialize)]
struct Request {
    api: String,
    #[serde(deserialize_with = "zeroizing")]
    credential: Zeroizing<String>,
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
        Ok(WorkspaceResponse::GitHostTokenReplaced { host, present }) => {
            json!({ "ok": true, "host": host, "present": present })
        }
        Ok(_) => failure("transport", None, false),
        Err(error) if error.code == "secret-refused" => {
            // Only a code the daemon's protocol lists; any other text stays out.
            let code = error.message.split(':').next().unwrap_or_default();
            let known = cmux_remote::secrets::REFUSAL_CODES.contains(&code);
            failure("refused", known.then_some(code), error.retryable)
        }
        Err(error) if error.code == "unsupported" => failure("unsupported", None, false),
        Err(error) => failure("transport", None, error.retryable),
    }
}

/// An op ready to seal: what the person's Mac read for `use-github-login`
/// is resolved before the dial, so a Mac with no gh login dials nothing.
enum Ready {
    MachineSecrets(Vec<NamedValue>),
    GitHost { host: String, token: Option<Zeroizing<String>>, login: Option<String> },
}

impl Ready {
    fn capability(&self) -> RemoteCapability {
        match self {
            Self::MachineSecrets(_) => RemoteCapability::SecretsV1,
            Self::GitHost { .. } => RemoteCapability::GitHostTokensV1,
        }
    }

    fn login(&self) -> Option<&str> {
        match self {
            Self::GitHost { login, .. } => login.as_deref(),
            Self::MachineSecrets(_) => None,
        }
    }
}

/// `op` with what it needs from this Mac, or the failure line.
fn ready(
    op: Op,
    own_login: impl FnOnce() -> Option<(Zeroizing<String>, Option<String>)>,
) -> Result<Ready, Value> {
    match op {
        Op::ReplaceMachineSecrets { values } => Ok(Ready::MachineSecrets(values)),
        Op::ReplaceGitHostToken { host, token } => {
            let token_ok = token
                .as_ref()
                .is_none_or(|token| cmux_remote::secrets::files::is_git_host_token(token));
            if !cmux_remote::secrets::files::is_git_host(&host) || !token_ok {
                return Err(failure("bad_request", None, false));
            }
            Ok(Ready::GitHost { host, token, login: None })
        }
        Op::UseGithubLogin {} => {
            let (token, login) = own_login().ok_or_else(|| failure("no_gh_login", None, false))?;
            Ok(Ready::GitHost { host: GITHUB_HOST.to_owned(), token: Some(token), login })
        }
    }
}

/// Seal `op` to `daemon_key` for `machine`.
fn sealed(daemon_key: &[u8; 32], machine: &str, op: Ready) -> Result<WorkspaceRequest, Value> {
    match op {
        Ready::MachineSecrets(values) => {
            let values: Vec<_> = values.into_iter().map(|v| (v.name, v.value)).collect();
            cmux_remote::secrets::request::replace_machine_secrets(daemon_key, machine, &values)
                .map_err(|_| failure("bad_request", None, false))
        }
        Ready::GitHost { host, token, .. } => {
            cmux_remote::secrets::request::replace_git_host_token(
                daemon_key,
                machine,
                &host,
                token.as_ref(),
            )
            .map_err(|_| failure("bad_request", None, false))
        }
    }
}

fn print(line: &Value) -> i32 {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
    if line.get("ok") == Some(&json!(true)) { 0 } else { 1 }
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
    let op = match ready(request.op, own_github_login) {
        Ok(op) => op,
        Err(line) => return print(&line),
    };
    let dial_failed = |failure: &Failure| {
        print(&self::failure(failure.step.error_code(), None, failure.retryable))
    };
    if request.team.as_deref().is_some_and(|team| !contract::valid_team(team)) {
        return print(&failure("bad_request", None, false));
    }
    let source = match crate::cli::secure_cloud_origin(request.api.trim())
        .map_err(|why| Failure::fatal(contract::Step::Ticket, why))
        .and_then(|api| {
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
            prefetched: Arc::new(answer::Prefetched::default()),
            // Route lines carry the machine id, the step and the time: no value.
            log: Arc::new(|line| {
                let mut stderr = std::io::stderr().lock();
                let _ = stderr.write_all(line.as_bytes());
            }),
            phases: Arc::new(|_| {}),
            fresh_sessions: Default::default(),
            progress: None,
            ssh: Arc::new(super::ssh::SshSetup::from_env(None)),
            ssh_refusal: super::ssh::SshRefusal::default(),
            drill: false,
        };
        let dialed = match client::dial(&plan).await {
            Ok(dialed) => dialed,
            Err(failure) => {
                return self::failure(failure.step.error_code(), None, failure.retryable);
            }
        };
        // The exchange and the shutdown stay inside the same deadline.
        exchange(dialed, &machine, op, plan.deadline).await
    });
    runtime.shutdown_timeout(super::STDIO_SHUTDOWN_TIMEOUT);
    print(&line)
}

/// Send `op` on the dialed session and shut it down, all by `deadline`; past
/// it the answer is `timeout` (retryable).
async fn exchange(
    dialed: client::Dialed,
    machine: &str,
    op: Ready,
    deadline: tokio::time::Instant,
) -> Value {
    let line = within(deadline, send(&dialed, machine, op)).await;
    let client::Dialed { connection, multiplexer, mux, .. } = dialed;
    let _ = tokio::time::timeout_at(deadline, async {
        mux.close().await;
        multiplexer.shutdown().await;
        let _ = connection.close().await;
    })
    .await;
    line
}

/// `answer`'s line, or `timeout` (retryable) once `deadline` passes: a
/// daemon that holds the session open without answering never outlasts it.
async fn within(deadline: tokio::time::Instant, answer: impl Future<Output = Value>) -> Value {
    tokio::time::timeout_at(deadline, answer)
        .await
        .unwrap_or_else(|_| failure("timeout", None, true))
}

async fn send(dialed: &client::Dialed, machine: &str, op: Ready) -> Value {
    let Ok(workspace) = WorkspaceClient::connect(dialed.multiplexer.clone()).await else {
        return failure("transport", None, true);
    };
    let needed = op.capability();
    let login = op.login().map(str::to_owned);
    match workspace.request(WorkspaceRequest::Capabilities).await {
        Ok(WorkspaceResponse::Capabilities { capabilities }) if capabilities.contains(&needed) => {}
        Ok(_) => return failure("unsupported", None, false),
        Err(error) => return failure("transport", None, error.retryable),
    }
    // The key this session's handshake proved: the dial pinned it to the
    // carrier answer's `daemon_key` (a dial with none fails), so only that
    // daemon can open what follows.
    let daemon_key = dialed.connection.daemon_public_key();
    let request = match sealed(&daemon_key, machine, op) {
        Ok(request) => request,
        Err(line) => return line,
    };
    with_login(answer_for(workspace.request(request).await), login.as_deref())
}

/// The answer with the login `use-github-login` carried, when it went through.
fn with_login(mut line: Value, login: Option<&str>) -> Value {
    if let (Some(login), Some(map)) = (login, line.as_object_mut())
        && map.get("ok") == Some(&json!(true))
    {
        map.insert("login".into(), json!(login));
    }
    line
}

#[cfg(test)]
#[path = "secrets_tests.rs"]
mod tests;
