use std::sync::mpsc;

use super::*;
use crate::SurfaceOptions;

fn terminal_fixture(command: Option<Vec<String>>) -> (Arc<Mux>, Arc<Surface>, ResourceSelectors) {
    let mux = Mux::new_for_test(
        "content-router",
        SurfaceOptions { command, cols: 12, rows: 4, ..SurfaceOptions::default() },
    );
    let session = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..ResourceSelectors::default()
    };
    let created = super::super::topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            &session,
            json!({"initial_content":"terminal","name":"content"}),
            Some("create-terminal-content-fixture"),
        ),
    )
    .unwrap();
    let terminal_id =
        TerminalPublicId::parse(created["value"]["terminal_id"].as_str().unwrap()).unwrap();
    let surface_id =
        mux.resource_surface_for_terminal(&terminal_id).expect("created terminal is live");
    let surface = mux.surface(surface_id).expect("created terminal surface is live");
    let selectors = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        terminal: Some(terminal_id.to_string()),
        ..ResourceSelectors::default()
    };
    (mux, surface, selectors)
}

fn parsed_request(
    operation: &str,
    selectors: &ResourceSelectors,
    fields: Value,
    idempotency_key: Option<&str>,
) -> ParsedResourceRequest {
    let mut params = serde_json::to_value(selectors).unwrap().as_object().unwrap().clone();
    params.extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = idempotency_key {
        envelope["idempotency_key"] = json!(key);
    }
    super::super::parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
}

#[test]
fn owns_every_non_stream_terminal_and_browser_content_operation() {
    let owned = [
        ResourceOperation::TerminalInputWrite,
        ResourceOperation::TerminalInputKeys,
        ResourceOperation::TerminalInputMouse,
        ResourceOperation::TerminalInputFocus,
        ResourceOperation::TerminalScreenRead,
        ResourceOperation::TerminalStateRead,
        ResourceOperation::TerminalHistoryRead,
        ResourceOperation::TerminalHistoryClear,
        ResourceOperation::TerminalOutputRead,
        ResourceOperation::TerminalWait,
        ResourceOperation::TerminalWaitExit,
        ResourceOperation::TerminalCopy,
        ResourceOperation::TerminalProcessGet,
        ResourceOperation::TerminalViewportScroll,
        ResourceOperation::TerminalMove,
        ResourceOperation::TerminalProject,
        ResourceOperation::TerminalClose,
        ResourceOperation::BrowserNavigate,
        ResourceOperation::BrowserBack,
        ResourceOperation::BrowserForward,
        ResourceOperation::BrowserReload,
        ResourceOperation::BrowserActivate,
        ResourceOperation::BrowserInputKey,
        ResourceOperation::BrowserInputText,
        ResourceOperation::BrowserInputMouse,
        ResourceOperation::BrowserInputWheel,
        ResourceOperation::BrowserClose,
    ];
    assert!(owned.into_iter().all(handles));
    assert!(!handles(ResourceOperation::TerminalAttach));
    assert!(!handles(ResourceOperation::BrowserAttach));
    assert!(!handles(ResourceOperation::TerminalViewerResize));
    assert!(!handles(ResourceOperation::BrowserViewerResize));
}

#[test]
fn one_terminal_can_be_detached_reprojected_and_closed_explicitly() {
    let (mux, original, selectors) = terminal_fixture(None);
    let terminal_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let initial = public_session_snapshot(&mux).unwrap();
    let terminal = initial["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap();
    let original_tab = terminal["tab_ids"][0].as_str().unwrap().to_string();
    let pane_id = initial["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == original_tab)
        .unwrap()["pane_id"]
        .as_str()
        .unwrap()
        .to_string();
    let pane = ResourceSelectors {
        machine: Some("current".into()),
        session: Some("current".into()),
        pane: Some(pane_id.clone()),
        ..ResourceSelectors::default()
    };
    super::super::topology::dispatch(
        &mux,
        parsed_request("tab.create_terminal", &pane, json!({}), Some("terminal-multiview-keeper")),
    )
    .unwrap();

    let destination = public_session_snapshot(&mux).unwrap();
    let workspace_id = destination["workspaces"][0]["id"].as_str().unwrap();
    let screen_id = destination["screens"][0]["id"].as_str().unwrap();
    let active_before_projection = mux.active_surface();
    let projected = dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
                "name":"mirror",
            }),
            Some("terminal-multiview-project"),
        ),
    )
    .unwrap();
    assert_eq!(projected["value"]["focused"], false);
    assert_eq!(mux.active_surface(), active_before_projection);
    let projected_tab = projected["value"]["id"].as_str().unwrap().to_string();
    let placements = mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec()
    });
    assert_eq!(placements.len(), 2);
    let mirror = mux.surface(placements[1]).unwrap();
    assert!(original.shares_terminal_runtime(&mirror));
    let terminal = public_session_snapshot(&mux).unwrap()["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap()
        .clone();
    assert_eq!(terminal["tab_ids"].as_array().unwrap().len(), 2);

    for (index, tab) in [original_tab, projected_tab].into_iter().enumerate() {
        let tab_selectors = ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            tab: Some(tab),
            ..ResourceSelectors::default()
        };
        super::super::topology::dispatch(
            &mux,
            parsed_request(
                "tab.close",
                &tab_selectors,
                json!({"terminals": "keep"}),
                Some(&format!("terminal-multiview-detach-{index}")),
            ),
        )
        .unwrap();
    }

    let detached = public_session_snapshot(&mux).unwrap();
    let terminal = detached["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap();
    assert!(terminal["tab_id"].is_null());
    assert_eq!(terminal["tab_ids"], json!([]));
    assert!(mux.surface(original.id).is_some());
    assert!(
        dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None),)
            .is_ok()
    );

    let reprojected = dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
            }),
            Some("terminal-multiview-reproject"),
        ),
    )
    .unwrap();
    assert_eq!(reprojected["value"]["content_id"], terminal_id.as_str());
    dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":2,
                "name":"second mirror",
            }),
            Some("terminal-multiview-second-reproject"),
        ),
    )
    .unwrap();
    assert_eq!(
        mux.with_state(|state| state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
            .len()),
        2
    );

    let before_close = mux.with_state(|state| state.resource_revision);
    dispatch(
        &mux,
        parsed_request(
            "terminal.close",
            &selectors,
            json!({}),
            Some("terminal-multiview-explicit-close"),
        ),
    )
    .unwrap();
    let close_events = mux.resource_events_after(before_close).unwrap();
    assert_eq!(close_events.batches.len(), 1);
    let close_changes = close_events.batches[0].changes.as_array().unwrap();
    assert_eq!(
        close_changes
            .iter()
            .filter(|change| {
                change["kind"] == "delete"
                    && change["resource"] == "terminal"
                    && change["id"] == terminal_id.as_str()
            })
            .count(),
        1
    );
    assert_eq!(
        close_changes
            .iter()
            .filter(|change| change["kind"] == "delete" && change["resource"] == "tab")
            .count(),
        2
    );
    assert!(
        public_session_snapshot(&mux).unwrap()["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .all(|terminal| terminal["id"] != terminal_id.as_str())
    );
    assert!(mux.surface(original.id).is_none());
}

#[test]
fn terminal_wait_coalesces_more_than_attach_capacity_without_losing_a_later_match() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let request = parsed_request(
        "terminal.wait",
        &selectors,
        json!({"pattern":"READY","timeout_ms":"2000"}),
        None,
    );
    let waiting_mux = mux;
    let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
        std::thread::yield_now();
    }
    for _ in 0..300 {
        surface.apply_stream_output_for_test(b"\r").unwrap();
    }
    surface.apply_stream_output_for_test(b"READY").unwrap();

    let result = waiter.join().unwrap().unwrap();
    assert_eq!(result["matched"], true, "wait lost the post-burst match: {result}");
    assert!(result["text"].as_str().unwrap().contains("READY"));
}

#[test]
fn terminal_wait_rechecks_after_resize_reflows_visible_text() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    surface.apply_stream_output_for_test(b"abcdefghij").unwrap();
    let request = parsed_request(
        "terminal.wait",
        &selectors,
        json!({"pattern":"abcde\\nfghij","timeout_ms":"2000"}),
        None,
    );
    let waiting_mux = mux;
    let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
        std::thread::yield_now();
    }
    assert!(surface.resize(5, 4).unwrap(), "fixture resize was unexpectedly unchanged");

    let result = waiter.join().unwrap().unwrap();
    assert_eq!(result["matched"], true, "wait ignored resize reflow: {result}");
}

#[test]
fn terminal_wait_exit_wakes_on_its_durable_terminal_event() {
    let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    mux.reset_terminal_exit_state_query_count_for_test();
    let request =
        parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"2000"}), None);
    let waiting_mux = mux.clone();
    let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
        || mux.terminal_exit_state_query_count_for_test() != 1
    {
        assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
        std::thread::yield_now();
    }
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 23 },
        exited_at_ms: 2_345_678,
    };
    assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());

    let result = waiter.join().unwrap().unwrap();
    assert_eq!(result["state"], "exited", "exit notification did not settle wait: {result}");
    assert_eq!(result["outcome"], json!({"kind":"exit","code":23}));
    assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
}

#[test]
fn terminal_wait_exit_wakes_when_a_concurrent_terminal_close_tombstones_it() {
    let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    mux.reset_terminal_exit_state_query_count_for_test();
    let request = parsed_request("terminal.wait_exit", &selectors, json!({}), None);
    let waiting_mux = mux.clone();
    let (settled_tx, settled_rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = settled_tx.send(dispatch(&waiting_mux, request));
    });

    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
        || mux.terminal_exit_state_query_count_for_test() != 1
    {
        assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
        std::thread::yield_now();
    }
    let closed = dispatch(
        &mux,
        parsed_request("terminal.close", &selectors, json!({}), Some("close-waited-terminal")),
    )
    .unwrap();
    assert_eq!(closed["replayed"], false);

    let error = settled_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("terminal close stranded an unbounded exit wait")
        .unwrap_err();
    assert_eq!(error.code, "terminal.closed");
    assert_eq!(error.details["terminal_id"], public_id.as_str());
    assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
}

#[test]
fn terminal_wait_exit_latches_one_public_event_without_host_identity() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&surface.id].clone());
    let durable = mux.terminal_registry_snapshot().unwrap();
    let internal = durable.terminals.first().expect("fixture has one durable terminal");
    let internal_id = internal.terminal_id.as_str();
    let incarnation = internal.incarnation.as_deref().unwrap_or_default();
    let pending = dispatch(
        &mux,
        parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"0"}), None),
    )
    .unwrap();
    assert_eq!(pending["state"], "pending");
    assert_eq!(pending["terminal_id"], public_id.as_str());
    assert!(pending.get("incarnation").is_none());
    let before = pending["revision"].as_str().unwrap().parse::<u64>().unwrap();

    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: false,
        },
        exited_at_ms: 1_234_567,
    };
    assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());
    assert!(
        !mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap(),
        "duplicate observations must not mint another revision"
    );

    let exited = dispatch(
        &mux,
        parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"1000"}), None),
    )
    .unwrap();
    assert_eq!(
        exited,
        json!({
            "state":"exited",
            "terminal_id":public_id,
            "lifecycle":"exited",
            "outcome":{"kind":"signal","signal":libc::SIGTERM,"core_dumped":false},
            "exited_at":"1234567",
            "revision":(before + 1).to_string(),
        })
    );

    let events = mux.resource_events_after(before).unwrap();
    assert_eq!(events.batches.len(), 1);
    let changes = events.batches[0].changes.as_array().unwrap();
    assert_eq!(changes[0]["kind"], "upsert");
    assert_eq!(changes[0]["sequence"], 0);
    assert_eq!(changes[0]["resource"], "terminal");
    assert_eq!(changes[0]["id"], public_id.as_str());
    assert_eq!(changes[0]["value"]["lifecycle"], "exited");
    assert_eq!(changes[0]["value"]["exit"]["outcome"], exited["outcome"]);
    assert!(
        changes.iter().enumerate().all(|(sequence, change)| {
            change["sequence"].as_u64() == u64::try_from(sequence).ok()
        })
    );
    assert!(changes.iter().any(|change| {
        change["kind"] == "delete" && change["resource"] == "tab" && change["id"] == tab_id.as_str()
    }));
    assert!(!changes.iter().any(|change| {
        change["kind"] == "delete"
            && change["resource"] == "terminal"
            && change["id"] == public_id.as_str()
    }));
    let public_json = serde_json::to_string(changes).unwrap();
    assert!(!public_json.contains("\"incarnation\""));
    assert!(!public_json.contains(internal_id));
    assert!(incarnation.is_empty() || !public_json.contains(incarnation));

    let snapshot = public_session_snapshot(&mux).unwrap();
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == public_id.as_str())
        .expect("exited terminal receipt remains publicly addressable");
    assert_eq!(terminal["lifecycle"], "exited");
    assert_eq!(terminal["tab_id"], Value::Null);
    assert_eq!(terminal["tab_ids"], json!([]));
    assert_eq!(terminal["exit"]["outcome"], exited["outcome"]);
    assert!(mux.surface(surface.id).is_none());
}

#[test]
fn terminal_close_tombstones_an_exited_receipt_without_a_live_runtime() {
    let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let host_id =
        mux.terminal_registry_snapshot().unwrap().terminals.into_iter().next().unwrap().terminal_id;
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
        exited_at_ms: 4_567_890,
    };
    assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());
    assert!(
        mux.resource_surface_for_terminal(&public_id).is_none(),
        "exit detach must retire the terminal runtime"
    );

    let closed = dispatch(
        &mux,
        parsed_request(
            "terminal.close",
            &selectors,
            json!({}),
            Some("close-exited-terminal-receipt"),
        ),
    )
    .expect("terminal.close must retire an exited receipt without a live runtime");

    assert_eq!(closed["replayed"], false);
    assert!(
        public_session_snapshot(&mux).unwrap()["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .all(|terminal| terminal["id"] != public_id.as_str()),
        "a closed exited receipt must leave the public session snapshot"
    );
    let tombstone = mux.resolve_terminal(&host_id).unwrap().unwrap();
    assert_eq!(
        tombstone.terminal.lifecycle,
        crate::workspace_registry::TerminalLifecycle::Tombstoned
    );
    mux.shutdown();
}

#[cfg(unix)]
#[test]
fn terminal_wait_exit_resolves_detached_id_after_exit_upsert() {
    let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let before = public_session_snapshot(&mux).unwrap()["cursor"]["revision"]
        .as_str()
        .unwrap()
        .parse::<u64>()
        .unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: true,
        },
        exited_at_ms: 3_456_789,
    };
    assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());

    let exited = dispatch(
        &mux,
        parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"0"}), None),
    )
    .unwrap();
    assert_eq!(exited["state"], "exited");
    assert_eq!(
        exited["outcome"],
        json!({"kind":"signal","signal":libc::SIGTERM,"core_dumped":true})
    );
    assert_eq!(exited["exited_at"], "3456789");

    let snapshot = public_session_snapshot(&mux).unwrap();
    let terminals = snapshot["terminals"].as_array().unwrap();
    assert_eq!(terminals.len(), 1);
    let terminal = &terminals[0];
    assert_eq!(terminal["id"], public_id.as_str());
    assert_eq!(terminal["lifecycle"], "exited");
    assert_eq!(terminal["running"], false);
    assert_eq!(terminal["tab_id"], Value::Null);
    assert_eq!(terminal["tab_ids"], json!([]));
    assert_eq!(terminal["exit"]["outcome"], exited["outcome"]);
    assert_eq!(terminal["exit"]["exited_at"], exited["exited_at"]);
    let events = mux.resource_events_after(before).unwrap();
    assert_eq!(events.batches.len(), 1);
    let exit_changes = events.batches[0].changes.as_array().unwrap();
    let exit_upsert = exit_changes
        .iter()
        .find(|change| {
            change["resource"] == "terminal"
                && change["id"] == public_id.as_str()
                && change["kind"] == "upsert"
        })
        .expect("exit batch omitted the terminal upsert");
    assert_eq!(exit_upsert["value"]["lifecycle"], "exited");
    assert_eq!(exit_upsert["value"]["exit"]["outcome"], exited["outcome"]);
    assert_eq!(exit_upsert["sequence"], 0);
    assert!(!exit_changes.iter().any(|change| {
        change["resource"] == "terminal"
            && change["id"] == public_id.as_str()
            && change["kind"] == "delete"
    }));

    let mut stale_nested = selectors.clone();
    stale_nested.pane = Some("pane_00000000000000000000000000000001".into());
    let error = dispatch(
        &mux,
        parsed_request("terminal.wait_exit", &stale_nested, json!({"timeout_ms":"0"}), None),
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.not_found");

    let mut unknown = selectors;
    unknown.terminal = Some("term_ffffffffffffffffffffffffffffffff".into());
    let error = dispatch(
        &mux,
        parsed_request("terminal.wait_exit", &unknown, json!({"timeout_ms":"0"}), None),
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.not_found");
}

#[test]
fn browser_key_mapping_preserves_text_and_named_key_identity() {
    let letter = browser_key_description("a");
    assert_eq!(letter.key, "a");
    assert_eq!(letter.code, "KeyA");
    assert_eq!(letter.windows_virtual_key_code, 65);
    assert_eq!(letter.text.as_deref(), Some("a"));

    let arrow = browser_key_description("ArrowLeft");
    assert_eq!(arrow.key, "ArrowLeft");
    assert_eq!(arrow.code, "ArrowLeft");
    assert_eq!(arrow.windows_virtual_key_code, 37);
    assert_eq!(arrow.text, None);

    let space = browser_key_description("Space");
    assert_eq!(space.key, " ");
    assert_eq!(space.code, "Space");
    assert_eq!(space.windows_virtual_key_code, 32);
    assert_eq!(space.text.as_deref(), Some(" "));

    let function = browser_key_description("F12");
    assert_eq!(function.key, "F12");
    assert_eq!(function.code, "F12");
    assert_eq!(function.windows_virtual_key_code, 123);
    assert_eq!(function.text, None);

    assert_eq!(browser_key_event_values(&letter, 0), ("a".into(), Some("a".into())));
    assert_eq!(browser_key_event_values(&letter, 8), ("A".into(), Some("A".into())));
    assert_eq!(browser_key_event_values(&letter, 1), ("a".into(), None));
    assert_eq!(browser_key_event_values(&letter, 2), ("a".into(), None));
    assert_eq!(browser_key_event_values(&letter, 4), ("a".into(), None));
}

#[test]
fn finds_the_exact_browser_upsert_in_a_typed_delta_batch() {
    let expected = json!({
        "id":"browser_00000000000000000000000000000001",
        "url":"https://example.test",
    });
    let changes = json!([
        {
            "kind":"upsert",
            "sequence":0,
            "resource":"terminal",
            "id":"term_00000000000000000000000000000002",
            "value":{"id":"term_00000000000000000000000000000002"},
        },
        {
            "kind":"upsert",
            "sequence":1,
            "resource":"browser",
            "id":"browser_00000000000000000000000000000001",
            "value":expected,
        },
    ]);
    assert_eq!(
        find_upsert_change(&changes, "browser", "browser_00000000000000000000000000000001"),
        Some(expected)
    );
    assert_eq!(
        find_upsert_change(&changes, "browser", "browser_00000000000000000000000000000003"),
        None
    );
}

#[test]
fn targeted_browser_projection_emits_only_the_browser_delta() {
    let mux = Mux::new_for_test("browser-effect-projection", SurfaceOptions::default());
    let session = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..ResourceSelectors::default()
    };
    let created = super::super::topology::dispatch(
        &mux,
        parsed_request(
            "tab.create_browser",
            &session,
            json!({"url":"about:blank"}),
            Some("create-browser-content-fixture"),
        ),
    )
    .unwrap();
    let browser_id =
        BrowserPublicId::parse(created["value"]["browser_id"].as_str().unwrap()).unwrap();
    let (_, surface) = browser_surface_for_id(&mux, &browser_id).expect("created browser is live");
    let durable =
        mux.with_resource_projection(|registry, _| registry.resource_topology_snapshot()).unwrap();
    let durable_browser = durable
        .browsers
        .iter()
        .find(|browser| browser.public_id == browser_id)
        .expect("created browser is durable");
    assert_eq!(durable_browser.status, RegistryBrowserStatus::Starting);

    let projection = mux
        .with_resource_projection(|registry, state| {
            targeted_browser_effect_projection(registry, state, &browser_id, true)
        })
        .unwrap();
    let deltas = projection.changes.as_array().unwrap();
    assert_eq!(deltas.len(), 1);
    assert_eq!(deltas[0]["kind"], "upsert");
    assert_eq!(deltas[0]["resource"], "browser");
    assert_eq!(deltas[0]["id"], browser_id.as_str());
    assert_eq!(projection.patch.changes.len(), 2);
    assert!(matches!(
        &projection.patch.changes[0],
        ResourceChange::UpsertBrowser(browser) if browser.public_id == browser_id
    ));
    assert!(matches!(
        &projection.patch.changes[1],
        ResourceChange::UpsertTab(tab)
            if tab.content_id == ContentPublicId::Browser(browser_id.clone())
    ));
    surface.kill();
}

#[test]
fn starting_browser_error_matches_catalog_contract() {
    let surface = crate::browser::new_surface(
        1,
        "about:blank".into(),
        (80, 24),
        (8, 16),
        &SurfaceOptions::default(),
        std::sync::Weak::new(),
    )
    .unwrap();
    let error = browser_not_ready_error(&surface, "browser.navigate");
    assert_eq!(error.code, "operation.failed");
    assert_eq!(error.details["operation"], "browser.navigate");
    assert_eq!(error.details["extra"]["status"], "starting");
    assert!(!error.retryable);
    surface.kill();
}

#[test]
fn terminal_reads_match_catalog_shapes_and_preserve_argv_boundaries() {
    {
        let reserved = Mux::new_for_test("ordinary-terminal-projection", SurfaceOptions::default());
        let surface = reserved.new_workspace(Some("ordinary".into()), Some((12, 4))).unwrap();
        let projection = reserved.resource_effect_projection().unwrap();
        assert!(!projection.patch.changes.is_empty());
        surface.kill();
    }

    let (mux, surface, selectors) =
        terminal_fixture(Some(vec!["fake-shell".into(), "argument with spaces".into()]));
    surface
        .try_with_terminal(|terminal| terminal.vt_write(b"one\r\ntwo\r\nthree\r\nfour\r\nfive"))
        .unwrap();

    let screen =
        dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None))
            .unwrap();
    assert!(screen["text"].as_str().unwrap().contains("five"));
    assert_eq!(screen["cols"], 12);
    assert_eq!(screen["rows"], 4);
    assert!(screen["cursor_row"].is_u64());
    assert!(screen["cursor_col"].is_u64());
    assert!(screen["cursor_visible"].is_boolean());

    let state =
        dispatch(&mux, parsed_request("terminal.state.read", &selectors, json!({}), None)).unwrap();
    assert!(
        !base64::engine::general_purpose::STANDARD
            .decode(state["state_base64"].as_str().unwrap())
            .unwrap()
            .is_empty()
    );

    let history = dispatch(
        &mux,
        parsed_request("terminal.history.read", &selectors, json!({"limit":2,"styled":true}), None),
    )
    .unwrap();
    assert!(history["start"].is_string());
    assert!(history["rows"].as_array().unwrap().len() <= 2);
    for row in history["rows"].as_array().unwrap() {
        assert!(row["row"].is_u64());
        for run in row["runs"].as_array().unwrap() {
            assert!(run["text"].is_string());
            assert!(run["attrs"].is_u64());
            assert!(run.get("fg").is_some());
            assert!(run.get("bg").is_some());
        }
    }

    surface.set_test_pwd(Some("file:///tmp/hostless".into()));
    let process =
        dispatch(&mux, parsed_request("terminal.process.get", &selectors, json!({}), None))
            .unwrap();
    assert_eq!(process["executable"], "fake-shell");
    assert_eq!(process["argv"], json!(["fake-shell", "argument with spaces"]));
    assert!(process["pid"].is_u64());
    assert!(process["children"].is_array());
    assert_eq!(process["cwd"], "/tmp/hostless");
    let foreground = process.get("foreground_cwd").expect("foreground_cwd is present");
    assert!(foreground.is_null() || foreground.is_string());
}

#[test]
fn terminal_external_effect_replays_before_selector_resolution() {
    let (mux, _surface, selectors) = terminal_fixture(None);
    let input_revision = mux.with_state(|state| state.resource_revision);
    let input_terminal_revision = mux.terminal_registry_snapshot().unwrap().revision;
    let first = dispatch(
        &mux,
        parsed_request(
            "terminal.input.write",
            &selectors,
            json!({"text":"echo safe\n"}),
            Some("terminal-write-replay"),
        ),
    )
    .unwrap();
    assert_eq!(first["value"], json!({}));
    assert_eq!(first["replayed"], false);
    assert_eq!(first["revision"], input_revision.to_string());
    assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);
    assert!(mux.resource_events_after(input_revision).unwrap().batches.is_empty());
    assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, input_terminal_revision);

    let second = dispatch(
        &mux,
        parsed_request(
            "terminal.input.write",
            &selectors,
            json!({"text":"echo safe\n"}),
            Some("terminal-write-replay"),
        ),
    )
    .unwrap();
    assert_eq!(second["replayed"], true);
    assert_eq!(second["revision"], first["revision"]);
    assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);
    assert!(mux.resource_events_after(input_revision).unwrap().batches.is_empty());

    let conflict = dispatch(
        &mux,
        parsed_request(
            "terminal.input.write",
            &selectors,
            json!({"text":"different payload\n"}),
            Some("terminal-write-replay"),
        ),
    )
    .unwrap_err();
    assert_eq!(conflict.code, "idempotency.conflict");
    assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);

    let before_resource = first["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
    let closed = dispatch(
        &mux,
        parsed_request("terminal.close", &selectors, json!({}), Some("terminal-close-replay")),
    )
    .unwrap();
    assert_eq!(closed["replayed"], false);
    assert_eq!(public_session_snapshot(&mux).unwrap()["terminals"], json!([]));
    assert_eq!(mux.with_state(|state| state.resource_revision), before_resource + 1);
    assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
    let (terminal_snapshot, terminal_events) =
        mux.terminal_registry_events_page(before_terminal).unwrap();
    assert_eq!(terminal_snapshot.revision, before_terminal + 1);
    assert_eq!(terminal_events.len(), 1);
    assert_eq!(terminal_events[0].kind, "terminal-closed");

    let replay = dispatch(
        &mux,
        parsed_request("terminal.close", &selectors, json!({}), Some("terminal-close-replay")),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["revision"], closed["revision"]);
    assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
    assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal + 1);
}

#[test]
fn terminal_viewport_scroll_uses_one_bounded_receipt_and_one_journal_outcome() {
    let (mux, surface, selectors) = terminal_fixture(None);
    surface
        .try_with_terminal(|terminal| {
            for index in 0..20 {
                terminal.vt_write(format!("line-{index}\r\n").as_bytes());
            }
        })
        .unwrap();
    let terminal_scrollbar = || {
        surface
            .try_with_terminal(|terminal| terminal.scrollbar().expect("fixture has scrollback"))
            .unwrap()
    };
    let bottom = terminal_scrollbar();
    assert!(!bottom.scrolled_back());
    let view = surface.view_scrollbar().expect("fixture has scrollback");

    let revision = mux.with_state(|state| state.resource_revision);
    let terminal_revision = mux.terminal_registry_snapshot().unwrap().revision;
    let event_epoch = mux.resource_event_epoch();
    let journal_head = mux.session_journal_after(0, 1).unwrap().head_sequence;
    let mutation_count = mux.resource_mutation_count_for_test().unwrap();
    let request = || {
        parsed_request(
            "terminal.viewport.scroll",
            &selectors,
            json!({
                "delta_rows":-2,
                "expected_revision":revision.to_string(),
            }),
            Some("terminal-scroll-receipt"),
        )
    };

    let first = dispatch(&mux, request()).unwrap();
    assert_eq!(first["value"], json!({}));
    assert_eq!(first["revision"], revision.to_string());
    assert_eq!(first["replayed"], false);
    let after_first = terminal_scrollbar();
    assert!(after_first.scrolled_back());
    assert_eq!(
        after_first.offset + 2,
        bottom.offset,
        "the scroll moves the terminal viewport that render attaches show"
    );
    assert_eq!(
        surface.view_scrollbar().expect("fixture has scrollback").offset + 2,
        view.offset,
        "the scroll also moves the placement's in-process frontend view"
    );
    assert_eq!(mux.with_state(|state| state.resource_revision), revision);
    assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, terminal_revision);
    assert_eq!(mux.resource_event_epoch(), event_epoch + 1);
    assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
    assert_eq!(mux.resource_mutation_count_for_test().unwrap(), mutation_count);
    let journal = mux.session_journal_after(journal_head, 2).unwrap();
    assert_eq!(journal.records.len(), 1);
    assert_eq!(journal.records[0].kind, "terminal.viewport.scroll.effect.succeeded");
    let effect_sequence = journal.records[0].sequence;

    let replay = dispatch(&mux, request()).unwrap();
    assert_eq!(replay["value"], first["value"]);
    assert_eq!(replay["generation"], first["generation"]);
    assert_eq!(replay["revision"], first["revision"]);
    assert_eq!(replay["replayed"], true);
    assert_eq!(
        terminal_scrollbar(),
        after_first,
        "receipt replay must not apply the viewport delta twice"
    );
    assert_eq!(mux.with_state(|state| state.resource_revision), revision);
    assert_eq!(mux.resource_event_epoch(), event_epoch + 1);
    assert!(mux.session_journal_after(effect_sequence, 1).unwrap().records.is_empty());
    assert_eq!(mux.resource_mutation_count_for_test().unwrap(), mutation_count);

    let closed = dispatch(
        &mux,
        parsed_request(
            "terminal.close",
            &selectors,
            json!({}),
            Some("terminal-scroll-close-target"),
        ),
    )
    .unwrap();
    assert_eq!(closed["revision"], (revision + 1).to_string());

    let replay_after_close = dispatch(&mux, request()).unwrap();
    assert_eq!(replay_after_close["value"], first["value"]);
    assert_eq!(replay_after_close["generation"], first["generation"]);
    assert_eq!(replay_after_close["revision"], first["revision"]);
    assert_eq!(replay_after_close["replayed"], true);

    let conflict = dispatch(
        &mux,
        parsed_request(
            "terminal.viewport.scroll",
            &selectors,
            json!({
                "delta_rows":-3,
                "expected_revision":revision.to_string(),
            }),
            Some("terminal-scroll-receipt"),
        ),
    )
    .unwrap_err();
    assert_eq!(conflict.code, "idempotency.conflict");

    let missing_before_stale_revision = dispatch(
        &mux,
        parsed_request(
            "terminal.viewport.scroll",
            &selectors,
            json!({
                "delta_rows":-2,
                "expected_revision":revision.to_string(),
            }),
            Some("terminal-scroll-new-receipt"),
        ),
    )
    .unwrap_err();
    assert_eq!(missing_before_stale_revision.code, "selector.not_found");
}

#[test]
fn browser_close_commits_the_tab_and_browser_tombstones_once() {
    let mux = Mux::new_for_test("content-browser-close", SurfaceOptions::default());
    let session = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..ResourceSelectors::default()
    };
    let created = super::super::topology::dispatch(
        &mux,
        parsed_request(
            "tab.create_browser",
            &session,
            json!({"url":"about:blank#atomic-browser-close"}),
            Some("content-browser-create"),
        ),
    )
    .unwrap();
    let browser_id = created["value"]["browser_id"].as_str().unwrap().to_string();
    let selectors = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        browser: Some(browser_id),
        ..ResourceSelectors::default()
    };
    let before_resource = mux.with_state(|state| state.resource_revision);
    let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
    let request = || {
        parsed_request("browser.close", &selectors, json!({}), Some("content-browser-close-effect"))
    };

    let closed = dispatch(&mux, request()).unwrap();
    assert_eq!(closed["replayed"], false);
    assert_eq!(mux.with_state(|state| state.resource_revision), before_resource + 1);
    assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
    assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal);
    let snapshot = public_session_snapshot(&mux).unwrap();
    assert!(snapshot["browsers"].as_array().unwrap().is_empty());
    assert!(snapshot["tabs"].as_array().unwrap().is_empty());

    let replay = dispatch(&mux, request()).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["revision"], closed["revision"]);
    assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
    mux.shutdown();
}

#[test]
fn terminal_move_of_a_panes_final_tab_collapses_the_source_pane() {
    let mux = Mux::new_for_test("content-terminal-move", SurfaceOptions::default());
    let session = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..ResourceSelectors::default()
    };
    let created = super::super::topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            &session,
            json!({"initial_content":"terminal","name":"move"}),
            Some("create-terminal-move-fixture"),
        ),
    )
    .unwrap();
    let destination_workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let destination_screen = created["value"]["screen_id"].as_str().unwrap().to_string();
    let destination_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let destination_selectors = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        pane: Some(destination_pane.clone()),
        ..ResourceSelectors::default()
    };
    let source = super::super::topology::dispatch(
        &mux,
        parsed_request(
            "pane.split",
            &destination_selectors,
            json!({"direction":"right","ratio":0.5}),
            Some("split-terminal-move-fixture"),
        ),
    )
    .unwrap();
    let source_terminal =
        TerminalPublicId::parse(source["value"]["terminal_id"].as_str().unwrap()).unwrap();
    let source_selectors = ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        terminal: Some(source_terminal.to_string()),
        ..ResourceSelectors::default()
    };

    let move_request = || {
        parsed_request(
            "terminal.move",
            &source_selectors,
            json!({
                "destination_workspace":&destination_workspace,
                "destination_screen":&destination_screen,
                "destination_pane":&destination_pane,
                "index":1,
            }),
            Some("terminal-final-tab-move"),
        )
    };
    let moved = dispatch(&mux, move_request()).unwrap();
    assert_eq!(moved["value"]["id"], source_terminal.as_str());
    assert_eq!(moved["replayed"], false);

    let after = public_session_snapshot(&mux).unwrap();
    assert_eq!(after["panes"].as_array().unwrap().len(), 1);
    assert_eq!(after["tabs"].as_array().unwrap().len(), 2);
    assert!(after["panes"][0]["focused"].as_bool().unwrap());

    dispatch(
        &mux,
        parsed_request(
            "terminal.close",
            &source_selectors,
            json!({}),
            Some("close-moved-terminal"),
        ),
    )
    .unwrap();
    let replay = dispatch(&mux, move_request()).unwrap();
    assert_eq!(replay["value"], moved["value"]);
    assert_eq!(replay["revision"], moved["revision"]);
    assert_eq!(replay["replayed"], true);
}

fn terminal_record(mux: &Arc<Mux>, selectors: &ResourceSelectors) -> Value {
    let id = selectors.terminal.clone().unwrap();
    public_session_snapshot(mux).unwrap()["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == id.as_str())
        .unwrap()
        .clone()
}

#[test]
fn read_run_terminal_reads_unwrap_soft_wraps_and_read_the_last_lines() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    let long = "x".repeat(40);
    surface
        .apply_stream_output_for_test(format!("one\r\ntwo\r\n{long}\r\nend").as_bytes())
        .unwrap();
    let read = |operation: &str, fields: Value| {
        dispatch(&mux, parsed_request(operation, &selectors, fields, None)).unwrap()
    };
    let rows = read("terminal.screen.read", json!({}));
    assert!(!rows["text"].as_str().unwrap().contains(&long), "rows break at the width");
    let last = read("terminal.screen.read", json!({"lines": 2, "unwrap": true}));
    assert_eq!(last["text"], format!("{long}\nend"), "two logical lines");
    assert_eq!(last["cols"], 12);
    assert!(last["cursor_row"].is_u64());
    let last_rows = read("terminal.screen.read", json!({"lines": 2}));
    assert_eq!(last_rows["text"], format!("{}\nend", "x".repeat(40 % 12)));
    let all = read("terminal.screen.read", json!({"lines": 100, "unwrap": true}));
    assert_eq!(all["text"], format!("one\ntwo\n{long}\nend"));
    let copied = read("terminal.copy", json!({"mode": "scrollback", "unwrap": true}));
    assert!(copied["text"].as_str().unwrap().contains(&long));
    let plain = read("terminal.copy", json!({"mode": "scrollback"}));
    assert!(!plain["text"].as_str().unwrap().contains(&long));
}

#[test]
fn read_run_terminal_wait_new_matches_only_output_printed_after_the_call() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    surface.apply_stream_output_for_test(b"old READY\r\n$ echo READY").unwrap();
    let wait = |fields: Value| {
        dispatch(&mux, parsed_request("terminal.wait", &selectors, fields, None)).unwrap()
    };
    let old = wait(json!({"pattern": "READY", "timeout_ms": "0"}));
    assert_eq!(old["matched"], true, "a plain wait matches the old text and the echo");
    let fresh = wait(json!({"pattern": "READY", "timeout_ms": "0", "new": true}));
    assert_eq!(fresh["matched"], false, "new text only: {fresh}");

    let request = parsed_request(
        "terminal.wait",
        &selectors,
        json!({"pattern": "(?m)^READY$", "timeout_ms": "2000", "new": true}),
        None,
    );
    let waiting_mux = mux.clone();
    let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while surface.terminal_stream_waiter_count_for_test() != Some(1) {
        assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
        std::thread::yield_now();
    }
    surface.apply_stream_output_for_test(b"\r\nREADY\r\n").unwrap();
    let result = waiter.join().unwrap().unwrap();
    assert_eq!(result["matched"], true, "{result}");
    assert_eq!(result["text"].as_str().unwrap().trim(), "READY");
}

#[test]
fn read_run_terminal_record_carries_the_osc_133_exit_status_only_with_shell_integration() {
    let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
    surface.apply_stream_output_for_test(b"$ sh -c 'exit 7'\r\n$ ").unwrap();
    let plain = terminal_record(&mux, &selectors);
    assert!(plain["extra"].get("last_command").is_none(), "no marks, no status: {plain}");

    surface.apply_stream_output_for_test(
        b"\x1b]133;A\x07$ \x1b]133;B\x07sh -c 'exit 7'\r\n\x1b]133;C\x07\x1b]133;D;7\x07\x1b]133;A\x07$ ",
    )
    .unwrap();
    let record = terminal_record(&mux, &selectors);
    assert_eq!(record["extra"]["last_command"]["exit_code"], 7, "{record}");
    assert!(record["extra"]["last_command"]["finished_at_ms"].is_string());
    assert!(record["extra"]["prompt"].is_object());
}

fn capture_diagnostics(mux: &Mux) -> Arc<std::sync::Mutex<Vec<String>>> {
    let diagnostics = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = diagnostics.clone();
    assert!(mux.set_diagnostic_reporter(Arc::new(move |message| {
        sink.lock().unwrap().push(message.to_string());
    })));
    diagnostics
}

#[test]
fn a_failed_outcome_commit_reports_its_cause_to_the_daemon_log() {
    let (mux, _surface, selectors) = terminal_fixture(None);
    let diagnostics = capture_diagnostics(&mux);
    mux.reject_resource_effect_commits_for_test();

    let error = dispatch(
        &mux,
        parsed_request(
            "terminal.input.write",
            &selectors,
            json!({"text":"echo cause\n"}),
            Some("terminal-write-commit-cause"),
        ),
    )
    .unwrap_err();

    assert_eq!(error.code, "mutation.indeterminate");
    let diagnostics = diagnostics.lock().unwrap();
    assert!(
        diagnostics.iter().any(|message| message.contains("terminal.input.write")
            && message.contains("terminal-write-commit-cause")
            && message.contains("injected outcome commit failure")),
        "the daemon log has no cause for the indeterminate outcome: {diagnostics:?}"
    );
}

#[test]
fn an_unconfirmed_terminal_input_reports_its_kind_but_no_private_detail() {
    let (mux, _surface, _selectors) = terminal_fixture(None);
    let diagnostics = capture_diagnostics(&mux);
    let private = "internal socket /private/terminal.sock token=secret-test-value";
    let failure = crate::surface::ConfirmedInputFailure::Indeterminate(std::io::Error::new(
        std::io::ErrorKind::TimedOut,
        private,
    ));
    let prepared = PreparedEffect {
        idempotency_key: "terminal-write-transport-cause".into(),
        operation: "terminal.input.write".into(),
        fingerprint: json!({}),
        intent: json!({}),
    };

    let error = finish_action_failure(
        &mux,
        prepared,
        confirmed_input_error("terminal.input.write", failure),
    )
    .unwrap_err();

    assert_eq!(error.code, "mutation.indeterminate");
    assert!(!error.details.to_string().contains(private));
    let diagnostics = diagnostics.lock().unwrap();
    assert!(
        diagnostics.iter().any(|message| message.contains("terminal-write-transport-cause")
            && message.contains("TimedOut")),
        "the daemon log has no cause for the unconfirmed input: {diagnostics:?}"
    );
    assert!(
        diagnostics.iter().all(|message| !message.contains("secret-test-value")),
        "raw transport text reached the daemon log: {diagnostics:?}"
    );
}
