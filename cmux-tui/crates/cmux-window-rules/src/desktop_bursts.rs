//! Agent-finished banners that land in one burst, per workspace (cx-kz6m0.1,
//! parity with the old app's coalescing queue; RFC #20891 proposal 3).
//!
//! The first finished turn in a workspace opens a burst (the app's one-shot
//! timer closes it after its window); while it is open, each other unread
//! agent that finishes there replaces every banner the burst still shows with
//! one digest that counts them ("3 agents finished") and opens the newest.
//! One agent finishing again is not a burst, and an agent the person read
//! leaves it. The digest is filed under the newest agent's tab. Approvals,
//! questions and errors never come here.
//!
//! The app keeps each workspace's [`Burst`] and its timer, and sends the
//! burst with each step.

use serde::{Deserialize, Serialize};

/// The prefix of a daemon notification's banner id (the notification number follows).
pub const TAB_BANNER_PREFIX: &str = "cmux-notification-";

/// A banner the burst still shows, and the tab it is filed under.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Showing {
    pub id: String,
    pub tab: String,
}

/// One workspace's open burst.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Burst {
    /// Unread tabs whose agents finished in it, each once.
    pub tabs: Vec<String>,
    /// Its banners still showing, oldest first.
    pub showing: Vec<Showing>,
}

/// A finished turn that joins: its banner becomes a digest of `count` agents,
/// replacing the banners `replacing`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Digest {
    pub count: usize,
    pub replacing: Vec<String>,
}

/// What joining did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Joined {
    /// The burst to keep; none: the notification does not join (the app opens
    /// no burst for it and keeps the one it had).
    pub burst: Option<Burst>,
    /// None: the banner posts on its own.
    pub digest: Option<Digest>,
}

/// One notification for the burst.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Arrival {
    /// The daemon's notification number (its banner is [`TAB_BANNER_PREFIX`] and it).
    pub notification: u64,
    /// An agent's turn completion (the agent source's info level).
    pub finished_turn: bool,
    /// It has a Reply field.
    pub reply: bool,
    /// The tab it is on.
    pub tab: String,
}

/// Adds `arrival` to `burst` (none: the workspace has no burst open, and one
/// opens) when it is a finished turn without a reply field. A digest only
/// while another unread agent's banner is still showing.
pub fn join(burst: Option<Burst>, arrival: &Arrival) -> Joined {
    if !arrival.finished_turn || arrival.reply {
        return Joined { burst: None, digest: None };
    }
    let mut burst = burst.unwrap_or_default();
    if !burst.tabs.contains(&arrival.tab) {
        burst.tabs.push(arrival.tab.clone());
    }
    let banner = Showing {
        id: format!("{TAB_BANNER_PREFIX}{}", arrival.notification),
        tab: arrival.tab.clone(),
    };
    let others = burst.showing.iter().any(|shown| shown.tab != arrival.tab);
    if !others {
        burst.showing.push(banner);
        return Joined { burst: Some(burst), digest: None };
    }
    let replacing = std::mem::replace(&mut burst.showing, vec![banner])
        .into_iter()
        .map(|shown| shown.id)
        .collect();
    let digest = Digest { count: burst.tabs.len(), replacing };
    Joined { burst: Some(burst), digest: Some(digest) }
}

/// What reading a tab left of a burst.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Read {
    pub burst: Burst,
    /// The burst is left empty: it closes (the app cancels its timer).
    pub closes: bool,
}

/// The person read `tab`: its agent leaves `burst`, and a burst left empty closes.
pub fn read(mut burst: Burst, tab: &str) -> Read {
    burst.tabs.retain(|held| held != tab);
    burst.showing.retain(|shown| shown.tab != tab);
    let closes = burst.tabs.is_empty();
    Read { burst, closes }
}

#[cfg(test)]
#[path = "desktop_bursts_tests.rs"]
mod tests;
