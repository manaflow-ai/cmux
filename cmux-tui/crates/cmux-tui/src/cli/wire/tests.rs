use super::*;
use cmux_tui_core::resource::ResourceOperation;

fn plan(operation: ResourceOperation) -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(operation),
        params: json!({}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: Default::default(),
    }
}

/// nxdog55: with `--order personal` the rows come in sidebar order, but
/// INDEX is the session index; an ORDER column numbers the shown order.
#[test]
fn personal_workspace_order_numbers_the_shown_rows() {
    let result = json!([
        {"id":"ws_f","index":5,"name":"six"},
        {"id":"ws_a","index":0,"name":"home"}
    ]);
    let mut personal = plan(ResourceOperation::WorkspaceList);
    personal.params = json!({"order":"personal"});
    assert_eq!(
        human_text(&human_view(&personal, &result)),
        "ID    NAME  ORDER  INDEX\nws_f  six   0      5\nws_a  home  1      0\n"
    );
    // The session order and other lists keep their table.
    assert_eq!(*human_view(&plan(ResourceOperation::WorkspaceList), &result), result);
    personal.operation = WireOperation::Typed(ResourceOperation::ScreenList);
    assert_eq!(*human_view(&personal, &result), result);
}

#[test]
fn capability_preflight_rejects_malformed_capabilities() {
    for capabilities in [json!(null), json!("journal-v1"), json!(["journal-v1", false])] {
        assert!(
            validate_capability_identity(&json!({
                "app": "cmux-tui", "protocol": 12, "capabilities": capabilities,
            }))
            .is_err()
        );
    }
}

/// Daemon and terminal-derived strings never write raw control
/// sequences (ESC, BEL, C1, OSC, CSI) to the terminal that runs the CLI.
#[test]
fn sec_audit_human_output_shows_controls_instead_of_sending_them() {
    let hostile = "title\u{1b}]0;owned\u{7}\u{9b}2J\u{1b}[2Jend";
    let outputs = [
        human_text(&json!(hostile)),
        human_text(&json!([{"name": hostile}])),
        human_text(&json!({"name": hostile})),
        human_error_lines(&json!({"message": hostile, "details": {"candidates": [hostile]}})),
    ];
    for output in outputs {
        assert!(!output.chars().any(|c| c.is_control() && c != '\n' && c != '\t'), "{output:?}");
        assert!(output.contains("title") && output.contains("end"), "{output:?}");
    }
}

#[test]
fn stream_timeout_polling_is_only_a_signal_watcher_fallback() {
    let stream = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::SessionJournalSubscribe),
        params: json!({}),
        idempotency_key: None,
        stream: true,
        resolve: Vec::new(),
        view: Default::default(),
    };
    assert_eq!(response_read_timeout(&stream, false), Some(Duration::from_millis(250)));
    assert_eq!(response_read_timeout(&stream, true), None);
}

#[test]
fn stopped_owner_reload_error_is_localized_for_human_output() {
    const PROBE_LOCALE: &str = "CMUX_TEST_STOPPED_OWNER_RELOAD_LOCALE";
    if let Ok(locale) = std::env::var(PROBE_LOCALE) {
        let plan = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::SessionReloadConfig),
            params: json!({}),
            idempotency_key: Some("reload-owner-stopped".into()),
            stream: false,
            resolve: Vec::new(),
            view: Default::default(),
        };
        let mut error = json!({
            "code":"operation.failed",
            "message":"owner_stopped",
            "details":{"operation":"session.reload_config","reason":"owner_stopped"},
            "retryable":false,
        });

        localize_operation_error(&plan, &mut error);

        let expected = match locale.as_str() {
            "en_US.UTF-8" => {
                "the local server stopped before it applied the configuration reload; start the session and retry"
            }
            "ja_JP.UTF-8" => {
                "ローカルサーバーが設定の再読み込みを適用する前に停止しました。セッションを起動して再試行してください"
            }
            _ => panic!("unexpected probe locale {locale}"),
        };
        assert_eq!(error["message"], expected);
        return;
    }

    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("stopped_owner_reload_error_is_localized_for_human_output")
            .arg("--nocapture")
            .env(PROBE_LOCALE, locale)
            .env("LC_ALL", locale)
            .status()
            .unwrap();
        assert!(status.success(), "{locale} localization probe failed");
    }
}

#[test]
fn sanitizers_cover_every_control_range() {
    let controls = ('\u{0}'..='\u{1f}').chain('\u{7f}'..='\u{9f}').chain(['\u{2028}', '\u{2029}']);
    for ch in controls {
        let cell = sanitize_human_cell(&format!("a{ch}b"));
        assert!(!cell.contains(ch), "cell kept {ch:?}: {cell:?}");
        let block = sanitize_human_block(&format!("a{ch}b"));
        if matches!(ch, '\n' | '\t') {
            assert_eq!(block, format!("a{ch}b"));
        } else {
            assert!(!block.contains(ch), "block kept {ch:?}: {block:?}");
        }
    }
    assert_eq!(sanitize_human_cell("plain ascii"), "plain ascii");
    assert_eq!(sanitize_human_block("plain ascii"), "plain ascii");
}

/// `closed list` shows one short MEMBERS cell per group (kind and the first
/// URL, folder or name); the full member JSON stays in --json.
#[test]
fn closed_list_summarizes_members_in_the_human_table() {
    let tab = json!({"kind":"browser","name":null,"url":"https://example.com","cwd":null});
    let screen =
        json!({"index":0,"kind":"screen","name":null,"screens":[{"name":null,"tabs":[tab]}]});
    let named = json!({"index":1,"kind":"workspace","name":"build","screens":[]});
    let result =
        json!([{"id":"closed_a","kind":"screen","member_count":2,"members":[screen, named]}]);
    let shown = human_view(&plan(ResourceOperation::ClosedList), &result);
    assert_eq!(shown[0]["members"], json!("screen https://example.com, workspace build"));
    assert!(!human_text(&shown).contains("\"screens\""), "{}", human_text(&shown));
    let long = json!({"kind":"tab","url":format!("https://example.com/{}", "a".repeat(200))});
    let result = json!([{"id":"closed_b","members":[long]}]);
    let cell = human_view(&plan(ResourceOperation::ClosedList), &result)[0]["members"].clone();
    assert!(cell.as_str().unwrap().chars().count() <= 80, "{cell}");
    assert!(cell.as_str().unwrap().ends_with('…'), "{cell}");
    // JSON output is the daemon's result unchanged (human_view is human-only).
    assert_eq!(*human_view(&plan(ResourceOperation::WorkspaceList), &result), result);
}
