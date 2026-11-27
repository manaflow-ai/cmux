//! One chat's view of a GitHub branch with nothing cloned: the base read once, files read on
//! first use, edits held in memory, a commit made through the git data API, and a projection of
//! only the paths a command must run.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context as _, bail};
use tokio::sync::Semaphore;

use crate::github::{Entry, GitHub, GitWriter, Head, TreeChange};

/// Blob reads in flight at once for a projection.
const FETCHES_AT_ONCE: usize = 8;

/// An edit to one path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Edit {
    /// New bytes, with the git mode (`100644`, `100755`).
    Put(Vec<u8>, String),
    Delete,
}

/// A file as the chat sees it: the base's, or an edit's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct File {
    pub path: String,
    pub mode: String,
    pub size: u64,
}

/// A GitHub branch, with this chat's edits on top.
pub struct Remote {
    gh: GitHub,
    branch: String,
    head: Head,
    tree: Option<Vec<Entry>>,
    /// Each file of `tree` by path.
    index: HashMap<String, usize>,
    read: HashMap<String, Arc<Vec<u8>>>,
    edits: BTreeMap<String, Edit>,
}

/// A relative path inside the repository: no root, no `..`, no empty part, never `.git`.
pub fn check_path(path: &str) -> anyhow::Result<()> {
    let bad = path.is_empty()
        || path.starts_with('/')
        || path.ends_with('/')
        || path.contains('\0')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == ".." || part == ".git");
    if bad {
        bail!("{path:?} is not a path inside the repository");
    }
    Ok(())
}

/// Whether `path` matches `pattern`: a path, a folder (`dir`, `dir/` or `dir/**`: everything
/// under it), or a glob where `*` stays within one part and `**` spans parts.
#[must_use]
pub fn matches(pattern: &str, path: &str) -> bool {
    let folder = pattern.trim_end_matches("/**").trim_end_matches('/');
    if !folder.contains('*') && (path == folder || path.starts_with(&format!("{folder}/"))) {
        return true;
    }
    let pattern: Vec<&str> = pattern.split('/').collect();
    let path: Vec<&str> = path.split('/').collect();
    glob(&pattern, &path)
}

fn glob(pattern: &[&str], path: &[&str]) -> bool {
    match (pattern.first(), path.first()) {
        (None, None) => true,
        (Some(&"**"), _) => {
            glob(&pattern[1..], path) || (!path.is_empty() && glob(pattern, &path[1..]))
        }
        (Some(part), Some(name)) => {
            part_matches(part.as_bytes(), name.as_bytes()) && glob(&pattern[1..], &path[1..])
        }
        _ => false,
    }
}

fn part_matches(pattern: &[u8], name: &[u8]) -> bool {
    match (pattern.first(), name.first()) {
        (None, None) => true,
        (Some(b'*'), _) => {
            part_matches(&pattern[1..], name)
                || (!name.is_empty() && part_matches(pattern, &name[1..]))
        }
        (Some(p), Some(n)) => p == n && part_matches(&pattern[1..], &name[1..]),
        _ => false,
    }
}

/// A link's target that stays inside the folder it is in.
fn link_stays_inside(path: &str, target: &[u8]) -> bool {
    let Ok(target) = std::str::from_utf8(target) else { return false };
    let mut depth = path.matches('/').count() as i64;
    for part in Path::new(target).components() {
        match part {
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::ParentDir => depth -= 1,
            Component::RootDir | Component::Prefix(_) => return false,
        }
        if depth < 0 {
            return false;
        }
    }
    true
}

impl Remote {
    /// The head of `branch` (the default branch when `None`): one call, two for the default.
    pub async fn open(gh: GitHub, branch: Option<&str>) -> anyhow::Result<Self> {
        let branch = match branch {
            Some(branch) => branch.to_owned(),
            None => gh.default_branch().await?,
        };
        let head = gh.branch_head(&branch).await?;
        Ok(Self {
            gh,
            branch,
            head,
            tree: None,
            index: HashMap::new(),
            read: HashMap::new(),
            edits: BTreeMap::new(),
        })
    }

    #[must_use]
    pub fn github(&self) -> &GitHub {
        &self.gh
    }

    #[must_use]
    pub fn branch(&self) -> &str {
        &self.branch
    }

    #[must_use]
    pub fn head(&self) -> &Head {
        &self.head
    }

    #[must_use]
    pub fn edits(&self) -> &BTreeMap<String, Edit> {
        &self.edits
    }

    async fn entries(&mut self) -> anyhow::Result<&[Entry]> {
        if self.tree.is_none() {
            let tree = self.gh.tree(&self.head.tree).await?;
            self.index = tree
                .iter()
                .enumerate()
                .filter(|(_, e)| e.is_file())
                .map(|(i, e)| (e.path.clone(), i))
                .collect();
            self.tree = Some(tree);
        }
        Ok(self.tree.as_deref().unwrap_or_default())
    }

    async fn base(&mut self, path: &str) -> anyhow::Result<Option<Entry>> {
        self.entries().await?;
        let at = self.index.get(path).copied();
        Ok(at.and_then(|i| self.tree.as_ref()?.get(i)).cloned())
    }

    /// The files whose path matches any of `patterns`, edits applied (deleted ones gone, new ones
    /// there), in path order.
    pub async fn files(&mut self, patterns: &[String]) -> anyhow::Result<Vec<File>> {
        let mut out: BTreeMap<String, File> = BTreeMap::new();
        for e in self.entries().await? {
            if e.is_file() && patterns.iter().any(|p| matches(p, &e.path)) {
                let file =
                    File { path: e.path.clone(), mode: e.mode.clone(), size: e.size.unwrap_or(0) };
                out.insert(e.path.clone(), file);
            }
        }
        for (path, edit) in &self.edits {
            match edit {
                Edit::Put(bytes, mode) if patterns.iter().any(|p| matches(p, path)) => {
                    let file =
                        File { path: path.clone(), mode: mode.clone(), size: bytes.len() as u64 };
                    out.insert(path.clone(), file);
                }
                _ => {
                    out.remove(path);
                }
            }
        }
        Ok(out.into_values().collect())
    }

    /// A file's bytes: this chat's edit, else the base's (read from GitHub once).
    pub async fn read(&mut self, path: &str) -> anyhow::Result<Arc<Vec<u8>>> {
        check_path(path)?;
        match self.edits.get(path) {
            Some(Edit::Put(bytes, _)) => return Ok(Arc::new(bytes.clone())),
            Some(Edit::Delete) => bail!("{path} was deleted in this chat"),
            None => {}
        }
        if let Some(bytes) = self.read.get(path) {
            return Ok(Arc::clone(bytes));
        }
        let entry =
            self.base(path).await?.with_context(|| format!("{path} is not in {}", self.branch))?;
        let bytes = Arc::new(self.gh.blob(&entry.sha).await?);
        self.read.insert(path.to_owned(), Arc::clone(&bytes));
        Ok(bytes)
    }

    /// Sets `path` to `bytes`, keeping the base's mode (or `100644` for a new file).
    pub async fn write(&mut self, path: &str, bytes: Vec<u8>) -> anyhow::Result<()> {
        check_path(path)?;
        let mode = match self.edits.get(path) {
            Some(Edit::Put(_, mode)) => mode.clone(),
            _ => self.base(path).await?.map_or_else(|| "100644".to_owned(), |e| e.mode),
        };
        self.write_mode(path, bytes, &mode)
    }

    /// Sets `path` to `bytes` with git mode `mode`.
    pub fn write_mode(&mut self, path: &str, bytes: Vec<u8>, mode: &str) -> anyhow::Result<()> {
        check_path(path)?;
        if !matches!(mode, "100644" | "100755") {
            bail!("{path}: mode {mode} is not a file's");
        }
        self.edits.insert(path.to_owned(), Edit::Put(bytes, mode.to_owned()));
        Ok(())
    }

    /// Deletes `path`.
    pub async fn delete(&mut self, path: &str) -> anyhow::Result<()> {
        check_path(path)?;
        if self.base(path).await?.is_some() {
            self.edits.insert(path.to_owned(), Edit::Delete);
        } else if self.edits.remove(path).is_none() {
            bail!("{path} is not in {}", self.branch);
        }
        Ok(())
    }

    /// Writes the files matching `patterns`, edits applied, into a new temporary folder that is
    /// deleted when the [`Projected`] drops. Base files are read in parallel; links whose target
    /// leaves the folder and submodules are left out.
    pub async fn project(&mut self, patterns: &[String]) -> anyhow::Result<Projected> {
        let dir = tempfile::Builder::new().prefix("cmux-no-checkout-").tempdir()?;
        let mut projected = Projected {
            dir,
            files: 0,
            bytes: 0,
            links: BTreeMap::new(),
            pending_links: BTreeMap::new(),
        };
        self.project_into(patterns, &mut projected).await?;
        Ok(projected)
    }

    /// [`Self::project`] into an existing projection (more paths for the same run).
    pub async fn project_into(
        &mut self,
        patterns: &[String],
        projected: &mut Projected,
    ) -> anyhow::Result<()> {
        let files = self.files(patterns).await?;
        let gates = Arc::new(Semaphore::new(FETCHES_AT_ONCE));
        let mut fetches = tokio::task::JoinSet::new();
        for file in &files {
            match self.edits.get(&file.path) {
                Some(Edit::Put(bytes, mode)) => {
                    projected.put(&file.path, bytes, mode)?;
                    continue;
                }
                Some(Edit::Delete) => continue,
                None => {}
            }
            if let Some(bytes) = self.read.get(&file.path) {
                projected.put(&file.path, bytes, &file.mode)?;
                continue;
            }
            let Some(entry) = self.base(&file.path).await? else { continue };
            let (gh, gates) = (self.gh.clone(), Arc::clone(&gates));
            fetches.spawn(async move {
                let _gate = gates.acquire_owned().await?;
                let bytes = gh.blob(&entry.sha).await?;
                anyhow::Ok((entry, bytes))
            });
        }
        while let Some(done) = fetches.join_next().await {
            let (entry, bytes) = done??;
            projected.put(&entry.path, &bytes, &entry.mode)?;
            self.read.insert(entry.path, Arc::new(bytes));
        }
        projected.finish_links()
    }

    /// Commits this chat's edits on the base as `branch` (created, or fast-forwarded): one blob
    /// per changed file, a tree on the base tree, a commit, the ref. Answers the commit's sha.
    /// The commit becomes the base: later edits commit on top of it, to the same branch.
    pub async fn commit(&mut self, branch: &str, message: &str) -> anyhow::Result<String> {
        let gh = self.gh.clone();
        self.commit_with(&gh, branch, message).await
    }

    /// [`Self::commit`] through `writer` (the REST client, or one that stands in for it).
    pub async fn commit_with(
        &mut self,
        writer: &dyn GitWriter,
        branch: &str,
        message: &str,
    ) -> anyhow::Result<String> {
        if self.edits.is_empty() {
            bail!("nothing to commit: this chat changed no file");
        }
        let mut changes = Vec::with_capacity(self.edits.len());
        for (path, edit) in &self.edits {
            let blob = match edit {
                Edit::Put(bytes, mode) => Some((writer.create_blob(bytes).await?, mode.clone())),
                Edit::Delete => None,
            };
            changes.push(TreeChange { path: path.clone(), blob });
        }
        let tree = writer.create_tree(&self.head.tree, &changes).await?;
        let commit = writer.create_commit(message, &tree, &self.head.commit).await?;
        writer.set_branch(branch, &commit).await?;
        for (path, edit) in std::mem::take(&mut self.edits) {
            match edit {
                Edit::Put(bytes, _) => self.read.insert(path, Arc::new(bytes)),
                Edit::Delete => self.read.remove(&path),
            };
        }
        self.head = Head { commit: commit.clone(), tree };
        self.branch = branch.to_owned();
        self.tree = None;
        self.index.clear();
        Ok(commit)
    }
}

/// Paths written to a temporary folder for one run; the folder is deleted on drop.
pub struct Projected {
    dir: tempfile::TempDir,
    links: BTreeMap<String, PathBuf>,
    pending_links: BTreeMap<String, PathBuf>,
    pub files: u64,
    pub bytes: u64,
}

impl Projected {
    #[must_use]
    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    fn put(&mut self, path: &str, bytes: &[u8], mode: &str) -> anyhow::Result<()> {
        check_path(path)?;
        let at = self.dir.path().join(path);
        // Never let an earlier projection (or a command run in it) redirect a write.
        let mut parent = self.dir.path().to_owned();
        for part in path.split('/').take(path.split('/').count() - 1) {
            parent.push(part);
            match std::fs::symlink_metadata(&parent) {
                Ok(meta) if meta.is_dir() => {}
                Ok(_) => bail!("{path}: projection parent is not a directory"),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => std::fs::create_dir(&parent)?,
                Err(e) => return Err(e.into()),
            }
        }
        if std::fs::symlink_metadata(&at).is_ok_and(|meta| meta.file_type().is_symlink()) {
            bail!("{path}: projection would overwrite a symbolic link");
        }
        match mode {
            "120000" => {
                if !link_stays_inside(path, bytes) {
                    return Ok(());
                }
                let target = std::str::from_utf8(bytes).context("a link's target is not UTF-8")?;
                // Blob completion order must not decide whether a chain escapes. Validate the
                // whole batch, including links from earlier project_into calls, before installing it.
                self.pending_links.insert(path.to_owned(), PathBuf::from(target));
                return Ok(());
            }
            "100644" | "100755" => {
                std::fs::write(&at, bytes)?;
                if mode == "100755" {
                    use std::os::unix::fs::PermissionsExt as _;
                    std::fs::set_permissions(&at, std::fs::Permissions::from_mode(0o755))?;
                }
            }
            _ => return Ok(()),
        }
        self.files += 1;
        self.bytes += bytes.len() as u64;
        Ok(())
    }

    fn finish_links(&mut self) -> anyhow::Result<()> {
        let pending = std::mem::take(&mut self.pending_links);
        for path in self.links.keys() {
            if !self.link_resolves_inside(path, &pending) {
                bail!("{path}: new projection would redirect an existing link outside its folder");
            }
        }
        let safe: Vec<_> = pending
            .iter()
            .filter(|(path, _)| self.link_resolves_inside(path, &pending))
            .map(|(path, target)| (path.clone(), target.clone()))
            .collect();
        for (path, target) in safe {
            std::os::unix::fs::symlink(&target, self.dir.path().join(&path))?;
            self.files += 1;
            self.bytes += target.as_os_str().len() as u64;
            self.links.insert(path, target);
        }
        Ok(())
    }

    fn link_resolves_inside(&self, path: &str, links: &BTreeMap<String, PathBuf>) -> bool {
        let mut todo: VecDeque<_> =
            Path::new(path).components().map(|c| c.as_os_str().to_owned()).collect();
        let mut resolved = PathBuf::new();
        let mut followed = 0;
        while let Some(part) = todo.pop_front() {
            if part == "." {
                continue;
            }
            if part == ".." {
                if !resolved.pop() {
                    return false;
                }
                continue;
            }
            if Path::new(&part).is_absolute() {
                return false;
            }
            resolved.push(part);
            let target = if let Some(target) = links.get(resolved.to_str().unwrap_or_default()) {
                Some(target.clone())
            } else {
                let at = self.dir.path().join(&resolved);
                match std::fs::symlink_metadata(&at) {
                    Ok(meta) if meta.file_type().is_symlink() => {
                        let Ok(target) = std::fs::read_link(at) else { return false };
                        Some(target)
                    }
                    Ok(_) => None,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                    Err(_) => return false,
                }
            };
            if let Some(target) = target {
                // Match the kernel's symlink traversal limit, including cycles.
                followed += 1;
                if followed > 40 || target.is_absolute() {
                    return false;
                }
                resolved.pop();
                for part in target.components().rev() {
                    todo.push_front(part.as_os_str().to_owned());
                }
            }
        }
        true
    }

    /// Deletes the folder now, saying so when it cannot (a drop would only try).
    pub fn close(self) -> anyhow::Result<()> {
        self.dir.close().context("could not delete the projected folder")
    }
}

#[cfg(test)]
#[path = "remote_tests.rs"]
mod tests;
