//! `cmux settings get [PATH] | set PATH VALUE | reset PATH | unset PATH`,
//! the app's `settings.*` control methods (plans/cmux-next/settings-surfaces.md),
//! plus `schema` and `validate`, which read this build's settings
//! schema (`cmux_config::Schema::embedded`). `cmux config` is the same scope
//! (classic cmux's name for it).
//!
//! - `list [--section S] [--keys]`: every schema key with the value that
//!   applies, read from the daemon (`settings.list`); `--keys` prints this
//!   build's key list without a connection (shell completion).
//! - `schema`: the JSON Schema of the settings file, for editors and agents.
//! - `validate [FILE]`: the problems the settings owner would report for the
//!   file (default: the settings file), without the app. Exit 1 when the
//!   file does not parse or a value is refused.
//!
//! A socket write of a user-only key (schema `agent_settable: false`) is
//! refused with `setting_user_only`. `--confirm` sends `confirm: true`: the
//! app then asks the person at the Mac on a native sheet, so the CLI waits
//! with no read deadline (the app bounds the sheet itself). A declined sheet
//! answers `setting_user_only` with `data.declined: true`. Both refusals exit
//! 1, the CLI's code for an op the app refused.

use cmux_config::schema::Accepted;
use cmux_config::{FileRead, Refusal, Schema, State};
use serde_json::{Value, json};

use super::{AppCommand, GlobalArgs, READ_TIMEOUT, UsageError};
use cmux_json::JsonSet as _;

/// The verbs of `cmux settings` (and `cmux config`).
pub(super) const VERBS: &[&str] = &["get", "set", "reset", "unset", "list", "schema", "validate"];

/// A settings verb this module runs itself.
#[derive(Debug, PartialEq)]
pub(crate) enum Command {
    /// An answer this CLI has without the app (`list --keys`, `validate`):
    /// printed as a success, or as an error with exit 1.
    Local(Result<Value, Value>),
    /// A JSON document (`schema`), printed as indented JSON in every output
    /// mode, so `> file` works.
    Document(Value),
}

impl Command {
    /// Local schema, completion and validation need no socket.
    pub(super) fn run(self, global: &GlobalArgs) -> i32 {
        match self {
            Command::Local(Ok(value)) => {
                super::super::wire::print_local_success(&value, global.output)
            }
            Command::Local(Err(error)) => {
                super::super::wire::print_local_error(&error, global.output, 1)
            }
            Command::Document(document) => print_document(&document),
        }
    }
}

fn print_document(document: &Value) -> i32 {
    use std::io::Write as _;
    let text = serde_json::to_string_pretty(document).unwrap_or_default();
    let mut stdout = std::io::stdout().lock();
    match writeln!(stdout, "{text}").and_then(|()| stdout.flush()) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

/// The app's refusal of a user-only key.
const USER_ONLY: &str = "setting_user_only";

/// `rest` starts with the verb (`get`, `set`, `reset`, `unset`).
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.settings_usage);
    let Some((verb, args)) = rest.split_first() else { return Err(usage()) };
    match verb.as_str() {
        "schema" if args.is_empty() => {
            return Ok(AppCommand::Settings(Command::Document(Schema::embedded().json_schema())));
        }
        "validate" => {
            return match args {
                [] => Ok(AppCommand::Settings(Command::Local(validate(
                    &cmux_config::config_path(),
                    false,
                )))),
                [file] if !file.starts_with("--") => Ok(AppCommand::Settings(Command::Local(
                    validate(std::path::Path::new(file), true),
                ))),
                _ => Err(usage()),
            };
        }
        _ => {}
    }
    if verb == "get" {
        return match args {
            [] => Ok(read(json!({}))),
            [path] if !path.starts_with("--") => Ok(read(json!({ "path": path }))),
            _ => Err(usage()),
        };
    }
    // `--` ends the options: every word after it is a path or value.
    let (options, literal) = match args.iter().position(|arg| arg == "--") {
        Some(end) => (&args[..end], &args[end + 1..]),
        None => (args, &[][..]),
    };
    let confirm = options.iter().any(|arg| arg == "--confirm");
    let mut words: Vec<&String> = options.iter().filter(|arg| *arg != "--confirm").collect();
    if let Some(flag) = words.iter().find(|word| word.starts_with("--")) {
        return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
    }
    words.extend(literal);
    let (method, mut params) = match (verb.as_str(), words.as_slice()) {
        ("set", [path, value]) => {
            // A JSON value when it parses as one, else the literal string.
            let value = serde_json::from_str(value).unwrap_or(Value::String((*value).clone()));
            ("settings.set", json!({ "path": path, "value": value }))
        }
        ("reset", [path]) => ("settings.reset", json!({ "path": path })),
        ("unset", [path]) => ("settings.unset", json!({ "path": path })),
        _ => return Err(usage()),
    };
    if confirm {
        params.set("confirm", json!(true));
    }
    // With --confirm a person answers: no client deadline cancels the wait.
    let timeout = if confirm { None } else { Some(READ_TIMEOUT) };
    Ok(AppCommand::Call { method, params, timeout, pick: None })
}

/// The line printed before a `--confirm` wait, so the person knows the
/// sheet is in the app. None for every other request.
pub(super) fn waiting_note(method: &str, params: &Value) -> Option<&'static str> {
    (matches!(method, "settings.set" | "settings.reset" | "settings.unset")
        && params.get("confirm") == Some(&Value::Bool(true)))
    .then(|| crate::localization::catalog().app_control.settings_waiting)
}

fn read(params: Value) -> AppCommand {
    AppCommand::Call { method: "settings.get", params, timeout: Some(READ_TIMEOUT), pick: None }
}

/// Says what to do about a `setting_user_only` refusal of a settings write,
/// in the error's `message` (the human output prints it; JSON keeps `code`
/// and `data`). Without `--confirm`: the app's message, then the rerun hint.
/// A declined sheet: "declined in cmux". The value is never echoed.
pub(super) fn explain_refusal(method: &str, params: &Value, error: &mut Value) {
    if !matches!(method, "settings.set" | "settings.reset" | "settings.unset")
        || error.get("code").and_then(Value::as_str) != Some(USER_ONLY)
    {
        return;
    }
    let messages = &crate::localization::catalog().app_control;
    let confirmed = params.get("confirm") == Some(&Value::Bool(true));
    let declined = error.pointer("/data/declined") == Some(&Value::Bool(true));
    let text = if confirmed && declined {
        messages.settings_declined.to_owned()
    } else if confirmed {
        return;
    } else {
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
        format!("{message}\n{}", messages.settings_confirm_hint)
    };
    error["message"] = json!(text);
}

/// Completion is local; a value listing falls through to the daemon grammar.
pub(super) fn parse_list(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    let options = super::super::command::SettingsList::parse(args)?;
    if !options.keys {
        return Ok(None);
    }
    let mut names: Vec<&str> = Schema::embedded()
        .rows_in(options.section.as_deref())
        .map(|row| row.key.as_str())
        .collect();
    names.sort_unstable();
    Ok(Some(AppCommand::Settings(Command::Local(Ok(json!(names))))))
}

/// The diagnostics the settings owner would report for the file at `path`.
/// A missing settings file (`named`: false) is valid, as the owner reads it:
/// every key has its default. A file the caller names must exist.
pub(super) fn validate(path: &std::path::Path, named: bool) -> Result<Value, Value> {
    let file = path.display().to_string();
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if !named && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(json!({ "file": file, "exists": false, "valid": true, "diagnostics": [] }));
        }
        Err(error) => {
            return Err(json!({
                "code": "settings.unreadable",
                "message": format!("cmux: {file}: {error}"),
                "details": { "file": file },
                "retryable": false,
            }));
        }
    };
    let state = local_state(FileRead::Text(text));
    let snapshot = state.snapshot();
    if snapshot.diagnostics.is_empty() {
        return Ok(json!({ "file": file, "exists": true, "valid": true, "diagnostics": [] }));
    }
    let mut lines = Vec::new();
    let mut diagnostics = Vec::new();
    for diagnostic in &snapshot.diagnostics {
        let accepted = expected(&snapshot.file, &diagnostic.path);
        let mut line = diagnostic.message.clone();
        if let Some(words) = accepted.as_ref().and_then(describe) {
            line = format!("{line}; expected {words}");
        }
        lines.push(line);
        let mut entry = serde_json::to_value(diagnostic).unwrap_or(Value::Null);
        entry.set("accepted", accepted.map_or(Value::Null, |accepted| accepted.to_json()));
        diagnostics.push(entry);
    }
    Err(json!({
        "code": "settings.invalid",
        "message": format!("cmux: {file}\n  {}", lines.join("\n  ")),
        "details": { "file": file, "diagnostics": diagnostics },
        "retryable": false,
    }))
}

/// What the row at `key` accepts, when the file's value there is refused.
fn expected(file: &Value, key: &str) -> Option<Accepted> {
    let row = Schema::embedded().row(key)?;
    let stored = cmux_config::value::value_at(file, &row.path)?;
    match cmux_config::schema::accepts(row, stored, &Default::default()) {
        Err(Refusal::InvalidValue { accepted, .. }) => Some(accepted),
        _ => None,
    }
}

/// `accepted` in words, for a person.
fn describe(accepted: &Accepted) -> Option<String> {
    let number = |x: &f64| x.to_string();
    Some(match accepted {
        Accepted::Choices(choices) => format!("one of {}", choices.join(", ")),
        Accepted::Range { min, max } => format!("a number from {} to {}", number(min), number(max)),
        Accepted::ChoicesOrRange { choices, min, max } => format!(
            "one of {}, or a number from {} to {}",
            choices.join(", "),
            number(min),
            number(max)
        ),
        Accepted::ChoicesOrShape { choices, shape } => {
            format!("one of {}, or {shape}", choices.join(", "))
        }
        Accepted::Shape(shape) => (*shape).to_owned(),
        Accepted::Domain { name, .. } => format!("a {name} name"),
    })
}

/// The owner's state for one file, with no managed layers and no published
/// value domains (theme, font and sound names are checked by shape).
fn local_state(file: FileRead) -> State {
    State::new(
        Schema::embedded(),
        file,
        Default::default(),
        Default::default(),
        Default::default(),
        0,
    )
}
