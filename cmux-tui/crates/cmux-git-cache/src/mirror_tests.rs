use super::*;

#[test]
fn dir_is_per_tenant_and_safe() {
    let m = Mirrors::new(PathBuf::from("/c"));
    assert_eq!(m.dir("team-1", "o/r"), PathBuf::from("/c/team-1/github.com/o/r.git"));
    assert_ne!(m.dir("team-1", "o/r"), m.dir("team-2", "o/r"));
    let odd = m.dir("../x", "o/r");
    assert!(odd.starts_with("/c/") && !odd.to_string_lossy().contains(".."));
}

#[test]
fn a_first_fill_asks_github_for_the_repository_size() {
    assert_eq!(
        api_repo_url("https://github.com/Manaflow-AI/cmux.git").as_deref(),
        Some("https://api.github.com/repos/Manaflow-AI/cmux")
    );
    assert_eq!(
        api_repo_url("https://github.com/o/r").as_deref(),
        Some("https://api.github.com/repos/o/r")
    );
    for other in [
        "http://127.0.0.1:9/o/r.git",
        "https://edge.example/o/r.git",
        "https://github.com/o/r/x.git",
    ] {
        assert_eq!(api_repo_url(other), None, "{other}");
    }
    // manaflow-ai/cmux's answer on 2026-11-26 was about this size.
    assert_eq!(
        api_size_bytes(br#"{"size": 16252928, "name": "cmux"}"#),
        Some(16_252_928 * 1024)
    );
    assert_eq!(api_size_bytes(b"{}"), None);
    assert_eq!(api_size_bytes(b"not json"), None);
}

#[tokio::test]
async fn a_mirror_holding_part_of_the_repository_needs_only_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let pack = dir.path().join("objects/pack");
    std::fs::create_dir_all(&pack).unwrap();
    std::fs::write(pack.join("pack-a.pack"), vec![0u8; 4096]).unwrap();
    assert_eq!(pack_bytes(dir.path()), 4096);
    // No client: unknown, so the fill is left to the floor watch.
    assert_eq!(
        expected_fill_bytes(None, "https://github.com/o/r.git", None, dir.path()).await,
        None
    );
}

#[test]
fn a_stopped_write_leaves_no_partial_pack() {
    let dir = tempfile::tempdir().unwrap();
    let pack = dir.path().join("objects/pack");
    std::fs::create_dir_all(&pack).unwrap();
    std::fs::create_dir_all(dir.path().join("objects/incoming-abc/pack")).unwrap();
    for name in
        ["tmp_pack_X1", "tmp_idx_X1", ".tmp-123-pack-a.pack", "pack-keep.pack", "pack-keep.idx"]
    {
        std::fs::write(pack.join(name), b"x").unwrap();
    }
    clear_partial_writes(dir.path());
    let mut left: Vec<String> = std::fs::read_dir(&pack)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, ["pack-keep.idx", "pack-keep.pack"]);
    assert!(!dir.path().join("objects/incoming-abc").exists());
}

fn age(path: &Path, secs: u64) {
    let t = std::time::SystemTime::now() - Duration::from_secs(secs);
    std::fs::File::options().write(true).open(path).unwrap().set_modified(t).unwrap();
}

#[test]
fn a_sweep_gives_back_only_partial_writes_left_for_an_hour() {
    let root = tempfile::tempdir().unwrap();
    let mirror = root.path().join("lane-vm/github.com/o/r.git");
    let pack = mirror.join("objects/pack");
    std::fs::create_dir_all(&pack).unwrap();
    for name in ["tmp_pack_old", "tmp_pack_live", ".tmp-1-pack-old.pack", "pack-a.pack"] {
        std::fs::write(pack.join(name), vec![0u8; 1000]).unwrap();
    }
    let hour = STALE_PARTIAL.as_secs();
    age(&pack.join("tmp_pack_old"), hour + 60);
    age(&pack.join(".tmp-1-pack-old.pack"), hour + 60);
    age(&pack.join("pack-a.pack"), 10 * hour);
    age(&pack.join("tmp_pack_live"), 60);
    assert_eq!(sweep_stale_partial_writes(root.path()), (2, 2000));
    let mut left: Vec<String> = std::fs::read_dir(&pack)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, ["pack-a.pack", "tmp_pack_live"], "a pack and a live write stay");
    assert_eq!(sweep_stale_partial_writes(&root.path().join("missing")), (0, 0));
}

#[test]
fn only_a_gone_fetchs_keep_counts_as_stale() {
    let here = this_host().expect("hostname");
    let me = std::process::id();
    assert!(keep_is_stale(&format!("fetch-pack {} on {here}\n", i32::MAX), Some(&here)));
    assert!(!keep_is_stale(&format!("fetch-pack {me} on {here}\n"), Some(&here)), "live");
    assert!(keep_is_stale(&format!("fetch-pack {me} on another-host\n"), Some(&here)));
    assert!(!keep_is_stale("", Some(&here)), "an empty keep is an operator's");
    assert!(!keep_is_stale("held by hand\n", Some(&here)));
    assert!(!keep_is_stale(&format!("receive-pack 1 on {here}"), Some(&here)));
    assert!(!keep_is_stale(&format!("fetch-pack {} on {here}", i32::MAX), None));
}

/// fs-agent-lane-34, 2026-11-27: a fill cut after `index-pack` left a 16 GB pack under its
/// `fetch-pack` lock. The clear drops the lock and nothing else, so a repack can drop the pack.
#[test]
fn a_cut_fetchs_lock_goes_and_its_pack_stays() {
    let root = tempfile::tempdir().unwrap();
    let mirror = root.path().join("lane-vm/github.com/o/r.git");
    let pack = mirror.join("objects/pack");
    std::fs::create_dir_all(&pack).unwrap();
    let here = this_host().expect("hostname");
    for name in ["pack-cut.pack", "pack-cut.idx", "pack-live.pack", "pack-hand.pack"] {
        std::fs::write(pack.join(name), vec![0u8; 1000]).unwrap();
    }
    std::fs::write(pack.join("pack-cut.keep"), format!("fetch-pack {} on {here}\n", i32::MAX))
        .unwrap();
    let me = std::process::id();
    std::fs::write(pack.join("pack-live.keep"), format!("fetch-pack {me} on {here}\n"))
        .unwrap();
    std::fs::write(pack.join("pack-hand.keep"), b"").unwrap();
    assert_eq!(sweep_stale_partial_writes(root.path()), (1, 1000));
    let mut left: Vec<String> = std::fs::read_dir(&pack)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(
        left,
        [
            "pack-cut.idx",
            "pack-cut.pack",
            "pack-hand.keep",
            "pack-hand.pack",
            "pack-live.keep",
            "pack-live.pack"
        ]
    );
}

fn git_ok(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A mirror whose packs hold upstream's tips but no ref names them (a cut fill): the next
/// fill names the held tips, so its fetch negotiates from them; a tip it lacks stays unnamed.
#[tokio::test]
async fn a_fill_negotiates_from_the_tips_a_cut_fetch_left() {
    let tmp = tempfile::tempdir().unwrap();
    let up = tmp.path().join("up");
    std::fs::create_dir_all(&up).unwrap();
    git_ok(&up, &["init", "--quiet", "-b", "main"]);
    git_ok(&up, &["commit", "--quiet", "--allow-empty", "-m", "one"]);
    let held = git_ok(&up, &["rev-parse", "HEAD"]);
    let mirror = tmp.path().join("m.git");
    git_ok(tmp.path(), &["init", "--quiet", "--bare", "m.git"]);
    let url = up.to_string_lossy().into_owned();
    git_ok(&mirror, &["fetch", "--quiet", &url, "+refs/heads/*:refs/heads/*"]);
    git_ok(&mirror, &["repack", "-a", "-d", "-q"]);
    git_ok(&mirror, &["update-ref", "-d", "refs/heads/main"]);
    git_ok(&up, &["commit", "--quiet", "--allow-empty", "-m", "two"]);
    git_ok(&up, &["branch", "old", &held]);
    assert_eq!(Mirrors::adopt_held_tips(&mirror, &url, None).await, 1);
    let named = git_ok(&mirror, &["for-each-ref", "--format=%(refname)", KEPT_REFS]);
    assert_eq!(named, format!("{KEPT_REFS}{held}"));
    let empty = tmp.path().join("e.git");
    git_ok(tmp.path(), &["init", "--quiet", "--bare", "e.git"]);
    assert_eq!(Mirrors::adopt_held_tips(&empty, &url, None).await, 0, "no pack, no ask");
}

/// The writer's own bug: a stopped `git fetch` left `index-pack` running, which wrote its
/// `tmp_pack_*` after the clear. A stop now ends the whole group, so a grandchild that would
/// write a file after the stop never does.
#[cfg(unix)]
#[tokio::test]
async fn a_stop_ends_the_children_of_the_git_it_stops() {
    let dir = tempfile::tempdir().unwrap();
    let late = dir.path().join("tmp_pack_late");
    let mut cmd = Command::new("/bin/sh");
    cmd.arg("-c").arg(format!("(sleep 3; : > '{}') & sleep 30", late.display()));
    // The daemon's gits lead their groups (it has no terminal); a test run from one must ask.
    cmd.process_group(0);
    let got = run_watched(
        cmd,
        None,
        Duration::from_secs(60),
        Some(Box::new(|| Some("under the floor".to_owned()))),
    )
    .await;
    assert_eq!(got.err().as_deref(), Some("under the floor"));
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!late.exists(), "a child of the stopped process wrote after the stop");
}

#[test]
fn a_fetch_the_floor_stopped_reads_no_room_though_clearing_its_pack_frees_the_disk() {
    let dir = tempfile::tempdir().unwrap();
    let pack = dir.path().join("objects/pack");
    std::fs::create_dir_all(&pack).unwrap();
    std::fs::write(pack.join("tmp_pack_X1"), b"x").unwrap();
    // The disk is under the floor while the stopped pack is there and above it once cleared.
    let room = |d: &Path| !d.join("objects/pack/tmp_pack_X1").exists();
    assert_eq!(after_stop(dir.path(), room), Fetched::NoRoom);
    assert!(!pack.join("tmp_pack_X1").exists());
    // A failure with room to spare is a plain failure: the next miss may try again soon.
    assert_eq!(after_stop(dir.path(), room), Fetched::Failed);
}

fn sh_git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn packs(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir.join("objects/pack"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".pack"))
        .collect();
    names.sort();
    names
}

/// gcp-agent-lane-4, 2026-11-27: a fill timed out after its fetch wrote the whole pack and
/// before it wrote a ref, and the next fill downloaded the whole repository again.
#[tokio::test]
async fn a_pack_a_cut_fill_finished_is_named_so_the_next_fill_fetches_only_the_rest() {
    let up = tempfile::tempdir().unwrap();
    sh_git(up.path(), &["init", "-q", "-b", "main"]);
    std::fs::write(up.path().join("a"), b"one").unwrap();
    sh_git(up.path(), &["add", "a"]);
    sh_git(
        up.path(),
        &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"],
    );
    sh_git(up.path(), &["tag", "v1"]);
    let tip = sh_git(up.path(), &["rev-parse", "HEAD"]);
    let url = format!("file://{}", up.path().display());
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("m.git");
    assert!(Mirrors::init(&dir).await);
    assert_eq!(Mirrors::adopt_cut_fetch_packs(&dir, &url, None).await, 0, "no keep, no work");
    // A fetch this small is unpacked into loose objects; the real one is one pack.
    let mut args = vec!["-c", "fetch.unpackLimit=1", "fetch", "-q", url.as_str()];
    args.extend(REFSPECS);
    sh_git(&dir, &args);
    // What the cut fill left: the pack and fetch's keep on it, no ref.
    let before = packs(&dir);
    assert_eq!(before.len(), 1);
    let keep = dir.join("objects/pack").join(before[0].replace(".pack", ".keep"));
    std::fs::write(&keep, b"fetch-pack 2647434 on lane-vm\n").unwrap();
    sh_git(&dir, &["update-ref", "-d", "refs/heads/main"]);
    sh_git(&dir, &["update-ref", "-d", "refs/tags/v1"]);
    assert_eq!(sh_git(&dir, &["for-each-ref"]), "");

    assert_eq!(Mirrors::adopt_cut_fetch_packs(&dir, &url, None).await, 1);
    assert!(!keep.exists(), "the stale keep stays");
    assert_eq!(
        sh_git(&dir, &["for-each-ref", "--format=%(refname)"]),
        format!("{KEPT_REFS}{tip}")
    );
    // The next fill negotiates from the named tip: it writes no second pack.
    sh_git(&dir, &args);
    assert_eq!(packs(&dir), before, "the next fill downloaded the repository again");
}

#[tokio::test]
async fn a_watch_stops_a_running_git_and_says_why() {
    let mut cmd = Command::new("sleep");
    cmd.arg("30");
    let started = std::time::Instant::now();
    let got = run_watched(
        cmd,
        None,
        Duration::from_secs(60),
        Some(Box::new(|| Some("under the floor".to_owned()))),
    )
    .await;
    assert_eq!(got.err().as_deref(), Some("under the floor"));
    assert!(started.elapsed() < Duration::from_secs(10));
}
