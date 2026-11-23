//! The `.git` swap on a real mount: a "Mac" repository with a public remote (a bare repository
//! read by `file://`, which serves `--filter` as GitHub does), projected through FUSE.

use std::collections::HashMap;
use std::io::Write as _;
use std::os::unix::fs::{FileExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::manifest::{Item, Kind, Manifest};
use crate::overlay::Overlay;
use crate::{Fetch, FetchError};

/// The Mac's files, read from its disk by manifest entry.
struct Disk(HashMap<u32, PathBuf>);

impl Fetch for Disk {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let path = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let file = std::fs::File::open(path).map_err(|_| FetchError::Failed)?;
        let mut bytes = vec![0u8; len as usize];
        let mut got = 0;
        while got < bytes.len() {
            match file.read_at(&mut bytes[got..], offset + got as u64) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(_) => return Err(FetchError::Failed),
            }
        }
        bytes.truncate(got);
        Ok(bytes)
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries
            .iter()
            .map(|entry| {
                let path = self.0.get(entry).ok_or(FetchError::Failed)?;
                std::fs::read(path).map_err(|_| FetchError::Failed)
            })
            .collect()
    }
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && std::process::Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|output| output.status.success())
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

/// Deterministic bytes that do not compress away.
fn noise(seed: u64, len: usize) -> Vec<u8> {
    let mut state = seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state & 0xff) as u8
        })
        .collect()
}

struct Repo {
    _dir: tempfile::TempDir,
    mac: PathBuf,
    public: PathBuf,
}

/// A public remote with `pushed` commits of `bytes` each, and a Mac clone with two unpushed
/// commits and a staged change on top.
fn repo(pushed: usize, bytes: usize) -> Repo {
    let dir = tempfile::tempdir().unwrap();
    let public = dir.path().join("public.git");
    let mac = dir.path().join("mac");
    std::fs::create_dir_all(&public).unwrap();
    sh(&public, &["init", "--bare", "--quiet", "-b", "main"]);
    sh(&public, &["config", "uploadpack.allowFilter", "true"]);
    sh(&public, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    let url = format!("file://{}", public.display());
    sh(dir.path(), &["clone", "--quiet", &url, "mac"]);
    sh(&mac, &["checkout", "--quiet", "-b", "main"]);
    for n in 0..pushed {
        std::fs::write(mac.join(format!("file-{}.bin", n % 8)), noise(n as u64, bytes)).unwrap();
        std::fs::write(mac.join("README.md"), format!("version {n}\n")).unwrap();
        sh(&mac, &["add", "-A"]);
        sh(&mac, &["commit", "--quiet", "-m", &format!("pushed {n}")]);
    }
    sh(&mac, &["push", "--quiet", "-u", "origin", "main"]);
    std::fs::write(mac.join("unpushed.txt"), "only on the mac\n").unwrap();
    sh(&mac, &["add", "unpushed.txt"]);
    sh(&mac, &["commit", "--quiet", "-m", "unpushed one"]);
    std::fs::write(mac.join("unpushed.txt"), "only on the mac, twice\n").unwrap();
    sh(&mac, &["commit", "--quiet", "-am", "unpushed two"]);
    std::fs::write(mac.join("README.md"), "staged\n").unwrap();
    sh(&mac, &["add", "README.md"]);
    sh(&mac, &["gc", "--quiet"]);
    Repo { _dir: dir, mac, public }
}

/// The manifest of everything under `root`, and where each file's bytes are.
fn project(root: &Path) -> (Manifest, Disk) {
    let mut items = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).unwrap();
            let relative = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            let kind = if meta.is_dir() {
                stack.push(path.clone());
                Kind::Dir
            } else if meta.file_type().is_symlink() {
                Kind::Link
            } else {
                Kind::File
            };
            items.push(Item {
                path: relative,
                kind,
                mode: meta.permissions().mode() & 0o7777,
                size: if kind == Kind::File { meta.len() } else { 0 },
                mtime_ns: meta.mtime() * 1_000_000_000 + meta.mtime_nsec(),
                link: (kind == Kind::Link)
                    .then(|| std::fs::read_link(&path).unwrap().to_string_lossy().into_owned()),
            });
        }
    }
    let manifest = Manifest::build(1, items).unwrap();
    let mut files = HashMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() && !path.is_symlink() {
                stack.push(path.clone());
            }
            let relative = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            files.insert(manifest.resolve(&relative).unwrap(), path);
        }
    }
    (manifest, Disk(files))
}

struct Projected {
    overlay: Arc<Overlay>,
    mounted: crate::mount::Mounted,
    at: tempfile::TempDir,
    state: tempfile::TempDir,
}

impl Projected {
    fn forget(&self) -> impl Fn() -> std::io::Result<()> + '_ {
        || self.mounted.forget_entry(self.overlay.root(), ".git")
    }
}

fn mount(mac: &Path) -> Option<Projected> {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return None;
    }
    let (manifest, disk) = project(mac);
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let meta = std::fs::metadata(state.path()).unwrap();
    let overlay = Arc::new(
        Overlay::open(Arc::new(manifest), state.path(), Arc::new(disk), (meta.uid(), meta.gid()))
            .unwrap(),
    );
    match crate::mount::mount(overlay.clone(), at.path()) {
        Ok(mounted) => Some(Projected { overlay, mounted, at, state }),
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            None
        }
    }
}

/// What a reader checks: HEAD, the log, the staged file and the unpushed file.
fn view(at: &Path) -> Result<String, String> {
    let run = |args: &[&str]| -> Result<String, String> {
        let out = std::process::Command::new("git")
            .args(["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"])
            .args(args)
            .current_dir(at)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .output()
            .map_err(|error| error.to_string())?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(format!("git {args:?}: {}", String::from_utf8_lossy(&out.stderr)))
        }
    };
    Ok([
        run(&["rev-parse", "HEAD", "HEAD^{tree}"])?,
        run(&["log", "--format=%H %s"])?,
        run(&["show", "HEAD:unpushed.txt"])?,
        run(&["diff", "--cached", "--name-only"])?,
        run(&["for-each-ref", "--format=%(objectname) %(refname)"])?,
    ]
    .join("--\n"))
}

#[test]
fn unpushed_commits_survive_the_swap() {
    let repo = repo(6, 4096);
    let Some(p) = mount(&repo.mac) else { return };
    let before = view(p.at.path()).unwrap();
    assert_eq!(before, view(&repo.mac).unwrap());
    let outcome = run(&p.overlay, &p.forget(), p.at.path(), p.state.path()).unwrap();
    let local = p.state.path().join(LOCAL_DIR);
    assert_eq!(outcome, Outcome::Swapped(local.clone()));
    let link = std::fs::read_link(p.at.path().join(".git")).unwrap();
    assert_eq!(link, local);
    // The same repository as the Mac's: HEAD, log, refs, the staged change, the unpushed file.
    assert_eq!(view(p.at.path()).unwrap(), before);
    assert!(before.contains("unpushed two") && before.contains("unpushed one"));
    // The unpushed commits' objects are local, not promised by the remote: the remote never
    // had them, and the swapped repository reads them with the remote gone.
    std::fs::rename(&repo.public, repo.public.with_extension("gone")).unwrap();
    let show = sh(p.at.path(), &["show", "HEAD~1:unpushed.txt"]);
    assert_eq!(show, "only on the mac\n");
    let status = sh(p.at.path(), &["-c", "core.checkStat=minimal", "status", "--porcelain"]);
    assert_eq!(status, "M  README.md\n");
    // A second run finds the swap done (the link is in the upper layer).
    assert_eq!(
        run(&p.overlay, &p.forget(), p.at.path(), p.state.path()).unwrap(),
        Outcome::Already
    );
}

#[test]
fn a_git_reading_through_the_swap_sees_one_repository() {
    let repo = repo(12, 2048);
    let Some(p) = mount(&repo.mac) else { return };
    let expected = view(p.at.path()).unwrap();
    // A reader that started before the switch and keeps its pack open across it.
    let mut batch = std::process::Command::new("git")
        .args(["cat-file", "--batch-check"])
        .current_dir(p.at.path())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let projected = p.at.path().join(".git");
    let local = p.state.path().join(LOCAL_DIR);
    let (_, url) = seed_remote(&projected).unwrap();
    let ready = prepare(&projected, &local, &url).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = (0..4)
        .map(|_| {
            let at = p.at.path().to_path_buf();
            let stop = stop.clone();
            let expected = expected.clone();
            std::thread::spawn(move || {
                let mut reads = 0;
                while !stop.load(Ordering::Relaxed) || reads < 3 {
                    let seen = view(&at);
                    assert_eq!(seen.as_ref(), Ok(&expected), "read {reads}");
                    reads += 1;
                }
                reads
            })
        })
        .collect();
    std::thread::sleep(std::time::Duration::from_millis(300));
    swap(&p.overlay, &p.forget(), &projected, &local, &ready).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(300));
    stop.store(true, Ordering::Relaxed);
    for reader in readers {
        assert!(reader.join().unwrap() >= 3);
    }
    assert!(std::fs::symlink_metadata(&projected).unwrap().file_type().is_symlink());
    // The reader from before still answers for every object, old and unpushed.
    let ids = sh(p.at.path(), &["rev-list", "--all"]);
    {
        let stdin = batch.stdin.as_mut().unwrap();
        stdin.write_all(ids.as_bytes()).unwrap();
    }
    drop(batch.stdin.take());
    let out = batch.wait_with_output().unwrap();
    let answered = String::from_utf8(out.stdout).unwrap();
    assert_eq!(answered.lines().count(), ids.lines().count());
    assert!(!answered.contains("missing"), "{answered}");
}

/// The number: bytes over the Mac's link for one repository's `.git` under one workload (`git
/// log -p` of all history, then `git status`), projection only against remote fetch plus swap.
#[test]
fn bytes_over_the_mac_link_before_and_after_the_swap() {
    let repo = repo(40, 1024 * 1024);
    let workload = |at: &Path| {
        sh(at, &["-c", "core.checkStat=minimal", "log", "-p", "--all", "--format=%H"]);
        sh(at, &["-c", "core.checkStat=minimal", "status", "--porcelain"]);
    };
    let Some(before) = mount(&repo.mac) else { return };
    workload(before.at.path());
    let projection_only = before.overlay.stats().remote_bytes;
    drop(before);
    let Some(after) = mount(&repo.mac) else { return };
    run(&after.overlay, &after.forget(), after.at.path(), after.state.path()).unwrap();
    workload(after.at.path());
    let swapped = after.overlay.stats().remote_bytes;
    let pack: u64 = std::fs::read_dir(repo.mac.join(".git/objects/pack"))
        .unwrap()
        .map(|entry| entry.unwrap().metadata().unwrap().len())
        .sum();
    println!("MEASURE mac_link_bytes git_dir_pack={pack} before={projection_only} after={swapped}");
    assert!(swapped * 4 < projection_only, "{swapped} vs {projection_only}");
}
