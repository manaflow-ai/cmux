//! `notification-program-status-v1`: a notification the daemon posts for an
//! OSC 7501 record that entered `blocked` or `error` carries the structured
//! reason (`program_status`: state, kind, msg) next to its English title and
//! body, so a client can show the body in its own language. It is on the
//! legacy `notification` event, the `list-notifications` rows and the resource
//! API value (`extra.program_status`), and it survives a daemon restart
//! through the durable receipt. Every other producer leaves it absent.

use super::*;
use crate::program_status::ProgramStatusRecords;
use crate::workspace_registry::WorkspaceRegistry;
use ghostty_vt::{ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport, ProgramStatusState};

const CAPABILITY: &str = "notification-program-status-v1";

fn run_json_command(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

fn report(
    id: &str,
    state: ProgramStatusState,
    kind: Option<ProgramStatusKind>,
    app: &str,
    message: &str,
) -> ProgramStatusEvent {
    ProgramStatusEvent::Report(ProgramStatusReport {
        state,
        kind,
        progress: None,
        id: id.into(),
        app: app.into(),
        title: String::new(),
        message: message.into(),
    })
}

/// The alerts the terminal's records keep for these reports, as the
/// publisher takes them.
fn alerts(events: Vec<ProgramStatusEvent>) -> Vec<crate::program_status::ProgramStatusAlert> {
    let mut records = ProgramStatusRecords::default();
    for (index, event) in events.into_iter().enumerate() {
        records.apply(event, index as u64 + 1);
    }
    records.take_alerts()
}

/// The resource API notification value titled `title`.
fn snapshot_row(mux: &Arc<Mux>, title: &str) -> Value {
    let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
    snapshot["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["title"] == title)
        .cloned()
        .unwrap_or_else(|| panic!("no notification titled {title}: {snapshot}"))
}

/// The `list-notifications` row titled `title`.
fn listed_row(mux: &Arc<Mux>, title: &str) -> Value {
    let listed = run_json_command(mux, json!({"cmd": "list-notifications"}));
    listed["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["title"] == title)
        .cloned()
        .unwrap_or_else(|| panic!("no notification titled {title}: {listed}"))
}

fn approval() -> Value {
    json!({"state": "blocked", "kind": "permission", "msg": "Apply?"})
}

fn failure() -> Value {
    json!({"state": "error", "kind": null, "msg": null})
}

/// The ledger, the list and the resource value of the three notifications.
fn assert_reasons(mux: &Arc<Mux>) {
    let plain = listed_row(mux, "plain");
    assert!(plain.get("program_status").is_none(), "{plain}");
    assert_eq!(listed_row(mux, "terraform")["program_status"], approval());
    assert_eq!(listed_row(mux, "make")["program_status"], failure());

    let plain = snapshot_row(mux, "plain");
    assert!(plain["extra"].get("program_status").is_none(), "{plain}");
    let approved = snapshot_row(mux, "terraform");
    assert_eq!(approved["extra"]["program_status"], approval());
    assert_eq!(approved["extra"]["source"], "terminal");
    assert_eq!(approved["body"], "Needs approval: Apply?", "the English body stays");
    assert_eq!(snapshot_row(mux, "make")["extra"]["program_status"], failure());
}

#[test]
fn program_status_notifications_carry_their_reason_through_a_restart() {
    assert!(advertised_capabilities(false).contains(&CAPABILITY));
    let root = std::env::temp_dir().join(format!(
        "cmux-notification-program-status-{}",
        crate::resource::WorkspacePublicId::random().unwrap()
    ));
    let session = "notification-program-status";
    let open = || {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        Mux::from_workspace_registry(
            session.into(),
            crate::SurfaceOptions::default(),
            registry,
            crate::mux::ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    let surface = mux.new_workspace(None, None).unwrap();
    let events = mux.subscribe();

    mux.post_notification("plain".into(), "".into(), NotificationLevel::Info, Some(surface.id))
        .unwrap();
    let posted = alerts(vec![
        report("", ProgramStatusState::Working, None, "terraform", ""),
        report(
            "",
            ProgramStatusState::Blocked,
            Some(ProgramStatusKind::Permission),
            "terraform",
            "Apply?",
        ),
        report("build", ProgramStatusState::Error, None, "make", ""),
    ]);
    assert_eq!(posted.len(), 2);
    mux.post_program_status_alerts(surface.id, "zsh", posted);

    let notified = events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::Notification(_)))
        .map(|event| subscribed_event_json(&event))
        .collect::<Vec<_>>();
    assert_eq!(notified.len(), 3, "{notified:?}");
    assert!(notified[0].get("program_status").is_none(), "{}", notified[0]);
    assert_eq!(notified[1]["program_status"], approval());
    assert_eq!(notified[1]["title"], "terraform");
    assert_eq!(notified[1]["body"], "Needs approval: Apply?");
    assert_eq!(notified[2]["program_status"], failure());
    assert_eq!(notified[2]["body"], "Failed");
    assert_reasons(&mux);
    drop(events);
    mux.shutdown();
    drop(mux);

    let mux = open();
    assert_reasons(&mux);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
