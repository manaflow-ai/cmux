//! Hosting of the history search index (`history-search-v1`).

use super::*;
use crate::history_search::HistorySearch;

impl Mux {
    /// Installs the search index once (the binary does this at startup with
    /// its feeds). A second install is refused and leaves the first in place.
    pub fn install_history_search(&self, service: HistorySearch) -> bool {
        self.history_search.set(service).is_ok()
    }

    /// The installed search index, if any.
    pub fn history_search(&self) -> Option<&HistorySearch> {
        self.history_search.get()
    }
}
