//! This Mac as a Mac Screen host (`MacScreenHubHost.swift`): which `session.ticket` serves,
//! in what order consent answers count, one viewer at a time (the newest), Stop Sharing,
//! Revoke This Device and the menu bar indicator. The app runs the effects: the consent
//! read, the screen host process, the hub's `/end` and the permission write.

use super::Message;
use super::access::Scope;
use super::reason::HubReason;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A host-role `session.ticket`, as far as the rules read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostTicket {
    pub session_id: String,
    pub scope: Scope,
    pub viewer_id: String,
    pub viewer_name: String,
    /// The hub admitted the viewer as the person's own device (`owner_kind: "user"`).
    #[serde(default)]
    pub own_account: bool,
    /// The acpmux daemon's share host serves it (`servedBy: "daemon"`): never this app's.
    #[serde(default)]
    pub served_by_daemon: bool,
}

/// The session this Mac serves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostSession {
    pub id: String,
    pub viewer_id: String,
    pub viewer_name: String,
    pub scope: Scope,
    pub own_account: bool,
    /// The viewer's data channel opened: it sees (and, Full Control, controls) the screen.
    pub connected: bool,
}

/// What happened, in the app or at the hub.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum HostEvent {
    /// A host-role ticket came. `hub`: signed in; `consent_gate`: this Mac's join consent
    /// gates sessions the hub did not admit as the person's own.
    Serve {
        ticket: HostTicket,
        hub: bool,
        consent_gate: bool,
    },
    /// The consent read for one delivery (`arrival`) answered.
    ConsentAnswered {
        ticket: HostTicket,
        arrival: u64,
        allowed: bool,
        hub: bool,
    },
    /// This Mac's consent changed: the scopes it allows now.
    ConsentChanged {
        allows: Vec<Scope>,
        hub: bool,
    },
    /// The screen host could not start (its signaling failed).
    StartFailed {
        session_id: String,
        hub: bool,
    },
    /// `session.revoked` or `session.ended`.
    SessionOver {
        session_id: String,
    },
    ViewerConnected {
        session_id: String,
    },
    ViewerEnded {
        session_id: String,
    },
    SourceFailed {
        session_id: String,
        message: String,
        hub: bool,
    },
    /// The host's serve loop returned (bye, closed, revoked).
    Served {
        session_id: String,
    },
    /// Stop Sharing (`immediately`: quitting).
    Stop {
        #[serde(default = "host_stopped")]
        reason: HubReason,
        #[serde(default)]
        immediately: bool,
        hub: bool,
    },
    /// The `/end` of a Stop finished.
    StopEnded {
        session_id: String,
    },
    /// Revoke This Device.
    Revoke {
        hub: bool,
    },
    /// The permission write of a Revoke failed.
    RevokeFailed {
        hub: bool,
    },
    /// Sharing turned off, signed out, or the hub went away.
    CloseAll,
}

fn host_stopped() -> HubReason {
    HubReason::HostStopped
}

/// What the app does, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum HostEffect {
    /// Read this Mac's consent for the ticket; answer with `consent_answered`.
    ReadConsent { session_id: String, arrival: u64 },
    /// Make the ticket's signaling and serve it (`start_failed` when that fails).
    Start { ticket: HostTicket },
    /// Stop the screen host here (its process disconnects the viewer).
    CloseLocal,
    /// `/end` on the hub, nothing waits on it.
    End { session_id: String, reason: String },
    /// `/end` on the hub, then `stop_ended`.
    EndThenStop { session_id: String, reason: String },
    /// Set the viewer's access to None (`revoke_failed` when the write fails).
    RevokePermission { viewer_id: String },
}

/// The host's state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Host {
    pub session: Option<HostSession>,
    /// Tickets waiting for their consent read, by session id: their delivery's arrival.
    pub awaiting_consent: BTreeMap<String, u64>,
    pub arrivals: u64,
    pub served_arrival: u64,
}

impl Host {
    pub fn apply(&mut self, event: HostEvent) -> Vec<HostEffect> {
        let mut fx = Vec::new();
        match event {
            HostEvent::Serve { ticket, hub, consent_gate } => {
                if !hub || ticket.served_by_daemon {
                    return fx;
                }
                self.arrivals += 1;
                let arrival = self.arrivals;
                // The person's own device serves at once; other tickets wait for consent.
                if !consent_gate || ticket.own_account {
                    self.awaiting_consent.remove(&ticket.session_id);
                    self.served_arrival = arrival;
                    self.start(ticket, &mut fx);
                } else {
                    self.awaiting_consent.insert(ticket.session_id.clone(), arrival);
                    fx.push(HostEffect::ReadConsent { session_id: ticket.session_id, arrival });
                }
            }
            HostEvent::ConsentAnswered { ticket, arrival, allowed, hub } => {
                // Only this delivery's own entry: a newer delivery of the same session answers itself.
                if !hub || self.awaiting_consent.get(&ticket.session_id) != Some(&arrival) {
                    return fx;
                }
                self.awaiting_consent.remove(&ticket.session_id);
                if !allowed {
                    end(&mut fx, &ticket.session_id, HubReason::ConsentRequired.raw());
                } else if arrival <= self.served_arrival {
                    // One viewer at a time, the newest: an older ticket is replaced.
                    end(&mut fx, &ticket.session_id, HubReason::Replaced.raw());
                } else {
                    self.served_arrival = arrival;
                    self.start(ticket, &mut fx);
                }
            }
            HostEvent::ConsentChanged { allows, hub } => {
                if let Some(current) = &self.session
                    && !current.own_account
                    && !allows.contains(&current.scope)
                {
                    self.stop(
                        HubReason::HostStopped,
                        HubReason::HostStopped.raw(),
                        true,
                        hub,
                        &mut fx,
                    );
                }
            }
            HostEvent::StartFailed { session_id, hub } => {
                if self.session.as_ref().is_some_and(|s| s.id == session_id) {
                    self.session = None;
                }
                if hub {
                    end(&mut fx, &session_id, HubReason::Failed.raw());
                }
            }
            HostEvent::SessionOver { session_id } => {
                self.awaiting_consent.remove(&session_id);
                if self.serves(&session_id) {
                    self.close_local(&mut fx);
                }
            }
            HostEvent::ViewerConnected { session_id } => {
                if let Some(s) = self.session.as_mut().filter(|s| s.id == session_id) {
                    s.connected = true;
                }
            }
            HostEvent::ViewerEnded { session_id } => {
                if self.serves(&session_id) {
                    self.close_local(&mut fx);
                }
            }
            HostEvent::SourceFailed { session_id, message, hub } => {
                if self.serves(&session_id) {
                    // The viewer's card says why (`failed: <message>`).
                    let text = HubReason::failure(&message);
                    self.stop(HubReason::Failed, &text, false, hub, &mut fx);
                }
            }
            HostEvent::Served { session_id } => {
                // A connected session outlives its signaling (a dropped hub link).
                if self.session.as_ref().is_some_and(|s| s.id == session_id && !s.connected) {
                    self.close_local(&mut fx);
                }
            }
            HostEvent::Stop { reason, immediately, hub } => {
                self.stop(reason, reason.raw(), immediately, hub, &mut fx);
            }
            HostEvent::StopEnded { session_id } => {
                if self.serves(&session_id) {
                    self.close_local(&mut fx);
                }
            }
            HostEvent::Revoke { hub } => {
                if let (Some(s), true) = (&self.session, hub) {
                    fx.push(HostEffect::RevokePermission { viewer_id: s.viewer_id.clone() });
                }
            }
            HostEvent::RevokeFailed { hub } => {
                self.stop(
                    HubReason::HostStopped,
                    HubReason::HostStopped.raw(),
                    false,
                    hub,
                    &mut fx,
                );
            }
            HostEvent::CloseAll => {
                self.awaiting_consent.clear();
                self.close_local(&mut fx);
            }
        }
        fx
    }

    fn serves(&self, id: &str) -> bool {
        self.session.as_ref().is_some_and(|s| s.id == id)
    }

    fn start(&mut self, ticket: HostTicket, fx: &mut Vec<HostEffect>) {
        if let Some(current) = self.session.as_ref().filter(|s| s.id != ticket.session_id) {
            // One viewer at a time: the newer session wins.
            let id = current.id.clone();
            self.close_local(fx);
            end(fx, &id, HubReason::Replaced.raw());
        }
        self.session = Some(HostSession {
            id: ticket.session_id.clone(),
            viewer_id: ticket.viewer_id.clone(),
            viewer_name: ticket.viewer_name.clone(),
            scope: ticket.scope,
            own_account: ticket.own_account,
            connected: false,
        });
        fx.push(HostEffect::Start { ticket });
    }

    /// Tickets waiting for consent end unserved with `reason`; the session ends on the hub
    /// first, then closes, unless `immediately` (or no hub), which closes at once.
    fn stop(
        &mut self,
        reason: HubReason,
        text: &str,
        immediately: bool,
        hub: bool,
        fx: &mut Vec<HostEffect>,
    ) {
        let waiting = std::mem::take(&mut self.awaiting_consent);
        if hub {
            for id in waiting.keys() {
                end(fx, id, reason.raw());
            }
        }
        let Some(current) = self.session.as_ref().map(|s| s.id.clone()) else { return };
        if immediately || !hub {
            self.close_local(fx);
            if hub {
                end(fx, &current, text);
            }
        } else {
            fx.push(HostEffect::EndThenStop { session_id: current, reason: text.to_owned() });
        }
    }

    fn close_local(&mut self, fx: &mut Vec<HostEffect>) {
        self.session = None;
        fx.push(HostEffect::CloseLocal);
    }

    /// The menu bar item's title while a viewer is connected (its `%@` takes the viewer's name).
    pub fn indicator(&self) -> Option<Message> {
        let s = self.session.as_ref().filter(|s| s.connected)?;
        Some(match s.scope {
            Scope::View => Message::named("macScreen.indicator.viewing", "%@ is viewing this Mac"),
            Scope::Full => {
                Message::named("macScreen.indicator.controlling", "%@ is controlling this Mac")
            }
        })
    }

    /// Why Stop Sharing This Mac and Revoke This Device cannot run: `None` while serving.
    pub fn no_session_reason(&self) -> Option<Message> {
        self.session.is_none().then_some(Message::plain(
            "macScreen.indicator.noSession",
            "No device is viewing or controlling this Mac.",
        ))
    }
}

fn end(fx: &mut Vec<HostEffect>, id: &str, reason: &str) {
    fx.push(HostEffect::End { session_id: id.to_owned(), reason: reason.to_owned() });
}

#[cfg(test)]
mod tests {
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
        let fx = host.apply(HostEvent::ConsentAnswered {
            ticket: t,
            arrival: 1,
            allowed: false,
            hub: true,
        });
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
        let fx = host.apply(HostEvent::ConsentAnswered {
            ticket: t2,
            arrival: 2,
            allowed: true,
            hub: true,
        });
        assert!(matches!(&fx[..], [HostEffect::Start { .. }]));
        let fx = host.apply(HostEvent::ConsentAnswered {
            ticket: t1,
            arrival: 1,
            allowed: true,
            hub: true,
        });
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
            let older = HostEvent::ConsentAnswered {
                ticket: t.clone(),
                arrival: 1,
                allowed: false,
                hub: true,
            };
            let newer = HostEvent::ConsentAnswered {
                ticket: t.clone(),
                arrival: 2,
                allowed: true,
                hub: true,
            };
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
            host.apply(HostEvent::ConsentChanged {
                allows: vec![Scope::View, Scope::Full],
                hub: true
            })
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
        assert!(
            host.apply(HostEvent::Serve { ticket: t, hub: true, consent_gate: false }).is_empty()
        );
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
        assert_eq!(
            host.apply(HostEvent::Served { session_id: "s1".into() }),
            [HostEffect::CloseLocal]
        );
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
}
