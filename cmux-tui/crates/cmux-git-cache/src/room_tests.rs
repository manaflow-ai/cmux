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
fn a_write_must_end_above_the_floor() {
    let gib = 1u64 << 30;
    // fs-agent-lane-24: 63 GiB disk (floor 15.75 GiB), 31 GiB free, a 15.5 GiB cmux mirror.
    assert!(above_floor(31 * gib, 63 * gib), "the old check let the fill start");
    assert!(!room_after(31 * gib, 63 * gib, 31 * gib / 2), "it would end under the floor");
    assert!(room_after(40 * gib, 63 * gib, 15 * gib));
    assert!(!room_after(gib, 63 * gib, 2 * gib), "more than is free never wraps around");
    assert!(room_after(0, 0, u64::MAX), "an unmeasured filesystem is never refused");
}

#[test]
fn space_reads_the_nearest_existing_ancestor() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("team/github.com/o/r.git");
    let (avail, total) = space(&missing).expect("tempdir's filesystem");
    assert!(total > 0 && avail <= total);
}
