//! The lane's half of the GitHub broker (`github_broker.rs`): which connected Macs lend this
//! machine their GitHub login, how each is doing, and the session row each decision leaves.
//!
//! A Mac says so in its `initialize` (`_meta.acpmux.githubBroker`), and only over a link that
//! proved this machine's peer token (`peer_auth.rs`: read over ssh); a Web, app or paired-device
//! connection saying it counts for nothing (`server/requests.rs`). The link counts once this
//! machine's answer to its `_acpmux/watch` is queued (`server/mod.rs`): the Mac opens its side
//! when it reads that answer, and every action goes out after it (`Conn::send_request_in_order`
//! refuses one while that answer still waits for room), so none reaches a Mac that would still
//! refuse it.
//!
//! Several Macs may lend at once, and each keeps an owner record here: the actions it is running
//! (when each started), how many in a row did not come back, and the longest one that did. An
//! action is asked of the healthiest open owner (`ranked`): first those not stalled (no action
//! running past twice the longest it ever answered, H15 of hq `remote-cloud-durability.md`), then
//! fewest failures in a row, then newest. One that stops answering (a wedged Mac, a dead link
//! that has not closed yet) is gone around by the next action instead of taking every one with
//! it until someone stops it by hand: the class-5 gap of hq `fleet-dogfoods-remote.md`, which the
//! fleet's `lane-gh-broker` standby fills today.

use super::{Hub, Session};
use crate::server::Conn;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};

/// One lending link and its record.
struct Owner<T> {
    link: Weak<T>,
    record: Record,
}

/// What this machine knows of one owner's progress.
#[derive(Default, Clone, Debug, PartialEq)]
pub(crate) struct Record {
    /// Actions it runs now, by call id: when each was sent (unix ms).
    running: HashMap<u64, u64>,
    /// Actions in a row that never came back (the link ended under it, or no answer in time).
    failures: u32,
    /// The longest an answered action took.
    longest_ok_ms: u64,
    last_ok_ms: Option<u64>,
}

/// An owner counts as stalled once an action of it runs past twice the longest it ever answered,
/// and at least this long: a Mac's `gh` takes seconds, a fresh owner has no history.
const STALL_FLOOR_MS: u64 = 15_000;

impl Record {
    fn stalled(&self, now_ms: u64) -> bool {
        let bound = (2 * self.longest_ok_ms).max(STALL_FLOOR_MS);
        self.running.values().any(|sent| now_ms.saturating_sub(*sent) > bound)
    }
}

/// How one call to an owner ended, for its record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// The Mac answered, whatever it said: GitHub refusing is still a Mac making progress.
    Answered,
    /// The request never left, or the Mac said it was busy: no mark against it.
    NotRun,
    /// Sent, and no answer came back.
    Lost,
}

pub(crate) struct Owners {
    list: Mutex<Vec<Owner<Conn>>>,
    next_call: std::sync::atomic::AtomicU64,
}

impl Default for Owners {
    fn default() -> Self {
        Self { list: Mutex::new(Vec::new()), next_call: 1.into() }
    }
}

/// How many lending links are kept; past that the oldest goes.
const OWNERS_MAX: usize = 16;

/// `new` becomes the newest of `list`, once: closed links and an earlier entry for it go. A link
/// listed again keeps its record.
fn register<T>(list: &mut Vec<Owner<T>>, new: &Arc<T>, open: impl Fn(&T) -> bool) {
    let mut record = Record::default();
    list.retain(|o| match o.link.upgrade() {
        Some(c) if Arc::ptr_eq(&c, new) => {
            record = o.record.clone();
            false
        }
        Some(c) => open(&c),
        None => false,
    });
    if list.len() >= OWNERS_MAX {
        list.remove(0);
    }
    list.push(Owner { link: Arc::downgrade(new), record });
}

/// The open owners, healthiest first (module docs).
fn ranked<T>(list: &[Owner<T>], open: impl Fn(&T) -> bool, now_ms: u64) -> Vec<Arc<T>> {
    let mut live: Vec<(usize, &Record, Arc<T>)> = list
        .iter()
        .enumerate()
        .filter_map(|(i, o)| o.link.upgrade().filter(|c| open(c)).map(|c| (i, &o.record, c)))
        .collect();
    live.sort_by_key(|(i, r, _)| (r.stalled(now_ms), r.failures, std::cmp::Reverse(*i)));
    live.into_iter().map(|(_, _, c)| c).collect()
}

fn find<'a, T>(list: &'a mut [Owner<T>], link: &Arc<T>) -> Option<&'a mut Record> {
    list.iter_mut()
        .find(|o| o.link.upgrade().is_some_and(|c| Arc::ptr_eq(&c, link)))
        .map(|o| &mut o.record)
}

fn begin<T>(list: &mut [Owner<T>], link: &Arc<T>, call: u64, now_ms: u64) {
    if let Some(r) = find(list, link) {
        r.running.insert(call, now_ms);
    }
}

fn end<T>(list: &mut [Owner<T>], link: &Arc<T>, call: u64, outcome: Outcome, now_ms: u64) {
    let Some(r) = find(list, link) else { return };
    let Some(sent) = r.running.remove(&call) else { return };
    match outcome {
        Outcome::Answered => {
            r.failures = 0;
            r.longest_ok_ms = r.longest_ok_ms.max(now_ms.saturating_sub(sent));
            r.last_ok_ms = Some(now_ms);
        }
        Outcome::NotRun => {}
        Outcome::Lost => r.failures = r.failures.saturating_add(1),
    }
}

/// One call asked of an owner: it counts as running on that owner's record until it ends, and
/// as lost if it is dropped unended (the asking session went away mid-call).
pub(crate) struct OwnerCall<'a> {
    hub: &'a Hub,
    link: Arc<Conn>,
    call: u64,
    ended: bool,
}

impl OwnerCall<'_> {
    pub(crate) fn link(&self) -> &Arc<Conn> {
        &self.link
    }
    pub(crate) fn end(mut self, outcome: Outcome) {
        self.ended = true;
        let mut list = self.hub.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
        end(&mut list, &self.link, self.call, outcome, crate::store::now_ms());
    }
}

impl Drop for OwnerCall<'_> {
    fn drop(&mut self) {
        if !self.ended {
            let mut list = self.hub.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
            end(&mut list, &self.link, self.call, Outcome::NotRun, crate::store::now_ms());
        }
    }
}

impl Hub {
    /// `conn` lends this machine its GitHub login (module docs).
    pub(crate) fn add_github_owner(&self, conn: &Arc<Conn>) {
        let mut owners = self.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
        register(&mut owners, conn, Conn::is_open);
        // Sessions spawned from now on get git, `gh` and GitHub MCP through it (slice 2).
        crate::github_broker::mark_lent_here();
    }

    /// The open links that lend their GitHub login, healthiest first.
    pub(crate) fn github_owner_links(&self) -> Vec<Arc<Conn>> {
        let owners = self.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
        ranked(&owners, Conn::is_open, crate::store::now_ms())
    }

    /// Start one call on `link`'s owner record.
    pub(crate) fn github_owner_call(&self, link: Arc<Conn>) -> OwnerCall<'_> {
        let call = self.github_owners.next_call.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut owners = self.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
        begin(&mut owners, &link, call, crate::store::now_ms());
        OwnerCall { hub: self, link, call, ended: false }
    }

    /// Each open owner's record, healthiest first, for a status read: no token, no output.
    pub(crate) fn github_owner_records(&self) -> Vec<Value> {
        let now = crate::store::now_ms();
        let owners = self.github_owners.list.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows: Vec<(bool, u32, std::cmp::Reverse<usize>, Value)> = owners
            .iter()
            .enumerate()
            .filter(|(_, o)| o.link.upgrade().is_some_and(|c| c.is_open()))
            .map(|(i, o)| {
                let r = &o.record;
                let row = json!({
                    "running": r.running.len(),
                    "failuresInARow": r.failures,
                    "longestOkMs": r.longest_ok_ms,
                    "lastOkMs": r.last_ok_ms,
                    "stalled": r.stalled(now),
                });
                (r.stalled(now), r.failures, std::cmp::Reverse(i), row)
            })
            .collect();
        rows.sort_by(|a, b| (a.0, a.1, a.2).cmp(&(b.0, b.1, b.2)));
        rows.into_iter().map(|r| r.3).collect()
    }

    /// One redacted broker decision, in the session's own event stream, so the app shows it
    /// beside the work that caused it.
    pub(crate) fn append_github_audit(&self, session: &Session, payload: Value) {
        self.append(session, "mux", "github_broker_action", payload);
    }
}

#[cfg(test)]
#[path = "github_owner_tests.rs"]
mod tests;
