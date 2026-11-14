//! How a Cloud start waits for the app's first machine list. An app just launched answers its list
//! `loaded: false` until its first read after sign-in lands (the production chat probe, cmuxterm-hq run
//! 43553290380, got `cloud.list_unread` right after sign-in). Both starts ask here: the CLI's
//! `cmux cloud start-chat` (`loaded_list`) and the app's `CloudStartChat` (`machine(for:)`, op
//! `cloud_start_list_wait`); each only reads the list again and pauses as the answer says.

use std::time::Duration;

use serde::{Deserialize, Serialize};

/// How long a start waits for the app's first machine list before it answers the list unread.
pub const LIST_LOAD_WAIT: Duration = Duration::from_secs(60);

/// The pace between reads of a machine list the app has not loaded yet.
pub const LIST_LOAD_POLL: Duration = Duration::from_secs(2);

/// What a start does with the machine list it has read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "next", rename_all = "camelCase")]
pub enum ListWait {
    /// Go on with the list as read: it is loaded, or the app is signed out (the start's sign-in
    /// check refuses that at once, never after a wait).
    Proceed,
    /// Pause `pause_ms`, then read the list again when `read_after`; else only ask again (the wait
    /// ends within this pause, and a read started at its end would only run past it).
    #[serde(rename_all = "camelCase")]
    Pause { pause_ms: u64, read_after: bool },
    /// Still not loaded once the wait is over: the start refuses it as a list not read.
    Unread,
}

/// The step for a list read `elapsed` into the wait (counted from the first read's answer), with
/// `deadline_left` of the start's own deadline (`--timeout`; `None` with none): read again
/// [`LIST_LOAD_POLL`] apart while the list says `loaded: false` for a signed-in app, for at most
/// [`LIST_LOAD_WAIT`] and never past the deadline.
pub fn list_wait(
    elapsed: Duration,
    deadline_left: Option<Duration>,
    loaded: bool,
    signed_in: bool,
) -> ListWait {
    if loaded || !signed_in {
        return ListWait::Proceed;
    }
    // RED PROBE (not for merge): the core change reverted to the app's old refuse-at-once rule.
    if !loaded {
        return ListWait::Unread;
    }
    let left = LIST_LOAD_WAIT.saturating_sub(elapsed);
    let left = deadline_left.map_or(left, |deadline| deadline.min(left));
    if left.is_zero() {
        return ListWait::Unread;
    }
    let pause = LIST_LOAD_POLL.min(left);
    ListWait::Pause {
        pause_ms: u64::try_from(pause.as_millis()).unwrap_or(u64::MAX),
        read_after: pause < left,
    }
}

#[cfg(test)]
mod tests;
