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
}
