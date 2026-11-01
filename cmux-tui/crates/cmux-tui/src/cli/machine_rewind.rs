//! Owner whole-machine rewind through the native app's fixed authenticated bridge.
//! Selection and generation fencing stay in Rust; no owner token enters this process.

use serde_json::{Value, json};
use std::time::Duration;

use super::{OutputMode, UsageError};

const USAGE: &str = "usage: cmux machine turns --workspace WS\n       cmux machine rewind --workspace WS --session SESSION --turn TURN [--key KEY] [--generation N]\nRestores memory and disk to the selected turn; the machine must have no running turn.\nRetry an uncertain rewind with the original --key and --generation.";

#[derive(Debug, PartialEq)]
enum Command {
    Help,
    Turns {
        workspace: String,
    },
    Rewind {
        workspace: String,
        session: String,
        turn: String,
        key: Option<String>,
        generation: Option<u64>,
    },
}

fn parse(args: &[String]) -> Option<Result<Command, UsageError>> {
    let [scope, verb, rest @ ..] = args else { return None };
    if scope != "machine" || !matches!(verb.as_str(), "turns" | "rewind") {
        return None;
    }
    Some((|| {
        if rest.iter().any(|value| value == "--help" || value == "-h") {
            return Ok(Command::Help);
        }
        let mut workspace = None;
        let mut session = None;
        let mut turn = None;
        let mut key = None;
        let mut generation = None;
        let mut words = rest.iter();
        while let Some(flag) = words.next() {
            if flag == "--generation" && verb == "rewind" {
                let value = words
                    .next()
                    .and_then(|word| word.parse::<u64>().ok())
                    .filter(|value| *value <= 9_007_199_254_740_991)
                    .ok_or_else(|| {
                        UsageError::new("--generation needs a nonnegative safe integer")
                    })?;
                if generation.replace(value).is_some() {
                    return Err(UsageError::new("repeated --generation"));
                }
                continue;
            }
            let target = match flag.as_str() {
                "--workspace" => &mut workspace,
                "--session" if verb == "rewind" => &mut session,
                "--turn" if verb == "rewind" => &mut turn,
                "--key" if verb == "rewind" => &mut key,
                _ => return Err(UsageError::new(format!("unexpected argument {flag}"))),
            };
            let value =
                words.next().ok_or_else(|| UsageError::new(format!("{flag} needs a value")))?;
            if target.is_some() || !valid_id(value) || (flag == "--key" && value.len() > 128) {
                return Err(UsageError::new(format!("invalid or repeated {flag}")));
            }
            *target = Some(value.to_owned());
        }
        let workspace = workspace.ok_or_else(|| UsageError::new("--workspace is required"))?;
        if verb == "turns" {
            return Ok(Command::Turns { workspace });
        }
        if generation.is_some() && key.is_none() {
            return Err(UsageError::new("--generation retries require the original --key"));
        }
        Ok(Command::Rewind {
            workspace,
            session: session.ok_or_else(|| UsageError::new("--session is required"))?,
            turn: turn.ok_or_else(|| UsageError::new("--turn is required"))?,
            key,
            generation,
        })
    })())
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && value.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
}

fn fenced_request(
    state: &Value,
    workspace: &str,
    session: &str,
    turn: &str,
    key: &str,
    original_generation: Option<u64>,
) -> Result<Value, String> {
    let machine = state
        .get("machineId")
        .and_then(Value::as_str)
        .filter(|id| valid_id(id))
        .ok_or_else(|| "The app returned no workspace machine.".to_owned())?;
    let current_generation = state
        .get("generation")
        .and_then(Value::as_u64)
        .ok_or_else(|| "The app returned no machine generation.".to_owned())?;
    let generation = original_generation.unwrap_or(current_generation);
    let found = state.get("captures").and_then(Value::as_array).is_some_and(|captures| {
        captures.iter().any(|capture| {
            capture.get("session").and_then(Value::as_str) == Some(session)
                && capture.get("turn").and_then(Value::as_str) == Some(turn)
                && capture.get("status").and_then(Value::as_str) == Some("ready")
        })
    });
    if !found {
        return Err("That session and turn have no ready machine snapshot.".into());
    }
    Ok(json!({"workspace":workspace,"session":session,"turn":turn,"clientKey":key,
        "expectedMachine":machine,"expectedGeneration":generation}))
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, args) = super::parse_globals(args).ok()?;
    let command = match parse(&args)? {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure("usage.invalid", &error.0, global.output, 2));
        }
    };
    if command == Command::Help {
        println!("{USAGE}");
        return Some(0);
    }
    let workspace = match &command {
        Command::Turns { workspace } | Command::Rewind { workspace, .. } => workspace,
        Command::Help => return Some(0),
    };
    let mut stream = match super::app::connect_command(&global) {
        Ok(stream) => stream,
        Err(error) => return Some(super::wire::print_local_error(&error, global.output, 3)),
    };
    let state = match super::app::request(
        &mut stream,
        "cloud.turn.state",
        json!({"workspace":workspace}),
        Duration::from_secs(30),
    ) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => return Some(super::wire::print_local_error(&error, global.output, 1)),
        Err(error) => {
            return Some(super::app::failure("cloud.turn.unavailable", &error, global.output, 1));
        }
    };
    let Command::Rewind { workspace, session, turn, key, generation } = command else {
        return Some(super::wire::print_local_success(&state, global.output));
    };
    let key = key.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let params = match fenced_request(&state, &workspace, &session, &turn, &key, generation) {
        Ok(params) => params,
        Err(error) => {
            return Some(super::app::failure("cloud.turn.invalid", &error, global.output, 1));
        }
    };
    let expected_generation = params.get("expectedGeneration").cloned().unwrap_or(Value::Null);
    let retry = format!(
        "cmux machine rewind --workspace {workspace} --session {session} --turn {turn} --key {key} --generation {expected_generation}"
    );
    if global.output != OutputMode::Quiet {
        eprintln!("Retry an uncertain result with: {retry}");
    }
    Some(
        match super::app::request(
            &mut stream,
            "cloud.turn.rewind",
            params,
            Duration::from_secs(310),
        ) {
            Ok(Ok(mut value)) => {
                if let Some(object) = value.as_object_mut() {
                    object.insert("clientKey".into(), Value::String(key));
                    object.insert("expectedGeneration".into(), expected_generation);
                }
                super::wire::print_local_success(&value, global.output)
            }
            Ok(Err(mut error)) => {
                if let Some(object) = error.as_object_mut() {
                    object.insert("clientKey".into(), Value::String(key));
                    object.insert("expectedGeneration".into(), expected_generation);
                }
                super::wire::print_local_error(&error, global.output, 1)
            }
            Err(error) => super::app::failure(
                "cloud.turn.uncertain",
                &format!("{error}; retry with: {retry}"),
                global.output,
                1,
            ),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| word.to_string()).collect()
    }

    #[test]
    fn only_explicit_owner_commands_are_routed() {
        assert!(matches!(
            parse(&args(&["machine", "turns", "--workspace", "ws_1"])),
            Some(Ok(Command::Turns { .. }))
        ));
        assert!(parse(&args(&["machine", "snapshot", "vm_1"])).is_none());
        assert!(matches!(
            parse(&args(&["machine", "rewind", "--workspace", "../other"])),
            Some(Err(_))
        ));
        assert!(matches!(
            parse(&args(&[
                "machine",
                "rewind",
                "--workspace",
                "ws_1",
                "--session",
                "s1",
                "--turn",
                "t1",
                "--key",
                "key1",
                "--generation",
                "3",
            ])),
            Some(Ok(Command::Rewind { generation: Some(3), .. }))
        ));
    }

    #[test]
    fn current_generation_and_exact_capture_scope_are_required() {
        let state = json!({"machineId":"vm_1","generation":4,"captures":[{"session":"s1","turn":"t1","status":"ready"}]});
        let request = fenced_request(&state, "ws_1", "s1", "t1", "retry-1", None).unwrap();
        assert_eq!(request["expectedGeneration"], 4);
        assert_eq!(request["expectedMachine"], "vm_1");
        assert_eq!(request["clientKey"], "retry-1");
        let replay = fenced_request(&state, "ws_1", "s1", "t1", "retry-1", Some(3)).unwrap();
        assert_eq!(replay["expectedGeneration"], 3);
        assert!(fenced_request(&state, "ws_1", "s2", "t1", "retry-1", None).is_err());
        assert!(
            fenced_request(
                &json!({"machineId":"vm_1","generation":-1}),
                "ws_1",
                "s1",
                "t1",
                "retry-1",
                None
            )
            .is_err()
        );
    }
}
