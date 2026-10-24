//! `cmux action run -`: app actions read from stdin, sent as ONE `action.batch`
//! request (the app's ControlRouter+ActionBatch): the app validates every op
//! before any runs, runs them in order as one transaction in one main-thread
//! task, and answers once. Stdin holds either one JSON array of `action.run`
//! param objects or one such object per line (`{"action": "newColumn",
//! "target": "pane:...", "args": {...}}`); blank lines are skipped.

use std::io::Read;

use serde_json::{Map, Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT};
use crate::localization::AppControlMessages;

/// `cmux action run - [--no-wait] [--split]` with stdin's ops. `origin`
/// is set on every op that does not name its own.
pub(super) fn parse_batch(
    args: &[String],
    stdin: &mut dyn Read,
    origin: &str,
) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut wait = true;
    let mut split = false;
    for arg in args {
        match arg.as_str() {
            "--wait" => wait = true,
            "--no-wait" => wait = false,
            "--split" => split = true,
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
    if split {
        params.insert("split".into(), json!(true));
    }
    Ok(AppCommand::Call {
        method: "action.batch",
        params: Value::Object(params),
        timeout: Some(if wait { WAITING_RUN_TIMEOUT } else { READ_TIMEOUT }),
        pick: None,
    })
}

/// The ops of stdin `text`: one JSON array, or one object per non-blank line.
/// A parse error names its line and column over `text` as given (1-based,
/// blank lines counted); an op that is not an object names its op index
/// (0-based, as the app's `data.op`).
fn batch_ops(text: &str, origin: &str) -> Result<Vec<Value>, UsageError> {
    batch_ops_in(text, origin, &crate::localization::catalog().app_control)
}

fn batch_ops_in(
    text: &str,
    origin: &str,
    messages: &AppControlMessages,
) -> Result<Vec<Value>, UsageError> {
    let parse_error = |line: usize, error: &serde_json::Error| {
        UsageError::new(
            messages
                .action_batch_parse
                .replace("{line}", &line.to_string())
                .replace("{column}", &error.column().to_string())
                .replace("{error}", &without_position(error)),
        )
    };
    let ops: Vec<Value> = if text.trim_start().starts_with('[') {
        // serde_json counts lines and columns over the whole text, leading blank lines too.
        serde_json::from_str(text).map_err(|error| parse_error(error.line(), &error))?
    } else {
        text.lines()
            .enumerate()
            .filter(|(_, line)| !line.trim().is_empty())
            .map(|(index, line)| {
                serde_json::from_str(line).map_err(|error| parse_error(index + 1, &error))
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
                    messages.action_batch_not_object.replace("{op}", &index.to_string()),
                ));
            };
            members.entry("origin").or_insert_with(|| json!(origin));
            Ok(Value::Object(members))
        })
        .collect()
}

/// `error`'s text without serde_json's own " at line L column C": the message
/// names the position over all of stdin, which a per-line parse does not know.
fn without_position(error: &serde_json::Error) -> String {
    let text = error.to_string();
    let position = format!(" at line {} column {}", error.line(), error.column());
    if let Some(message) = text.strip_suffix(&position) {
        return message.to_owned();
    }
    text
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{AppCommand, batch_ops_in, parse_batch};
    use crate::localization::catalog_for_locale;

    /// The English message of `text`'s refusal.
    fn refusal(text: &str) -> String {
        batch_ops_in(text, "script", &catalog_for_locale("en").app_control).unwrap_err().to_string()
    }

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
        let command = parse(&["--no-wait", "--split"], "[{\"action\":\"newRow\"}]").unwrap();
        let AppCommand::Call { params, .. } = command else { panic!("not a call") };
        assert_eq!(
            params,
            json!({"ops": [{"action": "newRow", "origin": "script"}], "wait": false, "split": true})
        );
    }

    #[test]
    fn empty_stdin_a_bad_line_or_a_non_object_runs_nothing() {
        assert!(parse(&[], " \n").is_err());
        assert!(parse(&[], "{\"action\":\"newRow\"}\nnot json\n").unwrap_err().contains('2'));
        assert!(parse(&[], "[1]").is_err());
        assert!(parse(&["--target"], "{\"action\":\"newRow\"}").is_err());
    }

    #[test]
    fn a_bad_json_line_is_named_by_its_line_in_stdin_as_given() {
        let message = refusal("\n\n{\"action\":\"newRow\"}\n\nnot json\n");
        assert!(message.contains("line 5, column "), "{message}");
        assert!(
            !message.contains("at line 1 column"),
            "serde's per-line position leaked: {message}"
        );
    }

    #[test]
    fn a_bad_op_in_an_array_is_named_by_its_own_line_and_column() {
        let message = refusal(
            "\n[{\"action\":\"a\"},\n {\"action\":\"b\"},\n {\"action\":\"c\"},\n {\"action\": }]\n",
        );
        assert!(message.contains("line 5, column "), "{message}");
    }

    #[test]
    fn an_op_that_is_not_an_object_is_named_from_zero_as_the_app_does() {
        let message = refusal("[{\"action\":\"a\"}, {\"action\":\"b\"}, 3]");
        assert!(message.contains("op 2 of stdin"), "{message}");
        let message = refusal("\n{\"action\":\"a\"}\n\n[1]\n");
        assert!(message.contains("op 1 of stdin"), "{message}");
    }
}
