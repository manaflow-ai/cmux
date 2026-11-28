//! A record's encodings its connections share while one sends them (`server::deliver`).

use serde_json::Value;
use std::sync::Arc;

/// One record's row ([`super::EventRow`]): a full row carries up to 512 time spans, the tools and
/// the MCP servers as `Value`s; a lane VM's ring held 1.6 million spans in 6.4 GB after 6 hours.
pub type SharedRow = Shared<Value>;

/// What one record's connections share as they send it (its row, its `session/update` line, its
/// `_acpmux/event` params), held only while one of them does: a weak share. The event ring and
/// every connection's queue keep up to 8,192 events each (`Events::new`) whatever their size, and
/// an encoding each event kept stayed until 8,192 later records pushed it out: a held row grew
/// huge-blue's daemon about 1.1 GB an hour (cmuxterm-hq#14649), and the line and params, a copy of
/// the record's whole message each, kept every big tool output two more times while the fleet's
/// daemons grew 520 to 900 MB an hour. The record itself is the one copy an event holds.
/// `T` is a sized value whose heap the last strong share frees: a `Weak<str>` would keep a line's
/// bytes in its allocation.
pub struct Shared<T>(std::sync::Mutex<std::sync::Weak<T>>);

impl<T> Default for Shared<T> {
    fn default() -> Self {
        Self(std::sync::Mutex::new(std::sync::Weak::new()))
    }
}

impl<T> std::fmt::Debug for Shared<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let held = self.0.lock().map(|w| w.strong_count() > 0).unwrap_or(false);
        f.debug_struct("Shared").field("held", &held).finish()
    }
}

impl<T> Shared<T> {
    /// The value a connection is still sending, else `build`'s, which the next one shares. None
    /// (`build` has none: a gone session, a line too large for one frame) is not kept.
    pub(crate) fn get_or_build(&self, build: impl FnOnce() -> Option<T>) -> Option<Arc<T>> {
        let mut held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(value) = held.upgrade() {
            return Some(value);
        }
        let value = Arc::new(build()?);
        *held = Arc::downgrade(&value);
        Some(value)
    }

    /// Whether a connection still holds what it shares (tests).
    #[cfg(test)]
    pub(crate) fn held(&self) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).strong_count() > 0
    }
}
