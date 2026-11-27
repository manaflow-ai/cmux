//! `cmux safe-mode on|off|status [--json] [--state-dir DIR]` and
//! `cmux apps rollback <app> [--json]` (docs/cmux-next/extensions/
//! safe-mode.md).
//!
//! Safe mode turns every extension off. These commands need no app UI, so
//! they work when the app is wedged: they ask the session daemon
//! (`apps-safe-mode`, cmux-tui-core apps/safe_mode.rs), and when no daemon
//! answers they write the flag file the daemon reads when it starts
//! (`cmux_tui_core::safe_mode_flag`), so cmux comes up in safe mode next
//! time. A running daemon lets only you leave safe mode, from the app
//! itself; with cmux quit, `cmux safe-mode off` removes the flag file.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_tui_core::safe_mode_flag::{self, Flag, Reason};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux safe-mode on|off|status [--json] [--state-dir DIR]\n\n  Safe mode turns every extension off (third-party, local and customize apps, and the\n  bundled apps that run scripts), so a broken extension cannot break cmux.\n  on:     turn it on now; cmux shows its own views in place of every extension.\n  off:    leave it. While cmux runs, only you can do this, in cmux (Leave Safe Mode).\n          With cmux quit, this removes the flag so the next start is normal.\n  status: whether it is on, why, and which extensions a crash loop held off.\n  With no cmux running, on and off write the flag in the state folder\n  (--state-dir, else CMUX_TUI_STATE_DIR, else the default) for the next start.\n\n  cmux apps rollback <app> puts back the last version of a local app that worked.";

const ROLLBACK_USAGE: &str = "usage: cmux apps rollback <app> [--json]\n\n  Rollback is confirmed by you, in cmux (Roll Back on the app). This asks cmux\n  and prints its answer; an agent's call is refused.\n  It puts back the last version of a local or customize app that loaded and drew.\n  The files it replaces are kept, so nothing is lost.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    On,
    Off,
    Status,
    Rollback { app: String },
}

/// What the daemon said, or that none answered.
#[derive(Debug)]
enum Answer {
    Ok(Value),
    Refused { code: String, message: String },
    NoDaemon(String),
}

/// Parses the words after `safe-mode` (`apps` false) or after `apps`
/// (`apps` true, only `rollback`); `None` when they are not ours.
pub(super) fn parse(
    args: &[String],
    apps: bool,
) -> Option<Result<(Request, Option<PathBuf>), String>> {
    let (verb, rest) = args.split_first()?;
    if apps {
        if verb != "rollback" {
            return None;
        }
        return Some(match rest {
            [app] if !app.starts_with('-') => Ok((Request::Rollback { app: app.clone() }, None)),
            _ => Err(ROLLBACK_USAGE.to_string()),
        });
    }
    let request = match verb.as_str() {
        "on" => Request::On,
        "off" => Request::Off,
        "status" => Request::Status,
        _ => return Some(Err(USAGE.to_string())),
    };
    let mut state_dir = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match (word.as_str(), words.next()) {
            ("--state-dir", Some(dir)) => state_dir = Some(PathBuf::from(dir)),
            _ => return Some(Err(USAGE.to_string())),
        }
    }
    Some(Ok((request, state_dir)))
}

/// `cmux [global options] safe-mode ...` or `cmux apps rollback ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    let apps = match scope.as_str() {
        "safe-mode" => false,
        "apps" => true,
        _ => return None,
    };
    if apps && rest.first().map(String::as_str) != Some("rollback") {
        return None;
    }
    if rest.iter().any(|word| matches!(word.as_str(), "-h" | "--help"))
        || (!apps && rest.is_empty())
    {
        println!("{}", if apps { ROLLBACK_USAGE } else { USAGE });
        return Some(0);
    }
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| match word.as_str() {
            "--json" => {
                global.output = OutputMode::Json;
                false
            }
            "--quiet" => {
                global.output = OutputMode::Quiet;
                false
            }
            _ => true,
        })
        .cloned()
        .collect();
    let (request, state_dir) = match parse(&rest, apps)? {
        Ok(parsed) => parsed,
        Err(usage) => {
            eprintln!("{usage}");
            return Some(2);
        }
    };
    Some(run(&global, &request, state_dir.as_deref()))
}

/// One request on a fresh connection to the session daemon.
fn ask(global: &GlobalArgs, frame: Value) -> Answer {
    let socket = match super::wire::resolve_socket_with_origin(global) {
        Ok((socket, _)) => socket,
        Err(error) => return Answer::NoDaemon(error.to_string()),
    };
    let stream = match UnixStream::connect(&socket) {
        Ok(stream) => stream,
        Err(error) => return Answer::NoDaemon(format!("{}: {error}", socket.display())),
    };
    let exchange = || -> Result<Value, String> {
        stream.set_read_timeout(Some(Duration::from_secs(15))).map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{frame}").map_err(|e| e.to_string())?;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                return Err("the daemon closed the connection".into());
            }
            let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
            if value.get("id") == frame.get("id") {
                return Ok(value);
            }
        }
    };
    match exchange() {
        Ok(reply) if reply.get("ok") == Some(&Value::Bool(true)) => {
            Answer::Ok(reply.get("data").cloned().unwrap_or(Value::Null))
        }
        Ok(reply) => Answer::Refused {
            code: reply.get("error_code").and_then(Value::as_str).unwrap_or("error").to_string(),
            message: reply.get("error").and_then(Value::as_str).unwrap_or("").to_string(),
        },
        Err(message) => Answer::Refused { code: "io".into(), message },
    }
}

fn run(global: &GlobalArgs, request: &Request, state_dir: Option<&Path>) -> i32 {
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let print = |text: String| {
        if global.output != OutputMode::Quiet {
            println!("{}", text.trim_end());
        }
    };
    if let Request::Rollback { app } = request {
        if global.output != OutputMode::Quiet {
            eprintln!("cmux: rollback is confirmed by you, in cmux (Roll Back on {app}).");
        }
        let frame = json!({"id": "cmux-rollback-1", "cmd": "apps-store", "op": "cmux.apps.rollback", "args": {"app": app}});
        return match ask(global, frame) {
            Answer::Ok(data) => {
                print(if json_out {
                    data.to_string()
                } else {
                    format!(
                        "Rolled back {app} to {}. The files it replaced are kept in cmux's state folder (apps-last-good).",
                        data.get("version")
                            .and_then(Value::as_str)
                            .unwrap_or("its last good version")
                    )
                });
                0
            }
            Answer::Refused { code, message } if code == "apps.origin" => {
                eprintln!("cmux: {message} (Roll Back on the app).");
                1
            }
            Answer::Refused { code, message } => {
                eprintln!("cmux: {code}: {message}");
                1
            }
            Answer::NoDaemon(why) => {
                eprintln!("cmux: rollback needs cmux running ({why})");
                1
            }
        };
    }
    let (op, args) = match request {
        Request::On => ("safe_mode.set", json!({"on": true})),
        Request::Off => ("safe_mode.set", json!({"on": false})),
        _ => ("safe_mode.get", json!({})),
    };
    let frame = json!({"id": "cmux-safe-mode-1", "cmd": "apps-safe-mode", "op": op, "args": args});
    let (state, via) = match ask(global, frame) {
        Answer::Ok(state) => (state, json!("daemon")),
        Answer::Refused { code, message } if code == "apps.safe_mode.origin" => {
            eprintln!(
                "cmux: {message}. Or quit cmux and run `cmux safe-mode off` to start normally next time."
            );
            return 1;
        }
        Answer::Refused { code, message } => {
            eprintln!("cmux: {code}: {message}");
            return 1;
        }
        Answer::NoDaemon(_) => {
            let Some(path) =
                state_dir.map(safe_mode_flag::path_in).or_else(safe_mode_flag::default_path)
            else {
                eprintln!("cmux: no state folder to hold the safe mode flag; pass --state-dir");
                return 1;
            };
            match offline(request, &path) {
                Ok(state) => (state, json!({"file": path.display().to_string()})),
                Err(error) => {
                    eprintln!("cmux: {}: {error}", path.display());
                    return 1;
                }
            }
        }
    };
    if json_out {
        let mut out = state;
        if let Some(map) = out.as_object_mut() {
            map.insert("via".into(), via);
        }
        print(out.to_string());
    } else {
        print(human(&state, request, via.is_object()));
    }
    0
}

/// No daemon: the flag file is the state.
fn offline(request: &Request, path: &Path) -> std::io::Result<Value> {
    match request {
        Request::On => {
            let flag = safe_mode_flag::read(path).unwrap_or(Flag {
                on: true,
                reason: Reason::User,
                since_ms: safe_mode_flag::now_ms(),
                extensions: Vec::new(),
            });
            safe_mode_flag::write(path, Some(&flag))?;
        }
        Request::Off => safe_mode_flag::write(path, None)?,
        _ => {}
    }
    Ok(flag_json(safe_mode_flag::read(path).as_ref()))
}

/// The daemon's `safe_mode.get` shape for a flag.
fn flag_json(flag: Option<&Flag>) -> Value {
    match flag {
        None => json!({"on": false}),
        Some(flag) => json!({
            "on": true,
            "reason": flag.reason.as_str(),
            "sinceMs": flag.since_ms,
            "extensions": flag.extensions,
        }),
    }
}

pub(super) fn human(state: &Value, request: &Request, from_file: bool) -> String {
    if state.get("on") != Some(&Value::Bool(true)) {
        return match (request, from_file) {
            (Request::Off, true) => "Safe mode is off: cmux starts normally next time.".into(),
            _ => "Safe mode is off.".into(),
        };
    }
    let why = match state.get("reason").and_then(Value::as_str) {
        Some("crash-loop") => "cmux crashed several times in a row at launch",
        Some("env") => "CMUX_SAFE_MODE is set",
        _ => "you turned it on",
    };
    let mut out = format!("Safe mode is on ({why}): every extension is off.");
    let named: Vec<&str> = state
        .get("extensions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !named.is_empty() {
        out.push_str(&format!("\nRunning when it crashed: {}.", named.join(", ")));
        out.push_str("\nRoll one back in cmux (Roll Back), or remove it in the App Store.");
    }
    if from_file {
        out.push_str("\ncmux is not running: it starts in safe mode next time.");
    }
    out.push_str("\nLeave it in cmux with Leave Safe Mode.");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn parses_the_verbs_and_leaves_other_apps_verbs() {
        assert_eq!(parse(&words("on"), false), Some(Ok((Request::On, None))));
        assert_eq!(
            parse(&words("off --state-dir /tmp/x"), false),
            Some(Ok((Request::Off, Some(PathBuf::from("/tmp/x")))))
        );
        assert_eq!(parse(&words("status"), false), Some(Ok((Request::Status, None))));
        assert!(matches!(parse(&words("maybe"), false), Some(Err(_))));
        assert!(matches!(parse(&words("on --state-dir"), false), Some(Err(_))));
        assert_eq!(
            parse(&words("rollback local/customize"), true),
            Some(Ok((Request::Rollback { app: "local/customize".into() }, None)))
        );
        assert!(matches!(parse(&words("rollback"), true), Some(Err(_))));
        assert_eq!(parse(&words("list"), true), None, "apps list is apps_list");
        assert_eq!(parse(&words("install acme/x"), true), None, "install is the app action");
    }

    #[test]
    fn with_no_daemon_on_and_off_write_the_flag_file() {
        let mut bytes = [0u8; 8];
        getrandom::fill(&mut bytes).unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-cli-safe-mode-{}",
            bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
        ));
        let path = safe_mode_flag::path_in(&dir);
        assert_eq!(offline(&Request::Status, &path).unwrap(), json!({"on": false}));
        let on = offline(&Request::On, &path).unwrap();
        assert_eq!((on["on"].clone(), on["reason"].clone()), (json!(true), json!("user")));
        // On again keeps the first time (and a crash loop's names).
        assert_eq!(offline(&Request::On, &path).unwrap()["sinceMs"], on["sinceMs"]);
        assert!(human(&on, &Request::Status, true).contains("starts in safe mode next time"));
        assert_eq!(offline(&Request::Off, &path).unwrap(), json!({"on": false}));
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_crash_loop_status_names_the_extensions() {
        let state = json!({"on": true, "reason": "crash-loop", "sinceMs": 1, "extensions": ["local/customize"]});
        let text = human(&state, &Request::Status, false);
        assert!(text.contains("crashed several times"), "{text}");
        assert!(text.contains("local/customize"), "{text}");
        assert!(text.contains("Roll Back"), "{text}");
    }
}
