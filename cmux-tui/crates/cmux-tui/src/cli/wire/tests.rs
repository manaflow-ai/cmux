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
        filter: Default::default(),
    }
}

/// A `screen wait` or `process wait` whose time ran out exits 124, as
/// `terminal send` and `terminal run` do; one that ended for its own reason
/// (a match, an exit) exits 0.
#[test]
fn a_terminal_wait_that_ran_out_of_time_exits_124() {
    let wait = plan(ResourceOperation::TerminalWait);
    assert_eq!(success_exit_code(&wait, &json!({"matched": false, "text": ""})), 124);
    assert_eq!(success_exit_code(&wait, &json!({"matched": true, "text": "ready"})), 0);
    let exit = plan(ResourceOperation::TerminalWaitExit);
    let pending = json!({"state": "pending", "terminal_id": "term_1", "lifecycle": "running"});
    assert_eq!(success_exit_code(&exit, &pending), 124);
    let exited = json!({"state": "exited", "outcome": {"kind": "exit", "code": 5}});
    assert_eq!(success_exit_code(&exit, &exited), 0, "the process's own code is in outcome");
    let read = plan(ResourceOperation::TerminalScreenRead);
    assert_eq!(success_exit_code(&read, &json!({"matched": false})), 0);
    assert_eq!(success_exit_code(&read, &json!({"state": "pending"})), 0);
    let unsend = plan(ResourceOperation::AgentMessageUnsend);
    assert_eq!(success_exit_code(&unsend, &json!({"value": {"outcome": "failed"}})), 1);
}

/// On a Cloud guest (one with a guest adapter), a timed-out `process wait`
/// exits 124 only for a caller that says it reads 124: an adapter that
/// predates 124, on disk or still running in a shell, reads any other exit as
/// a failed `agent --wait`, so it keeps 0. `screen wait` exits 124 either way:
/// every adapter reads its printed `matched: false`.
#[test]
fn a_timed_out_process_wait_exits_zero_for_a_guest_caller_that_predates_124() {
    let dir = std::env::temp_dir().join(format!("cmux-wait-adapter-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let adapter = dir.join("cmux-cloud-adapter");
    let exit = plan(ResourceOperation::TerminalWaitExit);
    let pending = json!({"state": "pending", "lifecycle": "running"});
    let missed = json!({"matched": false, "text": ""});
    let wait = plan(ResourceOperation::TerminalWait);

    let code = |plan, result, reads| wait_timeout::exit_code_with(plan, result, &adapter, reads);
    assert_eq!(code(&exit, &pending, false), Some(124), "no adapter: not a guest");
    std::fs::write(&adapter, "#!/bin/sh\n").unwrap();
    assert_eq!(code(&exit, &pending, false), None);
    assert_eq!(code(&exit, &pending, true), Some(124));
    assert_eq!(code(&wait, &missed, false), Some(124));
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The printed answer keeps the daemon's fields and adds `timed_out` (and,
/// when the time ran out, `waited_ms`: the timeout, a decimal string).
#[test]
fn a_terminal_wait_answer_says_whether_it_timed_out() {
    let mut wait = plan(ResourceOperation::TerminalWait);
    wait.params = json!({"pattern": "ready", "timeout_ms": "500"});
    let mut missed = json!({"matched": false, "text": "$ "});
    wait_timeout::mark(&wait, &mut missed);
    assert_eq!(
        missed,
        json!({"matched": false, "text": "$ ", "timed_out": true, "waited_ms": "500"})
    );
    let mut found = json!({"matched": true, "text": "ready"});
    wait_timeout::mark(&wait, &mut found);
    assert_eq!(found, json!({"matched": true, "text": "ready", "timed_out": false}));

    let mut exit = plan(ResourceOperation::TerminalWaitExit);
    exit.params = json!({"timeout_ms": "500"});
    let mut pending = json!({"state": "pending", "lifecycle": "running", "revision": "4"});
    wait_timeout::mark(&exit, &mut pending);
    assert_eq!(
        pending,
        json!({
            "state": "pending", "lifecycle": "running", "revision": "4",
            "timed_out": true, "waited_ms": "500"
        })
    );
    let mut exited = json!({"state": "exited", "outcome": {"kind": "exit", "code": 5}});
    wait_timeout::mark(&exit, &mut exited);
    assert_eq!(exited["timed_out"], false);
    assert!(exited.get("waited_ms").is_none());

    // Any other answer is printed as the daemon sent it.
    let mut read = json!({"matched": false});
    wait_timeout::mark(&plan(ResourceOperation::TerminalScreenRead), &mut read);
    assert_eq!(read, json!({"matched": false}));
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

/// W5-P: `screen list` drops the LAYOUT column (the whole split tree as
/// JSON) from its table; `--json` keeps the field.
#[test]
fn w5p_screen_list_table_has_no_layout_column() {
    let layout = json!({"kind":"split","direction":"right","children":[{"kind":"pane"}]});
    let result = json!([
        {"id":"screen_a","workspace_id":"ws_a","name":"main","focused":true,"layout":layout}
    ]);
    let shown = human_view(&plan(ResourceOperation::ScreenList), &result);
    let text = human_text(&shown);
    assert!(!text.contains("LAYOUT"), "{text}");
    assert!(!text.contains("split"), "{text}");
    assert!(text.contains("screen_a") && text.contains("main"), "{text}");
    assert_eq!(result[0]["layout"], layout, "the JSON result keeps the layout");
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
        view: Default::default(),
        filter: Default::default(),
    };
    assert!(request_value(&mutation).unwrap().get("idempotency_key").is_some());

    let read = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::WorkspaceList),
        params: json!({}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: Default::default(),
        filter: Default::default(),
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
        human_error_lines(&json!({"message": hostile, "details": {"candidates": [hostile]}})),
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
            view: Default::default(),
            filter: Default::default(),
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
        view: Default::default(),
        filter: Default::default(),
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
                view: Default::default(),
                filter: Default::default(),
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
            view: Default::default(),
            filter: Default::default(),
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
fn human_cells_disarm_escape_sequences_in_remote_titles() {
    // A remote-supplied title (browser page, terminal program) must not
    // reach the invoking terminal as a live escape sequence. Here the
    // payload is an OSC title change.
    let output = human_text(&json!([
        {"id":"b_1","title":"page\u{1b}]0;owned\u{7}title"}
    ]));
    assert!(!output.contains('\u{1b}'), "raw ESC in {output:?}");
    assert!(!output.contains('\u{7}'), "raw BEL in {output:?}");
    assert_eq!(output, "ID   TITLE\nb_1  page\u{fffd}]0;owned\u{fffd}title\n");
}

#[test]
fn human_cells_disarm_osc52_clipboard_payloads() {
    // OSC 52 writes the clipboard on supporting terminals; the sequence
    // must render as inert text.
    let output = human_text(&json!([
        {"id":"b_1","title":"\u{1b}]52;c;aGVsbG8=\u{7}"}
    ]));
    assert!(!output.contains("\u{1b}]52"), "live OSC 52 in {output:?}");
    assert_eq!(output, "ID   TITLE\nb_1  \u{fffd}]52;c;aGVsbG8=\u{fffd}\n");
}

#[test]
fn human_rows_replace_c1_and_del_controls_with_placeholders() {
    // C1 controls (CSI, DCS, OSC) and DEL are control bytes even without
    // a leading ESC on terminals that accept 8-bit controls.
    let output = human_text(&json!({"title":"a\u{9b}31mb\u{90}c\u{9d}d\u{7f}e"}));
    assert_eq!(output, "title  a\u{fffd}31mb\u{fffd}c\u{fffd}d\u{fffd}e\n");
}

#[test]
fn human_cells_replace_unicode_line_separators() {
    let output = human_text(&json!([{"id":"w","name":"x\u{2028}y\u{2029}z"}]));
    assert_eq!(output, "ID  NAME\nw   x\u{fffd}y\u{fffd}z\n");
}

#[test]
fn human_cells_keep_the_visible_newline_escape_for_cr_and_lf() {
    let output = human_text(&json!([{"id":"s_1","title":"line1\r\nline2"}]));
    assert_eq!(output, "ID   TITLE\ns_1  line1\\n\\nline2\n");
}

#[test]
fn human_cells_replace_tabs_so_column_math_stays_aligned() {
    let output = human_text(&json!([{"id":"x","title":"a\tb"}]));
    assert_eq!(output, "ID  TITLE\nx   a\u{fffd}b\n");
}

#[test]
fn human_headers_and_keys_cannot_carry_control_sequences() {
    let table = human_text(&json!([{"id":"x","bad\u{1b}key":"v"}]));
    assert_eq!(table, "ID  BAD\u{fffd}KEY\nx   v\n");
    let object = human_text(&json!({"k\u{1b}ey":"v"}));
    assert_eq!(object, "k\u{fffd}ey  v\n");
}

#[test]
fn human_nested_values_disarm_c1_controls_after_json_serialization() {
    // serde_json escapes C0 controls but writes C1 controls raw, so the
    // serialized fallback cell needs the same sanitizing as plain strings.
    let output = human_text(&json!([{"id":"x","tags":["a\u{85}b"]}]));
    assert!(!output.contains('\u{85}'), "raw C1 NEL in {output:?}");
    assert_eq!(output, "ID  TAGS\nx   [\"a\u{fffd}b\"]\n");
}

#[test]
fn human_top_level_strings_keep_newlines_but_disarm_controls() {
    assert_eq!(human_text(&json!("line1\nline2\u{1b}[2Jline3")), "line1\nline2\u{fffd}[2Jline3\n");
    assert_eq!(human_text(&json!("crlf\r\nkept")), "crlf\nkept\n");
    assert_eq!(human_text(&json!("overwrite\rspoof")), "overwrite\u{fffd}spoof\n");
    assert_eq!(human_text(&json!("tab\tkept")), "tab\tkept\n");
}

#[test]
fn human_string_lists_disarm_controls_per_line() {
    let output = human_text(&json!(["a\u{1b}b", "plain"]));
    assert_eq!(output, "a\u{fffd}b\nplain\n");
}

#[test]
fn human_output_keeps_plain_unicode_text_unchanged() {
    let output = human_text(&json!({"title":"日本語 🚀 ｶﾞ title"}));
    assert_eq!(output, "title  日本語 🚀 ｶﾞ title\n");
}

#[test]
fn human_error_text_disarms_control_sequences() {
    let error = json!({
        "code": "operation.failed",
        "message": "no workspace named b\u{1b}]0;owned\u{7}ad",
        "details": {"candidates": ["work\u{9b}space", "plain"]},
        "retryable": false
    });
    let text = human_error_lines(&error);
    assert!(!text.contains('\u{1b}'), "raw ESC in {text:?}");
    assert!(!text.contains('\u{9b}'), "raw C1 CSI in {text:?}");
    assert_eq!(
        text,
        "no workspace named b\u{fffd}]0;owned\u{fffd}ad\n  work\u{fffd}space\n  plain\n"
    );
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

#[test]
fn json_output_keeps_remote_title_bytes_intact() {
    // JSON modes rely on JSON escaping, not visible sanitizing: C0
    // controls are escaped, C1 controls and separator characters stay in
    // the encoded text, and the exact title survives a round-trip for
    // machine consumers.
    let title = "a\u{1b}]52;c;aGk=\u{7}b\u{9b}c\u{2028}d";
    let encoded = serde_json::to_string(&json!({"title": title})).expect("titles encode");
    assert!(!encoded.contains('\u{1b}'));
    assert!(!encoded.contains('\u{7}'));
    assert!(encoded.contains('\u{9b}'));
    assert!(encoded.contains('\u{2028}'));
    let decoded: Value = serde_json::from_str(&encoded).expect("titles decode");
    assert_eq!(decoded["title"].as_str(), Some(title));
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

/// W3-H: `--session` (or `--socket`) that names the caller's own session
/// keeps `caller`; one that names another session does not.
#[cfg(unix)]
#[test]
fn w3h_session_routes_to_the_caller_only_when_it_names_the_callers_socket() {
    use std::ffi::OsString;
    use std::path::PathBuf;
    let own = cmux_tui_core::server::try_default_socket_path("w3h-own").expect("socket path");
    let env = |name: &str| (name == "CMUX_TUI_SOCKET").then(|| OsString::from(own.clone()));
    let no_env = |_: &str| None::<OsString>;
    let global = |socket: Option<PathBuf>, session: Option<&str>| GlobalArgs {
        socket,
        session: session.map(str::to_owned),
        ..GlobalArgs::default()
    };
    assert!(routes_to_caller_session_with(&global(None, None), env));
    assert!(routes_to_caller_session_with(&global(None, Some("w3h-own")), env));
    assert!(routes_to_caller_session_with(&global(Some(own.clone()), None), env));
    assert!(!routes_to_caller_session_with(&global(None, Some("w3h-other")), env));
    assert!(!routes_to_caller_session_with(&global(Some(PathBuf::from("/tmp/x.sock")), None), env));
    // Outside a cmux-tui terminal no session is the caller's.
    assert!(!routes_to_caller_session_with(&global(None, Some("w3h-own")), no_env));
}

/// W3-H: `terminal <t> screen read` prints the screen text unless
/// `--details` asks for the record.
#[test]
fn w3h_screen_read_shows_text_unless_details_is_asked() {
    use super::super::command::{CommandPlan, ResponseView};
    let parse = |words: &[&str]| {
        let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
        match super::super::command::parse(&words, super::super::Surface::CmuxTui) {
            Ok(CommandPlan::Protocol(plan)) => plan.view,
            Ok(_) => panic!("{words:?} is not a daemon request"),
            Err(error) => panic!("{words:?}: {error:?}"),
        }
    };
    let id = "term_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    assert_eq!(parse(&["terminal", id, "screen", "read"]), ResponseView::ScreenText);
    assert_eq!(parse(&["terminal", id, "read"]), ResponseView::ScreenText);
    assert_eq!(parse(&["terminal", id, "screen", "read", "--details"]), ResponseView::Full);
}

/// A stream that answers each read with the next scripted step: some bytes,
/// or a read timeout (the 250 ms timeout a stream read uses).
struct ScriptedStream(std::sync::Mutex<std::collections::VecDeque<Option<&'static [u8]>>>);

impl ScriptedStream {
    fn boxed(steps: &[Option<&'static [u8]>]) -> Box<dyn transport::Stream> {
        Box::new(Self(std::sync::Mutex::new(steps.iter().copied().collect())))
    }
}

impl Read for ScriptedStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let mut steps = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match steps.pop_front() {
            None => Ok(0),
            Some(None) => Err(io::Error::from(io::ErrorKind::WouldBlock)),
            Some(Some(bytes)) => {
                let count = bytes.len().min(buffer.len());
                buffer[..count].copy_from_slice(&bytes[..count]);
                if count < bytes.len() {
                    steps.push_front(Some(&bytes[count..]));
                }
                Ok(count)
            }
        }
    }
}

impl Write for ScriptedStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for ScriptedStream {
    fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
        Err(io::Error::other("not cloneable"))
    }

    fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn shutdown(&self, _: Shutdown) -> io::Result<()> {
        Ok(())
    }
}

/// A stream line whose bytes arrive on both sides of a read timeout is one
/// line: the bytes read before the timeout stay, and the next read finishes
/// the line.
#[test]
fn a_stream_line_split_by_a_read_timeout_is_read_whole() {
    let stream =
        ScriptedStream::boxed(&[Some(br#"{"event":"ou"#), None, Some(b"tput\",\"n\":1}\n"), None]);
    let mut reader = BufReader::new(stream);
    let line = read_envelope(&mut reader, true);
    assert_eq!(line, Ok(Some(json!({"event": "output", "n": 1}))));
    // The peer closes in the middle of the next line: that is an error,
    // not a clean end of the stream.
    let stream = ScriptedStream::boxed(&[Some(br#"{"event":"#), None]);
    let mut reader = BufReader::new(stream);
    assert_eq!(
        read_envelope(&mut reader, true),
        Err("transport closed with a partial JSON line".to_string())
    );
}

/// A failure before the request was sent (the connection's preflight timed
/// out or dropped) leaves nothing on the daemon to join or to run twice, so
/// every request is tried again, a mutation and a wait with its own timeout
/// too, and none of them reports an unknown outcome.
#[test]
fn a_request_whose_preflight_failed_before_it_was_sent_is_tried_again() {
    for operation in [
        ResourceOperation::WorkspaceCreate,
        ResourceOperation::TerminalWait,
        ResourceOperation::TerminalScreenRead,
    ] {
        let tries = retry::Tries::new(&plan(operation));
        assert!(
            tries.may_retry_before_send(retry::Failure::Timeout),
            "{operation:?}: a preflight timeout"
        );
        assert!(
            tries.may_retry_before_send(retry::Failure::Dropped),
            "{operation:?}: a preflight drop"
        );
        assert!(!tries.may_retry_before_send(retry::Failure::Other), "{operation:?}");
        assert!(!tries.sent_before(), "{operation:?}: nothing was sent");
    }
}
