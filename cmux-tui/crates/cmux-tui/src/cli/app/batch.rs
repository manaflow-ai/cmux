//! `cmux action run -`: app actions read from stdin, sent as ONE `action.batch`
//! request (the app's ControlRouter+ActionBatch): the app validates every op
//! before any runs, runs them in order as one transaction in one main-thread
//! task, and answers once. Stdin holds either one JSON array of `action.run`
//! param objects or one such object per line (`{"action": "newColumn",
//! "target": "pane:...", "args": {...}}`); blank lines are skipped.

use std::io::Read;

use serde_json::{Map, Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT};

/// `cmux action run - [--no-wait] [--no-atomic]` with stdin's ops. `origin`
/// is set on every op that does not name its own.
pub(super) fn parse_batch(
    args: &[String],
    stdin: &mut dyn Read,
    origin: &str,
) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut wait = true;
    let mut atomic = true;
    for arg in args {
        match arg.as_str() {
            "--wait" => wait = true,
            "--no-wait" => wait = false,
            "--no-atomic" => atomic = false,
            _ => {
                return Err(UsageError::new(messages.unexpected_argument.replace("{value}", arg)));
            }
        }
    }
    let mut text = String::new();
    stdin.read_to_string(&mut text).map_err(|error| {
        UsageError::new(messages.action_batch_stdin.replace("{error}", &error.to_string()))
    })?;
    let ops = batch_ops(&text, origin)?;
    let mut params = Map::new();
    params.insert("ops".into(), Value::Array(ops));
    params.insert("wait".into(), json!(wait));
    if !atomic {
        params.insert("atomic".into(), json!(false));
    }
    Ok(AppCommand::Call {
        method: "action.batch",
        params: Value::Object(params),
        timeout: Some(if wait { WAITING_RUN_TIMEOUT } else { READ_TIMEOUT }),
        pick: None,
    })
}

/// The ops of stdin `text`: one JSON array, or one object per non-blank line.
fn batch_ops(text: &str, origin: &str) -> Result<Vec<Value>, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let trimmed = text.trim();
    let ops: Vec<Value> = if trimmed.starts_with('[') {
        serde_json::from_str(trimmed).map_err(|error| {
            UsageError::new(
                messages
                    .action_batch_line
                    .replace("{line}", "1")
                    .replace("{error}", &error.to_string()),
            )
        })?
    } else {
        trimmed
            .lines()
            .enumerate()
            .filter(|(_, line)| !line.trim().is_empty())
            .map(|(index, line)| {
                serde_json::from_str(line).map_err(|error| {
                    UsageError::new(
                        messages
                            .action_batch_line
                            .replace("{line}", &(index + 1).to_string())
                            .replace("{error}", &error.to_string()),
                    )
                })
            })
            .collect::<Result<_, _>>()?
    };
    if ops.is_empty() {
        return Err(UsageError::new(messages.action_batch_empty));
    }
    ops.into_iter()
        .enumerate()
        .map(|(index, op)| {
            let Value::Object(mut members) = op else {
                return Err(UsageError::new(
                    messages
                        .action_batch_line
                        .replace("{line}", &(index + 1).to_string())
                        .replace("{error}", messages.action_batch_not_object),
                ));
            };
            members.entry("origin").or_insert_with(|| json!(origin));
            Ok(Value::Object(members))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{AppCommand, parse_batch};

    fn parse(args: &[&str], stdin: &str) -> Result<AppCommand, String> {
        let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        parse_batch(&args, &mut stdin.as_bytes(), "script").map_err(|error| error.to_string())
    }

    #[test]
    fn json_lines_become_one_batch_request_in_order() {
        let command = parse(
            &[],
            "{\"action\":\"newColumn\",\"target\":\"pane_1\"}\n\n{\"action\":\"renameTab\",\"args\":{\"name\":\"a\"},\"origin\":\"mcp\"}\n",
        )
        .unwrap();
        let AppCommand::Call { method, params, .. } = command else { panic!("not a call") };
        assert_eq!(method, "action.batch");
        assert_eq!(
            params,
            json!({
                "ops": [
                    {"action": "newColumn", "target": "pane_1", "origin": "script"},
                    {"action": "renameTab", "args": {"name": "a"}, "origin": "mcp"},
                ],
                "wait": true,
            })
        );
    }

    #[test]
    fn a_json_array_and_the_flags_are_read() {
        let command = parse(&["--no-wait", "--no-atomic"], "[{\"action\":\"newRow\"}]").unwrap();
        let AppCommand::Call { params, .. } = command else { panic!("not a call") };
        assert_eq!(
            params,
            json!({"ops": [{"action": "newRow", "origin": "script"}], "wait": false, "atomic": false})
        );
    }

    #[test]
    fn empty_stdin_a_bad_line_or_a_non_object_runs_nothing() {
        assert!(parse(&[], " \n").is_err());
        assert!(parse(&[], "{\"action\":\"newRow\"}\nnot json\n").unwrap_err().contains('2'));
        assert!(parse(&[], "[1]").is_err());
        assert!(parse(&["--target"], "{\"action\":\"newRow\"}").is_err());
    }
}
