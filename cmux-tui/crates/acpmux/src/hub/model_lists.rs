//! Part of `Hub`; see `hub/mod.rs`. Every harness's model lists in one tagged cache
//! (`cmux_tag_cache::TagCache`, hq#13932): the ACP lists agents report or a probe reads
//! (`model_probe.rs`) and the live lists of Claude Code's and Codex's own CLIs (`live_models.rs`).
//!
//! Each list is keyed by its harness profile and tagged by what it was read from: the profile
//! (`ListTag::Profile`), the program a live list came from (`ListTag::Binary`, its real path, size
//! and modification time), and whether it came from disk (`ListTag::Disk`). A refresh never
//! clears a list. The picker's Refresh models invalidates `ListTag::Every`, a profile changed by a
//! config reload invalidates its `Profile` (and drops its ACP list, never served under another
//! profile), a CLI that changed on disk invalidates its `Binary`: each is one write, and every
//! list it covers turns stale. A stale list is still served, so a picker opened meanwhile draws
//! it at once and never waits on a probe; the probe that answers writes the fresh one
//! (stale-while-revalidate). A probe takes a [`Stamp`] before it reads, so an invalidation that
//! lands while it runs leaves what it read stale.

use crate::live_models::{CacheKey, LiveModel};
use cmux_tag_cache::{Lookup, Stamp, TagCache};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Far more than any machine's harness profiles: one ACP and one live list each.
const LIST_ENTRIES: usize = 512;

/// Which list of a harness.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum ListKey {
    /// What the agent reports in `session/new` (ACP) or a session's config options.
    Acp(String),
    /// The CLI's own list (`live_models`).
    Live(String),
}

/// What a list was read from (module docs).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum ListTag {
    /// Every list: the picker's Refresh models (`refresh_models`).
    Every,
    /// A harness profile, by name: a config reload changed it.
    Profile(String),
    /// The program a live list was read from: the CLI was updated.
    Binary(CacheKey),
    /// A list a restarted daemon read from disk: stale from the start, so its probe still runs.
    Disk,
}

#[derive(Debug, Clone)]
enum Listed {
    Acp(Vec<(String, String)>),
    Live { models: Vec<LiveModel>, binary: Option<CacheKey> },
}

/// The cache: see the module docs.
pub(crate) struct ModelLists {
    lists: Mutex<TagCache<ListKey, Listed, ListTag>>,
    /// Per harness, the program identity a changed-binary probe last ran for
    /// ([`ModelLists::claim_binary_change`]): a CLI whose probe fails after an update is probed
    /// once for that update, not on every read.
    binary_probes: Mutex<std::collections::HashMap<String, Option<CacheKey>>>,
}

impl Default for ModelLists {
    fn default() -> Self {
        Self { lists: Mutex::new(TagCache::new(LIST_ENTRIES)), binary_probes: Mutex::default() }
    }
}

/// Whether a lookup found a list, and whether it is fresh.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Freshness {
    Fresh,
    Stale,
    Missing,
}

fn freshness<V>(lookup: &Lookup<'_, V>) -> Freshness {
    match lookup {
        Lookup::Fresh(_) => Freshness::Fresh,
        Lookup::Stale(_) => Freshness::Stale,
        Lookup::Miss => Freshness::Missing,
    }
}

impl ModelLists {
    fn lock(&self) -> MutexGuard<'_, TagCache<ListKey, Listed, ListTag>> {
        self.lists.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live list of `harness` was read from `read_from`, and its program is `current` now.
    /// When they differ, the list's program tag is invalidated (it turns stale) and true is
    /// returned once per `current`, so the caller probes it once for this update.
    pub(crate) fn claim_binary_change(
        &self,
        harness: &str,
        read_from: &CacheKey,
        current: Option<CacheKey>,
    ) -> bool {
        if current.as_ref() == Some(read_from) {
            return false;
        }
        self.invalidate(ListTag::Binary(read_from.clone()));
        let mut probes = self.binary_probes.lock().unwrap_or_else(PoisonError::into_inner);
        probes.insert(harness.to_owned(), current.clone()) != Some(current)
    }

    /// The clock now: a probe takes it before it reads, then writes at it.
    pub(crate) fn stamp(&self) -> Stamp {
        self.lock().stamp()
    }

    /// Marks every list `tag` covers stale: one write, however many are cached.
    pub(crate) fn invalidate(&self, tag: ListTag) {
        self.lock().invalidate(tag);
    }

    /// A config reload changed or removed the profile `harness`: its ACP list, read under the old
    /// profile, is never served under the new one (as `AcpCache` keys its disk copy by profile),
    /// and its live list turns stale until the reload's probe answers.
    pub(crate) fn profile_changed(&self, harness: &str) {
        let mut cache = self.lock();
        cache.remove(&ListKey::Acp(harness.to_owned()));
        cache.invalidate(ListTag::Profile(harness.to_owned()));
    }

    /// The ACP list of `harness`, fresh or stale.
    pub(crate) fn acp(&self, harness: &str) -> Option<Vec<(String, String)>> {
        match self.lock().get(&ListKey::Acp(harness.to_owned())).value() {
            Some(Listed::Acp(list)) => Some(list.clone()),
            _ => None,
        }
    }

    /// Whether `harness` has an ACP list, and whether a probe has confirmed it since its tags
    /// last changed.
    pub(crate) fn acp_freshness(&self, harness: &str) -> Freshness {
        freshness(&self.lock().get(&ListKey::Acp(harness.to_owned())))
    }

    /// Writes the ACP list `harness` reported, read since `written`. True when it differs from
    /// the list served before (none, the disk copy, an earlier report).
    pub(crate) fn put_acp(
        &self,
        harness: &str,
        list: Vec<(String, String)>,
        written: Stamp,
    ) -> bool {
        let key = ListKey::Acp(harness.to_owned());
        let mut cache = self.lock();
        let changed = !matches!(cache.get(&key).value(), Some(Listed::Acp(old)) if *old == list);
        cache.insert_at(key, Listed::Acp(list), tags(harness, None), written);
        changed
    }

    /// Serves `lists` read from disk (`AcpCache`) for each harness with no list yet, stale.
    /// The harnesses served.
    pub(crate) fn serve_acp_from_disk(
        &self,
        lists: impl IntoIterator<Item = (String, Vec<(String, String)>)>,
    ) -> Vec<String> {
        let mut cache = self.lock();
        let mut served = Vec::new();
        for (harness, list) in lists {
            let key = ListKey::Acp(harness.clone());
            if !matches!(cache.get(&key), Lookup::Miss) {
                continue;
            }
            let mut tags = tags(&harness, None);
            tags.push(ListTag::Disk);
            cache.insert(key, Listed::Acp(list), tags);
            served.push(harness);
        }
        if !served.is_empty() {
            cache.invalidate(ListTag::Disk);
        }
        served
    }

    /// The live list of `harness`, fresh or stale.
    pub(crate) fn live(&self, harness: &str) -> Option<Vec<LiveModel>> {
        match self.lock().get(&ListKey::Live(harness.to_owned())).value() {
            Some(Listed::Live { models, .. }) => Some(models.clone()),
            _ => None,
        }
    }

    /// Whether `harness` has a live list, and whether it is fresh.
    #[cfg(test)]
    pub(crate) fn live_freshness(&self, harness: &str) -> Freshness {
        freshness(&self.lock().get(&ListKey::Live(harness.to_owned())))
    }

    /// The program identity the live list of `harness` was read under, when it has a list.
    pub(crate) fn live_binary(&self, harness: &str) -> Option<Option<CacheKey>> {
        match self.lock().get(&ListKey::Live(harness.to_owned())).value() {
            Some(Listed::Live { binary, .. }) => Some(binary.clone()),
            _ => None,
        }
    }

    /// Writes the live list of `harness` read from `binary` since `written`. True when it
    /// differs from the list served before.
    pub(crate) fn put_live(
        &self,
        harness: &str,
        models: Vec<LiveModel>,
        binary: Option<CacheKey>,
        written: Stamp,
    ) -> bool {
        let key = ListKey::Live(harness.to_owned());
        let mut cache = self.lock();
        let changed = !matches!(
            cache.get(&key).value(),
            Some(Listed::Live { models: old, .. }) if *old == models
        );
        let tags = tags(harness, binary.clone());
        cache.insert_at(key, Listed::Live { models, binary }, tags, written);
        changed
    }

    /// Serves live lists read from disk (`live_models::Cache`, already matched to their
    /// programs) for each harness with none yet, stale until their probes answer.
    pub(crate) fn serve_live_from_disk(
        &self,
        lists: impl IntoIterator<Item = (String, Vec<LiveModel>, Option<CacheKey>)>,
    ) {
        let mut cache = self.lock();
        let mut any = false;
        for (harness, models, binary) in lists {
            let key = ListKey::Live(harness.clone());
            if !matches!(cache.get(&key), Lookup::Miss) {
                continue;
            }
            let mut tags = tags(&harness, binary.clone());
            tags.push(ListTag::Disk);
            cache.insert(key, Listed::Live { models, binary }, tags);
            any = true;
        }
        if any {
            cache.invalidate(ListTag::Disk);
        }
    }
}

fn tags(harness: &str, binary: Option<CacheKey>) -> Vec<ListTag> {
    let mut tags = vec![ListTag::Every, ListTag::Profile(harness.to_owned())];
    tags.extend(binary.map(ListTag::Binary));
    tags
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(ids: &[&str]) -> Vec<(String, String)> {
        ids.iter().map(|id| (id.to_string(), id.to_uppercase())).collect()
    }

    #[test]
    fn an_invalidated_list_is_served_stale_until_a_probe_writes_it_again() {
        let lists = ModelLists::default();
        assert_eq!(lists.acp_freshness("acme"), Freshness::Missing);
        assert!(lists.put_acp("acme", pairs(&["a"]), lists.stamp()));
        assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
        lists.invalidate(ListTag::Every);
        assert_eq!(lists.acp_freshness("acme"), Freshness::Stale);
        assert_eq!(lists.acp("acme"), Some(pairs(&["a"])), "a stale list is still served");
        assert!(!lists.put_acp("acme", pairs(&["a"]), lists.stamp()), "the same list again");
        assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
        // Another harness's profile changing leaves this one fresh.
        lists.invalidate(ListTag::Profile("other".into()));
        assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
    }

    #[test]
    fn a_probe_that_read_across_an_invalidation_writes_a_stale_list() {
        let lists = ModelLists::default();
        let before = lists.stamp();
        lists.invalidate(ListTag::Profile("acme".into()));
        lists.put_acp("acme", pairs(&["a"]), before);
        assert_eq!(lists.acp_freshness("acme"), Freshness::Stale);
    }

    #[test]
    fn a_disk_list_is_stale_and_never_replaces_a_reported_one() {
        let lists = ModelLists::default();
        lists.put_acp("reported", pairs(&["new"]), lists.stamp());
        let served = lists.serve_acp_from_disk([
            ("reported".to_owned(), pairs(&["old"])),
            ("cold".to_owned(), pairs(&["disk"])),
        ]);
        assert_eq!(served, vec!["cold".to_owned()]);
        assert_eq!(lists.acp("reported"), Some(pairs(&["new"])));
        assert_eq!(lists.acp_freshness("reported"), Freshness::Fresh);
        assert_eq!(lists.acp_freshness("cold"), Freshness::Stale);
    }

    #[test]
    fn a_changed_binary_turns_only_its_live_list_stale() {
        let lists = ModelLists::default();
        let key = |len| CacheKey { program: "/bin/claude".into(), len, modified_ns: 1 };
        let model = LiveModel {
            id: "m".into(),
            name: "M".into(),
            efforts: vec![],
            default_effort: None,
            fast: None,
            service_tiers: vec![],
            is_default: false,
            upgrade: None,
        };
        lists.put_live("claude", vec![model.clone()], Some(key(1)), lists.stamp());
        lists.put_live("codex", vec![model], None, lists.stamp());
        lists.invalidate(ListTag::Binary(key(1)));
        assert_eq!(lists.live_freshness("claude"), Freshness::Stale);
        assert_eq!(lists.live_freshness("codex"), Freshness::Fresh);
        assert_eq!(lists.live_binary("claude"), Some(Some(key(1))));
    }

    #[test]
    fn each_update_of_a_cli_is_claimed_once() {
        let lists = ModelLists::default();
        let key = |len| CacheKey { program: "/bin/codex".into(), len, modified_ns: 1 };
        assert!(!lists.claim_binary_change("codex", &key(1), Some(key(1))), "unchanged");
        assert!(lists.claim_binary_change("codex", &key(1), Some(key(2))));
        // Its probe failed, so the list still names the old program: no second probe.
        assert!(!lists.claim_binary_change("codex", &key(1), Some(key(2))));
        assert!(lists.claim_binary_change("codex", &key(1), Some(key(3))), "another update");
        assert!(lists.claim_binary_change("codex", &key(1), None), "the program is gone");
    }
}
