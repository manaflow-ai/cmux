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
fn the_backoff_wait_runs_from_the_relay_thread_outside_any_runtime() {
    // run() waits between dials from its own plain thread, which is in no runtime: a wait that panics there
    // ends the relay thread, so the machine never dials the relay again after its first socket drops.
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let (_tx, mut rx) = watch::channel(false);
    let (_resume, mut resumes) = watch::channel(0);
    let started = std::time::Instant::now();
    let waited =
        std::thread::spawn(move || pause(&rt, &mut rx, &mut resumes, 0, Duration::from_millis(20)))
            .join();
    assert!(waited.is_ok(), "the wait panicked the relay thread");
    assert!(started.elapsed() >= Duration::from_millis(20), "it waited out the backoff");
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

#[cfg(target_os = "linux")]
#[test]
fn a_chats_process_exit_is_seen_with_sigchld_blocked() {
    // As in the agent: SIGCHLD blocked before the relay thread starts, so the thread inherits it.
    let waited = std::thread::spawn(|| {
        // SAFETY: plain libc signal-set calls on a local set, for this thread only.
        unsafe {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGCHLD);
            assert_eq!(libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()), 0);
        }
        assert!(child_waits_work());
        // SAFETY: geteuid and getegid have no preconditions.
        let (uid, gid) = unsafe { (libc::geteuid(), libc::getegid()) };
        let runner = Runner {
            bin: PathBuf::from("/bin/true"),
            user: "me".into(),
            uid,
            gid,
            groups: Vec::new(),
            home: PathBuf::from("/"),
        };
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        // Tokio's `status` spawns at once, so inside the runtime.
        rt.block_on(async {
            tokio::time::timeout(Duration::from_secs(10), runner.command(&[]).status()).await
        })
    })
    .join()
    .unwrap();
    assert!(waited.expect("the exit is seen within 10 s").expect("true runs").success());
}

/// acpmux's `--json` error envelope (`cli/errors.rs` `AppError::envelope`), as its last stderr line.
fn envelope(code: &str, exit: i32, detail: &str, retryable: bool, extra: Value) -> String {
    let mut error = json!({"code": code, "exit": exit, "detail": detail, "retryable": retryable,
        "message": format!("acpmux: {detail}"), "sessionId": null, "promptId": null});
    if let (Some(o), Some(e)) = (error.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            o.insert(k.clone(), v.clone());
        }
    }
    format!("warn: a line before\n{}\n", json!({"error": error}))
}

#[test]
fn an_acpmux_error_keeps_its_type_up_the_relay() {
    // The prod proof's failure (run 42112686310): the daemon closed while `session/new` waited.
    let e = final_event(Some(1), "", &envelope("runtime", 1, "daemon_closed", true, json!({})));
    assert_eq!(e["code"], "chat.failed");
    assert_eq!(e["detail"], "daemon_closed");
    assert_eq!(e["acpmux_code"], "runtime");
    assert_eq!(e["retryable"], true);
    // The message is acpmux's own sentence, never the envelope's raw JSON.
    assert_eq!(e["message"], "acpmux: daemon_closed");
    // A closed daemon's cause goes up with it: a panic is told apart from a restart.
    let e = final_event(
        Some(1),
        "",
        &envelope(
            "runtime",
            1,
            "daemon_closed",
            true,
            json!({"data": {"cause": "panicked", "panic": {"location": "src/a.rs:1:1"}}}),
        ),
    );
    assert_eq!(e["cause"], "panicked");
    assert!(e.get("panic").is_none(), "{e}");
    // The exit codes acpmux names keep their relay code, with the detail beside it.
    let e = final_event(
        Some(5),
        "",
        &envelope("permission_denied", 5, "trust_required", false, json!({})),
    );
    assert_eq!(
        (e["code"].as_str(), e["detail"].as_str()),
        (Some("chat.permission_denied"), Some("trust_required"))
    );
    assert_eq!(e["retryable"], false);
    let e = final_event(Some(3), "", &envelope("timeout", 3, "turn_timeout", true, json!({})));
    assert_eq!(
        (e["code"].as_str(), e["detail"].as_str()),
        (Some("chat.timeout"), Some("turn_timeout"))
    );
    // A typed agent failure (an auth one) names its kind.
    let e = final_event(
        Some(1),
        "",
        &envelope("runtime", 1, "agent_error", false, json!({"errorKind": "auth.signed_out"})),
    );
    assert_eq!(e["error_kind"], "auth.signed_out");
    // acpmux's recovery sentence goes up, bounded; a permission refusal keeps its detail beside it.
    let long = format!("Answer Trust for this folder. {}", "y".repeat(1_000));
    let e = final_event(
        Some(5),
        "",
        &envelope("permission_denied", 5, "trust_required", false, json!({"recovery": long})),
    );
    assert_eq!(e["detail"], "trust_required");
    let recovery = e["recovery"].as_str().unwrap();
    assert!(recovery.starts_with("Answer Trust") && recovery.chars().count() == 300, "{recovery}");
    // No exit status (a signal): the envelope's own exit decides the code.
    let e = final_event(None, "", &envelope("no_session", 4, "no_session", false, json!({})));
    assert_eq!(e["code"], "chat.no_session");
}

#[test]
fn an_error_with_no_envelope_stays_a_plain_failure() {
    for stderr in [
        "acpmux: no such harness\n",
        "{\"error\": 3}\n",
        "{\"error\": {\"code\": 7}}\n",
        "{not json\n",
        "",
    ] {
        let e = final_event(Some(1), "", stderr);
        assert_eq!(e["code"], "chat.failed", "{stderr}");
        for k in ["detail", "acpmux_code", "retryable", "error_kind"] {
            assert!(e.get(k).is_none(), "{k} for {stderr:?}: {e}");
        }
    }
}

#[test]
fn an_envelopes_fields_are_bounded_and_shaped() {
    let long = "x".repeat(5_000);
    let e = final_event(
        Some(1),
        "",
        &envelope(
            "runtime",
            1,
            &format!("bad detail {long}"),
            true,
            json!({"errorKind": &long, "message": &long}),
        ),
    );
    // A detail or kind that is not a short code is dropped; the message is cut as before.
    assert!(e.get("detail").is_none(), "{e}");
    assert!(e.get("error_kind").is_none(), "{e}");
    assert_eq!(e["message"].as_str().map(|m| m.chars().count()), Some(300));
    assert_eq!(e["acpmux_code"], "runtime");
}

#[cfg(unix)]
#[test]
fn a_failed_session_create_keeps_its_exit_and_its_type() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("acpmux");
    // A fake acpmux whose `acp --json new` fails as the prod daemon did, with exit 4 (no session).
    let err = envelope("no_session", 4, "daemon_closed", true, json!({}));
    std::fs::write(&bin, format!("#!/bin/sh\ncat >&2 <<'EOF'\n{err}EOF\nexit 4\n")).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    // SAFETY: geteuid and getegid have no preconditions.
    let (uid, gid) = unsafe { (libc::geteuid(), libc::getegid()) };
    let runner = Runner {
        bin,
        user: "me".into(),
        uid,
        gid,
        groups: Vec::new(),
        home: dir.path().to_owned(),
    };
    let Down::Chat(chat) = parse_down(&chat_frame(json!({}))) else { panic!("a chat") };
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let frames = rt.block_on(async {
        let (tx, mut rx) = up_queue();
        run_chat(chat, runner, tx).await;
        let mut frames = Vec::new();
        while let Ok(f) = rx.try_recv() {
            frames.push(serde_json::from_str::<Value>(&f).unwrap());
        }
        frames
    });
    assert_eq!(frames.len(), 1, "{frames:?}");
    let event = &frames[0]["event"];
    assert_eq!(event["code"], "chat.no_session", "{event}");
    assert_eq!(event["detail"], "daemon_closed");
    assert_eq!(event["retryable"], true);
}

#[test]
fn a_chat_counts_as_running_until_its_task_ends_or_is_aborted() {
    static COUNT: AtomicUsize = AtomicUsize::new(0);
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        let running = Running::start(&COUNT);
        let done = tokio::spawn(async move {
            let _running = running;
            let _ = wait.await;
        });
        assert_eq!(COUNT.load(Ordering::SeqCst), 1);
        let _ = release.send(());
        done.await.unwrap();
        assert_eq!(COUNT.load(Ordering::SeqCst), 0);

        // Aborted before it ever ran: the count still goes back down.
        let running = Running::start(&COUNT);
        let aborted = tokio::spawn(async move {
            let _running = running;
            std::future::pending::<()>().await;
        });
        assert_eq!(COUNT.load(Ordering::SeqCst), 1);
        aborted.abort();
        let _ = aborted.await;
        assert_eq!(COUNT.load(Ordering::SeqCst), 0);
    });
}
