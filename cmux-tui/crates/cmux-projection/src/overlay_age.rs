//! Cold-tier aging of an overlay's content store ([`content::Content::age`]): bytes no chat read
//! for [`content::COLD_AFTER`] go cold (compressed), and are deleted [`content::DELETE_AFTER`]
//! after their last read unless a pin covers them. The reaper runs it on its timer, so the store
//! holds what chats read lately, not everything they ever read.

use std::time::SystemTime;

use super::*;
use content::{AgeReport, Aging};

impl Overlay {
    /// One aging pass over this overlay's content store at `now`; `None` without a store. Every
    /// blob of a pinned file is kept as it is.
    pub fn age(&self, now: SystemTime, aging: &Aging) -> Option<AgeReport> {
        let content = self.content.as_ref()?;
        let (files, _) = self.pinned_files();
        let pinned: HashSet<content::Name> = files
            .iter()
            .filter_map(|file| Some((*file, self.manifest.entry(*file)?.size)))
            .flat_map(|(file, size)| Self::keys_of(file, size))
            .filter_map(|key| self.content_name(key))
            .collect();
        Some(content.age(now, aging, &pinned))
    }
}

#[cfg(test)]
#[path = "overlay_age_tests.rs"]
mod tests;
