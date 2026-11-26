//! One Mac Screen tab as the viewer of a device hub session (`MacScreenHubViewer.swift`): it
//! asks the hub for a session, waits for the host's approval and the ticket, hands the
//! ticket's signaling to the tab's stream once, and ends at once on a denial, revocation or
//! end. Tickets admit once, so every new stream is a new request. The app runs the effects:
//! the hub's HTTP calls, the signaling, the stream and the timers, and answers with events.

use super::access::Scope;
use super::reason::{EndReason, HubError, HubReason, Refusal};
use serde::{Deserialize, Serialize};

/// Where the tab's session stands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum Phase {
    /// The Connect card (View / Control).
    Idle,
    /// The request is on its way.
    Requesting {
        scope: Scope,
    },
    /// The host's person decides (permission Ask).
    WaitingForApproval {
        session_id: String,
        scope: Scope,
    },
    /// Approved: the ticket is on its way.
    Approved {
        session_id: String,
        scope: Scope,
    },
    /// The ticket came: the stream runs.
    Streaming {
        session_id: String,
        scope: Scope,
    },
    /// The stream failed; the hub hears `failed` unless its own reason comes first.
    StreamFailed {
        session_id: String,
        scope: Scope,
    },
    /// The host's person said Deny.
    Declined {
        scope: Scope,
    },
    Refused {
        refusal: Refusal,
        requested: Scope,
    },
    /// The hub ended the session at once (`session.revoked`).
    Revoked {
        reason: Option<String>,
    },
    /// The session ended (`session.ended`, or Disconnect here).
    Ended {
        reason: Option<String>,
    },
}

impl Phase {
    /// The session this phase belongs to, if any.
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Phase::WaitingForApproval { session_id, .. }
            | Phase::Approved { session_id, .. }
            | Phase::Streaming { session_id, .. }
            | Phase::StreamFailed { session_id, .. } => Some(session_id),
            _ => None,
        }
    }

    /// Waiting for the host or the ticket (a push can still arrive for it).
    pub fn is_pending(&self) -> bool {
        matches!(
            self,
            Phase::Requesting { .. } | Phase::WaitingForApproval { .. } | Phase::Approved { .. }
        )
    }

    /// The scope a running stream has.
    pub fn streaming_scope(&self) -> Option<Scope> {
        match self {
            Phase::Streaming { scope, .. } => Some(*scope),
            _ => None,
        }
    }
}

/// A `session.ticket`, as far as the viewer reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ticket {
    pub session_id: String,
    /// `viewer` or `host`.
    pub role: String,
    /// The other device's id.
    pub peer_id: String,
    pub scope: Scope,
}

impl Ticket {
    fn is_viewer(&self) -> bool {
        self.role == "viewer"
    }
}

/// A session's state in the hub's answer to `POST /v1/sessions`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HubSessionState {
    Pending,
    Approved,
    Live,
    Ended,
}

/// The hub's session in its answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HubSession {
    pub id: String,
    pub state: Option<HubSessionState>,
    pub scope: Option<Scope>,
}

/// A hub call's answer: the value, or the failure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Answer<T> {
    Ok(T),
    Err(HubError),
}

pub const FAILURE_GRACE_MS: u64 = 3_000;
pub const APPROVAL_TIMEOUT_MS: u64 = 300_000;
pub const TICKET_WAIT_MS: u64 = 8_000;

/// What happened, from the person, the hub or the stream. `hub`: this app is signed in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum ViewerEvent {
    /// Connect, Try Again, a scope on the home page.
    Request {
        scope: Scope,
        hub: bool,
    },
    /// A hub came (sign-in restored or done).
    HubArrived {
        hub: bool,
    },
    /// The request's HTTP answer. `ticket`: the hub already holds this session's ticket.
    RequestReturned {
        answer: Answer<HubSession>,
        scope: Scope,
        #[serde(default)]
        cancelled: bool,
        hub: bool,
        #[serde(default)]
        ticket: Option<Ticket>,
        #[serde(default)]
        signaling_error: Option<HubError>,
    },
    /// Cancel on a waiting card.
    Cancel {
        hub: bool,
    },
    /// Disconnect, or the tab closed.
    Disconnect {
        reason: HubReason,
        #[serde(default)]
        closing_tab: bool,
        hub: bool,
    },
    /// The `/end` of a streaming Disconnect finished.
    DisconnectEnded,
    /// The tab hid past its grace mid-session.
    EndForHiddenTab {
        hub: bool,
    },
    StreamFailed {
        hub_connected: bool,
        hub: bool,
    },
    /// The failure grace passed.
    FailureEndDue {
        session_id: String,
    },
    /// The approval expiry passed.
    ExpiryDue {
        session_id: String,
        hub: bool,
    },
    /// The ticket wait passed.
    TicketWaitDue {
        session_id: String,
    },
    /// `/reattach` answered.
    ReattachAnswered {
        session_id: String,
        answer: Answer<Ticket>,
        hub: bool,
        #[serde(default)]
        signaling_error: Option<HubError>,
    },
    /// A ticket this tab accepts (`accepts`). `signaling_error`: its signaling failed.
    Accept {
        ticket: Ticket,
        hub: bool,
        #[serde(default)]
        signaling_error: Option<HubError>,
    },
    /// A viewer ticket for this tab's host that no request here asked for.
    AcceptPushed {
        ticket: Ticket,
        hub: bool,
        #[serde(default)]
        signaling_error: Option<HubError>,
    },
    /// `session.denied`.
    Denied,
    /// `session.revoked`.
    Revoked {
        reason: Option<String>,
    },
    /// `session.ended`.
    Ended {
        reason: Option<String>,
    },
    /// Signed out, or this Mac was removed.
    HubGone {
        #[serde(default = "signed_out")]
        reason: String,
    },
    HostOnline {
        online: bool,
    },
    StreamStalled {
        stalled: bool,
    },
}

fn signed_out() -> String {
    HubReason::SignedOut.raw().to_owned()
}

/// What the app does, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum ViewerEffect {
    /// `POST /v1/sessions`; answer with `request_returned`.
    SendRequest {
        scope: Scope,
    },
    /// Cancel the request in flight (its answer comes back `cancelled`).
    CancelRequest,
    /// `/end` on the hub, nothing waits on it.
    EndOnHub {
        session_id: String,
        reason: String,
    },
    /// `/end` on the hub, then `disconnect_ended`.
    EndOnHubThenStop {
        session_id: String,
        reason: String,
    },
    StopStream,
    StartStream,
    /// Keep the ticket's signaling for the stream's connect.
    UseSignaling,
    /// Drop any signaling kept for a connect.
    DropSignaling,
    /// A session started streaming.
    OnStreaming,
    ScheduleFailureEnd {
        session_id: String,
        ms: u64,
    },
    CancelFailureEnd,
    ScheduleExpiry {
        session_id: String,
        ms: u64,
    },
    ScheduleTicketWait {
        session_id: String,
        ms: u64,
    },
    /// Cancel the expiry and the ticket wait.
    CancelTimers,
    /// `/reattach`; answer with `reattach_answered`.
    Reattach {
        session_id: String,
    },
    /// Run the Disconnect's follow-up now (a closing tab closes its session).
    Then,
}

type Fx = Vec<ViewerEffect>;

/// The tab's viewer state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Viewer {
    /// The host device (the hub's id).
    pub device_id: String,
    pub phase: Phase,
    /// The scope the person asked for last (Try Again asks for it again).
    pub last_scope: Scope,
    /// The host's own reason this session failed (`failed: <reason>`).
    pub host_failure: Option<String>,
    /// The session that ended here because the share moved.
    pub moved_session: Option<String>,
    /// The tab hid past its grace mid-session: showing it asks again for this scope.
    pub resume_scope: Option<Scope>,
    /// The session this tab's stream failed in.
    pub failed_session: Option<String>,
    /// The stream failed while this Mac's own hub link was down.
    pub failed_while_offline: bool,
    pub host_online: bool,
    pub stalled: bool,
}

impl Viewer {
    pub fn new(device_id: impl Into<String>) -> Self {
        Viewer {
            device_id: device_id.into(),
            phase: Phase::Idle,
            last_scope: Scope::Full,
            host_failure: None,
            moved_session: None,
            resume_scope: None,
            failed_session: None,
            failed_while_offline: false,
            host_online: true,
            stalled: false,
        }
    }

    /// Whether a `session.ticket` names this tab's request: its session, or (before the
    /// request's answer) its host.
    pub fn accepts(&self, ticket: &Ticket) -> bool {
        if !ticket.is_viewer() {
            return false;
        }
        if let Some(id) = self.phase.session_id() {
            return id == ticket.session_id;
        }
        matches!(self.phase, Phase::Requesting { .. }) && ticket.peer_id == self.device_id
    }

    pub fn apply(&mut self, event: ViewerEvent) -> Fx {
        let mut fx = Vec::new();
        match event {
            ViewerEvent::Request { scope, hub } => self.request(scope, hub, &mut fx),
            ViewerEvent::HubArrived { hub } => {
                if let (Phase::Refused { refusal: Refusal::NotSignedIn, requested }, true) =
                    (&self.phase, hub)
                {
                    let requested = *requested;
                    self.request(requested, hub, &mut fx);
                }
            }
            ViewerEvent::RequestReturned {
                answer,
                scope,
                cancelled,
                hub,
                ticket,
                signaling_error,
            } => {
                if cancelled {
                    // Ends are keyed to session ids: a session this tab already runs stays.
                    if let (Answer::Ok(session), true) = (&answer, hub)
                        && self.phase.session_id() != Some(session.id.as_str())
                    {
                        end(&mut fx, &session.id, HubReason::ViewerDisconnected.raw());
                    }
                } else {
                    self.request_answered(answer, scope, hub, ticket, signaling_error, &mut fx);
                }
            }
            ViewerEvent::Cancel { hub } => {
                self.cancel_pending(true, hub, &mut fx);
                self.phase = Phase::Idle;
            }
            ViewerEvent::Disconnect { reason, closing_tab, hub } => {
                self.disconnect(reason, closing_tab, hub, &mut fx);
            }
            ViewerEvent::DisconnectEnded => {
                // A newer session of this tab keeps running.
                if self.phase.session_id().is_none() {
                    fx.push(ViewerEffect::StopStream);
                }
                fx.push(ViewerEffect::Then);
            }
            ViewerEvent::EndForHiddenTab { hub } => {
                if let Some(scope) = self.phase.streaming_scope() {
                    self.disconnect(HubReason::ViewerDisconnected, false, hub, &mut fx);
                    self.resume_scope = Some(scope);
                    self.phase = Phase::Idle;
                }
            }
            ViewerEvent::StreamFailed { hub_connected, hub } => {
                let (Some(id), Some(scope)) =
                    (self.phase.session_id().map(str::to_owned), self.phase.streaming_scope())
                else {
                    return fx;
                };
                self.failed_session = Some(id.clone());
                self.phase = Phase::StreamFailed { session_id: id.clone(), scope };
                self.failed_while_offline = !hub_connected;
                if hub {
                    fx.push(ViewerEffect::ScheduleFailureEnd {
                        session_id: id,
                        ms: FAILURE_GRACE_MS,
                    });
                }
            }
            ViewerEvent::FailureEndDue { session_id } => {
                if self.phase.session_id() == Some(session_id.as_str()) {
                    end(&mut fx, &session_id, HubReason::Failed.raw());
                }
            }
            ViewerEvent::ExpiryDue { session_id, hub } => {
                if matches!(&self.phase, Phase::WaitingForApproval { session_id: s, .. } if *s == session_id)
                {
                    if hub {
                        end(&mut fx, &session_id, "expired");
                    }
                    self.phase = Phase::Ended { reason: Some("expired".into()) };
                }
            }
            ViewerEvent::TicketWaitDue { session_id } => {
                if self.approved_scope(&session_id).is_some() {
                    fx.push(ViewerEffect::Reattach { session_id });
                }
            }
            ViewerEvent::ReattachAnswered { session_id, answer, hub, signaling_error } => {
                let Some(scope) = self.approved_scope(&session_id) else { return fx };
                match answer {
                    Answer::Ok(ticket) if ticket.session_id == session_id && ticket.is_viewer() => {
                        self.accept(ticket, hub, signaling_error, &mut fx);
                    }
                    answer => {
                        if hub {
                            end(&mut fx, &session_id, HubReason::Failed.raw());
                        }
                        // The hub's reason when it gave one, else the failed card.
                        self.phase = match answer {
                            Answer::Err(error @ HubError::Server { .. }) => Phase::Refused {
                                refusal: Refusal::from_error(&error),
                                requested: scope,
                            },
                            _ => Phase::Ended { reason: Some(HubReason::Failed.raw().into()) },
                        };
                    }
                }
            }
            ViewerEvent::Accept { ticket, hub, signaling_error } => {
                self.accept(ticket, hub, signaling_error, &mut fx);
            }
            ViewerEvent::AcceptPushed { ticket, hub, signaling_error } => {
                if !ticket.is_viewer() || ticket.peer_id != self.device_id || self.streams(&ticket)
                {
                    return fx;
                }
                fx.push(ViewerEffect::CancelFailureEnd);
                self.failed_session = None;
                self.failed_while_offline = false;
                self.host_failure = None;
                self.moved_session = None;
                self.resume_scope = None;
                self.cancel_pending(true, hub, &mut fx);
                fx.push(ViewerEffect::StopStream);
                self.accept(ticket, hub, signaling_error, &mut fx);
            }
            ViewerEvent::Denied => {
                let scope = match &self.phase {
                    Phase::WaitingForApproval { scope, .. }
                    | Phase::Approved { scope, .. }
                    | Phase::Requesting { scope } => *scope,
                    _ => self.last_scope,
                };
                cancel_all(&mut fx);
                self.phase = Phase::Declined { scope };
            }
            ViewerEvent::Revoked { reason } => {
                if self.ends_here(reason.as_deref(), &mut fx) {
                    self.phase = Phase::Revoked { reason };
                }
            }
            ViewerEvent::Ended { reason } => {
                if EndReason::parse(reason.as_deref()) == EndReason::Moved
                    && let Some(id) = self.phase.session_id()
                {
                    self.moved_session = Some(id.to_owned());
                }
                if self.ends_here(reason.as_deref(), &mut fx)
                    && !matches!(self.phase, Phase::Revoked { .. })
                {
                    self.phase = Phase::Ended { reason };
                }
            }
            ViewerEvent::HubGone { reason } => {
                if self.phase.is_pending() || self.phase.streaming_scope().is_some() {
                    cancel_all(&mut fx);
                    fx.push(ViewerEffect::StopStream);
                    self.phase = Phase::Ended { reason: Some(reason) };
                }
            }
            ViewerEvent::HostOnline { online } => {
                self.host_online = online;
                self.end_if_host_gone(&mut fx);
            }
            ViewerEvent::StreamStalled { stalled } => {
                self.stalled = stalled;
                self.end_if_host_gone(&mut fx);
            }
        }
        fx
    }

    fn request(&mut self, scope: Scope, hub: bool, fx: &mut Fx) {
        fx.push(ViewerEffect::CancelFailureEnd);
        self.failed_while_offline = false;
        self.host_failure = None;
        self.moved_session = None;
        self.cancel_pending(true, hub, fx);
        fx.push(ViewerEffect::StopStream);
        self.last_scope = scope;
        self.resume_scope = None;
        if !hub {
            self.phase = Phase::Refused { refusal: Refusal::NotSignedIn, requested: scope };
            return;
        }
        self.phase = Phase::Requesting { scope };
        fx.push(ViewerEffect::SendRequest { scope });
    }

    fn request_answered(
        &mut self,
        answer: Answer<HubSession>,
        scope: Scope,
        hub: bool,
        ticket: Option<Ticket>,
        signaling_error: Option<HubError>,
        fx: &mut Fx,
    ) {
        // A ticket may have come before the answer (pushes race the HTTP reply).
        if !matches!(self.phase, Phase::Requesting { .. }) {
            return;
        }
        match answer {
            Answer::Ok(session) => {
                if let Some(ticket) = ticket.filter(|t| hub && t.session_id == session.id) {
                    self.accept(ticket, hub, signaling_error, fx);
                    return;
                }
                match session.state {
                    Some(HubSessionState::Pending) => {
                        fx.push(ViewerEffect::ScheduleExpiry {
                            session_id: session.id.clone(),
                            ms: APPROVAL_TIMEOUT_MS,
                        });
                        self.phase = Phase::WaitingForApproval { session_id: session.id, scope };
                    }
                    Some(HubSessionState::Ended) => self.phase = Phase::Ended { reason: None },
                    _ => {
                        if hub {
                            fx.push(ViewerEffect::ScheduleTicketWait {
                                session_id: session.id.clone(),
                                ms: TICKET_WAIT_MS,
                            });
                        }
                        self.phase = Phase::Approved {
                            session_id: session.id,
                            scope: session.scope.unwrap_or(scope),
                        };
                    }
                }
            }
            Answer::Err(error) => {
                self.phase =
                    Phase::Refused { refusal: Refusal::from_error(&error), requested: scope };
            }
        }
    }

    fn disconnect(&mut self, reason: HubReason, closing_tab: bool, hub: bool, fx: &mut Fx) {
        let id = self.phase.session_id().map(str::to_owned);
        let streaming = self.phase.streaming_scope().is_some();
        self.cancel_pending(true, hub, fx);
        self.phase = if closing_tab {
            Phase::Idle
        } else {
            Phase::Ended { reason: Some(reason.raw().into()) }
        };
        match id.filter(|_| streaming && hub) {
            // The hub hears the reason first, then the stream stops.
            Some(session_id) => {
                fx.push(ViewerEffect::EndOnHubThenStop { session_id, reason: reason.raw().into() });
            }
            None => fx.extend([ViewerEffect::StopStream, ViewerEffect::Then]),
        }
    }

    fn approved_scope(&self, id: &str) -> Option<Scope> {
        match &self.phase {
            Phase::Approved { session_id, scope } if session_id == id => Some(*scope),
            _ => None,
        }
    }

    fn streams(&self, ticket: &Ticket) -> bool {
        matches!(&self.phase, Phase::Streaming { session_id, .. } if *session_id == ticket.session_id)
    }

    fn accept(
        &mut self,
        ticket: Ticket,
        hub: bool,
        signaling_error: Option<HubError>,
        fx: &mut Fx,
    ) {
        // A repeated ticket for the stream already running changes nothing.
        if self.streams(&ticket) {
            return;
        }
        fx.push(ViewerEffect::CancelTimers);
        if !hub {
            return;
        }
        if let Some(error) = signaling_error {
            end(fx, &ticket.session_id, HubReason::Failed.raw());
            self.phase = Phase::Refused {
                refusal: Refusal::Other { reason: Refusal::reason(&error) },
                requested: ticket.scope,
            };
            return;
        }
        self.last_scope = ticket.scope;
        self.phase = Phase::Streaming { session_id: ticket.session_id, scope: ticket.scope };
        fx.extend([
            ViewerEffect::UseSignaling,
            ViewerEffect::OnStreaming,
            ViewerEffect::StartStream,
        ]);
    }

    fn cancel_pending(&mut self, ending: bool, hub: bool, fx: &mut Fx) {
        fx.extend([
            ViewerEffect::CancelRequest,
            ViewerEffect::CancelTimers,
            ViewerEffect::DropSignaling,
        ]);
        if ending
            && hub
            && self.phase.is_pending()
            && let Some(id) = self.phase.session_id()
        {
            end(fx, id, HubReason::ViewerDisconnected.raw());
        }
    }

    /// The shared start of `session.revoked` and `session.ended`: false when the failed card stays.
    fn ends_here(&mut self, reason: Option<&str>, fx: &mut Fx) -> bool {
        fx.push(ViewerEffect::CancelFailureEnd);
        // A hub end that carries the host's reason: the card says it.
        if self.phase.session_id().is_some()
            && let Some(detail) = EndReason::failure_detail(reason).filter(|d| !d.is_empty())
        {
            self.host_failure = Some(detail);
        }
        // The stream failed first and the end only echoes `failed` (or the host's reason).
        let keeps_failed_card = self.failed_session.is_some()
            && self.failed_session.as_deref() == self.phase.session_id()
            && matches!(EndReason::parse(reason), EndReason::Failed | EndReason::Other);
        if keeps_failed_card {
            return false;
        }
        cancel_all(fx);
        fx.push(ViewerEffect::StopStream);
        true
    }

    /// A stalled stream whose host the hub lists offline is over.
    fn end_if_host_gone(&mut self, fx: &mut Fx) {
        if self.host_online || !self.stalled || self.phase.streaming_scope().is_none() {
            return;
        }
        fx.extend([ViewerEffect::CancelFailureEnd, ViewerEffect::StopStream]);
        self.stalled = false;
        self.phase = Phase::Ended { reason: Some("peer_offline".into()) };
    }
}

fn cancel_all(fx: &mut Fx) {
    fx.extend([
        ViewerEffect::CancelRequest,
        ViewerEffect::CancelTimers,
        ViewerEffect::DropSignaling,
    ]);
}

fn end(fx: &mut Fx, id: &str, reason: &str) {
    fx.push(ViewerEffect::EndOnHub { session_id: id.to_owned(), reason: reason.to_owned() });
}

#[cfg(test)]
mod tests {
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
        let fx =
            v.apply(E::Accept { ticket: ticket("s1", "host"), hub: true, signaling_error: None });
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
        assert_eq!(
            v.phase,
            Phase::Refused { refusal: Refusal::NotSignedIn, requested: Scope::View }
        );
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
        assert_eq!(
            v.phase,
            Phase::Refused { refusal: Refusal::HostOffline, requested: Scope::Full }
        );
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
        assert_eq!(
            ends(&v.apply(E::ExpiryDue { session_id: "s1".into(), hub: true })),
            ["s1 expired"]
        );
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
        let fx = v.apply(E::AcceptPushed {
            ticket: ticket("s2", "host"),
            hub: true,
            signaling_error: None,
        });
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
}
