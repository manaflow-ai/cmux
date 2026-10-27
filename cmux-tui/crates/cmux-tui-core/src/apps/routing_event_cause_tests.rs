//! An app's op routed into the daemon (`MuxRouter::route`) sets off
//! automation events (crate::event_cause), whatever cause the supervisor
//! thread that calls it is in.

use serde_json::json;

use super::*;
use crate::event_cause::{EventCause, EventCauseScope};
use crate::{SurfaceOptions, TreeDeltaKind};

#[test]
fn event_cause_of_an_app_router_op_is_automation() {
    let mux = Mux::new_for_test("event-cause-app-router", SurfaceOptions::default());
    let router = MuxRouter::new(&mux);
    for (name, outer) in [("unscoped", None), ("in-frontend", Some(EventCause::Frontend))] {
        let events = mux.subscribe();
        {
            let _outer = outer.map(EventCauseScope::enter);
            router
                .route(
                    "app.test",
                    "workspace.create",
                    json!({"name": name, "initial_content": "empty"}),
                    Some(format!("key-{name}")),
                    Origin::default(),
                )
                .unwrap_or_else(|e| panic!("{name}: {e}"));
        }
        let causes: Vec<EventCause> = std::iter::from_fn(|| events.try_recv_caused().ok())
            .filter(|(event, _)| {
                matches!(event, MuxEvent::TreeDelta(delta)
                    if matches!(delta.kind, TreeDeltaKind::WorkspaceAdded))
            })
            .map(|(_, cause)| cause)
            .collect();
        assert!(!causes.is_empty(), "{name}: no workspace-added event");
        assert!(causes.iter().all(|cause| *cause == EventCause::Automation), "{name}: {causes:?}");
    }
    mux.shutdown();
}
