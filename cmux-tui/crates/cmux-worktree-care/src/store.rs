//! The archive store: one manifest per reclaimed worktree (`<id>.json`),
//! and a bundle of its archive commit when it had work only there
//! (`<id>.bundle`), in `~/.cmux/worktree-archive` unless the caller names
//! another folder. A manifest is written whole to a temporary file and
//! renamed, so a reader never sees half of one.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::inventory::Sparse;

/// A reclaimed worktree: enough to put it back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub id: String,
    pub created_ms: u64,
    pub path: PathBuf,
    pub common_dir: PathBuf,
    pub main_root: Option<PathBuf>,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// `refs/cmux/archive/<id>` in the repository, when the worktree had
    /// work only there: a commit of its files whose parents are HEAD and a
    /// commit of its index (the shape of `git stash`).
    pub archive_ref: Option<String>,
    pub archive_commit: Option<String>,
    /// The bundle copy of the archive commit, next to the manifest.
    pub bundle: Option<PathBuf>,
    pub sparse: Option<Sparse>,
    pub submodules: Vec<String>,
    /// Build output dropped with the folder (relative paths).
    pub dropped: Vec<String>,
    pub reason: String,
    /// Bytes the disk gained.
    pub freed: u64,
    /// Set once the worktree is back.
    #[serde(default)]
    pub restored_ms: Option<u64>,
}

/// The folder manifests and bundles live in.
#[derive(Debug, Clone)]
pub struct Store {
    pub dir: PathBuf,
}

impl Store {
    /// `~/.cmux/worktree-archive`.
    pub fn default_dir() -> Option<PathBuf> {
        std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cmux/worktree-archive"))
    }

    pub fn open(dir: PathBuf) -> Result<Self, String> {
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        Ok(Self { dir })
    }

    pub fn manifest_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    pub fn bundle_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.bundle"))
    }

    /// The bounded finished-answer memo shared by every daemon on this host.
    pub fn finished_path(&self) -> PathBuf {
        self.dir.join("finished-answers.json")
    }

    pub fn save(&self, manifest: &Manifest) -> Result<(), String> {
        let path = self.manifest_path(&manifest.id);
        let temporary = self.dir.join(format!(".{}.json.tmp", manifest.id));
        let text = serde_json::to_vec_pretty(manifest).map_err(|e| e.to_string())?;
        std::fs::write(&temporary, text).map_err(|e| format!("{}: {e}", temporary.display()))?;
        std::fs::rename(&temporary, &path).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn load(&self, id: &str) -> Result<Manifest, String> {
        let path = self.manifest_path(id);
        let text = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_slice(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Every manifest, newest first; unreadable files are skipped.
    pub fn list(&self) -> Vec<Manifest> {
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return Vec::new() };
        let mut manifests: Vec<Manifest> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
            // The finished-answer memo shares this directory but is not a
            // manifest. In particular, do not read it here: FinishedMemo
            // owns its bounded, validated loader.
            .filter(|path| path.file_name().is_none_or(|name| name != "finished-answers.json"))
            .filter_map(|path| std::fs::read(path).ok())
            .filter_map(|bytes| serde_json::from_slice(&bytes).ok())
            .collect();
        manifests.sort_by_key(|manifest| std::cmp::Reverse(manifest.created_ms));
        manifests
    }

    /// The newest manifest of a worktree that is not back yet, by its
    /// folder, its branch or its id.
    pub fn find(&self, key: &str) -> Option<Manifest> {
        let path = Path::new(key);
        self.list()
            .into_iter()
            .filter(|m| m.restored_ms.is_none())
            .find(|m| m.id == key || m.branch.as_deref() == Some(key) || same_folder(&m.path, path))
    }
}

/// `path` with its nearest existing ancestor resolved through links and the
/// rest kept as written. A reclaimed worktree's folder no longer exists, so
/// canonicalizing it fails; its parent still does. `~/.cmux/worktrees` is a
/// link to `~/.cmux/worktrees.noindex` on macOS, and git records a worktree
/// added through it by the real path, while a session keeps the path it was
/// given: both resolve to the same folder here.
pub fn resolved(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut at = path;
    loop {
        if let Ok(real) = std::fs::canonicalize(at) {
            return rest.iter().rev().fold(real, |acc, part| acc.join(part));
        }
        match (at.parent(), at.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_os_string());
                at = parent;
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// Whether two paths name the same folder, whether or not it exists now.
pub fn same_folder(a: &Path, b: &Path) -> bool {
    a == b || resolved(a) == resolved(b)
}

/// Whether `path` is `folder` or inside it, whether or not either exists now.
pub fn inside_folder(path: &Path, folder: &Path) -> bool {
    path.starts_with(folder) || resolved(path).starts_with(resolved(folder))
}

/// A new archive id: the time and the folder's name, readable in a listing
/// and safe in a ref name.
pub fn new_id(now_ms: u64, path: &Path) -> String {
    let name: String = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .take(48)
        .collect();
    let name = name.trim_matches('-');
    if name.is_empty() { format!("{now_ms}") } else { format!("{now_ms}-{name}") }
}

#[cfg(test)]
pub(crate) mod care_tests {
    use super::*;

    /// A fresh empty folder for one test.
    pub(crate) fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cmux-worktree-care-{name}-{}-{}",
            std::process::id(),
            crate::inventory::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn an_id_is_safe_in_a_ref_name() {
        assert_eq!(new_id(5, Path::new("/w/fix login.x")), "5-fix-login-x");
        assert_eq!(new_id(5, Path::new("/")), "5");
    }

    #[test]
    fn a_saved_manifest_is_found_by_folder_branch_or_id() {
        let store = Store::open(scratch("store")).unwrap();
        let manifest = Manifest {
            id: "1-a".into(),
            created_ms: 1,
            path: "/w/a".into(),
            common_dir: "/r/.git".into(),
            main_root: Some("/r".into()),
            branch: Some("feat/a".into()),
            head: None,
            archive_ref: None,
            archive_commit: None,
            bundle: None,
            sparse: None,
            submodules: vec![],
            dropped: vec![],
            reason: "test".into(),
            freed: 0,
            restored_ms: None,
        };
        store.save(&manifest).unwrap();
        assert_eq!(store.find("/w/a").as_ref(), Some(&manifest));
        assert_eq!(store.find("feat/a").as_ref(), Some(&manifest));
        assert_eq!(store.load("1-a").unwrap(), manifest);
        store.save(&Manifest { restored_ms: Some(2), ..manifest }).unwrap();
        assert!(store.find("1-a").is_none());
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_gone_folder_matches_through_a_linked_parent() {
        let dir = std::env::temp_dir().join(format!("cmux-care-resolved-{}", std::process::id()));
        let real = dir.join("worktrees.noindex");
        std::fs::create_dir_all(real.join("app")).unwrap();
        let link = dir.join("worktrees");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink("worktrees.noindex", &link).unwrap();
        // git recorded the real path; the session kept the linked one; the folder is gone
        let recorded = real.join("app/fix-retry");
        let cwd = link.join("app/fix-retry");
        assert!(same_folder(&recorded, &cwd));
        assert!(inside_folder(&cwd.join("sub"), &recorded));
        assert!(!same_folder(&recorded, &link.join("app/other")));
        // A live session registered with the linked cwd still holds the worktree git lists by
        // its real path, so a cleanup pass keeps it.
        std::fs::create_dir_all(&recorded).unwrap();
        let session = [crate::procs::Process { pid: u32::MAX, cwd: cwd.join("src") }];
        assert!(crate::procs::inside(&session, &recorded).is_some());
        assert!(crate::procs::inside(&session, &real.join("app/other")).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
