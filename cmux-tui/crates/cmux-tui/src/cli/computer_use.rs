//! `cmux computer-use`: cmux Computer Use from a shell, through the same
//! daemon endpoint and worker the agents' bridge uses
//! (acpmux `computer_use/client.rs`). The CLI is a local caller with the
//! session key `cli`; a call with `--machine` goes over the person's machine
//! links like an agent's. Settings are not here: they go through
//! `cmux settings` (`computerUse.*`), which agents may not change.

use acpmux::computer_use::client::{
    Caller, Daemon, DaemonError, ENDPOINT_CMD, Outcome, new_call_id,
};
use acpmux::computer_use::tools;
use base64::Engine as _;
use serde_json::{Value, json};

use super::{GlobalArgs, parse_globals};

const HELP: &str = "Usage: cmux computer-use <status|tools|call|screenshot|approvals|machines>\n\ncmux Computer Use is built into cmux: agents get it in the cmux MCP server as the cu_* tools (scripted in cmux_exec as cu.click({...})). These commands reach the same worker.\n\n  cmux computer-use status [--machine M]        Platform, permissions, mode and denied apps\n  cmux computer-use tools                        The tools and their arguments\n  cmux computer-use mcp                          Serve the tools alone as an MCP stdio server (cmux-computer-use, for other MCP clients)\n  cmux computer-use call TOOL [--args JSON] [--machine M]\n                                                 Run one tool (arguments as a JSON object)\n  cmux computer-use screenshot --out FILE [--window ID] [--machine M]\n                                                 Save a PNG of a window, or of the main display\n  cmux computer-use approvals list               Apps saved as Always allow or Never\n  cmux computer-use approvals forget APP         Forget APP's saved answer (needs the cmux app; use Settings > Computer Use)\n  cmux computer-use approvals revoke-sessions    End every agent session's approvals now\n  cmux computer-use machines                     Your other machines and whether Computer Use is on there\n\nSettings (mode, denied apps, other machines) are in Settings > Computer Use and `cmux settings get|set computerUse.<key>`.\n";

/// The daemon command for saved approvals (served with the worker's host).
const APPROVALS_CMD: &str = "computer-use-approvals";
/// Set in every agent's environment (acpmux `agent_tools::AGENT_SESSION_ENV`).
const AGENT_SESSION_ENV: &str = "CMUX_AGENT_SESSION";

/// Handles `cmux computer-use` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "computer-use" {
        return None;
    }
    Some(run(&global, rest))
}

/// What the command asked for.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Request {
    Help,
    Mcp,
    Tools,
    Call { tool: String, args: Value, machine: Option<String> },
    Screenshot { out: String, window: Option<String>, machine: Option<String> },
    Approvals { action: &'static str, app: Option<String> },
    Machines,
}

pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let (verb, rest) = words.split_first().map_or(("help", &[][..]), |(v, r)| (*v, r));
    let flags = |rest: &[&str], allowed: &[&str]| -> Result<Vec<(String, String)>, String> {
        let mut out = Vec::new();
        let mut words = rest.iter();
        while let Some(word) = words.next() {
            if !allowed.contains(word) {
                return Err(format!("unknown argument {word:?}"));
            }
            let value = words.next().ok_or_else(|| format!("{word} needs a value"))?;
            out.push(((*word).to_owned(), (*value).to_owned()));
        }
        Ok(out)
    };
    let get = |flags: &[(String, String)], key: &str| {
        flags.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    };
    match verb {
        "help" | "--help" | "-h" => Ok(Request::Help),
        "tools" if rest.is_empty() => Ok(Request::Tools),
        "mcp" if rest.is_empty() => Ok(Request::Mcp),
        "status" => {
            let f = flags(rest, &["--machine"])?;
            Ok(Request::Call {
                tool: "status".into(),
                args: json!({}),
                machine: get(&f, "--machine"),
            })
        }
        "machines" if rest.is_empty() => Ok(Request::Machines),
        "call" => {
            let (tool, rest) = rest.split_first().ok_or("call needs a tool name")?;
            if tools::find(tool).is_none() {
                return Err(format!("unknown tool {tool:?}; see `cmux computer-use tools`"));
            }
            let f = flags(rest, &["--args", "--machine"])?;
            let args = match get(&f, "--args") {
                None => json!({}),
                Some(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(v @ Value::Object(_)) => v,
                    _ => return Err("--args must be a JSON object".into()),
                },
            };
            if args.get("machine").is_some() {
                return Err("pass the machine with --machine".into());
            }
            Ok(Request::Call { tool: (*tool).to_owned(), args, machine: get(&f, "--machine") })
        }
        "screenshot" => {
            let f = flags(rest, &["--out", "--window", "--machine"])?;
            let out = get(&f, "--out").ok_or("screenshot needs --out FILE")?;
            Ok(Request::Screenshot {
                out,
                window: get(&f, "--window"),
                machine: get(&f, "--machine"),
            })
        }
        "approvals" => match rest {
            ["list"] => Ok(Request::Approvals { action: "list", app: None }),
            ["forget", app] if !app.starts_with('-') => {
                Ok(Request::Approvals { action: "forget", app: Some((*app).to_owned()) })
            }
            ["revoke-sessions"] => Ok(Request::Approvals { action: "revoke_sessions", app: None }),
            _ => Err("usage: cmux computer-use approvals list|forget APP|revoke-sessions".into()),
        },
        other => Err(format!("unknown computer-use command {other:?}")),
    }
}

/// The CLI's daemons: the session daemon of `--socket`/`--session` (or the
/// default) for the worker endpoint, and acpmux for other machines.
struct CliDaemon {
    global: GlobalArgs,
}

fn legacy(global: &GlobalArgs, cmd: &str, params: Value) -> Result<Value, DaemonError> {
    let mut request = match params {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    request.insert("id".into(), json!(1));
    request.insert("cmd".into(), json!(cmd));
    super::remote_host::daemon_value(global, &Value::Object(request)).map_err(|error| {
        let code = error["code"].as_str().unwrap_or("refused").to_owned();
        let message = error["message"].as_str().unwrap_or("the daemon refused").to_owned();
        if code.starts_with("transport.") {
            DaemonError::Unreachable(message)
        } else {
            DaemonError::Refused { code, message }
        }
    })
}

impl Daemon for CliDaemon {
    fn endpoint(&self) -> Result<Value, DaemonError> {
        legacy(&self.global, ENDPOINT_CMD, json!({}))
    }
    fn remote_call(&self, params: Value) -> Result<Value, DaemonError> {
        acpmux::computer_use::client::acpmux_request(
            acpmux::rpc::method::MUX_COMPUTER_USE_CALL,
            params,
        )
    }
    fn machines(&self) -> Result<Value, DaemonError> {
        acpmux::computer_use::client::acpmux_request(
            acpmux::rpc::method::MUX_COMPUTER_USE_MACHINES,
            json!({}),
        )
    }
}

fn caller(global: &GlobalArgs) -> Caller<CliDaemon> {
    Caller::new(CliDaemon { global: global.clone() }, "cli".into(), "cmux CLI".into())
}

fn with_machine(mut args: Value, machine: Option<&str>) -> Value {
    if let (Some(machine), Some(map)) = (machine, args.as_object_mut()) {
        map.insert("machine".into(), json!(machine));
    }
    args
}

/// Prints an outcome; exit 1 for a tool error or a failure.
fn print(global: &GlobalArgs, outcome: Outcome) -> i32 {
    match outcome {
        Outcome::Output(out) if !out.is_error => {
            let mut body = out.body;
            if out.png_base64.is_some() {
                body["image"] =
                    json!("png (use `cmux computer-use screenshot --out FILE` to save it)");
            }
            super::wire::print_local_success(&body, global.output)
        }
        Outcome::Output(out) => {
            let message = out.body["error"].as_str().unwrap_or("refused").to_owned();
            let code = out.code.unwrap_or_else(|| "refused".into());
            super::wire::print_local_error(
                &json!({"code": code, "message": message}),
                global.output,
                1,
            )
        }
        Outcome::Off(reason) => super::wire::print_local_error(
            &json!({"code": "computer_use_off", "message": format!(
                "Computer Use is off{}. Turn it on in Settings > Computer Use.",
                if reason.is_empty() { String::new() } else { format!(" ({reason})") })}),
            global.output,
            1,
        ),
        Outcome::Failed { code, message } => super::wire::print_local_error(
            &json!({"code": code, "message": message}),
            global.output,
            1,
        ),
    }
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let request = match parse(args) {
        Ok(request) => request,
        Err(message) => {
            eprintln!("cmux computer-use: {message}\n\n{HELP}");
            return 2;
        }
    };
    match request {
        Request::Help => {
            print!("{HELP}");
            0
        }
        Request::Mcp => {
            // The same bridge acpmux gives every agent session, on stdio.
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(e) => {
                    eprintln!("cmux computer-use mcp: {e}");
                    return 1;
                }
            };
            match runtime.block_on(acpmux::computer_use::mcp::run()) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("cmux computer-use mcp: {e:#}");
                    1
                }
            }
        }
        Request::Tools => {
            let list = tools::mcp_list();
            super::wire::print_local_success(&list, global.output)
        }
        Request::Machines => {
            print(global, caller(global).call("list_machines", &json!({}), &new_call_id()))
        }
        Request::Call { tool, args, machine } => {
            let args = with_machine(args, machine.as_deref());
            print(global, caller(global).call(&tool, &args, &new_call_id()))
        }
        Request::Screenshot { out, window, machine } => {
            let mut args = json!({"force": true});
            if let Some(window) = window {
                args["window_id"] = json!(window);
            }
            let args = with_machine(args, machine.as_deref());
            match caller(global).call("screenshot", &args, &new_call_id()) {
                Outcome::Output(shot) if !shot.is_error => {
                    let Some(png) = shot.png_base64.as_deref() else {
                        return super::wire::print_local_error(
                            &json!({"code": "no_image", "message": "the screenshot carried no image"}),
                            global.output,
                            1,
                        );
                    };
                    let bytes = match base64::engine::general_purpose::STANDARD.decode(png) {
                        Ok(bytes) => bytes,
                        Err(e) => {
                            return super::wire::print_local_error(
                                &json!({"code": "bad_image", "message": e.to_string()}),
                                global.output,
                                1,
                            );
                        }
                    };
                    if let Err(e) = std::fs::write(&out, &bytes) {
                        return super::wire::print_local_error(
                            &json!({"code": "write_failed", "message": format!("{out}: {e}")}),
                            global.output,
                            1,
                        );
                    }
                    let mut body = shot.body;
                    body["out"] = json!(out);
                    body["bytes"] = json!(bytes.len());
                    super::wire::print_local_success(&body, global.output)
                }
                other => print(global, other),
            }
        }
        Request::Approvals { action, app } => {
            // Forgetting a "Never" lets an agent use that app again: only the person.
            if action == "forget"
                && std::env::var_os(AGENT_SESSION_ENV).is_some_and(|v| !v.is_empty())
            {
                return super::wire::print_local_error(
                    &json!({"code": "person_only", "message": "Only the person can forget a saved Computer Use answer. Ask them to do it in Settings > Computer Use."}),
                    global.output,
                    1,
                );
            }
            let mut params = json!({"action": action});
            if let Some(app) = app {
                params["app_id"] = json!(app);
            }
            match legacy(global, APPROVALS_CMD, params) {
                Ok(value) => super::wire::print_local_success(&value, global.output),
                Err(e) => super::wire::print_local_error(
                    &json!({"code": "computer_use_unavailable", "message": e.to_string()}),
                    global.output,
                    1,
                ),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn the_commands_parse() {
        assert_eq!(parse(&words("tools")).unwrap(), Request::Tools);
        assert_eq!(parse(&words("mcp")).unwrap(), Request::Mcp);
        assert!(parse(&words("mcp --stdio")).is_err());
        assert_eq!(parse(&words("machines")).unwrap(), Request::Machines);
        assert_eq!(
            parse(&words("status --machine studio")).unwrap(),
            Request::Call {
                tool: "status".into(),
                args: json!({}),
                machine: Some("studio".into())
            }
        );
        let args = vec![
            "call".to_owned(),
            "click".into(),
            "--args".into(),
            r#"{"window_id":"w","x":1}"#.into(),
        ];
        assert_eq!(
            parse(&args).unwrap(),
            Request::Call {
                tool: "click".into(),
                args: json!({"window_id": "w", "x": 1}),
                machine: None
            }
        );
        assert_eq!(
            parse(&words("screenshot --out /tmp/a.png --window w1")).unwrap(),
            Request::Screenshot {
                out: "/tmp/a.png".into(),
                window: Some("w1".into()),
                machine: None
            }
        );
        assert_eq!(
            parse(&words("approvals forget com.apple.Notes")).unwrap(),
            Request::Approvals { action: "forget", app: Some("com.apple.Notes".into()) }
        );
        assert_eq!(
            parse(&words("approvals revoke-sessions")).unwrap(),
            Request::Approvals { action: "revoke_sessions", app: None }
        );
        assert_eq!(parse(&[]).unwrap(), Request::Help);
    }

    #[test]
    fn bad_commands_are_usage_errors() {
        for bad in [
            "call",
            "call run_shell",
            "call click --args [1]",
            "screenshot",
            "screenshot --out",
            "approvals forget",
            "approvals",
            "settings set mode off",
            "status --force",
        ] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
        let machine_in_args =
            vec!["call".to_owned(), "click".into(), "--args".into(), r#"{"machine":"x"}"#.into()];
        assert!(parse(&machine_in_args).is_err());
    }
}
