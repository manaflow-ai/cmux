//! Real git repositories for the tests: a bare remote with one commit on `main`, a laptop's
//! clone of it, and a folder's snapshot in the form a manifest names (a bundle of the commits
//! past the base, a binary patch of the uncommitted work).

use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_auto_session::wire::Cwd;

/// Runs git in `dir`; its output, trimmed. Panics when git fails.
pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"])
        .args(args)
        .output()
        .expect("git runs");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "git {args:?} in {}: {err}", dir.display());
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

pub fn write(dir: &Path, name: &str, text: &str) {
    std::fs::write(dir.join(name), text).unwrap();
}

pub fn read(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_default()
}

/// A remote and a laptop's clone of it.
pub struct Repos {
    pub dir: tempfile::TempDir,
    /// The bare remote.
    pub remote: PathBuf,
    /// The laptop's folder: `main` at the remote's commit.
    pub laptop: PathBuf,
    /// The commit the remote has.
    pub base: String,
}

impl Repos {
    /// The remote as a manifest names it.
    pub fn remote_url(&self) -> String {
        self.remote.to_string_lossy().into_owned()
    }

    /// A folder under the tests' temp folder that does not exist yet.
    pub fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }
}

/// A remote whose `main` has `README.md` ("base"), and a laptop's clone at that commit.
pub fn repos() -> Repos {
    let dir = tempfile::tempdir().unwrap();
    let (remote, laptop) = (dir.path().join("remote.git"), dir.path().join("laptop"));
    std::fs::create_dir_all(&remote).unwrap();
    std::fs::create_dir_all(&laptop).unwrap();
    git(&remote, &["init", "-q", "--bare"]);
    git(&laptop, &["init", "-q"]);
    write(&laptop, "README.md", "base\n");
    git(&laptop, &["add", "README.md"]);
    git(&laptop, &["commit", "-q", "-m", "base"]);
    git(&laptop, &["remote", "add", "origin", &remote.to_string_lossy()]);
    git(&laptop, &["push", "-q", "origin", "main"]);
    let base = git(&laptop, &["rev-parse", "HEAD"]);
    Repos { dir, remote, laptop, base }
}

/// The folder `dir` as a snapshot: the bundle of its commits past `base` and the patch of its
/// uncommitted tracked changes. Either is empty when there is nothing of its kind.
pub fn carry(dir: &Path, base: &str, scratch: &Path) -> (Vec<u8>, Vec<u8>) {
    let (bundle, patch) = (scratch.join("carry.bundle"), scratch.join("carry.patch"));
    let _ = std::fs::remove_file(&bundle);
    if git(dir, &["rev-parse", "HEAD"]) != base {
        let range = format!("{base}..main");
        git(dir, &["bundle", "create", "-q", &bundle.to_string_lossy(), &range]);
    }
    let output = format!("--output={}", patch.display());
    git(dir, &["diff", "--binary", "--full-index", &output, "HEAD"]);
    (std::fs::read(&bundle).unwrap_or_default(), std::fs::read(&patch).unwrap_or_default())
}

/// The manifest's `cwd` of a git folder on `main` whose files are the chunks `bundle` and
/// `patch`.
pub fn git_cwd(repos: &Repos, bundle: Vec<String>, patch: Vec<String>) -> Cwd {
    let (remote, base) = (repos.remote_url(), repos.base.clone());
    Cwd::Git { remote, branch: "main".into(), base, bundle, patch }
}
