//! `subscribed_event_name` and `page_relay_takes` (cmd_subscribe.rs) against
//! the lines `subscribe` sends and the pages of page-router.json.

use std::sync::Arc;

use serde_json::json;

use super::*;

/// Every event a page relay could take is named the same by the mailbox
/// filter as by the line it sends.
#[test]
fn subscribed_event_name_matches_the_wire_event() {
    let events = [
        MuxEvent::SurfaceOutput(1),
        MuxEvent::SurfaceExited(1, None),
        MuxEvent::Bell(1),
        MuxEvent::Status("x".into()),
        MuxEvent::ScreenDeviceChanged(None),
        MuxEvent::ConfigReloadRequested,
        MuxEvent::WindowTitleRequested("t".into()),
        MuxEvent::ScrollChanged { surface: 1, offset: 0, at_bottom: true },
        MuxEvent::TreeChanged,
        MuxEvent::TreeSelectionChanged(None),
        MuxEvent::PersonalChanged { personal_revision: 1 },
        MuxEvent::StashChanged { revision: 1 },
        MuxEvent::HistoryChanged { revision: 1, kinds: vec![] },
        MuxEvent::FeedViewChanged { revision: 1, changed: Arc::from(vec!["a".to_string()]) },
        MuxEvent::FeedReportsChanged { revision: 1 },
        MuxEvent::TerminalReaped { terminal_id: "t".into(), terminal: None, grace_ms: 1 },
        MuxEvent::ClientDetached(1),
        MuxEvent::ClientListInvalidated,
        MuxEvent::PairingResolved { request: 1 },
        MuxEvent::MachineUsageChanged(None),
        MuxEvent::AppsChanged(Arc::new(json!({"event": "apps-changed", "app": "a"}))),
        MuxEvent::TasksChanged(Arc::new(json!({"event": "tasks-changed", "lost": true}))),
        MuxEvent::AgentSessionShareChanged { session: "s".into() },
        MuxEvent::ComputerUseActivity(Arc::new(json!({"event": "computer-use-activity"}))),
        MuxEvent::ComputerUsePreview(Arc::new(json!({"event": "computer-use-preview"}))),
        MuxEvent::SwapDone(Arc::new(json!({"event": "swap.done", "layer": "web"}))),
    ];
    for event in &events {
        let wire = subscribed_event_json(event);
        assert_eq!(subscribed_event_name(event), wire["event"].as_str(), "{wire}",);
    }
    for event in [
        MuxEvent::ChatsChanged { revision: 1 },
        MuxEvent::GitHubChanged { live: None },
        MuxEvent::Empty,
    ] {
        assert_eq!(subscribed_event_name(&event), None);
    }
}

/// Every page that names events in page-router.json takes exactly them,
/// and no terminal's output.
#[test]
fn each_page_relay_takes_its_page_router_events() {
    let output = MuxEvent::SurfaceOutput(3);
    for page in ["history", "stash", "apps", "bookmarks", "tasks", "feed"] {
        let names = crate::request_origin::page_router_table::page_events(page);
        assert!(!names.is_empty(), "{page}");
        assert!(!page_relay_takes(names, &output), "{page}");
        assert!(page_relay_takes(names, &MuxEvent::Empty), "{page}");
    }
    let history = crate::request_origin::page_router_table::page_events("history");
    assert!(page_relay_takes(history, &MuxEvent::HistoryChanged { revision: 1, kinds: vec![] }));
    assert!(!page_relay_takes(history, &MuxEvent::StashChanged { revision: 1 }));
}
