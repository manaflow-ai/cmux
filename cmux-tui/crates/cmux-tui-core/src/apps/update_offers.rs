//! The background extension update check (`updates.checkExtensions`, off by
//! default; the daemon's timer is `server/extension_updates.rs`). One check
//! refreshes the Community index when its cache is due, and asks each app
//! installed from a git repository for the commit its update would install
//! (the recorded ref; an install pinned to a version tag follows the latest
//! release, as `apps.update` does). A newer commit becomes an offer:
//! `apps.updates.list` lists it next to the Community rows (a Community row
//! for the same app wins), `apps-changed {transaction: "community"}` tells
//! the Extensions page to read again, and `apps.update {app}` installs it
//! through the update path and its consent rule. Nothing installs here.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use serde_json::Value;

use super::community::{UpdateRow, short_commit};
use super::git_source::{self, GitSource};
use super::supervisor::Supervisor;
use crate::panic_free::RecoverPoison;

/// How often the background check runs while the setting is on.
pub(crate) const CHECK_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// How long after the daemon starts the first check waits.
pub(crate) const FIRST_CHECK_AFTER: Duration = Duration::from_secs(2 * 60);

impl Supervisor {
    /// Runs one update check now (network; off the request path) and answers
    /// every update known after it, by app id. A repository that does not
    /// answer keeps its earlier offer.
    pub(crate) fn check_extension_updates_now(&self) -> BTreeMap<String, UpdateRow> {
        let mut changed = false;
        let community = self.community();
        if community.claim_due_refresh() {
            changed |= community.refresh().is_ok();
        }
        let installed: Vec<(String, GitSource, String)> = {
            let inner = self.inner.lock().recover_poison();
            inner
                .catalog
                .git
                .iter()
                .filter(|(id, _)| inner.mirror.apps.get(*id).is_some_and(|r| r.installed))
                .map(|(id, source)| {
                    let name = inner
                        .catalog
                        .packages
                        .get(id)
                        .and_then(|p| p.manifest.get("name").and_then(Value::as_str))
                        .unwrap_or(id)
                        .to_string();
                    (id.clone(), source.clone(), name)
                })
                .collect()
        };
        let mut found = BTreeMap::new();
        let mut kept = BTreeSet::new();
        for (id, source, name) in installed {
            match self.newest_commit(&source) {
                Ok((commit, tag)) if !commit.eq_ignore_ascii_case(&source.commit) => {
                    found.insert(id.clone(), offer(&id, &name, &source, &commit, tag));
                }
                Ok(_) => {}
                Err(_) => {
                    kept.insert(id);
                }
            }
        }
        {
            let mut offers = self.git.offers.lock().recover_poison();
            let next: BTreeMap<String, UpdateRow> = offers
                .iter()
                .filter(|(id, _)| kept.contains(*id))
                .map(|(id, row)| (id.clone(), row.clone()))
                .chain(found)
                .collect();
            if *offers != next {
                *offers = next;
                changed = true;
            }
        }
        if changed {
            self.community_changed();
        }
        self.community_updates_cached()
    }

    /// The commit (and tag) an update of `source` would install: refs only,
    /// no package download.
    fn newest_commit(&self, source: &GitSource) -> Result<(String, Option<String>), String> {
        let reference = source.update_reference();
        // The person installed from this repository: its host passes the gate.
        cmux_egress::allow_named(&reference.host);
        let transport = self.git_transport();
        let _one = self.git.fetching.lock().recover_poison();
        let refs = git_source::list_refs(&*transport, &reference)?;
        let resolved = git_source::resolve(&*transport, &reference, &refs)?;
        Ok((resolved.commit, resolved.tag))
    }

    /// Adds the background check's offers to `updates` (the Community rows):
    /// one row per app, the Community row first; an offer for an app no
    /// longer installed, or one that moved since, is left out.
    pub(super) fn merge_git_offers(
        &self,
        updates: &mut Vec<UpdateRow>,
        sources: &BTreeMap<String, Value>,
        installed: &BTreeSet<String>,
    ) {
        let offers = self.git.offers.lock().recover_poison();
        let listed: BTreeSet<String> = updates.iter().map(|u| u.app.clone()).collect();
        updates.extend(
            offers
                .values()
                .filter(|o| still_offered(o, sources, installed) && !listed.contains(&o.app))
                .cloned(),
        );
    }
}

fn still_offered(
    offer: &UpdateRow,
    sources: &BTreeMap<String, Value>,
    installed: &BTreeSet<String>,
) -> bool {
    installed.contains(&offer.app)
        && sources
            .get(&offer.app)
            .and_then(|s| s.get("commit"))
            .and_then(Value::as_str)
            .is_some_and(|c| c.eq_ignore_ascii_case(&offer.current_commit))
}

fn offer(id: &str, name: &str, source: &GitSource, commit: &str, tag: Option<String>) -> UpdateRow {
    let version = |tag: Option<&str>, commit: &str| {
        tag.filter(|t| git_source::is_version_tag(t))
            .map(|t| t.strip_prefix('v').unwrap_or(t).to_string())
            .unwrap_or_else(|| short_commit(commit))
    };
    let current_version = if source.version.is_empty() {
        version(source.tag.as_deref(), &source.commit)
    } else {
        source.version.clone()
    };
    let reference = source.reference().canonical();
    UpdateRow {
        app: id.to_string(),
        name: name.to_string(),
        install_app: format!("{reference}@{commit}"),
        reference,
        current_version,
        current_commit: source.commit.clone(),
        version: version(tag.as_deref(), commit),
        commit: commit.to_string(),
    }
}

#[cfg(test)]
#[path = "update_offers_tests.rs"]
mod tests;
