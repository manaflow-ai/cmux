//! The host engine's session table: the single writer of `rd_session`
//! records. Every op re-checks the caller against the session and the policy;
//! Stop from the host user always wins; no media may flow for a session that
//! is not active, and only to its own viewer.

use std::collections::BTreeMap;

use crate::policy::{Admission, Deny, HostPolicy, Mode, Principal, admit};

/// Session id assigned by the host.
pub type SessionId = u64;

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
    pub viewer: Principal,
    pub mode: Mode,
    pub state: SessionState,
    pub via_grant: Option<String>,
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

/// The session table and its policy.
#[derive(Debug)]
pub struct SessionTable {
    policy: HostPolicy,
    sessions: BTreeMap<SessionId, Session>,
    /// Idempotency ledger for `start`: key -> decided session.
    started: BTreeMap<(String, String), Result<SessionId, Deny>>,
    next_id: SessionId,
    audit: Vec<AuditEvent>,
}

fn same_viewer(a: &Principal, b: &Principal) -> bool {
    a.user == b.user && a.install == b.install
}

impl SessionTable {
    pub fn new(policy: HostPolicy) -> Self {
        Self { policy, sessions: BTreeMap::new(), started: BTreeMap::new(), next_id: 1, audit: Vec::new() }
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

    /// `rd.session.start`. Replaying the same `(install, key)` returns the
    /// first decision and changes nothing.
    pub fn start(
        &mut self,
        key: &str,
        principal: Option<&Principal>,
        mode: Mode,
        console_user: Option<&str>,
        now_ms: u64,
    ) -> Result<SessionId, Deny> {
        let ledger_key = principal.map(|p| (p.install.clone(), key.to_owned()));
        if let Some(k) = &ledger_key
            && let Some(decided) = self.started.get(k)
        {
            return *decided;
        }
        let decision = match admit(&self.policy, principal, mode, console_user, now_ms) {
            Admission::Deny(reason) => {
                self.audit.push(AuditEvent::Refused { user: principal.map(|p| p.user.clone()), reason });
                Err(reason)
            }
            Admission::Allow { needs_consent, via_grant } => {
                let id = self.next_id;
                self.next_id += 1;
                let viewer = principal.cloned().ok_or(Deny::NoPrincipal)?;
                self.audit.push(AuditEvent::Requested { session: id, user: viewer.user.clone(), mode });
                let state = if needs_consent { SessionState::AwaitingConsent } else { SessionState::Active };
                if state == SessionState::Active {
                    self.audit.push(AuditEvent::Started { session: id, mode });
                }
                self.sessions.insert(id, Session { id, viewer, mode, state, via_grant, pending_control: false });
                Ok(id)
            }
        };
        if let Some(k) = ledger_key {
            self.started.insert(k, decision);
        }
        decision
    }

    /// The person at the host answers a consent request. `allow` grants at
    /// most `mode` (they may allow view when control was asked).
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

    /// `rd.session.stop`. A remote viewer stops only its own session; the host user stops any.
    pub fn stop(&mut self, id: SessionId, actor: &Actor) -> Result<(), Deny> {
        let session = self.sessions.get(&id).ok_or(Deny::NoSession)?;
        if matches!(session.state, SessionState::Ended(_)) {
            return Ok(());
        }
        let reason = match actor {
            Actor::HostUser => EndReason::StoppedByHost,
            Actor::Remote(None) => return Err(Deny::NoPrincipal),
            Actor::Remote(Some(p)) if same_viewer(p, &session.viewer) => EndReason::StoppedByViewer,
            Actor::Remote(Some(_)) => return Err(Deny::NotYourSession),
        };
        self.end(id, reason);
        Ok(())
    }

    /// The host indicator's Stop: ends every session at once.
    pub fn stop_all(&mut self) {
        let ids: Vec<SessionId> = self.live_ids();
        for id in ids {
            self.end(id, EndReason::StoppedByHost);
        }
    }

    /// `rd.control.request` / `rd.control.release` by the session's viewer.
    /// Control is re-checked against the policy. When the policy asks for
    /// consent, the session stays active in its current mode with
    /// `pending_control` set until the person at the host answers.
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
        if !same_viewer(principal, &session.viewer) {
            return Err(Deny::NotYourSession);
        }
        if session.state != SessionState::Active {
            return Err(Deny::NoSession);
        }
        let needs_consent = match admit(&self.policy, Some(principal), mode, console_user, now_ms) {
            Admission::Deny(reason) => return Err(reason),
            Admission::Allow { needs_consent, .. } => needs_consent && mode > session.mode,
        };
        if let Some(s) = self.sessions.get_mut(&id) {
            if needs_consent {
                s.pending_control = true;
            } else {
                s.mode = mode;
                s.pending_control = false;
                self.audit.push(AuditEvent::ModeChanged { session: id, mode });
            }
        }
        Ok(SessionState::Active)
    }

    /// Replaces the policy (user origin on the host). Sessions the new policy
    /// no longer covers end: a revoked grant ends its sessions, disabling
    /// hosting ends all.
    pub fn set_policy(&mut self, policy: HostPolicy, now_ms: u64) {
        self.policy = policy;
        if !self.policy.enabled {
            for id in self.live_ids() {
                self.end(id, EndReason::HostingDisabled);
            }
            return;
        }
        let revoked: Vec<SessionId> = self
            .sessions
            .values()
            .filter(|s| !matches!(s.state, SessionState::Ended(_)))
            .filter(|s| match &s.via_grant {
                Some(grant) => !self.policy.grants.iter().any(|g| {
                    &g.id == grant && g.expires_at_ms.is_none_or(|t| t > now_ms) && g.mode >= s.mode
                }),
                None => false,
            })
            .map(|s| s.id)
            .collect();
        for id in revoked {
            self.end(id, EndReason::GrantRevoked);
        }
    }

    /// Ends sessions whose grant expired by `now_ms` (a one-shot timer at the
    /// earliest expiry calls this; nothing polls).
    pub fn expire(&mut self, now_ms: u64) {
        let policy = self.policy.clone();
        self.set_policy(policy, now_ms);
    }

    /// May the engine send media of session `id` to `peer` now?
    pub fn may_send_media(&self, id: SessionId, peer: &Principal) -> bool {
        self.sessions
            .get(&id)
            .is_some_and(|s| s.state == SessionState::Active && same_viewer(peer, &s.viewer))
    }

    /// May `peer` inject input into session `id` now?
    pub fn may_inject_input(&self, id: SessionId, peer: &Principal) -> bool {
        self.may_send_media(id, peer) && self.sessions.get(&id).is_some_and(|s| s.mode == Mode::Control)
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
