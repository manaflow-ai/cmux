//! Rust-owned Cloud chat relay for the iOS mobile RPC adapter.
//!
//! The phone never gets an acpmux socket.  The local mobile host forwards three
//! narrowly shaped commands here; this module opens a short lived AcpmuxLink,
//! validates and bounds the request, and returns the acpmux result.  Keeping the
//! chat/session rules here means the Swift adapter stays a transport forwarder.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, Inbound, LinkError};
use super::*;

/// `identify` advertises it: this daemon serves `mobile-chat-sessions`,
/// `mobile-chat-history` and `mobile-chat-send`, which the Mac's mobile host
/// offers a phone as `cloud_chat_relay.v1`.
pub const CLOUD_CHAT_RELAY_CAPABILITY: &str = "cloud_chat_relay.v1";

const CALL_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_LIMIT: u64 = 200;
const DEFAULT_HISTORY_LIMIT: u64 = 50;
const MAX_TEXT_BYTES: usize = 64 * 1024;
const MAX_HISTORY_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

enum PromptOutcome {
    Accepted(Value),
    Error(LinkError),
}

/// Handles the three commands used by `mobile.chat.*`.  `None` means this is
/// another protocol line and lets the normal command parser handle it.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"mobile-chat-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let Some(Value::String(command)) = object.remove("cmd") else { return None };
    if !matches!(
        command.as_str(),
        "mobile-chat-sessions" | "mobile-chat-history" | "mobile-chat-send"
    ) {
        return None;
    }
    let id = object.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(refuse(writer, id, "not_trusted", "mobile chat relay is local only"));
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(refuse(writer, id, "unavailable", "acpmux is unavailable"));
    };
    let params = Value::Object(object);
    let local_machine_id = serde_json::to_value(&mux.machine_public_id)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned));
    if let Some(requested) = params.get("machine_id").and_then(Value::as_str)
        && local_machine_id.as_deref() != Some(requested)
    {
        return Some(refuse(writer, id, "bad_request", "machine_id does not match this daemon"));
    }
    let expected_prompt_id = (command == "mobile-chat-send")
        .then(|| params.get("prompt_id").and_then(Value::as_str).map(str::to_owned))
        .flatten();
    let (prompt_tx, prompt_rx) = sync_channel(2);
    let prompt_tx_for_call = prompt_tx.clone();
    let writer = writer.clone();
    let workspaces = Arc::clone(mux);
    std::thread::spawn(move || {
        let hides = |id: &str| hides_workspace(&workspaces, id);
        let prompt_id = expected_prompt_id;
        let result = match AcpmuxLink::connect(&socket, move |inbound| {
            if let Inbound::Notification(method, notification) = inbound
                && method == "_acpmux/prompt_accepted"
                && prompt_id.as_deref() == notification.get("promptId").and_then(Value::as_str)
            {
                let _ = prompt_tx.try_send(PromptOutcome::Accepted(notification));
            }
        }) {
            Ok(link) => dispatch(
                &link,
                &command,
                params,
                local_machine_id.as_deref(),
                Some((prompt_rx, prompt_tx_for_call)),
                &hides,
            ),
            Err(_) => Err(("unavailable", "acpmux is unavailable".to_owned())),
        };
        match result {
            Ok(data) => {
                send_response(
                    &writer,
                    Response {
                        id,
                        ok: true,
                        data: Some(data),
                        error: None,
                        error_code: None,
                        error_delivery: None,
                    },
                );
            }
            Err((code, message)) => {
                refuse(&writer, id, code, &message);
            }
        }
    });
    Some(true)
}

fn dispatch(
    link: &Arc<AcpmuxLink>,
    command: &str,
    params: Value,
    machine_id: Option<&str>,
    acceptance: Option<(Receiver<PromptOutcome>, SyncSender<PromptOutcome>)>,
    hides: &dyn Fn(&str) -> bool,
) -> Result<Value, (&'static str, String)> {
    match command {
        "mobile-chat-sessions" => {
            let acpmux_params = bounded_page_params(&params)?;
            let mut raw =
                link.call("_acpmux/sessions", acpmux_params, CALL_TIMEOUT).map_err(link_error)?;
            if let Some(rows) = raw.get_mut("sessions").and_then(Value::as_array_mut) {
                rows.retain(|row| {
                    row.get("sessionId")
                        .or_else(|| row.get("id"))
                        .and_then(Value::as_str)
                        .is_some_and(|id| visible(link, id, hides))
                });
            }
            Ok(normalize_sessions(raw, machine_id))
        }
        "mobile-chat-history" => {
            let session = required_text(&params, "session_id")?;
            if !visible(link, &session, hides) {
                return Err(not_found());
            }
            bounded_limit(&params, "limit")?;
            let mut request = Map::new();
            request.insert("sessionId".into(), Value::String(session.clone()));
            // A history read is not the chat being shown (`server/view.rs`).
            request.insert("visible".into(), Value::Bool(false));
            // Answers with the newest records rather than after a restarted daemon's log restore,
            // which for a long chat outlasts `CALL_TIMEOUT` (`agent_session_attach.rs`).
            request.insert("waitLogs".into(), Value::Bool(false));
            // Pages rather than failing on the response cap when the phone names no limit.
            request.insert("limit".into(), json!(DEFAULT_HISTORY_LIMIT));
            for (mobile, wire) in [
                ("after_seq", "afterSeq"),
                ("before_seq", "beforeSeq"),
                ("limit", "limit"),
                ("kinds", "kinds"),
            ] {
                if let Some(value) = params.get(mobile) {
                    request.insert(wire.into(), value.clone());
                }
            }
            let raw = link
                .call("_acpmux/attach", Value::Object(request), CALL_TIMEOUT)
                .map_err(link_error)?;
            normalize_history(raw, &session)
        }
        "mobile-chat-send" => {
            let session = required_text(&params, "session_id")?;
            if !visible(link, &session, hides) {
                return Err(not_found());
            }
            let text = required_text(&params, "text")?;
            if text.len() > MAX_TEXT_BYTES {
                return Err(("bad_request", "text exceeds 64 KiB".into()));
            }
            let prompt_id = required_text(&params, "prompt_id")?;
            if prompt_id.len() > 128
                || !prompt_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            {
                return Err((
                    "bad_request",
                    "prompt_id must contain only letters, numbers, '-' or '_'".into(),
                ));
            }
            let Some((acceptance, outcome_tx)) = acceptance else {
                return Err(("internal_error", "prompt acceptance channel unavailable".into()));
            };
            let caller = Arc::clone(link);
            // This link is a Local unix connection, but every prompt here is
            // the phone's: the marker keeps it under the Cloud mobile asking
            // floor (acpmux `remote_guard::control_of`), as
            // `agent_session_attach::prompt` does for the carrier path.
            let prompt = json!({
                "sessionId": session,
                "prompt": [{"type": "text", "text": text}],
                "_meta": {"acpmux": {"promptId": prompt_id, "via": "cloud-mobile"}},
            });
            std::thread::spawn(move || {
                if let Err(error) = caller.call("session/prompt", prompt, CALL_TIMEOUT) {
                    let _ = outcome_tx.send(PromptOutcome::Error(error));
                }
            });
            let accepted = match acceptance.recv_timeout(CALL_TIMEOUT) {
                Ok(PromptOutcome::Accepted(params)) => params,
                Ok(PromptOutcome::Error(error)) => return Err(link_error(error)),
                Err(_) => return Err(("timeout", "acpmux did not acknowledge the prompt".into())),
            };
            // Acceptance is the durable hand-off; release this short-lived
            // relay link while the Cloud chat continues in acpmux.
            link.close();
            Ok(json!({"accepted": true, "prompt_id": prompt_id,
                "turn_id": accepted.get("turnId").cloned().unwrap_or(Value::Null),
                "queued": accepted.get("queued").cloned().unwrap_or(json!(false)),
                "message": {"id": prompt_id, "role": "user", "text": text, "created_at": Value::Null}}))
        }
        _ => Err(("method_not_found", "unknown mobile chat command".into())),
    }
}

/// Whether a phone may see chat `session`: not one of an incognito workspace
/// (`PhoneAccessGate.hidesWorkspace`; design/spaces.md "Incognito"), whose
/// chats live in this daemon until the window closes. Read from `_acpmux/info`,
/// which names the chat's workspace to this local link only; a chat acpmux
/// cannot answer for is hidden (fail closed).
fn visible(link: &AcpmuxLink, session: &str, hides: &dyn Fn(&str) -> bool) -> bool {
    // The session list holds the env: no wait for the chat logs.
    let params = json!({"sessionId": session, "waitLogs": false});
    let Ok(info) = link.call("_acpmux/info", params, CALL_TIMEOUT) else {
        return false;
    };
    let recorded = info.get("workspaceId").and_then(Value::as_str);
    let env = info.pointer("/sessionEnv/CMUX_WORKSPACE_ID").and_then(Value::as_str);
    [recorded, env].into_iter().flatten().all(|id| !hides(id))
}

/// Whether the workspace a chat names is incognito. The chat may name it in
/// another spelling than the store's (an uppercase or dashless UUID), so
/// every form the key may be stored in is checked.
pub(super) fn hides_workspace(mux: &Mux, id: &str) -> bool {
    workspace_key_forms(id).iter().any(|key| mux.workspace_key_is_ephemeral(key))
}

/// `id` as given, lowercased, and as the store's dashed lowercase UUID
/// (`Mux::new_workspace_key`) when it is one.
fn workspace_key_forms(id: &str) -> Vec<String> {
    let mut forms = vec![id.to_owned(), id.to_ascii_lowercase()];
    let hex = crate::state::agent_message_policy::workspace_key(id);
    if hex.len() == 32 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        let mut dashed = String::with_capacity(36);
        for (index, digit) in hex.chars().enumerate() {
            if matches!(index, 8 | 12 | 16 | 20) {
                dashed.push('-');
            }
            dashed.push(digit);
        }
        forms.push(dashed);
    }
    forms.sort();
    forms.dedup();
    forms
}

/// The answer a chat the phone may not see gets: the same as one that does not exist.
fn not_found() -> (&'static str, String) {
    ("acpmux_refused", "unknown session".into())
}

fn bounded_page_params(params: &Value) -> Result<Value, (&'static str, String)> {
    let mut result = Map::new();
    for key in ["limit", "cursor", "status"] {
        if let Some(value) = params.get(key) {
            result.insert(key.into(), value.clone());
        }
    }
    check_limit(result.get("limit"), "limit")?;
    Ok(Value::Object(result))
}

fn bounded_limit(params: &Value, key: &str) -> Result<Option<u64>, (&'static str, String)> {
    check_limit(params.get(key), key)
}

fn check_limit(value: Option<&Value>, key: &str) -> Result<Option<u64>, (&'static str, String)> {
    let Some(value) = value else { return Ok(None) };
    let Some(limit) = value.as_u64() else {
        return Err(("bad_request", format!("{key} must be an integer")));
    };
    if limit == 0 || limit > MAX_LIMIT {
        return Err(("bad_request", format!("{key} must be between 1 and {MAX_LIMIT}")));
    }
    Ok(Some(limit))
}

fn normalize_sessions(raw: Value, machine_id: Option<&str>) -> Value {
    let rows = raw.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let sessions = rows.into_iter().filter_map(|row| {
        let id = row
            .get("sessionId")
            .or_else(|| row.get("id"))
            .and_then(Value::as_str)?
            .to_owned();
        let title = row.get("title").or_else(|| row.get("name")).and_then(Value::as_str)
            .unwrap_or(&id).to_owned();
        let state = row.get("status").or_else(|| row.get("state")).and_then(Value::as_str)
            .unwrap_or("unknown").to_owned();
        Some(json!({"id": id, "title": title,
            "machine_id": machine_id.or_else(|| row.get("machineId").and_then(Value::as_str)),
            "state": state,
            "updated_at": row.get("updatedAt").or_else(|| row.get("updated_at")).cloned().unwrap_or(Value::Null)}))
    }).collect::<Vec<_>>();
    json!({"sessions": sessions, "next_cursor": raw.get("nextCursor").cloned().unwrap_or(Value::Null)})
}

fn normalize_history(raw: Value, session_id: &str) -> Result<Value, (&'static str, String)> {
    let events = raw.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
    let messages = events
        .into_iter()
        .enumerate()
        .filter_map(|(index, event)| {
            let record = event.get("record").or_else(|| event.get("msg")).unwrap_or(&event);
            let kind = record
                .get("kind")
                .or_else(|| record.get("type"))
                .or_else(|| record.pointer("/params/update/sessionUpdate"))
                .or_else(|| event.pointer("/msg/params/update/sessionUpdate"))
                .or_else(|| event.get("kind"))
                .or_else(|| event.get("type"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let role = match kind.as_str() {
                "user" | "user_message" | "prompt" | "human" => "user",
                "assistant"
                | "assistant_message"
                | "assistant_message_chunk"
                | "assistant_chunk"
                | "agent"
                | "agent_message"
                | "agent_message_chunk"
                | "agent_message_delta"
                | "response" => "assistant",
                "system" | "system_message" => "system",
                "tool" | "tool_message" | "tool_result" => "tool",
                _ => return None,
            };
            let text = event_text(record)?;
            let id = record
                .get("id")
                .or_else(|| record.get("seq"))
                .or_else(|| event.get("id"))
                .or_else(|| event.get("seq"))
                .and_then(value_as_string)
                .unwrap_or_else(|| format!("{session_id}:{index}"));
            let created_at = record
                .get("createdAt")
                .or_else(|| record.get("created_at"))
                .or_else(|| record.get("at"))
                .or_else(|| record.get("timestamp"))
                .or_else(|| event.get("createdAt"))
                .or_else(|| event.get("at"))
                .or_else(|| event.get("timestamp"))
                .cloned()
                .unwrap_or(Value::Null);
            Some(json!({"id": id, "role": role, "text": text, "created_at": created_at}))
        })
        .collect::<Vec<_>>();
    let next_cursor = raw
        .get("nextCursor")
        .or_else(|| raw.get("next_cursor"))
        .or_else(|| raw.get("nextSeq"))
        .or_else(|| raw.get("next_seq"))
        .cloned()
        .unwrap_or(Value::Null);
    let result =
        json!({"session_id": session_id, "messages": messages, "next_cursor": next_cursor});
    let bytes = serde_json::to_vec(&result)
        .map_err(|_| ("acpmux_invalid", "history could not be encoded".into()))?;
    if bytes.len() > MAX_HISTORY_RESPONSE_BYTES {
        return Err(("response_too_large", "history exceeds the mobile response limit".into()));
    }
    Ok(result)
}

fn value_as_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.as_i64().map(|number| number.to_string()))
        .or_else(|| value.as_u64().map(|number| number.to_string()))
}

fn event_text(value: &Value) -> Option<String> {
    for key in ["text", "answer"] {
        if let Some(text) = value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty()) {
            return Some(text.to_owned());
        }
    }
    for key in ["message", "msg", "params", "update"] {
        if let Some(nested) = value.get(key)
            && let Some(text) = event_text(nested)
        {
            return Some(text);
        }
    }
    if let Some(content) = value.get("content") {
        if let Some(text) = content.as_str() {
            return (!text.is_empty()).then(|| text.to_owned());
        }
        if let Some(text) = content.get("text").and_then(Value::as_str) {
            return (!text.is_empty()).then(|| text.to_owned());
        }
        if let Some(parts) = content.as_array() {
            let text = parts
                .iter()
                .filter_map(|part| {
                    part.get("text").and_then(Value::as_str).or_else(|| part.as_str())
                })
                .collect::<Vec<_>>()
                .join("");
            return (!text.is_empty()).then_some(text);
        }
    }
    None
}

fn required_text(params: &Value, key: &str) -> Result<String, (&'static str, String)> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.trim().is_empty())
        .map(str::to_owned)
        .ok_or(("bad_request", format!("{key} is required")))
}

fn link_error(error: LinkError) -> (&'static str, String) {
    match error {
        LinkError::Rpc(message, _) => ("acpmux_refused", message),
        LinkError::MethodNotFound(message) => ("unsupported", message),
        LinkError::Timeout => ("timeout", "acpmux did not answer in time".into()),
        LinkError::Busy => ("busy", "acpmux is busy".into()),
        LinkError::Closed => ("unavailable", "acpmux connection closed".into()),
        LinkError::BadList(message) => ("acpmux_invalid", message),
    }
}

fn refuse(writer: &MessageWriter, id: Option<Value>, code: &'static str, message: &str) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(message.to_owned()),
            error_code: Some(code.to_owned()),
            error_delivery: None,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    fn scripted(
        results: Vec<Value>,
        accepted: Option<SyncSender<PromptOutcome>>,
    ) -> (Arc<AcpmuxLink>, cmux_unix_socket::TestDir) {
        scripted_seen(results, accepted, None)
    }

    /// `scripted`, also handing each request the server reads to `seen`.
    fn scripted_seen(
        results: Vec<Value>,
        accepted: Option<SyncSender<PromptOutcome>>,
        seen: Option<std::sync::mpsc::Sender<Value>>,
    ) -> (Arc<AcpmuxLink>, cmux_unix_socket::TestDir) {
        let dir = cmux_unix_socket::short_test_dir("mobile-chat");
        let socket = dir.path().join("acpmux.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut writer = stream.try_clone().unwrap();
            let mut lines = BufReader::new(stream).lines();
            for result in results {
                let Some(Ok(line)) = lines.next() else { return };
                let request: Value = serde_json::from_str(&line).unwrap();
                if let Some(seen) = &seen {
                    let _ = seen.send(request.clone());
                }
                let accepted = result.get("$accept").is_some();
                if accepted {
                    writeln!(
                        writer,
                        "{}",
                        json!({"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"sessionId":"s1","promptId":"p1","turnId":"t1","queued":false}})
                    )
                    .unwrap();
                }
                if let Some(message) = result.get("$error").and_then(Value::as_str) {
                    writeln!(
                        writer,
                        "{}",
                        json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32000,"message":message}})
                    )
                    .unwrap();
                } else {
                    let mut value = result;
                    if let Some(object) = value.as_object_mut() {
                        object.remove("$accept");
                    }
                    writeln!(
                        writer,
                        "{}",
                        json!({"jsonrpc":"2.0","id":request["id"],"result":value})
                    )
                    .unwrap();
                }
            }
        });
        let link = AcpmuxLink::connect(&socket, move |inbound| {
            if let (Some(sender), Inbound::Notification(method, params)) = (&accepted, inbound)
                && method == "_acpmux/prompt_accepted"
            {
                let _ = sender.try_send(PromptOutcome::Accepted(params));
            }
        })
        .unwrap();
        (link, dir)
    }

    const INCOGNITO: &str = "0f0e0d0c-0b0a-0908-0706-050403020100";

    fn none(_: &str) -> bool {
        false
    }

    fn incognito(id: &str) -> bool {
        workspace_key_forms(id).iter().any(|key| key == INCOGNITO)
    }

    /// `_acpmux/info` for a chat of an ordinary workspace.
    fn shown() -> Value {
        json!({"sessionId": "s1", "workspaceId": "11111111-2222-3333-4444-555555555555"})
    }

    #[test]
    fn relay_normalizes_sessions_and_actual_acp_records() {
        let (link, _dir) = scripted(
            vec![
                json!({
                    "sessions": [{"sessionId":"s1","name":"Cloud","status":"running","updatedAt":42}]
                }),
                shown(),
            ],
            None,
        );
        let sessions = dispatch(
            &link,
            "mobile-chat-sessions",
            json!({"machine_id":"vm_1","limit":20}),
            Some("vm_1"),
            None,
            &none,
        )
        .unwrap();
        assert_eq!(sessions["sessions"][0]["machine_id"], "vm_1");

        let (link, _dir) = scripted(
            vec![
                shown(),
                json!({
                    "events": [
                        {"sessionId":"s1","seq":1,"at":10,"kind":"user_message","msg":{"text":"hello"}},
                        {"sessionId":"s1","seq":2,"at":11,"kind":"message","msg":{"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}}
                    ], "nextSeq":3
                }),
            ],
            None,
        );
        let history = dispatch(
            &link,
            "mobile-chat-history",
            json!({"session_id":"s1","limit":20}),
            None,
            None,
            &none,
        )
        .unwrap();
        assert_eq!(history["messages"].as_array().unwrap().len(), 2);
        assert_eq!(history["messages"][0]["text"], "hello");
        assert_eq!(history["messages"][1]["role"], "assistant");
        assert_eq!(history["messages"][1]["text"], "hi");
    }

    #[test]
    fn history_answers_without_waiting_for_a_restarted_daemons_log_restore() {
        let (seen, requests) = std::sync::mpsc::channel();
        let (link, _dir) =
            scripted_seen(vec![shown(), json!({"events": [], "nextSeq": 1})], None, Some(seen));
        dispatch(&link, "mobile-chat-history", json!({"session_id":"s1"}), None, None, &none)
            .unwrap();
        let attach = requests.try_iter().find(|r| r["method"] == "_acpmux/attach").unwrap();
        assert_eq!(attach["params"]["waitLogs"], json!(false), "{attach}");
    }

    #[test]
    fn relay_send_waits_for_prompt_acceptance_and_surfaces_errors() {
        let (tx, rx) = sync_channel(2);
        let (link, _dir) = scripted(vec![shown(), json!({"$accept": true})], Some(tx.clone()));
        let accepted = dispatch(
            &link,
            "mobile-chat-send",
            json!({"session_id":"s1","text":"hello","prompt_id":"p1"}),
            None,
            Some((rx, tx)),
            &none,
        )
        .unwrap();
        assert_eq!(accepted["accepted"], true);
        assert_eq!(accepted["turn_id"], "t1");

        let (tx, rx) = sync_channel(2);
        let (link, _dir) = scripted(vec![shown(), json!({"$error":"permission.denied"})], None);
        let error = dispatch(
            &link,
            "mobile-chat-send",
            json!({"session_id":"s1","text":"hello","prompt_id":"p1"}),
            None,
            Some((rx, tx)),
            &none,
        )
        .unwrap_err();
        assert_eq!(error.0, "acpmux_refused");
        assert!(error.1.contains("permission.denied"));
    }

    #[test]
    fn relay_send_marks_the_prompt_as_the_phones() {
        let (seen_tx, seen_rx) = std::sync::mpsc::channel();
        let (tx, rx) = sync_channel(2);
        let (link, _dir) =
            scripted_seen(vec![shown(), json!({"$accept": true})], Some(tx.clone()), Some(seen_tx));
        dispatch(
            &link,
            "mobile-chat-send",
            json!({"session_id":"s1","text":"hello","prompt_id":"p1"}),
            None,
            Some((rx, tx)),
            &none,
        )
        .unwrap();
        let info = seen_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(info["method"], "_acpmux/info");
        let request = seen_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(request["method"], "session/prompt");
        assert_eq!(request["params"]["_meta"]["acpmux"]["via"], "cloud-mobile");
        assert_eq!(request["params"]["_meta"]["acpmux"]["promptId"], "p1");
    }

    /// An incognito workspace's chat stays off the phone: not listed, its history
    /// and a send answered as an unknown chat (`PhoneAccessGate.hidesWorkspace`).
    #[test]
    fn incognito_chats_never_reach_the_phone() {
        let (link, _dir) = scripted(
            vec![
                json!({"sessions": [{"sessionId":"s1","name":"Shown"},{"sessionId":"s2","name":"Hidden"}]}),
                shown(),
                json!({"sessionId": "s2", "workspaceId": INCOGNITO}),
            ],
            None,
        );
        let sessions =
            dispatch(&link, "mobile-chat-sessions", json!({}), None, None, &incognito).unwrap();
        let ids: Vec<&str> = sessions["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["s1"]);

        // Named by its env only, as a chat started from the workspace's terminal is.
        // In another spelling than the store's, as the Mac app's uppercase UUID is.
        let env = json!({"sessionId": "s2",
                         "sessionEnv": {"CMUX_WORKSPACE_ID": INCOGNITO.to_uppercase()}});
        let (link, _dir) = scripted(vec![env.clone()], None);
        let history = dispatch(
            &link,
            "mobile-chat-history",
            json!({"session_id":"s2"}),
            None,
            None,
            &incognito,
        )
        .unwrap_err();
        assert_eq!(history.1, "unknown session");

        let (tx, rx) = sync_channel(2);
        let (link, _dir) = scripted(vec![env], None);
        let send = dispatch(
            &link,
            "mobile-chat-send",
            json!({"session_id":"s2","text":"hello","prompt_id":"p1"}),
            None,
            Some((rx, tx)),
            &incognito,
        )
        .unwrap_err();
        assert_eq!(send.1, "unknown session");
    }
}
