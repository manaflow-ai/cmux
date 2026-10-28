//! `cmux cloud client-session create|exec --target machine:VM_ID`: a Freestyle
//! client session (freestyle.sh/docs/vms/client-sessions) on one of your own
//! Cloud machines.
//!
//! The cmux API mints it (`POST /v1/cloud/machines/{machine}/client-session`,
//! backend/apps/api/src/cloud-client-session.ts): a provider token that reaches
//! only that machine, only as its work user, for 60 to 900 seconds. `create`
//! prints how to use it (the SSH line, the token as its password) and shows the
//! token once, on stdout or in a new 0600 `--token-file`. `exec` mints one and
//! runs one command with it (`exec-await` with the
//! `x-freestyle-identity-access-token` header), printing the command's stdout and
//! stderr and exiting with its code; the token is never printed.
//!
//! The cmux API and the caller's credential come from `--cloud-api` (or
//! `CMUX_CLOUD_API_URL`) and `--cloud-token-file` (or `CMUX_CLOUD_ACCESS_TOKEN`),
//! as `cmux chief` takes them. The credential and the token go only in request
//! headers, never in a URL, an argument list, an error or a log line.

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};

use super::{OutputMode, UsageError};

const USAGE: &str = "usage: cmux cloud client-session create --target machine:VM_ID [--ttl SECONDS] [--token-file PATH]\n       cmux cloud client-session exec --target machine:VM_ID [--ttl SECONDS] [--timeout-ms MS] -- COMMAND...\n  both take --cloud-api URL (or CMUX_CLOUD_API_URL), --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN) and --team TEAM_ID";
const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
const IDENTITY_HEADER: &str = "x-freestyle-identity-access-token";
const TEAM_HEADER: &str = "x-cmux-team";
const MINT_TIMEOUT: Duration = Duration::from_secs(30);
const EXEC_TIMEOUT_DEFAULT_MS: u64 = 30_000;
/// The provider's inline exec limit (five minutes).
const EXEC_TIMEOUT_MAX_MS: u64 = 300_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Create { token_file: Option<PathBuf> },
    Exec { command: String, timeout_ms: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Command {
    pub verb: Verb,
    pub machine: String,
    pub ttl: Option<u64>,
    pub api: Option<String>,
    pub credential_file: Option<PathBuf>,
    pub team: Option<String>,
}

/// `Some(exit code)` when `args` is `cloud client-session …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "client-session" {
        return None;
    }
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => return Some(fail("usage.invalid", &error.0, 2)),
    };
    let resolved = resolve(&command, |key| std::env::var(key).ok());
    let (api, credential) = match resolved {
        Ok(pair) => pair,
        Err(message) => return Some(fail("usage.invalid", &message, 2)),
    };
    let stdout = &mut std::io::stdout();
    let stderr = &mut std::io::stderr();
    Some(match run(&command, &api, &credential, global.output, stdout, stderr) {
        Ok(code) => code,
        Err(message) => fail("cloud_client_session.failed", &message, 1),
    })
}

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let (options, tail) = match rest.iter().position(|a| a == "--") {
        Some(at) => {
            let (options, tail) = rest.split_at(at);
            (options, tail.split_first().map(|(_, words)| words))
        }
        None => (rest, None),
    };
    let mut command = Command {
        verb: Verb::Create { token_file: None },
        machine: String::new(),
        ttl: None,
        api: None,
        credential_file: None,
        team: None,
    };
    let (mut token_file, mut timeout_ms) = (None, None);
    let mut words = options.iter();
    while let Some(word) = words.next() {
        let (name, value) = match word.split_once('=') {
            Some((name, value)) => (name, value.to_owned()),
            None => (word.as_str(), words.next().cloned().ok_or_else(usage)?),
        };
        let ttl_error = || UsageError::new("--ttl takes whole seconds from 60 to 900");
        match name {
            "--target" => {
                command.machine = value.strip_prefix("machine:").unwrap_or(&value).to_owned();
            }
            "--ttl" => command.ttl = Some(value.parse().map_err(|_| ttl_error())?),
            "--cloud-api" => command.api = Some(value),
            "--cloud-token-file" => command.credential_file = Some(value.into()),
            "--team" => command.team = Some(value),
            "--token-file" if verb == "create" => token_file = Some(PathBuf::from(value)),
            "--timeout-ms" if verb == "exec" => {
                timeout_ms = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| UsageError::new("--timeout-ms takes milliseconds"))?,
                );
            }
            _ => return Err(usage()),
        }
    }
    if !valid_machine(&command.machine) {
        return Err(UsageError::new(format!(
            "--target names a Cloud machine (machine:vm_…)\n{USAGE}"
        )));
    }
    if command.ttl.is_some_and(|ttl| !(60..=900).contains(&ttl)) {
        return Err(UsageError::new("--ttl takes whole seconds from 60 to 900"));
    }
    command.verb = match (verb.as_str(), tail) {
        ("create", None) => Verb::Create { token_file },
        ("exec", Some(words)) if !words.is_empty() => {
            let timeout_ms = timeout_ms.unwrap_or(EXEC_TIMEOUT_DEFAULT_MS);
            if timeout_ms == 0 || timeout_ms > EXEC_TIMEOUT_MAX_MS {
                return Err(UsageError::new("--timeout-ms is at most 300000 (five minutes)"));
            }
            Verb::Exec { command: words.join(" "), timeout_ms }
        }
        _ => return Err(usage()),
    };
    Ok(command)
}

fn valid_machine(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// The cmux API origin and the caller's credential, from the flags or the environment.
pub(super) fn resolve(
    command: &Command,
    env: impl Fn(&str) -> Option<String>,
) -> Result<(String, String), String> {
    let api = command
        .api
        .clone()
        .or_else(|| env(API_ENV))
        .filter(|a| !a.trim().is_empty())
        .ok_or_else(|| format!("name the cmux API with --cloud-api URL or {API_ENV}"))?;
    let credential = match &command.credential_file {
        Some(path) => {
            std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?
        }
        None => env(TOKEN_ENV).ok_or_else(|| {
            format!("give your cmux credential with --cloud-token-file PATH or {TOKEN_ENV}")
        })?,
    };
    let credential = credential.trim().to_owned();
    if credential.is_empty() {
        return Err("the cmux credential is empty".into());
    }
    secure_origin(api.trim()).map(|origin| (origin, credential))
}

/// `https://…`, or `http://` only to this machine (a local API in development); no trailing slash.
fn secure_origin(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| format!("{raw:?} is not a URL"))?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err(format!("{raw:?} is not https: a credential never goes over plain http"));
    }
    Ok(raw.trim_end_matches('/').to_owned())
}

/// One minted session (the server's `value`).
#[derive(Debug, serde::Deserialize)]
struct Session {
    machine: String,
    vm_id: String,
    linux_user: String,
    token: String,
    expires_at: u64,
    api_base_url: String,
    ssh: Option<SshLine>,
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
struct SshLine {
    host: String,
    user: String,
}

pub(super) fn run(
    command: &Command,
    api: &str,
    credential: &str,
    output: OutputMode,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let session = runtime.block_on(mint(&client, command, api, credential))?;
    let io = |e: std::io::Error| e.to_string();
    match &command.verb {
        Verb::Create { token_file } => {
            if let Some(path) = token_file {
                write_token_file(path, &session.token)?;
            }
            let ssh = session.ssh.as_ref().map(|s| format!("ssh {}@{}", s.user, s.host));
            if output == OutputMode::Json {
                // With --token-file the token is only in the file.
                let (token, file) = match token_file {
                    Some(path) => (Value::Null, json!(path.display().to_string())),
                    None => (json!(session.token), Value::Null),
                };
                let value = json!({ "machine": session.machine, "vm_id": session.vm_id, "linux_user": session.linux_user, "expires_at": session.expires_at, "api_base_url": session.api_base_url, "ssh": session.ssh, "ssh_line": ssh, "token": token, "token_file": file });
                writeln!(out, "{value}").map_err(io)?;
                return Ok(0);
            }
            writeln!(
                out,
                "machine {} (VM {}) as {} until {}",
                session.machine,
                session.vm_id,
                session.linux_user,
                session.expires_at.checked_div(1000).unwrap_or_default()
            )
            .map_err(io)?;
            if let Some(line) = ssh {
                writeln!(out, "{line}   (the token is the password)").map_err(io)?;
            }
            match token_file {
                Some(path) => writeln!(out, "token written to {}", path.display()).map_err(io)?,
                None => writeln!(out, "{}", session.token).map_err(io)?,
            }
            Ok(0)
        }
        Verb::Exec { command: line, timeout_ms } => {
            let answer = runtime.block_on(exec(&client, &session, line, *timeout_ms))?;
            let text = |key: &str| answer.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
            if output == OutputMode::Json {
                writeln!(out, "{}", json!({ "machine": session.machine, "exit_code": exit_code(&answer), "stdout": text("stdout"), "stderr": text("stderr") })).map_err(io)?;
            } else {
                out.write_all(text("stdout").as_bytes()).map_err(io)?;
                err.write_all(text("stderr").as_bytes()).map_err(io)?;
            }
            Ok(exit_code(&answer))
        }
    }
}

/// The command's exit status; a command the guest killed at its deadline has none (124, as `timeout` says).
fn exit_code(answer: &Value) -> i32 {
    answer.get("statusCode").and_then(Value::as_i64).map_or(124, |c| i32::try_from(c).unwrap_or(1))
}

async fn mint(
    client: &reqwest::Client,
    command: &Command,
    api: &str,
    credential: &str,
) -> Result<Session, String> {
    let mut request = client
        .post(format!("{api}/v1/cloud/machines/{}/client-session", command.machine))
        .bearer_auth(credential)
        .timeout(MINT_TIMEOUT)
        .json(&command.ttl.map_or_else(|| json!({}), |ttl| json!({ "ttl_seconds": ttl })));
    if let Some(team) = &command.team {
        request = request.header(TEAM_HEADER, team);
    }
    let response = request
        .send()
        .await
        .map_err(|e| format!("the cmux API did not answer: {}", e.without_url()))?;
    let status = response.status();
    let body: Value = response
        .json()
        .await
        .map_err(|_| format!("the cmux API answered {status} with no readable body"))?;
    if !status.is_success() || body.get("ok") != Some(&Value::Bool(true)) {
        // Only the error's code, and only when it is a plain code: an answer that echoed a
        // credential (a proxy, a broken server) never reaches the terminal.
        let code = body.get("error").and_then(|e| e.get("code")).and_then(Value::as_str);
        return Err(format!(
            "the cmux API refused the client session: {status} {}",
            plain_code(code)
        ));
    }
    let session: Session =
        serde_json::from_value(body.get("value").cloned().unwrap_or_default())
            .map_err(|_| "the cmux API's answer is not a client session".to_owned())?;
    // The token goes only where the server said, and only over TLS (or to this machine).
    secure_origin(&session.api_base_url)?;
    Ok(session)
}

async fn exec(
    client: &reqwest::Client,
    session: &Session,
    command: &str,
    timeout_ms: u64,
) -> Result<Value, String> {
    let url = format!(
        "{}/v5/vms/{}/exec-await",
        session.api_base_url.trim_end_matches('/'),
        session.vm_id
    );
    let response = client
        .post(url)
        .header(IDENTITY_HEADER, &session.token)
        .timeout(Duration::from_millis(timeout_ms).saturating_add(Duration::from_secs(15)))
        .json(&json!({ "command": command, "linuxUser": session.linux_user, "timeoutMs": timeout_ms }))
        .send()
        .await
        .map_err(|e| format!("the machine did not answer: {}", e.without_url()))?;
    let status = response.status();
    let body: Option<Value> = response.json().await.ok();
    if !status.is_success() {
        let code = body.as_ref().and_then(|b| b.get("code")).and_then(Value::as_str);
        return Err(format!("the machine refused the command: {status} {}", plain_code(code)));
    }
    // A readable answer is an object; a statusCode, when present, is a number (absent: killed at the deadline).
    let body = body.filter(Value::is_object).ok_or("the machine's answer is not readable")?;
    if body.get("statusCode").is_some_and(|c| !c.is_null() && !c.is_i64()) {
        return Err("the machine's answer has no readable exit status".into());
    }
    Ok(body)
}

/// `code` when it is a plain error code (`cloud.machine.not_found` or `NOT_FOUND`: one case, no
/// digits, at most 64), else nothing, so a token or credential echoed in its place is never printed.
fn plain_code(code: Option<&str>) -> &str {
    let lower = |b: u8| b.is_ascii_lowercase() || b == b'.' || b == b'_';
    let upper = |b: u8| b.is_ascii_uppercase() || b == b'_';
    code.filter(|c| {
        !c.is_empty() && c.len() <= 64 && (c.bytes().all(lower) || c.bytes().all(upper))
    })
    .unwrap_or("")
}

/// A new file only (an existing path is refused), mode 0600 from creation.
fn write_token_file(path: &std::path::Path, token: &str) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(token.as_bytes())
        .and_then(|()| file.write_all(b"\n"))
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests;
