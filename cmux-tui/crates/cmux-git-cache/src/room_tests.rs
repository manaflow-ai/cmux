use super::*;

#[test]
fn floor_is_a_quarter_of_the_disk() {
    let gib = 1u64 << 30;
    assert!(above_floor(6 * gib, 20 * gib));
    assert!(!above_floor(5 * gib, 20 * gib));
    assert!(!above_floor(0, 20 * gib));
    assert!(above_floor(0, 0), "an unmeasured filesystem is never refused");
}

#[test]
fn floor_is_capped_on_big_disks() {
    let gib = 1u64 << 30;
    // A lane VM: 52 GiB free of 257 GiB was refused by the old 64 GiB floor.
    assert!(above_floor(52 * gib, 257 * gib));
    assert!(above_floor(17 * gib, 257 * gib));
    assert!(!above_floor(16 * gib, 257 * gib));
    assert_eq!(floor_bytes(20 * gib), 5 * gib, "Cloud's 20 GiB disk keeps its 5 GiB floor");
}

#[test]
fn space_reads_the_nearest_existing_ancestor() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("team/github.com/o/r.git");
    let (avail, total) = space(&missing).expect("tempdir's filesystem");
    assert!(total > 0 && avail <= total);
}
