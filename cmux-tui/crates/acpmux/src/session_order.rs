//! The session list's order (`hub/session_pages.rs`), which the CLI keeps when it joins pages
//! (`client.rs`), and what paging reads of a row.

use serde_json::Value;

/// Sorts session summaries newest first, ties by `sessionId` ascending, then by `peer` (this
/// daemon's own first): a chat here and its copy on a peer keep one order. The summaries are
/// snapshots, so the order is total while sorting.
pub(crate) fn sort_session_summaries(list: &mut [Value]) {
    list.sort_by(|a, b| {
        b.updated_ms()
            .cmp(&a.updated_ms())
            .then_with(|| a.session_id().cmp(b.session_id()))
            .then_with(|| a.peer().cmp(&b.peer()))
    });
}

/// What paging reads of a row: its id, `updatedAt`, `peer` and `status`. A built summary has
/// them as fields; a row not built yet (`page_first.rs`) has them from the session's metadata or
/// the peer's mirrored row, so a page is picked before any of its rows is built.
pub(crate) trait PageRow {
    fn session_id(&self) -> &str;
    fn updated_ms(&self) -> u64;
    fn peer(&self) -> Option<&str>;
    fn status(&self) -> Option<&str>;
    /// Whether a chat list shows it on its own (`_acpmux/sessions {topLevelOnly}`): not a side
    /// chat and not a session another chat's agent started ([`top_level_summary`]).
    fn top_level(&self) -> bool;
}

impl<R: PageRow + ?Sized> PageRow for &R {
    fn session_id(&self) -> &str {
        (**self).session_id()
    }

    fn updated_ms(&self) -> u64 {
        (**self).updated_ms()
    }

    fn peer(&self) -> Option<&str> {
        (**self).peer()
    }

    fn status(&self) -> Option<&str> {
        (**self).status()
    }

    fn top_level(&self) -> bool {
        (**self).top_level()
    }
}

impl PageRow for Value {
    fn session_id(&self) -> &str {
        self.get("sessionId").and_then(Value::as_str).unwrap_or("")
    }

    fn updated_ms(&self) -> u64 {
        self.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
    }

    fn peer(&self) -> Option<&str> {
        self.get("peer").and_then(Value::as_str)
    }

    fn status(&self) -> Option<&str> {
        self.get("status").and_then(Value::as_str)
    }

    fn top_level(&self) -> bool {
        top_level_summary(self)
    }
}

/// Whether a chat list shows the chat `summary` describes on its own, the rule every list's
/// `topLevelOnly` read keeps (the phone's lists, which used to apply it in Swift): not a side chat
/// (a `side` tag, `hub/btw.rs`) and no session another chat's agent started (`spawnedBy`, or a
/// sub-session's `startedBy`, which stays set after its parent closes: it lists under its
/// parent).
pub(crate) fn top_level_summary(summary: &Value) -> bool {
    let set = |value: Option<&Value>| value.is_some_and(|value| !value.is_null());
    let named = |key: &str| summary.get(key).and_then(Value::as_str).is_some_and(|v| !v.is_empty());
    !set(summary.get("tags").and_then(|tags| tags.get("side")))
        && !named("spawnedBy")
        && !named("startedBy")
}
