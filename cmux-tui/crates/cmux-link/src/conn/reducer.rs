//! The pure reducer of connection records:
//! `(state, request) -> Result<(state', outcome, events), Reject>`.
//!
//! No I/O happens here. The store commits the new state and the events in
//! one write, and replays a request with a known idempotency key without
//! applying it again.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};

use super::{
    CONN_PREFIX, ConnChange, ConnEvent, ConnKind, ConnOp, ConnPath, ConnRecord, ConnRequest,
    HostKeyState, Observation, Origin, Principal, Reject, Target,
};
use crate::host_key::HostKey;
use crate::ids::is_well_formed;

/// How many applied requests the reducer remembers for replay.
pub const IDEMPOTENCY_WINDOW: usize = 4_096;

/// The state of a connection's path.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnState {
    Disconnected,
    Connecting,
    /// A host key waits for the user in the host-owned sheet.
    Verifying,
    NeedsAuth,
    Connected,
    Unreachable,
}

/// The result of an applied request: the record after the change, or
/// `None` after a revoke.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Outcome {
    pub record: Option<ConnRecord>,
    /// True when this request was a replay of an already applied one.
    #[serde(default)]
    pub replayed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Applied {
    principal: Principal,
    idempotency_key: String,
    op: ConnOp,
    outcome: Outcome,
}

/// Everything the link knows about connections.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkState {
    records: BTreeMap<String, ConnRecord>,
    revoked: BTreeSet<String>,
    applied: VecDeque<Applied>,
}

impl LinkState {
    /// The records of one (user, app), in id order.
    #[must_use]
    pub fn list(&self, principal: &Principal) -> Vec<ConnRecord> {
        self.records.values().filter(|record| &record.principal == principal).cloned().collect()
    }

    /// One record, if it exists and belongs to `principal`.
    #[must_use]
    pub fn get(&self, principal: &Principal, conn: &str) -> Option<&ConnRecord> {
        self.records.get(conn).filter(|record| &record.principal == principal)
    }

    /// Every connection's confirmed SSH host key, for the per-connection
    /// known-hosts files. A key confirmed for one connection is never
    /// trusted for another.
    pub fn confirmed_host_keys(&self) -> impl Iterator<Item = (&str, &HostKey)> {
        self.records.values().filter_map(|record| match &record.host_key {
            HostKeyState::Confirmed { key } | HostKeyState::Changed { confirmed: key, .. } => {
                Some((record.conn.as_str(), key))
            }
            _ => None,
        })
    }

    /// The ids of every SSH connection.
    pub fn ssh_conns(&self) -> impl Iterator<Item = &str> {
        self.records
            .values()
            .filter(|record| record.kind == ConnKind::Ssh)
            .map(|record| record.conn.as_str())
    }

    fn lookup(&self, principal: &Principal, conn: &str) -> Result<&ConnRecord, Reject> {
        if self.revoked.contains(conn) {
            return Err(Reject::ConnRevoked);
        }
        self.get(principal, conn).ok_or(Reject::ConnUnknown)
    }
}

/// Refuses a connect attempt that the record forbids. A changed host key
/// is a hard stop until the user confirms the new key.
pub fn connect_gate(record: &ConnRecord) -> Result<(), Reject> {
    match &record.host_key {
        HostKeyState::Changed { confirmed, offered } => Err(Reject::HostKeyChanged {
            old_fingerprint: confirmed.fingerprint.clone(),
            new_fingerprint: offered.fingerprint.clone(),
        }),
        HostKeyState::Revoked { offered } => {
            Err(Reject::HostKeyRevoked { fingerprint: offered.fingerprint.clone() })
        }
        _ => Ok(()),
    }
}

/// Applies one request.
pub fn reduce(
    state: &LinkState,
    request: &ConnRequest,
) -> Result<(LinkState, Outcome, Vec<ConnEvent>), Reject> {
    if let Some(applied) = state.applied.iter().find(|applied| {
        applied.principal == request.principal && applied.idempotency_key == request.idempotency_key
    }) {
        if applied.op != request.op {
            return Err(Reject::IdempotencyConflict);
        }
        let mut outcome = applied.outcome.clone();
        outcome.replayed = true;
        return Ok((state.clone(), outcome, Vec::new()));
    }
    let mut next = state.clone();
    let (outcome, events) = apply(&mut next, request)?;
    next.applied.push_back(Applied {
        principal: request.principal.clone(),
        idempotency_key: request.idempotency_key.clone(),
        op: request.op.clone(),
        outcome: outcome.clone(),
    });
    while next.applied.len() > IDEMPOTENCY_WINDOW {
        next.applied.pop_front();
    }
    Ok((next, outcome, events))
}

fn apply(
    state: &mut LinkState,
    request: &ConnRequest,
) -> Result<(Outcome, Vec<ConnEvent>), Reject> {
    let principal = &request.principal;
    match &request.op {
        ConnOp::Create { conn, kind, target, credential } => {
            if !is_well_formed(conn, CONN_PREFIX) {
                return Err(Reject::ConnIdInvalid);
            }
            if state.revoked.contains(conn) {
                return Err(Reject::ConnRevoked);
            }
            if state.records.contains_key(conn) {
                return Err(Reject::ConnExists);
            }
            let host_key = match (kind, target) {
                (ConnKind::Local, Target::Local)
                | (
                    ConnKind::CmuxHost | ConnKind::CloudVm | ConnKind::TeamVm,
                    Target::Host { .. },
                ) => HostKeyState::NotApplicable,
                (ConnKind::Ssh, Target::Ssh(ssh)) => {
                    ssh.validate()?;
                    HostKeyState::None
                }
                _ => return Err(Reject::TargetInvalid),
            };
            if let Target::Host { host } = target
                && host.trim().is_empty()
            {
                return Err(Reject::TargetInvalid);
            }
            let record = ConnRecord {
                conn: conn.clone(),
                principal: principal.clone(),
                kind: *kind,
                target: target.clone(),
                credential: credential.clone(),
                host_key,
                state: ConnState::Disconnected,
                path: None,
                revision: 1,
            };
            state.records.insert(conn.clone(), record.clone());
            let event = event(&record, ConnChange::Created);
            Ok((Outcome { record: Some(record), replayed: false }, vec![event]))
        }
        ConnOp::Revoke { conn } => {
            let record = state.lookup(principal, conn)?.clone();
            state.records.remove(conn);
            state.revoked.insert(conn.clone());
            let mut gone = record;
            gone.revision += 1;
            Ok((Outcome { record: None, replayed: false }, vec![event(&gone, ConnChange::Revoked)]))
        }
        ConnOp::Observe { conn, observation } => {
            if request.origin != Origin::Link {
                return Err(Reject::OriginNotLink);
            }
            let mut record = state.lookup(principal, conn)?.clone();
            let changes = observe(&mut record, observation)?;
            commit(state, record, changes)
        }
        ConnOp::ConfirmHostKey { conn, fingerprint } => {
            if request.origin != Origin::User {
                return Err(Reject::OriginNotUser);
            }
            let mut record = state.lookup(principal, conn)?.clone();
            let offered = match &record.host_key {
                HostKeyState::Unknown { offered } | HostKeyState::Changed { offered, .. } => {
                    offered.clone()
                }
                HostKeyState::Revoked { offered } => {
                    return Err(Reject::HostKeyRevoked {
                        fingerprint: offered.fingerprint.clone(),
                    });
                }
                _ => return Err(Reject::HostKeyNotPending),
            };
            if &offered.fingerprint != fingerprint {
                return Err(Reject::HostKeyFingerprintMismatch);
            }
            let mut changes = vec![ConnChange::HostKeyConfirmed {
                key_type: offered.key_type.clone(),
                fingerprint: offered.fingerprint.clone(),
            }];
            record.host_key = HostKeyState::Confirmed { key: offered };
            changes.extend(set_state(&mut record, ConnState::Disconnected, None));
            commit(state, record, changes)
        }
    }
}

fn commit(
    state: &mut LinkState,
    mut record: ConnRecord,
    changes: Vec<ConnChange>,
) -> Result<(Outcome, Vec<ConnEvent>), Reject> {
    if !changes.is_empty() {
        record.revision += 1;
    }
    let events = changes.into_iter().map(|change| event(&record, change)).collect();
    state.records.insert(record.conn.clone(), record.clone());
    Ok((Outcome { record: Some(record), replayed: false }, events))
}

fn event(record: &ConnRecord, change: ConnChange) -> ConnEvent {
    ConnEvent {
        conn: record.conn.clone(),
        principal: record.principal.clone(),
        revision: record.revision,
        change,
    }
}

fn set_state(
    record: &mut ConnRecord,
    state: ConnState,
    path: Option<ConnPath>,
) -> Option<ConnChange> {
    if record.state == state && record.path == path {
        return None;
    }
    record.state = state;
    record.path = path;
    Some(ConnChange::StateChanged { state, path })
}

fn observe(record: &mut ConnRecord, observation: &Observation) -> Result<Vec<ConnChange>, Reject> {
    connect_gate(record)?;
    let ssh = record.kind == ConnKind::Ssh;
    let mut changes = Vec::new();
    match observation {
        Observation::Connecting => {
            changes.extend(set_state(record, ConnState::Connecting, None));
        }
        Observation::Connected { offered, path } => {
            if ssh {
                let Some(offered) = offered else {
                    // Strict checking accepted a key the observer did not
                    // see; the link cannot tell which key it trusts.
                    return Ok(set_state(record, ConnState::Unreachable, None)
                        .into_iter()
                        .collect());
                };
                if let HostKeyState::Confirmed { key } = &record.host_key
                    && key.fingerprint != offered.fingerprint
                {
                    changes.push(changed(key, offered));
                    record.host_key =
                        HostKeyState::Changed { confirmed: key.clone(), offered: offered.clone() };
                    changes.extend(set_state(record, ConnState::Disconnected, None));
                    return Ok(changes);
                }
                if !matches!(record.host_key, HostKeyState::Confirmed { .. }) {
                    // Accepted through the user's own known-hosts file, which
                    // is trusted read-only input.
                    changes.push(ConnChange::HostKeyConfirmed {
                        key_type: offered.key_type.clone(),
                        fingerprint: offered.fingerprint.clone(),
                    });
                    record.host_key = HostKeyState::Confirmed { key: offered.clone() };
                }
            }
            changes.extend(set_state(record, ConnState::Connected, *path));
        }
        Observation::HostKeyRejected { offered, known_elsewhere } => {
            if !ssh {
                return Ok(set_state(record, ConnState::Unreachable, None).into_iter().collect());
            }
            let previous = match &record.host_key {
                HostKeyState::Confirmed { key } => Some(key.clone()),
                _ => known_elsewhere.clone(),
            };
            match previous {
                Some(previous) if previous.fingerprint != offered.fingerprint => {
                    changes.push(changed(&previous, offered));
                    record.host_key =
                        HostKeyState::Changed { confirmed: previous, offered: offered.clone() };
                    changes.extend(set_state(record, ConnState::Disconnected, None));
                }
                Some(_) => {
                    // The confirmed key itself was refused: the store rewrites
                    // the known-hosts file on every commit, so the next
                    // attempt carries it.
                    changes.extend(set_state(record, ConnState::Disconnected, None));
                }
                None => {
                    let repeat = matches!(&record.host_key,
                        HostKeyState::Unknown { offered: pending } if pending == offered);
                    if !repeat {
                        changes.push(ConnChange::HostKeyUnknown {
                            key_type: offered.key_type.clone(),
                            fingerprint: offered.fingerprint.clone(),
                        });
                        record.host_key = HostKeyState::Unknown { offered: offered.clone() };
                    }
                    changes.extend(set_state(record, ConnState::Verifying, None));
                }
            }
        }
        Observation::HostKeyRevoked { offered } => {
            if !ssh {
                return Ok(set_state(record, ConnState::Unreachable, None).into_iter().collect());
            }
            changes.push(ConnChange::HostKeyRevoked {
                key_type: offered.key_type.clone(),
                fingerprint: offered.fingerprint.clone(),
            });
            record.host_key = HostKeyState::Revoked { offered: offered.clone() };
            changes.extend(set_state(record, ConnState::Disconnected, None));
        }
        Observation::AuthFailed => changes.extend(set_state(record, ConnState::NeedsAuth, None)),
        Observation::Unreachable => changes.extend(set_state(record, ConnState::Unreachable, None)),
        Observation::Disconnected => {
            changes.extend(set_state(record, ConnState::Disconnected, None));
        }
    }
    Ok(changes)
}

fn changed(previous: &HostKey, offered: &HostKey) -> ConnChange {
    ConnChange::HostKeyChanged {
        key_type: offered.key_type.clone(),
        old_fingerprint: previous.fingerprint.clone(),
        new_fingerprint: offered.fingerprint.clone(),
    }
}
