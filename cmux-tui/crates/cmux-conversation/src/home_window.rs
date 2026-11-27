//! A window of the Home list, built row by row only for the rows it shows.
//!
//! [`home_inbox`](crate::home_inbox) builds every row (its name, preview,
//! unread count, a Chief's state) and then sorts them, so a phone that asks
//! for its first screen of 30 rows paid for all of them. A row's place in the
//! list depends only on its pin, its activity time and its id
//! ([`SortKey`]); and whether it is listed at all, on its participants. So
//! [`HomeOrder`] orders the conversation heads by those alone, once, and a
//! window ([`HomeWindow`]) builds only its own rows: open costs the window,
//! not the list. The order can be kept and reused until the store changes
//! (the owner's cache, `conversation_store.rs` `home_order`).
//!
//! Equivalence: for any data, `HomeOrder::rows` of a window equals the same
//! cut of [`home_inbox`](crate::home_inbox) (`tests` below, random data).

use std::collections::{BTreeSet, HashMap};

use crate::home::{SortKey, activity_key, build_row, channels_of, listed};
use crate::{HomeInboxInput, HomeRow, Summary};

/// One conversation's head as the order reads it: the summary (its last
/// message may be left out) and its activity time (the last message's time,
/// a deleted one too, else `updated_at`).
#[derive(Debug, Clone, Copy)]
pub struct HomeHead<'a> {
    pub summary: &'a Summary,
    pub activity_at: &'a str,
}

impl<'a> HomeHead<'a> {
    /// The head of a whole summary (with its last message).
    pub fn of(summary: &'a Summary) -> Self {
        Self { summary, activity_at: crate::home::activity_of(summary) }
    }
}

/// What part of the list a read asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HomeWindow {
    /// `limit` rows from `offset`.
    Range { offset: usize, limit: usize },
    /// The rows of these conversations, each with its index in the list.
    Ids(Vec<String>),
}

/// Which conversations a window's list holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum HomeScope {
    /// Every listed conversation (the Mac's own Home).
    #[default]
    All,
    /// Only conversations between `user_local` (human) and plain `agent_`
    /// ids (kind agent): the rule a paired phone's link policy narrows to
    /// (`cmux-mobile-host` `chief_policy::in_scope`), so positions, `total`
    /// and `order` are the phone's own list.
    OwnerAndAgents,
}

impl HomeScope {
    /// Whether `summary` is in this scope.
    pub fn holds(self, summary: &Summary) -> bool {
        match self {
            Self::All => true,
            Self::OwnerAndAgents => owner_and_agents(summary),
        }
    }
}

/// True for a conversation between `user_local` (human) and plain `agent_`
/// ids only: exactly `chief_policy::in_scope`.
pub fn owner_and_agents(summary: &Summary) -> bool {
    let mut has_owner = false;
    for participant in &summary.participants {
        if participant.id == "user_local" && participant.kind == crate::ParticipantKind::Human {
            has_owner = true;
        } else if !(participant.kind == crate::ParticipantKind::Agent
            && plain_agent_id(&participant.id))
        {
            return false;
        }
    }
    has_owner
}

/// `agent_` then 1-64 ASCII letters, digits, `_` or `-`.
fn plain_agent_id(id: &str) -> bool {
    id.strip_prefix("agent_").is_some_and(|rest| {
        !rest.is_empty()
            && rest.len() <= 64
            && rest.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    })
}

/// The list order of one caller's Home rows, without the rows.
#[derive(Debug, Clone, Default)]
pub struct HomeOrder {
    ids: Vec<String>,
    index: HashMap<String, usize>,
    channels: BTreeSet<String>,
}

impl HomeOrder {
    /// The order of `heads` for `input.me`: exactly the order (and the rows)
    /// [`home_inbox`](crate::home_inbox) gives. Reads only ids, participants,
    /// titles, times and the caller's pins.
    pub fn new(heads: &[HomeHead<'_>], input: &HomeInboxInput<'_>) -> Self {
        Self::scoped(heads, input, HomeScope::All)
    }

    /// The order of the rows in `scope`: the same order with the rows out
    /// of scope left out. Channels are found over every head, as the whole
    /// list's rows are.
    pub fn scoped(heads: &[HomeHead<'_>], input: &HomeInboxInput<'_>, scope: HomeScope) -> Self {
        let channels = channels_of(heads.iter().map(|head| head.summary), input.me);
        let held: Vec<&HomeHead<'_>> = heads
            .iter()
            .filter(|head| scope.holds(head.summary) && listed(head.summary, input, &channels))
            .collect();
        // Each time's sort key once, not on every comparison (a sort of N
        // heads compares N log N times): the key of a key is itself.
        let times: Vec<std::borrow::Cow<'_, str>> =
            held.iter().map(|head| activity_key(head.activity_at)).collect();
        let mut keyed: Vec<SortKey<'_>> = held
            .iter()
            .zip(&times)
            .map(|(head, time)| {
                let state = input.states.get(&head.summary.id).copied().unwrap_or_default();
                SortKey {
                    pinned: state.pinned,
                    pin_position: state.pin_position.filter(|_| state.pinned),
                    activity_at: time,
                    id: &head.summary.id,
                }
            })
            .collect();
        keyed.sort_by(SortKey::cmp_list);
        let ids: Vec<String> = keyed.iter().map(|key| key.id.to_owned()).collect();
        let index = ids.iter().enumerate().map(|(at, id)| (id.clone(), at)).collect();
        Self { ids, index, channels }
    }

    /// Rows in the whole list.
    pub fn total(&self) -> usize {
        self.ids.len()
    }

    /// The list's ids in order.
    pub fn ids(&self) -> &[String] {
        &self.ids
    }

    /// The window's rows as (index in the list, id), in list order. An id
    /// not in the list is left out.
    pub fn select(&self, window: &HomeWindow) -> Vec<(usize, &str)> {
        match window {
            HomeWindow::Range { offset, limit } => self
                .ids
                .iter()
                .enumerate()
                .skip(*offset)
                .take(*limit)
                .map(|(at, id)| (at, id.as_str()))
                .collect(),
            HomeWindow::Ids(asked) => {
                let mut found: Vec<(usize, &str)> = asked
                    .iter()
                    .filter_map(|id| {
                        let at = *self.index.get(id)?;
                        Some((at, self.ids.get(at)?.as_str()))
                    })
                    .collect();
                found.sort_unstable();
                found.dedup();
                found
            }
        }
    }

    /// The Home row of one listed conversation (`summary` whole, with its
    /// last message).
    pub fn row(&self, summary: &Summary, input: &HomeInboxInput<'_>) -> HomeRow {
        build_row(summary, input, &self.channels)
    }

    /// The list's order as one digest: FNV-1a 64 over each row id and a
    /// newline, lowercase hex (the phone policy's `order`).
    pub fn digest(&self) -> String {
        order_digest(self.ids.iter().map(String::as_str))
    }
}

/// FNV-1a 64 over each id and a newline, lowercase hex.
pub fn order_digest<'a>(ids: impl IntoIterator<Item = &'a str>) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for id in ids {
        for byte in id.bytes().chain(std::iter::once(b'\n')) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    format!("{hash:x}")
}

/// A window of `summaries`' Home rows, each with its index in the list, and
/// the list's length: the rows built are the window's only.
pub fn home_inbox_window(
    summaries: &[Summary],
    input: &HomeInboxInput<'_>,
    window: &HomeWindow,
) -> (Vec<(usize, HomeRow)>, usize) {
    let heads: Vec<HomeHead<'_>> = summaries.iter().map(HomeHead::of).collect();
    let order = HomeOrder::new(&heads, input);
    let by_id: HashMap<&str, &Summary> =
        summaries.iter().map(|summary| (summary.id.as_str(), summary)).collect();
    let rows = order
        .select(window)
        .into_iter()
        .filter_map(|(at, id)| by_id.get(id).map(|summary| (at, order.row(summary, input))))
        .collect();
    (rows, order.total())
}

#[cfg(test)]
#[path = "home_window_tests.rs"]
mod tests;
