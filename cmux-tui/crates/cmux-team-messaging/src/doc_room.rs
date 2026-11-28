//! RFD 0170 phase 3, a shared document's live room: who is viewing it (RFD 0141 presence leases) and
//! who asks for access (RFD 0077's request flow).
//!
//! - **Presence is a lease.** A connection joins with a lease (30 s by default, never longer) and
//!   stays only while it renews. [`DocRoom::expire`] drops every lease past its deadline exactly
//!   once, through a deadline index, so a sweep costs the expired entries and not the room size. A
//!   crash cleans up with no message. Nothing here is a log record.
//! - **Bounded.** At most [`MAX_PEOPLE`] distinct principals view one document and each holds at
//!   most [`MAX_CONNS_PER_PRINCIPAL`] connections (devices).
//! - **Access is checked on every step.** Joining needs a role ([`DocState::role_of`]). Every
//!   update goes through [`DocRoom::apply`], which applies it to the document and in the same step
//!   re-checks every connection: a revoke, a role change, an agent whose owner lost access, or a
//!   space change emits [`RoomEvent::Disconnect`] for each connection that can no longer read. The
//!   transport closes the socket on that event, so revoke cuts a viewer off well inside RFD 0077's
//!   1 s bound: the bound is the transport's write, not a timer here.
//! - **Access requests (RFD 0077 D2).** A signed-in person in the space with no role on the
//!   document may ask, once. At most [`MAX_PENDING_REQUESTS`] are pending per document, one per
//!   account. The owner approves with a role (view unless they pick more) or declines; a declined
//!   account cannot ask again. Bridged authors (`via Slack`) and agents cannot ask: an agent's
//!   access is its owner's.
//!
//! Nothing here does I/O, reads a clock (callers pass `now_ms`) or draws UI, and nothing in the app
//! calls it yet.

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::identity::PrincipalKind;
use crate::model::{DocRole, Principal};
use crate::shared_doc::{Actor, Applied, DocError, DocOp, DocState, DocUpdate, Scope};

/// RFD 0141's default presence lease.
pub const DEFAULT_LEASE_MS: u32 = 30_000;
/// The shortest lease a connection may ask for.
pub const MIN_LEASE_MS: u32 = 1_000;
/// Distinct principals viewing one document at once (RFD 0141's 32 people a chat).
pub const MAX_PEOPLE: usize = 32;
/// Connections one principal may hold on one document (RFD 0077's 4 devices an account).
pub const MAX_CONNS_PER_PRINCIPAL: usize = 4;
/// Pending access requests per document (RFD 0077 D2).
pub const MAX_PENDING_REQUESTS: usize = 16;
/// Declined accounts remembered per document; the oldest falls out past this.
pub const DECLINED_WINDOW: usize = 1_024;

/// Why a connection left on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LeaveReason {
    Closed,
    LeaseExpired,
}

/// Why the room cut a connection off. The transport closes it on this event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DisconnectReason {
    /// The principal's document role was revoked.
    Revoked,
    /// It can no longer read: space grants, space membership, or an agent's owner lost access.
    AccessLost,
}

/// What the room tells the transport and the viewers. One event per change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "event")]
pub enum RoomEvent {
    Joined { principal_id: String, conn_id: String, role: DocRole },
    Left { principal_id: String, conn_id: String, reason: LeaveReason },
    Disconnect { principal_id: String, conn_id: String, reason: DisconnectReason },
    RoleChanged { principal_id: String, role: DocRole },
    AccessRequested { principal_id: String },
    AccessGranted { principal_id: String, role: DocRole },
    AccessDeclined { principal_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoomError {
    /// No role on the document. `can_request` says whether [`DocRoom::request_access`] would take a
    /// request from this principal.
    NoAccess {
        can_request: bool,
    },
    /// [`MAX_PEOPLE`] other principals are already here.
    RoomFull {
        max: usize,
    },
    /// This principal already holds [`MAX_CONNS_PER_PRINCIPAL`] connections.
    TooManyConnections {
        max: usize,
    },
    /// The connection id is held by another principal.
    ConnTaken,
    UnknownConnection,
    /// Agents and bridged authors cannot ask; nor can someone outside the space.
    CannotRequest,
    AlreadyHasAccess,
    AlreadyRequested,
    /// Declined before; the account cannot ask again.
    Declined,
    TooManyRequests {
        max: usize,
    },
    NoSuchRequest,
    Doc(DocError),
}

impl fmt::Display for RoomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for RoomError {}

impl From<DocError> for RoomError {
    fn from(e: DocError) -> Self {
        RoomError::Doc(e)
    }
}

/// One live connection on the document.
#[derive(Debug, Clone)]
struct Conn {
    principal: Principal,
    owner: Option<Principal>,
    role: DocRole,
    lease_ms: u32,
    expires_at: u64,
}

impl Conn {
    fn actor(&self) -> Actor<'_> {
        Actor { principal: &self.principal, owner: self.owner.as_ref() }
    }
}

/// A principal viewing the document, for the room's people list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewer {
    pub principal_id: String,
    pub kind: PrincipalKind,
    pub name: String,
    pub role: DocRole,
    pub connections: usize,
}

/// A pending access request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessRequest {
    pub principal_id: String,
    pub name: String,
    pub requested_at: u64,
}

/// The live room for one shared document.
#[derive(Debug, Clone, Default)]
pub struct DocRoom {
    conns: BTreeMap<String, Conn>,
    by_principal: BTreeMap<String, BTreeSet<String>>,
    deadlines: BTreeSet<(u64, String)>,
    requests: BTreeMap<String, AccessRequest>,
    declined: VecDeque<String>,
    declined_set: HashSet<String>,
}

impl DocRoom {
    pub fn new() -> Self {
        Self::default()
    }

    /// Live connections.
    pub fn connections(&self) -> usize {
        self.conns.len()
    }

    /// Distinct principals here.
    pub fn people(&self) -> usize {
        self.by_principal.len()
    }

    /// Who is viewing, by principal id. Expired leases still listed until the next
    /// [`DocRoom::expire`]; callers sweep first.
    pub fn viewers(&self) -> Vec<Viewer> {
        self.by_principal
            .iter()
            .filter_map(|(pid, conns)| {
                let c = conns.iter().next().and_then(|id| self.conns.get(id))?;
                Some(Viewer {
                    principal_id: pid.clone(),
                    kind: c.principal.kind,
                    name: c.principal.display_name.clone(),
                    role: c.role,
                    connections: conns.len(),
                })
            })
            .collect()
    }

    pub fn pending_requests(&self) -> Vec<&AccessRequest> {
        self.requests.values().collect()
    }

    /// Whether `principal` may file an access request on `doc` now.
    pub fn can_request(&self, doc: &DocState, scope: Scope<'_>, principal: &Principal) -> bool {
        self.request_check(doc, scope, principal).is_ok()
    }

    fn request_check(
        &self,
        doc: &DocState,
        scope: Scope<'_>,
        principal: &Principal,
    ) -> Result<(), RoomError> {
        if principal.kind != PrincipalKind::Person || principal.via.is_some() {
            return Err(RoomError::CannotRequest);
        }
        let me = Actor { principal, owner: None };
        if doc.role_of(scope, me).is_some() || principal.id == doc.owner_id {
            return Err(RoomError::AlreadyHasAccess);
        }
        // Outside the space (or with no read grant) a document role would still read nothing:
        // a link never widens who can read.
        let in_space = crate::shared_doc::role_ceiling(&crate::permission::effective(
            principal,
            None,
            scope.team,
            scope.space,
        ))
        .is_some();
        if !in_space {
            return Err(RoomError::CannotRequest);
        }
        if self.declined_set.contains(&principal.id) {
            return Err(RoomError::Declined);
        }
        if self.requests.contains_key(&principal.id) {
            return Err(RoomError::AlreadyRequested);
        }
        if self.requests.len() >= MAX_PENDING_REQUESTS {
            return Err(RoomError::TooManyRequests { max: MAX_PENDING_REQUESTS });
        }
        Ok(())
    }

    /// Join with connection `conn_id`. `lease_ms` is clamped to
    /// [`MIN_LEASE_MS`]..=[`DEFAULT_LEASE_MS`]. Joining again on a held connection renews it.
    pub fn join(
        &mut self,
        doc: &DocState,
        scope: Scope<'_>,
        actor: Actor<'_>,
        conn_id: &str,
        lease_ms: u32,
        now_ms: u64,
    ) -> Result<RoomEvent, RoomError> {
        let pid = &actor.principal.id;
        let Some(role) = doc.role_of(scope, actor) else {
            let can_request =
                actor.owner.is_none() && self.can_request(doc, scope, actor.principal);
            return Err(RoomError::NoAccess { can_request });
        };
        if let Some(c) = self.conns.get(conn_id) {
            if &c.principal.id != pid {
                return Err(RoomError::ConnTaken);
            }
        } else {
            match self.by_principal.get(pid) {
                Some(set) if set.len() >= MAX_CONNS_PER_PRINCIPAL => {
                    return Err(RoomError::TooManyConnections { max: MAX_CONNS_PER_PRINCIPAL });
                }
                None if self.by_principal.len() >= MAX_PEOPLE => {
                    return Err(RoomError::RoomFull { max: MAX_PEOPLE });
                }
                _ => {}
            }
        }
        let lease_ms = lease_ms.clamp(MIN_LEASE_MS, DEFAULT_LEASE_MS);
        let expires_at = now_ms.saturating_add(u64::from(lease_ms));
        if let Some(old) = self.conns.get(conn_id) {
            self.deadlines.remove(&(old.expires_at, conn_id.to_owned()));
        }
        self.conns.insert(
            conn_id.to_owned(),
            Conn {
                principal: actor.principal.clone(),
                owner: actor.owner.cloned(),
                role,
                lease_ms,
                expires_at,
            },
        );
        self.deadlines.insert((expires_at, conn_id.to_owned()));
        self.by_principal.entry(pid.clone()).or_default().insert(conn_id.to_owned());
        Ok(RoomEvent::Joined { principal_id: pid.clone(), conn_id: conn_id.to_owned(), role })
    }

    /// Renew a connection's lease for another `lease_ms` from `now_ms`.
    pub fn renew(&mut self, conn_id: &str, now_ms: u64) -> Result<(), RoomError> {
        let c = self.conns.get_mut(conn_id).ok_or(RoomError::UnknownConnection)?;
        let key = (c.expires_at, conn_id.to_owned());
        c.expires_at = now_ms.saturating_add(u64::from(c.lease_ms));
        let next = (c.expires_at, conn_id.to_owned());
        self.deadlines.remove(&key);
        self.deadlines.insert(next);
        Ok(())
    }

    /// The connection closed on its own.
    pub fn leave(&mut self, conn_id: &str) -> Option<RoomEvent> {
        let c = self.remove(conn_id)?;
        Some(RoomEvent::Left {
            principal_id: c.principal.id,
            conn_id: conn_id.to_owned(),
            reason: LeaveReason::Closed,
        })
    }

    /// Drop every lease whose deadline is at or before `now_ms`. Each lease expires exactly once.
    pub fn expire(&mut self, now_ms: u64) -> Vec<RoomEvent> {
        let mut out = Vec::new();
        while let Some((at, _)) = self.deadlines.first() {
            if *at > now_ms {
                break;
            }
            let Some((_, conn_id)) = self.deadlines.pop_first() else { break };
            if let Some(c) = self.remove(&conn_id) {
                out.push(RoomEvent::Left {
                    principal_id: c.principal.id,
                    conn_id,
                    reason: LeaveReason::LeaseExpired,
                });
            }
        }
        out
    }

    /// The next lease deadline, for the caller's one timer.
    pub fn next_deadline(&self) -> Option<u64> {
        self.deadlines.first().map(|(at, _)| *at)
    }

    fn remove(&mut self, conn_id: &str) -> Option<Conn> {
        let c = self.conns.remove(conn_id)?;
        self.deadlines.remove(&(c.expires_at, conn_id.to_owned()));
        if let Some(set) = self.by_principal.get_mut(&c.principal.id) {
            set.remove(conn_id);
            if set.is_empty() {
                self.by_principal.remove(&c.principal.id);
            }
        }
        Some(c)
    }

    /// Apply one document update and, in the same step, re-check every connection.
    pub fn apply(
        &mut self,
        doc: &mut DocState,
        scope: Scope<'_>,
        actor: Actor<'_>,
        update: &DocUpdate,
    ) -> Result<(Applied, Vec<RoomEvent>), RoomError> {
        let applied = doc.apply(scope, actor, update)?;
        let mut events = Vec::new();
        if let DocOp::Grant { principal_id, .. } = &update.op
            && self.requests.remove(principal_id).is_some()
            && let Some(role) = doc.doc.roles.get(principal_id).copied()
        {
            events.push(RoomEvent::AccessGranted { principal_id: principal_id.clone(), role });
        }
        let revoked = match &update.op {
            DocOp::Revoke { principal_id } => Some(principal_id.as_str()),
            _ => None,
        };
        events.extend(self.reconcile_inner(doc, scope, revoked));
        Ok((applied, events))
    }

    /// Re-check every connection against the document and the scope now: call after a space,
    /// team or grant change that did not go through [`DocRoom::apply`].
    pub fn reconcile(&mut self, doc: &DocState, scope: Scope<'_>) -> Vec<RoomEvent> {
        self.reconcile_inner(doc, scope, None)
    }

    fn reconcile_inner(
        &mut self,
        doc: &DocState,
        scope: Scope<'_>,
        revoked: Option<&str>,
    ) -> Vec<RoomEvent> {
        let mut out = Vec::new();
        let mut cut = Vec::new();
        let mut changed: BTreeMap<String, DocRole> = BTreeMap::new();
        for (conn_id, c) in &mut self.conns {
            match doc.role_of(scope, c.actor()) {
                None => cut.push(conn_id.clone()),
                Some(role) if role != c.role => {
                    c.role = role;
                    changed.insert(c.principal.id.clone(), role);
                }
                Some(_) => {}
            }
        }
        for conn_id in cut {
            if let Some(c) = self.remove(&conn_id) {
                let direct = revoked == Some(c.principal.id.as_str())
                    || c.owner.as_ref().is_some_and(|o| revoked == Some(o.id.as_str()));
                out.push(RoomEvent::Disconnect {
                    principal_id: c.principal.id,
                    conn_id,
                    reason: if direct {
                        DisconnectReason::Revoked
                    } else {
                        DisconnectReason::AccessLost
                    },
                });
            }
        }
        for (principal_id, role) in changed {
            if self.by_principal.contains_key(&principal_id) {
                out.push(RoomEvent::RoleChanged { principal_id, role });
            }
        }
        out
    }

    /// File an access request (RFD 0077 D2).
    pub fn request_access(
        &mut self,
        doc: &DocState,
        scope: Scope<'_>,
        principal: &Principal,
        now_ms: u64,
    ) -> Result<RoomEvent, RoomError> {
        self.request_check(doc, scope, principal)?;
        self.requests.insert(
            principal.id.clone(),
            AccessRequest {
                principal_id: principal.id.clone(),
                name: principal.display_name.clone(),
                requested_at: now_ms,
            },
        );
        Ok(RoomEvent::AccessRequested { principal_id: principal.id.clone() })
    }

    /// The owner approves a pending request with `role` (view unless they pick more). Goes through
    /// the document's own `Grant`, so only the owner can approve.
    pub fn approve(
        &mut self,
        doc: &mut DocState,
        scope: Scope<'_>,
        owner: Actor<'_>,
        update_id: &str,
        principal_id: &str,
        role: Option<DocRole>,
    ) -> Result<Vec<RoomEvent>, RoomError> {
        if !self.requests.contains_key(principal_id) {
            return Err(RoomError::NoSuchRequest);
        }
        let update = DocUpdate {
            id: update_id.to_owned(),
            actor_id: owner.principal.id.clone(),
            op: DocOp::Grant {
                principal_id: principal_id.to_owned(),
                role: role.unwrap_or(DocRole::View),
            },
        };
        let (_, events) = self.apply(doc, scope, owner, &update)?;
        Ok(events)
    }

    /// The owner declines a pending request; the account cannot ask again.
    pub fn decline(
        &mut self,
        doc: &DocState,
        owner: &Principal,
        principal_id: &str,
    ) -> Result<RoomEvent, RoomError> {
        if owner.id != doc.owner_id {
            return Err(RoomError::Doc(DocError::OwnerOnly));
        }
        if self.requests.remove(principal_id).is_none() {
            return Err(RoomError::NoSuchRequest);
        }
        if self.declined_set.insert(principal_id.to_owned()) {
            self.declined.push_back(principal_id.to_owned());
            if self.declined.len() > DECLINED_WINDOW
                && let Some(old) = self.declined.pop_front()
            {
                self.declined_set.remove(&old);
            }
        }
        Ok(RoomEvent::AccessDeclined { principal_id: principal_id.to_owned() })
    }
}
