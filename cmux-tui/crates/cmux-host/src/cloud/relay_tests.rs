use super::*;

fn chat_frame(extra: Value) -> String {
    let mut v = json!({"v": 1, "t": "chat", "id": "c1", "agent": "claude", "prompt": "say hi"});
    if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
        for (k, x) in e {
            o.insert(k.clone(), x.clone());
        }
    }
    v.to_string()
}

#[test]
fn parses_a_chat_and_a_cancel() {
    let Down::Chat(c) = parse_down(&chat_frame(json!({"cwd": "/home/cmux", "prompt_id": "p-1"})))
    else {
        panic!("not a chat")
    };
    assert_eq!(c.agent, "claude");
    assert_eq!(c.cwd.as_deref(), Some("/home/cmux"));
    assert_eq!(c.prompt_id, "p-1");
    assert_eq!(c.session, None);
    let Down::Chat(c) = parse_down(&chat_frame(json!({}))) else { panic!("not a chat") };
    assert_eq!(c.prompt_id, "relay-c1");
    assert_eq!(parse_down(r#"{"v":1,"t":"cancel","id":"c1"}"#), Down::Cancel("c1".into()));
}

#[test]
fn refuses_what_could_reach_a_flag_or_a_shell() {
    for bad in [
        json!({"agent": "--help"}),
        json!({"agent": "Claude"}),
        json!({"agent": "claude; rm -rf /"}),
        json!({"prompt": "   "}),
        json!({"cwd": "relative"}),
        json!({"session": "-x"}),
        json!({"agent": "opencode/-x"}),
        json!({"agent": "opencode/a/b/c/d/e"}),
        json!({"prompt_id": "--no-wait"}),
        json!({"id": "-c"}),
    ] {
        assert_eq!(parse_down(&chat_frame(bad.clone())), Down::Other, "{bad}");
    }
    assert_eq!(parse_down("not json"), Down::Other);
    assert_eq!(parse_down(r#"{"v":2,"t":"cancel","id":"c1"}"#), Down::Other);
    assert_eq!(parse_down(r#"{"v":1,"t":"hello","id":"x"}"#), Down::Other);
    // acpmux's nested models are fine.
    for agent in ["codex/gpt-5.5", "opencode/zai/glm-5.1"] {
        assert!(
            matches!(parse_down(&chat_frame(json!({"agent": agent}))), Down::Chat(_)),
            "{agent}"
        );
    }
}

#[test]
fn builds_the_acpmux_commands() {
    let Down::Chat(c) = parse_down(&chat_frame(json!({"prompt_id": "p-1"}))) else { panic!() };
    assert_eq!(
        new_args(&c, "/home/cmux"),
        [
            "acp",
            "--json",
            "new",
            "-d",
            "--reuse",
            "-m",
            "claude",
            "-n",
            "relay-c1",
            "--cwd",
            "/home/cmux"
        ]
    );
    assert_eq!(
        send_args(&c, "sess-1"),
        ["acp", "--json", "send", "--wait", "--no-steer", "--prompt-id", "p-1", "sess-1", "-"]
    );
    assert_eq!(tail_args("sess-1"), ["acp", "--json", "tail", "--since", "0", "-f", "sess-1"]);
    // The prompt is never an argument.
    assert!(!send_args(&c, "s").iter().any(|a| a.contains("say hi")));
}

#[test]
fn maps_tail_lines_to_events() {
    let chunk = json!({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}}});
    assert_eq!(events_of(&chunk.to_string()), vec![json!({"kind": "text", "text": "hi"})]);
    let thought = json!({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hm"}}}});
    assert!(events_of(&thought.to_string()).is_empty());
    let record = json!({"method": "_acpmux/event", "params": {"seq": 7, "kind": "turn"}});
    assert_eq!(
        events_of(&record.to_string()),
        vec![json!({"kind": "record", "record": {"seq": 7, "kind": "turn"}, "seq": 7})]
    );
    let perm = json!({"method": "_acpmux/permission_pending", "params": {"permissionId": "x"}});
    assert_eq!(events_of(&perm.to_string())[0]["kind"], "permission");
    assert!(events_of("{").is_empty());
    assert!(events_of(r#"{"stopReason": "end_turn"}"#).is_empty());
    // `acp tail` prints a logged record bare, with its cursor.
    let bare = json!({"seq": 3, "cursor": "s:3", "type": "prompt"});
    assert_eq!(
        events_of(&bare.to_string()),
        vec![json!({"kind": "record", "record": bare, "seq": 3})]
    );
}

#[test]
fn ends_with_done_or_a_named_error() {
    assert_eq!(
        final_event(Some(0), "{\n  \"stopReason\": \"end_turn\"\n}\n", ""),
        json!({"kind": "done", "stop_reason": "end_turn"})
    );
    // `send --json --wait`'s one object: the whole reply goes with `done`.
    assert_eq!(
        final_event(
            Some(0),
            r#"{"sessionId": "s", "reply": "Hello", "stopReason": "end_turn"}"#,
            ""
        ),
        json!({"kind": "done", "stop_reason": "end_turn", "reply": "Hello"})
    );
    assert_eq!(final_event(Some(0), "", "")["stop_reason"], "end_turn");
    // acpmux: 2 usage, 3 timeout, 4 no session, 5 permission denied.
    assert_eq!(final_event(Some(2), "", "")["code"], "chat.failed");
    assert_eq!(final_event(Some(3), "", "")["code"], "chat.timeout");
    assert_eq!(final_event(Some(4), "", "")["code"], "chat.no_session");
    assert_eq!(final_event(Some(5), "", "")["code"], "chat.permission_denied");
    let e = final_event(Some(1), "", "warn\nacpmux: no such harness\n\n");
    assert_eq!(
        e,
        json!({"kind": "error", "code": "chat.failed", "message": "acpmux: no such harness"})
    );
}

#[test]
fn reads_the_created_session_and_the_url() {
    assert_eq!(
        created_session(r#"{"sessionId": "abc", "name": "relay-c1"}"#).as_deref(),
        Some("abc")
    );
    assert_eq!(created_session("nope"), None);
    assert_eq!(
        relay_url("https://platform.example/", "vm_0123").as_deref(),
        Some("wss://platform.example/v1/cloud/machines/vm_0123/relay")
    );
    assert_eq!(relay_url("http://platform.example", "vm_0123"), None);
    assert_eq!(relay_url("https://platform.example", "../x"), None);
}

#[test]
fn frames_an_event() {
    let f: Value = serde_json::from_str(&up("c1", json!({"kind": "done"}))).unwrap();
    assert_eq!(f, json!({"v": 1, "t": "event", "id": "c1", "event": {"kind": "done"}}));
}

#[test]
fn a_stop_drops_the_socket_at_once() {
    struct Socket(std::sync::Arc<std::sync::atomic::AtomicBool>);
    impl Drop for Socket {
        fn drop(&mut self) {
            self.0.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    for gone in [false, true] {
        let dropped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let socket = Socket(dropped.clone());
        let (tx, mut rx) = watch::channel(false);
        let serving = async move {
            let _socket = socket;
            std::future::pending::<()>().await;
        };
        let started = std::time::Instant::now();
        let out = rt.block_on(async {
            let stopper = async {
                tokio::time::sleep(Duration::from_millis(20)).await;
                // A rebind drops the Relay: the sender goes, or it says stop.
                if gone {
                    drop(tx);
                } else {
                    tx.send_replace(true);
                }
            };
            tokio::join!(or_stop(&mut rx, serving), stopper).0
        });
        assert_eq!(out, None);
        assert!(
            dropped.load(std::sync::atomic::Ordering::SeqCst),
            "the socket is dropped with its chats"
        );
        assert!(started.elapsed() < Duration::from_secs(2), "not at the next ping tick");
    }
}

#[test]
fn a_dropped_chat_cancels_its_turn_in_the_daemon() {
    assert_eq!(cancel_args("s-1"), ["acp", "cancel", "s-1"]);
}

#[test]
fn output_past_the_cap_is_drained_and_a_cut_reply_is_not_the_reply() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let (kept, more) = rt.block_on(read_capped(&b"0123456789"[..], 4));
    assert_eq!((kept.as_str(), more), ("0123", true));
    let (kept, more) = rt.block_on(read_capped(&b"0123"[..], 4));
    assert_eq!((kept.as_str(), more), ("0123", false));
    let cut = final_event_of(Some(0), r#"{"reply": "par"#, true, "");
    assert_eq!(cut, json!({"kind": "done", "stop_reason": "end_turn", "reply_cut": true}));
    let whole = final_event_of(Some(0), r#"{"reply": "all", "stopReason": "end_turn"}"#, false, "");
    assert_eq!(whole["reply"], "all");
}

#[test]
fn chats_whose_ids_share_a_prefix_get_their_own_sessions() {
    let chat = |id: &str| match parse_down(&chat_frame(json!({"id": id}))) {
        Down::Chat(chat) => chat,
        _ => panic!("a chat"),
    };
    let (a, b) = (chat("0123456789ab-first"), chat("0123456789ab-second"));
    assert_ne!(session_name(&a), session_name(&b));
    assert_eq!(session_name(&a), "relay-0123456789ab-first");
}

#[test]
fn the_up_queue_is_bounded() {
    let (tx, _rx) = up_queue();
    for n in 0..UP_QUEUE {
        tx.try_send(n.to_string()).expect("room for the queue's frames");
    }
    // A full queue holds the senders back: the tail reader awaits a slot, the socket drains it.
    assert!(matches!(tx.try_send("one more".into()), Err(mpsc::error::TrySendError::Full(_))));
}

#[test]
fn a_reader_past_its_grace_sends_nothing_after_it_ends() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let (tx, mut rx) = up_queue();
        let reader = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_millis(5)).await;
                if tx.send("late".into()).await.is_err() {
                    return;
                }
            }
        });
        end_reader(reader, Duration::from_millis(20)).await;
        while rx.try_recv().is_ok() {}
        tokio::time::sleep(Duration::from_millis(50)).await;
        // The reader is gone: its sender dropped, and nothing came after `end_reader` returned.
        assert!(matches!(rx.try_recv(), Err(mpsc::error::TryRecvError::Disconnected)));
    });
}

#[test]
fn a_chat_runs_with_its_users_own_groups_only() {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        eprintln!("skipped: dropping privilege needs root");
        return;
    }
    let runner = Runner {
        bin: PathBuf::from("/usr/bin/id"),
        user: "nobody".into(),
        uid: 65534,
        gid: 65534,
        groups: vec![65534],
        home: PathBuf::from("/"),
    };
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let out = rt.block_on(runner.command(&["-G".to_owned()]).output()).expect("id runs");
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "65534");
}
