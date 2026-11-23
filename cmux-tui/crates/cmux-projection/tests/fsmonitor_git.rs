//! git's fsmonitor hook answered by a mounted projection (RFD 0007, hard case 2), end to end: a
//! real repo projected through FUSE, git running `cmux-projection fsmonitor-hook`, and every
//! `git status` with the hook equal to one without it.
#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use cmux_projection::manifest::{Item, Kind, Manifest};
use cmux_projection::overlay::Overlay;
use cmux_projection::{Fetch, FetchError};

struct Files(HashMap<u32, Vec<u8>>);

impl Fetch for Files {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.0.get(entry).cloned().ok_or(FetchError::Failed)).collect()
    }
}

fn usable() -> bool {
    let ok = |program: &str, arg: &str| {
        Command::new(program).arg(arg).output().is_ok_and(|output| output.status.success())
    };
    Path::new("/dev/fuse").exists() && ok("fusermount3", "--version") && ok("git", "--version")
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .args(["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

/// Every path under `root` as manifest items, and the files' bytes by path.
fn walk(root: &Path) -> (Vec<Item>, HashMap<String, Vec<u8>>) {
    let (mut items, mut bytes) = (Vec::new(), HashMap::new());
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            let meta = std::fs::symlink_metadata(&path).unwrap();
            let rel = path.strip_prefix(root).unwrap().to_str().unwrap().to_owned();
            let (kind, link) = if meta.is_dir() {
                stack.push(path.clone());
                (Kind::Dir, None)
            } else if meta.file_type().is_symlink() {
                (Kind::Link, Some(std::fs::read_link(&path).unwrap().to_str().unwrap().into()))
            } else {
                bytes.insert(rel.clone(), std::fs::read(&path).unwrap());
                (Kind::File, None)
            };
            let mtime_ns = meta.mtime() * 1_000_000_000 + meta.mtime_nsec();
            items.push(Item {
                path: rel,
                kind,
                mode: meta.mode() & 0o7777,
                size: meta.len(),
                mtime_ns,
                link,
            });
        }
    }
    (items, bytes)
}

#[test]
fn git_status_through_the_hook_matches_git_status_without_it() {
    if !usable() {
        println!("skipping: no FUSE or no git here");
        return;
    }
    let mac = tempfile::tempdir().unwrap();
    let repo = mac.path().join("repo");
    std::fs::create_dir_all(repo.join("sub/deep")).unwrap();
    Command::new("git").args(["init", "-q"]).current_dir(&repo).status().unwrap();
    let past = std::time::SystemTime::now() - std::time::Duration::from_secs(120);
    for (name, body) in [
        ("a.txt", "a\n"),
        ("b.txt", "b\n"),
        ("sub/c.txt", "c\n"),
        ("sub/deep/d.txt", "d\n"),
        (".gitignore", "*.log\n"),
        ("sub/.gitignore", "build/\n"),
    ] {
        std::fs::write(repo.join(name), body).unwrap();
        std::fs::File::options()
            .write(true)
            .open(repo.join(name))
            .unwrap()
            .set_modified(past)
            .unwrap();
    }
    git(&repo, &["add", "."]);
    git(&repo, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"]);
    assert_eq!(git(&repo, &["status", "--porcelain"]), "");

    let (items, bytes) = walk(mac.path());
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes =
        bytes.into_iter().map(|(path, bytes)| (manifest.resolve(&path).unwrap(), bytes)).collect();
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = std::fs::metadata(state.path()).map(|meta| (meta.uid(), meta.gid())).unwrap();
    let overlay =
        Arc::new(Overlay::open(manifest, state.path(), Arc::new(Files(bytes)), owner).unwrap());
    let socket = state.path().join("fsmonitor.sock");
    overlay.serve_fsmonitor(&socket).unwrap();
    let warm = overlay.warm_git();
    assert_eq!(warm.repos, 1);
    // HEAD, config, the index, refs, and both `.gitignore` files at least.
    assert!(warm.files >= 5, "{warm:?}");
    let at_path = std::fs::canonicalize(at.path()).unwrap();
    let mounted = match cmux_projection::mount::mount(overlay.clone(), &at_path) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: mount failed: {error:#}");
            return;
        }
    };
    // git already read the lower index through the mount: the primed one must replace it there.
    assert_eq!(git(&at_path.join("repo"), &["ls-files"]).lines().count(), 6);
    std::fs::write(at_path.join("repo/.git/index.lock"), "").unwrap();
    assert_eq!(overlay.prime_git(&at_path), 0, "git holds the index lock");
    std::fs::remove_file(at_path.join("repo/.git/index.lock")).unwrap();
    assert_eq!(overlay.prime_git(&at_path), 1);
    assert_eq!(overlay.prime_git(&at_path), 0, "the index is git's own now");
    let worktree = at_path.join("repo");
    let hook = format!(
        "core.fsmonitor='{}' fsmonitor-hook '{}' '{}'",
        env!("CARGO_BIN_EXE_cmux-projection"),
        socket.display(),
        at_path.display()
    );
    // git takes a FUSE mount for a network one and turns fsmonitor off there unless told.
    let with = |args: &[&str]| {
        git(&worktree, &[&["-c", "fsmonitor.allowRemote=true", "-c", hook.as_str()], args].concat())
    };

    // Primed: every tracked file is clean as of the hook's first token, and status agrees.
    assert_eq!(
        with(&["ls-files", "-f"]),
        "h .gitignore\nh a.txt\nh b.txt\nh sub/.gitignore\nh sub/c.txt\nh sub/deep/d.txt\n"
    );
    assert_eq!(with(&["status", "--porcelain"]), "");

    // Changes through the mount: each one reaches git through the hook.
    std::fs::write(worktree.join("a.txt"), "a changed, same second\n").unwrap();
    std::fs::rename(worktree.join("b.txt"), worktree.join("b2.txt")).unwrap();
    std::fs::remove_file(worktree.join("sub/c.txt")).unwrap();
    std::fs::write(worktree.join("new.txt"), "new\n").unwrap();
    std::fs::write(worktree.join("ignored.log"), "x\n").unwrap();
    std::fs::create_dir_all(worktree.join("sub/made")).unwrap();
    std::fs::write(worktree.join("sub/made/x.txt"), "x\n").unwrap();
    git(&worktree, &["status", "--porcelain"]);
    with(&["status", "--porcelain"]);
    // A lower folder renames as EXDEV (as on overlayfs; `mv` copies); a folder made here moves.
    std::fs::rename(worktree.join("sub/made"), worktree.join("sub/moved")).unwrap();
    std::fs::remove_file(worktree.join("sub/deep/d.txt")).unwrap();
    let plain = git(&worktree, &["status", "--porcelain"]);
    assert_eq!(
        plain,
        " M a.txt\n D b.txt\n D sub/c.txt\n D sub/deep/d.txt\n?? b2.txt\n?? new.txt\n?? sub/moved/\n"
    );
    assert_eq!(with(&["status", "--porcelain"]), plain);
    assert_eq!(with(&["status", "--porcelain"]), plain, "the second run, from git's own token");

    // A change after git's last run, to a file git just saw as unchanged.
    std::fs::write(worktree.join("sub/.gitignore"), "build/\nmore/\n").unwrap();
    let plain = git(&worktree, &["status", "--porcelain"]);
    assert!(plain.contains(" M sub/.gitignore"), "{plain}");
    assert_eq!(with(&["status", "--porcelain"]), plain);

    // Restored by `git checkout`, through the mount: clean again, both ways.
    git(&worktree, &["checkout", "--", "a.txt", "b.txt", "sub"]);
    std::fs::remove_file(worktree.join("b2.txt")).unwrap();
    std::fs::remove_file(worktree.join("new.txt")).unwrap();
    std::fs::remove_dir_all(worktree.join("sub/moved")).unwrap();
    std::fs::remove_file(worktree.join("ignored.log")).unwrap();
    assert_eq!(git(&worktree, &["status", "--porcelain"]), "");
    assert_eq!(with(&["status", "--porcelain"]), "");

    // A hook whose projection is gone answers nothing: git checks every file, never trusts it.
    std::fs::remove_file(&socket).unwrap();
    std::fs::write(worktree.join("a.txt"), "after the socket\n").unwrap();
    assert_eq!(with(&["status", "--porcelain"]), " M a.txt\n");
    mounted.unmount();
}
