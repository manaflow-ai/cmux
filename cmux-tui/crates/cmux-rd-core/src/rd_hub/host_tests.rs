use super::*;

fn ticket(id: &str, scope: Scope, viewer: &str) -> HostTicket {
    HostTicket {
        session_id: id.into(),
        scope,
        viewer_id: viewer.into(),
        viewer_name: "Studio".into(),
        own_account: false,
        served_by_daemon: false,
    }
}

fn ends(fx: &[HostEffect]) -> Vec<String> {
    fx.iter()
        .filter_map(|e| match e {
            HostEffect::End { session_id, reason }
            | HostEffect::EndThenStop { session_id, reason } => {
                Some(format!("{session_id} {reason}"))
            }
            _ => None,
        })
        .collect()
}

fn serving() -> Host {
    let mut host = Host::default();
    host.apply(HostEvent::Serve {
        ticket: ticket("s1", Scope::Full, "v1"),
        hub: true,
        consent_gate: false,
    });
    host.apply(HostEvent::ViewerConnected { session_id: "s1".into() });
    host
}

// MacScreenHubTests.ownAccountTicketServesOnAJoinedMacWithNoConsentAndNoSheet
#[test]
fn own_account_ticket_serves_at_once() {
    let mut host = Host::default();
    let mut t = ticket("s1", Scope::Full, "v1");
    t.own_account = true;
    let fx = host.apply(HostEvent::Serve { ticket: t.clone(), hub: true, consent_gate: true });
    assert_eq!(fx, [HostEffect::Start { ticket: t }]);
    let s = host.session.clone().unwrap();
    assert!(s.id == "s1" && s.scope == Scope::Full && s.own_account);
    // A consent change does not stop the person's own session.
    assert!(host.apply(HostEvent::ConsentChanged { allows: vec![], hub: true }).is_empty());
    assert_eq!(host.session.as_ref().map(|s| s.id.as_str()), Some("s1"));
    assert_eq!(
        host.apply(HostEvent::SessionOver { session_id: "s1".into() }),
        [HostEffect::CloseLocal]
    );
    assert!(host.session.is_none());
}

// MacScreenHubTests.aTicketTheHubDidNotAdmitAsOwnStillAsks
#[test]
fn a_ticket_the_hub_did_not_admit_as_own_still_asks() {
    let mut host = Host::default();
    let t = ticket("s1", Scope::View, "v1");
    let fx = host.apply(HostEvent::Serve { ticket: t.clone(), hub: true, consent_gate: true });
    assert_eq!(fx, [HostEffect::ReadConsent { session_id: "s1".into(), arrival: 1 }]);
    let fx =
        host.apply(HostEvent::ConsentAnswered { ticket: t, arrival: 1, allowed: false, hub: true });
    assert_eq!(ends(&fx), ["s1 consent_required"]);
    assert!(host.session.is_none());
}

// MacScreenHubTests.anOlderTicketWhoseReadAnswersLaterNeverReplacesANewerOne
#[test]
fn an_older_ticket_never_replaces_a_newer_one() {
    let mut host = Host::default();
    let (t1, t2) = (ticket("s1", Scope::View, "v1"), ticket("s2", Scope::View, "v2"));
    host.apply(HostEvent::Serve { ticket: t1.clone(), hub: true, consent_gate: true });
    host.apply(HostEvent::Serve { ticket: t2.clone(), hub: true, consent_gate: true });
    let fx =
        host.apply(HostEvent::ConsentAnswered { ticket: t2, arrival: 2, allowed: true, hub: true });
    assert!(matches!(&fx[..], [HostEffect::Start { .. }]));
    let fx =
        host.apply(HostEvent::ConsentAnswered { ticket: t1, arrival: 1, allowed: true, hub: true });
    assert_eq!(ends(&fx), ["s1 replaced"]);
    assert_eq!(host.session.as_ref().map(|s| s.id.as_str()), Some("s2"));
}

// MacScreenHubTests.twoDeliveriesOfOneSessionAreDecidedByTheNewer
#[test]
fn two_deliveries_of_one_session_are_decided_by_the_newer() {
    for newer_first in [true, false] {
        let mut host = Host::default();
        let t = ticket("s1", Scope::View, "v1");
        host.apply(HostEvent::Serve { ticket: t.clone(), hub: true, consent_gate: true });
        host.apply(HostEvent::Serve { ticket: t.clone(), hub: true, consent_gate: true });
        // Only the newer delivery's read allows.
        let older =
            HostEvent::ConsentAnswered { ticket: t.clone(), arrival: 1, allowed: false, hub: true };
        let newer =
            HostEvent::ConsentAnswered { ticket: t.clone(), arrival: 2, allowed: true, hub: true };
        let order = if newer_first { [newer, older] } else { [older, newer] };
        let fx: Vec<_> = order.into_iter().flat_map(|e| host.apply(e)).collect();
        assert_eq!(host.session.as_ref().map(|s| s.id.as_str()), Some("s1"));
        assert!(ends(&fx).is_empty(), "the older delivery ends nothing");
        assert_eq!(fx.iter().filter(|e| matches!(e, HostEffect::Start { .. })).count(), 1);
    }
}

// MacScreenHubTests.stopSharingEndsATicketStillWaitingForConsent
#[test]
fn stop_sharing_ends_a_ticket_still_waiting_for_consent() {
    let mut host = serving();
    let t2 = ticket("s2", Scope::View, "v2");
    host.apply(HostEvent::Serve { ticket: t2.clone(), hub: true, consent_gate: true });
    let mut fx = host.apply(HostEvent::Stop {
        reason: HubReason::HostStopped,
        immediately: false,
        hub: true,
    });
    fx.extend(host.apply(HostEvent::StopEnded { session_id: "s1".into() }));
    fx.extend(host.apply(HostEvent::ConsentAnswered {
        ticket: t2,
        arrival: 2,
        allowed: true,
        hub: true,
    }));
    assert!(host.session.is_none(), "the waiting ticket never serves");
    let mut e = ends(&fx);
    e.sort();
    assert_eq!(e, ["s1 host_stopped", "s2 host_stopped"]);
}

// MacScreenHubTests.revokeSetsNoneAndWaitsForTheHubsRevocation
#[test]
fn revoke_sets_none_and_waits_for_the_hubs_revocation() {
    let mut host = serving();
    let fx = host.apply(HostEvent::Revoke { hub: true });
    assert_eq!(fx, [HostEffect::RevokePermission { viewer_id: "v1".into() }]);
    assert!(host.session.is_some(), "still serving until the hub's push");
    host.apply(HostEvent::SessionOver { session_id: "s1".into() });
    assert!(host.session.is_none());
    // A failed write stops the session itself.
    let mut host = serving();
    let fx = host.apply(HostEvent::RevokeFailed { hub: true });
    assert_eq!(ends(&fx), ["s1 host_stopped"]);
}

// MacScreenHubTests.stopSharingEndsOnTheHubThenCloses
#[test]
fn stop_sharing_ends_on_the_hub_then_closes() {
    let mut host = serving();
    let fx = host.apply(HostEvent::Stop {
        reason: HubReason::HostStopped,
        immediately: false,
        hub: true,
    });
    assert_eq!(
        fx,
        [HostEffect::EndThenStop { session_id: "s1".into(), reason: "host_stopped".into() }]
    );
    assert!(host.session.is_some(), "still serving while the hub hears why");
    assert_eq!(
        host.apply(HostEvent::StopEnded { session_id: "s1".into() }),
        [HostEffect::CloseLocal]
    );
    assert!(host.session.is_none());
    // Immediately (quitting) closes first, then tells the hub.
    let mut host = serving();
    let fx = host.apply(HostEvent::Stop {
        reason: HubReason::HostStopped,
        immediately: true,
        hub: true,
    });
    assert_eq!(
        fx,
        [
            HostEffect::CloseLocal,
            HostEffect::End { session_id: "s1".into(), reason: "host_stopped".into() }
        ]
    );
}

#[test]
fn consent_lowered_below_the_scope_stops_at_once() {
    let mut host = Host::default();
    host.apply(HostEvent::Serve {
        ticket: ticket("s1", Scope::Full, "v1"),
        hub: true,
        consent_gate: false,
    });
    assert!(
        host.apply(HostEvent::ConsentChanged { allows: vec![Scope::View, Scope::Full], hub: true })
            .is_empty()
    );
    let fx = host.apply(HostEvent::ConsentChanged { allows: vec![Scope::View], hub: true });
    assert_eq!(fx[0], HostEffect::CloseLocal);
    assert_eq!(ends(&fx), ["s1 host_stopped"]);
}

#[test]
fn a_newer_ticket_replaces_the_session_and_failures_say_why() {
    let mut host = serving();
    let fx = host.apply(HostEvent::Serve {
        ticket: ticket("s2", Scope::View, "v2"),
        hub: true,
        consent_gate: false,
    });
    assert_eq!(fx[0], HostEffect::CloseLocal);
    assert_eq!(ends(&fx), ["s1 replaced"]);
    assert_eq!(host.session.as_ref().map(|s| s.id.as_str()), Some("s2"));
    // The source failed: the viewer reads the host's reason.
    let fx = host.apply(HostEvent::SourceFailed {
        session_id: "s2".into(),
        message: "capture\ndenied".into(),
        hub: true,
    });
    assert_eq!(ends(&fx), ["s2 failed: capture denied"]);
    // A daemon-served ticket is never this app's.
    let mut host = Host::default();
    let mut t = ticket("d1", Scope::View, "v1");
    t.served_by_daemon = true;
    assert!(host.apply(HostEvent::Serve { ticket: t, hub: true, consent_gate: false }).is_empty());
    assert_eq!(host.arrivals, 0);
}

#[test]
fn a_connected_session_outlives_its_signaling() {
    let mut host = serving();
    assert!(host.apply(HostEvent::Served { session_id: "s1".into() }).is_empty());
    let mut host = Host::default();
    host.apply(HostEvent::Serve {
        ticket: ticket("s1", Scope::View, "v1"),
        hub: true,
        consent_gate: false,
    });
    assert_eq!(host.apply(HostEvent::Served { session_id: "s1".into() }), [HostEffect::CloseLocal]);
    let fx = host.apply(HostEvent::StartFailed { session_id: "s9".into(), hub: true });
    assert_eq!(ends(&fx), ["s9 failed"]);
}

#[test]
fn the_indicator_names_the_viewer() {
    let mut host = Host::default();
    assert!(host.indicator().is_none() && host.no_session_reason().is_some());
    host.apply(HostEvent::Serve {
        ticket: ticket("s1", Scope::View, "v1"),
        hub: true,
        consent_gate: false,
    });
    assert!(host.indicator().is_none(), "no viewer connected yet");
    assert!(host.no_session_reason().is_none());
    host.apply(HostEvent::ViewerConnected { session_id: "s1".into() });
    assert_eq!(host.indicator().unwrap().english("Studio"), "Studio is viewing this Mac");
    assert_eq!(serving().indicator().unwrap().key, "macScreen.indicator.controlling");
}
