//! The host engine's session table: the single writer of `rd_session`
//! records. Every op re-checks the caller against the session and the policy;
//! Stop from the host user always wins; no media may flow for a session that
//! is not active, and only to its own viewer, which is always a person's
//! interactive client (never an agent).

use std::collections::{BTreeMap, VecDeque};

use crate::policy::{
    Admission, Deny, HostPolicy, Mode, Principal, PrincipalClass, admit, next_expiry_ms,
    still_allowed,
};

/// Session id assigned by the host.
pub type SessionId = u64;

/// Most remembered `start` decisions (oldest are forgotten first).
pub const LEDGER_CAPACITY: usize = 4096;

/// Why a session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndReason {
    StoppedByViewer,
    StoppedByHost,
    ConsentDenied,
    GrantRevoked,
    HostingDisabled,
}

/// Session state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    AwaitingConsent,
    Active,
    Ended(EndReason),
}

/// One `rd_session` record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub id: SessionId,
    /// The interactive client that receives the stream (and, in control
    /// mode, sends input).
    pub viewer: Principal,
    /// Who asked for the session: the viewer, or a mux acting for its user.
    pub opened_by: Principal,
    pub mode: Mode,
    pub state: SessionState,
    pub via_grant: Option<String>,
    /// Consent was waived by an unattended grant.
    pub unattended: bool,
    /// The viewer asked for control and waits for consent; the view stream
    /// keeps running meanwhile.
    pub pending_control: bool,
}

/// Who performs an op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Actor {
    /// A remote principal from the link `hello` (`None`: no valid hello).
    Remote(Option<Principal>),
    /// The person at the host (indicator, consent panel, Settings).
    HostUser,
}

/// An audit event (appended by the engine, mirrored to the team audit chain).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuditEvent {
    Requested { session: SessionId, user: String, mode: Mode },
    Refused { user: Option<String>, reason: Deny },
    Started { session: SessionId, mode: Mode },
    ModeChanged { session: SessionId, mode: Mode },
    Ended { session: SessionId, reason: EndReason },
}

/// A `start` request.
#[derive(Debug, Clone, Copy)]
pub struct StartRequest<'a> {
    /// Idempotency key chosen by the caller.
    pub key: &'a str,
    /// The authenticated caller (`None`: no valid `hello`).
    pub caller: Option<&'a Principal>,
    /// For a mux caller: its user's interactive client that will show the
    /// pane and receive the stream. Ignored for other callers.
    pub for_client: Option<&'a Principal>,
    pub mode: Mode,
    pub console_user: Option<&'a str>,
    pub now_ms: u64,
}

type LedgerKey = (String, String, PrincipalClass, String);

/// The session table and its policy.
#[derive(Debug)]
pub struct SessionTable {
    policy: HostPolicy,
    sessions: BTreeMap<SessionId, Session>,
    /// Idempotency ledger for `start`, keyed by the full caller identity.
    started: BTreeMap<LedgerKey, (Mode, Result<SessionId, Deny>)>,
    started_order: VecDeque<LedgerKey>,
    next_id: SessionId,
    audit: Vec<AuditEvent>,
}

/// The same person's same client: user, install and class all match, and
/// only a person's client (class `User`) ever receives a stream.
fn is_viewer(peer: &Principal, viewer: &Principal) -> bool {
    peer.class == PrincipalClass::User
        && peer.user == viewer.user
        && peer.install == viewer.install
        && peer.class == viewer.class
}

impl SessionTable {
    pub fn new(policy: HostPolicy) -> Self {
        Self {
            policy,
            sessions: BTreeMap::new(),
            started: BTreeMap::new(),
            started_order: VecDeque::new(),
            next_id: 1,
            audit: Vec::new(),
        }
    }

    pub fn policy(&self) -> &HostPolicy {
        &self.policy
    }

    pub fn get(&self, id: SessionId) -> Option<&Session> {
        self.sessions.get(&id)
    }

    /// Takes the audit events recorded since the last call.
    pub fn take_audit(&mut self) -> Vec<AuditEvent> {
        std::mem::take(&mut self.audit)
    }

    /// When the engine must call [`Self::expire`] next (earliest grant expiry).
    pub fn next_expiry_ms(&self, now_ms: u64) -> Option<u64> {
        next_expiry_ms(&self.policy, now_ms)
    }

    /// `rd.session.start`. Replaying the same key from the same caller
    /// returns the first decision; the same key with another mode is refused.
    pub fn start(&mut self, req: StartRequest<'_>) -> Result<SessionId, Deny> {
        let ledger_key = req.caller.map(|p| (p.user.clone(), p.install.clone(), p.class, req.key.to_owned()));
        if let Some(k) = &ledger_key
            && let Some((mode, decided)) = self.started.get(k)
        {
            return if *mode == req.mode { *decided } else { Err(Deny::KeyReused) };
        }
        let decision = self.decide(req);
        if let Err(reason) = decision {
            self.audit.push(AuditEvent::Refused { user: req.caller.map(|p| p.user.clone()), reason });
        }
        if let Some(k) = ledger_key {
            if self.started_order.len() >= LEDGER_CAPACITY
                && let Some(old) = self.started_order.pop_front()
            {
                self.started.remove(&old);
            }
            self.started_order.push_back(k.clone());
            self.started.insert(k, (req.mode, decision));
        }
        decision
    }

    fn decide(&mut self, req: StartRequest<'_>) -> Result<SessionId, Deny> {
        let caller = req.caller.ok_or(Deny::NoPrincipal)?;
        let (needs_consent, via_grant, unattended) =
            match admit(&self.policy, Some(caller), req.mode, req.console_user, req.now_ms) {
                Admission::Allow { needs_consent, via_grant, unattended } => {
                    (needs_consent, via_grant, unattended)
                }
                Admission::Deny(reason) => return Err(reason),
            };
        let viewer = match caller.class {
            PrincipalClass::Mux => {
                let client = req.for_client.ok_or(Deny::NoViewerClient)?;
                if client.class != PrincipalClass::User || !client.interactive || client.user != caller.user {
                    return Err(Deny::NoViewerClient);
                }
                client.clone()
            }
            _ => caller.clone(),
        };
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        self.audit.push(AuditEvent::Requested { session: id, user: viewer.user.clone(), mode: req.mode });
        let state = if needs_consent { SessionState::AwaitingConsent } else { SessionState::Active };
        if state == SessionState::Active {
            self.audit.push(AuditEvent::Started { session: id, mode: req.mode });
        }
        self.sessions.insert(
            id,
            Session {
                id,
                viewer,
                opened_by: caller.clone(),
                mode: req.mode,
                state,
                via_grant,
                unattended,
                pending_control: false,
            },
        );
        Ok(id)
    }

    /// The person at the host answers a consent request. `allow` grants at
    /// most the requested mode (they may allow view when control was asked).
    pub fn consent(&mut self, id: SessionId, allow: Option<Mode>) -> Result<(), Deny> {
        let session = self.sessions.get_mut(&id).ok_or(Deny::NoSession)?;
        if session.state == SessionState::Active && session.pending_control {
            session.pending_control = false;
            if allow == Some(Mode::Control) {
                session.mode = Mode::Control;
                self.audit.push(AuditEvent::ModeChanged { session: id, mode: Mode::Control });
                return Ok(());
            }
            return Err(Deny::ConsentDenied);
        }
        if session.state != SessionState::AwaitingConsent {
            return Err(Deny::NoSession);
        }
        match allow {
            Some(mode) => {
                session.mode = session.mode.min(mode);
                session.state = SessionState::Active;
                self.audit.push(AuditEvent::Started { session: id, mode: session.mode });
                Ok(())
            }
            None => {
                session.state = SessionState::Ended(EndReason::ConsentDenied);
                self.audit.push(AuditEvent::Ended { session: id, reason: EndReason::ConsentDenied });
                Err(Deny::ConsentDenied)
            }
        }
    }

    /// `rd.session.stop`. A remote caller stops only a session it views or
    /// opened; the host user stops any. Stopping an ended session is a no-op.
    pub fn stop(&mut self, id: SessionId, actor: &Actor) -> Result<(), Deny> {
        let session = self.sessions.get(&id).ok_or(Deny::NoSession)?;
        let reason = match actor {
            Actor::HostUser => EndReason::StoppedByHost,
            Actor::Remote(None) => return Err(Deny::NoPrincipal),
            Actor::Remote(Some(p)) if is_viewer(p, &session.viewer) || *p == session.opened_by => {
                EndReason::StoppedByViewer
            }
            Actor::Remote(Some(_)) => return Err(Deny::NotYourSession),
        };
        self.end(id, reason);
        Ok(())
    }

    /// The host indicator's Stop: ends every session at once.
    pub fn stop_all(&mut self) {
        for id in self.live_ids() {
            self.end(id, EndReason::StoppedByHost);
        }
    }

    /// `rd.control.request` / `rd.control.release` by the session's viewer.
    /// Releasing control always succeeds. Requesting control is re-checked
    /// against the policy; when the policy asks for consent, the session stays
    /// active in view mode with `pending_control` set until the person at the
    /// host answers.
    pub fn set_mode(
        &mut self,
        id: SessionId,
        principal: Option<&Principal>,
        mode: Mode,
        console_user: Option<&str>,
        now_ms: u64,
    ) -> Result<SessionState, Deny> {
        let principal = principal.ok_or(Deny::NoPrincipal)?;
        let session = self.sessions.get(&id).ok_or(Deny::NoSession)?;
        if !is_viewer(principal, &session.viewer) {
            return Err(Deny::NotYourSession);
        }
        if session.state != SessionState::Active {
            return Err(Deny::NoSession);
        }
        let upgrade = mode > session.mode;
        // A mux-opened session stays view-only: control is asked by the opener's rules.
        let checked = if session.opened_by.class == PrincipalClass::Mux { &session.opened_by } else { principal };
        let (needs_consent, grant) = if upgrade {
            match admit(&self.policy, Some(checked), mode, console_user, now_ms) {
                Admission::Deny(reason) => return Err(reason),
                Admission::Allow { needs_consent, via_grant, .. } => (needs_consent, via_grant),
            }
        } else {
            (false, None)
        };
        let Some(s) = self.sessions.get_mut(&id) else { return Err(Deny::NoSession) };
        if !upgrade {
            s.mode = mode;
            s.pending_control = false;
        } else if needs_consent {
            s.pending_control = true;
            if grant.is_some() {
                s.via_grant = grant;
            }
            return Ok(SessionState::Active);
        } else {
            s.mode = mode;
            s.pending_control = false;
            if grant.is_some() {
                s.via_grant = grant;
            }
        }
        self.audit.push(AuditEvent::ModeChanged { session: id, mode });
        Ok(SessionState::Active)
    }

    /// Replaces the policy (user origin on the host) and re-checks every live
    /// session against it: a revoked or expired grant, a removed owner, a
    /// forbidden unattended grant or disabled hosting ends the session.
    /// Consent already given stays valid.
    pub fn set_policy(&mut self, policy: HostPolicy, now_ms: u64) {
        self.policy = policy;
        let mut ended = Vec::new();
        for s in self.sessions.values().filter(|s| !matches!(s.state, SessionState::Ended(_))) {
            match still_allowed(&self.policy, &s.opened_by, s.mode, s.unattended, now_ms) {
                Ok(_) => {}
                Err(Deny::HostingDisabled) => ended.push((s.id, EndReason::HostingDisabled)),
                Err(_) => ended.push((s.id, EndReason::GrantRevoked)),
            }
        }
        for (id, reason) in ended {
            self.end(id, reason);
        }
    }

    /// Ends sessions whose grant expired by `now_ms`. The engine calls it from
    /// a one-shot timer at [`Self::next_expiry_ms`]; nothing polls.
    pub fn expire(&mut self, now_ms: u64) {
        let policy = self.policy.clone();
        self.set_policy(policy, now_ms);
    }

    /// May the engine send media of session `id` to `peer` now?
    pub fn may_send_media(&self, id: SessionId, peer: &Principal) -> bool {
        self.sessions.get(&id).is_some_and(|s| s.state == SessionState::Active && is_viewer(peer, &s.viewer))
    }

    /// May `peer` inject input into session `id` now? The engine checks this
    /// for every event it injects, including events released later by the
    /// input applier.
    pub fn may_inject_input(&self, id: SessionId, peer: &Principal) -> bool {
        self.may_send_media(id, peer)
            && self.sessions.get(&id).is_some_and(|s| s.mode == Mode::Control && s.opened_by.class == PrincipalClass::User)
    }

    fn live_ids(&self) -> Vec<SessionId> {
        self.sessions.values().filter(|s| !matches!(s.state, SessionState::Ended(_))).map(|s| s.id).collect()
    }

    fn end(&mut self, id: SessionId, reason: EndReason) {
        if let Some(s) = self.sessions.get_mut(&id)
            && !matches!(s.state, SessionState::Ended(_))
        {
            s.state = SessionState::Ended(reason);
            self.audit.push(AuditEvent::Ended { session: id, reason });
        }
    }
}
