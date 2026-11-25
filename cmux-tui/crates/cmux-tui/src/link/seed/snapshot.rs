//! A snapshot commit of any folder, git or not (RFD 0066, "What to build next" 5 and 6): the
//! working tree as one commit, made without touching the person's index, HEAD, refs or object
//! store, and written as one bundle.
//!
//! The commit is built in a scratch bare repository of ours (`store`, under this Mac's state
//! folder for the copy's base record: [`store_for`]), with a scratch index and the folder as
//! the work tree. When the folder is the top of a git working copy, the store borrows its
//! objects through `objects/info/alternates`, the scratch index starts as a copy of the
//! person's (so tracked files the person forced past `.gitignore` stay and unchanged files are
//! not hashed again), its `info/exclude` is read too, and the commit's parent is HEAD. A
//! folder that is not git (or is only inside one) gets the same with no alternates and no
//! parent. `git add -A` reads `.gitignore` either way. Every new blob, tree and commit lands in
//! the store, never in the person's repository.
//!
//! Left out, each named in [`Snapshot::skipped`]: untracked files the copy leaves out as
//! secrets (`skips::secret_text`: `.env*`, keys, credential files and folders) and heavy
//! folders the project rebuilds. A file the person tracks in git travels, as on every route.
//!
//! A git repository nested in the folder (not a submodule) is snapshotted the same way as its
//! own commit, recorded in the outer tree as a gitlink to it and carried by the bundle as
//! `refs/cmux-snapshot/nested/N` ([`Snapshot::nested`]). Empty folders, which a tree cannot
//! hold, are named in [`Snapshot::empty_folders`] and in the commit message, one
//! `empty: PATH` line each, so the bundle carries them.
//!
//! The bundle holds `refs/cmux-snapshot/work` (and the nested refs) with everything they reach;
//! given the commit of an earlier snapshot the receiver has, it is a thin bundle of only what
//! changed since. The same folder in the same state on the same HEAD gives the same commit.

use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::DirBuilderExt as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use sha2::{Digest as _, Sha256};

use super::super::sync_cli;
use super::git;
use super::plan::Skipped;
use crate::link::sync_cli::skips;

/// The ref of the folder's snapshot commit in the store and the bundle.
pub(crate) const WORK_REF: &str = "refs/cmux-snapshot/work";
/// The prefix of the nested repositories' snapshot refs (`refs/cmux-snapshot/nested/N`).
pub(crate) const NESTED_PREFIX: &str = "refs/cmux-snapshot/nested/";

/// The fixed identity and date of a snapshot commit, so the same tree on the same parent
/// always gives the same commit.
const NAME: &str = "cmux snapshot";
const EMAIL: &str = "snapshot@cmux.invalid";
const DATE: &str = "946684800 +0000";

/// The switch for the copy's snapshot base record (off by default: RFD 0066 open question 2).
pub(crate) const ENV: &str = "CMUX_LINK_SNAPSHOT_BASE";

/// Whether a copy keeps a snapshot as its base record ([`ENV`] is `1` or `true`).
pub(crate) fn enabled() -> bool {
    matches!(std::env::var(ENV).ok().as_deref(), Some("1" | "true"))
}

/// A snapshot made and its bundle written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Snapshot {
    /// The snapshot commit (`refs/cmux-snapshot/work`).
    pub commit: String,
    /// Its parent: HEAD of the folder's repository; for a folder that is not git, the earlier
    /// snapshot it was made since, else None.
    pub parent: Option<String>,
    /// Whether the folder is the top of a git working copy.
    pub git: bool,
    pub skipped: Vec<Skipped>,
    /// Empty folders (`/`-separated, from the top), which the tree cannot hold.
    pub empty_folders: Vec<String>,
    pub nested: Vec<Nested>,
    /// Bytes of the bundle; 0 when [`Self::unchanged`] (no bundle is written then).
    pub bundle_bytes: u64,
    /// The earlier snapshot the bundle is thin against, when it is.
    pub since: Option<String>,
    /// The snapshot is the `since` one: nothing to send.
    pub unchanged: bool,
}

/// A git repository nested in the folder and its own snapshot commit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Nested {
    /// From the top, `/`-separated, no trailing `/`.
    pub path: String,
    pub commit: String,
    /// The ref that carries it in the bundle.
    pub reference: String,
}

/// The store of `folder`'s snapshots: `<state>/link-snapshot/<sha256 of folder>/store.git`.
pub(crate) fn store_for(folder: &Path) -> Option<PathBuf> {
    let state = cmux_tui_core::platform::workspace_state_dir()?;
    let key: String = Sha256::digest(folder.as_os_str().as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Some(state.join("link-snapshot").join(key).join("store.git"))
}

/// Snapshots `folder` into the bare repository `store` (made when missing) and writes its
/// bundle to `out_bundle`, thin against `since` when that is an earlier snapshot's commit the
/// store still has (module docs).
pub(crate) fn snapshot(
    folder: &Path,
    store: &Path,
    out_bundle: &Path,
    since: Option<&str>,
) -> Result<Snapshot, String> {
    let folder = std::fs::canonicalize(folder)
        .map_err(|error| format!("cannot open {}: {error}", folder.display()))?;
    open_store(store)?;
    let mut made = Made { store: store.to_path_buf(), alternates: Vec::new(), nested: Vec::new() };
    let since = since.filter(|id| has_commit(store, id)).map(str::to_string);
    let top = made.tree(&folder, "", since.as_deref())?;
    let nested = made.nested;

    let stale =
        git::text(git::bare(store).args(["for-each-ref", "--format=%(refname)", NESTED_PREFIX]))
            .map_err(|error| format!("listing old snapshot refs: {error}"))?;
    for name in stale.lines().filter(|line| !line.is_empty()) {
        run(git::bare(store).args(["update-ref", "-d", name]), "dropping an old snapshot ref")?;
    }
    run(git::bare(store).args(["update-ref", WORK_REF, &top.commit]), "naming the snapshot")?;
    for item in &nested {
        run(
            git::bare(store).args(["update-ref", &item.reference, &item.commit]),
            "naming a nested snapshot",
        )?;
    }

    let unchanged = since.as_deref() == Some(top.commit.as_str());
    let mut bundle_bytes = 0;
    let mut thin = since.clone().filter(|_| !unchanged);
    if !unchanged {
        let refs: Vec<&str> = std::iter::once(WORK_REF)
            .chain(nested.iter().map(|item| item.reference.as_str()))
            .collect();
        let made_thin = match &thin {
            Some(previous) => bundle(store, out_bundle, &refs, &excluded(store, previous)).is_ok(),
            None => false,
        };
        if !made_thin {
            thin = None;
            bundle(store, out_bundle, &refs, &[])?;
        }
        bundle_bytes = std::fs::metadata(out_bundle)
            .map_err(|error| format!("reading the bundle: {error}"))?
            .len();
    }
    Ok(Snapshot {
        commit: top.commit,
        parent: top.parent,
        git: top.git,
        skipped: top.skipped,
        empty_folders: top.empty_folders,
        nested,
        bundle_bytes,
        since: thin,
        unchanged,
    })
}

/// A bare store of ours, made once, with gc off for good: its unreferenced earlier snapshots
/// are what a thin bundle builds on.
fn open_store(store: &Path) -> Result<(), String> {
    if store.join("HEAD").is_file() {
        return Ok(());
    }
    if let Some(parent) = store.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|error| format!("making {}: {error}", parent.display()))?;
    }
    let parent = store.parent().unwrap_or(Path::new("/"));
    run(
        git::at(parent).args(["init", "-q", "--bare", "--template="]).arg(store),
        "making the snapshot store",
    )?;
    run(git::bare(store).args(["config", "gc.auto", "0"]), "configuring the snapshot store")
}

fn has_commit(store: &Path, id: &str) -> bool {
    git::output(git::bare(store).args(["cat-file", "-e", &format!("{id}^{{commit}}")])).is_ok()
}

/// What a bundle thin against the snapshot `previous` leaves out: it and its tree (the new
/// commit is its sibling on HEAD, not its child, so git would not look inside it otherwise),
/// and the same for each nested snapshot its tree links to.
fn excluded(store: &Path, previous: &str) -> Vec<String> {
    let mut ids = vec![previous.to_string()];
    let links =
        git::text(git::bare(store).args(["ls-tree", "-r", "-z", previous])).unwrap_or_default();
    for entry in links.split('\0') {
        let mut fields = entry.split([' ', '\t']);
        if fields.next() == Some("160000") && fields.next() == Some("commit") {
            if let Some(id) = fields.next().filter(|id| has_commit(store, id)) {
                ids.push(id.to_string());
            }
        }
    }
    ids.iter().flat_map(|id| [format!("^{id}"), format!("^{id}^{{tree}}")]).collect()
}

fn bundle(store: &Path, out: &Path, refs: &[&str], excluded: &[String]) -> Result<(), String> {
    let _ = std::fs::remove_file(out);
    run(
        git::bare(store).args(["bundle", "create", "-q"]).arg(out).args(refs).args(excluded),
        "making the snapshot bundle",
    )
}

/// One snapshot commit and what it left out.
struct Tree {
    commit: String,
    parent: Option<String>,
    git: bool,
    skipped: Vec<Skipped>,
    empty_folders: Vec<String>,
}

/// The run's store, the object stores it borrows so far, and the nested snapshots made.
struct Made {
    store: PathBuf,
    alternates: Vec<PathBuf>,
    nested: Vec<Nested>,
}

impl Made {
    /// git in the store with `work` as the work tree and `index` as the index.
    fn git(&self, work: &Path, index: &Path) -> git::GitCommand {
        let mut command = git::bare(&self.store);
        command.arg("--work-tree").arg(work).env("GIT_INDEX_FILE", index);
        command.args(["-c", "core.untrackedCache=false", "-c", "core.bare=false"]);
        command
    }

    /// The store's `info/exclude`: a copy of the person's repository's, else none.
    fn exclude(&self, repo: Option<&Repository>) -> Result<(), String> {
        let exclude = self.store.join("info/exclude");
        let _ = std::fs::remove_file(&exclude);
        if let Some(repo) = repo.filter(|repo| repo.exclude.is_file()) {
            std::fs::create_dir_all(self.store.join("info")).map_err(|error| error.to_string())?;
            std::fs::copy(&repo.exclude, &exclude)
                .map_err(|error| format!("copying info/exclude: {error}"))?;
        }
        Ok(())
    }

    fn borrow(&mut self, objects: PathBuf) -> Result<(), String> {
        if !self.alternates.contains(&objects) {
            self.alternates.push(objects);
        }
        let info = self.store.join("objects/info");
        std::fs::create_dir_all(&info)
            .map_err(|error| format!("making {}: {error}", info.display()))?;
        let mut text = Vec::new();
        for path in &self.alternates {
            text.extend_from_slice(path.as_os_str().as_bytes());
            text.push(b'\n');
        }
        write(&info.join("alternates"), text)
    }

    /// The snapshot commit of the work tree `work` (`prefix` is its path from the outer top,
    /// with a trailing `/`, empty for the top), nested repositories first.
    fn tree(&mut self, work: &Path, prefix: &str, since: Option<&str>) -> Result<Tree, String> {
        let repo = repository(work);
        let scratch = ScratchIndex::new(&self.store)?;
        let index = scratch.0.as_path();
        let mut parent = None;
        if let Some(repo) = &repo {
            self.borrow(repo.objects.clone())?;
            parent = repo.head.clone();
            if repo.index.is_file() {
                std::fs::copy(&repo.index, index)
                    .map_err(|error| format!("copying the index: {error}"))?;
            } else if let Some(head) = &repo.head {
                run(self.git(work, index).args(["read-tree", head]), "reading HEAD")?;
            }
        } else if prefix.is_empty() {
            // A not-git folder's snapshots follow one another in the store.
            parent = since.map(str::to_string);
        }
        self.exclude(repo.as_ref())?;

        let listed = git::output(self.git(work, index).args([
            "ls-files",
            "-z",
            "--others",
            "--exclude-standard",
        ]))
        .map_err(|error| format!("listing untracked files: {error}"))?;
        let mut skipped = Vec::new();
        let mut nested_paths = Vec::new();
        let mut heavy = std::collections::BTreeSet::new();
        for raw in listed.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
            let path = String::from_utf8_lossy(raw).into_owned();
            if let Some(folder) = path.strip_suffix('/') {
                nested_paths
                    .push((folder.to_string(), raw.strip_suffix(b"/").unwrap_or(raw).to_vec()));
                continue;
            }
            if let Some((folder, why)) =
                std::str::from_utf8(raw).ok().and_then(|name| sync_cli::heavy_folder(work, name))
            {
                if heavy.insert(folder.clone()) {
                    skipped.push(Skipped {
                        raw: folder.clone().into_bytes(),
                        path: format!("{prefix}{folder}"),
                        why: why.to_string(),
                    });
                }
                continue;
            }
            if let Some(why) = skips::secret_text(work, &path) {
                skipped.push(Skipped {
                    path: format!("{prefix}{path}"),
                    why: why.to_string(),
                    raw: raw.to_vec(),
                });
            }
        }
        let own = skipped.clone();
        let mut links = Vec::new();
        for (path, raw) in &nested_paths {
            let inner = self.tree(
                &work.join(std::ffi::OsStr::from_bytes(raw)),
                &format!("{prefix}{path}/"),
                None,
            )?;
            let reference = format!("{NESTED_PREFIX}{}", self.nested.len());
            self.nested.push(Nested {
                path: format!("{prefix}{path}"),
                commit: inner.commit.clone(),
                reference,
            });
            skipped.extend(inner.skipped);
            links.push((raw.clone(), inner.commit, inner.empty_folders));
        }
        if !links.is_empty() {
            self.exclude(repo.as_ref())?;
        }

        // Left-out paths never enter the add, so no blob of a secret is ever written.
        let list = scratch.0.with_extension("pathspecs");
        let mut paths = b".\0".to_vec();
        for raw in own
            .iter()
            .map(|item| item.raw.clone())
            .chain(nested_paths.iter().map(|(_, raw)| raw.clone()))
        {
            paths.extend_from_slice(b":(exclude,literal)");
            paths.extend_from_slice(raw.strip_suffix(b"/").unwrap_or(&raw));
            paths.push(0);
        }
        write(&list, paths)?;
        let added = run(
            self.git(work, index)
                .args(["add", "-A", "--pathspec-file-nul"])
                .arg(format!("--pathspec-from-file={}", list.display())),
            "adding the working tree",
        );
        let _ = std::fs::remove_file(&list);
        added?;
        let mut empty_folders = Vec::new();
        for (raw, commit, inner_empty) in links {
            let path = String::from_utf8_lossy(&raw).into_owned();
            run(
                self.git(work, index)
                    .args(["update-index", "--add", "--cacheinfo"])
                    .arg(format!("160000,{commit},{path}")),
                "linking a nested repository",
            )?;
            empty_folders.extend(inner_empty);
        }
        empty_folders.extend(self.empty_folders(work, index, prefix, &own)?);
        empty_folders.sort();

        let tree = git::text(self.git(work, index).arg("write-tree"))
            .map_err(|error| format!("writing the snapshot tree: {error}"))?;
        let mut message = String::from("cmux snapshot\n");
        if !empty_folders.is_empty() {
            message.push('\n');
            for folder in &empty_folders {
                message.push_str(&format!("empty: {folder}\n"));
            }
        }
        let mut commit = git::bare(&self.store);
        commit
            .env("GIT_AUTHOR_NAME", NAME)
            .env("GIT_AUTHOR_EMAIL", EMAIL)
            .env("GIT_AUTHOR_DATE", DATE)
            .env("GIT_COMMITTER_NAME", NAME)
            .env("GIT_COMMITTER_EMAIL", EMAIL)
            .env("GIT_COMMITTER_DATE", DATE)
            .args(["commit-tree", "--no-gpg-sign"]);
        if let Some(parent) = &parent {
            commit.args(["-p", parent]);
        }
        let mut commit = git::text(commit.args(["-m", &message, &tree]))
            .map_err(|error| format!("making the snapshot commit: {error}"))?;
        // A not-git folder as the last snapshot left it is that snapshot, not a child of it.
        if let (None, Some(previous)) = (&repo, since.filter(|_| prefix.is_empty())) {
            let same = git::text(
                git::bare(&self.store).args(["rev-parse", &format!("{previous}^{{tree}}")]),
            )
            .is_ok_and(|old| old == tree)
                && git::text(git::bare(&self.store).args(["log", "-1", "--format=%B", previous]))
                    .is_ok_and(|old| old.trim_end() == message.trim_end());
            if same {
                commit = previous.to_string();
                parent = git::optional(git::bare(&self.store).args([
                    "rev-parse",
                    "-q",
                    "--verify",
                    &format!("{previous}^1"),
                ]));
            }
        }
        Ok(Tree { commit, parent, git: repo.is_some(), skipped, empty_folders })
    }

    /// The empty folders of `work` the snapshot keeps: under the folders git still calls
    /// untracked once everything else is added (a nested repository's and a left-out heavy
    /// folder's aside), each one with nothing in it.
    fn empty_folders(
        &self,
        work: &Path,
        index: &Path,
        prefix: &str,
        skipped: &[Skipped],
    ) -> Result<Vec<String>, String> {
        let listed = git::output(self.git(work, index).args([
            "ls-files",
            "-z",
            "--others",
            "--directory",
            "--exclude-standard",
        ]))
        .map_err(|error| format!("listing folders: {error}"))?;
        let mut found = Vec::new();
        for raw in listed.split(|byte| *byte == 0).filter(|path| path.ends_with(b"/")) {
            let trimmed = raw.strip_suffix(b"/").unwrap_or(raw);
            let relative = String::from_utf8_lossy(raw).trim_end_matches('/').to_string();
            let path = work.join(std::ffi::OsStr::from_bytes(trimmed));
            if path.join(".git").exists()
                || skipped.iter().any(|item| item.raw.strip_suffix(b"/") == Some(trimmed))
            {
                continue;
            }
            empty_under(&path, &format!("{prefix}{relative}"), &mut found);
        }
        Ok(found)
    }
}

/// Every folder at or under `path` that holds nothing at all, by `shown` name; no symlink is
/// followed.
fn empty_under(path: &Path, shown: &str, found: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(path) else { return };
    let mut any = false;
    for entry in entries.flatten() {
        any = true;
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) && entry.file_name() != ".git" {
            let name = entry.file_name();
            empty_under(&entry.path(), &format!("{shown}/{}", name.to_string_lossy()), found);
        }
    }
    if !any {
        found.push(shown.to_string());
    }
}

/// The person's repository whose top is `work`.
struct Repository {
    objects: PathBuf,
    index: PathBuf,
    exclude: PathBuf,
    head: Option<String>,
}

/// The git working copy whose top folder is `work`; None for a folder that is not one (a
/// folder inside a working copy is not its top, so it is snapshotted as a plain folder).
fn repository(work: &Path) -> Option<Repository> {
    let top = git::text(git::at(work).args(["rev-parse", "--show-toplevel"])).ok()?;
    if std::fs::canonicalize(&top).ok()? != std::fs::canonicalize(work).ok()? {
        return None;
    }
    let path = |name: &str| {
        git::text(git::at(work).args(["rev-parse", "--path-format=absolute", "--git-path", name]))
            .ok()
            .map(PathBuf::from)
    };
    Some(Repository {
        objects: path("objects")?,
        index: path("index")?,
        exclude: path("info/exclude")?,
        head: git::optional(git::at(work).args(["rev-parse", "--verify", "-q", "HEAD^{commit}"])),
    })
}

/// A scratch index file in the store, removed when dropped.
struct ScratchIndex(PathBuf);

impl ScratchIndex {
    fn new(store: &Path) -> Result<Self, String> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        for attempt in 0..32u32 {
            let path = store.join(format!("index-{}-{nanos}-{attempt}", std::process::id()));
            if !path.exists() {
                return Ok(Self(path));
            }
        }
        Err("every scratch index name was taken".to_string())
    }
}

impl Drop for ScratchIndex {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_file(self.0.with_extension("lock"));
    }
}

fn run(command: &mut git::GitCommand, what: &str) -> Result<(), String> {
    git::output(command).map(drop).map_err(|error| format!("{what}: {error}"))
}

fn write(path: &Path, contents: impl AsRef<[u8]>) -> Result<(), String> {
    std::fs::write(path, contents).map_err(|error| format!("writing {}: {error}", path.display()))
}
