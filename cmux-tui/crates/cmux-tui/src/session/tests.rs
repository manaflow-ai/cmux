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

/// A remote-terminal tab (`remote-terminal-tabs-v1`) of an in-process daemon,
/// made and retitled over the daemon's socket, as the app does it.
#[cfg(unix)]
struct RemoteTerminalTab {
    mux: std::sync::Arc<Mux>,
    dir: std::path::PathBuf,
    surface: cmux_tui_core::SurfaceId,
}

#[cfg(unix)]
impl RemoteTerminalTab {
    fn open(label: &str) -> Self {
        let mux = Mux::new(format!("remote-terminal-title-{label}"), SurfaceOptions::default());
        mux.new_workspace(None, Some((80, 24))).unwrap();
        let dir = std::path::PathBuf::from(format!("/tmp/cmux-rtt-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        cmux_tui_core::server::serve(mux.clone(), Some(dir.join("mux.sock"))).unwrap();
        let mut tab = Self { mux, dir, surface: 0 };
        let created = tab.request(serde_json::json!({
            "id": 1, "cmd": "new-remote-terminal-tab",
            "session_id": "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f",
            "terminal_id": "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f",
            "session_name": "build-box",
        }));
        tab.surface = created["surface"].as_u64().expect("the daemon names the new tab's surface");
        tab
    }

    fn request(&self, command: serde_json::Value) -> serde_json::Value {
        use std::io::{BufRead as _, Write as _};
        let stream = std::os::unix::net::UnixStream::connect(self.dir.join("mux.sock")).unwrap();
        let mut writer = stream.try_clone().unwrap();
        writeln!(writer, "{command}").unwrap();
        let mut line = String::new();
        std::io::BufReader::new(stream).read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "{command} failed: {response}");
        response["data"].clone()
    }

    /// The terminal on the other session reports `title`; the daemon stores it.
    fn retitle(&self, title: &str) {
        let updated = self.request(serde_json::json!({
            "id": 2, "cmd": "update-remote-terminal-tab", "surface": self.surface, "title": title,
        }));
        assert_eq!(updated["changed"], true, "the daemon stores {title:?}: {updated}");
    }

    /// The tab as `list-workspaces` reports it.
    fn wire(&self) -> serde_json::Value {
        let tree = self.request(serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
        tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| workspace["screens"].as_array().cloned().unwrap_or_default())
            .flat_map(|screen| screen["panes"].as_array().cloned().unwrap_or_default())
            .flat_map(|pane| pane["tabs"].as_array().cloned().unwrap_or_default())
            .find(|tab| tab["surface"] == serde_json::json!(self.surface))
            .unwrap_or_else(|| panic!("surface {} is not in the tree: {tree}", self.surface))
    }
}

#[cfg(unix)]
impl Drop for RemoteTerminalTab {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A remote terminal's spinner only animates, as a local terminal's does
/// (plans/cmux-next/main-thread-scheduling.md, D2): 20 frames of one working
/// title change what the tab shows once, so the daemon announces one
/// `title-changed` and one `tab-changed`, not one of each per frame. Each
/// frame's raw title is still stored.
#[cfg(unix)]
#[test]
fn remote_terminal_tab_title_spinner_frames_announce_one_title() {
    use cmux_tui_core::{MuxEvent, TreeDeltaKind};

    let tab = RemoteTerminalTab::open("spinner");
    let events = tab.mux.subscribe();
    let mut titles: Vec<String> = Vec::new();
    let mut tab_changes = 0usize;
    for frame in "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠋⠙⠹⠸⠼⠴⠦⠧⠇⠿".chars() {
        tab.retitle(&format!("{frame} Fix the login bug"));
        // A mailbox keeps one unread title per surface, so read after every
        // frame: the daemon publishes before it answers the request.
        for event in events.try_iter() {
            match event {
                MuxEvent::TitleChanged { surface, title, .. } if surface == tab.surface => {
                    titles.push(title.to_string());
                }
                MuxEvent::TreeDelta(delta)
                    if delta.kind == TreeDeltaKind::TabChanged
                        && delta.surface == Some(tab.surface) =>
                {
                    tab_changes += 1;
                }
                _ => {}
            }
        }
    }
    assert_eq!(
        (titles.len(), tab_changes),
        (1, 1),
        "(title-changed, tab-changed) for 20 spinner frames of one text; titles {titles:?}"
    );
    let wire = tab.wire();
    assert_eq!(wire["title"], "⠿ Fix the login bug", "the last raw title is stored: {wire}");
    assert_eq!(wire["title_text"], "Fix the login bug", "{wire}");
}

/// The in-process TUI builds its tree from the daemon's state, not from
/// `list-workspaces`. A remote-terminal tab is a terminal there too: its tab
/// shows the title without the status glyph, as the wire tree's `title_text`
/// does and as a local terminal's tab does.
#[cfg(unix)]
#[test]
fn remote_terminal_tab_title_in_the_local_tree_has_no_status_glyph() {
    let tab = RemoteTerminalTab::open("tree");
    tab.retitle("⠋ Fix the login bug");
    let wire = tab.wire();
    assert_eq!(wire["kind"], "remote-terminal", "{wire}");
    assert_eq!(wire["title_text"], "Fix the login bug", "{wire}");

    let tree = Session::Local(tab.mux.clone()).tree();
    let shown = tree.surface(tab.surface).map(|view| view.title.clone());
    assert_eq!(shown.as_deref(), Some("Fix the login bug"), "the local tree's tab title");
}
