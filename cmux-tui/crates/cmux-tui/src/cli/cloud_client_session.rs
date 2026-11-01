//! `cmux machine access new|exec --target machine:VM_ID` (old spelling:
//! `cmux cloud client-session create|exec`): a Freestyle
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

const USAGE: &str = "usage: cmux machine access new --target machine:VM_ID [--ttl SECONDS] [--token-file PATH]\n       cmux machine access exec --target machine:VM_ID [--ttl SECONDS] [--timeout-ms MS] -- COMMAND...\n  both take --cloud-api URL (or CMUX_CLOUD_API_URL), --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN) and --team TEAM_ID";
const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
pub(super) const IDENTITY_HEADER: &str = "x-freestyle-identity-access-token";
pub(super) const TEAM_HEADER: &str = "x-cmux-team";
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

/// `Some(exit code)` when `args` is `cloud client-session …`, the old
/// spelling of `machine access new|exec --target …` (vm.rs routes that here
/// through [`run_words`]).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "client-session" {
        return None;
    }
    Some(run_words(&global, rest))
}

/// Runs `create …` or `exec …` (the words after `client-session`, or after
/// `machine access` with `new` as `create`) and answers the exit code.
pub(super) fn run_words(global: &super::GlobalArgs, rest: &[String]) -> i32 {
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => return fail("usage.invalid", &error.0, 2),
    };
    let resolved = resolve(&command, |key| std::env::var(key).ok());
    let (api, credential) = match resolved {
        Ok(pair) => pair,
        Err(message) => return fail("usage.invalid", &message, 2),
    };
    let stdout = &mut std::io::stdout();
    let stderr = &mut std::io::stderr();
    match run(&command, &api, &credential, global.output, stdout, stderr) {
        Ok(code) => code,
        Err(message) => fail("cloud_client_session.failed", &message, 1),
    }
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

pub(super) fn valid_machine(id: &str) -> bool {
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
        // The error names neither the path nor the file's contents (a pasted secret could be in either).
        Some(path) => std::fs::read_to_string(path)
            .map_err(|e| format!("the --cloud-token-file could not be read ({:?})", e.kind()))?,
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
/// Errors never echo the URL (it could hold a secret someone pasted into it).
pub(super) fn secure_origin(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "the cmux API is not a URL".to_owned())?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(
            "the cmux API URL must be a bare origin (no user, path, query or fragment)".into()
        );
    }
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err("the cmux API is not https: a credential never goes over plain http".into());
    }
    Ok(url.origin().ascii_serialization())
}

/// One minted session (the server's `value`).
#[derive(Debug, serde::Deserialize)]
pub(super) struct Session {
    pub(super) machine: String,
    pub(super) vm_id: String,
    pub(super) linux_user: String,
    pub(super) token: String,
    pub(super) expires_at: u64,
    pub(super) api_base_url: String,
    pub(super) ssh: Option<SshLine>,
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub(super) struct SshLine {
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
                // The path is printed below: one that holds a secret is refused, and never echoed.
                let shown = path.display().to_string();
                if shown.contains(session.token.as_str()) || shown.contains(credential) {
                    return Err(
                        "the token file's path would reveal a secret; choose another".into()
                    );
                }
                write_token_file(path, &session.token)?;
            }
            if output == OutputMode::Quiet {
                // Quiet prints nothing on success, the token least of all.
                return Ok(0);
            }
            let ssh = session.ssh.as_ref().map(|s| format!("ssh {}@{}", s.user, s.host));
            if matches!(output, OutputMode::Json | OutputMode::JsonLines) {
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
            let mut answer = runtime.block_on(exec(&client, &session, line, *timeout_ms))?;
            // Nothing the provider answers carries either secret to the terminal.
            answer.stdout = redact(&answer.stdout, &session.token, credential);
            answer.stderr = redact(&answer.stderr, &session.token, credential);
            let code = answer.exit_code.to_string();
            if code == session.token || code == credential {
                return Err("the machine's answer is not readable".into());
            }
            match output {
                OutputMode::Json | OutputMode::JsonLines => {
                    writeln!(out, "{}", json!({ "machine": session.machine, "exit_code": answer.exit_code, "stdout": answer.stdout, "stderr": answer.stderr })).map_err(io)?;
                }
                // Quiet drops the command's output; its stderr and exit code still say what failed.
                OutputMode::Quiet => err.write_all(answer.stderr.as_bytes()).map_err(io)?,
                OutputMode::Human => {
                    out.write_all(answer.stdout.as_bytes()).map_err(io)?;
                    err.write_all(answer.stderr.as_bytes()).map_err(io)?;
                }
            }
            Ok(answer.exit_code)
        }
    }
}

/// A checked `exec-await` answer (Freestyle's `ExecResponse`: every field optional and nullable).
#[derive(Debug, PartialEq, Eq)]
pub(super) struct ExecAnswer {
    pub(super) exit_code: i32,
    pub(super) stdout: String,
    pub(super) stderr: String,
}

/// The answer, or an error when it is not an object or a field has the wrong type. A missing or
/// null `statusCode` means the guest killed the command at its deadline: 124, as `timeout` says.
pub(super) fn exec_answer(body: Option<Value>) -> Result<ExecAnswer, String> {
    let unreadable = || "the machine's answer is not readable".to_owned();
    let body = body.filter(Value::is_object).ok_or_else(unreadable)?;
    let text = |key: &str| match body.get(key) {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(_) => Err(unreadable()),
    };
    let exit_code = match body.get("statusCode") {
        None | Some(Value::Null) => 124,
        Some(code) => code
            .as_i64()
            .and_then(|c| i32::try_from(c).ok())
            .ok_or("the machine's answer has no readable exit status")?,
    };
    Ok(ExecAnswer { exit_code, stdout: text("stdout")?, stderr: text("stderr")? })
}

async fn mint(
    client: &reqwest::Client,
    command: &Command,
    api: &str,
    credential: &str,
) -> Result<Session, String> {
    mint_session(client, api, credential, command.team.as_deref(), &command.machine, command.ttl)
        .await
        .map_err(|refusal| refusal.message)
}

/// Why a mint gave no session: the HTTP status (0: no answer, or an answer that is not a
/// session) and the refusal code from [`KNOWN_CODES`] (empty for any other), with a message that
/// carries neither secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MintRefusal {
    pub(super) status: u16,
    pub(super) code: &'static str,
    pub(super) message: String,
}

/// `POST {api}/v1/cloud/machines/{machine}/client-session` as `credential` (in `team`), checked
/// by [`checked_session`]. Shared by `cloud client-session` and `cloud machine-io`.
pub(super) async fn mint_session(
    client: &reqwest::Client,
    api: &str,
    credential: &str,
    team: Option<&str>,
    machine: &str,
    ttl: Option<u64>,
) -> Result<Session, MintRefusal> {
    let refused =
        |status: u16, code: &'static str, message: String| MintRefusal { status, code, message };
    let mut request = client
        .post(format!("{api}/v1/cloud/machines/{machine}/client-session"))
        .bearer_auth(credential)
        .timeout(MINT_TIMEOUT)
        .json(&ttl.map_or_else(|| json!({}), |ttl| json!({ "ttl_seconds": ttl })));
    if let Some(team) = team {
        request = request.header(TEAM_HEADER, team);
    }
    let response = request
        .send()
        .await
        .map_err(|e| refused(0, "", format!("the cmux API did not answer: {}", e.without_url())))?;
    let status = response.status();
    let body: Value = response.json().await.map_err(|_| {
        refused(
            status.as_u16(),
            "",
            format!("the cmux API answered {status} with no readable body"),
        )
    })?;
    if !status.is_success() || body.get("ok") != Some(&Value::Bool(true)) {
        // Only a code this command knows, printed from its own table: nothing the answer
        // carries (a credential a proxy or a broken server echoed) reaches the terminal.
        let code = body.get("error").and_then(|e| e.get("code")).and_then(Value::as_str);
        let code = known_code(code);
        // A credential that happens to spell a known code is still never printed.
        let code = if code.contains(credential) { "" } else { code };
        let message = format!("the cmux API refused the client session: {status} {code}");
        return Err(refused(status.as_u16(), code, message));
    }
    let session: Session = serde_json::from_value(body.get("value").cloned().unwrap_or_default())
        .map_err(|_| {
        refused(0, "", "the cmux API's answer is not a client session".to_owned())
    })?;
    checked_session(session, machine, credential).map_err(|message| refused(0, "", message))
}

/// The session when it is for `machine`, every field this command prints is plain (no secret can
/// hide in it), and the token goes only to the provider's API: https on freestyle.sh, or this
/// machine (a fake in development), with no user, query or fragment.
pub(super) fn checked_session(
    session: Session,
    machine: &str,
    credential: &str,
) -> Result<Session, String> {
    let bad = |what: &str| Err(format!("the cmux API's answer has an unusable {what}"));
    if session.machine != machine {
        return bad("machine");
    }
    // Neither secret is in any field this command prints, and the token is not the credential.
    let secret_free = |v: &str| !v.contains(session.token.as_str()) && !v.contains(credential);
    // The expiry is printed too (milliseconds in JSON, seconds for people): a numeric secret could hide in it.
    let expiry_ms = session.expires_at.to_string();
    let expiry_s = session.expires_at.checked_div(1000).unwrap_or_default().to_string();
    let mut printed = vec![
        session.machine.as_str(),
        session.vm_id.as_str(),
        session.linux_user.as_str(),
        session.api_base_url.as_str(),
        expiry_ms.as_str(),
        expiry_s.as_str(),
    ];
    if let Some(ssh) = &session.ssh {
        printed.extend([ssh.host.as_str(), ssh.user.as_str()]);
    }
    if session.token.contains(credential) || !printed.into_iter().all(secret_free) {
        return bad("token");
    }
    let plain = |v: &str, extra: &[u8], max: usize| {
        !v.is_empty()
            && v.len() <= max
            && v.bytes().all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
            && !v.contains(session.token.as_str())
            && !v.contains(credential)
    };
    if session.token.is_empty() || !plain(&session.vm_id, b"-_", 64) {
        return bad("VM id");
    }
    let user_ok =
        session.linux_user.bytes().next().is_some_and(|b| b.is_ascii_lowercase() || b == b'_')
            && plain(&session.linux_user, b"-_", 32)
            && session.linux_user.bytes().all(|b| !b.is_ascii_uppercase());
    if !user_ok {
        return bad("Linux user");
    }
    if let Some(ssh) = &session.ssh {
        let host_ok =
            plain(&ssh.host, b"-.", 253) && ssh.host.bytes().all(|b| !b.is_ascii_uppercase());
        if !host_ok || ssh.user != format!("{}+{}", session.vm_id, session.linux_user) {
            return bad("SSH line");
        }
    }
    let url = reqwest::Url::parse(&session.api_base_url)
        .map_err(|_| "the cmux API's answer has an unusable provider API".to_owned())?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let freestyle = url.scheme() == "https"
        && url.host_str().is_some_and(|h| h == "freestyle.sh" || h.ends_with(".freestyle.sh"));
    let bare = url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    if !bare || !(freestyle || (local && matches!(url.scheme(), "http" | "https"))) {
        return bad("provider API");
    }
    Ok(session)
}

async fn exec(
    client: &reqwest::Client,
    session: &Session,
    command: &str,
    timeout_ms: u64,
) -> Result<ExecAnswer, String> {
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
        // The status only: the provider's error body is never printed.
        return Err(format!("the machine refused the command: {status}"));
    }
    exec_answer(body)
}

/// The cmux API's client-session refusal codes. `known_code` prints only these, from this table.
const KNOWN_CODES: [&str; 13] = [
    "auth.unauthenticated",
    "auth.forbidden",
    "owner.unreachable",
    "cloud.machine.not_found",
    "cloud.machine.paused",
    "cloud.machine.not_running",
    "cloud.plan.required",
    "cloud.rate_limited",
    "cloud.provider.unsupported",
    "cloud.provider.unavailable",
    "validation.invalid",
    "team.not_member",
    "auth.sso_required",
];

/// The table's copy of `code` when the code is one this command knows, else nothing.
pub(super) fn known_code(code: Option<&str>) -> &'static str {
    code.and_then(|c| KNOWN_CODES.iter().copied().find(|known| *known == c)).unwrap_or("")
}

/// `text` with every occurrence of the token and the credential replaced.
pub(super) fn redact(text: &str, token: &str, credential: &str) -> String {
    let mut text = text.to_owned();
    for secret in [token, credential] {
        if !secret.is_empty() {
            text = text.replace(secret, "[redacted]");
        }
    }
    text
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
