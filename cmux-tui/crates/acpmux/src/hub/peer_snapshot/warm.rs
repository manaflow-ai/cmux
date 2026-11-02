//! Part of `peer_snapshot.rs`: the copies are read ahead of an open. A copy holds only what a
//! client here read, so a chat nobody opened on this machine (a lane another agent started on a
//! remote machine) had none, and while its peer reconnected it opened on an error for as long as the
//! link took to come back (Leo, 2026-10-30: "IT DID IN FACT LOAD BUT TOOK 30+ FUCKING SECONDS").
//! So a daemon whose clients open peer chats (an attach forwarded this run) reads each peer's most
//! recently changed open chats a little after their rows change, and keeps the page as any
//! forwarded page is kept (`Hub::capture_peer_page`): the chat then paints at once from its copy,
//! whether its peer answers or not, and the peer's own page continues it once it does.
//!
//! Bounds: [`WARM_PER_PEER`] chats of each peer, changed in the last [`WARM_WITHIN_MS`]; a read is
//! the pane's open page ([`WARM_LIMIT`] records within [`WARM_BYTES`]), only past what the copy
//! covers once it covers some, one page a chat a round; a chat is read (or tried) at most once each
//! [`WARM_EVERY`], and its last change, a refusal and a page cut short are read again after it; one round at a
//! time per peer, one read at a time in it, and a round ends at the first read the link refuses (a
//! chat the peer refuses is passed over). What is kept stays within the copies' own bounds. Rounds
//! stop with the daemon (`Hub::stop_idle_reaper`), before its last flush.

use super::*;
use std::sync::Weak;
use tokio::sync::Notify;

/// Chats of one peer read ahead: its open chats that changed last.
const WARM_PER_PEER: usize = if cfg!(test) { 2 } else { 24 };
/// A chat whose row changed longer ago than this is not read ahead.
const WARM_WITHIN_MS: u64 = 86_400_000;
/// The least time between two reads of one chat; a change inside it is read when it ends.
const WARM_EVERY: Duration = Duration::from_millis(if cfg!(test) { 200 } else { 30_000 });
/// How long after a peer's first row change its round starts, so a burst of changes (a turn ends,
/// its title and usage follow) takes one round.
const WARM_SETTLE: Duration = Duration::from_millis(if cfg!(test) { 20 } else { 2_000 });
/// A read's bounds: those of the pane's attach (`OPEN_PAGE_BYTES`, webviews `direct.ts`).
const WARM_LIMIT: u64 = 400;
const WARM_BYTES: u64 = 128 << 10;
/// The kinds the pane's attach of a peer chat asks for, at most 8 (an older peer refuses more):
/// the transcript, the commands, usage, config, bookmarks and secret cards.
const WARM_KINDS: [&str; 7] = [
    "transcript",
    "available_commands_update",
    "usage_update",
    "config_option_update",
    "bookmarks",
    "secret_request",
    "secret_decision",
];
/// `beforeSeq` past every seq, 2^53 - 1 (the largest a client's number holds exactly): the newest
/// page (the pane's read-ahead asks the same).
pub(super) const NEWEST: u64 = 9_007_199_254_740_991;

/// What the hub keeps of the reads ahead.
#[derive(Default)]
pub(crate) struct Warm {
    /// A client here opened a peer chat this run: only then are chats read ahead.
    wanted: AtomicBool,
    /// The loop runs (`warm_loop`).
    started: AtomicBool,
    kick: Arc<Notify>,
    state: StdMutex<State>,
}

#[derive(Default)]
struct State {
    /// Peers whose round is due, and when: their first change since their last round, plus
    /// [`WARM_SETTLE`] (a later change does not put it off).
    due: HashMap<String, Instant>,
    /// Peers whose round runs.
    running: HashSet<String>,
    /// The rounds started, to stop them with the daemon (finished ones are pruned as rounds start).
    rounds: Vec<tokio::task::AbortHandle>,
    /// The daemon stops: no round starts, and none keeps a page.
    stopped: bool,
    /// When each chat was last read ahead, and the generation read (only chats of the rounds'
    /// plans: pruned each round). A session recreated since is not held back by it.
    read_at: HashMap<Key, (u64, Instant)>,
}

impl Warm {
    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The peers whose round starts now (marked running), and when the next is due.
    fn take_due(&self, now: Instant) -> (Vec<String>, Option<Instant>) {
        let mut s = self.state();
        if s.stopped {
            return (vec![], None);
        }
        let State { due, running, .. } = &mut *s;
        let ready: Vec<String> = due
            .iter()
            .filter(|(peer, at)| **at <= now && !running.contains(*peer))
            .map(|(peer, _)| peer.clone())
            .collect();
        for peer in &ready {
            due.remove(peer);
            running.insert(peer.clone());
        }
        let next = due.iter().filter(|(peer, _)| !running.contains(*peer)).map(|(_, at)| *at).min();
        (ready, next)
    }

    /// The daemon stops: every round ends at its next wait, and none keeps a page after this.
    pub(crate) fn stop(&self) {
        let mut s = self.state();
        s.stopped = true;
        for round in s.rounds.drain(..) {
            round.abort();
        }
    }

    /// Peer `peer`'s round is due by `at`, unless an earlier one is.
    fn due_by(&self, peer: &str, at: Instant) {
        let mut s = self.state();
        let due = s.due.entry(peer.to_owned()).or_insert(at);
        *due = (*due).min(at);
    }
}

/// `d` after `at`; `at` itself on a clock that cannot go that far (it never comes to that).
fn after(at: Instant, d: Duration) -> Instant {
    at.checked_add(d).unwrap_or(at)
}

/// One chat a round reads: which session, the generation its row names, its params.
#[derive(Debug, PartialEq)]
pub(super) struct Ask {
    pub mux: String,
    pub generation: u64,
    pub params: Value,
}

/// What a round reads of peer `peer`, whose rows are `rows` and whose copies cover `covers`
/// (session: its generation and last seq), at `now` (ms since the epoch, and the clock the reads
/// are timed on): the chats to read now, the chats it plans (for pruning `read_at`), and when a
/// chat it leaves for [`WARM_EVERY`] is due.
pub(super) fn plan(
    peer: &str,
    rows: &[Value],
    covers: &HashMap<String, (Option<u64>, u64)>,
    read_at: &HashMap<Key, (u64, Instant)>,
    (now_ms, now): (u64, Instant),
) -> (Vec<Ask>, HashSet<String>, Option<Instant>) {
    let u64_of = |row: &Value, k: &str| row.get(k).and_then(Value::as_u64);
    let mut open: Vec<(&Value, u64)> = rows
        .iter()
        .filter(|row| {
            let status = row.get("status").and_then(Value::as_str);
            !matches!(status, Some("closed" | "unreachable"))
                && row.get("stale") != Some(&Value::Bool(true))
                && u64_of(row, "createdAt").is_some()
                && u64_of(row, "lastSeq").is_some_and(|s| s > 0)
        })
        .filter_map(|row| {
            let at = u64_of(row, "updatedAt")?;
            (at.saturating_add(WARM_WITHIN_MS) >= now_ms).then_some((row, at))
        })
        .collect();
    open.sort_by_key(|(_, at)| std::cmp::Reverse(*at));
    open.truncate(WARM_PER_PEER);
    let (mut asks, mut planned, mut later) = (Vec::new(), HashSet::new(), None::<Instant>);
    for (row, _) in open {
        let Some(mux) = row.get("sessionId").and_then(Value::as_str) else { continue };
        let (Some(generation), Some(last)) = (u64_of(row, "createdAt"), u64_of(row, "lastSeq"))
        else {
            continue;
        };
        planned.insert(mux.to_owned());
        let through = covers.get(mux).filter(|(g, _)| *g == Some(generation)).map(|(_, to)| *to);
        // A copy as far as the row: nothing to read. One past it (a peer back on an older disk
        // with the same session) is read again from the newest page, which replaces it
        // (`Store::behind`).
        if through == Some(last) {
            continue;
        }
        if let Some((read, at)) = read_at.get(&(peer.to_owned(), mux.to_owned()))
            && *read == generation
            && after(*at, WARM_EVERY) > now
        {
            let due = after(*at, WARM_EVERY);
            later = Some(later.map_or(due, |l| l.min(due)));
            continue;
        }
        // Past what the copy covers, when that joins it within one page; else the newest page,
        // which replaces a copy it does not reach.
        let (cursor, seq) =
            match through.filter(|to| *to < last && last.saturating_sub(*to) <= WARM_LIMIT) {
                Some(to) => ("afterSeq", to),
                None => ("beforeSeq", NEWEST),
            };
        let mut params = json!({"sessionId": mux, "limit": WARM_LIMIT, "maxBytes": WARM_BYTES,
                                "kinds": WARM_KINDS});
        if let Some(object) = params.as_object_mut() {
            object.insert(cursor.to_owned(), json!(seq));
        }
        asks.push(Ask { mux: mux.to_owned(), generation, params });
    }
    (asks, planned, later)
}

impl PeerSnapshots {
    /// The daemon stops: no chat is read ahead any more (`Warm::stop`).
    pub(crate) fn stop_warming(&self) {
        self.warm.stop();
    }

    /// What the copies of peer `peer` cover: each session's generation and last seq. Empty when
    /// the store does not answer within [`ANSWER_WITHIN`] or the queue is full.
    pub(crate) fn covers(&self, peer: &str) -> HashMap<String, (Option<u64>, u64)> {
        let (tx, rx) = mpsc::sync_channel(1);
        let sent = {
            let mut dropped = self.dropped();
            self.send_unsent(&mut dropped)
                && self.reserve(OP_BYTES)
                && self.enqueue(OP_BYTES, Op::Covers { peer: peer.to_owned(), reply: tx })
        };
        if !sent {
            return HashMap::new();
        }
        blocking(|| rx.recv_timeout(ANSWER_WITHIN)).unwrap_or_default()
    }
}

impl Store {
    pub(super) fn covers(&self, peer: &str) -> HashMap<String, (Option<u64>, u64)> {
        self.copies
            .iter()
            .filter(|(k, _)| k.0 == peer)
            .map(|(k, c)| (k.1.clone(), (c.head.generation, c.head.last_seq)))
            .collect()
    }
}

impl Hub {
    /// A client here opened a peer chat: from now on every peer's chats are read ahead.
    pub(crate) fn want_peer_copies(self: &Arc<Self>) {
        if self.peer_snapshots.warm.wanted.swap(true, Ordering::SeqCst) {
            return;
        }
        let peers: Vec<String> =
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        for peer in peers {
            self.warm_peer_copies(&peer);
        }
    }

    /// Peer `peer`'s rows changed (or it listed them): its round is due soon.
    pub(crate) fn warm_peer_copies(self: &Arc<Self>, peer: &str) {
        let warm = &self.peer_snapshots.warm;
        if !warm.wanted.load(Ordering::SeqCst) || self.peer_snapshots.dir.is_none() {
            return;
        }
        warm.due_by(peer, after(Instant::now(), WARM_SETTLE));
        if !warm.started.swap(true, Ordering::SeqCst) {
            tokio::spawn(warm_loop(Arc::downgrade(self)));
        }
        warm.kick.notify_one();
    }

    /// The rows peer `peer` lists now.
    fn peer_rows(&self, peer: &str) -> Vec<Value> {
        let rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        rows.values().filter(|r| r.peer == peer).map(|r| r.summary.clone()).collect()
    }

    /// One round of peer `peer`: reads what `plan` asks, one at a time, until the link refuses one.
    async fn warm_round(self: Arc<Self>, peer: String) {
        let warm = &self.peer_snapshots.warm;
        let later = match self.peer(&peer) {
            Some(link) => self.warm_reads(&link).await,
            None => {
                warm.state().read_at.retain(|k, _| k.0 != peer);
                None
            }
        };
        {
            let mut s = warm.state();
            s.running.remove(&peer);
        }
        if let Some(at) = later {
            warm.due_by(&peer, at);
        }
        warm.kick.notify_one();
    }

    async fn warm_reads(&self, peer: &crate::peer::Peer) -> Option<Instant> {
        let warm = &self.peer_snapshots.warm;
        let name = peer.name.as_str();
        // `covers` waits for the store's thread.
        let covers = self.peer_snapshots.covers(name);
        let rows = self.peer_rows(name);
        let (asks, later) = {
            let mut s = warm.state();
            let (asks, planned, later) =
                plan(name, &rows, &covers, &s.read_at, (now_ms(), Instant::now()));
            s.read_at.retain(|k, _| k.0 != name || planned.contains(&k.1));
            (asks, later)
        };
        let mut later = later;
        // Read again after the interval: a chat refused or not read to its end.
        let again = |later: &mut Option<Instant>| {
            let at = after(Instant::now(), WARM_EVERY);
            *later = Some(later.map_or(at, |l| l.min(at)));
        };
        for ask in asks {
            // Tried counts as read: a chat the peer refuses waits its interval too.
            let key = (name.to_owned(), ask.mux.clone());
            warm.state().read_at.insert(key, (ask.generation, Instant::now()));
            // The link the page is asked on, read before it, as the forward path does.
            let link = peer.link_epoch();
            let read = peer.request_on(method::MUX_EVENTS, ask.params.clone(), Some(link)).await;
            let mut page = match read {
                Ok(page) => page,
                // The link is down: nothing else of this peer is read this round; the link's
                // return starts the next.
                Err(e) if link_down(peer, &e) => return later,
                // This chat only (gone meanwhile, a page it cannot give): the next one is read,
                // and this one again after the interval.
                Err(_) => {
                    again(&mut later);
                    continue;
                }
            };
            let held = |r: &Value| r.get("events").and_then(Value::as_array).map(Vec::len);
            let before = held(&page);
            crate::server::strip_peer_asks(self, name, &ask.mux, method::MUX_EVENTS, &mut page);
            if held(&page) != before {
                continue;
            }
            {
                // Kept under the lock the stop takes, so no page is kept once the daemon stops
                // (its last flush comes after `Warm::stop`). The capture only queues the page.
                let s = warm.state();
                if s.stopped {
                    return None;
                }
                let on = (name, peer.generation, link, Some(ask.generation));
                self.capture_peer_page(on, (&ask.mux, true), &ask.params, &page);
            }
            // New records past the copy that did not fit one page: the rest is read after the
            // interval, one page a round (the plan continues from what the copy covers then).
            if cut_short(&ask.params, &page) {
                again(&mut later);
            }
        }
        later
    }
}

/// Whether `page`, a read past a copy asked with `params`, stopped short of the chat's newest
/// record (`hasMore`) after holding something new: a newest page is the chat's tail already.
pub(super) fn cut_short(params: &Value, page: &Value) -> bool {
    let Some(after) = params.get("afterSeq").and_then(Value::as_u64) else { return false };
    let events = page.get("events").and_then(Value::as_array);
    page.get("hasMore") != Some(&Value::Bool(false))
        && events.is_some_and(|e| e.iter().filter_map(seq_of).any(|seq| seq > after))
}

/// Whether `e` refused a read because peer `peer`'s link is down, not because of the chat.
fn link_down(peer: &crate::peer::Peer, e: &RpcError) -> bool {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    reason == Some("peer_unreachable") || !peer.connected.load(Ordering::SeqCst)
}

/// Starts each round when it is due, until the daemon stops or the hub goes.
async fn warm_loop(hub: Weak<Hub>) {
    loop {
        let Some(h) = hub.upgrade() else { return };
        let mut stop = h.peer_notices_stop.subscribe();
        if *stop.borrow() {
            return;
        }
        let kick = h.peer_snapshots.warm.kick.clone();
        let (ready, next) = h.peer_snapshots.warm.take_due(Instant::now());
        for peer in ready {
            let round = tokio::spawn(h.clone().warm_round(peer)).abort_handle();
            let mut s = h.peer_snapshots.warm.state();
            s.rounds.retain(|r| !r.is_finished());
            // A stop since `take_due` aborts it here: the stop drained the rounds already.
            if s.stopped {
                round.abort();
            } else {
                s.rounds.push(round);
            }
        }
        drop(h);
        // `notify_one` keeps a permit when nothing waits: no kick is lost before this wait.
        let until = next.map(tokio::time::Instant::from_std);
        tokio::select! {
            () = kick.notified() => {}
            () = async {
                match until {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            } => {}
            _ = stop.changed() => return,
        }
    }
}

#[cfg(test)]
#[path = "warm_tests.rs"]
mod tests;
