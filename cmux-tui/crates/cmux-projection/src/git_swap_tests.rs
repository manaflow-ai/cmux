//! The `.git` swap on a real mount: a "Mac" repository with a public remote (a bare repository
//! read by `file://`, which serves `--filter` as GitHub does), projected through FUSE.

use std::collections::HashMap;
use std::io::Write as _;
use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
use std::os::unix::fs::{FileExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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
        && Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|output| output.status.success())
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
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
    let base = sh(&mac, &["rev-parse", "HEAD"]).trim().to_owned();
    std::fs::write(mac.join(".git/cmux-carry.base"), format!("{base}\n")).unwrap();
    let mut pack = Command::new("git");
    pack.current_dir(&mac)
        .args([
            "pack-objects",
            "--filter=blob:none",
            "--revs",
            "--stdout",
            "-q",
            "--delta-base-offset",
        ])
        .stdin(Stdio::piped())
        .stdout(std::fs::File::create(mac.join(".git/cmux-carry.pack")).unwrap())
        .stderr(Stdio::piped());
    let mut child = pack.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("--shallow {base}\n{base}\n").as_bytes())
        .unwrap();
    assert!(child.wait_with_output().unwrap().status.success());
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

// A serialized 4.4 Mbit/s link with 50 ms per request, including batched reads.
// Only the measurement fixture enables this; ordinary correctness tests use local I/O.
struct MeasuredLink {
    disk: Disk,
    duress: bool,
    wire: std::sync::Mutex<()>,
}

impl MeasuredLink {
    fn transfer(&self, bytes: usize) {
        if self.duress {
            let _wire = self.wire.lock().unwrap();
            std::thread::sleep(std::time::Duration::from_secs_f64(
                0.050 + bytes as f64 * 8.0 / 4_400_000.0,
            ));
        }
    }
}

impl Fetch for MeasuredLink {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let result = self.disk.read(entry, offset, len);
        self.transfer(result.as_ref().map_or(0, Vec::len));
        result
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        let result = self.disk.batch(entries);
        self.transfer(result.iter().filter_map(|r| r.as_ref().ok()).map(Vec::len).sum());
        result
    }
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
    mount_with_link(mac, false)
}

fn mount_with_link(mac: &Path, duress: bool) -> Option<Projected> {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return None;
    }
    let (manifest, disk) = project(mac);
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let meta = std::fs::metadata(state.path()).unwrap();
    let overlay = Arc::new(
        Overlay::open(
            Arc::new(manifest),
            state.path(),
            Arc::new(MeasuredLink { disk, duress, wire: std::sync::Mutex::new(()) }),
            (meta.uid(), meta.gid()),
        )
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
        let out = Command::new("git")
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

/// Carry must preserve staged work and detached history without needing remote credentials.
#[test]
fn carry_preserves_public_private_and_local_repositories() {
    for kind in ["public", "private", "local"] {
        let repo = repo(3, 64);
        match kind {
            "private" => {
                sh(&repo.mac, &["remote", "set-url", "origin", "https://127.0.0.1:1/private.git"]);
            }
            "local" => {
                sh(&repo.mac, &["remote", "remove", "origin"]);
            }
            _ => {}
        }
        // The carried HEAD is detached and no longer reachable from the branch tip.
        let base = sh(&repo.mac, &["rev-parse", "HEAD"]).trim().to_owned();
        sh(&repo.mac, &["checkout", "--detach", "--quiet"]);
        sh(&repo.mac, &["branch", "-f", "main", "HEAD~2"]);
        sh(
            &repo.mac,
            &[
                "update-index",
                "--add",
                "--cacheinfo",
                "160000,1111111111111111111111111111111111111111,uninitialized-submodule",
            ],
        );
        std::fs::write(repo.mac.join("staged\nname.txt"), "staged with a newline in its path")
            .unwrap();
        sh(&repo.mac, &["add", "staged\nname.txt"]);
        let expected_log = sh(&repo.mac, &["log", "--format=%H"]);
        let expected_index = sh(&repo.mac, &["ls-files", "--stage"]);
        let expected_diff = sh(&repo.mac, &["diff", "--cached"]);
        let projected = repo.mac.join(".git");
        let state = tempfile::tempdir().unwrap();
        let local = state.path().join(LOCAL_DIR);
        prepare_carry(&projected, &local, &projected.join(CARRY_PACK), &base).unwrap();
        for (args, expected) in [
            (vec!["log", "--format=%H"], expected_log),
            (vec!["ls-files", "--stage"], expected_index),
            (vec!["diff", "--cached"], expected_diff),
        ] {
            let mut command = git(&local);
            command.args(args);
            assert_eq!(text(command).unwrap(), expected, "kind={kind}");
        }
        let config = std::fs::read_to_string(local.join("config")).unwrap();
        assert!(!config.contains(SEED_REMOTE), "carry must not add a promisor: {kind}");
    }
}

#[test]
fn carry_accepts_a_non_utf8_staged_path() {
    let repo = repo(3, 64);
    let name = std::ffi::OsString::from_vec(b"staged-\xff.txt".to_vec());
    let path = repo.mac.join(&name);
    std::fs::write(&path, b"staged bytes").unwrap();
    let mut add = git(&repo.mac.join(".git"));
    add.current_dir(&repo.mac).args(["add", "--"]).arg(&name);
    output(add).unwrap();

    let projected = repo.mac.join(".git");
    let base = sh(&repo.mac, &["rev-parse", "HEAD"]).trim().to_owned();
    let state = tempfile::tempdir().unwrap();
    let local = state.path().join(LOCAL_DIR);
    prepare_carry(&projected, &local, &projected.join(CARRY_PACK), &base).unwrap();

    let mut staged = git(&local);
    staged.args(["ls-files", "--stage", "-z"]);
    let listing = output(staged).unwrap();
    assert!(listing.windows(name.as_bytes().len()).any(|window| window == name.as_bytes()));
}

/// Git can read the loose directory before the rename and packed-refs after it (or
/// vice versa). Fetch alone creates only loose refs, so that mixed view used to be empty
/// when the sender had run gc. Exercise those views without relying on thread timing.
#[test]
fn prepared_git_preserves_refs_across_both_lookup_orders() {
    let repo = repo(3, 64);
    let projected = repo.mac.join(".git");
    let expected = sh(&repo.mac, &["for-each-ref", "--format=%(objectname) %(refname)"]);
    let old_packed = std::fs::read(projected.join("packed-refs")).unwrap();
    assert!(!projected.join("refs/heads/main").exists());
    for carry in [false, true] {
        let state = tempfile::tempdir().unwrap();
        let local = state.path().join(LOCAL_DIR);
        if carry {
            let base = std::fs::read_to_string(projected.join(CARRY_BASE)).unwrap();
            prepare_carry(&projected, &local, &projected.join(CARRY_PACK), base.trim()).unwrap();
        } else {
            let (_, url) = seed_remote(&projected).unwrap();
            prepare(&projected, &local, &url).unwrap();
        }
        let mut refs = git(&local);
        refs.args(["for-each-ref", "--format=%(objectname) %(refname)"]);
        assert_eq!(text(refs).unwrap(), expected);
        // Old loose directory (empty), new packed file.
        let loose = local.join("refs");
        let saved = local.join("saved-refs");
        std::fs::rename(&loose, &saved).unwrap();
        std::fs::create_dir(&loose).unwrap();
        let mut refs = git(&local);
        refs.args(["for-each-ref", "--format=%(objectname) %(refname)"]);
        assert_eq!(text(refs).unwrap(), expected, "old loose/new packed, carry={carry}");
        std::fs::remove_dir(&loose).unwrap();
        std::fs::rename(saved, loose).unwrap();
        // Old packed file, new loose refs. Both must still name the same tips.
        std::fs::write(local.join("packed-refs"), &old_packed).unwrap();
        let mut refs = git(&local);
        refs.args(["for-each-ref", "--format=%(objectname) %(refname)"]);
        assert_eq!(text(refs).unwrap(), expected, "old packed/new loose, carry={carry}");
    }
}

#[test]
fn a_sealed_projection_does_not_swap_its_git_folder() {
    let mac = tempfile::tempdir().unwrap();
    std::fs::create_dir(mac.path().join(".git")).unwrap();
    let (manifest, disk) = project(mac.path());
    let state = tempfile::tempdir().unwrap();
    let meta = state.path().metadata().unwrap();
    let overlay =
        Overlay::open(Arc::new(manifest), state.path(), Arc::new(disk), (meta.uid(), meta.gid()))
            .unwrap();
    let git = overlay.lookup(overlay.root(), ".git").unwrap().ino;
    let target = tempfile::tempdir().unwrap();

    overlay.seal();
    assert_eq!(overlay.swap_to_link(".git", target.path()), Err(libc::EROFS));
    assert_eq!(overlay.lookup(overlay.root(), ".git").unwrap().ino, git);
    assert_eq!(
        state.path().join("upper/.git").symlink_metadata().unwrap_err().kind(),
        std::io::ErrorKind::NotFound
    );
}

#[test]
fn a_git_reading_through_the_swap_sees_one_repository() {
    readers_through_swap(false);
}

#[test]
fn a_git_reading_through_the_carry_swap_sees_one_repository() {
    for _ in 0..10 {
        readers_through_swap(true);
    }
}

fn readers_through_swap(carry: bool) {
    let repo = repo(12, 2048);
    let Some(p) = mount(&repo.mac) else { return };
    let expected = view(p.at.path()).unwrap();
    // A reader that started before the switch and keeps its pack open across it.
    let mut batch = Command::new("git")
        .args(["cat-file", "--batch-check"])
        .current_dir(p.at.path())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let projected = p.at.path().join(".git");
    let local = p.state.path().join(LOCAL_DIR);
    let ready = if carry {
        let base = std::fs::read_to_string(projected.join(CARRY_BASE)).unwrap();
        prepare_carry(&projected, &local, &projected.join(CARRY_PACK), base.trim()).unwrap()
    } else {
        let (_, url) = seed_remote(&projected).unwrap();
        prepare(&projected, &local, &url).unwrap()
    };
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
    let results: Vec<_> = readers.into_iter().map(std::thread::JoinHandle::join).collect();
    for result in results {
        assert!(result.unwrap() >= 3);
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
    let projected = after.at.path().join(".git");
    let local = after.state.path().join(LOCAL_DIR);
    let (_, url) = seed_remote(&projected).unwrap();
    let ready = prepare(&projected, &local, &url).unwrap();
    swap(&after.overlay, &after.forget(), &projected, &local, &ready).unwrap();
    workload(after.at.path());
    let swapped = after.overlay.stats().remote_bytes;
    let pack: u64 = std::fs::read_dir(repo.mac.join(".git/objects/pack"))
        .unwrap()
        .map(|entry| entry.unwrap().metadata().unwrap().len())
        .sum();
    println!("MEASURE mac_link_bytes git_dir_pack={pack} before={projection_only} after={swapped}");
    // This measures the legacy public-remote path, not carry. Carry has no remote seed.
    assert!(swapped * 20 < projection_only, "{swapped} vs {projection_only}");
}

/// One harness for readiness before/after carry, on a normal and a simulated constrained link.
#[test]
fn measure_carry_readiness_for_three_repository_kinds() {
    for kind in ["public", "private", "local"] {
        let repo = repo(4, 32 * 1024);
        match kind {
            "private" => {
                sh(&repo.mac, &["remote", "set-url", "origin", "https://127.0.0.1:1/private.git"]);
            }
            "local" => {
                sh(&repo.mac, &["remote", "remove", "origin"]);
            }
            _ => {}
        }
        let workload = |at: &Path| {
            let log = sh(at, &["log", "--format=%H"]);
            let status = sh(
                at,
                &[
                    "-c",
                    "core.checkStat=minimal",
                    "-c",
                    "core.trustctime=false",
                    "status",
                    "--porcelain",
                ],
            );
            (log, status)
        };
        let expected = workload(&repo.mac);
        for duress in [false, true] {
            let Some(before) = mount_with_link(&repo.mac, duress) else { return };
            let started = std::time::Instant::now();
            assert_eq!(workload(before.at.path()), expected);
            let before_ms = started.elapsed().as_millis();
            let before_bytes = before.overlay.stats().remote_bytes;
            drop(before);
            let Some(after) = mount_with_link(&repo.mac, duress) else { return };
            let started = std::time::Instant::now();
            assert!(matches!(
                run(&after.overlay, &after.forget(), after.at.path(), after.state.path()).unwrap(),
                Outcome::Swapped(_)
            ));
            assert_eq!(workload(after.at.path()), expected);
            let after_ms = started.elapsed().as_millis();
            let after_bytes = after.overlay.stats().remote_bytes;
            let started = std::time::Instant::now();
            assert_eq!(workload(after.at.path()), expected);
            let warm_ms = started.elapsed().as_millis();
            assert_eq!(after.overlay.stats().remote_bytes, after_bytes);
            println!(
                "MEASURE carry_ready kind={kind} duress={duress} before_ms={before_ms} after_ms={after_ms} warm_ms={warm_ms} before_bytes={before_bytes} after_bytes={after_bytes}"
            );
        }
    }
}

#[test]
fn carry_swap_bring_back_transfers_new_commits_and_tracks_later_edits() {
    let repo = repo(3, 64);
    let Some(p) = mount(&repo.mac) else { return };
    assert!(matches!(
        run(&p.overlay, &p.forget(), p.at.path(), p.state.path()).unwrap(),
        Outcome::Swapped(_)
    ));
    let before = crate::state::mark(p.state.path()).unwrap();
    sh(p.at.path(), &["commit", "--quiet", "-m", "made on the machine"]);
    let after = crate::state::mark(p.state.path()).unwrap();
    assert_ne!(before, after, "the transfer mark must see commits outside the upper layer");
    let expected = sh(p.at.path(), &["log", "--format=%H"]);
    let layer = crate::layer::Layer::collect(p.state.path()).unwrap();
    assert!(layer.upper.iter().any(|entry| entry.path == ".git" && entry.kind == Kind::Dir));
    let paths: Vec<_> = layer
        .upper
        .iter()
        .filter(|entry| entry.kind == Kind::File && entry.path.starts_with(".git/"))
        .map(|entry| entry.path.clone())
        .collect();
    let mut wire = Vec::new();
    crate::layer::send_files(p.state.path(), &paths, &mut wire).unwrap();
    let received = tempfile::tempdir().unwrap();
    assert!(
        crate::layer::receive_files(&mut wire.as_slice(), &paths, received.path(), u64::MAX)
            .unwrap()
            .into_iter()
            .all(|arrived| arrived)
    );
    let mut log = git(&received.path().join(".git"));
    log.args(["log", "--format=%H"]);
    assert_eq!(text(log).unwrap(), expected);
    // An unrelated link must not be walked, even if it points at a directory.
    std::os::unix::fs::symlink(&repo.public, p.state.path().join("upper/other-link")).unwrap();
    let layer = crate::layer::Layer::collect(p.state.path()).unwrap();
    assert!(layer.upper.iter().any(|entry| entry.path == "other-link" && entry.kind == Kind::Link));
    assert!(!layer.upper.iter().any(|entry| entry.path.starts_with("other-link/")));
}
