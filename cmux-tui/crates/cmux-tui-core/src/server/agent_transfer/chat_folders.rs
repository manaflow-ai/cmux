//! A folder added to a running chat on this Cloud machine (`chat-folder-add-v1`). Leo,
//! 2026-11-25: "mostly just the one you selected, right? then you can add more folders and
//! files/select more as you go potentially". The app on the person's Mac first copies a Mac folder
//! here (`cmux link access grant --attach`), then asks this daemon to put the copy among the chat's
//! folders. The daemon reads the chat's `additionalDirectories` from acpmux and sets them again with
//! the new one at the end (`_acpmux/set_directories`), which restarts the agent between turns,
//! resuming the same conversation: now when no turn runs, else when the running turn ends, so a turn
//! is never cut. acpmux records it as a `mux` `directories` row carrying `added`, which the chat
//! draws as one line ("Added ~/x as /vm/path").
//!
//! - `chat-folder-add {session, path, from?}`: `path` is the absolute folder on this machine, `from`
//!   the Mac path the person picked (shown in the chat line only). Answers
//!   `{applied, path, additionalDirectories}`, `applied` as acpmux says it (`now`, `afterTurn`,
//!   `nextStart` or `unchanged`).
//!
//! Who: as `access-request` (trusted local Unix connections that are not remote clients, on a
//! Cloud host): the Mac's link client arrives that way. Adds of one daemon run one at a time, so
//! two adds never set the list from the same old one.

use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::mux::Mux;
use crate::panic_free::JsonFields;
use crate::server::agent_session_attach::agent_session_link::AcpmuxLink;
use crate::server::remote_relay::gate::COMMAND_PARAMS;
use crate::server::responses::send_response_with_details;
use crate::server::{MessageWriter, Response};

pub const CHAT_FOLDER_CAPABILITY: &str = "chat-folder-add-v1";

const CMD: &str = "chat-folder-add";
const MAX_PATH_BYTES: usize = 4096;
const MAX_SESSION_BYTES: usize = 200;
/// acpmux's own cap (`hub/additional_dirs.rs` `MAX_DIRS`).
const MAX_DIRS: usize = 64;
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// One add at a time on this daemon (see the module docs).
static ADDING: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Refusal {
    NotTrusted,
    Unavailable,
    BadRequest,
    NotAFolder,
    TooMany,
    Acpmux(String),
}

impl Refusal {
    fn code(&self) -> &'static str {
        match self {
            Self::NotTrusted => "chat_folder.not_trusted",
            Self::Unavailable => "chat_folder.unavailable",
            Self::BadRequest => "chat_folder.bad_request",
            Self::NotAFolder => "chat_folder.not_a_folder",
            Self::TooMany => "chat_folder.too_many",
            Self::Acpmux(_) => "chat_folder.acpmux",
        }
    }

    fn message(&self) -> String {
        match self {
            Self::NotTrusted => "chat folders are added by trusted local clients only".into(),
            Self::Unavailable => {
                "chat folders are added on a Cloud machine with acpmux only".into()
            }
            Self::BadRequest => "bad chat folder request".into(),
            Self::NotAFolder => "that folder is not on this machine".into(),
            Self::TooMany => format!("a chat sees at most {MAX_DIRS} folders"),
            Self::Acpmux(message) => message.clone(),
        }
    }
}

/// A checked `chat-folder-add`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Add {
    pub session: String,
    pub path: String,
    pub from: Option<String>,
}

fn plain_path(path: &str) -> bool {
    path.starts_with('/')
        && path.len() <= MAX_PATH_BYTES
        && !path.chars().any(char::is_control)
        && !path.split('/').any(|part| part == "..")
}

/// The frame's params checked: nothing but `session`, `path` and `from`.
pub(crate) fn parse(params: &Map<String, Value>) -> Result<Add, Refusal> {
    if params.keys().any(|key| {
        COMMAND_PARAMS.contains(&key.as_str())
            || !["session", "path", "from"].contains(&key.as_str())
    }) {
        return Err(Refusal::BadRequest);
    }
    let text = |key: &str| match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(Refusal::BadRequest),
    };
    let session = text("session")?
        .filter(|session| {
            (1..=MAX_SESSION_BYTES).contains(&session.len())
                && session.chars().all(|c| c.is_ascii_alphanumeric() || "-_.:".contains(c))
        })
        .ok_or(Refusal::BadRequest)?;
    let path = text("path")?.filter(|path| plain_path(path)).ok_or(Refusal::BadRequest)?;
    let path = match path.trim_end_matches('/') {
        "" => return Err(Refusal::BadRequest),
        trimmed => trimmed.to_string(),
    };
    let from = text("from")?;
    if from.as_deref().is_some_and(|from| !plain_path(from) && !from.starts_with("~/")) {
        return Err(Refusal::BadRequest);
    }
    Ok(Add { session, path, from })
}

/// The chat's folders with `path` at the end, each once; None when it is there already.
pub(crate) fn with_folder(current: &Value, path: &str) -> Result<Option<Vec<String>>, Refusal> {
    let mut dirs: Vec<String> = current
        .as_array()
        .map(|dirs| dirs.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    if dirs.iter().any(|dir| dir == path) {
        return Ok(None);
    }
    if dirs.len() >= MAX_DIRS {
        return Err(Refusal::TooMany);
    }
    dirs.push(path.to_string());
    Ok(Some(dirs))
}

/// Handles a `chat-folder-add` line; None for any other line.
pub(super) fn try_handle(
    mux: &Mux,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"chat-folder-add\"") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    match object.remove("cmd") {
        Some(Value::String(cmd)) if cmd == CMD => {}
        _ => return None,
    }
    let id = object.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Refusal::NotTrusted)));
    }
    if !mux.on_cloud_host() {
        return Some(reply(writer, id, Err(Refusal::Unavailable)));
    }
    let params = match object.remove("params") {
        Some(Value::Object(params)) => params,
        None => object,
        Some(_) => return Some(reply(writer, id, Err(Refusal::BadRequest))),
    };
    let add = match parse(&params) {
        Ok(add) => add,
        Err(refusal) => return Some(reply(writer, id, Err(refusal))),
    };
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Refusal::Unavailable)));
    };
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-chat-folder-add".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = run(&socket, &add);
            reply(&worker_writer, worker_id, result);
        });
    if spawned.is_err() {
        return Some(reply(writer, id, Err(Refusal::Unavailable)));
    }
    Some(true)
}

fn run(socket: &Path, add: &Add) -> Result<Value, Refusal> {
    if !Path::new(&add.path).is_dir() {
        return Err(Refusal::NotAFolder);
    }
    let _one = ADDING.lock().unwrap_or_else(|e| e.into_inner());
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Refusal::Unavailable)?;
    let acpmux = |error| Refusal::Acpmux(format!("{error:?}"));
    let info = link
        .call("_acpmux/info", json!({"sessionId": add.session, "waitLogs": false}), CALL_TIMEOUT)
        .map_err(acpmux)?;
    let current = info.field("additionalDirectories").clone();
    let Some(dirs) = with_folder(&current, &add.path)? else {
        link.close();
        return Ok(
            json!({"applied": "unchanged", "path": add.path, "additionalDirectories": current}),
        );
    };
    let mut added = json!({"path": add.path});
    if let Some(from) = &add.from
        && let Some(object) = added.as_object_mut()
    {
        object.insert("from".into(), json!(from));
    }
    let answer = link.call(
        "_acpmux/set_directories",
        json!({"sessionId": add.session, "additionalDirectories": dirs, "added": added}),
        CALL_TIMEOUT,
    );
    link.close();
    let answer = answer.map_err(acpmux)?;
    Ok(json!({
        "applied": answer.field("applied"),
        "path": add.path,
        "additionalDirectories": answer.field("additionalDirectories"),
    }))
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Refusal>) -> bool {
    let (data, error, code) = match result {
        Ok(data) => (Some(data), None, None),
        Err(refusal) => (None, Some(refusal.message()), Some(refusal.code())),
    };
    send_response_with_details(
        writer,
        Response {
            id,
            ok: data.is_some(),
            data,
            error,
            error_code: code.map(str::to_owned),
            error_delivery: None,
        },
        None,
        None,
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn an_add_takes_a_session_an_absolute_path_and_the_macs_path() {
        let add = parse(&params(
            json!({"session": "chat-1", "path": "/root/work/local/x-1/", "from": "~/x"}),
        ));
        assert_eq!(
            add,
            Ok(Add {
                session: "chat-1".into(),
                path: "/root/work/local/x-1".into(),
                from: Some("~/x".into())
            })
        );
    }

    #[test]
    fn an_add_refuses_relative_dotted_and_extra_params() {
        for bad in [
            json!({"session": "chat-1", "path": "work/x"}),
            json!({"session": "chat-1", "path": "/root/../etc"}),
            json!({"session": "chat-1", "path": "/"}),
            json!({"session": "chat 1", "path": "/root/x"}),
            json!({"session": "chat-1", "path": "/root/x", "cwd": "/"}),
            json!({"session": "chat-1", "path": "/root/x", "from": "relative"}),
            json!({"path": "/root/x"}),
        ] {
            assert_eq!(parse(&params(bad.clone())), Err(Refusal::BadRequest), "{bad}");
        }
    }

    #[test]
    fn a_folder_goes_at_the_end_once() {
        let current = json!(["/a", "/b"]);
        assert_eq!(
            with_folder(&current, "/c"),
            Ok(Some(vec!["/a".into(), "/b".into(), "/c".into()]))
        );
        assert_eq!(with_folder(&current, "/b"), Ok(None));
        assert_eq!(with_folder(&Value::Null, "/c"), Ok(Some(vec!["/c".into()])));
    }

    #[test]
    fn a_chat_with_64_folders_takes_no_more() {
        let full: Vec<String> = (0..MAX_DIRS).map(|n| format!("/d{n}")).collect();
        assert_eq!(with_folder(&json!(full), "/new"), Err(Refusal::TooMany));
    }
}
