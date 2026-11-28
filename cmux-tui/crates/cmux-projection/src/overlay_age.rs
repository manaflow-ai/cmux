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

/// One aging pass over the content store of a projection no daemon has mounted, in its state
/// folder `state`; `None` when it has no store (none is made).
///
/// With no live overlay there is no manifest to resolve pins to files, so the pins come from the
/// state folder's persisted [`pin::PINS_FILE`], the list a mount reads back
/// ([`pin::read_pins`]): every name at or under a pinned path is kept, whatever its size or
/// mtime (a superset of what the mount would pin). When that file cannot be read, nothing is
/// known to be unpinned, so the pass only compresses ([`Aging::compress_only`]) and deletes
/// nothing; a cold blob still thaws on its next read. The caller keeps the projection unmounted
/// for the pass (two stores over one folder would race on its index).
pub fn age_unmounted(state: &Path, now: SystemTime, aging: &Aging) -> Option<AgeReport> {
    let dir = state.join("content");
    if !dir.join("blobs").is_dir() {
        return None;
    }
    let content = content::Content::open(&dir)?;
    let (pinned, aging) = match pin::read_pins(&state.join(pin::PINS_FILE)) {
        Ok(pins) => {
            let under = |path: &str| {
                pins.iter().any(|pin| {
                    pin.is_empty()
                        || path == pin
                        || path.strip_prefix(pin.as_str()).is_some_and(|rest| rest.starts_with('/'))
                })
            };
            let pinned: HashSet<content::Name> =
                content.names().into_iter().filter(|name| under(&name.path)).collect();
            (pinned, *aging)
        }
        Err(_) => (HashSet::new(), aging.compress_only()),
    };
    Some(content.age(now, &aging, &pinned))
}

#[cfg(test)]
#[path = "overlay_age_tests.rs"]
mod tests;
