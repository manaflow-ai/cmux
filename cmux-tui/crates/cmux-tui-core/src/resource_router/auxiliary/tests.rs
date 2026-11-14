use super::*;
use crate::resource::{RequestEnvelope, RequestId};
use crate::{SidebarPluginOptions, SurfaceOptions};
use std::time::{Duration, Instant};

fn public_id(prefix: &str, value: u128) -> String {
    format!("{prefix}_{value:032x}")
}

fn request(
    operation: ResourceOperation,
    key: Option<&str>,
    selectors: ResourceSelectors,
    fields: Value,
) -> ParsedResourceRequest {
    ParsedResourceRequest {
        envelope: RequestEnvelope::request(
            RequestId::parse(format!("aux-{operation:?}")).unwrap(),
            operation,
            json!({}),
            key.map(str::to_string),
        ),
        selectors,
        fields: fields.as_object().unwrap().clone(),
        actor: crate::Actor::local_user(),
    }
}

fn session_selectors() -> ResourceSelectors {
    ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..Default::default()
    }
}

#[test]
fn sidebar_input_emits_a_delta_only_when_public_lifecycle_changes() {
    let sidebar_id =
        SidebarViewPublicId::parse(public_id("sidebar_view", 1)).expect("sidebar test id");
    let before = json!({
        "id":sidebar_id,
        "session_id":public_id("session", 1),
        "cols":80,
        "rows":24,
        "running":true,
    });
    assert!(sidebar_input_lifecycle_delta(&sidebar_id, &before, &before).is_none());

    let mut after = before.clone();
    after["running"] = json!(false);
    let changes = sidebar_input_lifecycle_delta(&sidebar_id, &before, &after).unwrap();
    assert_eq!(changes[0]["kind"], "upsert");
    assert_eq!(changes[0]["resource"], "sidebar_view");
    assert_eq!(changes[0]["id"], sidebar_id.as_str());
    assert_eq!(changes[0]["value"], after);
}

#[test]
fn pending_pairing_snapshots_use_public_ids_and_wire_decimals() {
    let mux = Mux::new_for_test("aux-pairing", SurfaceOptions::default());
    let (challenge, _response) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let session = resolve_session(
        &mux,
        &ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..Default::default()
        },
    )
    .unwrap();
    let snapshot = pairing_snapshot(&session, &challenge, "pending").unwrap();
    assert!(snapshot["id"].as_str().unwrap().starts_with("pairing_"));
    assert_eq!(snapshot["expires_in_seconds"], "60");
    assert_eq!(snapshot["status"], "pending");
    assert_eq!(
        pairing_numeric_id(
            &PairingRequestPublicId::parse(snapshot["id"].as_str().unwrap().to_string()).unwrap()
        )
        .unwrap(),
        challenge.id
    );
}

#[test]
fn agent_report_replays_and_list_filters_by_public_terminal() {
    let mux = Mux::new_for_test("aux-agent", SurfaceOptions::default());
    let created = crate::resource_router::handle_parsed_resource_request(
        &mux,
        request(
            ResourceOperation::WorkspaceCreate,
            Some("aux-agent-create"),
            session_selectors(),
            json!({"initial_content":"terminal"}),
        ),
    )
    .unwrap();
    assert_eq!(created["ok"], true);
    let terminal_id = TerminalPublicId::parse(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["terminals"][0]["id"]
            .as_str()
            .unwrap()
            .to_string(),
    )
    .unwrap();
    let report_request = |key| {
        request(
            ResourceOperation::AgentReport,
            Some(key),
            session_selectors(),
            json!({
                "terminal_id":terminal_id,
                "state":"working",
                "source":"socket",
                "source_session":"sdk-test",
            }),
        )
    };
    let first = dispatch(&mux, report_request("agent-report-once")).unwrap();
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["terminal_id"], terminal_id.as_str());
    assert_eq!(first["value"]["state"], "working");
    assert_eq!(first["value"]["source_session"], "sdk-test");
    let replay = dispatch(&mux, report_request("agent-report-once")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], first["value"]);
    let revision_after_first = first["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let epoch_after_first = mux.resource_event_epoch();
    let repeated = dispatch(&mux, report_request("agent-report-twice")).unwrap();
    assert_eq!(repeated["replayed"], true);
    assert_eq!(repeated["revision"], revision_after_first.to_string());
    assert_eq!(repeated["value"], first["value"]);
    assert_eq!(mux.resource_event_epoch(), epoch_after_first);
    assert_eq!(
        mux.with_state(|state| state.resource_revision),
        revision_after_first,
        "a same-state socket report must not advance the shared revision"
    );
    assert!(
        !first["value"]["id"]
            .as_str()
            .unwrap()
            .ends_with(terminal_id.as_str().trim_start_matches("term_")),
        "agent ids must remain stable without revealing the terminal id payload"
    );

    let listed = dispatch(
        &mux,
        request(
            ResourceOperation::AgentList,
            None,
            session_selectors(),
            json!({"terminal_id":terminal_id,"state":"working"}),
        ),
    )
    .unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], first["value"]["id"]);
}

#[test]
fn public_agent_report_rejects_internal_plugin_and_detected_sources() {
    for source in ["plugin", "detected"] {
        assert!(parse_agent_source(source).is_err(), "{source} is an internal projection source");
    }
    assert!(parse_agent_source("hook").is_ok());
    assert!(parse_agent_source("socket").is_ok());
}

#[test]
fn filtered_agent_list_does_not_decode_unrelated_projections() {
    let mux = Mux::new_for_test("filtered-agent-list", SurfaceOptions::default());
    let requested = mux.new_workspace(Some("requested".into()), None).unwrap();
    let unrelated = mux.new_workspace(Some("unrelated".into()), None).unwrap();
    let requested_terminal = requested.terminal_public_id().cloned().unwrap();
    let unrelated_terminal = unrelated.terminal_public_id().cloned().unwrap();

    for (surface, session) in [(requested.id, "requested"), (unrelated.id, "unrelated")] {
        mux.report_agent(surface, AgentState::Working, AgentSource::Hook, Some(session.into()))
            .unwrap();
    }
    mux.corrupt_agent_projection_for_test(&unrelated_terminal);

    let listed = dispatch(
        &mux,
        request(
            ResourceOperation::AgentList,
            None,
            session_selectors(),
            json!({"terminal_id":requested_terminal,"state":"working"}),
        ),
    )
    .expect("the selected query must not decode an unrelated projection");
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["terminal_id"], requested_terminal.as_str());
}

#[test]
fn pairing_resolution_replays_without_resolving_twice() {
    let mux = Mux::new_for_test("aux-pairing-resolve", SurfaceOptions::default());
    let (challenge, response) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let id = format!("pairing_{:032x}", challenge.id);
    let mut selected = session_selectors();
    selected.pairing_request = Some(id);
    let resolve_request = || ParsedResourceRequest {
        actor: crate::Actor::Frontend { install_id: "test".into() },
        ..request(
            ResourceOperation::PairingRequestResolve,
            Some("pairing-resolve-once"),
            selected.clone(),
            json!({"decision":"accept"}),
        )
    };
    let first = dispatch_trusted_local(&mux, resolve_request()).unwrap();
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["pairing_request"]["status"], "accepted");
    assert!(matches!(
        response.recv_timeout(Duration::from_secs(1)).unwrap(),
        crate::PairingDecision::Approved { .. }
    ));
    let replay = dispatch_trusted_local(&mux, resolve_request()).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], first["value"]);
    assert!(mux.pending_pairings().is_empty());
}

#[test]
fn frontend_projection_round_trips_exact_json_and_replays() {
    let mux = Mux::new_for_test("aux-projection", SurfaceOptions::default());
    let projection_id = FrontendProjectionPublicId::random().unwrap();
    let mut selected = session_selectors();
    selected.frontend_projection = Some(projection_id.to_string());
    let put_request = || {
        request(
            ResourceOperation::FrontendProjectionPut,
            Some("projection-put-once"),
            selected.clone(),
            json!({
                "frontend_id":"cmux-test",
                "window_id":"window-test",
                "generation":"launch-test",
                "projection":{"columns":[{"workspace":"α"}]},
            }),
        )
    };
    let first = dispatch(&mux, put_request()).unwrap();
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["projection"], json!({"columns":[{"workspace":"α"}]}));
    let revision = first["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let events = mux.resource_events_after(0).unwrap();
    assert_eq!(events.head_revision, revision);
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].changes[0]["resource"], "frontend_projection");
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["cursor"]["revision"],
        first["revision"]
    );
    let replay = dispatch(&mux, put_request()).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], first["value"]);
    let got = dispatch(
        &mux,
        request(ResourceOperation::FrontendProjectionGet, None, selected, json!({})),
    )
    .unwrap();
    assert_eq!(got, first["value"]);
}

#[test]
fn frontend_projection_cas_is_window_local() {
    let mux = Mux::new_for_test("aux-projection-window-cas", SurfaceOptions::default());
    let first_id = FrontendProjectionPublicId::random().unwrap();
    let second_id = FrontendProjectionPublicId::random().unwrap();
    let fields = |window: &str, generation: &str, selected: &str| {
        json!({
            "frontend_id":"cmux-swift",
            "window_id":window,
            "generation":generation,
            "projection":{"selected_workspace":selected},
        })
    };
    let mut first = session_selectors();
    first.frontend_projection = Some(first_id.to_string());
    let mut second = session_selectors();
    second.frontend_projection = Some(second_id.to_string());

    let initial = dispatch(
        &mux,
        request(
            ResourceOperation::FrontendProjectionPut,
            Some("projection-window-first"),
            first.clone(),
            fields("window-a", "launch-a", "alpha"),
        ),
    )
    .unwrap();
    assert_eq!(initial["value"]["projection_revision"], "1");

    dispatch(
        &mux,
        request(
            ResourceOperation::FrontendProjectionPut,
            Some("projection-window-second"),
            second,
            fields("window-b", "launch-b", "beta"),
        ),
    )
    .unwrap();

    let updated = dispatch(
        &mux,
        request(
            ResourceOperation::FrontendProjectionPut,
            Some("projection-window-first-update"),
            first,
            {
                let mut fields = fields("window-a", "launch-a", "gamma");
                fields["expected_projection_revision"] = json!("1");
                fields
            },
        ),
    )
    .unwrap();
    assert_eq!(updated["value"]["projection_revision"], "2");
    assert_eq!(updated["value"]["projection"]["selected_workspace"], "gamma");
}

#[test]
fn sidebar_resource_lifecycle_uses_the_real_plugin_pty_and_exact_receipts() {
    let mux = Mux::new("aux-sidebar-lifecycle", SurfaceOptions::default());
    mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
        command: vec!["/bin/cat".to_string()],
        cwd: None,
    }));

    let ensure_request = || {
        request(
            ResourceOperation::SidebarViewEnsure,
            Some("sidebar-ensure-once"),
            session_selectors(),
            json!({"cols":24,"rows":5,"relaunch":false}),
        )
    };
    let ensured = dispatch(&mux, ensure_request()).unwrap();
    assert_eq!(ensured["replayed"], false);
    assert_eq!(ensured["value"]["running"], true);
    assert_eq!(ensured["value"]["cols"], 24);
    assert_eq!(ensured["value"]["rows"], 5);
    let sidebar_id = ensured["value"]["id"].as_str().unwrap().to_string();
    let first_surface = mux.sidebar_plugin_status().surface.unwrap();
    let events_before_input = mux.resource_events_after(0).unwrap();

    let replay = dispatch(&mux, ensure_request()).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], ensured["value"]);
    assert_eq!(mux.sidebar_plugin_status().surface, Some(first_surface));

    let mut selected = session_selectors();
    selected.sidebar_view = Some(sidebar_id.clone());
    let input_request = || {
        request(
            ResourceOperation::SidebarViewInput,
            Some("sidebar-input-once"),
            selected.clone(),
            json!({
                "data_base64":base64::engine::general_purpose::STANDARD
                    .encode(b"resource-sidebar-input\n"),
            }),
        )
    };
    let input = dispatch(&mux, input_request()).unwrap();
    assert_eq!(input["value"], json!({}));
    assert_eq!(input["revision"], ensured["revision"]);
    let events_after_input = mux.resource_events_after(0).unwrap();
    assert_eq!(events_after_input.head_revision, events_before_input.head_revision);
    assert_eq!(events_after_input.batches.len(), events_before_input.batches.len());
    let replay = dispatch(&mux, input_request()).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], input["value"]);
    assert_eq!(replay["revision"], input["revision"]);
    let surface = mux.sidebar_plugin_surface().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
        if text.contains("resource-sidebar-input") {
            break;
        }
        assert!(Instant::now() < deadline, "input did not reach the sidebar PTY");
        std::thread::sleep(Duration::from_millis(10));
    }

    let resized = dispatch(
        &mux,
        request(
            ResourceOperation::SidebarViewResize,
            Some("sidebar-resize-once"),
            selected.clone(),
            json!({"cols":31,"rows":7}),
        ),
    )
    .unwrap();
    assert_eq!(resized["value"]["cols"], 31);
    assert_eq!(resized["value"]["rows"], 7);
    assert_eq!(mux.sidebar_plugin_surface().unwrap().size(), (31, 7));

    let got = dispatch(
        &mux,
        request(ResourceOperation::SidebarViewGet, None, selected.clone(), json!({})),
    )
    .unwrap();
    assert_eq!(got["id"], sidebar_id);
    assert_eq!(got["running"], true);
    assert_eq!(got["cols"], 31);
    assert_eq!(got["rows"], 7);

    let reloaded = dispatch(
        &mux,
        request(
            ResourceOperation::SidebarViewReload,
            Some("sidebar-reload-once"),
            selected,
            json!({}),
        ),
    )
    .unwrap();
    assert_eq!(reloaded["value"]["running"], true);
    let second_surface = mux.sidebar_plugin_status().surface.unwrap();
    assert_ne!(second_surface, first_surface);
    mux.sidebar_plugin_surface().unwrap().kill();
}
