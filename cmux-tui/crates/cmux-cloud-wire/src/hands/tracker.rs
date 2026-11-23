//! The waiting requests one app follows: the socket's frames and the list
//! read after each subscribe, merged so neither drops nor repeats a request.
//!
//! - A request the socket brings while a list read runs is never dropped by
//!   that read (it arrived after the read began).
//! - A request that ended here is never posted again by a read that started
//!   earlier (ended keys are kept 10 minutes).
//! - A request a read no longer lists, and that arrived before the read
//!   began, ended while the socket was away: it settles with no outcome.

use std::collections::BTreeMap;

use super::{HandApproval, HandOutcome, HandSummary};

/// How long an ended key keeps a later list read from posting it again.
pub const ENDED_KEEP_MS: u64 = 600_000;

/// What the app shows changes.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    /// A request now waits: post its banner (`name` is the hand's, for the title).
    Pending { approval: HandApproval, name: String },
    /// A request ended (no outcome: the app stopped following it): withdraw its banner.
    Settled { approval: HandApproval, outcome: Option<HandOutcome> },
}

#[derive(Debug, Default)]
pub struct Tracker {
    hands: Vec<HandSummary>,
    /// Each waiting request with the time (a monotonic ms clock) it arrived here.
    pending: BTreeMap<String, (HandApproval, u64)>,
    /// When each request ended here.
    ended: BTreeMap<String, u64>,
}

impl Tracker {
    pub fn hands(&self) -> &[HandSummary] {
        &self.hands
    }

    /// The waiting requests, oldest first.
    pub fn pending(&self) -> Vec<&HandApproval> {
        let mut list: Vec<&HandApproval> =
            self.pending.values().map(|(approval, _)| approval).collect();
        list.sort_by(|a, b| a.at.total_cmp(&b.at));
        list
    }

    pub fn approval(&self, key: &str) -> Option<&HandApproval> {
        self.pending.get(key).map(|(approval, _)| approval)
    }

    /// The name people see for `hand`: its name, else its id.
    pub fn name_of(&self, hand: &str) -> String {
        self.hands
            .iter()
            .find(|h| h.hand == hand)
            .map_or(hand, HandSummary::display_name)
            .to_owned()
    }

    /// The hands a list read asks for their waiting requests.
    pub fn hands_to_read(hands: &[HandSummary]) -> Vec<String> {
        hands.iter().filter(|h| h.may_wait()).map(|h| h.hand.clone()).collect()
    }

    /// A request arrived (socket or read): a change unless it waits already.
    pub fn add(&mut self, approval: HandApproval, now: u64) -> Option<Change> {
        if self.pending.contains_key(&approval.key) {
            return None;
        }
        let name = self.name_of(&approval.hand);
        self.pending.insert(approval.key.clone(), (approval.clone(), now));
        Some(Change::Pending { approval, name })
    }

    /// A request ended. The key is remembered even when it was not waiting here.
    pub fn settle(&mut self, key: &str, outcome: Option<HandOutcome>, now: u64) -> Option<Change> {
        self.ended.insert(key.to_owned(), now);
        let (approval, _) = self.pending.remove(key)?;
        Some(Change::Settled { approval, outcome })
    }

    /// The hands a read listed (set before its waiting requests are read, so they post with names).
    pub fn set_hands(&mut self, hands: Vec<HandSummary>) {
        self.hands = hands;
    }

    /// The rows of a read that failed part way: each is added (unless it ended), and
    /// nothing is taken away, since the read did not see every hand.
    pub fn partly_read(&mut self, listed: Vec<HandApproval>, now: u64) -> Vec<Change> {
        let mut changes = Vec::new();
        for approval in listed {
            if !self.ended.contains_key(&approval.key) {
                changes.extend(self.add(approval, now));
            }
        }
        changes
    }

    /// A list read that began at `began` listed `listed`.
    pub fn refreshed(&mut self, began: u64, listed: Vec<HandApproval>, now: u64) -> Vec<Change> {
        let mut changes = Vec::new();
        let mut seen = std::collections::BTreeSet::new();
        for approval in listed {
            if self.ended.contains_key(&approval.key) {
                continue;
            }
            seen.insert(approval.key.clone());
            changes.extend(self.add(approval, now));
        }
        let gone: Vec<String> = self
            .pending
            .iter()
            .filter(|(key, (_, arrived))| !seen.contains(*key) && *arrived < began)
            .map(|(key, _)| key.clone())
            .collect();
        for key in gone {
            changes.extend(self.settle(&key, None, now));
        }
        self.ended.retain(|_, at| now.saturating_sub(*at) < ENDED_KEEP_MS);
        changes
    }

    /// Stops following: every waiting request settles with no outcome, the hands go.
    pub fn clear(&mut self) -> Vec<Change> {
        self.hands.clear();
        std::mem::take(&mut self.pending)
            .into_values()
            .map(|(approval, _)| Change::Settled { approval, outcome: None })
            .collect()
    }
}
