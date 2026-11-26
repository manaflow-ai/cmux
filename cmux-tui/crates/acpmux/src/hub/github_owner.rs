//! The lane's half of the GitHub broker (`github_broker.rs`): which connected Macs lend this
//! machine their GitHub login, and the session row each decision leaves.
//!
//! A Mac says so in its `initialize` (`_meta.acpmux.githubBroker`), and only over a link that
//! proved this machine's peer token (`peer_auth.rs`: read over ssh); a Web, app or paired-device
//! connection saying it counts for nothing (`server/requests.rs`). The link counts once this
//! machine's answer to its `_acpmux/watch` is queued (`server/mod.rs`): the Mac opens its side
//! when it reads that answer, and every action goes out after it (`Conn::send_request_in_order`
//! refuses one while that answer still waits for room), so none reaches a Mac that would still
//! refuse it. Several Macs (or a Mac and the controller) may lend at once: the newest healthy
//! link is asked first, and the lane moves to the next when one is busy or stalls
//! (`server/github_lane.rs`).

use super::{Hub, Session};
use crate::server::Conn;
use serde_json::Value;
use std::sync::{Arc, Mutex, Weak};

/// The links that lend GitHub here, oldest first, each with when it last stalled (an action it
/// took that timed out or whose link ended mid-answer).
#[derive(Default)]
pub(crate) struct Owners(Mutex<Vec<Owner<Conn>>>);

pub(crate) struct Owner<T> {
    link: Weak<T>,
    stalled_ms: Option<u64>,
}

/// How many lending links are kept; past that the oldest goes.
const OWNERS_MAX: usize = 16;
/// How long a stall puts an owner behind the ones that did not stall.
pub(crate) const STALL_MS: u64 = 5 * 60_000;

/// `new` becomes the newest of `list`, once: closed links and an earlier entry for it go.
fn register<T>(list: &mut Vec<Owner<T>>, new: &Arc<T>, open: impl Fn(&T) -> bool) {
    list.retain(|o| o.link.upgrade().is_some_and(|c| open(&c) && !Arc::ptr_eq(&c, new)));
    if list.len() >= OWNERS_MAX {
        list.remove(0);
    }
    list.push(Owner { link: Arc::downgrade(new), stalled_ms: None });
}

/// The open links in the order they are asked: those with no stall within `STALL_MS` first, then
/// the rest; newest first within each.
fn ordered<T>(list: &[Owner<T>], now_ms: u64, open: impl Fn(&T) -> bool) -> Vec<Arc<T>> {
    let mut live: Vec<(bool, usize, Arc<T>)> = list
        .iter()
        .enumerate()
        .filter_map(|(i, o)| {
            let c = o.link.upgrade().filter(|c| open(c))?;
            let stalled = o.stalled_ms.is_some_and(|t| now_ms.saturating_sub(t) < STALL_MS);
            Some((stalled, usize::MAX - i, c))
        })
        .collect();
    live.sort_by_key(|(stalled, newer, _)| (*stalled, *newer));
    live.into_iter().map(|(_, _, c)| c).collect()
}

fn mark<T>(list: &mut [Owner<T>], link: &Arc<T>, stalled_ms: Option<u64>) {
    if let Some(o) =
        list.iter_mut().find(|o| o.link.upgrade().is_some_and(|c| Arc::ptr_eq(&c, link)))
    {
        o.stalled_ms = stalled_ms;
    }
}

impl Hub {
    /// `conn` lends this machine its GitHub login (module docs).
    pub(crate) fn add_github_owner(&self, conn: &Arc<Conn>) {
        let mut owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        register(&mut owners, conn, Conn::is_open);
        // Sessions spawned from now on get git, `gh` and GitHub MCP through it (slice 2).
        crate::github_broker::mark_lent_here();
    }

    /// The open links that lend their GitHub login, in the order to ask them: healthy ones
    /// first, newest first (`ordered`).
    pub(crate) fn github_owner_links(&self) -> Vec<Arc<Conn>> {
        let owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        ordered(&owners, crate::store::now_ms(), Conn::is_open)
    }

    /// `link` stalled on an action (`stalled`), or answered one (it is healthy again).
    pub(crate) fn github_owner_health(&self, link: &Arc<Conn>, stalled: bool) {
        let mut owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        mark(&mut owners, link, stalled.then(crate::store::now_ms));
    }

    /// One redacted broker decision, in the session's own event stream, so the app shows it
    /// beside the work that caused it.
    pub(crate) fn append_github_audit(&self, session: &Session, payload: Value) {
        self.append(session, "mux", "github_broker_action", payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// The review of the lane part at 1ea8bb6: each `initialize` on one link added it again.
    #[test]
    fn a_link_is_listed_once_and_the_list_stays_bounded() {
        let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
        let mut list = Vec::new();
        let link = Arc::new(AtomicBool::new(true));
        for _ in 0..100 {
            register(&mut list, &link, open);
        }
        assert_eq!(list.len(), 1);
        let others: Vec<_> = (0..40).map(|_| Arc::new(AtomicBool::new(true))).collect();
        for o in &others {
            register(&mut list, o, open);
        }
        assert_eq!(list.len(), OWNERS_MAX);
        others.last().unwrap().store(false, Ordering::SeqCst);
        register(&mut list, &link, open);
        assert!(Arc::ptr_eq(&list.last().unwrap().link.upgrade().unwrap(), &link));
        assert!(list.iter().all(|o| o.link.upgrade().is_some_and(|c| open(&c))));
    }

    /// Several Macs lend GitHub: the newest healthy one is asked first, one that stalled goes
    /// behind the rest until `STALL_MS` passes, and a closed one is not asked.
    #[test]
    fn a_stalled_owner_is_asked_last_and_a_closed_one_never() {
        let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
        let mut list = Vec::new();
        let (a, b, c) = (
            Arc::new(AtomicBool::new(true)),
            Arc::new(AtomicBool::new(true)),
            Arc::new(AtomicBool::new(true)),
        );
        for o in [&a, &b, &c] {
            register(&mut list, o, open);
        }
        let now = 1_000_000;
        let order = ordered(&list, now, open);
        assert!(Arc::ptr_eq(&order[0], &c) && Arc::ptr_eq(&order[2], &a));
        mark(&mut list, &c, Some(now));
        let order = ordered(&list, now + 1, open);
        assert!(Arc::ptr_eq(&order[0], &b) && Arc::ptr_eq(&order[2], &c));
        assert!(Arc::ptr_eq(&ordered(&list, now + STALL_MS, open)[0], &c), "the stall wears off");
        b.store(false, Ordering::SeqCst);
        assert_eq!(ordered(&list, now + 1, open).len(), 2);
        mark(&mut list, &c, None);
        assert!(Arc::ptr_eq(&ordered(&list, now + 1, open)[0], &c), "an answer clears it");
    }
}
