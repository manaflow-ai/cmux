//! Update offers for apps installed from a git repository.
//!
//! - The check: for every installed git app, the refs of its update
//!   reference ([`GitSource::update_reference`]: a version-tag pin follows the
//!   newest version tag, a branch its branch). Same commit: nothing more is
//!   fetched. A new commit: its package is fetched and validated (never
//!   staged, so only a consent card's read lets an install take it) and its
//!   scopes are compared with the installed ones.
//! - When: no polling loop. Listing the installed apps (`apps.installed.list`)
//!   or the offers (`apps.updates.list`) starts one check off the request
//!   when the last one is older than [`CHECK_EVERY`]; `{check: true}` asks
//!   for one now (at most once a minute). One check runs at a time, on its
//!   own thread, and a check that changes the offers broadcasts
//!   `apps-changed {transaction: "updates"}`.
//! - `apps.updates.list` answers the offers found:
//!   `{updates: [{app, source_ref, update_ref, installed, available,
//!   new_scopes, needs_consent, review}], checking, checked_at, errors}`.
//!   `needs_consent`: the new commit asks for a scope the installed one did
//!   not, so `apps.update` refuses (`apps.update.needs_consent`) and the
//!   person reviews the new scopes on `review`'s consent card
//!   (`cmux apps install <update_ref>`). Without it `apps.update` moves the
//!   app.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::git_install::git_error;
use super::git_source::{self, GitSource};
use super::mirror::Facts;
use super::supervisor::{ApiError, Supervisor};
use crate::panic_free::RecoverPoison;

/// How old the last check may be before a listing starts another.
pub(crate) const CHECK_EVERY: Duration = Duration::from_secs(6 * 60 * 60);

/// The least time between two checks asked for with `{check: true}`.
const FORCED_AT_MOST_EVERY: Duration = Duration::from_secs(60);

/// A new commit found for an installed git app.
#[derive(Debug, Clone, PartialEq)]
struct Offer {
    /// The installed commit the offer is against.
    installed_commit: String,
    /// The fetched package's directory, relative to the git directory.
    dir: String,
    value: Value,
}

#[derive(Default)]
pub(crate) struct Updates {
    checking: bool,
    checked_at: Option<Instant>,
    checked_unix: Option<u64>,
    offers: BTreeMap<String, Offer>,
    errors: BTreeMap<String, String>,
}

/// The scopes `after` asks for (required or optional) that `before` did not.
pub(super) fn new_scopes(before: &Facts, after: &Facts) -> Vec<String> {
    let known: BTreeSet<&String> = before.requested.iter().chain(&before.optional).collect();
    let mut new: Vec<String> = after
        .requested
        .iter()
        .chain(&after.optional)
        .filter(|scope| !known.contains(scope))
        .cloned()
        .collect();
    new.sort();
    new.dedup();
    new
}

impl Supervisor {
    /// Starts a background update check when one is due (or `force`d and
    /// the last one is over a minute old) and none is running. Answers
    /// whether it started one.
    pub(crate) fn check_updates_if_due(&self, force: bool) -> bool {
        if self.inner.lock().recover_poison().catalog.git.is_empty() {
            return false;
        }
        {
            let mut updates = self.git.updates.lock().recover_poison();
            let every = if force { FORCED_AT_MOST_EVERY } else { CHECK_EVERY };
            let due = updates.checked_at.is_none_or(|at| at.elapsed() >= every);
            if updates.checking || !due {
                return false;
            }
            updates.checking = true;
        }
        let me = self.me.clone();
        let spawned =
            std::thread::Builder::new().name("apps-git-updates".into()).spawn(move || {
                if let Some(supervisor) = me.upgrade() {
                    supervisor.check_updates_now();
                }
            });
        if spawned.is_err() {
            self.git.updates.lock().recover_poison().checking = false;
            return false;
        }
        true
    }

    /// Checks every installed git app for a new commit now, on this thread,
    /// and records the offers.
    pub(crate) fn check_updates_now(&self) {
        let apps: Vec<(String, GitSource)> = {
            let inner = self.inner.lock().recover_poison();
            inner
                .catalog
                .git
                .iter()
                .filter(|(id, _)| inner.mirror.apps.get(*id).is_some_and(|r| r.installed))
                .map(|(id, source)| (id.clone(), source.clone()))
                .collect()
        };
        let mut offers = BTreeMap::new();
        let mut errors = BTreeMap::new();
        for (id, current) in &apps {
            match self.update_offer(id, current) {
                Ok(Some(offer)) => {
                    offers.insert(id.clone(), offer);
                }
                Ok(None) => {}
                Err(error) => {
                    errors.insert(id.clone(), format!("{}: {}", error.code, error.message));
                }
            }
        }
        let (changed, dropped) = {
            let mut updates = self.git.updates.lock().recover_poison();
            let changed = updates.offers != offers;
            let dropped: Vec<String> = updates
                .offers
                .values()
                .filter(|old| !offers.values().any(|new| new.dir == old.dir))
                .map(|old| old.dir.clone())
                .collect();
            updates.offers = offers;
            updates.errors = errors;
            updates.checked_at = Some(Instant::now());
            updates.checked_unix =
                SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs());
            updates.checking = false;
            (changed, dropped)
        };
        self.drop_offer_trees(&dropped);
        if changed {
            self.updates_changed();
        }
    }

    /// The offer for `id` installed at `current`, if its update reference
    /// names another commit now.
    fn update_offer(&self, id: &str, current: &GitSource) -> Result<Option<Offer>, ApiError> {
        let reference = current.update_reference();
        let transport = self.git_transport();
        let resolved = {
            let _one = self.git.fetching.lock().recover_poison();
            let refs = git_source::list_refs(&*transport, &reference)
                .map_err(git_error("apps.git.fetch"))?;
            git_source::resolve(&*transport, &reference, &refs)
                .map_err(git_error("apps.git.ref"))?
        };
        if resolved.commit == current.commit {
            return Ok(None);
        }
        let fetched = self.git_fetch(&reference.reference())?;
        if fetched.package.id != id {
            return Err(ApiError::new(
                "apps.git.invalid",
                format!("the repository's app is now {}, not {id}", fetched.package.id),
            ));
        }
        if fetched.source.commit == current.commit {
            return Ok(None);
        }
        let new = {
            let inner = self.inner.lock().recover_poison();
            match inner.catalog.packages.get(id) {
                Some(installed) => new_scopes(&installed.facts(), &fetched.package.facts()),
                None => return Ok(None),
            }
        };
        let update_ref = reference.reference();
        let value = json!({
            "app": id,
            "source_ref": current.reference().reference(),
            "update_ref": update_ref,
            "installed": {
                "commit": current.commit,
                "version": current.version,
                "tag": current.tag,
            },
            "available": {
                "commit": fetched.source.commit,
                "version": fetched.source.version,
                "tag": fetched.source.tag,
                "verified_source": fetched.source.verified_source,
                "reviewed": fetched.reviewed,
            },
            "needs_consent": !new.is_empty(),
            "new_scopes": new,
            "review": format!("cmux apps install {update_ref}"),
        });
        Ok(Some(Offer {
            installed_commit: current.commit.clone(),
            dir: fetched.source.dir.clone(),
            value,
        }))
    }

    /// `apps.updates.list`: the offers of the last check (still against
    /// the installed commit), starting a check when one is due.
    pub(super) fn updates_list(&self, args: &Value) -> Result<Value, ApiError> {
        let force = match args.get("check") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(force)) => *force,
            Some(_) => {
                return Err(super::store::bad_request("check is a boolean"));
            }
        };
        self.check_updates_if_due(force);
        let installed: BTreeMap<String, String> = {
            let inner = self.inner.lock().recover_poison();
            inner
                .catalog
                .git
                .iter()
                .filter(|(id, _)| inner.mirror.apps.get(*id).is_some_and(|r| r.installed))
                .map(|(id, source)| (id.clone(), source.commit.clone()))
                .collect()
        };
        let updates = self.git.updates.lock().recover_poison();
        let offers: Vec<Value> = updates
            .offers
            .iter()
            .filter(|(id, offer)| installed.get(*id) == Some(&offer.installed_commit))
            .map(|(_, offer)| offer.value.clone())
            .collect();
        let errors: Vec<Value> = updates
            .errors
            .iter()
            .filter(|(id, _)| installed.contains_key(*id))
            .map(|(id, error)| json!({ "app": id, "error": error }))
            .collect();
        Ok(json!({
            "updates": offers,
            "checking": updates.checking,
            "checked_at": updates.checked_unix,
            "errors": errors,
        }))
    }

    /// After an uninstall: the app's offer and the tree it fetched go. Takes
    /// only the offers' lock (the caller may hold `inner`).
    pub(super) fn forget_update_offer(&self, app: &str) {
        let offer = self.git.updates.lock().recover_poison().offers.remove(app);
        if let Some(offer) = offer
            && let Some(git_dir) = git_source::git_dir(&self.config.sources)
            && let Some(path) = git_source::inside(&git_dir, &offer.dir)
        {
            let _ = std::fs::remove_dir_all(path);
        }
    }

    /// Removes fetched trees no offer and no installed app uses any more.
    fn drop_offer_trees(&self, dirs: &[String]) {
        if dirs.is_empty() {
            return;
        }
        let Some(git_dir) = git_source::git_dir(&self.config.sources) else { return };
        let used: BTreeSet<String> = {
            let inner = self.inner.lock().recover_poison();
            inner.catalog.git.values().map(|source| source.dir.clone()).collect()
        };
        for dir in dirs.iter().filter(|dir| !used.contains(*dir)) {
            if let Some(path) = git_source::inside(&git_dir, dir) {
                let _ = std::fs::remove_dir_all(path);
            }
        }
    }

    /// Tells clients to read the offers again; an `apps-changed` with no
    /// app, so nothing reconciles or activates.
    fn updates_changed(&self) {
        let (sinks, revision) = {
            let inner = self.inner.lock().recover_poison();
            (inner.sinks.clone(), inner.mirror.revision)
        };
        let event =
            json!({ "event": "apps-changed", "revision": revision, "transaction": "updates" });
        for sink in sinks.values() {
            sink(&event);
        }
    }
}
