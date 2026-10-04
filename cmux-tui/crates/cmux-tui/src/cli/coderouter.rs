//! `cmux coderouter …` and `cmux cr …`.
//!
//! cmux owns five verbs: `status`, `machines` and `claude list|add|remove|
//! disable|enable|clear` manage the team's CodeRouter model plane through the
//! cmux app, which holds the Stack session and passes each call to the
//! CodeRouter control plane (`coderouter.*` app methods,
//! plans/cmux-next/coderouter.md). Every other `cmux coderouter …` and all of
//! `cmux cr …` exec the CodeRouter CLI the app bundles
//! (`Contents/Resources/bin/coderouter`) with every `CMUX_*` variable removed,
//! so arguments and the exit code pass through unchanged.
//!
//! A secret (`claude add`) comes only from its environment variable, stdin or
//! a hidden terminal prompt, never from argv, where it would land in shell
//! history and process listings.

use std::ffi::OsString;
use std::io::{BufRead, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

mod accounts;

use accounts::{SelectorError, account_id, account_lines, redact_emails};

/// The app bounds every CodeRouter call at 20 s (`AppControl+Accounts`); the
/// CLI waits a little longer so the app's own timeout error reaches it.
const CODEROUTER_TIMEOUT: Duration = Duration::from_secs(25);
const BUNDLED_CODEROUTER: &str = "Contents/Resources/bin/coderouter";
const OAUTH_ENV: &str = "CLAUDE_CODE_OAUTH_TOKEN";
const API_KEY_ENV: &str = "ANTHROPIC_API_KEY";

/// What `cmux coderouter|cr …` runs.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    /// Exec the bundled CodeRouter CLI with these arguments.
    Passthrough(Vec<String>),
    Help,
    Owned(Verb),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Verb {
    Status { team: Option<String> },
    Machines { team: Option<String> },
    ClaudeList { team: Option<String> },
    ClaudeAdd { team: Option<String>, label: Option<String>, credential: Credential },
    ClaudeRemove { team: Option<String>, account: String },
    ClaudeState { team: Option<String>, account: String, enable: bool },
    ClaudeClear { team: Option<String> },
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Credential {
    OauthToken { stdin: bool },
    ApiKey { stdin: bool },
    Bedrock { region: Option<String>, models: Vec<(String, String)> },
}

/// `cmux coderouter …` and `cmux cr …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (word, rest) = split(&command_args)?;
    Some(match parse(word, rest, args) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

/// `Some(args after the command word)` when `args` (after the global
/// options) start with `coderouter` or `cr`.
pub(super) fn split(command_args: &[String]) -> Option<(&str, &[String])> {
    let (first, rest) = command_args.split_first()?;
    matches!(first.as_str(), "coderouter" | "cr").then_some((first.as_str(), rest))
}

/// The raw arguments after the first `coderouter`/`cr` word of `args`, for a
/// passthrough: the global-option parser must not eat the CodeRouter CLI's
/// own `--json` or `--help`.
fn raw_tail(args: &[String]) -> Vec<String> {
    args.iter()
        .position(|arg| arg == "coderouter" || arg == "cr")
        .map(|index| args[index + 1..].to_vec())
        .unwrap_or_default()
}

pub(super) fn parse(word: &str, rest: &[String], raw: &[String]) -> Result<Invocation, UsageError> {
    if word == "cr" {
        return Ok(Invocation::Passthrough(raw_tail(raw)));
    }
    let Some((verb, tail)) = rest.split_first() else {
        return Ok(Invocation::Passthrough(raw_tail(raw)));
    };
    if matches!(verb.as_str(), "status" | "machines" | "machine" | "claude")
        && tail.iter().take_while(|arg| *arg != "--").any(|arg| arg == "--help" || arg == "-h")
    {
        return Ok(Invocation::Help);
    }
    let owned = match verb.as_str() {
        "help" | "--help" | "-h" => return Ok(Invocation::Help),
        "status" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            options.no_positionals("coderouter status")?;
            Verb::Status { team: options.take("team") }
        }
        "machines" | "machine" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            options.no_positionals("coderouter machines")?;
            Verb::Machines { team: options.take("team") }
        }
        "claude" => parse_claude(tail)?,
        // Any other verb, and a bare `cmux coderouter`, is the CodeRouter
        // CLI's (`cmux coderouter login`, `cmux coderouter accounts`).
        _ => return Ok(Invocation::Passthrough(raw_tail(raw))),
    };
    Ok(Invocation::Owned(owned))
}

fn parse_claude(args: &[String]) -> Result<Verb, UsageError> {
    let messages = &crate::localization::catalog().coderouter;
    let (sub, tail) = match args.split_first() {
        Some((sub, tail)) if !sub.starts_with('-') => (sub.as_str(), tail),
        _ => ("list", args),
    };
    Ok(match sub {
        "list" | "ls" | "show" | "get" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            options.no_positionals("coderouter claude list")?;
            Verb::ClaudeList { team: options.take("team") }
        }
        "add" | "set" => parse_claude_add(tail)?,
        "remove" | "rm" | "delete" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            let account = options.one_positional("coderouter claude remove")?;
            Verb::ClaudeRemove { team: options.take("team"), account }
        }
        "disable" | "enable" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            let account = options.one_positional(&format!("coderouter claude {sub}"))?;
            Verb::ClaudeState { team: options.take("team"), account, enable: sub == "enable" }
        }
        "clear" | "remove-all" => {
            let mut options = Options::parse(tail, &["team"], &[])?;
            options.no_positionals("coderouter claude clear")?;
            Verb::ClaudeClear { team: options.take("team") }
        }
        other => {
            return Err(UsageError::new(messages.unknown_claude_verb.replace("{verb}", other)));
        }
    })
}

fn parse_claude_add(args: &[String]) -> Result<Verb, UsageError> {
    let messages = &crate::localization::catalog().coderouter;
    let Some((kind, tail)) = args.split_first().filter(|(kind, _)| !kind.starts_with('-')) else {
        return Err(UsageError::new(messages.add_kind_required));
    };
    let mut options = Options::parse(tail, &["team", "label", "region", "model"], &["stdin"])?;
    // A positional after the kind would be a secret on the command line.
    if !options.positionals.is_empty() {
        return Err(UsageError::new(messages.secret_in_argv));
    }
    let stdin = options.flag("stdin");
    let credential = match kind.as_str() {
        "oauth-token" | "oauth" | "claude-code" => Credential::OauthToken { stdin },
        "api-key" | "apikey" | "anthropic-key" => Credential::ApiKey { stdin },
        "bedrock" => {
            let mut models = Vec::new();
            for pair in options.take_all("model") {
                match pair.split_once('=') {
                    Some((claude, bedrock)) if !claude.is_empty() && !bedrock.is_empty() => {
                        models.push((claude.to_owned(), bedrock.to_owned()));
                    }
                    _ => {
                        return Err(UsageError::new(
                            messages.bedrock_model.replace("{value}", &pair),
                        ));
                    }
                }
            }
            Credential::Bedrock { region: options.take("region"), models }
        }
        other => {
            return Err(UsageError::new(messages.add_kind_unsupported.replace("{kind}", other)));
        }
    };
    if !matches!(credential, Credential::Bedrock { .. })
        && (options.has("region") || options.has("model"))
    {
        return Err(UsageError::new(messages.bedrock_only));
    }
    Ok(Verb::ClaudeAdd { team: options.take("team"), label: options.take("label"), credential })
}

/// Where a secret may come from. Production reads the process; tests pass
/// fixed values.
pub(super) struct SecretSources<'a> {
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub stdin_is_terminal: bool,
    pub read_stdin: &'a mut dyn FnMut() -> std::io::Result<String>,
    pub prompt_hidden: &'a mut dyn FnMut(&str) -> std::io::Result<String>,
}

/// `--stdin` (or a stdin that is not a terminal) reads the first non-empty
/// stdin line, unless the variable is set and `--stdin` was not given; a
/// terminal uses the variable, else a hidden prompt.
pub(super) fn read_secret(
    label: &str,
    env_var: &str,
    force_stdin: bool,
    sources: &mut SecretSources<'_>,
) -> Result<String, String> {
    let messages = &crate::localization::catalog().coderouter;
    let from_env =
        (sources.env)(env_var).map(|value| value.trim().to_owned()).filter(|v| !v.is_empty());
    if force_stdin || !sources.stdin_is_terminal {
        if !force_stdin && let Some(value) = from_env {
            return Ok(value);
        }
        let text = (sources.read_stdin)().map_err(|error| error.to_string())?;
        return text
            .lines()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| messages.no_secret.replace("{label}", label).replace("{env}", env_var));
    }
    if let Some(value) = from_env {
        return Ok(value);
    }
    let prompt = messages.hidden_prompt.replace("{label}", label);
    let line = (sources.prompt_hidden)(&prompt).map_err(|error| error.to_string())?;
    let line = line.trim();
    if line.is_empty() {
        return Err(messages.no_secret.replace("{label}", label).replace("{env}", env_var));
    }
    Ok(line.to_owned())
}

/// The `coderouter.claude_upstream.add` params for `credential`, reading its
/// secret from `sources`.
pub(super) fn add_params(
    team: Option<&str>,
    label: Option<&str>,
    credential: &Credential,
    sources: &mut SecretSources<'_>,
) -> Result<Map<String, Value>, String> {
    let messages = &crate::localization::catalog().coderouter;
    let mut params = team_params(team);
    if let Some(label) = label.map(str::trim).filter(|label| !label.is_empty()) {
        params.insert("label".into(), json!(label));
    }
    match credential {
        Credential::OauthToken { stdin } => {
            let token = read_secret(messages.oauth_label, OAUTH_ENV, *stdin, sources)?;
            if !token.starts_with("sk-ant-oat01-") {
                return Err(messages.not_oauth_token.to_owned());
            }
            params.insert("kind".into(), json!("anthropic_oauth"));
            params.insert("token".into(), json!(token));
        }
        Credential::ApiKey { stdin } => {
            let key = read_secret(messages.api_key_label, API_KEY_ENV, *stdin, sources)?;
            if !key.starts_with("sk-ant-") || key.starts_with("sk-ant-oat") {
                return Err(messages.not_api_key.to_owned());
            }
            params.insert("kind".into(), json!("anthropic_api_key"));
            params.insert("apiKey".into(), json!(key));
        }
        Credential::Bedrock { region, models } => {
            let env = |name: &str| (sources.env)(name).filter(|value| !value.trim().is_empty());
            let region = region
                .clone()
                .or_else(|| env("AWS_REGION"))
                .or_else(|| env("AWS_DEFAULT_REGION"))
                .ok_or_else(|| messages.bedrock_region.to_owned())?;
            let (Some(access), Some(secret)) =
                (env("AWS_ACCESS_KEY_ID"), env("AWS_SECRET_ACCESS_KEY"))
            else {
                return Err(messages.bedrock_keys.to_owned());
            };
            params.insert("kind".into(), json!("bedrock"));
            params.insert("region".into(), json!(region));
            params.insert("accessKeyId".into(), json!(access));
            params.insert("secretAccessKey".into(), json!(secret));
            if let Some(token) = env("AWS_SESSION_TOKEN") {
                params.insert("sessionToken".into(), json!(token));
            }
            if !models.is_empty() {
                let models: Map<String, Value> = models
                    .iter()
                    .map(|(claude, bedrock)| (claude.clone(), json!(bedrock)))
                    .collect();
                params.insert("modelIds".into(), Value::Object(models));
            }
        }
    }
    Ok(params)
}

fn team_params(team: Option<&str>) -> Map<String, Value> {
    let mut params = Map::new();
    if let Some(team) = team.map(str::trim).filter(|team| !team.is_empty()) {
        params.insert("teamId".into(), json!(team));
    }
    params
}

fn is_uuid(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(group, length)| {
            group.len() == length && group.chars().all(|c| c.is_ascii_hexdigit())
        })
}

// Running

pub(super) fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    match invocation {
        Invocation::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(crate::localization::catalog().coderouter.usage.as_bytes());
            let _ = stdout.flush();
            0
        }
        Invocation::Passthrough(args) => exec_bundled(&args),
        Invocation::Owned(verb) => run_owned(global, verb),
    }
}

/// The CodeRouter CLI inside the app bundle that holds `exe`.
pub(super) fn bundled_coderouter(exe: &Path) -> Option<PathBuf> {
    let exe = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    crate::app_identity::containing_app_bundle(&exe).map(|bundle| bundle.join(BUNDLED_CODEROUTER))
}

/// The command a passthrough runs: `program args…` with every `CMUX_*`
/// variable of `environment` removed.
pub(super) fn passthrough_command(
    program: &Path,
    args: &[String],
    environment: impl IntoIterator<Item = (OsString, OsString)>,
) -> Command {
    let mut command = Command::new(program);
    command.args(args);
    for (name, _) in environment {
        if name.to_string_lossy().starts_with("CMUX_") {
            command.env_remove(name);
        }
    }
    command
}

fn exec_bundled(args: &[String]) -> i32 {
    use std::os::unix::process::CommandExt;
    let messages = &crate::localization::catalog().coderouter;
    let exe = std::env::current_exe().ok();
    let Some(program) = exe.as_deref().and_then(bundled_coderouter) else {
        eprintln!("cmux: {}", messages.no_bundle);
        return 127;
    };
    if !program.is_file() {
        eprintln!(
            "cmux: {}",
            messages.missing_binary.replace("{path}", &program.display().to_string())
        );
        return 127;
    }
    let error = passthrough_command(&program, args, std::env::vars_os()).exec();
    eprintln!(
        "cmux: {}",
        messages
            .exec_failed
            .replace("{path}", &program.display().to_string())
            .replace("{error}", &error.to_string())
    );
    126
}

fn run_owned(global: &GlobalArgs, verb: Verb) -> i32 {
    let mut client = match AppClient::connect(global) {
        Ok(client) => client,
        Err(code) => return code,
    };
    let result = match verb {
        Verb::Status { team } => status(&mut client, team.as_deref()),
        Verb::Machines { team } => {
            client.call("coderouter.machines", team_params(team.as_deref())).map(|response| {
                let machines = response.get("machines").cloned();
                (response, machines)
            })
        }
        Verb::ClaudeList { team } => client
            .call("coderouter.claude_upstream.get", team_params(team.as_deref()))
            .map(|response| {
                let lines = account_lines(response.get("accounts"));
                (response, Some(lines))
            }),
        Verb::ClaudeAdd { team, label, credential } => {
            let env = |name: &str| std::env::var(name).ok();
            let mut read_stdin = || {
                let mut text = String::new();
                std::io::stdin().lock().read_to_string(&mut text).map(|_| text)
            };
            let mut prompt_hidden = |prompt: &str| read_hidden_line(prompt);
            let mut sources = SecretSources {
                env: &env,
                stdin_is_terminal: std::io::stdin().is_terminal(),
                read_stdin: &mut read_stdin,
                prompt_hidden: &mut prompt_hidden,
            };
            match add_params(team.as_deref(), label.as_deref(), &credential, &mut sources) {
                Ok(params) => {
                    client.call("coderouter.claude_upstream.add", params).map(|r| (r, None))
                }
                Err(message) => Err(Failed::Usage(message)),
            }
        }
        Verb::ClaudeRemove { team, account } => {
            with_account(&mut client, team.as_deref(), &account, |client, mut params| {
                client.call("coderouter.claude_upstream.remove", std::mem::take(&mut params))
            })
        }
        Verb::ClaudeState { team, account, enable } => {
            with_account(&mut client, team.as_deref(), &account, |client, mut params| {
                params.insert("state".into(), json!(if enable { "active" } else { "disabled" }));
                client.call("coderouter.claude_upstream.update", params)
            })
        }
        Verb::ClaudeClear { team } => client
            .call("coderouter.claude_upstream.clear", team_params(team.as_deref()))
            .map(|r| (r, None)),
    };
    match result {
        Ok((response, human)) => {
            let value = match global.output {
                OutputMode::Human => human.unwrap_or(response),
                _ => response,
            };
            super::wire::print_local_success(&value, global.output)
        }
        Err(Failed::App(mut error)) => {
            let exit_code = match error.get("code").and_then(Value::as_str) {
                Some("not_signed_in") => 3,
                Some("method_not_found") => 5,
                _ => 1,
            };
            if let Some(message) = error.get("message").and_then(Value::as_str) {
                error["message"] = json!(redact_emails(message));
            }
            super::wire::print_local_error(&error, global.output, exit_code)
        }
        Err(Failed::Transport(message)) => {
            super::app::failure("app.transport", &redact_emails(&message), global.output, 3)
        }
        Err(Failed::Usage(message)) => {
            super::app::failure("usage.invalid", &message, global.output, 2)
        }
        Err(Failed::Selector(error)) => {
            super::wire::print_local_error(&error.error_value(), global.output, 2)
        }
    }
}

/// `auth.status` plus the team's Claude upstream accounts when signed in.
fn status(client: &mut AppClient, team: Option<&str>) -> Result<(Value, Option<Value>), Failed> {
    let auth = client.call("auth.status", Map::new())?;
    let signed_in = auth.get("signed_in").and_then(Value::as_bool).unwrap_or(false);
    let mut payload = Map::new();
    payload.insert("signed_in".into(), json!(signed_in));
    for (key, from) in [("user", "user"), ("selected_team_id", "selected_team_id")] {
        if let Some(value) = auth.get(from) {
            payload.insert(key.into(), value.clone());
        }
    }
    if signed_in {
        match client.call("coderouter.claude_upstream.get", team_params(team)) {
            Ok(response) => {
                payload.insert(
                    "team_id".into(),
                    response.get("teamId").cloned().unwrap_or(Value::Null),
                );
                payload.insert(
                    "claude_accounts".into(),
                    response.get("accounts").cloned().unwrap_or_else(|| json!([])),
                );
            }
            Err(Failed::App(error)) => {
                let message = error.get("message").cloned().unwrap_or(error);
                payload.insert("claude_accounts_error".into(), message);
            }
            Err(other) => return Err(other),
        }
    }
    let human = status_text(&payload);
    Ok((Value::Object(payload), Some(human)))
}

/// The text form of `coderouter status`: sign-in state, then one line per
/// Claude account. It never prints the user's email.
fn status_text(payload: &Map<String, Value>) -> Value {
    let messages = &crate::localization::catalog().coderouter;
    let signed_in = payload.get("signed_in").and_then(Value::as_bool).unwrap_or(false);
    if !signed_in {
        return json!(messages.status_signed_out);
    }
    let mut text = messages.status_signed_in.to_owned();
    if let Some(error) = payload.get("claude_accounts_error").and_then(Value::as_str) {
        text.push('\n');
        text.push_str(&redact_emails(error));
    } else if let Value::String(lines) = account_lines(payload.get("claude_accounts")) {
        text.push('\n');
        text.push_str(&lines);
    }
    json!(text)
}

fn with_account(
    client: &mut AppClient,
    team: Option<&str>,
    selector: &str,
    call: impl FnOnce(&mut AppClient, Map<String, Value>) -> Result<Value, Failed>,
) -> Result<(Value, Option<Value>), Failed> {
    let id = if is_uuid(selector) {
        selector.to_lowercase()
    } else {
        let response = client.call("coderouter.claude_upstream.get", team_params(team))?;
        account_id(selector, response.get("accounts").unwrap_or(&Value::Null))
            .map_err(Failed::Selector)?
    };
    let mut params = team_params(team);
    params.insert("accountId".into(), json!(id));
    call(client, params).map(|response| (response, None))
}

enum Failed {
    App(Value),
    Transport(String),
    Usage(String),
    Selector(SelectorError),
}

/// One connection to the app control socket for every call of a verb.
struct AppClient {
    stream: std::os::unix::net::UnixStream,
}

impl AppClient {
    fn connect(global: &GlobalArgs) -> Result<Self, i32> {
        let socket = super::app::socket_path(global)
            .map_err(|error| super::app::failure("app.not_found", &error, global.output, 3))?;
        let stream = super::app::connect(&socket)
            .map_err(|error| super::app::failure("app.unreachable", &error, global.output, 3))?;
        Ok(Self { stream })
    }

    fn call(&mut self, method: &str, params: Map<String, Value>) -> Result<Value, Failed> {
        match super::app::request(
            &mut self.stream,
            method,
            Value::Object(params),
            CODEROUTER_TIMEOUT,
        ) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(Failed::App(error)),
            Err(message) => Err(Failed::Transport(message)),
        }
    }
}

/// One line from stdin with terminal echo off.
fn read_hidden_line(prompt: &str) -> std::io::Result<String> {
    let mut stderr = std::io::stderr().lock();
    stderr.write_all(prompt.as_bytes())?;
    stderr.flush()?;
    // SAFETY: termios is plain data; tcgetattr fills it for fd 0.
    let mut original: libc::termios = unsafe { std::mem::zeroed() };
    let has_terminal = unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } == 0;
    if has_terminal {
        let mut hidden = original;
        hidden.c_lflag &= !libc::ECHO;
        // SAFETY: a termios copy of the current settings with ECHO cleared.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &hidden) };
    }
    let mut line = String::new();
    let read = std::io::stdin().lock().read_line(&mut line);
    if has_terminal {
        // SAFETY: restores the settings read above.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &original) };
    }
    let _ = stderr.write_all(b"\n");
    read.map(|_| line)
}

/// `--name value`, `--name=value` (repeatable), boolean flags and positionals.
struct Options {
    values: Vec<(String, String)>,
    flags: Vec<String>,
    positionals: Vec<String>,
}

impl Options {
    fn parse(args: &[String], valued: &[&str], flags: &[&str]) -> Result<Self, UsageError> {
        let messages = &crate::localization::catalog().app_control;
        let mut options = Self { values: Vec::new(), flags: Vec::new(), positionals: Vec::new() };
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            index += 1;
            let Some(name) = arg.strip_prefix("--") else {
                if arg.starts_with('-') && arg != "-" {
                    return Err(UsageError::new(
                        messages.unexpected_argument.replace("{value}", arg),
                    ));
                }
                options.positionals.push(arg.clone());
                continue;
            };
            if let Some((name, value)) = name.split_once('=')
                && valued.contains(&name)
            {
                options.values.push((name.into(), value.into()));
            } else if valued.contains(&name) {
                let value = args.get(index).ok_or_else(|| {
                    UsageError::new(messages.missing_value.replace("{flag}", arg))
                })?;
                options.values.push((name.into(), value.clone()));
                index += 1;
            } else if flags.contains(&name) {
                options.flags.push(name.into());
            } else {
                return Err(UsageError::new(messages.unexpected_argument.replace("{value}", arg)));
            }
        }
        Ok(options)
    }

    fn take(&mut self, key: &str) -> Option<String> {
        self.values.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.clone())
    }

    fn take_all(&mut self, key: &str) -> Vec<String> {
        self.values.iter().filter(|(name, _)| name == key).map(|(_, value)| value.clone()).collect()
    }

    fn has(&self, key: &str) -> bool {
        self.values.iter().any(|(name, _)| name == key)
    }

    fn flag(&self, key: &str) -> bool {
        self.flags.iter().any(|flag| flag == key)
    }

    fn no_positionals(&self, command: &str) -> Result<(), UsageError> {
        match self.positionals.first() {
            None => Ok(()),
            Some(extra) => Err(UsageError::new(
                crate::localization::catalog()
                    .coderouter
                    .unexpected_argument
                    .replace("{command}", command)
                    .replace("{value}", extra),
            )),
        }
    }

    fn one_positional(&mut self, command: &str) -> Result<String, UsageError> {
        let messages = &crate::localization::catalog().coderouter;
        match self.positionals.as_slice() {
            [one] if !one.is_empty() => Ok(one.clone()),
            [] | [_] => {
                Err(UsageError::new(messages.account_required.replace("{command}", command)))
            }
            [_, extra, ..] => Err(UsageError::new(
                messages
                    .unexpected_argument
                    .replace("{command}", command)
                    .replace("{value}", extra),
            )),
        }
    }
}

#[cfg(test)]
mod tests;
