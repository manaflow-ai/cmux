//! `cmux link chat VERB --host ID ...`: a Cloud machine's agent chats as the caller reaches them
//! over the link (cloud multiplayer lane C), so a script or the self-test loop drives the same
//! daemon verbs the app's chat pane does. The link mints the dial's token, and CloudDO signs the
//! caller's role in it (`owner`, or `team` for a member of the machine's team); the machine's
//! daemon decides what that role may do. Nothing here names a role or an author: a member is
//! stamped by the daemon as the account its token names.
//!
//! Verbs (each prints one JSON object on stdout; `--json` is accepted and is the only output):
//! - `list --host ID [--name NAME]`: `{"team","machine","chats":[{"surface","session","harness",
//!   "cloud_id"}]}`. `cloud_id` is the chat's address `cloud:<team>/<machine>/<session>`.
//! - `read --host ID --surface N [--after-seq N] [--limit N] [--name NAME]`: the attach page
//!   (`{"session","events","hasMore","lastSeq","presence"?}`), the transcript only for a member.
//! - `send --host ID --surface N --text TEXT [--steer] [--prompt-id ID] [--name NAME]`:
//!   `{"prompt_id","turn_id","queued","state","awaiting_owner"}`. `state` is acpmux's word:
//!   `steered` (into the running turn), `queued` or `started`; `awaiting_owner` is true for a
//!   prompt held for the owner's approval (a link guest's).
//! - `approve --host ID --surface N --prompt-id P --turn-id T --revision R` and
//!   `decline --host ID --surface N --prompt-id P`: the owner's decision on a held prompt.
//!
//! `--name NAME` is the display name a member is shown with (`person_name`); the owner's is
//! ignored. `--socket PATH` dials that link socket, as `cmux link dial` does.
//!
//! A refusal prints `{"ok":false,"error_code":CODE,"error":MESSAGE}` and exits 1, with the
//! daemon's own code: `agent_session.owner_only` (a member answering an ask or deciding a held
//! prompt), `agent_session.not_trusted`, `agent_session.unknown_tab`, `agent_session.not_shared`,
//! `remote_denied` (the role may not use the verb, or the caller is no member of the machine's
//! team), `chat.bad_usage` (exit 64). A dial that does not connect prints `cmux link dial`'s
//! line on stdout and exits with its code (2 unknown host, 3 not authorized, 4 paused,
//! 5 unreachable, 6 link unavailable).

use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

use super::dial_cli::{Failure, chosen_socket, connect_because};
use cmux_link::dial::Service;

/// One verb's reply wait; an attach or a prompt's acceptance answers within acpmux's own limits.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq)]
enum Verb {
    List,
    Read { surface: u64, after_seq: Option<u64>, limit: Option<u64> },
    Send { surface: u64, text: String, steer: bool, prompt_id: String },
    Approve { surface: u64, prompt_id: String, turn_id: String, revision: u64 },
    Decline { surface: u64, prompt_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    host: String,
    socket: Option<std::path::PathBuf>,
    name: Option<String>,
    verb: Verb,
}

/// `cmux link chat --help` (and `cmux link chat VERB --help`).
const USAGE: &str = "\
usage: cmux link chat list --host ID [--name NAME] [--socket PATH] [--json]
       cmux link chat read --host ID --surface N [--after-seq N] [--limit N] [--name NAME]
       cmux link chat send --host ID --surface N --text TEXT [--steer] [--prompt-id ID] [--name NAME]
       cmux link chat approve --host ID --surface N --prompt-id P --turn-id T --revision R
       cmux link chat decline --host ID --surface N --prompt-id P

A Cloud machine's agent chats as your role reaches them over the link (owner, or a member of
the machine's team). Each prints one JSON object; a refusal is
{\"ok\":false,\"error_code\":CODE,\"error\":MESSAGE} with exit 1, bad usage chat.bad_usage (exit 64).
";

fn usage(message: &str) -> i32 {
    println!("{}", json!({"ok": false, "error_code": "chat.bad_usage", "error": message}));
    64
}

fn parse(args: &[String]) -> Result<Args, String> {
    let (verb, rest) =
        args.split_first().ok_or("name a verb: list, read, send, approve, decline")?;
    let mut values: Vec<(String, String)> = Vec::new();
    let mut steer = false;
    let mut index = 0;
    while let Some(flag) = rest.get(index).map(String::as_str) {
        match flag {
            "--steer" => steer = true,
            "--json" => {}
            "--host" | "--socket" | "--name" | "--surface" | "--after-seq" | "--limit"
            | "--text" | "--prompt-id" | "--turn-id" | "--revision" => {
                let value = rest.get(index + 1).ok_or_else(|| format!("{flag} needs a value"))?;
                if values.iter().any(|(key, _)| key == flag) {
                    return Err(format!("{flag} given twice"));
                }
                values.push((flag.to_owned(), value.clone()));
                index += 1;
            }
            other => return Err(format!("unknown option {other}")),
        }
        index += 1;
    }
    let get = |key: &str| values.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    let number = |key: &str| -> Result<Option<u64>, String> {
        get(key).map(|v| v.parse::<u64>().map_err(|_| format!("{key} takes a number"))).transpose()
    };
    let required = |key: &str| get(key).ok_or_else(|| format!("{key} is required"));
    let surface =
        || -> Result<u64, String> { number("--surface")?.ok_or("--surface is required".into()) };
    let host = required("--host")?;
    if !cmux_link::stamp::valid_id(&host) {
        return Err("--host takes a host id".into());
    }
    let socket = get("--socket").map(std::path::PathBuf::from);
    if socket.as_deref().is_some_and(|path| !path.is_absolute()) {
        return Err("--socket takes an absolute path".into());
    }
    let verb = match verb.as_str() {
        "list" => Verb::List,
        "read" => Verb::Read {
            surface: surface()?,
            after_seq: number("--after-seq")?,
            limit: number("--limit")?,
        },
        "send" => {
            let text = required("--text")?;
            if text.trim().is_empty() {
                return Err("--text is empty".into());
            }
            let prompt_id = get("--prompt-id")
                .unwrap_or_else(|| format!("cli-{}", uuid::Uuid::new_v4().simple()));
            Verb::Send { surface: surface()?, text, steer, prompt_id }
        }
        "approve" => Verb::Approve {
            surface: surface()?,
            prompt_id: required("--prompt-id")?,
            turn_id: required("--turn-id")?,
            revision: number("--revision")?.ok_or("--revision is required")?,
        },
        "decline" => Verb::Decline { surface: surface()?, prompt_id: required("--prompt-id")? },
        other => return Err(format!("unknown verb {other}")),
    };
    Ok(Args { host, socket, name: get("--name"), verb })
}

/// Sets `key` on a JSON object; any other value is left as it is.
fn set(object: &mut Value, key: &str, value: Value) {
    if let Some(fields) = object.as_object_mut() {
        fields.insert(key.to_owned(), value);
    }
}

/// The frames a verb sends after the handshake, the last one's reply being the answer.
fn frames(verb: &Verb) -> Vec<Value> {
    match verb {
        Verb::List => vec![json!({"cmd": "agent-session-team-list"})],
        Verb::Read { surface, after_seq, limit } => {
            let mut attach = json!({"cmd": "agent-session-attach", "surface": surface});
            if let Some(after) = after_seq {
                set(&mut attach, "after_seq", json!(after));
            }
            if let Some(limit) = limit {
                set(&mut attach, "limit", json!(limit));
            }
            vec![attach]
        }
        Verb::Send { surface, text, steer, prompt_id } => {
            let mut prompt = json!({"cmd": "agent-session-prompt", "surface": surface,
                "prompt_id": prompt_id, "text": text});
            if *steer {
                set(&mut prompt, "steer", json!(true));
            }
            vec![json!({"cmd": "agent-session-attach", "surface": surface, "limit": 1}), prompt]
        }
        Verb::Approve { surface, prompt_id, turn_id, revision } => vec![
            json!({"cmd": "agent-session-attach", "surface": surface, "limit": 1}),
            json!({"cmd": "agent-session-queue-approve", "surface": surface, "prompt_id": prompt_id,
                "turn_id": turn_id, "revision": revision}),
        ],
        Verb::Decline { surface, prompt_id } => vec![
            json!({"cmd": "agent-session-attach", "surface": surface, "limit": 1}),
            json!({"cmd": "agent-session-queue-decline", "surface": surface, "prompt_id": prompt_id}),
        ],
    }
}

/// `--help` or `-h` in a flag's place (never a flag's value, so `--text --help` is a prompt), or
/// `help` as the verb.
fn asks_for_help(args: &[String]) -> bool {
    if args.first().is_some_and(|verb| matches!(verb.as_str(), "-h" | "--help" | "help")) {
        return true;
    }
    let mut words = args.iter().skip(1);
    while let Some(word) = words.next() {
        match word.as_str() {
            "-h" | "--help" => return true,
            "--host" | "--socket" | "--name" | "--surface" | "--after-seq" | "--limit"
            | "--text" | "--prompt-id" | "--turn-id" | "--revision" => {
                words.next();
            }
            _ => {}
        }
    }
    false
}

/// `cmux link chat ...`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    if asks_for_help(args) {
        print!("{USAGE}");
        return 0;
    }
    let args = match parse(args) {
        Ok(args) => args,
        Err(message) => return usage(&message),
    };
    let socket = match chosen_socket(args.socket.as_deref()) {
        Ok(socket) => socket,
        Err(failure) => return dial_failed(failure, None),
    };
    let Ok(runtime) = super::tokio_runtime() else {
        return dial_failed(Failure::LinkUnavailable, None);
    };
    runtime.block_on(async {
        let stream = match connect_because(&socket, &args.host, Service::Daemon).await {
            Ok(stream) => stream,
            Err((failure, detail)) => return dial_failed(failure, detail.as_deref()),
        };
        match converse(stream.stream, &args).await {
            Ok(answer) => {
                println!("{answer}");
                0
            }
            Err(refusal) => {
                println!("{refusal}");
                1
            }
        }
    })
}

fn dial_failed(failure: Failure, detail: Option<&str>) -> i32 {
    print!("{}", failure.line_because(detail));
    failure.exit_code()
}

/// The handshake, then the verb's frames in turn; the last reply's `data`, or the first refusal.
async fn converse(stream: tokio::net::UnixStream, args: &Args) -> Result<Value, Value> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let mut info = json!({"cmd": "set-client-info", "name": "cmux link chat", "kind": "frontend",
        "capabilities": ["agent-session-presence-v1"]});
    if let Some(name) = &args.name {
        set(&mut info, "person_name", json!(name));
    }
    let mut handshake = vec![json!({"cmd": "identify"}), info];
    handshake.extend(frames(&args.verb));
    let mut last = Value::Null;
    for (id, mut frame) in handshake.into_iter().enumerate() {
        let id = id as u64 + 1;
        set(&mut frame, "id", json!(id));
        let line = format!("{frame}\n");
        if writer.write_all(line.as_bytes()).await.is_err() {
            return Err(
                json!({"ok": false, "error_code": "chat.closed", "error": "the machine closed the connection"}),
            );
        }
        let reply = loop {
            let next = tokio::time::timeout(REPLY_TIMEOUT, lines.next_line()).await;
            let Ok(Ok(Some(line))) = next else {
                return Err(
                    json!({"ok": false, "error_code": "chat.closed", "error": "the machine did not answer"}),
                );
            };
            // Attach streams records before and after replies: only this frame's reply counts.
            let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
            if value.get("id") == Some(&json!(id)) {
                break value;
            }
        };
        if reply.get("ok") != Some(&json!(true)) {
            let code = reply.get("error_code").cloned().unwrap_or(json!("chat.refused"));
            let message = reply.get("error").cloned().unwrap_or(code.clone());
            return Err(
                json!({"ok": false, "error_code": code, "error": message, "step": frame.get("cmd")}),
            );
        }
        last = reply.get("data").cloned().unwrap_or(Value::Null);
    }
    let _ = writer.shutdown().await;
    Ok(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        line.split(' ').map(str::to_owned).collect()
    }

    #[test]
    fn each_verb_parses_to_its_frames() {
        let send = parse(&words(
            "send --host host_ab12 --surface 3 --text hello --steer --prompt-id p1 --json",
        ))
        .unwrap();
        assert_eq!(
            frames(&send.verb)[1],
            json!({"cmd":"agent-session-prompt","surface":3,"prompt_id":"p1","text":"hello","steer":true})
        );
        let list = parse(&words("list --host host_ab12 --name Ana")).unwrap();
        assert_eq!(list.name.as_deref(), Some("Ana"));
        assert_eq!(frames(&list.verb), vec![json!({"cmd":"agent-session-team-list"})]);
        let approve = parse(&words(
            "approve --host host_ab12 --surface 3 --prompt-id g1 --turn-id t1 --revision 0",
        ))
        .unwrap();
        assert_eq!(
            frames(&approve.verb)[1],
            json!({"cmd":"agent-session-queue-approve","surface":3,"prompt_id":"g1","turn_id":"t1","revision":0})
        );
    }

    #[test]
    fn help_names_every_verb() {
        for verb in ["list", "read", "send", "approve", "decline"] {
            assert!(USAGE.contains(&format!("cmux link chat {verb} --host ID")), "{verb}");
        }
        assert_eq!(run(&words("--help")), 0);
        assert_eq!(run(&words("send --help")), 0);
        assert!(!asks_for_help(&words("send --host host_ab12 --surface 1 --text --help")));
        assert!(!asks_for_help(&words("send --host host_ab12 --surface 1 --text help")));
    }

    #[test]
    fn bad_usage_is_refused_before_any_dial() {
        for line in [
            "send --host host_ab12 --surface 3",
            "send --host host_ab12 --text hi",
            "read --surface 1",
            "list --host host_ab12 --host host_cd34",
            "approve --host host_ab12 --surface 3 --prompt-id g1",
            "list --host host_ab12 --socket relative.sock",
            "shout --host host_ab12",
        ] {
            assert!(parse(&words(line)).is_err(), "{line}");
        }
    }
}
