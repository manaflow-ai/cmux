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
    /// Prompt ids a triage record decided: their inbox record, read again, holds nothing.
    pub(super) triaged: BTreeSet<String>,
    /// The recipient's own grants of its threads to owner sessions.
    pub(super) grants: Owners,
    /// Undelivered digests: their items by prompt id.
    pub(super) owed: BTreeMap<String, BTreeMap<String, Line>>,
    pub(super) delivered: BTreeSet<String>,
    /// What its digests told whom, for [`triage::mark_repeats`].
    pub(super) told: triage::Told,
    /// `needs_this_session` items: prompt id to thread, while unread.
    pub(super) open: BTreeMap<String, String>,
}

impl Journal {
    /// One journal event of `kind`, written at `at` (ms).
    pub(super) fn read(&mut self, kind: &str, msg: &Value, at: u64) {
        match kind {
            "inbox" => {
                if let Some(h) = triage::held_from_inbox(msg)
                    && !self.triaged.contains(&h.prompt_id)
                    && !self.held.iter().any(|x| x.prompt_id == h.prompt_id)
                {
                    self.held.push(h);
                }
            }
            triage::GRANT_KIND => self.grants.apply(msg),
            triage::RECORD_KIND => {
                let done: BTreeSet<String> = triage::triaged_ids(msg).collect();
                if !done.is_empty() {
                    self.held.retain(|h| !done.contains(&h.prompt_id));
                    self.triaged.extend(done);
                }
                if let Some(d) = msg.get("digestDelivered").and_then(Value::as_str) {
                    self.owed.remove(d);
                    self.delivered.insert(d.to_owned());
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
    format!("{id}-o{}", format!("{h:x}").chars().take(12).collect::<String>())
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
                let more = match hub.surge_triage_pass(&session).await {
                    Ok(PassEnd::Done) => {
                        failures = 0;
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
                if !(more || again || retry) || super::queue::closing(&session) {
                    due.remove(&session.id);
                    return;
                }
                due.insert(session.id.clone(), false);
                wait = if retry {
                    hub.surge_triage_wait(RETRY_AFTER * 2u32.pow(failures - 1))
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
        let kinds = ["inbox", triage::RECORD_KIND, triage::GRANT_KIND];
        let mut newest = journal.cursor;
        self.scan_kinds_after_and_kept(session, journal.cursor, &kinds, &mut |e: EventRecord| {
            newest = newest.max(e.seq);
            journal.read(&e.kind, &e.msg, e.at);
            true
        })
        .map_err(|e| RpcError::internal(format!("read surge records: {e}")))?;
        journal.cursor = newest;
        Ok(())
    }

    /// `lines` as delivered now: an owner item whose owner is no longer the thread's
    /// authorized owner (its grant revoked, its subscription removed since the pass decided
    /// it) is this chat's again, never the old owner's. Returns the lines and the redirected.
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
            if owners.0.get(&l.thread_id).map(String::as_str) == Some(owner) {
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
                if let Some(fields) = record.as_object_mut() {
                    fields.insert("at".into(), json!(now));
                }
                journal.read(triage::RECORD_KIND, &record, now);
                let open = self.surge_open_topics(session, journal);
                self.surge_persist(session, record, open)?;
            }
        }
        #[cfg(test)]
        if let Some(n) =
            FAIL_BEFORE_DELIVERY.lock().unwrap_or_else(|e| e.into_inner()).get_mut(&session.id)
            && *n > 0
        {
            *n -= 1;
            return Err(RpcError::internal("test: a failure after the journal write"));
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
            self.deliver_surge_digests(session, &id, &lines, &redirected).await?;
            let redirected: Vec<Value> = redirected
                .iter()
                .map(|l| json!({"promptId": l.prompt_id, "threadId": l.thread_id}))
                .collect();
            let mut marker = json!({"digestDelivered": id, "items": []});
            if !redirected.is_empty()
                && let Some(fields) = marker.as_object_mut()
            {
                fields.insert("redirected".into(), json!(redirected));
            }
            journal.read(triage::RECORD_KIND, &marker, crate::store::now_ms());
            let open = self.surge_open_topics(session, journal);
            self.surge_persist(session, marker, open)?;
        }
        Ok(if undecided > 0 {
            PassEnd::Undecided
        } else if left {
            PassEnd::More
        } else {
            PassEnd::Done
        })
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

    /// Sends the digests named `id`: the chat's own and each owner's. Each is sent once: a
    /// resend is its prompt id's duplicate.
    async fn deliver_surge_digests(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        lines: &[Line],
        redirected: &[Line],
    ) -> Result<(), RpcError> {
        if let Some(text) = triage::digest(&session.id, lines) {
            let mine = triage::digest_lines(lines);
            // Redirected items change what the chat's digest says: its own prompt id, so a
            // copy sent before the revocation does not swallow it as a duplicate.
            let id = if redirected.is_empty() {
                id.to_owned()
            } else {
                owner_digest_id(id, &triage::digest_id(&session.id, redirected))
            };
            self.send_surge_digest(session, &id, text, &mine).await?;
        }
        let owners: BTreeSet<&str> = lines.iter().filter_map(|l| l.owner.as_deref()).collect();
        for owner in owners {
            let Some(text) = triage::owner_digest(&session.id, owner, lines) else { continue };
            // An owner gone since its subscription: its items stay in this chat's archive.
            let Ok(to) = self.resolve(owner) else {
                tracing::info!(session = %session.id, owner, "surge triage: owner gone");
                continue;
            };
            let theirs = triage::owner_digest_lines(owner, lines);
            self.send_surge_digest(&to, &owner_digest_id(id, owner), text, &theirs).await?;
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
        // Runs on past the accept: a queued prompt's run lasts until its turn ends.
        let run = self.scope.spawn_named("surge-digest", async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            hub.prompt_with(&chat, blocks, "acpmux", false, opts).await
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
        let recipient_name = self
            .resolve(&batch.recipient)
            .map(|session| session.read_meta(|meta| meta.name.clone()))
            .unwrap_or_else(|_| batch.recipient.clone());
        let prompt = triage::prompt(batch, &recipient_name, owners);
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
