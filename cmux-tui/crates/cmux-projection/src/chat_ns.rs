//! A chat's namespace authority (RFD 0007, "Projection as the view layer of the fleet
//! filesystem"): the one place that holds, for every path of one chat's shared namespace, its
//! current version and its write lease. Bytes never pass through it; members (the agent VM, its
//! work VMs, collaborators) send it a path's new version at close and ask for it at open.
//!
//! This is the pure core: every call takes the time as `now_ms` from the caller's clock, so the
//! lease rules are tested on an injected clock. The agent VM's daemon hosts one per chat
//! (`cmux_tui_core::projection_ns`).
//!
//! - **Close-to-open.** [`Authority::close`] records the path's new [`Version`] and names the
//!   other members that opened the path, whose cached pages must go
//!   ([`Authority::take_invalidations`]). [`Authority::open`] answers the current version in one
//!   call and whether the member's cached one is stale.
//! - **Leases**, one per path per writer, held by `(member, actor)` ([`Writer`]):
//!   - acquire is implicit on the first mutating call ([`Authority::acquire`]);
//!   - any call from a member renews its leases, and [`Authority::heartbeat`] (every
//!     [`RENEW_EVERY_MS`]) renews them all; a lease not renewed for [`LEASE_TTL_MS`] expires;
//!   - it is released at the holder's last close, after that close's version is recorded;
//!   - a non-owner asking for a held path waits up to [`CONTEND_MS`] ([`Acquire::Wait`]), then
//!     gets a private copy ([`Acquire::Private`]) whose close publishes `NAME.cmux-sync-conflict`
//!     instead of `NAME`. Never `EBUSY`, never a dropped write;
//!   - two members of the same actor hand the lease over at once;
//!   - an owner never waits: it steals a collaborator's lease, and the collaborator's closes in
//!     the next [`STEAL_FLUSH_MS`] still publish if the owner has not published since; later
//!     ones, and every close after an expiry, are conflict copies;
//!   - each conflict copy raises exactly one [`ConflictEvent`], the fleet filesystem's popover 2
//!     ("A sync-back conflict": the path, both writers, keep mine, keep theirs, open both),
//!     pending until [`Authority::resolve`].
//! - **Moving.** The authority serializes whole, so it moves with the session inside the RFD 0138
//!   fence; [`Authority::moved`] re-times it on the new machine's clock.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

/// How often a member renews all of its leases when it makes no other call.
pub const RENEW_EVERY_MS: u64 = 10_000;
/// A lease not renewed for this long is lost.
pub const LEASE_TTL_MS: u64 = 30_000;
/// How long a non-owner waits for a held path before it writes a private copy (RFD 0030's
/// freeze bound).
pub const CONTEND_MS: u64 = 5_000;
/// How long a collaborator whose lease the owner stole may still publish what it had closed.
pub const STEAL_FLUSH_MS: u64 = 2_000;
/// What a conflict copy's name ends in.
pub const CONFLICT_SUFFIX: &str = ".cmux-sync-conflict";

/// Who writes: a machine in the chat (`member`) and the agent or person on it (`actor`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Writer {
    pub member: String,
    pub actor: String,
}

/// What a close sends: the file's size, mtime, mode and content chunk ids.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Meta {
    pub size: u64,
    pub mtime_ns: i64,
    pub mode: u32,
    #[serde(default)]
    pub chunks: Vec<String>,
}

/// A path's version. `seq` 0 is a path no close has recorded (the base revision's bytes).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Version {
    pub seq: u64,
    pub meta: Meta,
    pub by: Option<Writer>,
}

/// Why a write became a conflict copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConflictReason {
    /// The path stayed held by another writer past [`CONTEND_MS`].
    Contended,
    /// The writer's lease expired (crash, partition) before it closed.
    Expired,
    /// The owner took the lease.
    Stolen,
}

/// What a person may do with a conflict (popover 2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Choice {
    KeepMine,
    KeepTheirs,
    OpenBoth,
}

/// The kind every [`ConflictEvent`] carries: the fleet filesystem's popover 2.
pub const CONFLICT_KIND: &str = "sync_conflict";

/// One conflict copy, as the app's popover 2 and `cmux fs stranded --json` show it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConflictEvent {
    pub id: u64,
    /// Always [`CONFLICT_KIND`].
    pub kind: String,
    pub chat: String,
    pub path: String,
    /// Where the losing write was published.
    pub conflict_path: String,
    /// The writer whose bytes are in the conflict copy.
    pub mine: Writer,
    /// The writer whose bytes are at `path`, when known.
    pub theirs: Option<Writer>,
    pub reason: ConflictReason,
    pub at_ms: u64,
    pub choices: Vec<Choice>,
}

/// The answer to [`Authority::acquire`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "acquire", rename_all = "snake_case")]
pub enum Acquire {
    /// The writer holds the lease; its close publishes at the path.
    Granted { token: u64, stole_from: Option<Writer> },
    /// Held by someone else: ask again at `retry_at_ms` (or sooner, if it may free).
    Wait { retry_at_ms: u64, holder: Writer },
    /// Write a private copy; its close publishes a conflict copy.
    Private { token: u64, reason: ConflictReason, theirs: Writer },
}

/// The answer to [`Authority::close`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Closed {
    /// Where the bytes were published: the path, or its conflict copy.
    pub path: String,
    pub version: Version,
    /// The other members whose cached pages of `path` must go.
    pub invalidate: Vec<String>,
    /// Whether the writer's lease on the path ended with this close.
    pub released: bool,
    /// Set when the write became a conflict copy (the first close of a grant raises it; later
    /// closes of the same grant update the same copy and raise none).
    pub conflict: Option<ConflictEvent>,
}

/// The answer to [`Authority::open`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Opened {
    pub version: Version,
    /// The member's cached copy is of another version: drop its pages.
    pub stale: bool,
}

/// A call the authority refuses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NsError {
    /// No open grant has this token (closed already, or from before a restart).
    UnknownToken(u64),
    /// No pending conflict has this id.
    UnknownEvent(u64),
}

impl std::fmt::Display for NsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownToken(token) => write!(f, "no open write with token {token}"),
            Self::UnknownEvent(id) => write!(f, "no pending conflict {id}"),
        }
    }
}

impl std::error::Error for NsError {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Lease {
    token: u64,
    holder: Writer,
    renewed_ms: u64,
}

/// How a lease grant lost its lease.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
enum Lost {
    Expired,
    /// Stolen at `seq`; closes until `until_ms` still publish while the path stays at `seq`.
    Stolen {
        until_ms: u64,
        seq: u64,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
enum Kind {
    Lease { lost: Option<Lost>, handed: bool },
    Private { reason: ConflictReason },
}

/// An open write: a lease, or a private copy.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Grant {
    path: String,
    writer: Writer,
    kind: Kind,
    opens: u32,
    /// Who held or won the path when this grant lost it.
    theirs: Option<Writer>,
    /// The conflict this grant's closes publish into, once it raised one.
    conflict: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct PathState {
    version: Version,
    lease: Option<Lease>,
    /// Non-owners waiting on the lease, with when each first asked.
    contenders: Vec<(Writer, u64)>,
    /// Members that opened this path (their pages may be cached).
    cached_by: BTreeSet<String>,
}

/// One chat's namespace authority (module docs).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Authority {
    chat: String,
    /// The actors that always win: the chat's person and the chat's own agent.
    owners: BTreeSet<String>,
    paths: HashMap<String, PathState>,
    grants: HashMap<u64, Grant>,
    /// Each member's leased paths, for renewals.
    held: HashMap<String, BTreeSet<String>>,
    invalidations: HashMap<String, BTreeSet<String>>,
    /// Conflicts not yet resolved, by id.
    events: BTreeMap<u64, ConflictEvent>,
    next_token: u64,
    next_seq: u64,
    next_event: u64,
}

impl Authority {
    /// The authority of `chat`, whose `owners` (actors) always win a lease.
    #[must_use]
    pub fn new(chat: impl Into<String>, owners: impl IntoIterator<Item = String>) -> Self {
        Self {
            chat: chat.into(),
            owners: owners.into_iter().collect(),
            paths: HashMap::new(),
            grants: HashMap::new(),
            held: HashMap::new(),
            invalidations: HashMap::new(),
            events: BTreeMap::new(),
            next_token: 1,
            next_seq: 1,
            next_event: 1,
        }
    }

    #[must_use]
    pub fn chat(&self) -> &str {
        &self.chat
    }

    /// Adds an owner actor (the chat's person or agent, as the chat names them).
    pub fn add_owner(&mut self, actor: impl Into<String>) {
        self.owners.insert(actor.into());
    }

    #[must_use]
    pub fn is_owner(&self, actor: &str) -> bool {
        self.owners.contains(actor)
    }

    /// The current version of `path` on `member`, and whether `cached_seq` (the version its
    /// pages are of, if any) is stale. Reads never take a lease.
    pub fn open(
        &mut self,
        member: &str,
        path: &str,
        cached_seq: Option<u64>,
        now_ms: u64,
    ) -> Opened {
        self.renew_member(member, now_ms);
        self.sweep(path, now_ms);
        let state = self.paths.entry(path.to_owned()).or_default();
        state.cached_by.insert(member.to_owned());
        let version = state.version.clone();
        if let Some(pending) = self.invalidations.get_mut(member) {
            pending.remove(path);
        }
        let stale = cached_seq.is_some_and(|seq| seq != version.seq);
        Opened { version, stale }
    }

    /// The lease for a mutating call on `path` by `writer` (module docs).
    pub fn acquire(&mut self, writer: &Writer, path: &str, now_ms: u64) -> Acquire {
        self.renew_member(&writer.member, now_ms);
        self.sweep(path, now_ms);
        let owner = self.is_owner(&writer.actor);
        let holder_owner = self
            .paths
            .get(path)
            .and_then(|state| state.lease.as_ref())
            .is_some_and(|lease| self.is_owner(&lease.holder.actor));
        let state = self.paths.entry(path.to_owned()).or_default();
        let Some(lease) = state.lease.clone() else {
            state.contenders.retain(|(waiting, _)| waiting != writer);
            let token = self.grant_lease(writer, path, now_ms);
            return Acquire::Granted { token, stole_from: None };
        };
        if lease.holder == *writer {
            if let Some(grant) = self.grants.get_mut(&lease.token) {
                grant.opens += 1;
            }
            return Acquire::Granted { token: lease.token, stole_from: None };
        }
        if lease.holder.actor == writer.actor {
            // One actor's members run its tool calls one at a time: hand over, and the old
            // member's close (already sent, or in flight) still publishes.
            if let Some(Grant { kind: Kind::Lease { handed, .. }, .. }) =
                self.grants.get_mut(&lease.token)
            {
                *handed = true;
            }
            self.unhold(&lease.holder.member, path);
            let token = self.grant_lease(writer, path, now_ms);
            return Acquire::Granted { token, stole_from: None };
        }
        if owner && !holder_owner {
            let seq = state.version.seq;
            if let Some(grant) = self.grants.get_mut(&lease.token) {
                grant.kind = Kind::Lease {
                    lost: Some(Lost::Stolen { until_ms: now_ms + STEAL_FLUSH_MS, seq }),
                    handed: false,
                };
                grant.theirs = Some(writer.clone());
            }
            self.unhold(&lease.holder.member, path);
            let token = self.grant_lease(writer, path, now_ms);
            return Acquire::Granted { token, stole_from: Some(lease.holder) };
        }
        let first = match state.contenders.iter().find(|(waiting, _)| waiting == writer) {
            Some((_, first)) => *first,
            None => {
                state.contenders.push((writer.clone(), now_ms));
                now_ms
            }
        };
        if now_ms < first + CONTEND_MS {
            return Acquire::Wait { retry_at_ms: first + CONTEND_MS, holder: lease.holder };
        }
        state.contenders.retain(|(waiting, _)| waiting != writer);
        let token = self.mint_token();
        self.grants.insert(
            token,
            Grant {
                path: path.to_owned(),
                writer: writer.clone(),
                kind: Kind::Private { reason: ConflictReason::Contended },
                opens: 1,
                theirs: Some(lease.holder.clone()),
                conflict: None,
            },
        );
        Acquire::Private { token, reason: ConflictReason::Contended, theirs: lease.holder }
    }

    /// A close of the write `token` with the file's new `meta`: publishes it at the path, or as
    /// its conflict copy (module docs).
    ///
    /// # Errors
    /// [`NsError::UnknownToken`] when no open write has `token`.
    pub fn close(&mut self, token: u64, meta: Meta, now_ms: u64) -> Result<Closed, NsError> {
        let path = self.grants.get(&token).ok_or(NsError::UnknownToken(token))?.path.clone();
        let member = self.grants[&token].writer.member.clone();
        self.renew_member(&member, now_ms);
        self.sweep(&path, now_ms);
        let grant = self.grants.get_mut(&token).ok_or(NsError::UnknownToken(token))?;
        grant.opens = grant.opens.saturating_sub(1);
        let last = grant.opens == 0;
        let grant = grant.clone();
        if last {
            self.grants.remove(&token);
        }
        let state = self.paths.entry(path.clone()).or_default();
        let holds = state.lease.as_ref().is_some_and(|lease| lease.token == token);
        let reason = match grant.kind {
            Kind::Private { reason } => Some(reason),
            Kind::Lease { handed: true, .. } => None,
            Kind::Lease { lost: None, .. } => (!holds).then_some(ConflictReason::Expired),
            Kind::Lease { lost: Some(Lost::Expired), .. } => Some(ConflictReason::Expired),
            Kind::Lease { lost: Some(Lost::Stolen { until_ms, seq }), .. } => {
                (now_ms > until_ms || state.version.seq != seq).then_some(ConflictReason::Stolen)
            }
        };
        let Some(reason) = reason else {
            let released = holds && last;
            if released {
                state.lease = None;
                self.unhold(&member, &path);
            }
            let (version, invalidate) = self.publish(&path, meta, &grant.writer);
            return Ok(Closed { path, version, invalidate, released, conflict: None });
        };
        let theirs = grant
            .theirs
            .clone()
            .or_else(|| state.lease.as_ref().map(|lease| lease.holder.clone()))
            .or_else(|| state.version.by.clone());
        let (conflict_path, conflict) = match grant.conflict.and_then(|id| self.events.get(&id)) {
            Some(event) => (event.conflict_path.clone(), None),
            None => {
                let conflict_path = self.free_conflict_name(&path);
                let event = ConflictEvent {
                    id: self.next_event,
                    kind: CONFLICT_KIND.to_owned(),
                    chat: self.chat.clone(),
                    path: path.clone(),
                    conflict_path: conflict_path.clone(),
                    mine: grant.writer.clone(),
                    theirs,
                    reason,
                    at_ms: now_ms,
                    choices: vec![Choice::KeepMine, Choice::KeepTheirs, Choice::OpenBoth],
                };
                self.next_event += 1;
                self.events.insert(event.id, event.clone());
                if let Some(open) = self.grants.get_mut(&token) {
                    open.conflict = Some(event.id);
                }
                (conflict_path, Some(event))
            }
        };
        let (version, invalidate) = self.publish(&conflict_path, meta, &grant.writer);
        Ok(Closed { path: conflict_path, version, invalidate, released: false, conflict })
    }

    /// Renews every lease `member` holds; returns how many.
    pub fn heartbeat(&mut self, member: &str, now_ms: u64) -> usize {
        self.renew_member(member, now_ms)
    }

    /// The paths whose cached pages `member` must drop since it last asked.
    pub fn take_invalidations(&mut self, member: &str) -> Vec<String> {
        self.invalidations
            .remove(member)
            .map(|paths| paths.into_iter().collect())
            .unwrap_or_default()
    }

    /// The conflicts not yet resolved, oldest first.
    #[must_use]
    pub fn pending(&self) -> Vec<ConflictEvent> {
        self.events.values().cloned().collect()
    }

    /// The person chose `choice` for conflict `id`: it is no longer pending. Moving the bytes
    /// (keep mine: the copy over the path) is an ordinary leased write by the app.
    ///
    /// # Errors
    /// [`NsError::UnknownEvent`] when no pending conflict has `id`.
    pub fn resolve(&mut self, id: u64, choice: Choice) -> Result<(ConflictEvent, Choice), NsError> {
        let event = self.events.remove(&id).ok_or(NsError::UnknownEvent(id))?;
        Ok((event, choice))
    }

    /// The version of `path`, with no side effect.
    #[must_use]
    pub fn version(&self, path: &str) -> Version {
        self.paths.get(path).map(|state| state.version.clone()).unwrap_or_default()
    }

    /// The writer holding `path`'s lease at `now_ms`, if any.
    #[must_use]
    pub fn holder(&self, path: &str, now_ms: u64) -> Option<Writer> {
        let lease = self.paths.get(path)?.lease.as_ref()?;
        (now_ms < lease.renewed_ms + LEASE_TTL_MS).then(|| lease.holder.clone())
    }

    /// This authority as it arrives on another machine inside the session's fence, whose clock
    /// reads `now_ms`: every lease is renewed then, every wait starts again, and a steal's flush
    /// window is over.
    #[must_use]
    pub fn moved(mut self, now_ms: u64) -> Self {
        for state in self.paths.values_mut() {
            if let Some(lease) = state.lease.as_mut() {
                lease.renewed_ms = now_ms;
            }
            for (_, first) in &mut state.contenders {
                *first = now_ms;
            }
        }
        for grant in self.grants.values_mut() {
            if let Kind::Lease { lost: Some(Lost::Stolen { until_ms, .. }), .. } = &mut grant.kind {
                *until_ms = 0;
            }
        }
        for event in self.events.values_mut() {
            event.at_ms = now_ms;
        }
        self
    }

    fn mint_token(&mut self) -> u64 {
        let token = self.next_token;
        self.next_token += 1;
        token
    }

    fn grant_lease(&mut self, writer: &Writer, path: &str, now_ms: u64) -> u64 {
        let token = self.mint_token();
        self.grants.insert(
            token,
            Grant {
                path: path.to_owned(),
                writer: writer.clone(),
                kind: Kind::Lease { lost: None, handed: false },
                opens: 1,
                theirs: None,
                conflict: None,
            },
        );
        let state = self.paths.entry(path.to_owned()).or_default();
        state.lease = Some(Lease { token, holder: writer.clone(), renewed_ms: now_ms });
        self.held.entry(writer.member.clone()).or_default().insert(path.to_owned());
        token
    }

    fn unhold(&mut self, member: &str, path: &str) {
        if let Some(paths) = self.held.get_mut(member) {
            paths.remove(path);
            if paths.is_empty() {
                self.held.remove(member);
            }
        }
    }

    /// Ends `path`'s lease if it was not renewed in time; its grant's closes become conflicts.
    fn sweep(&mut self, path: &str, now_ms: u64) {
        let Some(state) = self.paths.get_mut(path) else { return };
        let Some(lease) = state.lease.clone() else { return };
        if now_ms < lease.renewed_ms + LEASE_TTL_MS {
            return;
        }
        state.lease = None;
        if let Some(grant) = self.grants.get_mut(&lease.token) {
            grant.kind = Kind::Lease { lost: Some(Lost::Expired), handed: false };
        }
        self.unhold(&lease.holder.member, path);
    }

    fn renew_member(&mut self, member: &str, now_ms: u64) -> usize {
        let Some(paths) = self.held.get(member).cloned() else { return 0 };
        let mut renewed = 0;
        for path in paths {
            self.sweep(&path, now_ms);
            if let Some(lease) = self.paths.get_mut(&path).and_then(|state| state.lease.as_mut())
                && lease.holder.member == member
            {
                lease.renewed_ms = now_ms;
                renewed += 1;
            }
        }
        renewed
    }

    fn publish(&mut self, path: &str, meta: Meta, writer: &Writer) -> (Version, Vec<String>) {
        let seq = self.next_seq;
        self.next_seq += 1;
        let state = self.paths.entry(path.to_owned()).or_default();
        state.version = Version { seq, meta, by: Some(writer.clone()) };
        let invalidate: Vec<String> =
            state.cached_by.iter().filter(|member| **member != writer.member).cloned().collect();
        for member in &invalidate {
            self.invalidations.entry(member.clone()).or_default().insert(path.to_owned());
        }
        (state.version.clone(), invalidate)
    }

    /// `NAME.cmux-sync-conflict`, or with `-2`, `-3`... when a conflict already took it.
    fn free_conflict_name(&self, path: &str) -> String {
        let base = format!("{path}{CONFLICT_SUFFIX}");
        let taken = |name: &str| self.paths.get(name).is_some_and(|state| state.version.seq > 0);
        if !taken(&base) {
            return base;
        }
        (2..).map(|n| format!("{base}-{n}")).find(|name| !taken(name)).unwrap_or(base)
    }
}

#[cfg(test)]
#[path = "chat_ns_tests.rs"]
mod tests;
