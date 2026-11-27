use serde_json::json;

use super::*;

#[test]
fn a_layout_rejects_an_oversized_count_without_allocating_it() {
    assert_eq!(Layout::parse(&json!({"terminals": [0]}), usize::MAX), None);
}

fn pane(terminals: &[usize]) -> Layout {
    Layout::Pane { terminals: terminals.to_vec() }
}

#[test]
fn a_layout_names_every_terminal_once() {
    let tree = json!({"split": "right", "ratio": 0.3, "first": {"terminals": [0, 2]}, "second": {"terminals": [1.0]}});
    let layout = Layout::parse(&tree, 3).unwrap();
    assert_eq!(
        layout,
        Layout::Split {
            direction: Direction::Right,
            ratio: 0.3,
            first: Box::new(pane(&[0, 2])),
            second: Box::new(pane(&[1]))
        }
    );
    assert_eq!(layout.terminals(), vec![0, 2, 1]);
    // Missing, repeated or out-of-range indices refuse the tree.
    assert_eq!(Layout::parse(&tree, 4), None);
    assert_eq!(Layout::parse(&json!({"terminals": [0, 0]}), 1), None);
    assert_eq!(Layout::parse(&json!({"terminals": [0, 1]}), 1), None);
    assert_eq!(Layout::parse(&json!({"terminals": [0]}), 1), Some(pane(&[0])));
}

#[test]
fn a_pane_needs_whole_indices() {
    assert_eq!(Layout::parse(&json!({"terminals": []}), 0), None);
    assert_eq!(Layout::parse(&json!({"terminals": [0.5]}), 1), None);
    assert_eq!(Layout::parse(&json!({"terminals": [-1]}), 1), None);
    assert_eq!(Layout::parse(&json!({"terminals": ["0"]}), 1), None);
}

#[test]
fn a_split_needs_a_direction_and_both_children() {
    let child = json!({"terminals": [0]});
    let other = json!({"terminals": [1]});
    assert_eq!(Layout::parse(&json!({"split": "left", "first": child, "second": other}), 2), None);
    assert_eq!(Layout::parse(&json!({"first": child, "second": other}), 2), None);
    assert_eq!(Layout::parse(&json!({"split": "down", "first": child}), 2), None);
    assert_eq!(
        Layout::parse(&json!({"split": "down", "first": child, "second": {"split": "x"}}), 2),
        None
    );
    assert_eq!(Layout::parse(&json!("pane"), 0), None);
    // The ratio defaults to half and stays strictly inside (0, 1).
    for ratio in [json!(null), json!(0), json!(1), json!(1.5), json!("0.2")] {
        let tree = json!({"split": "down", "ratio": ratio, "first": child, "second": other});
        let Some(Layout::Split { direction, ratio, .. }) = Layout::parse(&tree, 2) else {
            panic!("{tree}")
        };
        assert_eq!((direction, ratio), (Direction::Down, 0.5));
    }
}

#[test]
fn a_layout_round_trips_as_json() {
    let layout = Layout::Split {
        direction: Direction::Down,
        ratio: 0.25,
        first: Box::new(pane(&[1])),
        second: Box::new(pane(&[0])),
    };
    let value = serde_json::to_value(&layout).unwrap();
    assert_eq!(value["kind"], "split");
    assert_eq!(value["direction"], "down");
    assert_eq!(value["first"], json!({"kind": "pane", "terminals": [1]}));
    assert_eq!(serde_json::from_value::<Layout>(value).unwrap(), layout);
}

#[test]
fn a_classic_agent_carries_its_resume_session() {
    let surface = json!({
        "id": "s1", "type": "terminal", "title": "Claude",
        "resume_binding": {"kind": "claude", "command": "claude --dangerously-skip", "launch_command": "claude --resume 'abc'", "cwd": "/b"},
    });
    let item = classic_item(&surface, "w1", Some("/w")).unwrap();
    assert_eq!(
        item,
        ClassicItem {
            source_surface: "s1".into(),
            workspace: "w1".into(),
            kind: "agent".into(),
            title: "Claude".into(),
            cwd: Some("/b".into()),
            ssh_target: None,
            agent_harness: Some("claude".into()),
            agent_session_id: Some("abc".into()),
        }
    );
    let value = serde_json::to_value(&item).unwrap();
    assert_eq!(value["agentSessionID"], "abc");
    assert_eq!(value["sourceSurface"], "s1");
}

#[test]
fn a_classic_terminal_without_a_session_reopens_as_a_shell() {
    // An agent kind with no session id, or another kind, is a terminal.
    let surface = json!({"ref": "surface:2", "type": "pty", "resume_binding": {"kind": "gemini", "command": "gemini --resume x"}});
    let item = classic_item(&surface, "w", Some("/w")).unwrap();
    assert_eq!((item.source_surface.as_str(), item.kind.as_str()), ("surface:2", "terminal"));
    assert_eq!((item.agent_harness, item.agent_session_id), (None, None));
    assert_eq!(item.cwd.as_deref(), Some("/w"));
    assert_eq!(item.title, "");
    let codex = json!({"id": "s", "type": "terminal", "resume_binding": {"kind": "codex", "command": "codex"}});
    assert_eq!(classic_item(&codex, "w", None).unwrap().kind, "terminal");
}

#[test]
fn a_classic_surface_must_be_a_terminal_with_an_id() {
    assert_eq!(classic_item(&json!({"id": "s", "type": "browser"}), "w", None), None);
    assert_eq!(classic_item(&json!({"id": "s"}), "w", None), None);
    assert_eq!(classic_item(&json!({"type": "terminal"}), "w", None), None);
    assert_eq!(classic_item(&json!(["s"]), "w", None), None);
}

#[test]
fn a_classic_cwd_and_ssh_target_follow_their_order() {
    let surface = json!({
        "id": "s", "type": "terminal", "requested_working_directory": "/r",
        "initial_command": "ssh -p 22 dev@box", "resume_binding": {"command": "ssh other", "cwd": "/b"},
    });
    let item = classic_item(&surface, "w", Some("/w")).unwrap();
    assert_eq!(item.cwd.as_deref(), Some("/r"));
    assert_eq!(item.ssh_target.as_deref(), Some("dev@box"));
    let binding_only =
        json!({"id": "s", "type": "terminal", "resume_binding": {"command": "ssh other"}});
    assert_eq!(
        classic_item(&binding_only, "w", None).unwrap().ssh_target.as_deref(),
        Some("other")
    );
    let named = json!({"id": "s", "type": "terminal", "ssh_target": "named", "initial_command": "ssh other"});
    assert_eq!(classic_item(&named, "w", None).unwrap().ssh_target.as_deref(), Some("named"));
}

#[test]
fn a_resume_command_names_its_session() {
    assert_eq!(agent_session_id("claude", Some("claude --resume abc")).as_deref(), Some("abc"));
    assert_eq!(agent_session_id("claude", Some("claude\t-r \"abc\"")).as_deref(), Some("abc"));
    assert_eq!(
        agent_session_id("claude", Some("claude  --session-id  abc --x")).as_deref(),
        Some("abc")
    );
    assert_eq!(agent_session_id("codex", Some("codex resume 'id-1'")).as_deref(), Some("id-1"));
    // The other harness's flag, a flag in the id's place, no id or no command: none.
    assert_eq!(agent_session_id("codex", Some("claude --resume abc")), None);
    assert_eq!(agent_session_id("claude", Some("claude --resume --verbose")), None);
    assert_eq!(agent_session_id("claude", Some("claude --resume ''")), None);
    assert_eq!(agent_session_id("claude", Some("claude --resume")), None);
    assert_eq!(agent_session_id("claude", None), None);
}

#[test]
fn an_ssh_command_names_its_host() {
    assert_eq!(ssh_target(Some("ssh box")).as_deref(), Some("box"));
    assert_eq!(
        ssh_target(Some("/usr/bin/ssh -A -o X=y -J jump -- 'me@box' ls")).as_deref(),
        Some("me@box")
    );
    assert_eq!(ssh_target(Some("exec ssh -p 2222 \"h\"")).as_deref(), Some("h"));
    assert_eq!(ssh_target(Some("ssh -p")), None);
    assert_eq!(ssh_target(Some("ssh -v")), None);
    assert_eq!(ssh_target(Some("mosh box")), None);
    assert_eq!(ssh_target(None), None);
}

#[test]
fn an_ssh_terminal_reopens_with_a_quoted_target() {
    assert_eq!(ssh_command("me@box"), "exec ssh -- 'me@box'");
    assert_eq!(ssh_command("it's"), "exec ssh -- 'it'\\''s'");
}

#[test]
fn an_older_peer_has_no_transfer_method() {
    for code in ["method_not_found", "unknown_method", "unsupported", "unavailable"] {
        assert!(is_missing_transfer_method(code), "{code}");
    }
    assert!(!is_missing_transfer_method("terminal_busy"));
}

#[test]
fn a_chat_move_names_its_flags() {
    assert_eq!(
        transfer_arguments("s", "/sock", false, None),
        ["--json", "transfer", "s", "--to", "/sock"]
    );
    assert_eq!(
        transfer_arguments("s", "/sock", true, Some("/here")),
        ["--json", "transfer", "s", "--to", "/sock", "--interrupt", "--cwd", "/here"]
    );
    assert_eq!(moved_session(r#"{"sessionId":"new"}"#, "s"), "new");
    assert_eq!(moved_session("{}", "s"), "s");
    assert_eq!(moved_session("not json", "s"), "s");
}

#[test]
fn a_failed_chat_move_reads_its_last_error_line() {
    let missing = "starting\n{\"error\":{\"detail\":\"cwd_missing\",\"message\":\"no folder\",\"data\":{\"cwd\":\"/gone\"}}}\n";
    assert_eq!(acpmux_failure(missing, 1), ChatFailure::FolderMissing { folder: "/gone".into() });
    // cwd_missing without its folder falls to the message.
    let bare = r#"{"error":{"detail":"cwd_missing","message":"no folder"}}"#;
    assert_eq!(acpmux_failure(bare, 1), ChatFailure::NotMoved { reason: "no folder".into() });
    assert_eq!(
        acpmux_failure(r#"{"error":"busy"}"#, 1),
        ChatFailure::NotMoved { reason: "busy".into() }
    );
    assert_eq!(
        acpmux_failure("  plain text\n", 2),
        ChatFailure::NotMoved { reason: "plain text".into() }
    );
    assert_eq!(
        acpmux_failure(r#"{"error":{"code":1}}"#, 3),
        ChatFailure::NotMoved { reason: r#"{"error":{"code":1}}"#.into() }
    );
    assert_eq!(
        acpmux_failure("", 9),
        ChatFailure::NotMoved { reason: "acpmux exited with 9".into() }
    );
    assert_eq!(
        serde_json::to_value(ChatFailure::FolderMissing { folder: "/f".into() }).unwrap(),
        json!({"kind": "folderMissing", "folder": "/f"})
    );
}

#[test]
fn a_peer_identity_skips_this_build() {
    assert_eq!(identity(&json!({"pid": 7, "app": "cmux NEXT"}), 7), None);
    assert_eq!(identity(&json!("x"), 7), None);
    assert_eq!(
        identity(
            &json!({"pid": 8, "app": "cmux NEXT", "build": "42", "version": "1.0", "tag": "dev"}),
            7
        ),
        Some(Identity {
            app: "cmux NEXT".into(),
            build: "42".into(),
            tag: Some("dev".into()),
            bundle_identifier: None,
            pid: 8
        })
    );
    // Classic: no pid or tag, the version for its build, the bundle id for its tag.
    assert_eq!(
        identity(&json!({"version": "0.9", "bundle_identifier": "com.cmuxterm.app.debug.x"}), 7),
        Some(Identity {
            app: "cmux".into(),
            build: "0.9".into(),
            tag: None,
            bundle_identifier: Some("com.cmuxterm.app.debug.x".into()),
            pid: 0
        })
    );
    assert_eq!(identity(&json!({"socket_path": "/s"}), 7).unwrap().build, "");
}
