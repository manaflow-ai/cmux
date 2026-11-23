//! Part of `Hub`; see `hub/mod.rs`. The schedule, model call and delivery of surge triage
//! (`crate::surge_triage`, which says what the model may and may not decide).
//!
//! [`Hub::schedule_surge_triage`] runs one pass per chat at most [`DEBOUNCE`] after it is
//! called; a call while a pass runs asks for one more after it, so a slow pass coalesces the
//! arrivals behind it into the next one. The surge holder calls it after each held message, and
//! a restored inbox that holds held messages calls it ([`resume_after_restore`]), so a restart
//! resumes the backlog with no new arrival. A pass that fails (a journal write, a delivery) is
//! tried again [`RETRIES`] times, backing off from [`RETRY_AFTER`], with no new arrival either.
//! A pass:
//!
//! 1. reads the chat's `inbox` and `inbox_triaged` records past its cursor into its cached
//!    [`Journal`] (all of them once after a restart), and the thread owners: the sessions that
//!    subscribed to a thread themselves (`inbox_subscription.rs`), each record read from the
//!    subscriber's own journal, once per daemon run, then kept by the subscription RPC
//!    ([`Hub::note_inbox_subscription`]);
//! 2. triages at most `MAX_BATCHES_PER_PASS` batches of the held messages no record decided,
//!    each through one `complete_own` call on the harness's small model (Claude: Haiku; Codex:
//!    its small model); blockers and questions skip the model. What the model leaves undecided
//!    (a failed or timed-out call, a garbled line) stays held for a later pass;
//! 3. names the pass's digest before sending it (`digest_id`: a hash of its items) and journals
//!    each batch with that name (`persist_surge_triage`), so a crash after it leaves a record
//!    of a digest owed;
//! 4. sends every owed digest: the chat's own (its `needs_this_session` items only; none when
//!    there are none) and one per thread owner its subscriptions name (its `needs_its_owner`
//!    items). The prompt id is the digest's name, so a resend after a crash is the prompt
//!    ledger's duplicate, never a second digest. Then it journals the digest as delivered.
//!
//! A digest is the daemon's own prompt (provenance kind [`PROVENANCE_KIND`], no agent sender),
//! so no surge hold takes it back into an inbox.

use super::*;
use crate::surge_triage::{self as triage, Batch, Decision, Line, Owners};
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

/// The record a read appends (`inbox_thread`, the team read and ack): `{threadId, promptIds,
/// wholeThread?}`.
pub(crate) const READ_KIND: &str = "inbox_read";

/// How long a pass waits after its first call, so one pass takes a burst.
pub(crate) const DEBOUNCE: Duration = Duration::from_secs(30);
pub(crate) const PROVENANCE_KIND: &str = "surge_digest";
/// How a pass ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PassEnd {
    Done,
    /// Held messages are left past the pass's bound: another pass runs at once.
    More,
    /// The model left messages undecided (an outage, a timeout, a garbled answer): they stay
    /// held, and the pass is tried again as a failed one is.
    Undecided,
    /// A recipient is still in the turn an earlier digest started: what is owed waits, and
    /// the next pass runs after this long (its measured reply period, at least [`DEBOUNCE`]),
    /// when everything owed by then goes out as one digest.
    Busy(Duration),
}

/// How long owed digests wait behind a recipient's digest turn, at most: then they go out.
pub(crate) const MAX_HOLD: Duration = Duration::from_secs(600);

/// One digest recipient's pace: the digest turn under way, and how long its digest turns took.
#[derive(Debug, Clone, Default)]
pub(crate) struct DigestPace {
    /// The digest prompt id whose turn runs, and since when.
    pub(crate) running: Option<(String, std::time::Instant)>,
    /// The recipient's measured reply period: a moving average of its digest turns' lengths.
    pub(crate) period: Duration,
}

/// A failed pass is tried again this many times, then waits for the next call.
pub(crate) const RETRIES: u32 = 5;
/// The first retry's wait; each next one doubles it.
pub(crate) const RETRY_AFTER: Duration = Duration::from_secs(30);

/// A restored inbox holds held messages: triage them with no new arrival (module doc). Outside
/// a runtime, or for a chat the hub no longer holds, nothing runs.
pub(super) fn resume_after_restore(session: &Session) {
    if tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    let Some(hub) = session.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
    let held = hub.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id).cloned();
    if let Some(session) = held {
        hub.schedule_surge_triage(&session);
    }
}

/// The thread owners the hub knows: thread to `(at, owner session)`, the newest subscription
/// of a thread winning. None until the first pass reads every chat's subscriptions.
pub(crate) type Subscribers = Option<BTreeMap<String, BTreeMap<String, u64>>>;

/// One subscription record of session `owner`'s journal into `map` (thread to every session
/// subscribed to it, with when): each session's own latest record decides its own entry only,
/// so no later self-subscription shadows another's, and an unsubscribe drops only its own.
fn apply_subscription(
    map: &mut BTreeMap<String, BTreeMap<String, u64>>,
    owner: &str,
    msg: &Value,
    at: u64,
) {
    let Some(thread) = msg.get("threadId").and_then(Value::as_str).filter(|t| !t.is_empty()) else {
        return;
    };
    // A record names its own journal's session or nothing (`inbox_subscription.rs` `replay`).
    if msg.get("ownerSessionId").and_then(Value::as_str) != Some(owner) {
        return;
    }
    let subscribed = map.entry(thread.to_owned()).or_default();
    if msg.get("active").and_then(Value::as_bool).unwrap_or(true) {
        subscribed.insert(owner.to_owned(), at);
    } else {
        subscribed.remove(owner);
    }
    if subscribed.is_empty() {
        map.remove(thread);
    }
}

/// The owner of each thread among `subscribed` that `authorized` allows: the most recent
/// authorized subscriber (ties: the smaller session id), so the pick is the same every pass.
fn authorized_owners(
    subscribed: &BTreeMap<String, BTreeMap<String, u64>>,
    authorized: impl Fn(&str, &str) -> bool,
) -> Owners {
    let pick = |thread: &str, owners: &BTreeMap<String, u64>| {
        owners
            .iter()
            .filter(|(o, _)| authorized(thread, o))
            .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
            .map(|(o, _)| o.clone())
    };
    Owners(
        subscribed
            .iter()
            .filter_map(|(t, owners)| pick(t, owners).map(|o| (t.clone(), o)))
            .collect(),
    )
}
/// What answers instead of the small model (tests).
pub type SurgeTriager = Arc<dyn Fn(String) -> Option<String> + Send + Sync>;

/// A chat's surge triage state, projected from its records and kept between passes
/// (`Hub::surge_triage_journals`): a pass reads only the records past [`Journal::cursor`]. A
/// restart starts from none and reads the chat's records once. Every read is idempotent, so a
/// kept record read again, or this pass's own records read back, change nothing.
#[derive(Default)]
pub(crate) struct Journal {
    /// The last record seq read.
    pub(super) cursor: u64,
    /// Held messages no record decided yet, oldest first.
    pub(super) held: Vec<triage::Held>,
    /// The recipient's own grants of its threads to owner sessions.
    pub(super) grants: Owners,
    /// Undelivered digests: their items by prompt id.
    pub(super) owed: BTreeMap<String, BTreeMap<String, Line>>,
    pub(super) delivered: BTreeSet<String>,
    /// What its digests told whom, for [`triage::mark_repeats`].
    pub(super) told: triage::Told,
    /// Whether the scan has started (a fork's inherited prefix is decided then).
    pub(super) started: bool,
    /// A fork's records copied from its parent, before its `forked` marker: none of them is
    /// this chat's (the parent's held messages, grants and owed digests stay the parent's).
    pub(super) inherited: bool,
    /// `needs_this_session` items: prompt id to thread, while unread.
    pub(super) open: BTreeMap<String, String>,
    /// Held messages filed fyi by rule ([`triage::Held::fyi_by_rule`]) until their triage
    /// record is read: an older pass's `needs_this_session` for one never opens it.
    pub(super) fyi: BTreeSet<String>,
}

impl Journal {
    /// One journal event of `kind`, written at `at` (ms).
    pub(super) fn read(&mut self, kind: &str, msg: &Value, at: u64) {
        match kind {
            "inbox" => {
                if let Some(h) = triage::held_from_inbox(msg)
                    && !self.held.iter().any(|x| x.prompt_id == h.prompt_id)
                {
                    if h.fyi_by_rule() {
                        self.fyi.insert(h.prompt_id.clone());
                    }
                    self.held.push(h);
                }
            }
            // A read lowers needYou: a thread read (`wholeThread`) closes every open item of
            // that thread so far, an item read closes that item.
            READ_KIND => {
                let ids = msg.get("promptIds").and_then(Value::as_array);
                for id in ids.into_iter().flatten().filter_map(Value::as_str) {
                    self.open.remove(id);
                }
                if msg.get("wholeThread").and_then(Value::as_bool) == Some(true)
                    && let Some(thread) = msg.get("threadId").and_then(Value::as_str)
                {
                    self.open.retain(|_, t| t != thread);
                }
            }
            triage::GRANT_KIND => self.grants.apply(msg),
            triage::RECORD_KIND => {
                let done: BTreeSet<String> = triage::triaged_ids(msg).collect();
                if !done.is_empty() {
                    self.held.retain(|h| !done.contains(&h.prompt_id));
                }
                let fyi: BTreeSet<String> =
                    done.iter().filter(|id| self.fyi.remove(*id)).cloned().collect();
                if let Some(d) = msg.get("digestDelivered").and_then(Value::as_str) {
                    self.owed.remove(d);
                    self.delivered.insert(d.to_owned());
                }
                // Owed digests that waited behind a busy recipient, merged into one.
                if let Some(into) = msg.get("into").and_then(Value::as_str) {
                    let from = msg.get("coalesced").and_then(Value::as_array);
                    let ids = from.into_iter().flatten().filter_map(Value::as_str);
                    for id in ids.filter(|id| *id != into) {
                        let lines = self.owed.remove(id).unwrap_or_default();
                        self.delivered.insert(id.to_owned());
                        if !self.delivered.contains(into) {
                            self.owed.entry(into.to_owned()).or_default().extend(lines);
                        }
                    }
                }
                // Owner items whose owner lost its authorization before delivery: told here.
                let redirected = msg.get("redirected").and_then(Value::as_array);
                for r in redirected.into_iter().flatten() {
                    let s = |k: &str| r.get(k).and_then(Value::as_str).map(str::to_owned);
                    if let (Some(id), Some(thread)) = (s("promptId"), s("threadId")) {
                        self.open.insert(id, thread);
                    }
                }
                let Some(d) = msg.get("digestPromptId").and_then(Value::as_str) else { return };
                let recipient = msg.get("recipient").and_then(Value::as_str).unwrap_or_default();
                self.told.read_record(recipient, msg, at);
                for line in triage::record_lines(msg) {
                    if line.category == triage::Category::NeedsThisSession
                        && line.repeat_of.is_none()
                        && !fyi.contains(&line.prompt_id)
                    {
                        self.open.insert(line.prompt_id.clone(), line.thread_id.clone());
                    }
                    if !self.delivered.contains(d) {
                        let owed = self.owed.entry(d.to_owned()).or_default();
                        owed.insert(line.prompt_id.clone(), line);
                    }
                }
            }
            _ => {}
        }
    }
}

/// Tests: passes of a chat that fail after their journal writes, before any delivery.
#[cfg(test)]
pub(super) static FAIL_BEFORE_DELIVERY: std::sync::Mutex<BTreeMap<String, u32>> =
    std::sync::Mutex::new(BTreeMap::new());

/// Tests: journal writes of a chat that fail, by kind (`batch` or `marker`).
#[cfg(test)]
pub(super) static FAIL_WRITES: std::sync::Mutex<BTreeMap<(String, &'static str), u32>> =
    std::sync::Mutex::new(BTreeMap::new());

/// Tests: every digest's acceptance, with the session it went to.
#[cfg(test)]
pub(super) static DIGEST_ACCEPTS: std::sync::Mutex<Vec<(String, Value)>> =
    std::sync::Mutex::new(Vec::new());

/// The owner digest's prompt id under the chat's digest `id`.
fn owner_digest_id(id: &str, owner: &str) -> String {
    let h = sha2::Sha256::digest(owner.as_bytes());
    format!("{id}-o{}", triage::hex_prefix(format!("{h:x}"), 12))
}

use sha2::Digest as _;

impl Hub {
    /// Triage `session`'s held messages once, [`DEBOUNCE`] from now (module doc).
    pub(crate) fn schedule_surge_triage(self: &Arc<Self>, session: &Arc<Session>) {
        {
            let mut due = self.surge_triage_due.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(again) = due.get_mut(&session.id) {
                *again = true;
                return;
            }
            due.insert(session.id.clone(), false);
        }
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("surge-triage", async move {
            let mut wait = hub.surge_triage_wait(DEBOUNCE);
            let mut failures = 0u32;
            loop {
                tokio::time::sleep(wait).await;
                let mut busy = None;
                let more = match hub.surge_triage_pass(&session).await {
                    Ok(PassEnd::Done) => {
                        failures = 0;
                        false
                    }
                    // Arrivals meanwhile coalesce into the digest that goes when the turn ends.
                    Ok(PassEnd::Busy(after)) => {
                        failures = 0;
                        busy = Some(after);
                        false
                    }
                    Ok(PassEnd::More) => {
                        failures = 0;
                        true
                    }
                    // The model left messages undecided: back off, as after a failure.
                    Ok(PassEnd::Undecided) => {
                        failures += 1;
                        false
                    }
                    Err(e) => {
                        failures += 1;
                        tracing::warn!(session = %session.id, failures, "surge triage: {}", e.message);
                        false
                    }
                };
                let mut due = hub.surge_triage_due.lock().unwrap_or_else(|e| e.into_inner());
                let again = due.get(&session.id).copied().unwrap_or(false);
                let retry = failures > 0 && failures <= RETRIES;
                if !(more || again || retry || busy.is_some()) || super::queue::closing(&session) {
                    due.remove(&session.id);
                    return;
                }
                due.insert(session.id.clone(), false);
                wait = if retry {
                    hub.surge_triage_wait(RETRY_AFTER * 2u32.pow(failures - 1))
                } else if let Some(after) = busy {
                    // Paced by the receiver: no faster than it answers, however many arrive.
                    hub.surge_triage_wait(after)
                } else {
                    hub.surge_triage_wait(DEBOUNCE)
                };
            }
        });
    }

    /// `full`, or a thousandth of it while a test answers for the model.
    fn surge_triage_wait(&self, full: Duration) -> Duration {
        if self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
            full / 1000
        } else {
            full
        }
    }

    /// The subscription RPC's change (`inbox_subscription.rs`): kept in the owners the hub
    /// knows, once it read them. Before that, the first read finds the record in the journal.
    pub(crate) fn note_inbox_subscription(&self, owner: &str, thread: &str, active: bool) {
        let mut subs = self.surge_subscribers.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(map) = subs.as_mut() {
            let msg = json!({"threadId": thread, "ownerSessionId": owner, "active": active});
            apply_subscription(map, owner, &msg, now_ms());
        }
    }

    /// The thread owners: every chat's own subscriptions, read once per daemon run. The lock
    /// is held while reading, so no subscription change is lost between the read and its note.
    ///
    /// A subscription alone grants nothing (RFD 0018: a thread name is no access): an owner
    /// is one the recipient authorized, by a grant in its own journal ([`triage::GRANT_KIND`])
    /// or as its parent or delegator. An unrelated session that subscribed itself to a matching
    /// thread gets nothing of the recipient's.
    fn surge_owners(&self, recipient: &Session, grants: &Owners) -> Owners {
        let meta = recipient.meta();
        let parent = meta.lineage.as_ref().map(|l| l.parent.as_str());
        let delegator = meta.delegator.as_deref();
        let authorized = |thread: &str, owner: &str| {
            grants.0.get(thread).is_some_and(|g| g == owner)
                || Some(owner) == parent
                || Some(owner) == delegator
        };
        let mut subs = self.surge_subscribers.lock().unwrap_or_else(|e| e.into_inner());
        authorized_owners(self.surge_subscribed(&mut subs), authorized)
    }

    /// Every session's own thread subscriptions, read once per daemon run under `subs`.
    fn surge_subscribed<'a>(
        &self,
        subs: &'a mut Subscribers,
    ) -> &'a BTreeMap<String, BTreeMap<String, u64>> {
        subs.get_or_insert_with(|| {
            let mut map = BTreeMap::new();
            for s in self.session_handles() {
                let read = self.scan_for_rebuild(&s, &[triage::SUBSCRIPTION_KIND], &mut |e| {
                    apply_subscription(&mut map, &s.id, &e.msg, e.at);
                    true
                });
                if let Err(e) = read {
                    tracing::warn!(session = %s.id, "surge triage: subscriptions unread: {e}");
                }
            }
            map
        })
    }

    /// One journal write of a pass. A failure ends the pass with its error; the pass drops its
    /// cached projection, so the retry rebuilds it from the log and nothing the failed write
    /// held counts as done: undecided messages are triaged again, an undelivered digest sent
    /// again (its prompt id's duplicate if it reached the chat), a missing marker written again.
    fn surge_persist(&self, session: &Session, msg: Value, open: u64) -> Result<(), RpcError> {
        #[cfg(test)]
        {
            let mut fail = FAIL_WRITES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let kind = if msg.get("digestDelivered").is_some() { "marker" } else { "batch" };
            if let Some(n) = fail.get_mut(&(session.id.clone(), kind))
                && *n > 0
            {
                *n -= 1;
                return Err(RpcError::internal("test: a failed journal write"));
            }
        }
        self.persist_surge_triage(session, msg, open)
    }

    #[cfg(test)]
    pub(crate) fn set_surge_triager(&self, triager: Option<SurgeTriager>) {
        *self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()) = triager;
    }

    /// Turns surge admission on or off for this hub, whatever the settings file says (tests).
    #[cfg(test)]
    pub(crate) fn set_surge_inbox(&self, on: Option<bool>) {
        *self.surge_inbox.lock().unwrap_or_else(|e| e.into_inner()) = on;
    }

    /// `session`'s journal, read up to its newest record: the cached one past its cursor, or,
    /// after a restart, the chat's records once.
    fn surge_journal(&self, session: &Session) -> Result<Journal, RpcError> {
        let cached = {
            let mut all = self.surge_triage_journals.lock().unwrap_or_else(|e| e.into_inner());
            all.remove(&session.id)
        };
        let mut journal = cached.unwrap_or_default();
        self.surge_journal_tail(session, &mut journal)?;
        Ok(journal)
    }

    /// Reads `journal`'s records past its cursor.
    fn surge_journal_tail(&self, session: &Session, journal: &mut Journal) -> Result<(), RpcError> {
        if !journal.started {
            journal.started = true;
            // As `message_events::recover_message_events_after`: a fork skips everything up to
            // its `forked` marker, all of it when a crash left none.
            journal.inherited = session.meta().fork_seq.is_some();
        }
        let kinds = ["inbox", triage::RECORD_KIND, triage::GRANT_KIND, READ_KIND, "forked"];
        let mut newest = journal.cursor;
        self.scan_kinds_after_and_kept(session, journal.cursor, &kinds, &mut |e: EventRecord| {
            newest = newest.max(e.seq);
            if journal.inherited {
                journal.inherited = e.kind != "forked";
            } else {
                journal.read(&e.kind, &e.msg, e.at);
            }
            true
        })
        .map_err(|e| RpcError::internal(format!("read surge records: {e}")))?;
        journal.cursor = newest;
        Ok(())
    }

    /// `lines` as delivered now: an owner item whose owner is no longer the thread's
    /// authorized owner (its grant revoked, its subscription removed since the pass decided
    /// it), or that is closed, is this chat's again: never the old owner's, and never lost.
    /// Returns the lines and the redirected.
    fn surge_reauthorize(
        &self,
        session: &Session,
        grants: &Owners,
        mut lines: Vec<Line>,
    ) -> (Vec<Line>, Vec<Line>) {
        let mut redirected = Vec::new();
        if !lines.iter().any(|l| l.owner.is_some()) {
            return (lines, redirected);
        }
        let owners = self.surge_owners(session, grants);
        for l in &mut lines {
            let Some(owner) = l.owner.as_deref() else { continue };
            let reachable = || self.resolve(owner).is_ok_and(|s| !super::queue::closing(&s));
            if owners.0.get(&l.thread_id).map(String::as_str) == Some(owner) && reachable() {
                continue;
            }
            l.category = triage::Category::NeedsThisSession;
            l.owner = None;
            // The chat was never told it: the owner's receipt says nothing to it.
            l.repeat_of = None;
            redirected.push(l.clone());
        }
        (lines, redirected)
    }

    /// One pass (module doc).
    pub(super) async fn surge_triage_pass(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<PassEnd, RpcError> {
        let mut journal = self.surge_journal(session)?;
        // A failed write leaves the cached state ahead of the disk: the next pass reads it again.
        let end = self.surge_triage_pass_on(session, &mut journal).await?;
        let mut all = self.surge_triage_journals.lock().unwrap_or_else(|e| e.into_inner());
        all.insert(session.id.clone(), journal);
        Ok(end)
    }

    async fn surge_triage_pass_on(
        self: &Arc<Self>,
        session: &Arc<Session>,
        journal: &mut Journal,
    ) -> Result<PassEnd, RpcError> {
        // Blockers and questions first, with no model; then the rest through it.
        let (urgent, rest) = triage::split_urgent(&journal.held);
        let urgent = triage::batches(&session.id, urgent);
        let batches = triage::batches(&session.id, rest);
        let taken: usize = urgent.iter().chain(&batches).map(|b| b.messages.len()).sum();
        let left = journal.held.len() > taken;
        let harness = session.meta().harness;
        let owners = if batches.is_empty() {
            Owners::default()
        } else {
            self.surge_owners(session, &journal.grants)
        };
        let mut decided: Vec<(Batch, Vec<Decision>)> = Vec::new();
        let mut undecided = 0usize;
        for batch in urgent {
            let d = triage::decide(&batch, None, &owners).into_iter().flatten().collect();
            decided.push((batch, d));
        }
        for batch in batches {
            let all = self.surge_triage_batch(Some(harness.as_str()), &batch, &owners).await;
            undecided += all.iter().filter(|d| d.is_none()).count();
            let d: Vec<Decision> = all.into_iter().flatten().collect();
            if !d.is_empty() {
                decided.push((batch, d));
            }
        }
        // A repeat of what a digest already told its recipient (another host's report of one
        // incident, the same blocker again) is journaled with its receipt and shown nowhere.
        let now = crate::store::now_ms();
        for (batch, d) in &mut decided {
            triage::mark_repeats(batch, d, &mut journal.told, now);
        }
        // The pass's one digest is named by every item it carries, before any is journaled.
        let lines: Vec<Line> = decided
            .iter()
            .flat_map(|(b, d)| triage::record_lines(&triage::triaged_record(b, d, None)))
            .collect();
        if !lines.is_empty() {
            let id = triage::digest_id(&session.id, &lines);
            for (batch, d) in &decided {
                let mut record = triage::triaged_record(batch, d, Some(&id));
                triage::set_key(&mut record, "at", json!(now));
                journal.read(triage::RECORD_KIND, &record, now);
                let open = self.surge_open_topics(session, journal);
                self.surge_persist(session, record, open)?;
            }
        }
        #[cfg(test)]
        if let Some(n) = FAIL_BEFORE_DELIVERY
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get_mut(&session.id)
            && *n > 0
        {
            *n -= 1;
            return Err(RpcError::internal("test: a failure after the journal write"));
        }
        // Owed digests that waited (behind a busy recipient, or a failed delivery) go as one.
        if journal.owed.len() > 1 {
            let ids: Vec<String> = journal.owed.keys().cloned().collect();
            let all: Vec<Line> = journal.owed.values().flat_map(|l| l.values().cloned()).collect();
            let into = triage::digest_id(&session.id, &all);
            let record = json!({"coalesced": ids, "into": into, "items": []});
            journal.read(triage::RECORD_KIND, &record, crate::store::now_ms());
            let open = self.surge_open_topics(session, journal);
            self.surge_persist(session, record, open)?;
        }
        let owed: Vec<(String, Vec<Line>)> = journal
            .owed
            .iter()
            .map(|(id, lines)| (id.clone(), lines.values().cloned().collect()))
            .collect();
        // A grant revoked or a subscription removed since the decision counts at delivery.
        if owed.iter().any(|(_, lines)| lines.iter().any(|l| l.owner.is_some())) {
            self.surge_journal_tail(session, journal)?;
        }
        for (id, lines) in owed {
            let (lines, redirected) = self.surge_reauthorize(session, &journal.grants, lines);
            if let Some(after) = self.surge_digest_busy(session, &id, &lines, &redirected) {
                return Ok(PassEnd::Busy(after));
            }
            self.deliver_surge_digests(session, &id, &lines, &redirected).await?;
            let redirected: Vec<Value> = redirected
                .iter()
                .map(|l| json!({"promptId": l.prompt_id, "threadId": l.thread_id}))
                .collect();
            let mut marker = json!({"digestDelivered": id, "items": []});
            if !redirected.is_empty() {
                triage::set_key(&mut marker, "redirected", json!(redirected));
            }
            journal.read(triage::RECORD_KIND, &marker, crate::store::now_ms());
            let open = self.surge_open_topics(session, journal);
            self.surge_persist(session, marker, open)?;
        }
        // needYou as the journal counts it now: a read since, or a rule that files what an
        // older pass opened as fyi, lowers it with no new item.
        let open = self.surge_open_topics(session, journal);
        if open != session.inbox().surge_counts_need_you() {
            self.surge_persist(session, json!({"items": []}), open)?;
        }
        Ok(if undecided > 0 {
            PassEnd::Undecided
        } else if left {
            PassEnd::More
        } else {
            PassEnd::Done
        })
    }

    /// After a read: needYou counted again now, not at the next pass. A thread read whose
    /// items all left memory (`trim` lets held ones go first) wrote no read record, so one is
    /// written here; then a changed count is journaled, which the chat row reads.
    pub(crate) fn surge_after_read(&self, session: &Session, thread: Option<&str>) {
        if !self.surge_inbox_on() && session.inbox().surge_counts_need_you() == 0 {
            return;
        }
        let Ok(mut journal) = self.surge_journal(session) else { return };
        if let Some(thread) = thread
            && journal.open.values().any(|t| t == thread)
        {
            let msg = json!({"threadId": thread, "promptIds": [], "wholeThread": true});
            self.append(session, "mux", READ_KIND, msg.clone());
            journal.read(READ_KIND, &msg, crate::store::now_ms());
        }
        let open = self.surge_open_topics(session, &mut journal);
        if open != session.inbox().surge_counts_need_you() {
            let _ = self.persist_surge_triage(session, json!({"items": []}), open);
        }
        let mut all = self.surge_triage_journals.lock().unwrap_or_else(|e| e.into_inner());
        // A pass that took the journal meanwhile puts its own back; it reads these records then.
        all.entry(session.id.clone()).or_insert(journal);
    }

    /// Distinct threads with a `needs_this_session` item the chat has not read; read ones
    /// leave the journal.
    fn surge_open_topics(&self, session: &Session, journal: &mut Journal) -> u64 {
        if !journal.open.is_empty() {
            let inbox = session.inbox();
            for item in inbox.items.iter().filter(|i| i.read) {
                journal.open.remove(&item.prompt_id);
            }
        }
        let threads: BTreeSet<&String> = journal.open.values().collect();
        threads.len() as u64
    }

    /// The digests `id` sends now, as `(recipient, prompt id, text, shown lines)`: the chat's
    /// own and each owner's, none for a recipient with nothing to show.
    fn surge_digests<'a>(
        &self,
        session: &Session,
        id: &str,
        lines: &'a [Line],
        redirected: &[Line],
    ) -> Vec<(String, String, String, Vec<&'a Line>)> {
        let mut out = Vec::new();
        if let Some(text) = triage::digest(&session.id, lines) {
            // Redirected items change what the chat's digest says: its own prompt id, so a
            // copy sent before the revocation does not swallow it as a duplicate.
            let id = if redirected.is_empty() {
                id.to_owned()
            } else {
                owner_digest_id(id, &triage::digest_id(&session.id, redirected))
            };
            out.push((session.id.clone(), id, text, triage::digest_lines(lines)));
        }
        let owners: BTreeSet<&str> = lines.iter().filter_map(|l| l.owner.as_deref()).collect();
        for owner in owners {
            let Some(text) = triage::owner_digest(&session.id, owner, lines) else { continue };
            let theirs = triage::owner_digest_lines(owner, lines);
            out.push((owner.to_owned(), owner_digest_id(id, owner), text, theirs));
        }
        out
    }

    /// How long digest `id` waits: None when every recipient is free (or in this digest's
    /// own turn, a resend being its duplicate); else the busiest one's reply period, at least
    /// [`DEBOUNCE`]. A turn past [`MAX_HOLD`] holds nothing.
    fn surge_digest_busy(
        &self,
        session: &Session,
        id: &str,
        lines: &[Line],
        redirected: &[Line],
    ) -> Option<Duration> {
        let digests = self.surge_digests(session, id, lines, redirected);
        let pace = self.surge_digest_pace.lock().unwrap_or_else(|e| e.into_inner());
        digests
            .iter()
            .filter_map(|(to, prompt, _, _)| {
                let p = pace.get(to)?;
                let (running, since) = p.running.as_ref()?;
                (running != prompt && since.elapsed() < MAX_HOLD).then_some(p.period.max(DEBOUNCE))
            })
            .max()
    }

    /// Sends the digests named `id`: the chat's own and each owner's. Each is sent once: a
    /// resend is its prompt id's duplicate. An owner that cannot be reached fails the pass
    /// (it is retried; [`Hub::surge_reauthorize`] hands a closed owner's items to the chat),
    /// so no digest is journaled delivered that no one received.
    async fn deliver_surge_digests(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        lines: &[Line],
        redirected: &[Line],
    ) -> Result<(), RpcError> {
        for (to, prompt, text, shown) in self.surge_digests(session, id, lines, redirected) {
            let to = if to == session.id { session.clone() } else { self.resolve(&to)? };
            self.send_surge_digest(&to, &prompt, text, &shown).await?;
        }
        Ok(())
    }

    /// One digest prompt, accepted (queued, steered or a duplicate) before this returns. Its
    /// provenance names only `lines`, the ones its text shows its recipient.
    async fn send_surge_digest(
        self: &Arc<Self>,
        to: &Arc<Session>,
        id: &str,
        text: String,
        lines: &[&Line],
    ) -> Result<(), RpcError> {
        let ids: Vec<&str> = lines.iter().map(|l| l.prompt_id.as_str()).collect();
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(id.to_owned()),
            provenance: Some(json!({"kind": PROVENANCE_KIND, "digestId": id, "promptIds": ids})),
            on_accepted: Some(Box::new(move |accepted: Value| {
                let _ = tx.send(accepted);
            })),
            ..PromptOptions::default()
        };
        let (hub, chat) = (self.clone(), to.clone());
        let started = std::time::Instant::now();
        {
            let mut pace = self.surge_digest_pace.lock().unwrap_or_else(|e| e.into_inner());
            pace.entry(to.id.clone()).or_default().running = Some((id.to_owned(), started));
        }
        let prompt = id.to_owned();
        // Runs on past the accept: a queued prompt's run lasts until its turn ends, which
        // ends the recipient's digest turn and measures its reply period.
        let run = self.scope.spawn_named("surge-digest", async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            let ran = hub.prompt_with(&chat, blocks, "acpmux", false, opts).await;
            let took = started.elapsed();
            let mut pace = hub.surge_digest_pace.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(p) = pace.get_mut(&chat.id) {
                p.period = if p.period.is_zero() { took } else { (p.period * 3 + took) / 4 };
                if p.running.as_ref().is_some_and(|(id, _)| *id == prompt) {
                    p.running = None;
                }
            }
            // A closed chat paces nothing: its entry goes with it.
            if super::queue::closing(&chat) {
                pace.remove(&chat.id);
            }
            ran
        });
        match rx.await {
            Ok(_accepted) => {
                #[cfg(test)]
                DIGEST_ACCEPTS
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push((to.id.clone(), _accepted));
                Ok(())
            }
            Err(_) => match run.await {
                Ok(Err(e)) => Err(e),
                _ => Err(RpcError::internal("surge digest was not accepted")),
            },
        }
    }

    /// The decisions of `batch`, through `harness` (None: the default harness).
    pub(crate) async fn surge_triage_batch(
        self: &Arc<Self>,
        harness: Option<&str>,
        batch: &Batch,
        owners: &Owners,
    ) -> Vec<Option<Decision>> {
        if batch.messages.is_empty() {
            return Vec::new();
        }
        let prompt = triage::prompt(batch);
        let triager = self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let answer = match triager {
            Some(triage_with) => triage_with(prompt),
            None => {
                let timeout = Duration::from_millis(triage::TIMEOUT_MS);
                match self
                    .complete_own(
                        harness,
                        prompt,
                        triage::MAX_TOKENS,
                        timeout,
                        super::complete::ModelFallback::SmallOnly,
                    )
                    .await
                {
                    Ok(text) => Some(text),
                    Err(e) => {
                        tracing::info!(
                            recipient = %batch.recipient,
                            batch = %batch.batch_id,
                            reason = e.reason(),
                            "surge triage: no model answer; its messages stay held for a later pass"
                        );
                        None
                    }
                }
            }
        };
        triage::decide(batch, answer.as_deref(), owners)
    }
}

#[cfg(test)]
#[path = "surge_triage_tests.rs"]
mod tests;
