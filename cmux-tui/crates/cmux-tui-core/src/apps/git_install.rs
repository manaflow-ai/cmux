//! Git installs on the supervisor (`git_source.rs` has the fetch, the
//! limits and the rules). The App Store ops take a repository reference
//! wherever they take an app id:
//!
//! - `catalog.get {app: <reference>}` fetches and validates that commit
//!   (staged, not installed) and answers its listing with its scopes, the
//!   source (`repository`, `path`, `ref`, `commit`, `tag`, `version`) and
//!   `reviewed` / `verified_source`: what the consent card shows.
//! - `install {app: <reference>, commit}` installs the commit the card showed
//!   (`commit` is the card's; it must be staged, and a later `catalog.get` that
//!   staged another commit does not replace it; nothing else installs); on an
//!   installed app it moves it to that commit, the card having shown the new
//!   scopes. `grant_optional` is the card's too.
//! - `update {app: <id or reference>}` re-resolves the recorded ref and moves
//!   the app to the new commit; when the new commit asks for a scope the
//!   installed one did not, it refuses (`apps.update.needs_consent`): the
//!   person reviews the new scopes on `cmux apps install <reference>`'s card.
//! - `uninstall` of a git app also removes its files and its `sources.json`
//!   record (the tree digest stays, so a reinstall is checked).
//!
//! Every row of `catalog.list`, `catalog.get` and `installed.list` of a git
//! app carries its source fields. [`Supervisor::install_from_git`] is the
//! one "install this ref" entry point, after [`Supervisor::git_stage`].

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::catalog::Package;
use super::git_source::{self, GitSource, GitTransport, HttpTransport, Index, RepoRef};
use super::mirror::{Origin, SetOp};
use super::store;
use super::supervisor::{ApiError, Out, Supervisor};
use crate::panic_free::RecoverPoison;

/// How long a fetch the consent card showed stays the one an install takes.
const STAGED_FOR: Duration = Duration::from_secs(15 * 60);

/// A fetched, validated package not yet installed at this commit.
#[derive(Clone)]
pub(crate) struct Staged {
    at: Instant,
    pub source: GitSource,
    pub package: Package,
    /// The cmux registry approved this repository at this commit.
    pub reviewed: bool,
}

/// Requests that finished, newest last: (idempotency key, what it asked,
/// the commit it installed, the app). A retry of one replays its answer.
type Done = (String, String, String, String);

/// How many finished requests a retry can still replay.
const DONE_KEPT: usize = 256;

#[derive(Default)]
pub(crate) struct GitState {
    /// Staged packages by `reference#commit`: each card's commit stays its own.
    staged: Mutex<HashMap<String, Staged>>,
    done: Mutex<std::collections::VecDeque<Done>>,
    transport: OnceLock<Arc<dyn GitTransport>>,
    /// One fetch at a time.
    pub(super) fetching: Mutex<()>,
    /// One `sources.json` read-modify-write at a time.
    index: Mutex<()>,
    /// The newer commits the background check found, by app id
    /// (`update_offers.rs`); `apps.updates.list` lists them.
    pub(super) offers: Mutex<std::collections::BTreeMap<String, super::community::UpdateRow>>,
    /// The background update check and what it found (`git_updates.rs`).
    pub(super) updates: Mutex<super::git_updates::Updates>,
}

fn staged_key(reference: &str, commit: &str) -> String {
    format!("{reference}#{commit}")
}

pub(super) fn git_error(code: &str) -> impl Fn(String) -> ApiError + '_ {
    move |message| ApiError::new(code, message)
}

/// Whether App Store op `op` with `args` may fetch from the network, so the
/// wire answers it off the connection's thread.
pub(crate) fn store_op_fetches(op: &str, args: &Value) -> bool {
    let reference = args.get("app").and_then(Value::as_str).is_some_and(RepoRef::looks_like);
    match op.strip_prefix("cmux.").unwrap_or(op) {
        "apps.update" => true,
        "apps.catalog.get" | "apps.install" => reference,
        _ => false,
    }
}

fn merge(value: &mut Value, fields: serde_json::Map<String, Value>) {
    if let Some(object) = value.as_object_mut() {
        object.extend(fields);
    }
}

impl Supervisor {
    /// Replaces the network (tests use a local fixture).
    #[cfg(test)]
    pub(crate) fn set_git_transport(&self, transport: Arc<dyn GitTransport>) {
        let _ = self.git.transport.set(transport);
    }

    pub(super) fn git_transport(&self) -> Arc<dyn GitTransport> {
        self.git.transport.get_or_init(|| Arc::new(HttpTransport)).clone()
    }

    fn git_dir(&self) -> Result<PathBuf, ApiError> {
        git_source::git_dir(&self.config.sources).ok_or_else(|| {
            ApiError::new(
                "apps.git.unavailable",
                "this daemon has no state directory for git installs",
            )
        })
    }

    /// The App Store op `op`: git references and git apps here, the rest
    /// in `store_call_base`. `origin` is the request's, admitted by the A2
    /// gate on the wire.
    pub fn store_call(
        &self,
        client: u64,
        op: &str,
        args: Value,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        let short = op.strip_prefix("cmux.").unwrap_or(op);
        let app = args.get("app").and_then(Value::as_str).map(str::to_string);
        let reference = app.as_deref().filter(|app| RepoRef::looks_like(app));
        let key = || {
            args.get("idempotency_key")
                .and_then(Value::as_str)
                .map(str::to_string)
                .ok_or_else(|| store::bad_request("idempotency_key is required"))
        };
        match (short, reference) {
            ("apps.catalog.get", Some(reference)) => self.git_detail(reference),
            ("apps.install", Some(reference)) => {
                if args.get("deploy").is_some_and(|d| !d.is_null()) {
                    return Err(store::bad_request(
                        "an app from a git repository installs without deploy",
                    ));
                }
                let commit = args
                    .get("commit")
                    .and_then(Value::as_str)
                    .filter(|c| git_source::is_commit(c))
                    .ok_or_else(|| {
                        ApiError::new(
                            "apps.git.commit_required",
                            "an install from a git repository names the commit its consent card showed (commit)",
                        )
                    })?;
                let grant_optional =
                    args.get("grant_optional").and_then(Value::as_bool).unwrap_or(false);
                self.install_from_git(client, reference, commit, grant_optional, &key()?, origin)
            }
            ("apps.update", _) => {
                let grant_optional =
                    args.get("grant_optional").and_then(Value::as_bool).unwrap_or(false);
                match self.git_update(
                    client,
                    app.as_deref().unwrap_or_default(),
                    grant_optional,
                    &key()?,
                    origin,
                ) {
                    // Not installed from git: a community (registry) app's
                    // update, or `apps.update.none` (community.rs).
                    Err(error) if error.code == "apps.git.not_git" => {
                        self.store_call_base(client, op, args, origin)
                    }
                    result => result,
                }
            }
            ("apps.updates.list", _) => self.updates_list(&args),
            ("apps.uninstall", _) => {
                let result = self.store_call_base(client, op, args, origin)?;
                if let Some(app) = app.as_deref() {
                    self.forget_git_app(app);
                }
                Ok(result)
            }
            _ => {
                let mut result = self.store_call_base(client, op, args, origin)?;
                self.decorate(short, &mut result);
                if short == "apps.installed.list" {
                    // Listing the installed apps is when an update check
                    // that is due starts, off this request (no timer loop).
                    self.check_updates_if_due(false);
                }
                Ok(result)
            }
        }
    }

    /// Adds the source fields to the rows of git apps.
    fn decorate(&self, op: &str, result: &mut Value) {
        let inner = self.inner.lock().recover_poison();
        if inner.catalog.git.is_empty() {
            return;
        }
        let fields = |row: &mut Value| {
            let source =
                row.get("app").and_then(Value::as_str).and_then(|id| inner.catalog.git.get(id));
            if let Some(source) = source {
                let fields = source.wire_fields();
                merge(row, fields);
            }
        };
        match op {
            "apps.catalog.get" => fields(result),
            "apps.catalog.list" | "apps.installed.list" => {
                let list = if op == "apps.catalog.list" { "listings" } else { "apps" };
                if let Some(rows) = result.get_mut(list).and_then(Value::as_array_mut) {
                    rows.iter_mut().for_each(fields);
                }
            }
            _ => {}
        }
    }

    /// Fetches `reference` at the commit its ref names and validates it:
    /// the staged package an install of the same reference takes.
    pub(crate) fn git_stage(&self, reference: &str) -> Result<Staged, ApiError> {
        let staged = self.git_fetch(reference)?;
        let key = RepoRef::parse(reference).map_err(git_error("apps.git.reference"))?.reference();
        self.git
            .staged
            .lock()
            .recover_poison()
            .insert(staged_key(&key, &staged.source.commit), staged.clone());
        Ok(staged)
    }

    /// Fetches and validates `reference` at the commit its ref names without
    /// staging it: the update check reads a new commit's scopes this way, so
    /// only a consent card's read ever lets an install take a commit.
    pub(super) fn git_fetch(&self, reference: &str) -> Result<Staged, ApiError> {
        let reference = RepoRef::parse(reference).map_err(git_error("apps.git.reference"))?;
        // The person named this repository: its host passes the egress gate.
        cmux_egress::allow_named(&reference.host);
        let git_dir = self.git_dir()?;
        let transport = self.git_transport();
        let _one = self.git.fetching.lock().recover_poison();
        let refs =
            git_source::list_refs(&*transport, &reference).map_err(git_error("apps.git.fetch"))?;
        let resolved = git_source::resolve(&*transport, &reference, &refs)
            .map_err(git_error("apps.git.ref"))?;
        let release = resolved.asset.is_some();
        let commit = resolved.commit.clone();
        let relative = reference.package_dir(&commit, release);
        let dir = git_dir.join(&relative);
        let index = Index::load(&git_dir);
        let key = reference.digest_key(&commit, release);
        let known = index.digests.get(&key).cloned();
        let (sha256, asset_sha256) = match known.filter(|_| dir.is_dir()) {
            Some(sha256) => (sha256, index.assets.get(&key).cloned()),
            None => self.fetch_tree(&*transport, &reference, &resolved, &git_dir, &relative)?,
        };
        let tag = resolved.tag;
        let package = git_source::validate(&dir, &reference.host, &reference.owner)
            .map_err(git_error("apps.git.invalid"))?;
        let tag = tag.or_else(|| refs.tag_at(&commit, &package.version));
        let verified_source = tag
            .as_deref()
            .is_some_and(|tag| git_source::signed_tag(&*transport, &reference, &refs, tag));
        let reviewed = git_source::reviewed(&*transport, &reference);
        let source = GitSource {
            repository: reference.repository_url(),
            host: reference.host.clone(),
            owner: reference.owner.clone(),
            repo: reference.repo.clone(),
            path: reference.path.clone(),
            git_ref: reference.git_ref.clone(),
            commit,
            tag,
            version: package.version.clone(),
            sha256,
            asset_sha256,
            dir: relative,
            verified_source,
        };
        Ok(Staged { at: Instant::now(), source, package, reviewed })
    }

    /// Downloads the release's built package (else the tree at the commit),
    /// extracts it into `<git>/<relative>`, checks its digest against the
    /// one recorded for this commit, validates it, and records the digest.
    /// Answers the tree digest and the release asset's.
    fn fetch_tree(
        &self,
        transport: &dyn GitTransport,
        reference: &RepoRef,
        resolved: &git_source::Resolved,
        git_dir: &std::path::Path,
        relative: &str,
    ) -> Result<(String, Option<String>), ApiError> {
        let commit = resolved.commit.as_str();
        let (archive, asset_sha256) = match &resolved.asset {
            Some(asset) => git_source::download_asset(transport, asset)
                .map(|(bytes, sha256)| (bytes, Some(sha256)))
                .map_err(git_error("apps.git.fetch"))?,
            None => (
                git_source::download(transport, reference, commit)
                    .map_err(git_error("apps.git.fetch"))?,
                None,
            ),
        };
        let key = reference.digest_key(commit, asset_sha256.is_some());
        let staging = git_dir.join(".staging").join(format!("{}-{commit}", std::process::id()));
        let _ = std::fs::remove_dir_all(&staging);
        let checked = (|| {
            let sha256 = if asset_sha256.is_some() {
                git_source::extract_release(&archive, &staging)
            } else {
                git_source::extract(&archive, &reference.path, &staging)
            }
            .map_err(git_error("apps.git.archive"))?;
            if let Some(known) = Index::load(git_dir).digests.get(&key).filter(|k| **k != sha256) {
                return Err(ApiError::new(
                    "apps.git.digest_mismatch",
                    format!(
                        "{} at {commit} is not the tree installed before (sha256 {known}, now {sha256}); nothing installed",
                        reference.canonical()
                    ),
                ));
            }
            git_source::validate(&staging, &reference.host, &reference.owner)
                .map_err(git_error("apps.git.invalid"))?;
            Ok(sha256)
        })();
        let sha256 = match checked {
            Ok(sha256) => sha256,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&staging);
                return Err(error);
            }
        };
        let dir = git_dir.join(relative);
        let _ = std::fs::remove_dir_all(&dir);
        let placed = dir
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::rename(&staging, &dir));
        if let Err(error) = placed {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(ApiError::new("apps.git.persist", format!("{}: {error}", dir.display())));
        }
        let _index = self.git.index.lock().recover_poison();
        let mut index = Index::load(git_dir);
        index.digests.insert(key.clone(), sha256.clone());
        if let Some(asset) = &asset_sha256 {
            index.assets.insert(key, asset.clone());
        }
        index
            .save(git_dir)
            .map_err(|e| ApiError::new("apps.git.persist", format!("sources.json: {e}")))?;
        Ok((sha256, asset_sha256))
    }

    /// `catalog.get` of a reference: the staged commit's listing for the
    /// consent card.
    fn git_detail(&self, reference: &str) -> Result<Value, ApiError> {
        let staged = self.git_stage(reference)?;
        let inner = self.inner.lock().recover_poison();
        let id = &staged.package.id;
        let mut value =
            store::to_value(store::listing(&staged.package, inner.mirror.apps.get(id)))?;
        let mut scopes = Vec::new();
        for (field, optional) in [("scopes", false), ("optionalScopes", true)] {
            for (scope, reason) in
                staged.package.manifest.get(field).and_then(Value::as_object).into_iter().flatten()
            {
                scopes.push(json!({
                    "scope": scope, "reason": store::text(reason), "risk": store::risk(scope), "optional": optional,
                }));
            }
        }
        value.set("scopes", Value::Array(scopes));
        merge(&mut value, staged.source.wire_fields());
        value.set("reviewed", json!(staged.reviewed));
        if let Some(installed) = inner.catalog.git.get(id) {
            value.set("installed_commit", json!(installed.commit));
        }
        Ok(value)
    }

    /// The package the card for `commit` of `reference` staged, still fresh.
    fn staged_at(&self, reference: &str, commit: &str) -> Option<Staged> {
        let mut staged = self.git.staged.lock().recover_poison();
        staged.retain(|_, s| s.at.elapsed() < STAGED_FOR && s.package.dir.is_dir());
        staged.get(&staged_key(reference, commit)).cloned()
    }

    /// After an install finished: its reference's staged packages go.
    fn consume_staged(&self, reference: &str) {
        let prefix = format!("{reference}#");
        self.git.staged.lock().recover_poison().retain(|key, _| !key.starts_with(&prefix));
    }

    /// The app a finished request with this idempotency key answered, when
    /// `request` (and, for an install, the `commit`) is the one it asked: a
    /// retry replays success. Another request under the key conflicts.
    fn replayed(
        &self,
        key: &str,
        request: &str,
        commit: Option<&str>,
    ) -> Result<Option<String>, ApiError> {
        let done = self.git.done.lock().recover_poison();
        let Some((_, asked, installed, app)) = done.iter().find(|(k, ..)| k == key) else {
            return Ok(None);
        };
        if asked == request && commit.is_none_or(|c| c == installed) {
            Ok(Some(app.clone()))
        } else {
            Err(ApiError::new(
                "idempotency.conflict",
                "this idempotency key was used for a different change",
            ))
        }
    }

    fn remember_done(&self, key: &str, request: &str, commit: &str, app: &str) {
        let mut done = self.git.done.lock().recover_poison();
        done.push_back((key.into(), request.into(), commit.into(), app.into()));
        while done.len() > DONE_KEPT {
            done.pop_front();
        }
    }

    /// The one "install this ref" entry point (CLI, deeplink, App Store page,
    /// setups): installs `reference` (`HOST/OWNER/REPO[/PATH][@REF]`) at
    /// `commit`, the commit the consent card showed, which [`Self::git_stage`]
    /// (the card's `catalog.get`) staged in the last 15 minutes; refuses
    /// `apps.git.not_staged` otherwise, so a card for one commit never
    /// installs another. On an app already installed from this repository it
    /// moves the app to that commit. `grant_optional`: the card listed the
    /// optional scopes too. Origin user only: the person confirmed the card.
    /// A retry with the same `idempotency_key` replays the finished answer.
    /// Answers the app's state as `apps.install` does, with its source fields.
    pub(crate) fn install_from_git(
        &self,
        client: u64,
        reference: &str,
        commit: &str,
        grant_optional: bool,
        idempotency_key: &str,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new("apps.origin", "installing an app needs a user action"));
        }
        let parsed = RepoRef::parse(reference).map_err(git_error("apps.git.reference"))?;
        // The person named this repository: its host passes the egress gate.
        cmux_egress::allow_named(&parsed.host);
        let request = format!("install {} {grant_optional}", parsed.reference());
        if let Some(app) = self.replayed(idempotency_key, &request, Some(commit))? {
            return self.git_result(&app);
        }
        // Only what the consent card showed installs: its `catalog.get` (or
        // a caller's [`Self::git_stage`]) staged this exact commit.
        let Some(staged) = self.staged_at(&parsed.reference(), commit) else {
            return Err(ApiError::new(
                "apps.git.not_staged",
                format!(
                    "{} at {commit} was not shown on a consent card in the last 15 minutes; install it again to see the card",
                    parsed.reference()
                ),
            ));
        };
        let result = self.commit_git(
            client,
            staged,
            idempotency_key,
            &request,
            origin,
            true,
            grant_optional,
        )?;
        self.consume_staged(&parsed.reference());
        Ok(result)
    }

    /// `apps.update`: the git app `app` (an id or a reference) at the commit
    /// its recorded ref names now.
    fn git_update(
        &self,
        client: u64,
        app: &str,
        grant_optional: bool,
        key: &str,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new("apps.origin", "updating an app needs a user action"));
        }
        let request = format!("update {app}");
        if let Some(id) = self.replayed(key, &request, None)? {
            let mut result = self.git_result(&id)?;
            result.set("updated", json!(true));
            return Ok(result);
        }
        let found = {
            let inner = self.inner.lock().recover_poison();
            match RepoRef::parse(app).ok().filter(|_| RepoRef::looks_like(app)) {
                Some(reference) => inner
                    .catalog
                    .git
                    .iter()
                    .find(|(_, s)| s.reference().canonical() == reference.canonical())
                    .map(|(id, s)| (id.clone(), s.clone())),
                None => inner.catalog.git.get(app).map(|s| (app.to_string(), s.clone())),
            }
        };
        let Some((id, current)) = found else {
            return Err(ApiError::new(
                "apps.git.not_git",
                format!("{app} is not an app installed from a git repository"),
            ));
        };
        // Updates follow new releases: an install pinned to a version tag
        // moves to the latest release; a branch keeps following its branch.
        let staged = self.git_stage(&current.update_reference().reference())?;
        if staged.package.id != id {
            return Err(ApiError::new(
                "apps.git.invalid",
                format!("the repository's app is now {}, not {id}", staged.package.id),
            ));
        }
        let updated = staged.source.commit != current.commit;
        let mut result =
            self.commit_git(client, staged, key, &request, origin, false, grant_optional)?;
        result.set("updated", json!(updated));
        Ok(result)
    }

    /// Records and installs (or moves to) a staged package. `consented`:
    /// the consent card showed this commit's scopes, so it may grant what a
    /// fresh install grants; without it a commit asking for more refuses.
    #[allow(clippy::too_many_arguments, reason = "one internal step shared by install and update")]
    fn commit_git(
        &self,
        client: u64,
        staged: Staged,
        key: &str,
        request: &str,
        origin: Origin,
        consented: bool,
        grant_optional: bool,
    ) -> Result<Value, ApiError> {
        let id = staged.package.id.clone();
        let git_dir = self.git_dir()?;
        let (installed, previous) = {
            let inner = self.inner.lock().recover_poison();
            if inner.catalog.packages.contains_key(&id) {
                match inner.catalog.git.get(&id) {
                    None => {
                        return Err(ApiError::new(
                            "apps.git.id_taken",
                            format!("{id} already ships with cmux or is one of your local apps"),
                        ));
                    }
                    Some(other)
                        if other.repository != staged.source.repository
                            || other.path != staged.source.path =>
                    {
                        return Err(ApiError::new(
                            "apps.git.id_taken",
                            format!(
                                "{id} is installed from {}; remove it first",
                                other.reference().canonical()
                            ),
                        ));
                    }
                    _ => {}
                }
            }
            let installed = inner.mirror.apps.get(&id).is_some_and(|r| r.installed);
            let previous = inner.catalog.git.get(&id).cloned();
            if installed && previous.as_ref().is_some_and(|p| p.commit == staged.source.commit) {
                drop(inner);
                return self.git_result(&id);
            }
            if installed && let Some(current) = inner.catalog.packages.get(&id) {
                let new = super::git_updates::new_scopes(&current.facts(), &staged.package.facts());
                if !consented && !new.is_empty() {
                    return Err(ApiError::new(
                        "apps.update.needs_consent",
                        format!(
                            "the new version of {id} also asks for {}: review it with `cmux apps install {}`",
                            new.join(", "),
                            staged.source.reference().reference()
                        ),
                    ));
                }
            }
            (installed, previous)
        };
        {
            let _index = self.git.index.lock().recover_poison();
            let mut index = Index::load(&git_dir);
            index.apps.insert(id.clone(), staged.source.clone());
            index
                .save(&git_dir)
                .map_err(|e| ApiError::new("apps.git.persist", format!("sources.json: {e}")))?;
        }
        let commit = staged.source.commit.clone();
        let applied = if installed {
            self.repackage(
                &id,
                staged.package.clone(),
                staged.source.clone(),
                consented,
                grant_optional,
            )
        } else {
            {
                let mut inner = self.inner.lock().recover_poison();
                inner.catalog.packages.insert(id.clone(), staged.package.clone());
                inner.catalog.git.insert(id.clone(), staged.source.clone());
            }
            let op = SetOp {
                key: key.to_string(),
                app: id.clone(),
                origin,
                installed: Some(true),
                grant_optional,
                ..SetOp::default()
            };
            self.set(client, op).map(|_| ())
        };
        if let Err(error) = applied {
            // `apps.json` did not take it: `sources.json` and the catalog go
            // back to what they were, so a restart loads what still runs.
            if !installed {
                let mut inner = self.inner.lock().recover_poison();
                inner.catalog.packages.remove(&id);
                inner.catalog.git.remove(&id);
            }
            let _index = self.git.index.lock().recover_poison();
            let mut index = Index::load(&git_dir);
            match &previous {
                Some(previous) => index.apps.insert(id.clone(), previous.clone()),
                None => index.apps.remove(&id),
            };
            let _ = index.save(&git_dir);
            return Err(error);
        }
        if !installed {
            // Best effort, bounded at 5 s; this request already runs off the connection's thread.
            git_source::ping_install(&*self.git_transport(), &staged.source.reference(), &commit);
        }
        self.remember_done(key, request, &commit, &id);
        if let Some(previous) = previous.filter(|p| p.dir != staged.source.dir) {
            self.remove_tree(&git_dir, &previous.dir);
        }
        self.git_result(&id)
    }

    /// `set_result` with the app's source fields.
    fn git_result(&self, id: &str) -> Result<Value, ApiError> {
        let mut result = self.set_result(id)?;
        let fields =
            self.inner.lock().recover_poison().catalog.git.get(id).map(GitSource::wire_fields);
        if let (Some(fields), Some(row)) = (fields, result.get_mut("app")) {
            merge(row, fields);
        }
        Ok(result)
    }

    /// Moves an installed git app to a new package: grants the new manifest
    /// no longer asks for go, a consented one gains a fresh install's
    /// defaults, and a running host restarts on the new code.
    fn repackage(
        &self,
        id: &str,
        package: Package,
        source: GitSource,
        consented: bool,
        grant_optional: bool,
    ) -> Result<(), ApiError> {
        let turn = self.commits.lock().recover_poison();
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            let facts = package.facts();
            let before = inner.catalog.packages.get(id).map(Package::facts);
            let mut next = inner.mirror.clone();
            if let Some(record) = next.apps.get_mut(id) {
                record.grants.retain(|s| facts.requested.contains(s) || facts.optional.contains(s));
                if consented {
                    // What the card listed and the person confirmed, as a
                    // fresh install grants it, for the scopes the old commit
                    // did not ask for (a scope they took away stays away).
                    let (confirmed, _) = facts.confirmed_install(grant_optional);
                    let new: Vec<String> = confirmed
                        .into_iter()
                        .filter(|s| {
                            before
                                .as_ref()
                                .is_none_or(|b| !b.requested.contains(s) && !b.optional.contains(s))
                        })
                        .collect();
                    // A new scope that reaches out lifts the sandbox, as it does at install.
                    if new.iter().any(|s| cmux_app_manifest::scope_reaches_out(s)) {
                        record.sandboxed = false;
                    }
                    record.grants.extend(new);
                }
            }
            next.revision += 1;
            self.persist(&next)
                .map_err(|e| ApiError::new("apps.persist", format!("apps.json: {e}")))?;
            inner.mirror = next;
            inner.catalog.packages.insert(id.to_string(), package);
            inner.catalog.git.insert(id.to_string(), source);
            let mut outs = self.regrant_locked(&mut inner, id);
            outs.push(Out::Broadcast(json!({
                "event": "apps-changed",
                "revision": inner.mirror.revision,
                "transaction": "git-update",
                "app": id,
            })));
            outs.extend(Self::inventory_demand_locked(&mut inner));
            outs
        };
        drop(turn);
        self.emit(outs);
        Ok(())
    }

    fn remove_tree(&self, git_dir: &std::path::Path, relative: &str) {
        if let Some(dir) = git_source::inside(git_dir, relative) {
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    /// After an uninstall: a git app's files and record go (its digest stays).
    fn forget_git_app(&self, app: &str) {
        let Ok(git_dir) = self.git_dir() else { return };
        let source = {
            let mut inner = self.inner.lock().recover_poison();
            if inner.mirror.apps.get(app).is_some_and(|r| r.installed) {
                return;
            }
            let Some(source) = inner.catalog.git.remove(app) else { return };
            self.git.staged.lock().recover_poison().retain(|_, s| s.package.id != app);
            self.forget_update_offer(app);
            inner.catalog.packages.remove(app);
            source
        };
        {
            let _index = self.git.index.lock().recover_poison();
            let mut index = Index::load(&git_dir);
            if index.apps.remove(app).is_some() {
                let _ = index.save(&git_dir);
            }
        }
        self.remove_tree(&git_dir, &source.dir);
    }
}
