//! A head-first seed: the chat may open once the root's files, the harness folders and the
//! subpath's folders are in place with the person's uncommitted edits, while every tool
//! waits for the whole checkout, and nothing reads a half-filled tree back to the Mac.

use std::sync::mpsc;

use cmux_git::sync_barrier::{Probe, probe, wait_ready};

use super::*;

fn head_params(world: &World, folder: &Path, snapshot: &Snapshot, subpath: Option<&str>) -> Value {
    let mut params = world.start_params(folder, snapshot);
    params["head_first"] = true.into();
    if let Some(subpath) = subpath {
        params["subpath"] = subpath.into();
    }
    params
}

/// Starts the seed and returns once it stands at its head; it fills when `release` sends
/// or drops.
fn held_at_head(
    world: &World,
    params: &Value,
    folder: &Path,
) -> (GitSeedService, String, mpsc::Sender<()>) {
    let (reached, at_head) = mpsc::channel();
    let (release, released) = mpsc::channel();
    run::hold::at(folder, reached, released);
    let service = world.service();
    let job = start(&service, params).unwrap();
    at_head.recv_timeout(Duration::from_secs(120)).expect("the seed reached its head");
    (service, job, release)
}

fn status(service: &GitSeedService, job: &str) -> Value {
    service.call("git.seed.status", &json!({ "job": job })).unwrap()
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

/// No path is left out of the tree behind a skip-worktree bit (`git status` would not say).
fn whole(folder: &Path) {
    let listing = git(folder, &["ls-files", "-t"]);
    assert!(!listing.lines().any(|line| line.starts_with("S ")), "{listing}");
    assert!(!filling(folder));
}

fn filling(folder: &Path) -> bool {
    folder.join(".git/cmux-seed-filling").exists()
}

#[test]
fn a_head_first_seed_fills_to_the_macs_head_index_worktree_and_stash() {
    let world = World::new("head-whole");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("work/project");
    let status = seed(&world, &head_params(&world, &folder, &snapshot, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["head_ready"], true, "{status}");
    // Unstaged edits and the unstaged delete are WORK's, the untracked file is there, and
    // `diff --cached` is INDEX against HEAD.
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
    assert!(matches!(probe(&folder).unwrap(), Probe::Ready(_)));
    assert!(!snapshot.bundle.exists(), "the applied bundle is deleted");
}

#[test]
fn at_the_head_the_start_files_carry_work_and_every_tool_still_waits() {
    let world = World::new("head-held");
    dirty_branch(&world);
    write(&world.mac.join("d/sub/deep"), "deep\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, Some("d"));
    let (service, job, release) = held_at_head(&world, &params, &folder);
    let held = status(&service, &job);
    assert_eq!((&held["state"], &held["head_ready"]), (&json!("running"), &json!(true)), "{held}");
    assert!(matches!(probe(&folder).unwrap(), Probe::HeadReady));
    assert_eq!(read(&folder.join("a")), "a\nstaged\nunstaged\n", "the person's unstaged edit");
    assert_eq!(read(&folder.join("b")), "b\nunpushed\n");
    assert!(!folder.join("gone").exists(), "WORK's delete");
    assert_eq!(read(&folder.join("d/c")), "c\n", "the subpath's own files");
    assert_eq!(read(&folder.join("d/new")), "new\n");
    assert!(!folder.join("d/sub").exists(), "a folder below the subpath waits for the fill");
    assert!(!folder.join("untracked").exists(), "a folder off the head waits for the fill");
    let waited = wait_ready(&folder, Duration::from_millis(50)).unwrap_err();
    assert_eq!(waited.kind(), std::io::ErrorKind::TimedOut);
    drop(release);
    let done = wait(&service, &job);
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(read(&folder.join("d/sub/deep")), "deep\n");
    assert_eq!(read(&folder.join("untracked/u.txt")), "untracked\n");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
    assert!(matches!(probe(&folder).unwrap(), Probe::Ready(_)));
}

#[test]
fn a_head_with_start_settings_or_mcp_servers_is_never_marked() {
    for (label, path, subpath) in [
        ("settings", ".claude/settings.json", None),
        ("mcp", ".mcp.json", None),
        ("submcp", "d/.mcp.json", Some("d")),
    ] {
        let world = World::new(&format!("head-{label}"));
        write(&world.mac.join(path), "{}\n");
        let snapshot = world.snapshot("one", &[&world.base]);
        let folder = world.home.join("project");
        let params = head_params(&world, &folder, &snapshot, subpath);
        let (service, job, release) = held_at_head(&world, &params, &folder);
        assert!(folder.join(path).exists(), "{label}: the settings are in the head");
        assert!(status(&service, &job)["head_ready"].is_null(), "{label}");
        assert!(matches!(probe(&folder).unwrap(), Probe::Syncing), "{label}: a start waits");
        drop(release);
        let done = wait(&service, &job);
        assert_eq!(done["state"], "done", "{label}: {done}");
        assert!(done["head_ready"].is_null(), "{label}");
        assert_eq!(state(&folder), state(&world.mac), "{label}");
        whole(&folder);
    }
}

#[test]
fn a_fill_waits_for_a_reader_holding_the_index_lock() {
    let world = World::new("head-lock");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, None);
    let (service, job, release) = held_at_head(&world, &params, &folder);
    // A harness started at the head runs `git status`, which holds the lock a moment.
    let lock = folder.join(".git/index.lock");
    write(&lock, "");
    let reader = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        std::fs::remove_file(lock).unwrap();
    });
    drop(release);
    let done = wait(&service, &job);
    reader.join().unwrap();
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
}

#[test]
fn nothing_reads_a_filling_tree_back_and_a_failed_fill_stays_incomplete() {
    let world = World::new("head-fail");
    dirty_branch(&world);
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &first, None);
    let export = json!({
        "folder": folder, "since_work": first.work, "since_head": first.head,
        "bundle": world.home.join("back.bundle"),
    });
    let mut delta = world.start_params(&folder, &first);
    delta["since"] = first.work.into();
    let (service, job, release) = held_at_head(&world, &params, &folder);
    assert_eq!(service.call("git.seed.export", &export).unwrap_err().code, "seed.filling");
    assert_eq!(start(&service, &delta).unwrap_err().code, "seed.filling");
    // A lock no reader lets go of fails the fill.
    write(&folder.join(".git/index.lock"), "");
    drop(release);
    let failed = wait(&service, &job);
    assert_eq!(failed["state"], "failed", "{failed}");
    assert_eq!(failed["error_code"], "seed.checkout_failed", "{failed}");
    assert!(matches!(probe(&folder).unwrap(), Probe::Incomplete));
    assert!(filling(&folder));
    std::fs::remove_file(folder.join(".git/index.lock")).unwrap();
    // A daemon that restarted knows no job here: the folder itself says it never filled.
    let restarted = world.service();
    assert_eq!(restarted.call("git.seed.export", &export).unwrap_err().code, "seed.filling");
    let refused = wait(&restarted, &start(&restarted, &delta).unwrap());
    assert_eq!(refused["error_code"], "seed.filling", "{refused}");
    assert!(matches!(probe(&folder).unwrap(), Probe::Incomplete));
    // A whole seed again fills it: the clone is there, so it checks out whole.
    let retried = wait(&restarted, &start(&restarted, &params).unwrap());
    assert_eq!(retried["state"], "done", "{retried}");
    assert!(retried["head_ready"].is_null(), "an existing clone never opens at a head");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
    assert!(matches!(probe(&folder).unwrap(), Probe::Ready(_)));
    let exported = service.call("git.seed.export", &export).unwrap();
    assert_eq!(wait(&service, exported["job"].as_str().unwrap())["state"], "done");
}

/// Review F1 (cmux#39018): a tracked `.claude -> .` resolves at the head, but the skills
/// below its target are not in it, so the head is never marked.
#[test]
fn a_harness_folder_linked_to_a_folder_is_never_marked() {
    let world = World::new("head-dirlink");
    std::os::unix::fs::symlink(".", world.mac.join(".claude")).unwrap();
    write(&world.mac.join("skills/review/SKILL.md"), "review\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, None);
    let (service, job, release) = held_at_head(&world, &params, &folder);
    assert!(std::fs::symlink_metadata(folder.join(".claude")).unwrap().is_symlink());
    assert!(!folder.join("skills").exists(), "the skills wait for the fill");
    assert!(status(&service, &job)["head_ready"].is_null());
    assert!(matches!(probe(&folder).unwrap(), Probe::Syncing), "a start waits");
    drop(release);
    let done = wait(&service, &job);
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(read(&folder.join(".claude/skills/review/SKILL.md")), "review\n");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
}

/// Review F1 (cmux#39018, 7373781): a subpath inside a harness folder keeps the rest of
/// that folder in the head (`/.claude/**` after the subpath's exclusions).
#[test]
fn a_subpath_inside_a_harness_folder_keeps_the_whole_harness_folder() {
    let world = World::new("head-in-harness");
    write(&world.mac.join(".claude/rules/project.md"), "rules\n");
    write(&world.mac.join(".claude/skills/task/SKILL.md"), "task\n");
    write(&world.mac.join(".claude/skills/task/deep/more.md"), "more\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, Some(".claude/skills/task"));
    let (service, job, release) = held_at_head(&world, &params, &folder);
    assert_eq!(status(&service, &job)["head_ready"], true);
    assert_eq!(read(&folder.join(".claude/rules/project.md")), "rules\n");
    assert_eq!(read(&folder.join(".claude/skills/task/SKILL.md")), "task\n");
    assert_eq!(read(&folder.join(".claude/skills/task/deep/more.md")), "more\n");
    drop(release);
    assert_eq!(wait(&service, &job)["state"], "done");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
}

/// Review F2 (cmux#39018, 7373781): `.claude -> app` with the chat in `app` resolves, but
/// `app/rules/` is not in the head, so the head is never marked.
#[test]
fn a_harness_folder_linked_to_the_subpath_is_never_marked() {
    let world = World::new("head-link-sub");
    write(&world.mac.join("app/rules/project.md"), "rules\n");
    std::os::unix::fs::symlink("app", world.mac.join(".claude")).unwrap();
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, Some("app"));
    let (service, job, release) = held_at_head(&world, &params, &folder);
    assert!(!folder.join("app/rules").exists(), "outside the head");
    assert!(status(&service, &job)["head_ready"].is_null());
    assert!(matches!(probe(&folder).unwrap(), Probe::Syncing), "a start waits");
    drop(release);
    assert_eq!(wait(&service, &job)["state"], "done");
    assert_eq!(read(&folder.join(".claude/rules/project.md")), "rules\n");
    assert_eq!(state(&folder), state(&world.mac));
    whole(&folder);
}

/// A seed whose WORK has a submodule at `at` (its folder not initialized, as a clone leaves
/// one; no `.gitmodules`, so the seed never reaches for it over the network), held at its
/// head: the barrier's state there and the job's status.
fn submodule_at_head(label: &str, at: &str) -> (String, Value) {
    let world = World::new(label);
    let lib = world.home.join("lib");
    std::fs::create_dir_all(&lib).unwrap();
    git(&lib, &["init", "-q", "-b", "main"]);
    write(&lib.join("CLAUDE.md"), "lib\n");
    git(&lib, &["add", "-A"]);
    git(&lib, &["commit", "-q", "-m", "lib"]);
    let commit = git(&lib, &["rev-parse", "HEAD"]);
    let entry = format!("160000,{commit},{at}");
    git(&world.mac, &["update-index", "--add", "--cacheinfo", &entry]);
    std::fs::create_dir_all(world.mac.join(at)).unwrap();
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let params = head_params(&world, &folder, &snapshot, None);
    let (service, job, release) = held_at_head(&world, &params, &folder);
    let probed = barrier_state(&folder);
    let reported = status(&service, &job);
    drop(release);
    let done = wait(&service, &job);
    assert_eq!(done["state"], "done", "{label}: {done}");
    (probed, reported)
}

/// The probe's answer, and for a syncing folder which of its sidecar locks are held, so a
/// failure says why it read short of its head.
fn barrier_state(folder: &Path) -> String {
    use sha2::{Digest, Sha256};
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let answer = match probe(folder).unwrap() {
        Probe::Ready(_) => return "ready".into(),
        Probe::HeadReady => return "head".into(),
        Probe::Syncing => "syncing",
        Probe::Incomplete => return "incomplete".into(),
    };
    let name = folder.file_name().unwrap().as_bytes();
    let marker = folder.parent().unwrap().join(format!(".cmux-sync-{:x}", Sha256::digest(name)));
    let held = |suffix: &str| {
        let mut path = marker.clone().into_os_string();
        path.push(suffix);
        let file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(error) => return error.kind().to_string(),
        };
        // SAFETY: the descriptor is live for the call; the lock goes with the file.
        let taken = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) };
        (taken != 0).to_string()
    };
    let (marker_held, head, owner) = (held(""), held(".head"), held(".owner"));
    format!("{answer} (held: marker {marker_held}, head {head}, owner {owner})")
}

/// Review F1 (cmux#39018, 4f2b22b): a `.claude` kept as a submodule is an empty folder at
/// the head (submodules come after the fill), so the head is never marked.
#[test]
fn a_harness_folder_kept_as_a_submodule_is_never_marked() {
    let (probed, reported) = submodule_at_head("head-sub-harness", ".claude");
    assert!(probed.starts_with("syncing"), "{probed}");
    assert!(reported["head_ready"].is_null(), "{reported}");
}

/// A submodule off the head leaves it marked: barrier and status say the same.
#[test]
fn a_submodule_off_the_head_leaves_it_marked() {
    let (probed, reported) = submodule_at_head("head-sub-elsewhere", "vendor/lib");
    assert_eq!(reported["head_ready"], true, "{reported}");
    assert_eq!(probed, "head", "{reported}");
}
