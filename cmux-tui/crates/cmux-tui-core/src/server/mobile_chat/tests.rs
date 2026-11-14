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
                writeln!(writer, "{}", json!({"jsonrpc":"2.0","id":request["id"],"result":value}))
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
    dispatch(&link, "mobile-chat-history", json!({"session_id":"s1"}), None, None, &none).unwrap();
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
    let history =
        dispatch(&link, "mobile-chat-history", json!({"session_id":"s2"}), None, None, &incognito)
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
