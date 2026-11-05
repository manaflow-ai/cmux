//! `cmux cloud chat send|status|last` and `cmux cloud computer <op>|control …`: the `cloud_*`
//! MCP tools (mcp/cloud_tools.rs) as commands. The words become the tool's arguments and the
//! tool's own code runs, so a command and its tool never differ.

use std::io::Read as _;

use base64::Engine as _;
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// Flags of `cloud computer` and the tool argument each sets; the integer ones parse as numbers.
const COMPUTER_FLAGS: &[(&str, &str, bool)] = &[
    ("--target", "machine", false),
    ("--x", "x", true),
    ("--y", "y", true),
    ("--to-x", "to_x", true),
    ("--to-y", "to_y", true),
    ("--button", "button", false),
    ("--direction", "direction", false),
    ("--amount", "amount", true),
    ("--text", "text", false),
    ("--keys", "keys", false),
    ("--url", "url", false),
];

/// What the words ask for.
#[derive(Debug, PartialEq)]
pub(super) enum Command {
    Help(&'static str),
    /// One tool call; `out` is where a screenshot goes.
    Tool {
        name: &'static str,
        arguments: Map<String, Value>,
        out: Option<String>,
        reply_only: bool,
    },
}

/// `Some(exit code)` when `args` is `cloud chat …` or `cloud computer …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || !matches!(noun.as_str(), "chat" | "computer") {
        return None;
    }
    let output = global.output;
    let parsed = parse(noun, rest, || {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text).map(|_| text).map_err(|e| e.to_string())
    });
    Some(match parsed {
        Ok(Command::Help(usage)) => {
            print!("{usage}");
            0
        }
        Ok(Command::Tool { name, arguments, out, reply_only }) => {
            report(global, name, &arguments, out.as_deref(), reply_only)
        }
        Err(error) => {
            let usage = if noun == "chat" {
                super::cloud_help::CHAT_USAGE
            } else {
                super::cloud_help::COMPUTER_USAGE
            };
            super::app::failure("usage.invalid", &format!("cmux: {}\n{usage}", error.0), output, 2)
        }
    })
}

/// `flag value` pairs (or `--flag=value`) after the verb.
fn pairs(words: &[String]) -> Result<Vec<(String, String)>, UsageError> {
    let mut out = Vec::new();
    let mut index = 0;
    while let Some(word) = words.get(index) {
        let Some(flag) = word.strip_prefix("--").map(|_| word.as_str()) else {
            return Err(UsageError::new(format!("unexpected argument {word:?}")));
        };
        if let Some((flag, value)) = flag.split_once('=') {
            out.push((flag.to_owned(), value.to_owned()));
        } else {
            index += 1;
            let value =
                words.get(index).ok_or_else(|| UsageError::new(format!("{flag} needs a value")))?;
            out.push((flag.to_owned(), value.clone()));
        }
        index += 1;
    }
    Ok(out)
}

fn number(flag: &str, value: &str) -> Result<Value, UsageError> {
    value
        .parse::<u64>()
        .map(|n| json!(n))
        .map_err(|_| UsageError::new(format!("{flag} {value}: give a whole number")))
}

/// The words after `cloud chat` or `cloud computer`. `stdin` reads `--prompt -`.
pub(super) fn parse(
    noun: &str,
    words: &[String],
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Command, UsageError> {
    let help = |words: &[String]| words.iter().any(|w| matches!(w.as_str(), "-h" | "--help"));
    match noun {
        "chat" => {
            let Some((verb, rest)) = words.split_first() else {
                return Ok(Command::Help(super::cloud_help::CHAT_USAGE));
            };
            if help(words) || verb == "help" {
                return Ok(Command::Help(super::cloud_help::CHAT_USAGE));
            }
            let (name, allowed): (&'static str, &[&str]) = match verb.as_str() {
                "send" => ("cloud_chat_send", &["--target", "--session", "--prompt"]),
                "status" => ("cloud_chat_status", &["--target", "--session", "--after", "--wait"]),
                "last" => ("cloud_chat_status", &["--target", "--session"]),
                other => return Err(UsageError::new(format!("unknown chat verb {other:?}"))),
            };
            let mut arguments = Map::new();
            let mut stdin = Some(stdin);
            for (flag, value) in pairs(rest)? {
                if !allowed.contains(&flag.as_str()) {
                    return Err(UsageError::new(format!("cloud chat {verb} takes no {flag}")));
                }
                let (key, value) = match flag.as_str() {
                    "--target" => ("machine", json!(value)),
                    "--session" => ("session", json!(value)),
                    "--prompt" if value == "-" => {
                        let read =
                            stdin.take().ok_or_else(|| UsageError::new("--prompt - twice"))?;
                        (
                            "prompt",
                            json!(read().map_err(|e| UsageError::new(format!("--prompt -: {e}")))?),
                        )
                    }
                    "--prompt" => ("prompt", json!(value)),
                    "--after" => ("after", number(&flag, &value)?),
                    _ => ("wait_s", number(&flag, &value)?),
                };
                arguments.insert(key.into(), value);
            }
            for (flag, key) in [("--target", "machine"), ("--session", "session")] {
                if !arguments.contains_key(key) {
                    return Err(UsageError::new(format!("cloud chat {verb} needs {flag}")));
                }
            }
            if name == "cloud_chat_send" && !arguments.contains_key("prompt") {
                return Err(UsageError::new("cloud chat send needs --prompt"));
            }
            Ok(Command::Tool { name, arguments, out: None, reply_only: verb == "last" })
        }
        _ => {
            let Some((op, rest)) = words.split_first() else {
                return Ok(Command::Help(super::cloud_help::COMPUTER_USAGE));
            };
            if help(words) || op == "help" {
                return Ok(Command::Help(super::cloud_help::COMPUTER_USAGE));
            }
            if op == "control" {
                let Some((action, rest)) = rest.split_first() else {
                    return Err(UsageError::new("cloud computer control status|request|release"));
                };
                let action = match action.as_str() {
                    "status" => "status",
                    "request" => "request_human",
                    "release" => "hand_back",
                    other => {
                        return Err(UsageError::new(format!(
                            "cloud computer control {other:?}: status, request or release"
                        )));
                    }
                };
                let mut arguments = Map::new();
                arguments.insert("action".into(), json!(action));
                for (flag, value) in pairs(rest)? {
                    match flag.as_str() {
                        "--target" => arguments.insert("machine".into(), json!(value)),
                        "--reason" => arguments.insert("reason".into(), json!(value)),
                        _ => {
                            return Err(UsageError::new(format!(
                                "cloud computer control takes no {flag}"
                            )));
                        }
                    };
                }
                return Ok(Command::Tool {
                    name: "cloud_computer_control",
                    arguments,
                    out: None,
                    reply_only: false,
                });
            }
            let op = op.replace('-', "_");
            let mut arguments = Map::new();
            arguments.insert("op".into(), json!(op));
            let mut out = None;
            for (flag, value) in pairs(rest)? {
                if flag == "--out" && op == "screenshot" {
                    out = Some(value);
                    continue;
                }
                let Some((_, key, integer)) =
                    COMPUTER_FLAGS.iter().find(|(name, ..)| *name == flag)
                else {
                    return Err(UsageError::new(format!("cloud computer takes no {flag}")));
                };
                let value = if *integer { number(&flag, &value)? } else { json!(value) };
                arguments.insert((*key).into(), value);
            }
            Ok(Command::Tool { name: "cloud_computer", arguments, out, reply_only: false })
        }
    }
}

/// Runs the tool and prints its answer; a screenshot goes to `out` (else a new temporary file).
fn report(
    global: GlobalArgs,
    name: &str,
    arguments: &Map<String, Value>,
    out: Option<&str>,
    reply_only: bool,
) -> i32 {
    let output = global.output;
    let result = super::mcp::cloud_tool(global, name, arguments);
    if result.get("isError").and_then(Value::as_bool) == Some(true) {
        let content = result.get("structuredContent").cloned().unwrap_or_default();
        let exit = if content["state"] == "in_progress" { 75 } else { 1 };
        return super::wire::print_local_error(&content["error"], output, exit);
    }
    let image = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|block| block["type"] == "image")
        .and_then(|block| block["data"].as_str());
    if let Some(data) = image {
        let machine = arguments.get("machine").and_then(Value::as_str).unwrap_or("computer");
        let path = out.map(std::path::PathBuf::from).unwrap_or_else(|| {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or_default();
            let safe: String = machine
                .chars()
                .map(|ch| if ch.is_ascii_alphanumeric() || ch == '-' { ch } else { '_' })
                .collect();
            std::env::temp_dir().join(format!("cmux-computer-{safe}-{stamp}.png"))
        });
        let written = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|e| e.to_string())
            .and_then(|bytes| std::fs::write(&path, bytes).map_err(|e| e.to_string()));
        return match written {
            Ok(()) => super::wire::print_local_success(
                &json!({"file": path.display().to_string(), "mime_type": "image/png"}),
                output,
            ),
            Err(error) => super::wire::print_local_error(
                &json!({"code": "computer.write_failed", "message": format!("{}: {error}", path.display())}),
                output,
                1,
            ),
        };
    }
    let answer = result.get("structuredContent").cloned().unwrap_or_default();
    if reply_only && output == OutputMode::Human {
        match answer.get("reply").and_then(Value::as_str) {
            Some(reply) => println!("{}", super::wire::sanitize_remote_text(reply)),
            None => println!(
                "(no reply yet: the turn is {})",
                answer["state"].as_str().unwrap_or("unknown")
            ),
        }
        return 0;
    }
    super::wire::print_local_success(&answer, output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|w| (*w).to_owned()).collect()
    }

    #[test]
    fn chat_and_computer_words_become_the_tools_arguments() {
        let Ok(Command::Tool { name, arguments, .. }) = parse(
            "chat",
            &words(&["send", "--target", "machine:vm-1", "--session", "s-1", "--prompt", "-"]),
            || Ok("from stdin".into()),
        ) else {
            panic!()
        };
        assert_eq!(name, "cloud_chat_send");
        assert_eq!(
            Value::Object(arguments),
            json!({"machine": "machine:vm-1", "session": "s-1", "prompt": "from stdin"})
        );
        let Ok(Command::Tool { name, arguments, .. }) = parse(
            "chat",
            &words(&[
                "status",
                "--target",
                "machine:vm-1",
                "--session",
                "s-1",
                "--wait",
                "20",
                "--after",
                "3",
            ]),
            || Err(String::new()),
        ) else {
            panic!()
        };
        assert_eq!(name, "cloud_chat_status");
        assert_eq!(arguments["wait_s"], 20);
        assert_eq!(arguments["after"], 3);

        let Ok(Command::Tool { name, arguments, out, .. }) = parse(
            "computer",
            &words(&["screenshot", "--target", "machine:vm-1", "--out", "/tmp/s.png"]),
            || Err(String::new()),
        ) else {
            panic!()
        };
        assert_eq!((name, out.as_deref()), ("cloud_computer", Some("/tmp/s.png")));
        assert_eq!(
            Value::Object(arguments),
            json!({"op": "screenshot", "machine": "machine:vm-1"})
        );
        let Ok(Command::Tool { arguments, .. }) = parse(
            "computer",
            &words(&["click", "--x", "10", "--y=20", "--button", "right"]),
            || Err(String::new()),
        ) else {
            panic!()
        };
        assert_eq!(
            Value::Object(arguments),
            json!({"op": "click", "x": 10, "y": 20, "button": "right"})
        );
        let Ok(Command::Tool { name, arguments, .. }) =
            parse("computer", &words(&["control", "request", "--reason", "Sign in"]), || {
                Err(String::new())
            })
        else {
            panic!()
        };
        assert_eq!(name, "cloud_computer_control");
        assert_eq!(
            Value::Object(arguments),
            json!({"action": "request_human", "reason": "Sign in"})
        );

        assert!(
            parse("chat", &words(&["send", "--target", "machine:vm-1"]), || Err(String::new()))
                .is_err()
        );
        assert!(
            parse("computer", &words(&["click", "--x", "ten"]), || Err(String::new())).is_err()
        );
        assert!(matches!(
            parse("computer", &words(&["--help"]), || Err(String::new())),
            Ok(Command::Help(_))
        ));
    }
}
