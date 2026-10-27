//! The request scopes against the test binary's one process hang watch
//! (crate::hang_watch_test_support).

use super::*;

use cmux_hang_watch::ThreadKind;

use crate::hang_watch_test_support::Harness;

#[test]
fn request_hang_watch_reports_a_query_past_its_class_deadline() {
    const THREAD: &str = "request-hang-test-query";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let owner = RequestHang::enter(MethodClass::Query);
    assert!(owner.is_some(), "a request with no frame owns its scope");
    harness.advance(Duration::from_millis(1_500));
    let hangs = harness.wait_for(THREAD, 1);
    assert_eq!(hangs[0].deadline_ms, 1_000);
    assert_eq!(hangs[0].kind, ThreadKind::Control);
}

#[test]
fn request_hang_watch_frame_takes_its_requests_class_deadline() {
    const THREAD: &str = "request-hang-test-frame";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, THREAD);
    let frame = RequestHang::frame();
    assert!(frame.is_some(), "a frame owns its thread's scope");
    assert!(RequestHang::frame().is_none(), "a nested frame keeps the running scope");
    assert!(RequestHang::enter(MethodClass::Create).is_none(), "the frame's scope watches it");
    harness.advance(Duration::from_millis(6_000));
    harness.wait_for(THREAD, 1);
    // The frame's own 1 s deadline closed when the request began.
    assert!(harness.hangs_of(THREAD).iter().all(|hang| hang.deadline_ms == 5_000));
}

#[test]
fn request_hang_watch_does_not_blame_a_may_wait_round_trip() {
    const THREAD: &str = "request-hang-test-agent-wait";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let _owner = RequestHang::enter(MethodClass::Agent);
    ipc_reply(|| {
        harness.advance(Duration::from_secs(20));
        harness.full_pass("request-hang-test-agent-control");
    });
    assert_eq!(harness.hangs_of(THREAD), Vec::new());
}

#[test]
fn request_hang_watch_still_watches_a_query_through_a_round_trip() {
    const THREAD: &str = "request-hang-test-query-wait";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let _owner = RequestHang::enter(MethodClass::Query);
    let hangs = ipc_reply(|| {
        harness.advance(Duration::from_secs(2));
        harness.wait_for(THREAD, 1)
    });
    assert_eq!(hangs[0].deadline_ms, 1_000);
}

#[test]
fn request_hang_watch_does_not_blame_wait_for() {
    const THREAD: &str = "request-hang-test-wait-for";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let command: Command = serde_json::from_value(serde_json::json!({
        "cmd": "wait-for",
        "surface": 1,
        "pattern": "never",
        "timeout_ms": 60_000,
    }))
    .expect("a wait-for command");
    assert!(command.waits_by_design());
    let _owner = RequestHang::enter_command(&command);
    harness.advance(Duration::from_secs(30));
    harness.full_pass("request-hang-test-wait-for-control");
    assert_eq!(harness.hangs_of(THREAD), Vec::new());
}

#[test]
fn request_hang_watch_scope_owner_ends_the_request() {
    let frame = RequestHang::frame();
    assert!(frame.is_some());
    assert_eq!(current_class(), None, "a frame has no class until it reaches its request");
    assert!(RequestHang::enter(MethodClass::Browser).is_none());
    assert_eq!(current_class(), Some(MethodClass::Browser));
    drop(frame);
    assert_eq!(current_class(), None);
    let owner = RequestHang::enter(MethodClass::Topology);
    assert!(owner.is_some(), "the next request on the thread opens its own scope");
    assert_eq!(current_class(), Some(MethodClass::Topology));
}

#[test]
fn request_hang_watch_watches_a_route_at_its_routed_class() {
    const THREAD: &str = "request-hang-test-route";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, THREAD);
    let _frame = RequestHang::frame();
    let head = RequestHead::parse(r#"{"id":1,"cmd":"fs.read","path":"/tmp/a"}"#);
    // An fs read past the frame's 1 s but within its routed class (Other,
    // 10 s) is not a hang.
    route(&head, || {
        assert_eq!(current_class(), Some(MethodClass::Other));
        harness.advance(Duration::from_millis(1_500));
        harness.full_pass("request-hang-test-route-control");
    });
    assert_eq!(harness.hangs_of(THREAD), Vec::new());
}

#[test]
fn request_hang_watch_route_takes_an_agent_lines_class() {
    let _frame = RequestHang::frame();
    let head = RequestHead::parse(r#"{"id":1,"cmd":"agent-session-list"}"#);
    route(&head, || assert_eq!(current_class(), Some(MethodClass::Agent)));
}

#[test]
fn request_hang_watch_reports_a_frame_that_never_reaches_its_request() {
    const THREAD: &str = "request-hang-test-frame-only";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, THREAD);
    let _frame = RequestHang::frame();
    harness.advance(Duration::from_millis(1_500));
    let hangs = harness.wait_for(THREAD, 1);
    assert_eq!(hangs[0].deadline_ms, 1_000);
}
