//! Parity tests for the remote view sessions rules (`view/session.rs`,
//! `view/tabs.rs`), ported from the Swift suites that pin them:
//! RemoteVNCMappingTests, RemoteVNCReconnectTests and RemoteVNCGenerationTests
//! (RemoteViewVNCTests.swift), and the page session and control surface cases
//! of CloudDesktopLinkTests.swift. The JSON tests go through
//! `cmux_rd_view_call`, as the Swift shell will.

use serde_json::{Value, json};

use crate::view::pane::{ControlMode, ModeControl, SessionEnd, SessionState};
use crate::view::session::{
    self, Endpoint, MakeContext, PageEffect as P, PageEvent, PageSession, PaneButton, RfbError,
    SessionKind, SourceFence, VncEffect as V, VncEvent, VncSession, WheelScroll,
};
use crate::view::tab::{TabDecision, TabRecord, Target, UnavailableReason};
use crate::view::tabs::{self, ControlPlan, LiveTab, TabContent};
use crate::{CMUX_RD_OK, cmux_rd_view_call, cmux_rd_view_free, cmux_rd_view_new};

fn call(request: Value) -> Value {
    let view = cmux_rd_view_new();
    let bytes = request.to_string();
    let mut out: *const u8 = std::ptr::null();
    let mut len = 0usize;
    // SAFETY: a live handle and readable bytes; out pointers are writable.
    let code = unsafe { cmux_rd_view_call(view, bytes.as_ptr(), bytes.len(), &mut out, &mut len) };
    assert_eq!(code, CMUX_RD_OK, "{request}");
    // SAFETY: valid until the next call on `view`.
    let value = serde_json::from_slice(unsafe { std::slice::from_raw_parts(out, len) }).unwrap();
    // SAFETY: from cmux_rd_view_new, not used again.
    unsafe { cmux_rd_view_free(view) };
    value
}

fn record(host: &str, mode: ControlMode, cloud_desktop: bool, cloud_rd: bool) -> TabRecord {
    TabRecord {
        host: host.to_owned(),
        target: Target::Virtual,
        mode,
        vnc_port: None,
        cloud_desktop,
        cloud_rd,
    }
}

fn cloud_rd_record(mode: ControlMode) -> TabRecord {
    record("vm-1", mode, true, true)
}

const CLOUD: MakeContext = MakeContext {
    debug_build: false,
    available: false,
    cloud_rd_available: true,
    cloud_rd_route: true,
    cloud_transport: false,
    debug_rd_host: false,
};

/// Every rd transport the session asks for, in order: the first one `make`
/// builds, then each `replaceRdTransport`.
fn made(plan_control: bool, effects: &[Vec<P>]) -> Vec<bool> {
    let mut made = vec![plan_control];
    for effect in effects.iter().flatten() {
        if let P::ReplaceRdTransport { control } = effect {
            made.push(*control);
        }
    }
    made
}

const NO_VNC: [V; 0] = [];
const NO_PAGE: [P; 0] = [];

const LOST: SessionState = SessionState::Ended { reason: SessionEnd::ConnectionLost };

// MARK: - RemoteVNCMappingTests

#[test]
fn failures_map_to_pane_ends() {
    use RfbError as E;
    assert_eq!(session::end_for(None, false), SessionEnd::StoppedByViewer);
    assert_eq!(
        session::end_for(Some(E::CredentialsRequired), false),
        SessionEnd::SignInRequired { rejected: false }
    );
    assert_eq!(
        session::end_for(Some(E::PasswordRequired), false),
        SessionEnd::SignInRequired { rejected: false }
    );
    assert_eq!(
        session::end_for(Some(E::AuthenticationFailed), true),
        SessionEnd::SignInRequired { rejected: true }
    );
    assert_eq!(
        session::end_for(Some(E::AuthenticationFailed), false),
        SessionEnd::SignInRequired { rejected: false }
    );
    assert_eq!(session::end_for(Some(E::Transport), true), SessionEnd::ConnectionLost);
    assert_eq!(session::end_for(Some(E::ConnectionClosed), false), SessionEnd::ConnectionLost);
    for error in [E::UnsupportedProtocolVersion, E::NoSupportedSecurityType, E::ProtocolViolation] {
        assert_eq!(session::end_for(Some(error), true), SessionEnd::ConnectionLost);
    }
    assert_eq!(
        call(json!({"op": "vnc.endFor", "error": "authenticationFailed", "hadCredentials": true})),
        json!({"kind": "signInRequired", "rejected": true})
    );
    assert_eq!(call(json!({"op": "vnc.endFor"})), json!({"kind": "stoppedByViewer"}));
}

#[test]
fn scroll_accumulates_to_wheel_clicks() {
    let mut scroll = WheelScroll::default();
    assert_eq!(scroll.add(0, 50, false), (0, 0));
    assert_eq!(scroll.add(0, 60, false), (0, 1));
    assert_eq!(scroll.add(-250, 0, false), (-2, 0));
    assert_eq!(scroll.add(0, -1500, true), (0, -1));

    let first = call(json!({"op": "vnc.scroll", "dx": 0, "dy": 50}));
    assert_eq!((first["x"].clone(), first["y"].clone()), (json!(0), json!(0)));
    let next = call(json!({"op": "vnc.scroll", "state": first["state"], "dx": 0, "dy": 60}));
    assert_eq!(next["y"], json!(1));
}

#[test]
fn back_and_forward_have_no_rfb_button() {
    assert_eq!(session::rfb_button(PaneButton::Left), Some(PaneButton::Left));
    assert_eq!(session::rfb_button(PaneButton::Middle), Some(PaneButton::Middle));
    assert_eq!(session::rfb_button(PaneButton::Right), Some(PaneButton::Right));
    assert_eq!(session::rfb_button(PaneButton::Back), None);
    assert_eq!(call(json!({"op": "vnc.button", "button": "forward"})), Value::Null);
}

// MARK: - Endpoint, retry wait and the saved sign-in

#[test]
fn endpoints_resolve_reserved_names_and_label_v6() {
    let (endpoint, demo) = session::vnc_endpoint("LocalHost", 5900, "mock");
    assert_eq!(endpoint, Endpoint { host: "127.0.0.1".into(), port: 5900 });
    assert!(!demo);
    assert!(session::vnc_endpoint("Mock", 5901, "mock").1);
    assert_eq!(session::vnc_endpoint("10.0.0.5", 5900, "mock").0.host, "10.0.0.5");
    assert_eq!(session::cloud_endpoint("vm-1"), Endpoint { host: "vm-1".into(), port: 5901 });
    assert_eq!(Endpoint { host: "::1".into(), port: 5900 }.label(), "[::1]:5900");
    let answer = call(json!({"op": "vnc.endpoint", "host": "local", "port": 5901}));
    assert_eq!(
        answer,
        json!({"endpoint": {"host": "127.0.0.1", "port": 5901}, "demo": false, "label": "127.0.0.1:5901"})
    );
}

#[test]
fn retry_waits_back_off_to_eight_seconds() {
    let waits: Vec<u64> = (0..6).map(session::retry_wait_seconds).collect();
    assert_eq!(waits, [1, 2, 4, 8, 8, 8]);
    assert_eq!(session::retry_wait_seconds(u32::MAX), 8);
}

#[test]
fn credentials_key_is_service_and_endpoint_label() {
    let answer =
        call(json!({"op": "vnc.credentialKey", "endpoint": {"host": "fe80::1", "port": 5900}}));
    assert_eq!(
        answer,
        json!({"service": "cmux-next VNC", "account": "[fe80::1]:5900", "debugEnv": "CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE"})
    );
    assert!(session::debug_file_readable(0o600));
    assert!(session::debug_file_readable(0o100400));
    assert!(!session::debug_file_readable(0o640));
    assert!(!session::debug_file_readable(0o604));
    let stored: session::StoredCredentials = serde_json::from_str(r#"{"password":"p"}"#).unwrap();
    assert_eq!(stored.username, None);
    assert_eq!(serde_json::to_value(&stored).unwrap(), json!({"password": "p"}));
    assert_eq!(
        call(json!({"op": "vnc.signInIds"})),
        json!({"user": "user", "password": "password", "connect": "connect", "identifier": "remote.vnc.signIn"})
    );
}

// MARK: - RemoteVNCReconnectTests

#[test]
fn manual_reconnect_cancels_stale_automatic_retry() {
    let mut session = VncSession::new(true, false);
    // A lost path scheduled the automatic retry.
    assert_eq!(session.reduce(VncEvent::Loss { source: LOST }), [V::ScheduleRetry { seconds: 1 }]);
    assert!(session.retry_pending);
    assert_eq!(
        session.reduce(VncEvent::Reconnect { source: LOST }),
        [V::CancelRetry, V::ConnectCloud]
    );
    assert!(!session.retry_pending);
    assert_eq!(session.reduce(VncEvent::Connected), NO_VNC);
    // The cancelled retry ends without connecting again.
    assert_eq!(session.reduce(VncEvent::RetryFired), NO_VNC);
}

#[test]
fn queued_loss_after_manual_reconnect_schedules_no_retry() {
    let mut session = VncSession::new(true, false);
    assert_eq!(
        session.reduce(VncEvent::Reconnect { source: SessionState::Connecting }),
        [V::ConnectCloud]
    );
    session.reduce(VncEvent::Connected);
    // The old session's loss lands while the source streams.
    assert_eq!(session.reduce(VncEvent::Loss { source: SessionState::Streaming }), NO_VNC);
    assert!(!session.retry_pending);
}

#[test]
fn queued_loss_after_stop_schedules_no_retry() {
    let mut session = VncSession::new(true, false);
    session.reduce(VncEvent::Reconnect { source: SessionState::Connecting });
    assert_eq!(session.reduce(VncEvent::Stop), [V::StopSource]);
    assert_eq!(session.reduce(VncEvent::Loss { source: LOST }), NO_VNC);
    assert!(!session.retry_pending);
}

#[test]
fn losses_back_off_and_a_stream_resets_the_count() {
    let mut session = VncSession::new(true, false);
    let mut waits = Vec::new();
    for _ in 0..5 {
        for effect in session.reduce(VncEvent::Loss { source: LOST }) {
            if let V::ScheduleRetry { seconds } = effect {
                waits.push(seconds);
            }
        }
        assert_eq!(session.reduce(VncEvent::RetryFired), [V::ConnectCloud]);
    }
    assert_eq!(waits, [1, 2, 4, 8, 8]);
    session.reduce(VncEvent::Connected);
    assert_eq!(session.lost_tries, 0);
    // A compatibility host (not Cloud) never retries by itself.
    let mut local = VncSession::new(false, false);
    assert_eq!(local.reduce(VncEvent::Loss { source: LOST }), NO_VNC);
}

#[test]
fn sign_in_prompts_once_and_connects_only_on_connect() {
    let sign_in = SessionState::Ended { reason: SessionEnd::SignInRequired { rejected: false } };
    let mut session = VncSession::new(false, false);
    assert_eq!(session.reduce(VncEvent::Connect), [V::ConnectSaved]);
    assert_eq!(session.reduce(VncEvent::Reconnect { source: sign_in.clone() }), [V::PromptSignIn]);
    assert_eq!(session.reduce(VncEvent::Reconnect { source: sign_in.clone() }), NO_VNC);
    let cancel = VncEvent::SignInAnswer { button: None, dismissal: true, has_password: false };
    assert_eq!(session.reduce(cancel), [V::RepublishStatus]);
    session.reduce(VncEvent::Reconnect { source: sign_in.clone() });
    let typed = VncEvent::SignInAnswer {
        button: Some("connect".into()),
        dismissal: false,
        has_password: true,
    };
    assert_eq!(session.reduce(typed), [V::ConnectTyped]);
    // A Cloud desktop never shows the sheet.
    let mut cloud = VncSession::new(true, false);
    assert_eq!(cloud.reduce(VncEvent::Reconnect { source: sign_in }), [V::ConnectCloud]);
}

#[test]
fn the_demo_desktop_starts_once_and_close_stops_it() {
    let mut session = VncSession::new(false, true);
    assert_eq!(session.reduce(VncEvent::Connect), [V::StartDemo]);
    assert_eq!(session.reduce(VncEvent::Connect), NO_VNC);
    assert_eq!(
        session.reduce(VncEvent::DemoStarted { port: Some(6000) }),
        [V::ConnectDemo { port: 6000 }]
    );
    assert_eq!(session.reduce(VncEvent::Connect), [V::ConnectDemo { port: 6000 }]);
    assert_eq!(session.reduce(VncEvent::Close), [V::StopSource, V::StopDemo]);
    assert_eq!(session.reduce(VncEvent::Connect), NO_VNC);

    // Closed while the server started: the started server stops.
    let mut closing = VncSession::new(false, true);
    closing.reduce(VncEvent::Connect);
    assert_eq!(closing.reduce(VncEvent::Close), [V::StopSource, V::CancelDemoStart, V::StopDemo]);
    assert_eq!(closing.reduce(VncEvent::DemoStarted { port: Some(6000) }), [V::StopDemo]);

    let answer = call(
        json!({"op": "vnc.reduce", "state": VncSession::new(false, true), "event": {"kind": "connect"}}),
    );
    assert_eq!(answer["effects"], json!([{"kind": "startDemo"}]));
    assert_eq!(answer["state"]["demoStarting"], json!(true));
}

// MARK: - RemoteVNCGenerationTests

#[test]
fn old_session_cannot_publish_after_reconnect_or_stop() {
    let mut source = SourceFence::default();
    let first = source.connect();
    let second = source.connect();
    assert!(second > first);
    assert!(source.accepts(second));
    assert!(!source.accepts(first));
    assert_eq!(source.stop(), Some(second + 1));
    assert!(!source.accepts(second));
}

#[test]
fn stop_ends_the_generation_at_once() {
    let connected = call(json!({"op": "vncSource.connect", "state": SourceFence::default()}));
    assert_eq!(connected["generation"], json!(1));
    let stopped = call(json!({"op": "vncSource.stop", "state": connected["state"]}));
    assert_eq!(stopped["state"], json!({"generation": 2, "hasClient": false}));
    assert_eq!(stopped["generation"], json!(2));
    // A second stop has no session to end and publishes nothing.
    let again = call(json!({"op": "vncSource.stop", "state": stopped["state"]}));
    assert_eq!(again["generation"], Value::Null);
    assert_eq!(
        call(json!({"op": "vncSource.accepts", "state": stopped["state"], "generation": 1})),
        json!(false)
    );
}

// MARK: - Which session a record opens

#[test]
fn make_chooses_the_session_by_record_and_build() {
    let debug = MakeContext {
        debug_build: true,
        available: true,
        cloud_transport: true,
        debug_rd_host: true,
        ..MakeContext::default()
    };
    let kind = |record: &TabRecord, context| session::make(record, context, None).map(|p| p.kind);
    let cloud = cloud_rd_record(ControlMode::View);
    assert_eq!(kind(&cloud, CLOUD), Some(SessionKind::Rd));
    assert_eq!(kind(&cloud, MakeContext { cloud_rd_route: false, ..CLOUD }), None);
    assert_eq!(kind(&cloud, debug), None, "a Cloud rd record needs cmux-rd");
    let desktop = record("vm-1", ControlMode::View, true, false);
    assert_eq!(kind(&desktop, debug), Some(SessionKind::Vnc));
    assert_eq!(kind(&desktop, MakeContext { cloud_transport: false, ..debug }), None);
    assert_eq!(kind(&desktop, MakeContext { debug_build: false, ..debug }), None);
    let mut vnc = record("10.0.0.5", ControlMode::Control, false, false);
    vnc.vnc_port = Some(5900);
    let plan = session::make(&vnc, debug, None).unwrap();
    assert_eq!((plan.kind, plan.vnc_port, plan.vnc_cloud), (SessionKind::Vnc, Some(5900), false));
    assert_eq!(plan.pane.initial_mode, ControlMode::Control);
    assert!(plan.pane.layer_contents_fit);
    assert_eq!(
        kind(&record("MOCK", ControlMode::View, false, false), debug),
        Some(SessionKind::Mock)
    );
    assert_eq!(
        kind(&record("localhost", ControlMode::View, false, false), debug),
        Some(SessionKind::Rd)
    );
    assert_eq!(
        kind(
            &record("localhost", ControlMode::View, false, false),
            MakeContext { debug_rd_host: false, ..debug }
        ),
        None
    );
    assert_eq!(kind(&record("10.0.0.5", ControlMode::View, false, false), debug), None);
}

#[test]
fn a_cloud_desktop_record_in_control_still_opens_watching() {
    let record = cloud_rd_record(ControlMode::Control);
    let plan = session::make(&record, CLOUD, Some("Chief's Mac")).unwrap();
    assert_eq!(made(plan.first_control, &[]), [false]);
    assert_eq!(plan.pane.initial_mode, ControlMode::View);
    assert!(!plan.state.rd_control);
    assert_eq!(plan.pane.host_name, "Chief's Mac");
    assert_eq!(plan.pane.mode_control, ModeControl::TakeOver);
    assert!(plan.pane.via_cloud_tunnel && plan.pane.auto_reconnects_lost);
    assert!(plan.state.keeps_session_when_hidden);
    assert_eq!(call(json!({"op": "page.startsInControl", "record": record})), json!(false));
    let local = self::record("localhost", ControlMode::Control, false, false);
    assert!(session::starts_in_control(&local));
}

// MARK: - The page session

#[test]
fn take_over_restarts_the_session_in_control() {
    let plan = session::make(&cloud_rd_record(ControlMode::View), CLOUD, None).unwrap();
    let mut state = plan.state;
    let mut log = vec![state.reduce(PageEvent::Resume)];
    assert_eq!(log[0], [P::PaneStart, P::RdConnect]);
    assert_eq!(made(plan.first_control, &log), [false], "a Cloud desktop opens watching");
    assert_eq!(state.mode_control(), ModeControl::TakeOver);
    log.push(state.select_mode(true).unwrap());
    assert_eq!(
        log[1],
        [
            P::PaneStop,
            P::PaneRestartForMode,
            P::ReplaceRdTransport { control: true },
            P::PaneStart,
            P::RdConnect
        ]
    );
    assert_eq!(made(plan.first_control, &log), [false, true]);
    assert!(state.rd_control);
    log.push(state.select_mode(false).unwrap());
    assert_eq!(made(plan.first_control, &log), [false, true, false]);
    assert_eq!(
        state.reduce(PageEvent::End),
        [P::PaneStop, P::ScheduleHideGrace { seconds: 120 }, P::CancelHideGrace, P::RdStop]
    );
}

#[test]
fn the_control_surface_switches_mode_on_a_cloud_desktop() {
    let plan = session::make(&cloud_rd_record(ControlMode::View), CLOUD, None).unwrap();
    let mut state = plan.state;
    let mut log = vec![state.reduce(PageEvent::Resume)];
    let changed = call(json!({"op": "page.selectMode", "state": state, "control": true}));
    assert_eq!(changed["changed"], json!(true));
    state = serde_json::from_value(changed["state"].clone()).unwrap();
    log.push(serde_json::from_value(changed["effects"].clone()).unwrap());
    assert_eq!(made(plan.first_control, &log), [false, true]);
    // The mode in force changes nothing.
    log.push(state.select_mode(true).unwrap());
    assert_eq!(log[2], NO_PAGE);
    assert_eq!(made(plan.first_control, &log), [false, true]);
    // A session without Take over refuses.
    let mut local = PageSession::new(SessionKind::Rd, false, false);
    assert_eq!(local.select_mode(true), None);
    let refused = call(json!({"op": "page.selectMode", "state": local, "control": true}));
    assert_eq!((refused["changed"].clone(), refused["effects"].clone()), (json!(false), json!([])));
}

#[test]
fn take_over_while_hidden_ends_the_hidden_session() {
    let plan = session::make(&cloud_rd_record(ControlMode::View), CLOUD, None).unwrap();
    let mut state = plan.state;
    let mut log = vec![state.reduce(PageEvent::Resume)];
    assert_eq!(
        state.reduce(PageEvent::Pause),
        [P::PaneStop, P::ScheduleHideGrace { seconds: 120 }]
    );
    assert!(state.live_while_hidden);
    log.push(state.select_mode(true).unwrap());
    assert_eq!(log[1], [P::CancelHideGrace, P::RdStop]);
    assert!(!state.live_while_hidden, "the watching session ended");
    assert_eq!(made(plan.first_control, &log), [false]);
    log.push(state.reduce(PageEvent::Resume));
    assert_eq!(
        made(plan.first_control, &log),
        [false, true],
        "shown again: a new session, in control"
    );
}

#[test]
fn a_short_hide_keeps_the_cloud_session_and_the_grace_ends_it() {
    let mut state = PageSession::new(SessionKind::Rd, true, false);
    state.reduce(PageEvent::Resume);
    state.reduce(PageEvent::Pause);
    assert_eq!(state.reduce(PageEvent::Resume), [P::CancelHideGrace, P::PaneStart]);
    state.reduce(PageEvent::Pause);
    assert_eq!(state.reduce(PageEvent::HideGraceElapsed), [P::RdStop]);
    assert!(!state.live_while_hidden);
    assert_eq!(
        state.reduce(PageEvent::Resume),
        [P::ReplaceRdTransport { control: false }, P::PaneStart, P::RdConnect]
    );
    // A local session ends on every hide.
    let mut local = PageSession::new(SessionKind::Vnc, false, false);
    assert_eq!(local.reduce(PageEvent::Resume), [P::PaneStart, P::VncConnect]);
    assert_eq!(local.reduce(PageEvent::Pause), [P::PaneStop, P::VncStop]);
    assert_eq!(local.reduce(PageEvent::Pause), NO_PAGE);
}

#[test]
fn stop_holds_until_reconnect() {
    let mut rd = PageSession::new(SessionKind::Rd, true, false);
    rd.reduce(PageEvent::Resume);
    assert_eq!(rd.reduce(PageEvent::StopPressed), [P::RdStop]);
    // A stopped Cloud session does not linger through a hide.
    assert_eq!(rd.reduce(PageEvent::Pause), [P::PaneStop, P::RdStop]);
    assert_eq!(rd.reduce(PageEvent::Resume), NO_PAGE);
    assert_eq!(
        rd.reduce(PageEvent::ReconnectPressed),
        [P::PaneStop, P::ReplaceRdTransport { control: false }, P::PaneStart, P::RdConnect]
    );
    let mut vnc = PageSession::new(SessionKind::Vnc, false, false);
    vnc.reduce(PageEvent::Resume);
    assert_eq!(vnc.reduce(PageEvent::StopPressed), [P::VncStop]);
    vnc.reduce(PageEvent::Pause);
    assert_eq!(vnc.reduce(PageEvent::Resume), [P::PaneStart]);
    assert_eq!(vnc.reduce(PageEvent::ReconnectPressed), [P::VncReconnect]);
    let mut mock = PageSession::new(SessionKind::Mock, false, false);
    assert_eq!(mock.reduce(PageEvent::Resume), [P::PaneStart, P::MockKeyframe]);
    assert_eq!(mock.reduce(PageEvent::StopPressed), [P::MockStop]);
    assert_eq!(mock.reduce(PageEvent::ReconnectPressed), [P::MockReconnect]);
    assert_eq!(call(json!({"op": "page.view", "state": mock}))["source"], json!("mock"));
}

// MARK: - The page tab

#[test]
fn a_tab_shows_its_decision() {
    let record = cloud_rd_record(ControlMode::View);
    assert_eq!(
        tabs::content(TabDecision::Connect { record: record.clone() }),
        TabContent::Session {
            record: record.clone(),
            if_none: UnavailableReason::NoTransport { host: "vm-1".into() }
        }
    );
    let TabContent::Confirm { url, .. } =
        tabs::content(TabDecision::Confirm { record: record.clone() })
    else {
        panic!("confirm")
    };
    assert_eq!(url, record.url());
    let reason = UnavailableReason::RemoteRecord;
    assert_eq!(
        call(
            json!({"op": "pageTab.content", "decision": {"kind": "unavailable", "reason": reason}})
        ),
        json!({"kind": "unavailable", "reason": {"kind": "remoteRecord"}})
    );
    // A Cloud machine's Connect card reads its name, never its id.
    assert_eq!(tabs::gate_target_name(&record, None), "");
    assert_eq!(tabs::gate_target_name(&record, Some("Chief")), "Chief");
    let local = self::record("mock", ControlMode::View, false, false);
    assert_eq!(call(json!({"op": "pageTab.gateTarget", "record": local})), json!("mock"));
}

// MARK: - The control socket

fn live(id: &str, cloud_desktop: bool, confirm: bool, session: Value) -> LiveTab {
    LiveTab {
        id: id.into(),
        url: Some(format!("cmux-remote://{id}")),
        cloud_desktop,
        cloud_rd: cloud_desktop,
        confirm,
        session,
    }
}

#[test]
fn the_release_surface_refuses_connect_and_control() {
    let tabs: Vec<LiveTab> = Vec::new();
    let connect = tabs::plan(&tabs, Some("connect"), None, None, true);
    assert!(matches!(connect, ControlPlan::Error { .. }));
    let ControlPlan::Error { message } =
        tabs::plan(&tabs, Some("mode"), Some("t"), Some("control"), true)
    else {
        panic!("control")
    };
    assert!(message.contains("person"));
    assert_eq!(
        tabs::plan(&tabs, Some("mode"), Some("t"), Some("view"), true),
        ControlPlan::Error { message: "no live session on that tab".into() }
    );
    assert_eq!(
        call(json!({"op": "tabs.plan", "tabs": [], "action": "mode", "mode": "view"})),
        json!({"kind": "error", "message": "mode needs tab and mode (control or view)"})
    );
    assert_eq!(
        tabs::plan(&tabs, Some("mode"), Some("t"), Some("other"), false),
        ControlPlan::Error { message: tabs::MODE_NEEDS.into() }
    );
    assert_eq!(
        tabs::plan(&tabs, Some("wave"), None, None, false),
        ControlPlan::Error { message: "unknown action".into() }
    );
    assert_eq!(
        call(json!({"op": "tabs.releaseMethods"})),
        json!(["remote_view.state", "remote_view.mode"])
    );
}

#[test]
fn the_development_surface_presses_connect_and_filters() {
    let tabs = vec![
        live("a", true, true, Value::Null),
        live("b", false, true, Value::Null),
        live("c", false, false, json!({"source": "mock"})),
    ];
    assert_eq!(
        tabs::plan(&tabs, Some("connect"), None, None, false),
        ControlPlan::Press { tabs: vec!["a".into(), "b".into()] }
    );
    assert_eq!(
        tabs::plan(&tabs, None, None, None, true),
        ControlPlan::State { tabs: vec!["a".into()] }
    );
    assert_eq!(
        tabs::plan(&tabs, Some("mode"), Some("c"), Some("control"), false),
        ControlPlan::SelectMode { tab: "c".into(), mode: ControlMode::Control }
    );
}

#[test]
fn the_release_state_names_viewer_connection_and_control() {
    let asking = live("tab_state_confirm", true, true, Value::Null);
    let first = tabs::row(&asking);
    assert_eq!(first["confirm"], json!(true));
    assert_eq!(first["viewer"], json!("rd"));
    assert_eq!(first["connected"], json!(false));
    assert_eq!(first["control"], json!("agent"));
    assert_eq!(first["session"], Value::Null);
    let mut watching = live(
        "tab_state_live",
        true,
        false,
        json!({"source": "rd", "state": "connecting", "mode": "view"}),
    );
    let rows = call(json!({"op": "tabs.rows", "tabs": [watching]}));
    let row = &rows["tabs"][0];
    assert_eq!((row["viewer"].clone(), row["connected"].clone()), (json!("rd"), json!(false)));
    assert_eq!(row["control"], json!("agent"));
    watching.session = json!({"source": "rd", "state": "streaming", "mode": "control"});
    let row = tabs::row(&watching);
    assert_eq!((row["connected"].clone(), row["control"].clone()), (json!(true), json!("person")));
    // A tab without a session that is not Cloud rd reads as VNC.
    assert_eq!(tabs::row(&live("v", false, true, Value::Null))["viewer"], json!("vnc"));
}
