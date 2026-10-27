//! A `cmux.protocol/2` request's `priority` (p02-threads task 224,
//! `request-priority-v1`): it parses as `user` or `automation` or not at
//! all, narrows the class the connection's origin gives the request, and
//! never raises it.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_threads::ThreadQos::{self, UserInitiated, Utility};
use serde_json::{Value, json};

use super::handle_connection_frame;
use crate::event_cause::RequestPriority;
use crate::resource::RequestEnvelope;
use crate::server::origin_gate::{set_role_for_test, set_verified_app_for_test};
use crate::server::tests::captured_writer;
use crate::server::*;

fn workspace_create(name: &str, priority: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": name,
        "operation": "workspace.create",
        "params": {"machine": "current", "session": "current", "name": name,
                   "initial_content": "empty"},
        "idempotency_key": name,
    });
    if let Some(priority) = priority {
        request["priority"] = json!(priority);
    }
    request
}

#[test]
fn request_priority_parses_user_automation_or_nothing() {
    let parse = |priority: Option<&str>| {
        serde_json::from_value::<RequestEnvelope>(workspace_create("parse", priority))
            .map(|envelope| envelope.priority)
    };
    assert_eq!(parse(None).unwrap(), None);
    assert_eq!(parse(Some("user")).unwrap(), Some(RequestPriority::User));
    assert_eq!(parse(Some("automation")).unwrap(), Some(RequestPriority::Automation));
    assert!(parse(Some("urgent")).is_err(), "an unknown priority is malformed");
    let unset = serde_json::to_value(
        serde_json::from_value::<RequestEnvelope>(workspace_create("unset", None)).unwrap(),
    )
    .unwrap();
    assert!(unset.get("priority").is_none(), "{unset}");
}

/// The classes the connection's dispatcher enters for one v2 line on a
/// connection that is the verified app (`app`) or not, with the feature on
/// (the reader runs no handler, p05-ipc-086).
fn entered_for(app: bool, priority: Option<&str>) -> Vec<ThreadQos> {
    let mux = Mux::new_for_test(
        format!("request-priority-{app}-{}", priority.unwrap_or("none")),
        crate::SurfaceOptions::default(),
    );
    mux.set_request_qos_for_test(true);
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if app {
        set_role_for_test(&mux, client, "main");
        set_verified_app_for_test(&mux, client, true);
    }
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let line = workspace_create("prioritized", priority).to_string();
    assert!(handle_connection_frame(
        &mux,
        client,
        ClientTransport::Unix,
        &line,
        &writer,
        &scheduler
    ));
    let deadline = Instant::now() + Duration::from_secs(10);
    let reply: Value = loop {
        if let Some(line) = outbound.try_pop() {
            break serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(reply["ok"], true, "{reply}");
    let entered = super::sequenced_lines_tests::dispatcher_entered(
        &mux, client, &writer, &scheduler, &outbound,
    );
    mux.shutdown();
    entered
}

/// The verified app's request runs at user-initiated without a priority and
/// with `user`, and at utility with `automation`.
#[test]
fn request_priority_narrows_the_apps_request() {
    for priority in [None, Some("user")] {
        let entered = entered_for(true, priority);
        assert_eq!(entered.first(), Some(&UserInitiated), "{priority:?}: {entered:?}");
        assert!(!entered.contains(&Utility), "{priority:?} keeps the app's class: {entered:?}");
    }
    let automation = entered_for(true, Some("automation"));
    assert_eq!(automation.get(..2), Some(&[UserInitiated, Utility][..]), "{automation:?}");
}

/// An automation connection's request stays at utility whatever priority it
/// names: `user` never raises it.
#[test]
fn request_priority_never_raises_an_automation_request() {
    for priority in [None, Some("user"), Some("automation")] {
        let entered = entered_for(false, priority);
        assert!(!entered.is_empty(), "{priority:?}");
        assert!(entered.iter().all(|class| *class == Utility), "{priority:?}: {entered:?}");
    }
}
