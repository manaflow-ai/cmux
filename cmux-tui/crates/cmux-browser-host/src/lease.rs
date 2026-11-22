//! The automation lease state machine (plans/cmux-next/automation-lease.md).
//!
//! One lease per target (a provider tab). The host owns it; the app only
//! renders the `lease` frames this table returns. Both hosts (this one and
//! the CUA host) replay `schemas/automation-lease/vectors.json`.

use crate::provider::{Lease, LeaseState};
use std::collections::{BTreeMap, BTreeSet};

/// One operation on the table. `session`, `actor` and `origin` come from the
/// connection, never from the caller's request body.
#[derive(Debug, Clone, PartialEq)]
pub enum LeaseOp {
    Acquire {
        target: String,
    },
    Act {
        target: String,
    },
    Observe {
        target: String,
    },
    Release {
        target: String,
    },
    SessionEnd,
    UserInput {
        target: String,
    },
    TakeOver {
        target: String,
    },
    HandBack {
        target: String,
    },
    Stop {
        target: String,
    },
    /// The person allows a stopped principal again (`allow {actor}` in the
    /// shared vectors; the principal is an `on_behalf_of` or an `actor`).
    Allow {
        actor: String,
    },
    /// Host-local, not in the shared vectors: the target is gone (its tab
    /// closed), so its lease ends with no origin check and a null frame.
    TargetGone {
        target: String,
    },
}

/// Who sent an operation.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LeaseCaller {
    pub session: String,
    pub actor: String,
    pub on_behalf_of: Option<String>,
    /// `user | cli | mcp | script | remote`.
    pub origin: String,
    /// The agent's task label (badge text).
    pub label: String,
    /// The caller named no session and the host substituted its default.
    pub implicit_session: bool,
    /// The target's engine: `headless`, `cef`, `webkit`, `desktop`, or empty.
    pub engine: String,
}

impl LeaseCaller {
    /// A caller with an explicit session on an engine's target.
    pub fn new(
        session: impl Into<String>,
        actor: impl Into<String>,
        on_behalf_of: Option<String>,
        origin: impl Into<String>,
        label: impl Into<String>,
        engine: impl Into<String>,
    ) -> LeaseCaller {
        LeaseCaller {
            session: session.into(),
            actor: actor.into(),
            on_behalf_of,
            origin: origin.into(),
            label: label.into(),
            implicit_session: false,
            engine: engine.into(),
        }
    }

    /// The principal a stop applies to: `on_behalf_of` when present, else `actor`.
    pub fn stop_key(&self) -> &str {
        self.on_behalf_of.as_deref().unwrap_or(&self.actor)
    }
}

/// Engines whose targets are the person's own tabs: they refuse the
/// implicit shared session.
const PROVIDER_ENGINES: [&str; 2] = ["cef", "webkit"];

/// A refused operation, by its contract error code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaseError {
    LeaseHeld,
    PausedByUser,
    UserDriving,
    StaleAfterHandBack,
    StoppedByUser,
    SessionRequired,
    NotLeaseHolder,
    NoLease,
    NotPaused,
    UserOriginRequired,
    AgentOriginRequired,
}

impl LeaseError {
    pub fn code(self) -> &'static str {
        match self {
            LeaseError::LeaseHeld => "lease_held",
            LeaseError::PausedByUser => "paused_by_user",
            LeaseError::UserDriving => "user_driving",
            LeaseError::StaleAfterHandBack => "stale_after_hand_back",
            LeaseError::StoppedByUser => "stopped_by_user",
            LeaseError::SessionRequired => "session_required",
            LeaseError::NotLeaseHolder => "not_lease_holder",
            LeaseError::NoLease => "no_lease",
            LeaseError::NotPaused => "not_paused",
            LeaseError::UserOriginRequired => "user_origin_required",
            LeaseError::AgentOriginRequired => "agent_origin_required",
        }
    }
}

/// A target's lease and the state the badge does not show.
#[derive(Debug, Clone, PartialEq)]
pub struct LeaseRecord {
    pub lease: Lease,
    pub needs_fresh_observe: bool,
}

/// A `lease {target, lease?}` frame to send: the rendered lease changed.
#[derive(Debug, Clone, PartialEq)]
pub struct LeaseFrame {
    pub target: String,
    pub lease: Option<Lease>,
}

#[derive(Debug, Default)]
pub struct LeaseTable {
    leases: BTreeMap<String, LeaseRecord>,
    /// Stopped principals (`on_behalf_of`, else `actor`): a new session name
    /// cannot dodge a stop.
    stopped: BTreeSet<String>,
}

impl LeaseTable {
    pub fn get(&self, target: &str) -> Option<&LeaseRecord> {
        self.leases.get(target)
    }

    /// Applies one operation at `now_ms`; on success returns the frames
    /// for every target whose rendered lease changed (target order).
    pub fn apply(
        &mut self,
        op: &LeaseOp,
        caller: &LeaseCaller,
        now_ms: u64,
    ) -> Result<Vec<LeaseFrame>, LeaseError> {
        let user_op = matches!(
            op,
            LeaseOp::TakeOver { .. }
                | LeaseOp::HandBack { .. }
                | LeaseOp::Stop { .. }
                | LeaseOp::Allow { .. }
        );
        if user_op && caller.origin != "user" {
            return Err(LeaseError::UserOriginRequired);
        }
        let agent_op = matches!(op, LeaseOp::Acquire { .. } | LeaseOp::Act { .. });
        if agent_op && caller.origin == "user" {
            return Err(LeaseError::AgentOriginRequired);
        }
        let before: BTreeMap<String, Lease> =
            self.leases.iter().map(|(t, r)| (t.clone(), r.lease.clone())).collect();
        self.mutate(op, caller, now_ms)?;
        let mut frames = Vec::new();
        let targets: BTreeSet<&String> = before.keys().chain(self.leases.keys()).collect();
        for target in targets {
            let after = self.leases.get(target).map(|r| &r.lease);
            if before.get(target) != after {
                frames.push(LeaseFrame { target: target.clone(), lease: after.cloned() });
            }
        }
        Ok(frames)
    }

    fn mutate(
        &mut self,
        op: &LeaseOp,
        caller: &LeaseCaller,
        now_ms: u64,
    ) -> Result<(), LeaseError> {
        match op {
            LeaseOp::Acquire { target } | LeaseOp::Act { target } => {
                if caller.implicit_session && PROVIDER_ENGINES.contains(&caller.engine.as_str()) {
                    return Err(LeaseError::SessionRequired);
                }
                let stopped =
                    |principal: Option<&str>| principal.is_some_and(|p| self.stopped.contains(p));
                if stopped(Some(&caller.actor)) || stopped(caller.on_behalf_of.as_deref()) {
                    return Err(LeaseError::StoppedByUser);
                }
                let Some(record) = self.leases.get(target) else {
                    self.leases.insert(target.clone(), new_record(caller, now_ms));
                    return Ok(());
                };
                if record.lease.session != caller.session {
                    return Err(LeaseError::LeaseHeld);
                }
                if matches!(op, LeaseOp::Act { .. }) {
                    match record.lease.state {
                        LeaseState::Paused => return Err(LeaseError::PausedByUser),
                        LeaseState::UserDriving => return Err(LeaseError::UserDriving),
                        LeaseState::Driving if record.needs_fresh_observe => {
                            return Err(LeaseError::StaleAfterHandBack);
                        }
                        LeaseState::Driving => {}
                    }
                }
            }
            LeaseOp::Observe { target } => {
                if let Some(record) = self.leases.get_mut(target)
                    && record.lease.session == caller.session
                    && record.lease.state == LeaseState::Driving
                {
                    record.needs_fresh_observe = false;
                }
            }
            LeaseOp::Release { target } => match self.leases.get(target) {
                None => {}
                Some(record) if record.lease.session != caller.session => {
                    return Err(LeaseError::NotLeaseHolder);
                }
                Some(_) => {
                    self.leases.remove(target);
                }
            },
            LeaseOp::SessionEnd => self.leases.retain(|_, r| r.lease.session != caller.session),
            LeaseOp::UserInput { target } => {
                if let Some(record) = self.leases.get_mut(target)
                    && record.lease.state == LeaseState::Driving
                {
                    record.lease.state = LeaseState::Paused;
                }
            }
            LeaseOp::TakeOver { target } => {
                let record = self.leases.get_mut(target).ok_or(LeaseError::NoLease)?;
                record.lease.state = LeaseState::UserDriving;
            }
            LeaseOp::HandBack { target } => {
                let record = self.leases.get_mut(target).ok_or(LeaseError::NoLease)?;
                if record.lease.state == LeaseState::Driving {
                    return Err(LeaseError::NotPaused);
                }
                record.lease.state = LeaseState::Driving;
                record.needs_fresh_observe = true;
            }
            LeaseOp::Stop { target } => {
                let record = self.leases.remove(target).ok_or(LeaseError::NoLease)?;
                let lease = record.lease;
                self.stopped.insert(lease.on_behalf_of.unwrap_or(lease.actor));
            }
            LeaseOp::Allow { actor } => {
                self.stopped.remove(actor);
            }
            LeaseOp::TargetGone { target } => {
                self.leases.remove(target);
            }
        }
        Ok(())
    }
}

fn new_record(caller: &LeaseCaller, now_ms: u64) -> LeaseRecord {
    LeaseRecord {
        lease: Lease {
            session: caller.session.clone(),
            actor: caller.actor.clone(),
            on_behalf_of: caller.on_behalf_of.clone(),
            origin: caller.origin.clone(),
            label: caller.label.clone(),
            since_ms: now_ms,
            state: LeaseState::Driving,
        },
        needs_fresh_observe: false,
    }
}

#[cfg(test)]
#[path = "lease_tests.rs"]
mod tests;
