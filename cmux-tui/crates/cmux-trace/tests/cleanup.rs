//! The dead-ring cleanup ([`cmux_trace::cleanup`], task 095): live processes keep their rings,
//! long-dead ones go, and the dead processes' black boxes stay under the cap.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use cmux_trace::cleanup::{self, DEAD_BYTE_CAP, MAX_AGE};
use cmux_trace::{HEADER_BYTES, Role, blackbox_file_name, recording_file_name};

const DAY_NS: u64 = 24 * 3600 * 1_000_000_000;
/// "Now" of every case: day 100 after 1970.
const NOW: u64 = 100 * DAY_NS;

fn scratch_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-trace-cleanup-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// A v1 ring header for `pid` (started at `start_us`), `bytes` long.
fn write_ring(dir: &Path, name: &str, pid: u32, start_us: u64, bytes: u64) {
    let mut header = vec![0u8; HEADER_BYTES];
    header[..8].copy_from_slice(b"CMXTRACE");
    header[8..12].copy_from_slice(&1u32.to_le_bytes());
    header[16..20].copy_from_slice(&pid.to_le_bytes());
    header[32..40].copy_from_slice(&(NOW - 50 * DAY_NS).to_le_bytes());
    header[40..48].copy_from_slice(&start_us.to_le_bytes());
    let path = dir.join(name);
    std::fs::write(&path, &header).expect("writes the header");
    std::fs::File::options()
        .write(true)
        .open(&path)
        .and_then(|file| file.set_len(bytes))
        .expect("sizes the ring");
}

/// Dates the dead marker of ring `name` `age_ns` before [`NOW`].
fn mark_dead(dir: &Path, name: &str, age_ns: u64) {
    let marker = dir.join(format!("{name}.dead"));
    let file = std::fs::File::create(&marker).expect("creates the marker");
    file.set_modified(UNIX_EPOCH + Duration::from_nanos(NOW - age_ns)).expect("dates the marker");
}

fn names(dir: &Path) -> HashSet<String> {
    std::fs::read_dir(dir)
        .expect("lists")
        .map(|entry| entry.expect("entry").file_name().into_string().expect("utf-8"))
        .collect()
}

#[test]
fn cleanup_keeps_live_pids_and_deletes_long_dead_rings() {
    let dir = scratch_dir("age");
    let live = blackbox_file_name(Role::Daemon, 10);
    let old_dead = blackbox_file_name(Role::TerminalHost, 20);
    let new_dead = blackbox_file_name(Role::Holder, 30);
    let unmarked = blackbox_file_name(Role::AppHost, 40);
    let recording = recording_file_name(Role::Daemon, 20);
    for (name, pid) in [(&live, 10), (&old_dead, 20), (&new_dead, 30), (&unmarked, 40)] {
        write_ring(&dir, name, pid, 7, 64 * 1024);
    }
    write_ring(&dir, &recording, 20, 7, 64 * 1024);
    // A live process whose pid an older dead one used: the old marker must not date it.
    mark_dead(&dir, &live, 10 * DAY_NS);
    mark_dead(&dir, &old_dead, 4 * DAY_NS);
    mark_dead(&dir, &new_dead, 2 * DAY_NS);
    // A marker whose ring is gone.
    mark_dead(&dir, &blackbox_file_name(Role::Acpmux, 50), DAY_NS);

    let report = cleanup::run_with(&dir, |pid, _| pid == 10, NOW);

    assert_eq!(report.live, vec![live.clone()]);
    assert_eq!(report.deleted, vec![old_dead]);
    let mut kept = report.kept_dead;
    kept.sort();
    let mut expected = vec![new_dead.clone(), unmarked.clone()];
    expected.sort();
    assert_eq!(kept, expected);
    let left = names(&dir);
    let expected: HashSet<String> = [
        live,
        new_dead.clone(),
        format!("{new_dead}.dead"),
        unmarked.clone(),
        format!("{unmarked}.dead"),
        recording,
    ]
    .into_iter()
    .collect();
    assert_eq!(left, expected, "the recording ring is not the cleanup's");

    // The ring found dead now is dated from now: it goes once it has been dead past the age.
    let later = NOW + u64::try_from(MAX_AGE.as_nanos()).expect("fits") + 1;
    let report = cleanup::run_with(&dir, |pid, _| pid == 10, later);
    assert!(report.deleted.contains(&unmarked), "{report:?}");
    assert!(report.deleted.contains(&new_dead), "{report:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cleanup_holds_the_cap_without_touching_live_rings() {
    let dir = scratch_dir("cap");
    let ring_bytes = 6 * 1024 * 1024;
    // Five dead rings of 6 MiB (30 MiB): the three longest dead go, two stay (12 MiB).
    let dead: Vec<String> = (1..=5).map(|pid| blackbox_file_name(Role::Daemon, pid)).collect();
    for (age, name) in dead.iter().enumerate() {
        let pid = u32::try_from(age + 1).expect("small");
        write_ring(&dir, name, pid, 7, ring_bytes);
        // pid 1 has been dead longest.
        mark_dead(
            &dir,
            name,
            (2 * DAY_NS) - u64::try_from(age).expect("small") * 3_600_000_000_000,
        );
    }
    // Two live rings that alone are over the cap.
    let live: Vec<String> = (100..102).map(|pid| blackbox_file_name(Role::App, pid)).collect();
    for (offset, name) in live.iter().enumerate() {
        write_ring(&dir, name, 100 + u32::try_from(offset).expect("small"), 7, 2 * DEAD_BYTE_CAP);
    }

    let report = cleanup::run_with(&dir, |pid, _| pid >= 100, NOW);

    assert_eq!(report.deleted, dead[..3].to_vec());
    assert_eq!(report.kept_dead, dead[3..].to_vec());
    let mut live_report = report.live.clone();
    live_report.sort();
    assert_eq!(live_report, live);
    let kept_bytes: u64 = report
        .kept_dead
        .iter()
        .map(|name| std::fs::metadata(dir.join(name)).expect("kept").len())
        .sum();
    assert!(kept_bytes <= DEAD_BYTE_CAP, "{kept_bytes}");
    for name in &live {
        assert!(dir.join(name).exists(), "{name} is live");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cleanup_deletes_dead_spare_builds_only() {
    let dir = scratch_dir("spare");
    let own = format!("app.spare.cmxtrace.{}.tmp", std::process::id());
    let dead = "app.spare.cmxtrace.77.tmp".to_owned();
    let other = "notes.77.tmp".to_owned();
    for name in [&own, &dead, &other] {
        std::fs::write(dir.join(name), b"x").expect("writes");
    }
    let me = std::process::id();
    let report = cleanup::run_with(&dir, |pid, _| pid == me, NOW);
    assert_eq!(report.deleted, vec![dead]);
    assert_eq!(names(&dir), [own, other].into_iter().collect());
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn cleanup_process_table_tells_live_dead_and_reused_pids() {
    let me = std::process::id();
    assert!(cleanup::process_is_alive(me, 0));
    let mut child = std::process::Command::new("true").spawn().expect("spawns true");
    let pid = child.id();
    child.wait().expect("reaps");
    assert!(!cleanup::process_is_alive(pid, 0), "an exited, reaped child is dead");
    assert!(!cleanup::process_is_alive(0, 0));

    // The real header's start time keeps our ring; another start time (a reused pid) does not.
    let dir = scratch_dir("table");
    let open = cmux_trace::init_blackbox(&dir, Role::Daemon).expect("first init");
    let path = open.wait().expect("the ring file");
    let header = std::fs::read(&path).expect("reads the ring");
    let start_us = u64::from_le_bytes(header[40..48].try_into().expect("8 bytes"));
    if start_us != 0 {
        assert!(cleanup::process_is_alive(me, start_us));
        assert!(!cleanup::process_is_alive(me, start_us + 1));
    }
    let report = cleanup::run(&dir);
    assert_eq!(report.live, vec![blackbox_file_name(Role::Daemon, me)]);
    assert!(report.deleted.is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}
