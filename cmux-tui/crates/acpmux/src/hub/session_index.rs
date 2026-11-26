//! Part of `Hub`; see `hub/mod.rs`. The session table's reads: the index of live sessions, the
//! handles and counts every list and sweep takes.

use super::*;

impl Hub {
    /// Keep the hot-path index in step with a session's status. The complete session map is
    /// intentionally retained so an explicit history/restore lookup can still load a closed chat.
    pub(crate) fn update_live_session_index(&self, session: &Session) {
        let mut live = self.live_session_ids.lock().unwrap_or_else(|e| e.into_inner());
        if session.status() == SessionStatus::Closed {
            live.remove(&session.id);
        } else {
            live.insert(session.id.clone());
        }
    }

    pub(crate) fn remove_live_session_index(&self, id: &str) {
        self.live_session_ids.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        // A purged session leaves the map; a replacement may take its id.
        self.chat_activity_cache.invalidate();
    }

    /// The sessions the daemon may need to summarize on a hot path. Closed records are looked up
    /// from `sessions` only by an explicit id/name request.
    pub(crate) fn indexed_live_sessions(&self) -> Vec<Arc<Session>> {
        newest_first(self.live_session_handles())
    }

    /// The sessions that are not closed, in no order and with no metadata read: the ones that
    /// may hold an agent or run a turn (a close ends both before its status). A timer that takes
    /// the first deadline of these reads them, not every closed record too.
    pub(crate) fn live_session_handles(&self) -> Vec<Arc<Session>> {
        // The ids are copied and that lock let go at the end of this statement, before `sessions`
        // is taken: never both at once, so no order against a purge (which holds `sessions`
        // while it updates the index) can deadlock.
        let ids: Vec<String> = self
            .live_session_ids
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned()
            .collect();
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        ids.into_iter().filter_map(|id| sessions.get(&id).cloned()).collect()
    }

    /// How many sessions the map holds, and how many of them are not closed, each read under
    /// its own lock (never both at once, as [`Hub::live_session_handles`]): not one snapshot.
    pub(crate) fn session_counts(&self) -> (usize, usize) {
        let live = self.live_session_ids.lock().unwrap_or_else(|e| e.into_inner()).len();
        let all = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).len();
        // An evicted chat counts as it did in memory: live unless closed (`evict.rs`).
        (all + self.evicted.len(), live + self.evicted.live_len())
    }

    // ------------------------------------------------------------ lookup

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        newest_first(self.session_handles())
    }

    /// Every session, in no order and with no metadata read.
    pub(crate) fn session_handles(&self) -> Vec<Arc<Session>> {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect()
    }

    /// Connect the optional v2 list tee. The v1 event path remains unchanged when no tee is
    /// installed, which is the default for an empty `acpmux.v2` setting.
    pub(crate) fn install_v2_tee(&self, tee: Arc<list_tee::TeeHandle>) {
        self.events.install_tee(tee);
    }

    /// The v2 list holds the hub machines' rows: `initialize` names
    /// [`list_tee::HUB_ROWS_FEATURE`] on every connection.
    pub(crate) fn v2_lists_hub_rows(&self) -> bool {
        self.events.tee_lists_hub_rows()
    }

    /// Every chat this daemon has, in memory or evicted (`evict.rs`).
    pub(crate) fn session_count(&self) -> usize {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).len() + self.evicted.len()
    }
}
