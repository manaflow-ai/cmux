//! `cmux vault …` (cmux issue 26412): the Chief vault, named secrets the person hands cmux that
//! agents use without seeing them. The cmux app owns the vault (its values live in the app's
//! Keychain items, which only the signed app reads); this command only talks to the app's control
//! socket (`vault.*`, VaultControl.swift).
//!
//! - `set NAME [--scope user|agents|user,agents] [--note TEXT]`: the value comes from a no-echo
//!   prompt or stdin, never argv, and is never printed. The person only: an agent is refused.
//! - `ls`, `rm NAME`, `scope NAME user,agents`, `log [--limit N]`.
//! - `request NAME [--reason TEXT]`: asks the person on a cmux sheet to enter the value (the
//!   Chief's way to get a credential; the answer never holds it).
//! - `exec --env VAR[=NAME]... [--no-mask] -- COMMAND [ARGS...]`: runs COMMAND with the secrets in
//!   its environment. Its output is masked: every secret value it prints shows as
//!   `[vault:NAME]`, so an agent reading the output never sees one. `--no-mask` (the person only)
//!   passes the output through untouched.
//!
//! Masking guards against accidents (a tool that prints its own token into an agent's context);
//! it is not a boundary: a command that has a value can write it elsewhere or transform it. The
//! boundary is the scope: an agent gets no value of a secret kept for the person. The socket
//! cannot tell the person's `cmux` from an agent's (the `caller` this command sends can only
//! narrow it), so the app asks the person on a native sheet before a use of a secret kept for
//! them and before every `set`, `rm` and `scope` (`CredentialVault+Approval.swift`).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use acpmux::cli::harness_secret::read_value;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

const USAGE: &str = "usage: cmux vault set NAME [--scope user|agents|user,agents] [--note TEXT] (value on stdin or a hidden prompt)\n       cmux vault ls | rm NAME | scope NAME user,agents | log [--limit N]\n       cmux vault request NAME [--reason TEXT]\n       cmux vault exec --env VAR[=NAME] [--env ...] [--no-mask] -- COMMAND [ARGS...]";

const READ_TIMEOUT: Duration = Duration::from_secs(15);
/// The person answers a sheet (a value to type, or an approval of a write or of a use of a secret
/// kept for them): the app ends a lost one after 600 s.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(610);

/// `Some(exit code)` when `args` is `vault …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [vault, rest @ ..] = command_args.as_slice() else { return None };
    if vault != "vault" {
        return None;
    }
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    Some(run(&global, command))
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Command {
    Help,
    Set { name: String, scope: Option<String>, note: Option<String> },
    Ls,
    Rm { name: String },
    Scope { name: String, scope: String },
    Log { limit: u32 },
    Request { name: String, reason: Option<String> },
    Exec { env: Vec<(String, String)>, mask: bool, argv: Vec<String> },
}

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let Some((verb, rest)) = args.split_first() else { return Ok(Command::Help) };
    match verb.as_str() {
        "help" | "--help" | "-h" => Ok(Command::Help),
        "ls" | "list" if rest.is_empty() => Ok(Command::Ls),
        "rm" | "remove" => match rest {
            [name] => Ok(Command::Rm { name: valid_name(name)? }),
            _ => Err(usage()),
        },
        "scope" => match rest {
            [name, scope] => {
                Ok(Command::Scope { name: valid_name(name)?, scope: valid_scope(scope)? })
            }
            _ => Err(usage()),
        },
        "set" => {
            let (name, options) = rest.split_first().ok_or_else(usage)?;
            let options = options_of(options, &["--scope", "--note"])?;
            let scope = options
                .iter()
                .find(|(k, _)| k == "--scope")
                .map(|(_, v)| valid_scope(v))
                .transpose()?;
            let note = options.iter().find(|(k, _)| k == "--note").map(|(_, v)| v.clone());
            Ok(Command::Set { name: valid_name(name)?, scope, note })
        }
        "request" => {
            let (name, options) = rest.split_first().ok_or_else(usage)?;
            let options = options_of(options, &["--reason"])?;
            Ok(Command::Request {
                name: valid_name(name)?,
                reason: options.into_iter().find(|(k, _)| k == "--reason").map(|(_, v)| v),
            })
        }
        "log" => {
            let options = options_of(rest, &["--limit"])?;
            let limit = match options.iter().find(|(k, _)| k == "--limit") {
                Some((_, v)) => {
                    v.parse::<u32>().ok().filter(|n| (1..=1000).contains(n)).ok_or_else(|| {
                        UsageError::new(format!("--limit {v:?}: expected a number from 1 to 1000"))
                    })?
                }
                None => 50,
            };
            Ok(Command::Log { limit })
        }
        "exec" => parse_exec(rest),
        _ => Err(usage()),
    }
}

fn parse_exec(args: &[String]) -> Result<Command, UsageError> {
    let mut parts = args.splitn(2, |a| a == "--");
    let flags = parts.next().unwrap_or_default();
    let argv = parts.next().ok_or_else(|| {
        UsageError::new(
            "cmux vault exec needs `--` before the command: cmux vault exec --env NAME -- COMMAND",
        )
    })?;
    if argv.is_empty() {
        return Err(UsageError::new("cmux vault exec: no command after `--`"));
    }
    let mut env = Vec::new();
    let mut mask = true;
    let mut flags = flags.iter();
    while let Some(flag) = flags.next() {
        let flag = flag.as_str();
        let spec = if flag == "--env" {
            flags.next().cloned().ok_or_else(|| UsageError::new("--env needs VAR or VAR=NAME"))?
        } else if let Some(spec) = flag.strip_prefix("--env=") {
            spec.to_owned()
        } else if flag == "--no-mask" {
            mask = false;
            continue;
        } else {
            return Err(UsageError::new(format!("cmux vault exec: unknown option {flag:?}")));
        };
        let (var, name) = spec.split_once('=').unwrap_or((spec.as_str(), spec.as_str()));
        let var = valid_env_var(var)?;
        let name = valid_name(name)?;
        if env.iter().any(|(v, _): &(String, String)| *v == var) {
            return Err(UsageError::new(format!("--env {var} is given twice")));
        }
        env.push((var, name));
    }
    if env.is_empty() {
        return Err(UsageError::new("cmux vault exec needs at least one --env VAR[=NAME]"));
    }
    Ok(Command::Exec { env, mask, argv: argv.to_vec() })
}

/// `--key value` / `--key=value` pairs, each key at most once, from `allowed`.
fn options_of(args: &[String], allowed: &[&str]) -> Result<Vec<(String, String)>, UsageError> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let (key, value) = match arg.split_once('=') {
            Some((key, value)) if allowed.contains(&key) => (key.to_owned(), value.to_owned()),
            _ if allowed.contains(&arg.as_str()) => {
                let value =
                    args.next().ok_or_else(|| UsageError::new(format!("{arg} needs a value")))?;
                (arg.clone(), value.clone())
            }
            _ => return Err(UsageError::new(format!("unexpected {arg:?}\n{USAGE}"))),
        };
        if out.iter().any(|(k, _)| *k == key) {
            return Err(UsageError::new(format!("{key} is given twice")));
        }
        out.push((key, value));
    }
    Ok(out)
}

/// The app's name rule (`CredentialVault.isValidName`): `[A-Za-z_][A-Za-z0-9_]*`, at most 128.
fn valid_name(name: &str) -> Result<String, UsageError> {
    let ok = (1..=128).contains(&name.len())
        && name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if ok {
        Ok(name.to_owned())
    } else {
        Err(UsageError::new(format!(
            "{name:?} is not a vault name: letters, digits and _, not starting with a digit"
        )))
    }
}

/// Variables that steer what a process loads or runs (the loader, shells, interpreters, git's and
/// ssh's helpers): a secret never fills one.
const RESERVED_ENV: &[&str] = &[
    "PATH",
    "HOME",
    "SHELL",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "IFS",
    "ENV",
    "BASH_ENV",
    "PWD",
    "TERM",
    "ZDOTDIR",
    "PS4",
    "PROMPT_COMMAND",
    "NODE_OPTIONS",
    "NODE_PATH",
    "PERL5OPT",
    "PERL5LIB",
    "PERLLIB",
    "RUBYOPT",
    "RUBYLIB",
    "SSH_ASKPASS",
    "SUDO_ASKPASS",
    "EDITOR",
    "VISUAL",
    "PAGER",
    "BROWSER",
];
const RESERVED_ENV_PREFIXES: &[&str] =
    &["DYLD_", "LD_", "CMUX_", "BASH_FUNC_", "PYTHON", "GIT_", "LESS"];

/// An env variable a secret may fill: a vault name that the loader, the shell or cmux does not
/// own, so a secret never redirects what runs (`PATH`, `DYLD_*`) or which cmux it talks to.
fn valid_env_var(var: &str) -> Result<String, UsageError> {
    let var = valid_name(var)?;
    let upper = var.to_ascii_uppercase();
    let reserved = RESERVED_ENV.contains(&upper.as_str())
        || RESERVED_ENV_PREFIXES.iter().any(|p| upper.starts_with(p));
    if reserved {
        return Err(UsageError::new(format!("{var} is not an env variable a secret may fill")));
    }
    Ok(var)
}

fn valid_scope(scope: &str) -> Result<String, UsageError> {
    let words: Vec<&str> = scope.split(',').map(str::trim).collect();
    if words.is_empty() || !words.iter().all(|w| *w == "user" || *w == "agents") {
        return Err(UsageError::new(format!(
            "scope {scope:?}: expected user, agents or user,agents"
        )));
    }
    Ok(words.join(","))
}

/// Who calls, as the app's other caller-aware methods hear it (an agent session or a Chief turn
/// is an agent).
fn caller() -> Option<Value> {
    super::app::caller_from(|key| std::env::var(key).ok())
}

fn caller_is_agent(caller: &Option<Value>) -> bool {
    caller
        .as_ref()
        .is_some_and(|c| c.get("agent_session").is_some() || c.get("home_chat").is_some())
}

fn with_caller(mut params: Value) -> Value {
    if let (Some(object), Some(caller)) = (params.as_object_mut(), caller()) {
        object.insert("caller".into(), caller);
    }
    params
}

fn connect(global: &GlobalArgs) -> Result<UnixStream, i32> {
    super::app::connect_command(global)
        .map_err(|error| super::wire::print_local_error(&error, global.output, 1))
}

/// One vault request; Ok(the result) or the printed error's exit code.
fn call(global: &GlobalArgs, method: &str, params: Value, timeout: Duration) -> Result<Value, i32> {
    let mut stream = connect(global)?;
    match super::app::request(&mut stream, method, with_caller(params), timeout) {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(error)) => Err(super::wire::print_local_error(&error, global.output, 1)),
        Err(message) => {
            Err(super::app::failure("app.transport", &format!("cmux: {message}"), global.output, 1))
        }
    }
}

fn run(global: &GlobalArgs, command: Command) -> i32 {
    let output = global.output;
    let done = |result: Result<Value, i32>| match result {
        Ok(value) => super::wire::print_local_success(&value, output),
        Err(code) => code,
    };
    match command {
        Command::Help => {
            println!("{USAGE}");
            0
        }
        Command::Ls => match call(global, "vault.list", json!({}), READ_TIMEOUT) {
            Ok(value) if output == OutputMode::Human => print_list(&value),
            other => done(other),
        },
        Command::Rm { name } => {
            done(call(global, "vault.remove", json!({ "name": name }), REQUEST_TIMEOUT))
        }
        Command::Scope { name, scope } => done(call(
            global,
            "vault.scope",
            json!({ "name": name, "scope": scope }),
            REQUEST_TIMEOUT,
        )),
        Command::Log { limit } => {
            done(call(global, "vault.audit", json!({ "limit": limit }), READ_TIMEOUT))
        }
        Command::Set { name, scope, note } => {
            // Before the prompt: nobody types a secret an agent caller could not store.
            if caller_is_agent(&caller()) {
                return super::app::failure(
                    "vault.user_only",
                    &format!(
                        "cmux: only the person adds vault secrets; ask them with `cmux vault request {name}`"
                    ),
                    output,
                    1,
                );
            }
            let value = match read_value(&name) {
                Ok(value) => value,
                Err(error) => {
                    return super::app::failure(
                        "vault.input",
                        &format!("cmux: {error}"),
                        output,
                        1,
                    );
                }
            };
            let mut params = serde_json::Map::from_iter([
                ("name".into(), json!(name)),
                ("value".into(), json!(value.as_str())),
            ]);
            drop(value);
            if let Some(scope) = scope {
                params.insert("scope".into(), json!(scope));
            }
            if let Some(note) = note {
                params.insert("note".into(), json!(note));
            }
            let result = call(global, "vault.set", Value::Object(params), REQUEST_TIMEOUT);
            done(result)
        }
        Command::Request { name, reason } => {
            if output == OutputMode::Human {
                eprintln!("Waiting for the person to enter {name} in cmux…");
            }
            let mut params = serde_json::Map::from_iter([("name".into(), json!(name))]);
            if let Some(reason) = reason {
                params.insert("reason".into(), json!(reason));
            }
            done(call(global, "vault.request", Value::Object(params), REQUEST_TIMEOUT))
        }
        Command::Exec { env, mask, argv } => exec(global, env, mask, argv),
    }
}

fn print_list(value: &Value) -> i32 {
    let rows = value.get("secrets").and_then(Value::as_array).cloned().unwrap_or_default();
    if rows.is_empty() {
        println!("The vault is empty. Add a secret with `cmux vault set NAME`.");
        return 0;
    }
    for row in rows {
        let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
        let scope: Vec<&str> = row
            .get("scope")
            .and_then(Value::as_array)
            .map(|s| s.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let used = match row.get("uses").and_then(Value::as_u64) {
            Some(0) | None => "never used".to_owned(),
            Some(n) => format!("used {n}×, last by {}", text("last_used_by")),
        };
        let note = text("note");
        let note = if note.is_empty() { String::new() } else { format!("  {note}") };
        println!("{}  [{}]  {used}{note}", text("name"), scope.join(","));
    }
    0
}

/// `vault exec`: the values from the app, then the command with them in its environment.
fn exec(global: &GlobalArgs, env: Vec<(String, String)>, mask: bool, argv: Vec<String>) -> i32 {
    let output = global.output;
    let agent = caller_is_agent(&caller());
    if !mask && agent {
        return super::app::failure(
            "vault.user_only",
            "cmux: --no-mask is for the person only; an agent's output stays masked",
            output,
            1,
        );
    }
    let mut names: Vec<&str> = env.iter().map(|(_, name)| name.as_str()).collect();
    names.dedup();
    let params = json!({ "names": names, "command": argv.join(" ") });
    let values = match call(global, "vault.resolve", params, REQUEST_TIMEOUT) {
        Ok(result) => result.get("values").and_then(Value::as_object).cloned().unwrap_or_default(),
        Err(code) => return code,
    };
    let mut secrets: Vec<(String, zeroize::Zeroizing<String>)> = Vec::new();
    for (var, name) in &env {
        let Some(value) = values.get(name).and_then(Value::as_str) else {
            return super::app::failure(
                "vault.missing",
                &format!("cmux: the app sent no value for {name}"),
                output,
                1,
            );
        };
        secrets.push((var.clone(), zeroize::Zeroizing::new(value.to_owned())));
    }
    drop(values);
    let masker = mask.then(|| {
        Masker::new(
            env.iter()
                .zip(&secrets)
                .map(|((_, name), (_, value))| (value.as_bytes().to_vec(), name.clone()))
                .collect(),
        )
    });
    let Some((program, arguments)) = argv.split_first() else {
        return super::app::failure("vault.exec", "cmux: no command after `--`", output, 2);
    };
    let mut command = cmux_process::Command::new(program);
    command.args(arguments).stdin(cmux_process::Stdio::inherit());
    for (var, value) in &secrets {
        command.env(var, value.as_str());
    }
    if masker.is_some() {
        command.stdout(cmux_process::Stdio::piped()).stderr(cmux_process::Stdio::piped());
    } else {
        command.stdout(cmux_process::Stdio::inherit()).stderr(cmux_process::Stdio::inherit());
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return super::app::failure(
                "vault.exec",
                &format!("cmux: cannot run {program}: {error}"),
                output,
                127,
            );
        }
    };
    drop(command);
    drop(secrets);
    let pumps = masker.map(|masker| {
        let out = child.stdout.take().map(|pipe| pump(pipe, masker.clone(), std::io::stdout()));
        let err = child.stderr.take().map(|pipe| pump(pipe, masker, std::io::stderr()));
        (out, err)
    });
    let status = child.wait();
    if let Some((out, err)) = pumps {
        for handle in [out, err].into_iter().flatten() {
            let _ = handle.join();
        }
    }
    match status {
        Ok(status) => exit_code(status),
        Err(error) => super::app::failure("vault.exec", &format!("cmux: {error}"), output, 1),
    }
}

fn exit_code(status: cmux_process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt as _;
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// Copies `input` to `output` through `masker` on its own thread.
fn pump(
    mut input: impl Read + Send + 'static,
    mut masker: Masker,
    mut output: impl Write + Send + 'static,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut buffer = [0u8; 16 * 1024];
        loop {
            match input.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    let Some(bytes) = buffer.get(..n) else { break };
                    let shown = masker.push(bytes);
                    if output.write_all(&shown).and_then(|()| output.flush()).is_err() {
                        break;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        let _ = output.write_all(&masker.finish());
        let _ = output.flush();
    })
}

/// Replaces every occurrence of a secret value in a byte stream with `[vault:NAME]`, across read
/// boundaries: bytes that may start a value wait for the next read (at most the longest value).
/// Values shorter than 4 bytes are not masked (they would garble ordinary output). Output that ends
/// in what could start a value waits for the next read or the end, even a prompt: showing it at
/// once would show the start of a value split across two writes.
#[derive(Clone)]
pub(super) struct Masker {
    secrets: Vec<(Vec<u8>, String)>,
    pending: Vec<u8>,
}

impl Masker {
    pub(super) fn new(secrets: Vec<(Vec<u8>, String)>) -> Self {
        let mut secrets: Vec<(Vec<u8>, String)> =
            secrets.into_iter().filter(|(value, _)| value.len() >= 4).collect();
        // The longest first: a value that contains another is replaced whole.
        secrets.sort_by_key(|(value, _)| std::cmp::Reverse(value.len()));
        Self { secrets, pending: Vec::new() }
    }

    pub(super) fn push(&mut self, bytes: &[u8]) -> Vec<u8> {
        self.pending.extend_from_slice(bytes);
        self.drain(false)
    }

    pub(super) fn finish(&mut self) -> Vec<u8> {
        self.drain(true)
    }

    fn drain(&mut self, end: bool) -> Vec<u8> {
        let data = std::mem::take(&mut self.pending);
        let mut out = Vec::with_capacity(data.len());
        let mut rest = data.as_slice();
        'scan: while let Some((byte, tail)) = rest.split_first() {
            // The tail may be the start of a value the next read completes: wait for it before
            // taking any match, so a shorter value never wins over a longer one that starts the
            // same way (that would show the longer one's tail).
            if !end
                && self
                    .secrets
                    .iter()
                    .any(|(value, _)| rest.len() < value.len() && value.starts_with(rest))
            {
                self.pending = rest.to_vec();
                break;
            }
            for (value, name) in &self.secrets {
                if let Some(tail) = rest.strip_prefix(value.as_slice()) {
                    out.extend_from_slice(format!("[vault:{name}]").as_bytes());
                    rest = tail;
                    continue 'scan;
                }
            }
            out.push(*byte);
            rest = tail;
        }
        // The copy of the input goes; only masked text leaves.
        let mut data = data;
        zeroize::Zeroize::zeroize(&mut data);
        out
    }
}

impl Drop for Masker {
    fn drop(&mut self) {
        for (value, _) in &mut self.secrets {
            zeroize::Zeroize::zeroize(value);
        }
        zeroize::Zeroize::zeroize(&mut self.pending);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn a_value_never_comes_from_argv_and_names_follow_the_apps_rule() {
        assert_eq!(
            parse(&words("set OPENAI_API_KEY --scope agents --note work")),
            Ok(Command::Set {
                name: "OPENAI_API_KEY".into(),
                scope: Some("agents".into()),
                note: Some("work".into())
            })
        );
        assert!(
            parse(&words("set OPENAI_API_KEY sk-live-123")).is_err(),
            "a value on the command line"
        );
        assert!(parse(&words("set 1BAD")).is_err());
        assert!(parse(&words("set A-B")).is_err());
        assert!(parse(&words("set KEY --scope everyone")).is_err());
        assert_eq!(parse(&words("ls")), Ok(Command::Ls));
        assert_eq!(parse(&words("rm KEY")), Ok(Command::Rm { name: "KEY".into() }));
        assert_eq!(
            parse(&words("scope KEY user,agents")),
            Ok(Command::Scope { name: "KEY".into(), scope: "user,agents".into() })
        );
        assert_eq!(parse(&words("log --limit 5")), Ok(Command::Log { limit: 5 }));
        assert!(parse(&words("log --limit 0")).is_err());
        assert_eq!(
            parse(&["request".into(), "GH_TOKEN".into(), "--reason".into(), "open the PR".into()]),
            Ok(Command::Request { name: "GH_TOKEN".into(), reason: Some("open the PR".into()) })
        );
    }

    #[test]
    fn exec_maps_env_variables_to_names_and_refuses_the_ones_that_steer_a_process() {
        assert_eq!(
            parse(&words(
                "exec --env GH_TOKEN --env OPENAI_API_KEY=WORK_OPENAI -- gh pr list --json"
            )),
            Ok(Command::Exec {
                env: vec![
                    ("GH_TOKEN".into(), "GH_TOKEN".into()),
                    ("OPENAI_API_KEY".into(), "WORK_OPENAI".into())
                ],
                mask: true,
                argv: words("gh pr list --json"),
            })
        );
        assert!(matches!(
            parse(&words("exec --env=K --no-mask -- env")),
            Ok(Command::Exec { mask: false, .. })
        ));
        for bad in [
            "exec --env K",
            "exec --env K --",
            "exec -- env",
            "exec --env PATH=K -- env",
            "exec --env DYLD_INSERT_LIBRARIES=K -- env",
            "exec --env CMUX_SOCKET_PATH=K -- env",
            "exec --env NODE_OPTIONS=K -- env",
            "exec --env PYTHONSTARTUP=K -- env",
            "exec --env GIT_SSH_COMMAND=K -- env",
            "exec --env PROMPT_COMMAND=K -- env",
            "exec --env K --env K=L -- env",
            "exec --bogus -- env",
        ] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn exec_no_mask_preserves_child_arguments_through_global_parsing() {
        let (global, args) = super::super::parse_globals(&words(
            "vault exec --env K --no-mask -- echo --json --socket /child.sock",
        ))
        .unwrap();
        assert_eq!(global.output, OutputMode::Human);
        assert_eq!(global.socket, None);
        assert_eq!(
            parse(&args[1..]),
            Ok(Command::Exec {
                env: vec![("K".into(), "K".into())],
                mask: false,
                argv: words("echo --json --socket /child.sock"),
            })
        );
    }

    fn mask_in_chunks(secrets: &[(&str, &str)], input: &str, chunk: usize) -> String {
        let mut masker = Masker::new(
            secrets.iter().map(|(v, n)| (v.as_bytes().to_vec(), (*n).to_owned())).collect(),
        );
        let mut out = Vec::new();
        for piece in input.as_bytes().chunks(chunk) {
            out.extend(masker.push(piece));
        }
        out.extend(masker.finish());
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn output_never_shows_a_value_whatever_the_read_boundaries() {
        let secrets = [("sk-live-abcdef123456", "OPENAI"), ("ghp_0123456789", "GH")];
        let input =
            "token=sk-live-abcdef123456\nother ghp_0123456789ghp_0123456789 end sk-live-abc";
        let want = "token=[vault:OPENAI]\nother [vault:GH][vault:GH] end sk-live-abc";
        for chunk in 1..=input.len() {
            assert_eq!(mask_in_chunks(&secrets, input, chunk), want, "chunk {chunk}");
        }
    }

    #[test]
    fn the_longest_value_wins_and_short_values_are_left_alone() {
        let input = "xabcdefghx abcdx abcdefg";
        for chunk in 1..=input.len() {
            assert_eq!(
                mask_in_chunks(&[("abcd", "A"), ("abcdefgh", "B")], input, chunk),
                "x[vault:B]x [vault:A]x [vault:A]efg",
                "chunk {chunk}"
            );
        }
        // The reads that showed the longer value's tail before: `ab`, `cde`, `fgh`.
        let mut masker =
            Masker::new(vec![(b"abcd".to_vec(), "A".into()), (b"abcdefgh".to_vec(), "B".into())]);
        let mut out = Vec::new();
        for piece in ["ab", "cde", "fgh"] {
            out.extend(masker.push(piece.as_bytes()));
        }
        out.extend(masker.finish());
        assert_eq!(String::from_utf8(out).unwrap(), "[vault:B]");
        assert_eq!(
            mask_in_chunks(&[("abc", "S")], "abc abc", 2),
            "abc abc",
            "under 4 bytes is not masked"
        );
    }
}
