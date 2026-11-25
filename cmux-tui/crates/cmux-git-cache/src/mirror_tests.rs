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
