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

/// An account given by id (a UUID, used as is) or by its exact label,
/// masked identifier or id among the team's accounts.
pub(super) fn account_id(selector: &str, accounts: &Value) -> Result<String, String> {
    let messages = &crate::localization::catalog().coderouter;
    let needle = selector.to_lowercase();
    let accounts = accounts.as_array().map(Vec::as_slice).unwrap_or_default();
    let matches = accounts
        .iter()
        .filter(|account| {
            ["label", "identifier", "id"].iter().any(|key| {
                account
                    .get(*key)
                    .and_then(Value::as_str)
                    .is_some_and(|v| v.to_lowercase() == needle)
            })
        })
        .filter_map(|account| account.get("id").and_then(Value::as_str))
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [id] => Ok((*id).to_owned()),
        [] => Err(messages.account_not_found.replace("{account}", selector)),
        many => Err(messages
            .account_ambiguous
            .replace("{account}", selector)
            .replace("{count}", &many.len().to_string())),
    }
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
                let accounts = response.get("accounts").cloned();
                (response, accounts)
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
        Err(Failed::App(error)) => super::wire::print_local_error(&error, global.output, 1),
        Err(Failed::Transport(message)) => {
            super::app::failure("app.transport", &message, global.output, 3)
        }
        Err(Failed::Usage(message)) => {
            super::app::failure("usage.invalid", &message, global.output, 2)
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
    Ok((Value::Object(payload), None))
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
            .map_err(Failed::Usage)?
    };
    let mut params = team_params(team);
    params.insert("accountId".into(), json!(id));
    call(client, params).map(|response| (response, None))
}

enum Failed {
    App(Value),
    Transport(String),
    Usage(String),
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
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    fn parsed(words: &[&str]) -> Result<Invocation, UsageError> {
        let all = args(words);
        let (word, rest) = split(&all).expect("a coderouter command");
        parse(word, rest, &all)
    }

    #[test]
    fn cmux_owns_status_machines_and_claude_and_everything_else_passes_through() {
        assert_eq!(
            parsed(&["coderouter", "status"]).unwrap(),
            Invocation::Owned(Verb::Status { team: None })
        );
        assert_eq!(
            parsed(&["coderouter", "machines", "--team", "t1"]).unwrap(),
            Invocation::Owned(Verb::Machines { team: Some("t1".into()) })
        );
        assert_eq!(
            parsed(&["coderouter", "claude"]).unwrap(),
            Invocation::Owned(Verb::ClaudeList { team: None })
        );
        assert_eq!(parsed(&["coderouter", "--help"]).unwrap(), Invocation::Help);
        assert_eq!(
            parsed(&["coderouter", "login", "--json"]).unwrap(),
            Invocation::Passthrough(args(&["login", "--json"]))
        );
        assert_eq!(parsed(&["coderouter"]).unwrap(), Invocation::Passthrough(vec![]));
        // `cr` is always the CodeRouter CLI, even for cmux's own verbs.
        assert_eq!(
            parsed(&["cr", "status", "--help"]).unwrap(),
            Invocation::Passthrough(args(&["status", "--help"]))
        );
        assert!(split(&args(&["workspace", "list"])).is_none());
    }

    #[test]
    fn passthrough_keeps_arguments_the_global_parser_would_take() {
        let raw = args(&["--app-socket", "/tmp/a.sock", "cr", "--json", "accounts"]);
        assert_eq!(raw_tail(&raw), args(&["--json", "accounts"]));
    }

    #[test]
    fn claude_verbs_take_an_account_and_reject_extra_words() {
        assert_eq!(
            parsed(&["coderouter", "claude", "disable", "work", "--team", "t"]).unwrap(),
            Invocation::Owned(Verb::ClaudeState {
                team: Some("t".into()),
                account: "work".into(),
                enable: false
            })
        );
        assert_eq!(
            parsed(&["coderouter", "claude", "rm", "work"]).unwrap(),
            Invocation::Owned(Verb::ClaudeRemove { team: None, account: "work".into() })
        );
        assert!(parsed(&["coderouter", "claude", "remove"]).is_err());
        assert!(parsed(&["coderouter", "claude", "remove", "a", "b"]).is_err());
        assert!(parsed(&["coderouter", "claude", "clear", "x"]).is_err());
        assert!(parsed(&["coderouter", "claude", "frob"]).is_err());
    }

    #[test]
    fn a_secret_is_never_accepted_on_the_command_line() {
        let error = parsed(&["coderouter", "claude", "add", "oauth-token", "sk-ant-oat01-abc"])
            .expect_err("a token in argv was accepted");
        assert_eq!(error.0, crate::localization::catalog().coderouter.secret_in_argv);
        assert!(parsed(&["coderouter", "claude", "add", "api-key", "--token", "x"]).is_err());
        assert!(parsed(&["coderouter", "claude", "add"]).is_err());
        assert!(parsed(&["coderouter", "claude", "add", "api-key", "--region", "us"]).is_err());
        assert_eq!(
            parsed(&["coderouter", "claude", "add", "bedrock", "--model", "c=b", "--label", "w"])
                .unwrap(),
            Invocation::Owned(Verb::ClaudeAdd {
                team: None,
                label: Some("w".into()),
                credential: Credential::Bedrock {
                    region: None,
                    models: vec![("c".into(), "b".into())]
                },
            })
        );
        assert!(parsed(&["coderouter", "claude", "add", "bedrock", "--model", "c="]).is_err());
    }

    fn with_sources<T>(
        env: &[(&str, &str)],
        stdin_is_terminal: bool,
        stdin: &str,
        typed: &str,
        body: impl FnOnce(&mut SecretSources<'_>) -> T,
    ) -> (T, bool, bool) {
        let env: Vec<(String, String)> =
            env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        let lookup = move |name: &str| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
        let mut stdin_read = false;
        let mut prompted = false;
        let stdin = stdin.to_owned();
        let typed = typed.to_owned();
        let mut read_stdin = || {
            stdin_read = true;
            Ok(stdin.clone())
        };
        let mut prompt_hidden = |_: &str| {
            prompted = true;
            Ok(typed.clone())
        };
        let result = body(&mut SecretSources {
            env: &lookup,
            stdin_is_terminal,
            read_stdin: &mut read_stdin,
            prompt_hidden: &mut prompt_hidden,
        });
        (result, stdin_read, prompted)
    }

    #[test]
    fn secrets_come_from_the_variable_stdin_or_a_hidden_prompt() {
        let token = "sk-ant-oat01-aaaaaaaaaaaaaaaaaaaaaaaa";
        // A terminal with the variable set: the variable, nothing read.
        let (result, read, prompted) = with_sources(&[(OAUTH_ENV, token)], true, "", "", |s| {
            add_params(None, Some("work"), &Credential::OauthToken { stdin: false }, s)
        });
        let params = result.unwrap();
        assert_eq!(params["token"], token);
        assert_eq!(params["kind"], "anthropic_oauth");
        assert_eq!(params["label"], "work");
        assert!(!read && !prompted);
        // --stdin wins over the variable.
        let (result, read, _) =
            with_sources(&[(OAUTH_ENV, "ignored")], true, &format!("\n{token}\n"), "", |s| {
                add_params(Some("t"), None, &Credential::OauthToken { stdin: true }, s)
            });
        let params = result.unwrap();
        assert_eq!((params["token"].as_str(), params["teamId"].as_str()), (Some(token), Some("t")));
        assert!(read);
        // A terminal without the variable prompts with echo off.
        let (result, read, prompted) = with_sources(&[], true, "", "sk-ant-api-key-1", |s| {
            add_params(None, None, &Credential::ApiKey { stdin: false }, s)
        });
        assert_eq!(result.unwrap()["apiKey"], "sk-ant-api-key-1");
        assert!(!read && prompted);
        // Wrong kinds of secret are refused before anything is sent.
        let (result, _, _) = with_sources(&[(API_KEY_ENV, token)], true, "", "", |s| {
            add_params(None, None, &Credential::ApiKey { stdin: false }, s)
        });
        assert!(result.is_err());
        let (result, _, _) = with_sources(&[], false, "\n\n", "", |s| {
            add_params(None, None, &Credential::OauthToken { stdin: false }, s)
        });
        assert!(result.is_err());
    }

    #[test]
    fn bedrock_reads_aws_credentials_from_the_environment() {
        let env = [
            ("AWS_ACCESS_KEY_ID", "AKIA1"),
            ("AWS_SECRET_ACCESS_KEY", "secret"),
            ("AWS_DEFAULT_REGION", "us-west-2"),
        ];
        let credential =
            Credential::Bedrock { region: None, models: vec![("c".into(), "b".into())] };
        let (result, read, prompted) =
            with_sources(&env, true, "", "", |s| add_params(None, None, &credential, s));
        let params = Value::Object(result.unwrap());
        assert_eq!(
            params,
            json!({
                "kind": "bedrock", "region": "us-west-2", "accessKeyId": "AKIA1",
                "secretAccessKey": "secret", "modelIds": {"c": "b"},
            })
        );
        assert!(!read && !prompted);
        let (result, _, _) =
            with_sources(&env[..2], true, "", "", |s| add_params(None, None, &credential, s));
        assert!(result.is_err());
    }

    #[test]
    fn accounts_resolve_by_label_identifier_or_id() {
        let accounts = json!([
            {"id": "a1", "label": "Work", "identifier": "sk-…1"},
            {"id": "a2", "label": "home", "identifier": "sk-…2"},
            {"id": "a3", "label": "home", "identifier": "sk-…3"},
        ]);
        assert_eq!(account_id("work", &accounts).unwrap(), "a1");
        assert_eq!(account_id("sk-…2", &accounts).unwrap(), "a2");
        assert!(account_id("home", &accounts).is_err());
        assert!(account_id("nope", &accounts).is_err());
        assert!(is_uuid("3f2a1b4c-0000-4000-8000-0123456789ab"));
        assert!(!is_uuid("work"));
    }

    #[test]
    fn passthrough_removes_every_cmux_variable_and_keeps_the_rest() {
        let environment = [
            (OsString::from("CMUX_SOCKET_PATH"), OsString::from("/tmp/x")),
            (OsString::from("CMUX_TAG"), OsString::from("t")),
            (OsString::from("HOME"), OsString::from("/home/u")),
        ];
        let command = passthrough_command(
            Path::new("/A.app/Contents/Resources/bin/coderouter"),
            &args(&["login"]),
            environment,
        );
        let envs: Vec<_> = command.get_envs().collect();
        assert_eq!(
            envs,
            vec![
                (std::ffi::OsStr::new("CMUX_SOCKET_PATH"), None),
                (std::ffi::OsStr::new("CMUX_TAG"), None),
            ]
        );
        assert_eq!(command.get_args().collect::<Vec<_>>(), vec![std::ffi::OsStr::new("login")]);
    }

    #[test]
    fn the_bundled_cli_is_found_next_to_the_bundled_cmux() {
        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("cmux DEV.app/Contents/Resources/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("cmux"), b"").unwrap();
        let found = bundled_coderouter(&bin.join("cmux")).unwrap();
        assert!(found.ends_with("cmux DEV.app/Contents/Resources/bin/coderouter"), "{found:?}");
        assert_eq!(bundled_coderouter(Path::new("/usr/local/bin/cmux")), None);
    }

    /// A fake app that answers each line with the next response.
    fn fake_app(responses: Vec<Value>) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir().unwrap().keep();
        let socket = directory.join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut received = Vec::new();
            let mut responses = responses.into_iter();
            let mut line = String::new();
            while reader.read_line(&mut line).unwrap() > 0 {
                received.push(serde_json::from_str::<Value>(&line).unwrap());
                line.clear();
                let Some(response) = responses.next() else { break };
                writeln!(writer, "{response}").unwrap();
            }
            let _ = std::fs::remove_dir_all(directory);
            received
        });
        (socket, handle)
    }

    #[test]
    fn disable_resolves_a_label_then_updates_that_account_on_one_connection() {
        let list = json!({"id": 1, "ok": true, "result": {"accounts": [{"id": "acc-1", "label": "work"}]}});
        let updated = json!({"id": 1, "ok": true, "result": {"ok": true}});
        let (socket, app) = fake_app(vec![list, updated]);
        let global = GlobalArgs {
            app_socket: Some(socket),
            output: OutputMode::Quiet,
            ..GlobalArgs::default()
        };
        let verb =
            Verb::ClaudeState { team: Some("t".into()), account: "work".into(), enable: false };
        assert_eq!(run(&global, Invocation::Owned(verb)), 0);
        let received = app.join().unwrap();
        let methods: Vec<_> = received.iter().map(|r| r["method"].clone()).collect();
        assert_eq!(
            methods,
            vec![
                json!("coderouter.claude_upstream.get"),
                json!("coderouter.claude_upstream.update")
            ]
        );
        assert_eq!(received[1]["params"]["accountId"], "acc-1");
        assert_eq!(received[1]["params"]["state"], "disabled");
        assert_eq!(received[1]["params"]["teamId"], "t");
    }
}
