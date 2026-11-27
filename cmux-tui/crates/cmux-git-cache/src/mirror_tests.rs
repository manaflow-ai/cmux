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
    assert_eq!(api_size_bytes(br#"{"size": 16252928, "name": "cmux"}"#), Some(16_252_928 * 1024));
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
