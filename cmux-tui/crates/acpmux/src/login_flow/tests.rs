use super::*;

fn target(harness: &str, host: Option<&str>) -> SessionAuthTarget {
    SessionAuthTarget {
        harness: harness.into(),
        cwd: Some("/work/app".into()),
        host: host.map(str::to_owned),
        route_id: None,
    }
}

fn auth(state: SessionAuthState, source: SessionAuthSource, at: Option<u64>) -> Observation {
    Observation::Auth(SessionAuthResult {
        state,
        source,
        evidence_at: at,
        detail: String::new(),
        harness: "codex".into(),
        host: None,
        route_id: None,
        login: None,
        from_session_id: None,
        credential: None,
        provider: None,
    })
}

#[test]
fn opening_the_login_is_not_a_sign_in() {
    let mut flows = Flows::default();
    let flow = flows.start(target("codex", None), false, 1_000);
    assert_eq!(flow.phase, Phase::Starting);
    let flow = flows.opened(&flow.flow_id, 1_100).unwrap();
    assert_eq!(flow.phase, Phase::Waiting);
    assert_eq!(flow.verified_at, None);
}

#[test]
fn only_a_ready_observed_after_the_start_succeeds() {
    let mut flows = Flows::default();
    let id = flows.start(target("codex", None), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    let (flow, run) = flows.begin_check(&id, 1_200).unwrap();
    assert!(run);
    assert_eq!(flow.phase, Phase::Verifying);
    // Still signed out: back to waiting, nothing failed.
    let signed_out = auth(SessionAuthState::SignedOut, SessionAuthSource::AuthCheck, Some(1_200));
    let flow = flows.finish_check(&id, &signed_out, false, 1_200).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Waiting, Some(reason::NOT_YET)));
    // An older chat's completed turn is not this sign-in.
    flows.begin_check(&id, 1_300);
    let old_turn = auth(SessionAuthState::Ready, SessionAuthSource::Turn, Some(500));
    let flow = flows.finish_check(&id, &old_turn, false, 1_300).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Waiting, Some(reason::STALE_EVIDENCE)));
    // The harness's own check, run now, says ready.
    flows.begin_check(&id, 1_400);
    let ready = auth(SessionAuthState::Ready, SessionAuthSource::AuthCheck, Some(1_400));
    let flow = flows.finish_check(&id, &ready, false, 1_400).unwrap();
    assert_eq!(flow.phase, Phase::Succeeded);
    assert_eq!(flow.verified_at, Some(1_400));
    assert_eq!(flow.observed, Some(SessionAuthState::Ready));
}

#[test]
fn a_login_that_ended_without_a_sign_in_fails_and_is_retryable() {
    let mut flows = Flows::default();
    let t = target("claude", None);
    let id = flows.start(t.clone(), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    flows.begin_check(&id, 1_500);
    let signed_out = auth(SessionAuthState::SignedOut, SessionAuthSource::AuthCheck, Some(1_500));
    let flow = flows.finish_check(&id, &signed_out, true, 1_500).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Failed, Some(reason::NOT_SIGNED_IN)));
    // Ended: nothing moves it again, and a check runs nothing.
    let (flow, run) = flows.begin_check(&id, 1_600).unwrap();
    assert!(!run);
    assert_eq!(flow.phase, Phase::Failed);
    // Retry: a new flow for the same target.
    let again = flows.start(t, false, 1_700);
    assert_ne!(again.flow_id, id);
    assert_eq!(again.phase, Phase::Starting);
}

#[test]
fn a_check_error_is_never_a_sign_in_state() {
    let mut flows = Flows::default();
    let id = flows.start(target("codex", None), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    flows.begin_check(&id, 1_100);
    let flow = flows.finish_check(&id, &Observation::Error, false, 1_100).unwrap();
    assert_eq!(
        (flow.phase, flow.reason, flow.observed),
        (Phase::Waiting, Some(reason::CHECK_FAILED), None)
    );
    flows.begin_check(&id, 1_200);
    let flow = flows.finish_check(&id, &Observation::Error, true, 1_200).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Failed, Some(reason::CHECK_FAILED)));
}

#[test]
fn an_unreachable_machine_waits_rather_than_failing_the_sign_in() {
    let mut flows = Flows::default();
    let id = flows.start(target("codex", Some("devbox")), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    flows.begin_check(&id, 1_100);
    let down = auth(SessionAuthState::PeerUnreachable, SessionAuthSource::PeerLink, Some(900));
    let flow = flows.finish_check(&id, &down, false, 1_100).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Waiting, Some(reason::PEER_UNREACHABLE)));
}

#[test]
fn cancel_open_failure_and_expiry_each_end_the_flow() {
    let mut flows = Flows::default();
    let a = flows.start(target("a", None), false, 0).flow_id;
    assert_eq!(flows.cancel(&a, 1).unwrap().phase, Phase::Cancelled);
    let b = flows.start(target("b", None), false, 0).flow_id;
    let flow = flows.open_failed(&b, 1).unwrap();
    assert_eq!((flow.phase, flow.reason), (Phase::Failed, Some(reason::OPEN_FAILED)));
    let c = flows.start(target("c", None), false, 0).flow_id;
    flows.opened(&c, 1);
    assert_eq!(flows.get(&c, EXPIRY_MS - 1).unwrap().phase, Phase::Waiting);
    assert_eq!(flows.get(&c, EXPIRY_MS).unwrap().phase, Phase::Expired);
    // An expired flow is not revived by a late `opened`.
    assert_eq!(flows.opened(&c, EXPIRY_MS + 1).unwrap().phase, Phase::Expired);
}

#[test]
fn a_cancel_during_a_check_stands() {
    let mut flows = Flows::default();
    let id = flows.start(target("codex", None), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    flows.begin_check(&id, 1_100);
    flows.cancel(&id, 1_150);
    let ready = auth(SessionAuthState::Ready, SessionAuthSource::AuthCheck, Some(1_200));
    assert_eq!(flows.finish_check(&id, &ready, false, 1_200).unwrap().phase, Phase::Cancelled);
}

#[test]
fn reopening_setup_finds_the_live_flow_and_restart_replaces_it() {
    let mut flows = Flows::default();
    let t = target("codex", Some("devbox"));
    let first = flows.start(t.clone(), false, 1_000);
    flows.opened(&first.flow_id, 1_001);
    let again = flows.start(t.clone(), false, 2_000);
    assert_eq!(again.flow_id, first.flow_id);
    assert_eq!(again.phase, Phase::Waiting);
    // Another machine, or another folder, is another flow.
    let elsewhere = flows.start(target("codex", None), false, 2_000);
    assert_ne!(elsewhere.flow_id, first.flow_id);
    let restarted = flows.start(t, true, 3_000);
    assert_ne!(restarted.flow_id, first.flow_id);
    let old = flows.get(&first.flow_id, 3_000).unwrap();
    assert_eq!((old.phase, old.reason), (Phase::Cancelled, Some(reason::SUPERSEDED)));
}

#[test]
fn a_flow_keeps_no_secret_on_the_wire() {
    let mut flows = Flows::default();
    let id = flows.start(target("codex", None), false, 1_000).flow_id;
    flows.opened(&id, 1_001);
    flows.begin_check(&id, 1_100);
    let mut seen = auth(SessionAuthState::SignedOut, SessionAuthSource::AuthCheck, Some(1_100));
    if let Observation::Auth(a) = &mut seen {
        a.detail = "visit https://auth.example/cb?code=SECRET".into();
        a.login = Some(crate::protocol::auth::SessionAuthLogin {
            kind: crate::protocol::auth::SessionAuthLoginKind::Terminal,
            command: Some("codex login --token SECRET".into()),
            host: None,
            route_id: None,
        });
    }
    let flow = flows.finish_check(&id, &seen, false, 1_100).unwrap();
    let wire = serde_json::to_string(&flow).unwrap();
    assert!(!wire.contains("SECRET"), "{wire}");
    assert!(!wire.contains("https://"), "{wire}");
}

#[test]
fn ended_flows_are_pruned_to_a_bound() {
    let mut flows = Flows::default();
    for i in 0..(KEEP_ENDED as u64 * 3) {
        let id = flows.start(target(&format!("h{i}"), None), false, i).flow_id;
        flows.cancel(&id, i);
    }
    assert!(flows.flows.len() <= KEEP_ENDED + 1, "{}", flows.flows.len());
}
