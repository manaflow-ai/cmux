//! `optchat-chief agents ...` (also `chief agents ...` in the turn session):
//! how the Chief starts and steers its children. Each verb is one short
//! acpmux connection; the host, watching acpmux, turns a child's turn end into
//! a `[name] report` message (section 9), so nothing here waits for a child.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::Duration;

use cmux_chief::acp::SessionSummary;
use cmux_chief::rules::PARENT_TAG;
use serde_json::{Value, json};

use crate::acpmux::{SessionSpec, new_session, sessions};
use crate::brain::PARENT;
use crate::cli::{Flags, env};
use crate::rpc::{Notification, RpcClient};

pub const USAGE: &str = "chief agents spawn --name N --cwd DIR [--harness H] [--policy P] \"task\"
chief agents list | prompt NAME \"text\" | allow NAME [OPTION_ID] | deny NAME";

type Notes = (Sender<Notification>, Receiver<Notification>);

fn connect() -> Result<(Arc<RpcClient>, Notes), String> {
    let socket = crate::acpmux_daemon::socket_path();
    let (tx, rx) = channel();
    let forward = tx.clone();
    let client = RpcClient::connect(&socket, move |n| {
        let _ = forward.send(n);
    })
    .map_err(|e| format!("acpmux is not reachable at {}: {e}", socket.display()))?;
    client
        .request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "chief-agents", "version": env!("CARGO_PKG_VERSION")}}),
        )
        .map_err(|e| format!("initialize: {e}"))?;
    Ok((client, (tx, rx)))
}

fn mine(list: Vec<SessionSummary>) -> Vec<SessionSummary> {
    list.into_iter()
        .filter(|s| s.tags.get(PARENT_TAG).map(String::as_str) == Some(PARENT))
        .collect()
}

fn child(client: &RpcClient, name: &str) -> Result<SessionSummary, String> {
    mine(sessions(client)?)
        .into_iter()
        .find(|s| s.name == name || s.session_id == name)
        .ok_or_else(|| format!("no agent {name} started by the Chief (see `chief agents list`)"))
}

/// The prompt's own answer, forwarded into the notification stream.
const ANSWER: &str = "\u{0}answer";

/// Sends a prompt and returns once acpmux accepted it (ran or queued it), not when its turn ends.
fn prompt_accepted(
    client: &RpcClient,
    notes: &Notes,
    session: &str,
    text: &str,
) -> Result<(), String> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let prompt_id = format!("chief-cli-{}-{nanos}", std::process::id());
    let answer = client.start(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
    );
    let forward = notes.0.clone();
    std::thread::spawn(move || {
        let params = match answer.recv() {
            Ok(Ok(_)) => Value::Null,
            Ok(Err(e)) => Value::String(e.to_string()),
            Err(_) => Value::String("acpmux closed the connection".into()),
        };
        let _ = forward.send(Notification {
            method: ANSWER.into(),
            params,
        });
    });
    loop {
        match notes.1.recv_timeout(Duration::from_secs(60)) {
            Ok(n)
                if n.method == "_acpmux/prompt_accepted"
                    && n.params.get("promptId").and_then(Value::as_str)
                        == Some(prompt_id.as_str()) =>
            {
                return Ok(());
            }
            Ok(n) if n.method == ANSWER => {
                return match n.params {
                    Value::String(error) => Err(error),
                    _ => Ok(()),
                };
            }
            Ok(n) if n.method.is_empty() => return Err("acpmux closed the connection".into()),
            Ok(_) => {}
            Err(RecvTimeoutError::Timeout) => {
                return Err("acpmux did not accept the prompt within 60 s".into());
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err("acpmux closed the connection".into());
            }
        }
    }
}

/// Runs one `agents` verb; Ok carries what to print.
pub fn run(flags: &Flags) -> Result<String, String> {
    let words = &flags.words[1..];
    let verb = words.first().map(String::as_str).unwrap_or("");
    let args = &words[words.len().min(1)..];
    match verb {
        "spawn" => {
            let name = flags.value("name").ok_or("spawn needs --name")?;
            let cwd = flags.value("cwd").ok_or("spawn needs --cwd")?;
            let task = args.join(" ");
            if task.trim().is_empty() {
                return Err(format!("spawn needs a task\n{USAGE}"));
            }
            let (client, notes) = connect()?;
            // A named session from a failed earlier start is reused.
            let existing = sessions(&client)?
                .into_iter()
                .find(|s| s.name == name)
                .map(|s| s.session_id);
            let id = match existing {
                Some(id) => id,
                None => new_session(
                    &client,
                    &SessionSpec {
                        name: name.to_owned(),
                        cwd: cwd.into(),
                        harness: flags
                            .value("harness")
                            .map(str::to_owned)
                            .or_else(|| env("MUX_HARNESS"))
                            .unwrap_or_else(|| "claude-sr".into()),
                        policy: flags
                            .value("policy")
                            .map(str::to_owned)
                            .or_else(|| env("MUX_POLICY"))
                            .unwrap_or_else(|| "approve-all".into()),
                        model: flags.value("model").map(str::to_owned),
                    },
                )?,
            };
            client
                .request(
                    "_acpmux/tag",
                    json!({"sessionId": id, "set": {PARENT_TAG: PARENT}}),
                )
                .map_err(|e| format!("tag: {e}"))?;
            prompt_accepted(&client, &notes, &id, &task)?;
            client.close();
            Ok(format!(
                "started {name} ({id}) in {cwd}; its report comes back as a \"[{name}] ...\" message"
            ))
        }
        "list" => {
            let (client, _) = connect()?;
            let rows: Vec<String> = mine(sessions(&client)?)
                .into_iter()
                .map(|s| {
                    let pending = if s.pending_permissions > 0 {
                        format!("\t{} pending permission(s)", s.pending_permissions)
                    } else {
                        String::new()
                    };
                    format!(
                        "{}\t{:?}\t{}\t{}{pending}",
                        s.name, s.status, s.harness, s.cwd
                    )
                })
                .collect();
            client.close();
            Ok(if rows.is_empty() {
                "(no agents)".into()
            } else {
                rows.join("\n")
            })
        }
        "prompt" => {
            let name = args.first().ok_or(USAGE)?;
            let text = args[1..].join(" ");
            if text.trim().is_empty() {
                return Err(USAGE.into());
            }
            let (client, notes) = connect()?;
            let target = child(&client, name)?;
            prompt_accepted(&client, &notes, &target.session_id, &text)?;
            client.close();
            Ok(format!(
                "sent to {name}; its report comes back as a message"
            ))
        }
        "allow" | "deny" => {
            let name = args.first().ok_or(USAGE)?;
            let (client, _) = connect()?;
            let target = child(&client, name)?;
            let info = client
                .request("_acpmux/info", json!({"sessionId": target.session_id}))
                .map_err(|e| e.to_string())?;
            let pending = info
                .get("pending")
                .and_then(Value::as_array)
                .and_then(|p| p.first())
                .cloned()
                .ok_or_else(|| format!("{name} has no pending permission"))?;
            let permission = pending
                .get("permissionId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let options: Vec<Value> = pending
                .pointer("/request/options")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let starts = |o: &Value, p: &str| {
                o.get("kind")
                    .and_then(Value::as_str)
                    .is_some_and(|k| k.starts_with(p))
            };
            let id_of = |o: &Value| o.get("optionId").and_then(Value::as_str).map(str::to_owned);
            let option = if verb == "allow" {
                args.get(1)
                    .cloned()
                    .or_else(|| options.iter().find(|o| starts(o, "allow")).and_then(id_of))
                    .or_else(|| options.first().and_then(id_of))
            } else {
                options.iter().find(|o| starts(o, "reject")).and_then(id_of)
            };
            let mut params = json!({"sessionId": target.session_id, "permissionId": permission});
            if let Some(option) = &option {
                params["optionId"] = json!(option);
            }
            client
                .request("_acpmux/permission_respond", params)
                .map_err(|e| e.to_string())?;
            client.close();
            Ok(format!(
                "{}: {}",
                if verb == "allow" { "allowed" } else { "denied" },
                option.unwrap_or_else(|| "(cancelled)".into())
            ))
        }
        _ => Err(USAGE.into()),
    }
}
