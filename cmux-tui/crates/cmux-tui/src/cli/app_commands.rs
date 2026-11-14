//! `cmux <cli.name> <path…> [args]`: an installed app's own command
//! (plans/cmux-next/app-commands-codemode.md section 1). The mux grammar
//! goes first, so an app never shadows a built-in command: only words the
//! grammar refused reach here, and only a first word that is not a reserved
//! cmux word (`cli-reserved.json`, which the manifest validator also
//! enforces). The daemon resolves the name and the `cli.path`
//! (`apps-cli`, cmux-tui-core apps/cli_commands.rs); the arguments are
//! built from the op's input schema here and the op runs through
//! `apps-run`, the path `cmux apps run` takes, with the same grants,
//! hidden-app access, Ctrl-C cancel and output.
//!
//! Arguments: each top-level input property is `--kebab-name VALUE` (or
//! `--name=VALUE`); a boolean is `--x` or `--no-x`; an array repeats its
//! flag; an object takes JSON; `cli.positional` names the properties that
//! plain words fill, in order (an array last takes the rest); `--args JSON`
//! gives the whole object. Required properties are checked before the run.

mod messages;
#[cfg(test)]
mod tests;

use serde_json::{Map, Value, json};

use self::messages::messages;
use super::apps_run::{self, AppOp};
use super::{GlobalArgs, OutputMode};

/// `apps-cli` refusals that mean an installed app owns the name.
const APP_REFUSALS: &[&str] = &["apps.cli.conflict", "apps.cli.path_unknown", "apps.disabled"];

/// Runs `args` as an app command when the daemon knows an installed app by
/// its first word; `None` leaves the words to the usage error.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (name, words) = command_args.split_first()?;
    if name.starts_with('-') || cmux_app_manifest::is_reserved_cli_name(name) {
        return None;
    }
    let request = json!({ "id": "apps-cli-1", "cmd": "apps-cli", "name": name, "words": words });
    let resolved = match super::remote_host::daemon_value(&global, &request) {
        Ok(resolved) => resolved,
        // An app took the name but can't run these words.
        Err(error) if APP_REFUSALS.contains(&error["code"].as_str().unwrap_or_default()) => {
            return Some(refuse(name, &error, global.output));
        }
        // No daemon, no app host, an older daemon or no app by that name:
        // not an app command, so the usage error stands.
        Err(_) => return None,
    };
    Some(run(&global, name, words, &resolved))
}

fn run(global: &GlobalArgs, name: &str, words: &[String], resolved: &Value) -> i32 {
    let Some(op) = resolved["op"].as_str() else {
        println!("{}", app_help(name, resolved));
        return 0;
    };
    let consumed = resolved["consumed"].as_u64().unwrap_or(0) as usize;
    let rest = words.get(consumed..).unwrap_or_default();
    if rest.iter().any(|word| matches!(word.as_str(), "--help" | "-h")) {
        println!("{}", op_help(name, resolved));
        return 0;
    }
    let args = match build_args(rest, &resolved["input"], &resolved["positional"]) {
        Ok(args) => args,
        Err(message) => {
            eprintln!("cmux: {message}\n\n{}", op_help(name, resolved));
            return 2;
        }
    };
    let request = AppOp {
        app: resolved["app"].as_str().unwrap_or_default().to_owned(),
        op: op.to_owned(),
        args,
        idempotency_key: global.idempotency_key.clone(),
    };
    let outcome = match apps_run::execute(global, &request) {
        Ok(outcome) => outcome,
        Err(code) => return code,
    };
    let (stdout, stderr, code) = apps_run::report(&outcome, global.output);
    if let Some(text) = stdout {
        println!("{text}");
    }
    if let Some(text) = stderr {
        eprintln!("{text}");
    }
    code
}

/// A refusal from `apps-cli` (conflict, disabled app, unknown command),
/// with the app's command list when the daemon sent one.
fn refuse(name: &str, error: &Value, output: OutputMode) -> i32 {
    let mut message = format!("cmux: {}", error["message"].as_str().unwrap_or_default());
    if error["code"] == "apps.cli.path_unknown" {
        message.push_str(&format!("\n{}", messages().see_help.replace("{name}", name)));
    }
    super::wire::print_local_error(
        &json!({
            "code": error["code"],
            "message": message,
            "details": {},
            "retryable": false,
        }),
        output,
        2,
    )
}

/// `cmux <name>` alone or with `--help`: the app's commands.
pub(super) fn app_help(name: &str, resolved: &Value) -> String {
    let title = resolved["name"].as_str().unwrap_or(name);
    let app = resolved["app"].as_str().unwrap_or_default();
    let mut text = messages()
        .app_usage
        .replace("{name}", name)
        .replace("{title}", title)
        .replace("{app}", app);
    for command in resolved["commands"].as_array().into_iter().flatten() {
        let path = command["path"].as_str().unwrap_or_default();
        let docs = command["docs"].as_str().unwrap_or_default();
        text.push_str(&format!("\n  cmux {name} {path:<20} {docs}"));
    }
    text
}

/// `cmux <name> <path> --help`: the op's docs and arguments.
pub(super) fn op_help(name: &str, resolved: &Value) -> String {
    let path = resolved["path"].as_str().unwrap_or_default();
    let positional: Vec<&str> =
        resolved["positional"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut usage = format!("cmux {name} {path}");
    for property in &positional {
        usage.push_str(&format!(" [{property}]"));
    }
    let mut text = format!(
        "{} {usage} [--args JSON]\n\n  {}",
        messages().usage,
        resolved["docs"].as_str().unwrap_or_default()
    );
    let required = required(&resolved["input"]);
    for (property, schema) in resolved["input"]["properties"].as_object().into_iter().flatten() {
        let kind = schema["type"].as_str().unwrap_or("json");
        let mark = if required.contains(&property.as_str()) { " *" } else { "" };
        let about = schema["description"].as_str().unwrap_or_default();
        text.push_str(&format!("\n  --{:<20} {kind}{mark} {about}", kebab(property)));
    }
    text
}

fn required(input: &Value) -> Vec<&str> {
    input["required"].as_array().into_iter().flatten().filter_map(Value::as_str).collect()
}

/// `fooBar` and `foo_bar` are `foo-bar` on the command line.
fn kebab(property: &str) -> String {
    let mut out = String::new();
    for c in property.chars() {
        if c.is_ascii_uppercase() {
            out.push('-');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(if c == '_' { '-' } else { c });
        }
    }
    out
}

/// The op's arguments from the words after its path.
pub(super) fn build_args(
    words: &[String],
    input: &Value,
    positional: &Value,
) -> Result<Value, String> {
    let properties = input["properties"].as_object().cloned().unwrap_or_default();
    let find = |flag: &str| properties.keys().find(|p| kebab(p) == flag).cloned();
    let mut args = Map::new();
    let mut plain = Vec::new();
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let Some(flag) = word.strip_prefix("--") else {
            plain.push(word.clone());
            continue;
        };
        if flag.is_empty() {
            plain.extend(words.by_ref().cloned());
            break;
        }
        let (flag, inline) = match flag.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (flag, None),
        };
        if flag == "args" {
            let raw = inline.or_else(|| words.next().cloned()).ok_or(messages().args_value)?;
            match serde_json::from_str::<Value>(&raw) {
                Ok(Value::Object(object)) => args.extend(object),
                _ => return Err(messages().args_value.to_owned()),
            }
            continue;
        }
        let negated = flag
            .strip_prefix("no-")
            .and_then(|bare| find(bare))
            .filter(|p| properties[p]["type"] == "boolean");
        if let Some(property) = negated {
            args.insert(property, Value::Bool(false));
            continue;
        }
        let property = find(flag).ok_or_else(|| messages().unknown_flag.replace("{flag}", flag))?;
        let schema = &properties[&property];
        if schema["type"] == "boolean" && inline.is_none() {
            args.insert(property, Value::Bool(true));
            continue;
        }
        let raw = inline
            .or_else(|| words.next().cloned())
            .ok_or_else(|| messages().missing_value.replace("{flag}", flag))?;
        insert(&mut args, &property, schema, &raw)?;
    }
    let names: Vec<&str> =
        positional.as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut plain = plain.into_iter();
    for (index, property) in names.iter().enumerate() {
        let schema = properties.get(*property).cloned().unwrap_or(Value::Null);
        let last = index + 1 == names.len();
        if last && schema["type"] == "array" {
            for raw in plain.by_ref() {
                insert(&mut args, property, &schema, &raw)?;
            }
        } else if let Some(raw) = plain.next() {
            insert(&mut args, property, &schema, &raw)?;
        }
    }
    if let Some(extra) = plain.next() {
        return Err(messages().extra_word.replace("{word}", &extra));
    }
    let missing: Vec<String> = required(input)
        .into_iter()
        .filter(|property| !args.contains_key(*property))
        .map(|property| format!("--{}", kebab(property)))
        .collect();
    if !missing.is_empty() {
        return Err(messages().missing_required.replace("{flags}", &missing.join(", ")));
    }
    Ok(Value::Object(args))
}

/// Adds one value for `property`: an array collects, anything else is set.
fn insert(
    args: &mut Map<String, Value>,
    property: &str,
    schema: &Value,
    raw: &str,
) -> Result<(), String> {
    if schema["type"] == "array" {
        let item = typed(&schema["items"], raw, property)?;
        match args.entry(property.to_owned()).or_insert_with(|| json!([])) {
            Value::Array(items) => items.push(item),
            other => *other = json!([item]),
        }
        return Ok(());
    }
    args.insert(property.to_owned(), typed(schema, raw, property)?);
    Ok(())
}

/// `raw` as the schema's type; an untyped or object value is JSON when it
/// parses, else a string.
fn typed(schema: &Value, raw: &str, property: &str) -> Result<Value, String> {
    let bad = || messages().bad_value.replace("{flag}", &kebab(property)).replace("{value}", raw);
    let value = match schema["type"].as_str() {
        Some("string") => Value::String(raw.to_owned()),
        Some("integer") => json!(raw.parse::<i64>().map_err(|_| bad())?),
        Some("number") => json!(raw.parse::<f64>().map_err(|_| bad())?),
        Some("boolean") => json!(raw.parse::<bool>().map_err(|_| bad())?),
        Some("object") => serde_json::from_str(raw).map_err(|_| bad())?,
        _ => serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_owned())),
    };
    if let Some(choices) = schema["enum"].as_array()
        && !choices.contains(&value)
    {
        return Err(bad());
    }
    Ok(value)
}

/// Words the mux grammar refused: an installed app's command first, then
/// the app action with that CLI name.
pub(super) fn unknown_words(args: &[String]) -> Option<i32> {
    run_if_requested(args).or_else(|| run_app_action_fallback(args))
}

/// Runs `<noun> <verb…> [--flags]` as the app action with that CLI name when
/// the app marks one for the CLI. `None` when it does not, or no app answers.
pub(super) fn run_app_action_fallback(args: &[String]) -> Option<i32> {
    use super::{action_hint, agent_view, app, share_cli, wire};
    let (mut global, command_args) = super::parse_action_globals(args).ok()?;
    if let Some((name, action_args)) = agent_view::action(&command_args) {
        return app::run_cli_action(&global, &name, &action_args);
    }
    match share_cli::action(&command_args) {
        Some(Ok((name, mut action_args))) => {
            for switch in share_cli::take_output_switches(&mut action_args) {
                let output = match switch.as_str() {
                    "--json" => OutputMode::Json,
                    "--jsonl" => OutputMode::JsonLines,
                    _ => OutputMode::Quiet,
                };
                if let Err(error) = super::set_output_mode(&mut global, output, &switch) {
                    let error = json!({"code": "usage.invalid", "message": error.0,
                        "details": {}, "retryable": false});
                    return Some(wire::print_local_error(&error, global.output, 2));
                }
            }
            return app::run_cli_action(&global, &name, &action_args);
        }
        Some(Err(message)) => {
            let error = json!({"code": "usage.invalid", "message": message, "details": {}, "retryable": false});
            return Some(wire::print_local_error(&error, global.output, 2));
        }
        None => {}
    }
    let words = command_args.iter().take_while(|arg| !arg.starts_with('-')).count();
    if words < 2 {
        return None;
    }
    let name = command_args[..words].join(" ");
    // `<noun> move-to-window --new` is `<noun> move-to-new-window`.
    let (name, rest) = app::new_window_spelling(&name, &command_args[words..])
        .unwrap_or_else(|| (name, command_args[words..].to_vec()));
    app::run_cli_action(&global, &name, &rest).or_else(|| action_hint::report(&name, global.output))
}
