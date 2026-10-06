use super::*;
use cmux_tui_core::resource::ResourceOperation;

fn plan(operation: ResourceOperation) -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(operation),
        params: json!({}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
    }
}

#[test]
fn screen_wait_timeout_exits_one_and_a_match_exits_zero() {
    let wait = plan(ResourceOperation::TerminalWait);
    assert_eq!(success_exit_code(&wait, &json!({"matched": false, "text": ""})), 1);
    assert_eq!(success_exit_code(&wait, &json!({"matched": true, "text": "ready"})), 0);
    let read = plan(ResourceOperation::TerminalScreenRead);
    assert_eq!(success_exit_code(&read, &json!({"matched": false})), 0);
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
fn capability_preflight_rejects_wrong_app_even_when_capability_is_present() {
    let identity = json!({"app":"other", "protocol":12, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert!(validate_capability_identity(&identity).is_err());
}

#[test]
fn capability_preflight_rejects_pre_capability_protocol_even_when_capability_is_present() {
    let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION - 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert!(validate_capability_identity(&identity).is_err());
}

#[test]
fn capability_preflight_accepts_capability_introduction_protocol() {
    let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert!(validate_capability_identity(&identity).is_ok());
}

#[test]
fn capability_preflight_accepts_current_protocol() {
    let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert_eq!(validate_capability_identity(&identity), Ok(()));
}

#[test]
fn capability_preflight_rejects_future_protocol() {
    let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION + 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
}

#[test]
fn capability_preflight_rejects_max_protocol() {
    let identity = json!({"app":"cmux-tui", "protocol":u64::MAX, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
    assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
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

#[test]
fn mutation_request_has_a_key_and_read_does_not() {
    let mutation = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::WorkspaceCreate),
        params: json!({"initial_content":"empty"}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
    };
    assert!(request_value(&mutation).unwrap().get("idempotency_key").is_some());

    let read = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::WorkspaceList),
        params: json!({}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
    };
    assert!(request_value(&read).unwrap().get("idempotency_key").is_none());
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
        human_error_text(&json!({"message": hostile, "details": {"candidates": [hostile]}})),
    ];
    for output in outputs {
        assert!(!output.chars().any(|c| c.is_control() && c != '\n' && c != '\t'), "{output:?}");
        assert!(output.contains("title") && output.contains("end"), "{output:?}");
    }
}

#[test]
fn human_lists_are_readable_tables_instead_of_json_lines() {
    let output = human_text(&json!([
        {"id":"ws_a","name":"build","focused":true},
        {"id":"ws_b","name":"docs","focused":false}
    ]));
    assert_eq!(output, "ID    NAME   FOCUSED\nws_a  build  true\nws_b  docs   false\n");
    assert!(!output.contains(['{', '}', '"']));
}

#[test]
fn human_tables_pad_wide_cells_by_terminal_width() {
    let output = human_text(&json!([
        {"name":"界","value":"a"},
        {"name":"x","value":"界"}
    ]));
    assert_eq!(output, "NAME  VALUE\n界    a\nx     界\n");
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn human_tables_pad_halfwidth_dakuten_by_terminal_width() {
    let output = human_text(&json!([
        {"name":"ｶﾞ","value":"a"},
        {"name":"x","value":"ｶﾞ"}
    ]));
    assert_eq!(output, "NAME  VALUE\nｶﾞ    a\nx     ｶﾞ\n");
}

#[test]
fn human_single_array_wrappers_use_the_same_table() {
    let output = human_text(&json!({
        "workspaces": [
            {"id":"ws_a","name":"build"},
            {"id":"ws_b","name":"docs"}
        ]
    }));
    assert_eq!(output, "ID    NAME\nws_a  build\nws_b  docs\n");
}

#[test]
fn human_records_flatten_nested_results_without_losing_fields() {
    let output = human_text(&json!({
        "generation": "generation-1",
        "revision": "7",
        "replayed": false,
        "value": {"kind": "workspace", "workspace_id": "ws_a"}
    }));
    for expected in [
        "generation",
        "generation-1",
        "revision",
        "7",
        "replayed",
        "false",
        "value.kind",
        "workspace",
        "value.workspace_id",
        "ws_a",
    ] {
        assert!(output.contains(expected), "missing {expected:?} in {output:?}");
    }
    assert!(!output.contains(['{', '}', '"']));
}

#[test]
fn terminal_wait_transport_timeout_follows_the_operation_timeout() {
    for operation in [ResourceOperation::TerminalWait, ResourceOperation::TerminalWaitExit] {
        let bounded = RequestPlan {
            operation: WireOperation::Typed(operation),
            params: json!({"timeout_ms":"5000"}),
            idempotency_key: None,
            stream: false,
            resolve: Vec::new(),
        };
        assert_eq!(response_read_timeout(&bounded, false), Some(Duration::from_secs(7)));

        let unbounded = RequestPlan { params: json!({}), ..bounded };
        assert_eq!(response_read_timeout(&unbounded, false), None);
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
    };
    assert_eq!(response_read_timeout(&stream, false), Some(Duration::from_millis(250)));
    assert_eq!(response_read_timeout(&stream, true), None);
}

#[test]
fn terminal_input_errors_use_localized_copy_and_keep_wire_reasons() {
    for operation in [
        ResourceOperation::TerminalInputWrite,
        ResourceOperation::TerminalInputKeys,
        ResourceOperation::TerminalInputMouse,
        ResourceOperation::TerminalInputFocus,
    ] {
        for locale in ["en", "ja"] {
            let catalog = crate::localization::catalog_for_locale(locale);
            let plan = RequestPlan {
                operation: WireOperation::Typed(operation),
                params: json!({}),
                idempotency_key: Some("input-error".into()),
                stream: false,
                resolve: Vec::new(),
            };
            for (reason, expected) in [
                ("terminal_input_too_large", catalog.terminal_input.too_large),
                ("terminal_input_unavailable", catalog.terminal_input.unavailable),
                (
                    "terminal_input_confirmation_unsupported",
                    catalog.terminal_input.confirmation_unsupported,
                ),
                ("terminal_input_delivery_failed", catalog.terminal_input.delivery_failed),
            ] {
                let wire = json!({"code":"operation.failed", "message":reason,
                        "details":{"reason":reason}, "retryable":false});
                let mut human = wire.clone();
                localize_operation_error_with_catalog(&plan, &mut human, catalog);
                assert_eq!(human["message"], expected);
                assert_ne!(human["message"], reason);
                assert_eq!(human["details"], wire["details"]);
                assert_eq!(wire["message"], reason);
                assert_eq!(human["retryable"], false);
            }
        }
    }
    assert_ne!(
        crate::localization::catalog_for_locale("en").terminal_input,
        crate::localization::catalog_for_locale("ja").terminal_input
    );
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
