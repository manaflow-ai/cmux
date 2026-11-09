use crate::local_actor::TuiMuxOps;
use cmux_tui_core::{LayoutUndoError, Mux, SurfaceOptions};

use super::{
    Session, SessionPort, is_remote_surface_unavailable, normalize_remote_layout_undo_error,
    resize_action, test_remote_rejected_error_with_code, test_remote_rejected_error_with_message,
    test_remote_session_with_view_attachment_leases,
    test_remote_surface_with_missing_attachment_lease, test_remote_transport_error,
};

#[test]
fn releasing_a_missing_remote_attachment_lease_is_idempotent() {
    let session = test_remote_session_with_view_attachment_leases();

    session.release_surface_size(77).expect("a missing lease is already released");
}

#[test]
fn remote_transport_shutdown_is_not_a_local_owner_shutdown() {
    let session = super::test_remote_session_without_provider_authority();

    assert!(!session.daemon_shutdown_requested());
    session.begin_shutdown();
    assert!(!session.daemon_shutdown_requested());
}

#[test]
fn resizing_a_surface_after_its_attachment_disappears_is_superseded() {
    let surface = test_remote_surface_with_missing_attachment_lease(77);
    let (report_tx, report_rx) = std::sync::mpsc::sync_channel(1);

    let accepted = surface
        .resize_reporting_acceptance(
            100,
            30,
            false,
            Box::new(move |reservation| report_tx.send(reservation).unwrap()),
        )
        .expect("a resize cannot fail after its attachment has already disappeared");

    assert!(!accepted);
    assert_eq!(report_rx.recv().unwrap(), None);
}

#[test]
fn remote_surface_unavailable_matches_only_the_requested_surface_rejection() {
    assert!(is_remote_surface_unavailable(
        &test_remote_rejected_error_with_message("unknown surface 77"),
        77
    ));
    assert!(!is_remote_surface_unavailable(
        &test_remote_rejected_error_with_message("unknown surface 78"),
        77
    ));
    assert!(!is_remote_surface_unavailable(&test_remote_transport_error(), 77));
}

#[test]
fn remote_layout_undo_error_codes_restore_typed_failures() {
    let stale = normalize_remote_layout_undo_error(test_remote_rejected_error_with_code(
        "layout changed",
        LayoutUndoError::STALE_CODE,
    ));
    assert!(matches!(
        stale.downcast_ref::<LayoutUndoError>(),
        Some(LayoutUndoError::Stale(message)) if message == "layout changed"
    ));

    let unavailable = normalize_remote_layout_undo_error(test_remote_rejected_error_with_code(
        "no layout change to undo",
        LayoutUndoError::UNAVAILABLE_CODE,
    ));
    assert!(matches!(
        unavailable.downcast_ref::<LayoutUndoError>(),
        Some(LayoutUndoError::Unavailable)
    ));
}

#[test]
fn first_layout_after_attach_sends_ordered_resize() {
    let desired = (123, 65);
    assert!(resize_action(desired, None));
}

#[test]
fn already_sized_first_layout_does_not_send_redundant_resize() {
    let desired = (123, 65);
    assert!(!resize_action(desired, Some(desired)));
}

#[test]
fn shared_resize_does_not_reassert_unchanged_local_report() {
    let desired = (123, 65);
    assert!(!resize_action(desired, Some(desired)));
}

#[test]
fn steady_state_does_not_send() {
    let desired = (123, 65);
    assert!(!resize_action(desired, Some(desired)));
}

#[test]
fn local_set_split_ratio_rejects_an_unknown_split() {
    let session = Session::Local(Mux::new("unknown-local-split-test", SurfaceOptions::default()));

    let error = session.set_split_ratio(999_999, 0.5).unwrap_err();
    assert_eq!(error.to_string(), "unknown split 999999");
}

#[test]
fn session_port_agents_matches_existing_agent_read() {
    let session = Session::Local(Mux::new("session-port-agents-test", SurfaceOptions::default()));
    let direct = session.agents_impl();
    let port: &dyn SessionPort = &session;
    assert_eq!(port.agents(), direct);
}

#[test]
fn local_provider_guard_surfaces_actionable_ordinary_mutation_errors() {
    let mux = Mux::new("local-provider-guard-test", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("managed".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa06".into()),
            None,
        )
        .unwrap();
    let session = Session::Local(mux.clone());
    session.mark_workspaces_provider_managed().unwrap();

    let rename_error =
        session.rename_workspace(workspace.workspace, "raw rename".into()).unwrap_err();
    let close_error = session.close_workspace(workspace.workspace).unwrap_err();

    assert_eq!(
        rename_error.to_string(),
        "cannot rename a provider-managed workspace directly; use the managed workspace lifecycle controls"
    );
    assert_eq!(
        close_error.to_string(),
        "cannot close a provider-managed workspace directly; use the managed workspace lifecycle controls"
    );
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].name, "managed");
    });
}

#[test]
fn machine_usage_payload_decodes_and_degrades_to_none() {
    use super::parse_machine_usage;
    use serde_json::json;

    let ready = json!({
        "usage": {
            "vm_id": "vm-1",
            "period_days": 30,
            "total_tokens": 17,
            "api_equivalent_usd": 1.23,
            "as_of": "2026-09-01T00:00:00Z"
        }
    });
    let usage = parse_machine_usage(&ready).expect("ready usage decodes");
    assert_eq!(usage.vm_id, "vm-1");
    assert_eq!(usage.period_days, 30);
    assert_eq!(usage.total_tokens, 17);
    assert!((usage.api_equivalent_usd - 1.23).abs() < f64::EPSILON);
    assert_eq!(usage.as_of.as_deref(), Some("2026-09-01T00:00:00Z"));

    let without_stamp = json!({"usage": {
        "vm_id": "vm-1", "period_days": 30, "total_tokens": 0, "api_equivalent_usd": 0.0, "as_of": null
    }});
    assert_eq!(parse_machine_usage(&without_stamp).map(|usage| usage.as_of), Some(None));

    assert_eq!(parse_machine_usage(&json!({"usage": null})), None);
    assert_eq!(parse_machine_usage(&json!({})), None);
    assert_eq!(parse_machine_usage(&json!({"usage": {"vm_id": "vm-1"}})), None);
    assert_eq!(
        parse_machine_usage(&json!({"usage": {
            "vm_id": "vm-1", "period_days": -1, "total_tokens": 0, "api_equivalent_usd": 0.0
        }})),
        None
    );
}

/// Against a `shared-sizing-v1` daemon, focusing a terminal is activity
/// only: it must not send the legacy `set-client-sizing`, which clears a
/// "not counted" choice another participant (the Mac) made for this TUI.
#[test]
fn shared_sizing_focus_keeps_a_counts_choice_made_elsewhere() {
    use cmux_tui_core::sizing_policy::TerminalDeviceKind;

    let mux = Mux::new("shared-sizing-focus-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let dir = std::path::PathBuf::from(format!("/tmp/cmux-szf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    cmux_tui_core::server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let session = Session::Remote(super::RemoteSession::connect(&socket).unwrap());
    session.refresh_tree().unwrap();
    assert!(matches!(
        session.try_surface_sized(surface.id, Some((100, 40))).unwrap(),
        super::SurfaceAttach::Attached(_)
    ));
    let tui = || {
        mux.terminal_size_state(surface.id)
            .unwrap()
            .participants
            .iter()
            .find(|row| {
                row.participant.device_kind == TerminalDeviceKind::Tui && row.participant.id != "c0"
            })
            .map(|row| row.participant.clone())
            .expect("the remote TUI joined shared sizing")
    };
    let id = tui().id;
    mux.set_terminal_size_counts(surface.id, &id, Some(false)).unwrap();

    session.claim_terminal_geometry(surface.id).unwrap();

    assert_eq!(tui().counts_override, Some(false));
    let _ = std::fs::remove_dir_all(&dir);
}
