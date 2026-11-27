//! The session tree's chat history (`sidebar.sessionTree`, hq#2569 #6), moved from Swift's
//! `SidebarChatHistoryState` (`make`, `showsLoading`, `pinnedHeight`, `earlierHeight`): the pinned
//! chats above the tree, and the Earlier page of every chat no open workspace shows, newest first.
//! Metadata only (key, title, last activity, harness), never a transcript.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// One chat of acpmux's index as the history lists it (`SidebarHistoryChat`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Chat {
    pub id: String,
    pub title: String,
    /// Last activity, seconds since 1970.
    pub updated_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
}

/// The history the sidebar draws (`SidebarChatHistoryState`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct History {
    pub pinned: Vec<Chat>,
    /// The page of Earlier shown; empty while folded.
    pub earlier: Vec<Chat>,
    /// Earlier has a chat to list (its header shows, folded or not).
    pub has_earlier: bool,
    /// More chats wait past the page (Show More).
    pub has_more: bool,
    pub earlier_folded: bool,
    /// acpmux has not sent Earlier's rows yet: Earlier keeps its header and one Loading row.
    pub loading: bool,
}

impl History {
    /// Earlier shows its Loading row: still loading, unfolded, with no row of its own yet.
    pub fn shows_loading(&self) -> bool {
        self.loading && self.earlier.is_empty() && !self.earlier_folded
    }

    /// The Pinned block: its header and one row per chat; 0 without pins.
    pub fn pinned_height(&self, m: &Metrics) -> f64 {
        if self.pinned.is_empty() {
            return 0.0;
        }
        m.section_header_height + self.pinned.len() as f64 * (m.row_height + m.row_spacing)
    }

    /// The Earlier block: its header, the page's rows and the Show More or Loading row; 0 with
    /// nothing earlier.
    pub fn earlier_height(&self, m: &Metrics) -> f64 {
        if !self.has_earlier {
            return 0.0;
        }
        if self.earlier_folded {
            return m.section_header_height;
        }
        let extra = usize::from(self.has_more || self.shows_loading());
        m.section_header_height
            + (self.earlier.len() + extra) as f64 * (m.row_height + m.row_spacing)
    }
}

/// The list metrics the heights read (`SidebarLayoutMetrics`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Metrics {
    pub section_header_height: f64,
    pub row_height: f64,
    pub row_spacing: f64,
}

/// The history of `newest` (acpmux's Earlier window, newest first, read until the page is full).
/// `known` finds a pinned chat outside the page; `live` are the chats an open workspace shows;
/// `pinned` the pinned keys in pin order; `more` that acpmux has chats past the window.
#[allow(clippy::too_many_arguments)]
pub fn make(
    newest: &[Chat],
    known: &BTreeMap<String, Chat>,
    live: &BTreeSet<String>,
    pinned: &[String],
    limit: i64,
    folded: bool,
    more: bool,
    loading: bool,
) -> History {
    let mut state =
        History { earlier_folded: folded, loading, has_earlier: loading, ..History::default() };
    state.pinned = pinned.iter().filter_map(|key| known.get(key).cloned()).collect();
    let wanted = if folded { 0 } else { usize::try_from(limit.max(0)).unwrap_or(usize::MAX) };
    for chat in newest.iter().filter(|chat| !live.contains(&chat.id) && !pinned.contains(&chat.id))
    {
        state.has_earlier = true;
        if state.earlier.len() >= wanted {
            break;
        }
        state.earlier.push(chat.clone());
        if state.earlier.len() == wanted {
            break;
        }
    }
    state.has_more = more && !folded;
    if state.has_more {
        state.has_earlier = true;
    }
    state
}

/// A request to the `sidebar_chat_history` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{history, shows_loading, pinned_height, earlier_height}`.
    Make {
        #[serde(default)]
        newest: Vec<Chat>,
        #[serde(default)]
        known: BTreeMap<String, Chat>,
        #[serde(default)]
        live: BTreeSet<String>,
        #[serde(default)]
        pinned: Vec<String>,
        limit: i64,
        #[serde(default)]
        folded: bool,
        #[serde(default)]
        more: bool,
        #[serde(default)]
        loading: bool,
        #[serde(default)]
        metrics: Metrics,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Make { newest, known, live, pinned, limit, folded, more, loading, metrics } => {
            let history = make(&newest, &known, &live, &pinned, limit, folded, more, loading);
            json!({
                "shows_loading": history.shows_loading(),
                "pinned_height": history.pinned_height(&metrics),
                "earlier_height": history.earlier_height(&metrics),
                "history": history,
            })
        }
    }
}

#[cfg(test)]
#[path = "sidebar_chat_history_tests.rs"]
mod tests;
