//! `--json` on a command that streams. `--json` promises one JSON result,
//! and a stream (`session events`, `session journal subscribe`, `terminal
//! attach`, every operation of class `stream_open`) has none: it sends one
//! item per event until it ends or is stopped. So the call is refused before
//! anything connects, with `cli.use_jsonl` and the exact command to run
//! instead, rather than a generic usage error the agent must decode.

use serde_json::json;

use super::OutputMode;

/// The error code of `--json` on a stream.
pub(super) const USE_JSONL: &str = "cli.use_jsonl";

/// `Some(exit 2)`, after printing `cli.use_jsonl`, when `output` is `--json`;
/// `None` lets the stream run (`--jsonl`, `--quiet`, human lines).
pub(super) fn refuse_json(output: OutputMode) -> Option<i32> {
    if output != OutputMode::Json {
        return None;
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = jsonl_command(&args);
    let error = json!({
        "code": USE_JSONL,
        "message": format!(
            "this command streams; use --jsonl (one JSON object per line): {command}"
        ),
        "details": {"command": command},
        "retryable": false,
    });
    Some(super::wire::print_local_error(&error, output, 2))
}

/// `cmux ARGS` with the output switch `--json` as `--jsonl`, one POSIX shell
/// word each. Only the switch the global parser reads changes: a `--json`
/// after `--`, or one that is an option's value (`--regex --json`), is the
/// caller's argument and stays as typed (the same arity as `scan_globals`).
fn jsonl_command(args: &[String]) -> String {
    let mut words = vec!["cmux".to_owned()];
    let mut command: Vec<String> = Vec::new();
    let mut switched = false;
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        index += 1;
        if arg == "--" {
            words.push(shell_word(arg));
            words.extend(args.get(index..).unwrap_or_default().iter().map(|word| shell_word(word)));
            break;
        }
        if arg == "--json" && !switched {
            words.push("--jsonl".to_owned());
            switched = true;
            continue;
        }
        words.push(shell_word(arg));
        command.push(arg.clone());
        if super::option_takes_value(arg)
            && !super::own_switch(&command, arg)
            && let Some(value) = args.get(index)
        {
            words.push(shell_word(value));
            command.push(value.clone());
            index += 1;
        }
    }
    if !switched {
        words.insert(1, "--jsonl".to_owned());
    }
    words.join(" ")
}

fn shell_word(text: &str) -> String {
    if !text.is_empty()
        && text.chars().all(|ch| ch.is_ascii_alphanumeric() || "-_./:@=+,".contains(ch))
    {
        return text.to_owned();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests;
