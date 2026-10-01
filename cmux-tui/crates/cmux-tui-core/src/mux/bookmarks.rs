//! Bookmarks of the home session (plans/cmux-next/bookmarks.md section 2.1,
//! `bookmarks-v1`). The durable rows live in the workspace registry
//! (`workspace_registry/personal_bookmarks.rs`); each committed change wakes
//! journal readers and emits `bookmarks-changed` with the browser profile
//! and the new `bookmarks_revision`, after which frontends refetch
//! `list-bookmarks`.

use super::*;

impl Mux {
    /// The `bookmarks_revision` and every node of one profile's tree.
    pub fn list_bookmarks(
        &self,
        browser_profile_id: &str,
    ) -> anyhow::Result<(u64, Vec<crate::workspace_registry::Bookmark>)> {
        self.workspace_registry.lock().unwrap().list_bookmarks(browser_profile_id)
    }

    /// Run one bookmark mutation under the registry lock. The mutation
    /// returns the browser profile whose tree changed, or `None` when it
    /// changed nothing; then journal readers and subscribers are notified.
    pub(crate) fn bookmarks_mutation<T>(
        &self,
        mutation: impl FnOnce(&mut WorkspaceRegistry) -> anyhow::Result<(T, Option<String>)>,
    ) -> anyhow::Result<(T, bool)> {
        let (value, changed, revision) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let (value, changed) = mutation(&mut registry)?;
            let revision = registry.bookmarks_revision()?;
            (value, changed, revision)
        };
        let Some(browser_profile_id) = changed else {
            return Ok((value, false));
        };
        self.publish_journal_event();
        self.emit_bookmarks_changed(browser_profile_id, revision);
        Ok((value, true))
    }

    /// Announce a committed change to one profile's bookmark tree. The
    /// caller has already notified journal readers.
    pub(crate) fn emit_bookmarks_changed(&self, browser_profile_id: String, revision: u64) {
        self.emit(MuxEvent::BookmarksChanged { browser_profile_id, bookmarks_revision: revision });
    }
}
