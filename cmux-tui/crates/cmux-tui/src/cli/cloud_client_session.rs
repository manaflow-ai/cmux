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
//! runs one command with it (or, on a machine whose provider has no client
//! sessions, runs it through the cmux API's machine exec route,
//! `POST /v1/cloud/machines/{machine}/exec`) (`exec-await` with the
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

use cmux_cloud_client::machine::{Machine, Scope};
use serde_json::{Value, json};

use super::{OutputMode, UsageError};
pub(crate) use cmux_cloud_api::session::secure_origin;
use cmux_cloud_api::session::{
    ExecAnswer, IDENTITY_HEADER, Session, TEAM_HEADER, exec_answer, known_code, mint_session,
    redact, valid_machine,
};

const USAGE: &str = "usage: cmux vm access new --target vm:VM_ID [--ttl SECONDS] [--token-file PATH]\n       cmux vm access exec --target vm:VM_ID [--ttl SECONDS] [--timeout-ms MS] -- COMMAND...\n  both take --cloud-api URL (or CMUX_CLOUD_API_URL), --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN) and --team TEAM_ID";
const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
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
    let env = |key: &str| std::env::var(key).ok().filter(|value| !value.trim().is_empty());
    if let Some(words) = app_exec(&command, env)
        && super::app::connect_command(global).is_ok()
    {
        return super::vm_short::exec_here(global, "cloud exec", &words);
    }
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
                command.machine = super::vm_words::bare_id(&value).to_owned();
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

/// `access exec` with no cmux API or credential given (no flag, no environment): the words of the app's `cloud exec`,
/// which runs the command on the machine with the app's own sign-in, as `cmux vm exec` does. `None` for `access new`:
/// the app has no action that mints a client session, so `new` still needs `--cloud-api` and a credential.
pub(super) fn app_exec(
    command: &Command,
    env: impl Fn(&str) -> Option<String>,
) -> Option<Vec<String>> {
    let Verb::Exec { command: line, .. } = &command.verb else { return None };
    let named =
        command.api.is_some() || command.credential_file.is_some() || command.team.is_some();
    if named || env(API_ENV).is_some() || env(TOKEN_ENV).is_some() {
        return None;
    }
    Some(vec![
        "--target".to_owned(),
        format!("machine:{}", command.machine),
        "--command".to_owned(),
        line.clone(),
    ])
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
    let io = |e: std::io::Error| e.to_string();
    // The machine is a handle on this backend and team from here on: no call below names the
    // backend again (lens review 2026-11-05, finding 2).
    let scope = Scope::new(api, command.team.as_deref()).map_err(|e| e.to_string())?;
    let machine = scope.machine(&command.machine).map_err(|e| e.to_string())?;
    let minted = runtime.block_on(mint_session(&client, &scope, credential, &machine, command.ttl));
    let session = match (minted, &command.verb) {
        (Ok(session), _) => session,
        // A provider with no client sessions (a VM API machine): exec runs through the cmux
        // API's own machine exec route as the work user, with the same answer this command
        // prints for a direct exec. `new` has no such route: a session is what it makes.
        // Only the machine's creator gets here: the platform refuses anyone else with
        // not_creator (auth.forbidden) before it asks the provider (ClientSession.ts
        // mintClientSessionOn), so this fallback never widens who may run a command.
        (Err(refusal), Verb::Exec { command: line, timeout_ms })
            if refusal.code == "cloud.provider.unsupported" =>
        {
            let mut answer = runtime.block_on(exec_route(
                &client,
                &scope,
                credential,
                &machine,
                line,
                *timeout_ms,
            ))?;
            answer.stdout = redact(&answer.stdout, "", credential);
            answer.stderr = redact(&answer.stderr, "", credential);
            return print_exec(&command.machine, &answer, output, out, err).map_err(io);
        }
        (Err(refusal), _) => return Err(refusal.message),
    };
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
            print_exec(&session.machine, &answer, output, out, err).map_err(io)
        }
    }
}

/// Prints one exec's answer as `output` asks and answers its exit code.
fn print_exec(
    machine: &str,
    answer: &ExecAnswer,
    output: OutputMode,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> std::io::Result<i32> {
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            writeln!(
                out,
                "{}",
                json!({ "machine": machine, "exit_code": answer.exit_code, "stdout": answer.stdout, "stderr": answer.stderr })
            )?;
        }
        // Quiet drops the command's output; its stderr and exit code still say what failed.
        OutputMode::Quiet => err.write_all(answer.stderr.as_bytes())?,
        OutputMode::Human => {
            out.write_all(answer.stdout.as_bytes())?;
            err.write_all(answer.stderr.as_bytes())?;
        }
    }
    Ok(answer.exit_code)
}

/// `POST {api}/v1/cloud/machines/{machine}/exec` (cmux-platform MachineGuest.ts):
/// `{command, timeoutMs}` -> `{exitCode, stdout, stderr}`, as the work user. A refusal answers
/// `{ok: false, error: {code}}`; only a code from `cmux_cloud_api::session::known_code` is printed.
async fn exec_route(
    client: &reqwest::Client,
    scope: &Scope,
    credential: &str,
    machine: &Machine,
    command: &str,
    timeout_ms: u64,
) -> Result<ExecAnswer, String> {
    let url = scope.route(machine, "/exec").map_err(|foreign| foreign.to_string())?;
    let mut request = client
        .post(url)
        .bearer_auth(credential)
        .timeout(Duration::from_millis(timeout_ms).saturating_add(Duration::from_secs(15)))
        .json(&json!({ "command": command, "timeoutMs": timeout_ms }));
    if let Some(team) = scope.team() {
        request = request.header(TEAM_HEADER, team);
    }
    let response = request
        .send()
        .await
        .map_err(|e| format!("the cmux API did not answer: {}", e.without_url()))?;
    let status = response.status();
    let body: Option<Value> = response.json().await.ok();
    let unreadable = || "the machine's answer is not readable".to_owned();
    let body = body.filter(Value::is_object).ok_or_else(unreadable)?;
    if !status.is_success() || body.get("ok") == Some(&Value::Bool(false)) {
        let code = body.get("error").and_then(|e| e.get("code")).and_then(Value::as_str);
        let code = known_code(code);
        let code = if code.contains(credential) { "" } else { code };
        return Err(format!("the cmux API refused the command: {status} {code}"));
    }
    let body = body.get("value").filter(|v| v.is_object()).unwrap_or(&body);
    let text = |key: &str| match body.get(key) {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(_) => Err(unreadable()),
    };
    let exit_code = body
        .get("exitCode")
        .and_then(Value::as_i64)
        .and_then(|c| i32::try_from(c).ok())
        .ok_or("the machine's answer has no readable exit status")?;
    Ok(ExecAnswer { exit_code, stdout: text("stdout")?, stderr: text("stderr")? })
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
