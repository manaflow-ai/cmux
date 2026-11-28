use super::*;
use ViewerEvent as E;

fn ticket(id: &str, peer: &str) -> Ticket {
    Ticket {
        session_id: id.into(),
        role: "viewer".into(),
        peer_id: peer.into(),
        scope: Scope::Full,
    }
}

fn session(id: &str, state: Option<HubSessionState>) -> Answer<HubSession> {
    Answer::Ok(HubSession { id: id.into(), state, scope: None })
}

fn returned(answer: Answer<HubSession>) -> ViewerEvent {
    E::RequestReturned {
        answer,
        scope: Scope::Full,
        cancelled: false,
        hub: true,
        ticket: None,
        signaling_error: None,
    }
}

fn ends(fx: &[ViewerEffect]) -> Vec<String> {
    fx.iter()
        .filter_map(|e| match e {
            ViewerEffect::EndOnHub { session_id, reason }
            | ViewerEffect::EndOnHubThenStop { session_id, reason } => {
                Some(format!("{session_id} {reason}"))
            }
            _ => None,
        })
        .collect()
}

fn has(fx: &[ViewerEffect], effect: &ViewerEffect) -> bool {
    fx.contains(effect)
}

fn streaming(id: &str) -> Viewer {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(E::Accept { ticket: ticket(id, "host"), hub: true, signaling_error: None });
    assert_eq!(v.phase.streaming_scope(), Some(Scope::Full));
    v
}

#[test]
fn a_request_waits_for_approval_then_streams_its_ticket() {
    let mut v = Viewer::new("host");
    let fx = v.apply(E::Request { scope: Scope::View, hub: true });
    assert_eq!(fx.last(), Some(&ViewerEffect::SendRequest { scope: Scope::View }));
    assert_eq!(v.phase, Phase::Requesting { scope: Scope::View });
    assert!(v.accepts(&ticket("s1", "host")), "before the answer: the host's ticket");
    assert!(!v.accepts(&ticket("s1", "other")));
    let fx = v.apply(returned(session("s1", Some(HubSessionState::Pending))));
    assert!(has(&fx, &ViewerEffect::ScheduleExpiry { session_id: "s1".into(), ms: 300_000 }));
    assert!(v.phase.is_pending() && v.phase.session_id() == Some("s1"));
    assert!(!v.accepts(&ticket("s2", "host")));
    let fx = v.apply(E::Accept { ticket: ticket("s1", "host"), hub: true, signaling_error: None });
    assert_eq!(
        &fx[1..],
        [ViewerEffect::UseSignaling, ViewerEffect::OnStreaming, ViewerEffect::StartStream]
    );
    // A repeated ticket (`/reattach` answers and pushes it) changes nothing.
    assert!(
        v.apply(E::Accept { ticket: ticket("s1", "host"), hub: true, signaling_error: None })
            .is_empty()
    );
}

#[test]
fn no_hub_refuses_and_a_hub_arriving_asks_again() {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::View, hub: false });
    assert_eq!(v.phase, Phase::Refused { refusal: Refusal::NotSignedIn, requested: Scope::View });
    let fx = v.apply(E::HubArrived { hub: true });
    assert_eq!(fx.last(), Some(&ViewerEffect::SendRequest { scope: Scope::View }));
}

#[test]
fn the_answer_after_a_ticket_or_a_cancel_changes_nothing() {
    let mut v = streaming("s1");
    assert!(v.apply(returned(session("s1", Some(HubSessionState::Approved)))).is_empty());
    // Cancelled: the session it made ends, unless this tab runs it.
    let cancelled = |id: &str| E::RequestReturned {
        answer: session(id, None),
        scope: Scope::Full,
        cancelled: true,
        hub: true,
        ticket: None,
        signaling_error: None,
    };
    assert!(v.apply(cancelled("s1")).is_empty());
    assert_eq!(ends(&v.apply(cancelled("s2"))), ["s2 viewer_disconnected"]);
}

#[test]
fn approved_waits_for_its_ticket_then_reattaches() {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    let fx = v.apply(E::RequestReturned {
        answer: Answer::Ok(HubSession {
            id: "s1".into(),
            state: Some(HubSessionState::Live),
            scope: Some(Scope::View),
        }),
        scope: Scope::Full,
        cancelled: false,
        hub: true,
        ticket: None,
        signaling_error: None,
    });
    assert!(has(&fx, &ViewerEffect::ScheduleTicketWait { session_id: "s1".into(), ms: 8_000 }));
    assert_eq!(v.phase, Phase::Approved { session_id: "s1".into(), scope: Scope::View });
    assert_eq!(
        v.apply(E::TicketWaitDue { session_id: "s1".into() }),
        [ViewerEffect::Reattach { session_id: "s1".into() }]
    );
    // The hub has no ticket either: the failed card.
    let fx = v.apply(E::ReattachAnswered {
        session_id: "s1".into(),
        answer: Answer::Err(HubError::Transport { detail: "offline".into() }),
        hub: true,
        signaling_error: None,
    });
    assert_eq!(ends(&fx), ["s1 failed"]);
    assert_eq!(v.phase, Phase::Ended { reason: Some("failed".into()) });
    // A server reason says why.
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", None)));
    v.apply(E::ReattachAnswered {
        session_id: "s1".into(),
        answer: Answer::Err(HubError::Server {
            status: 409,
            code: "host_offline".into(),
            message: String::new(),
        }),
        hub: true,
        signaling_error: None,
    });
    assert_eq!(v.phase, Phase::Refused { refusal: Refusal::HostOffline, requested: Scope::Full });
    // A matching ticket streams.
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", None)));
    v.apply(E::ReattachAnswered {
        session_id: "s1".into(),
        answer: Answer::Ok(ticket("s1", "host")),
        hub: true,
        signaling_error: None,
    });
    assert!(matches!(v.phase, Phase::Streaming { .. }));
}

#[test]
fn a_waiting_request_expires_and_cancel_ends_it() {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", Some(HubSessionState::Pending))));
    assert!(v.apply(E::ExpiryDue { session_id: "s2".into(), hub: true }).is_empty());
    assert_eq!(ends(&v.apply(E::ExpiryDue { session_id: "s1".into(), hub: true })), ["s1 expired"]);
    assert_eq!(v.phase, Phase::Ended { reason: Some("expired".into()) });
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", Some(HubSessionState::Pending))));
    assert_eq!(ends(&v.apply(E::Cancel { hub: true })), ["s1 viewer_disconnected"]);
    assert_eq!(v.phase, Phase::Idle);
}

#[test]
fn a_refusal_and_a_denial_say_why() {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(Answer::Err(HubError::Server {
        status: 403,
        code: "permission_none".into(),
        message: "no".into(),
    })));
    assert_eq!(
        v.phase,
        Phase::Refused { refusal: Refusal::PermissionNone, requested: Scope::Full }
    );
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", Some(HubSessionState::Pending))));
    v.apply(E::Denied);
    assert_eq!(v.phase, Phase::Declined { scope: Scope::Full });
    v.apply(E::Request { scope: Scope::Full, hub: true });
    v.apply(returned(session("s1", Some(HubSessionState::Ended))));
    assert_eq!(v.phase, Phase::Ended { reason: None });
}

#[test]
fn disconnect_tells_the_hub_first_then_stops() {
    let mut v = streaming("s1");
    let fx = v.apply(E::Disconnect {
        reason: HubReason::ViewerDisconnected,
        closing_tab: false,
        hub: true,
    });
    assert_eq!(
        fx.last(),
        Some(&ViewerEffect::EndOnHubThenStop {
            session_id: "s1".into(),
            reason: "viewer_disconnected".into()
        })
    );
    assert!(!has(&fx, &ViewerEffect::StopStream));
    assert_eq!(v.phase, Phase::Ended { reason: Some("viewer_disconnected".into()) });
    assert_eq!(v.apply(E::DisconnectEnded), [ViewerEffect::StopStream, ViewerEffect::Then]);
    // A closing tab goes idle; nothing streaming stops at once.
    let mut v = Viewer::new("host");
    let fx = v.apply(E::Disconnect {
        reason: HubReason::ViewerDisconnected,
        closing_tab: true,
        hub: true,
    });
    assert_eq!(&fx[fx.len() - 2..], [ViewerEffect::StopStream, ViewerEffect::Then]);
    assert_eq!(v.phase, Phase::Idle);
    // A hidden tab ends and asks again when shown.
    let mut v = streaming("s1");
    v.apply(E::EndForHiddenTab { hub: true });
    assert_eq!((v.phase.clone(), v.resume_scope), (Phase::Idle, Some(Scope::Full)));
}

// MacScreenHubViewerTests: a failed stream keeps its card against its own `failed` echo.
#[test]
fn a_failed_stream_keeps_its_card_until_a_real_cause() {
    let mut v = streaming("s1");
    let fx = v.apply(E::StreamFailed { hub_connected: false, hub: true });
    assert_eq!(fx, [ViewerEffect::ScheduleFailureEnd { session_id: "s1".into(), ms: 3_000 }]);
    assert!(v.failed_while_offline);
    assert_eq!(ends(&v.apply(E::FailureEndDue { session_id: "s1".into() })), ["s1 failed"]);
    v.apply(E::Ended { reason: Some("failed".into()) });
    assert!(matches!(v.phase, Phase::StreamFailed { .. }), "its own echo leaves the card");
    // The host's reason reaches the card, which stays.
    v.apply(E::Revoked { reason: Some("failed: capture denied".into()) });
    assert!(matches!(v.phase, Phase::StreamFailed { .. }));
    assert_eq!(v.host_failure.as_deref(), Some("capture denied"));
    // A real cause wins.
    v.apply(E::Ended { reason: Some("sharing_off".into()) });
    assert_eq!(v.phase, Phase::Ended { reason: Some("sharing_off".into()) });
    // A new request clears the host's reason.
    v.apply(E::Request { scope: Scope::Full, hub: true });
    assert!(v.host_failure.is_none() && !v.failed_while_offline);
}

#[test]
fn revoked_stays_revoked_and_moved_remembers_the_session() {
    let mut v = streaming("s1");
    v.apply(E::Revoked { reason: Some("permission_revoked".into()) });
    v.apply(E::Ended { reason: Some("host_stopped".into()) });
    assert_eq!(v.phase, Phase::Revoked { reason: Some("permission_revoked".into()) });
    let mut v = streaming("s1");
    v.apply(E::Ended { reason: Some("moved".into()) });
    assert_eq!(v.moved_session.as_deref(), Some("s1"));
    // The replacement, pushed here, takes the tab over.
    let fx =
        v.apply(E::AcceptPushed { ticket: ticket("s2", "host"), hub: true, signaling_error: None });
    assert!(has(&fx, &ViewerEffect::StartStream));
    assert!(v.moved_session.is_none());
    assert_eq!(v.phase.session_id(), Some("s2"));
    // Not for another host.
    assert!(
        v.apply(E::AcceptPushed {
            ticket: ticket("s3", "other"),
            hub: true,
            signaling_error: None
        })
        .is_empty()
    );
}

#[test]
fn a_signaling_failure_refuses_with_its_words() {
    let mut v = Viewer::new("host");
    v.apply(E::Request { scope: Scope::Full, hub: true });
    let fx = v.apply(E::Accept {
        ticket: ticket("s1", "host"),
        hub: true,
        signaling_error: Some(HubError::Identity { detail: "no key".into() }),
    });
    assert_eq!(ends(&fx), ["s1 failed"]);
    assert_eq!(
        v.phase,
        Phase::Refused {
            refusal: Refusal::Other { reason: Some("no key".into()) },
            requested: Scope::Full
        }
    );
}

#[test]
fn signed_out_and_an_offline_stalled_host_end_the_stream() {
    let mut v = streaming("s1");
    assert!(v.apply(E::HostOnline { online: false }).is_empty(), "offline alone is not enough");
    let fx = v.apply(E::StreamStalled { stalled: true });
    assert!(has(&fx, &ViewerEffect::StopStream));
    assert_eq!(v.phase, Phase::Ended { reason: Some("peer_offline".into()) });
    assert!(!v.stalled);
    let mut v = streaming("s1");
    v.apply(E::HubGone { reason: signed_out() });
    assert_eq!(v.phase, Phase::Ended { reason: Some("signed_out".into()) });
    assert!(v.apply(E::HubGone { reason: signed_out() }).is_empty(), "an end keeps its card");
}

// MacScreenHubTests.theHubsReasonReachesBothCards (the viewer's card).
#[test]
fn the_hubs_reason_reaches_the_viewers_card() {
    let mut v = streaming("s1");
    v.apply(E::Ended { reason: Some("failed: no helper".into()) });
    assert_eq!(v.host_failure.as_deref(), Some("no helper"));
    assert_eq!(v.phase, Phase::Ended { reason: Some("failed: no helper".into()) });
    // A bare `failed` names no one.
    let mut v = streaming("s1");
    v.apply(E::Ended { reason: Some("failed".into()) });
    assert!(v.host_failure.is_none());
}
