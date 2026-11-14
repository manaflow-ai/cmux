use super::*;
pub(super) async fn app() -> (App, mpsc::UnboundedReceiver<Value>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let socket = std::env::temp_dir().join(format!("acpmux-ui-{}.sock", uuid::Uuid::now_v7()));
    let _ = std::fs::remove_file(&socket);
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let (sent, mut requests) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let msg: Value = serde_json::from_str(&line).unwrap();
            let _ = sent.send(msg.clone());
            let result = if msg["method"] == "session/new" {
                json!({"sessionId":"test-session"})
            } else {
                json!({})
            };
            let reply = json!({"jsonrpc":"2.0","id":msg["id"],"result":result}).to_string() + "\n";
            if writer.write_all(reply.as_bytes()).await.is_err() {
                break;
            }
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let _ = std::fs::remove_file(socket);
    let (tx, _) = mpsc::unbounded_channel();
    let mut app = run::make_app(client, tx, vec![], crate::config::Config::default()).unwrap();
    app.default_harness = Some("codex".into());
    app.harnesses = vec!["codex".into(), "claude".into()];
    app.open_draft();
    // Client::connect performs initialization before the fixture returns;
    // keep that setup request out of interaction assertions below.
    let _ = requests.recv().await;
    (app, requests)
}
#[tokio::test]
async fn refreshed_peer_harness_is_searchable_and_selectable() {
    let (mut app, _) = app().await;
    app.show_harness_picker(
        json!({"harnesses":[{"harness":"providers/deepseek"},{"harness":"providers/opencode-v2"}]}),
    );
    if let Overlay::Picker(ref mut picker) = app.overlay {
        picker.filter.insert_str("deepseek harness");
        picker.refilter();
        assert_eq!(picker.visible.len(), 1);
        assert_eq!(picker.selected().unwrap().value, "providers/deepseek");
    } else {
        panic!("harness picker missing");
    }
    app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
    let draft = app.draft().unwrap();
    assert_eq!(draft.peer.as_deref(), Some("providers"));
    assert_eq!(draft.harness, "deepseek");
}

/// The TUI offers steer from the session's own `steering` (acpmux sets it from the agent's
/// `_meta.steering` at initialize). It read `agentCapabilities._meta`, which acpmux never
/// stores, and a list row's `agentInfo`, which it never sends, so Ctrl-s never steered.
#[tokio::test]
async fn a_steering_session_offers_steer() {
    let (mut app, _) = app().await;
    app.sessions = vec![
        json!({"sessionId": "steers", "status": "running", "steering": true}),
        json!({"sessionId": "stops", "status": "running", "steering": false}),
    ];
    app.selected = app.drafts.len();
    assert!(app.selected_supports_steer(), "a steering session does not offer steer");
    app.selected = app.drafts.len() + 1;
    assert!(!app.selected_supports_steer(), "a session that cannot steer offers it");
}

/// Enter on a running turn steers when the agent steers and queues only when it cannot; Ctrl-s
/// queues (Leo, 2026-11-05: "wt* like no these default enters became queues?").
#[tokio::test]
async fn enter_steers_a_running_turn_and_ctrl_s_queues() {
    let (mut app, mut requests) = app().await;
    app.sessions = vec![
        json!({"sessionId": "steers", "status": "running", "steering": true}),
        json!({"sessionId": "stops", "status": "running", "steering": false}),
        json!({"sessionId": "idle", "status": "idle", "steering": true}),
    ];
    async fn sent(
        app: &mut App,
        requests: &mut mpsc::UnboundedReceiver<Value>,
        row: usize,
        text: &str,
        key: KeyEvent,
    ) -> bool {
        app.selected = app.drafts.len() + row;
        app.editor_mut().clear();
        app.editor_mut().insert_str(text);
        app.on_key(key);
        loop {
            // timeout: a test bound on an in-process request channel; a hang fails the test instead of hanging the suite
            let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
                .await
                .unwrap()
                .unwrap();
            if msg["method"] == "session/prompt" {
                return msg["params"]["_meta"]["acpmux"]["steer"].as_bool().unwrap();
            }
        }
    }
    let enter = KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE);
    let ctrl_s = KeyEvent::new(KeyCode::Char('s'), KeyModifiers::CONTROL);
    assert!(
        sent(&mut app, &mut requests, 0, "also this", enter).await,
        "Enter queued on a steering agent"
    );
    assert!(!sent(&mut app, &mut requests, 0, "after this", ctrl_s).await, "Ctrl-s did not queue");
    assert!(!sent(&mut app, &mut requests, 0, "/compact", enter).await, "a slash command steered");
    assert!(
        !sent(&mut app, &mut requests, 1, "also this", enter).await,
        "steered an agent that cannot"
    );
    assert!(
        !sent(&mut app, &mut requests, 2, "hello", enter).await,
        "steered with no turn running"
    );
    // A turn waiting on a permission is still open and takes a steer (#39568 F1).
    app.sessions[2]["status"] = json!("waiting");
    assert!(
        sent(&mut app, &mut requests, 2, "also this", enter).await,
        "a turn waiting on a permission queued"
    );
    // Help and the palette name Enter for Send and Steer, which no keymap binding runs (F3).
    let steer = actions::def(actions::Action::Steer);
    assert_eq!(steer.shown_keys(&app.keymap), steer.keys);
    let queue = actions::def(actions::Action::Queue);
    assert_eq!(queue.shown_keys(&app.keymap), app.keymap.hints("queue"));
    assert!(!queue.shown_keys(&app.keymap).is_empty());
}

#[tokio::test]
async fn lagged_recovery_replays_from_each_transcript_cursor() {
    let (mut app, mut requests) = app().await;
    let id = "test-session";
    app.sessions = vec![json!({"sessionId": id})];
    app.selected = 0;
    app.attached.insert(id.into());
    let mut transcript = Transcript::default();
    transcript.last_seq = 41;
    app.transcripts.insert(id.into(), transcript);

    app.on_notification("_acpmux/lagged", json!({"dropped": 3}));
    assert_eq!(app.status, "event stream lagged; recovering 1 session(s)…");

    let request = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(request["method"], method::MUX_ATTACH);
    assert_eq!(request["params"]["sessionId"], id);
    assert_eq!(request["params"]["afterSeq"], 41);
    assert_eq!(request["params"]["limit"], 3000);

    // A second lag notification while the replay is in flight does not
    // fan out another request for the same session.
    app.on_notification("_acpmux/lagged", json!({"dropped": 1}));
    assert_eq!(app.status, "event stream lagged; recovery required");
}

#[tokio::test]
async fn recovery_attach_merges_only_new_records_and_clears_the_guard() {
    let (mut app, _) = app().await;
    let id = "test-session";
    let mut transcript = Transcript::default();
    transcript.last_seq = 41;
    app.transcripts.insert(id.into(), transcript);
    app.recovery_in_flight.insert(id.into());

    app.on_msg(AppMsg::Attached {
        id: id.into(),
        detail: json!({"status": "running"}),
        events: vec![
            json!({"seq": 41, "dir": "mux", "kind": "user_message", "msg": {"text": "old"}}),
            json!({"seq": 42, "dir": "mux", "kind": "user_message", "msg": {"text": "new"}}),
        ],
        after_seq: Some(40),
        has_more: false,
        last_seq: 42,
    });

    let transcript = app.transcripts.get(id).unwrap();
    assert_eq!(transcript.last_seq, 42);
    assert_eq!(
        transcript.items,
        vec![Item::User { text: "new".into(), steer: false, queued: false }]
    );
    assert!(!app.recovery_in_flight.contains(id));
    assert_eq!(app.status, "recovered 1 events from seq 40");
}

#[tokio::test]
async fn rendered_clicks_cd_and_chords_preserve_user_input() {
    let (mut app, mut requests) = app().await;
    let root = std::env::temp_dir().join(format!("acpmux-ui-dirs-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("My Project")).unwrap();
    app.draft_mut().unwrap().cwd = root.to_string_lossy().into_owned();
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(140, 40)).unwrap();
    terminal.draw(|f| render::draw(f, &mut app)).unwrap();
    let buttons = app.buttons.clone();
    let find = |a: ButtonAction| buttons.iter().find(|(_, b)| *b == a).unwrap().0;
    let harness = find(ButtonAction::DraftHarness);
    let model = find(ButtonAction::DraftModel);
    let policy = find(ButtonAction::DraftPolicy);
    assert!(harness.x + harness.width <= model.x && model.x + model.width <= policy.x);
    app.press(harness.x, harness.y, KeyModifiers::NONE);
    assert!(
        matches!(app.overlay, Overlay::Picker(ref p) if matches!(p.on_pick, PickTarget::DraftHarness))
    );
    app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
    app.editor_mut().insert_str("cd 'My Project'");
    app.send_prompt(false);
    assert!(matches!(app.overlay, Overlay::Directory { .. }));
    terminal.draw(|f| render::draw(f, &mut app)).unwrap();
    assert!(!app.buttons.iter().any(|(_, b)| *b == ButtonAction::DraftHarness));
    app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
    assert_eq!(app.editor().text(), "cd 'My Project'");
    app.send_prompt(false);
    app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
    assert_eq!(
        app.current_directory(),
        std::fs::canonicalize(root.join("My Project")).unwrap().to_string_lossy()
    );
    assert!(app.editor().is_empty());
    app.editor_mut().insert_str("cd ..");
    app.send_prompt(false);
    app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
    assert_eq!(app.current_directory(), std::fs::canonicalize(&root).unwrap().to_string_lossy());
    app.on_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL));
    app.on_key(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::NONE));
    assert!(matches!(app.overlay,Overlay::Picker(ref p) if p.title=="Commands"));
    app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
    app.palette_prefix = ":".into();
    app.palette_aliases = vec![];
    app.on_key(KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));
    assert_eq!(app.editor().text(), "/");
    app.editor_mut().clear();
    app.on_key(KeyEvent::new(KeyCode::Char(':'), KeyModifiers::NONE));
    assert!(matches!(app.overlay,Overlay::Picker(ref p) if p.title=="Commands"));
    app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
    let skill_dir = root.join(".agents/skills/acpmux-ui-test");
    std::fs::create_dir_all(&skill_dir).unwrap();
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: UI test\ndescription: test only\n---\nCheck this test fixture.",
    )
    .unwrap();
    app.skill_prefix = "%".into();
    app.editor_mut().insert_str("Review with ");
    app.on_key(KeyEvent::new(KeyCode::Char('%'), KeyModifiers::NONE));
    assert!(
        matches!(app.overlay,Overlay::Picker(ref p) if p.rows.iter().any(|r|r.value=="acpmux-ui-test"))
    );
    app.overlay = Overlay::None;
    app.apply_pick(
        PickTarget::Skill { replace_prefix: true },
        "acpmux-ui-test".into(),
        String::new(),
    );
    assert_eq!(app.editor().text(), "Review with %acpmux-ui-test ");
    app.draft_mut().unwrap().model = Some("test-model".into());
    app.draft_mut().unwrap().effort = Some("high".into());
    app.send_prompt(false);
    let mut saw_new = false;
    loop {
        let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
            .await
            .unwrap()
            .unwrap();
        if msg["method"] == "session/new" {
            assert_eq!(msg["params"]["_meta"]["acpmux"]["model"], "test-model");
            assert_eq!(msg["params"]["_meta"]["acpmux"]["effort"], "high");
            saw_new = true;
        }
        if msg["method"] == "session/prompt" {
            let text = msg["params"]["prompt"][0]["text"].as_str().unwrap();
            assert!(
                saw_new
                    && text.contains("Check this test fixture.")
                    && text.contains("Base directory:")
            );
            break;
        }
    }
    app.drafts.clear();
    app.sessions = vec![json!({"sessionId":"test-session","harness":"fake","cwd":root})];
    app.selected = 0;
    let mut transcript = Transcript::default();
    transcript.available_commands = vec!["compact".into()];
    app.transcripts.insert("test-session".into(), transcript);
    app.open_palette();
    assert!(
        matches!(app.overlay,Overlay::Picker(ref p) if p.rows.iter().any(|r|r.value=="agent:/compact"))
    );
    app.overlay = Overlay::None;
    app.apply_pick(PickTarget::Action, "agent:/compact".into(), String::new());
    let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(msg["method"], "session/prompt");
    assert_eq!(msg["params"]["prompt"][0]["text"], "/compact");
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn dropped_image_becomes_an_acp_image_block() {
    let (mut app, _) = app().await;
    let path = std::env::temp_dir().join(format!("acpmux-ui-image-{}.png", uuid::Uuid::now_v7()));
    std::fs::write(&path, [137, 80, 78, 71]).unwrap();
    assert!(app.paste_images(&path.to_string_lossy()));
    assert_eq!(app.prompt_images().len(), 1);
    let blocks = App::prompt_blocks("look", app.prompt_images());
    assert_eq!(blocks[0]["type"], "text");
    assert_eq!(blocks[1]["type"], "image");
    assert_eq!(blocks[1]["mimeType"], "image/png");
    assert!(!blocks[1]["data"].as_str().unwrap().is_empty());
    std::fs::remove_file(path).unwrap();
}
