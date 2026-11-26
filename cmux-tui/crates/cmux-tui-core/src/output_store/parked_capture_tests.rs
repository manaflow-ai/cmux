//! The snapshot pass on parked mirrors: a quiet or ended tab nobody views
//! is judged by what its park wrote down, so a pass rebuilds nothing.

use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use super::super::{LogState, PersistencePolicy, TerminalLog};
use super::{Capture, Plan, capture_screen, content_digest};
use crate::resource::TerminalPublicId;
use crate::surface::{Surface, SurfaceOptions};

fn ended_terminal(index: usize) -> Arc<Surface> {
    Surface::exited_terminal_placeholder(
        index as u64 + 40,
        SurfaceOptions { cols: 20, rows: 4, ..SurfaceOptions::default() },
        Weak::new(),
        crate::terminal_host_runtime::TerminalHostIdentity {
            terminal_id: format!("000000000000400080000000000{index:05x}").into(),
            incarnation: format!("100000000000400080000000000{index:05x}").into(),
        },
    )
    .unwrap()
}

/// A log of generation `g` whose stored snapshot (20x4) has `digest`, ends
/// at offset 0 and is continued by an empty tail.
fn log(index: usize, digest: Option<u64>) -> TerminalLog {
    let mut state = LogState::new(Arc::from("g"), 0);
    state.snapshot_digest = digest;
    state.snapshot_end = digest.map(|_| 0);
    state.snapshot_generation = digest.map(|_| Arc::from("g"));
    state.snapshot_size = digest.map(|_| (20, 4));
    state.snapshot_at = digest.map(|_| std::time::Instant::now());
    state.tail_end = digest.map(|_| 0);
    let id = format!("term_000000000000000000000000000{index:05x}");
    TerminalLog { terminal_id: TerminalPublicId::parse(&id).unwrap(), state: Mutex::new(state) }
}

/// One capture of `surface` for `log` in snapshot mode.
fn look(surface: &Surface, log: &TerminalLog) -> (u64, Capture) {
    let policy = PersistencePolicy::resolve(Some("snapshot"), None, None);
    let plan = Plan::of(log, Duration::from_secs(3600));
    let (seen, _, capture) =
        capture_screen(surface, log, &plan, policy, false, true, false).unwrap().unwrap();
    (seen.digest, capture)
}

fn printed(index: usize) -> (Arc<Surface>, u64) {
    let surface = ended_terminal(index);
    let digest = surface
        .try_with_terminal(|terminal| {
            terminal.vt_write(format!("tab {index}\r\n$ make\r\nok\r\n$ ").as_bytes());
            content_digest(terminal)
        })
        .unwrap()
        .unwrap();
    (surface, digest)
}

/// N parked tabs whose snapshot was stored before the park: a pass over
/// them writes nothing and builds no scratch terminal, and neither does the
/// next one.
#[cfg(unix)]
#[test]
fn parked_mirrors_with_a_stored_snapshot_rebuild_nothing() {
    for index in 0..32 {
        let (surface, digest) = printed(index);
        let log = log(index, Some(digest));
        assert!(surface.park_exited_mirror());
        for _ in 0..2 {
            let (seen, capture) = look(&surface, &log);
            assert_eq!(seen, digest, "the parked digest is the stored one");
            assert!(matches!(capture, Capture::None));
        }
        assert_eq!(surface.mirror_scratch_builds(), 0, "tab {index}");
        assert!(surface.mirror_parked());
    }
}

/// A tab that parked before its snapshot was written: one pass writes it
/// from one scratch rebuild, under the digest the park wrote down, and the
/// next pass finds nothing to do.
#[cfg(unix)]
#[test]
fn a_parked_mirror_snapshots_once_then_rests() {
    let (surface, digest) = printed(0);
    let log = log(0, None);
    assert!(surface.park_exited_mirror());
    let (seen, capture) = look(&surface, &log);
    let Capture::Snapshot { replay, .. } = capture else { panic!("a snapshot is due") };
    assert!(String::from_utf8_lossy(&replay).contains("tab 0"));
    assert_eq!(seen, digest);
    assert_eq!(surface.mirror_scratch_builds(), 1);
    {
        let mut state = log.state.lock().unwrap();
        state.snapshot_digest = Some(seen);
        state.snapshot_end = Some(0);
        state.snapshot_generation = Some(Arc::from("g"));
        state.snapshot_size = Some((20, 4));
        state.snapshot_at = Some(std::time::Instant::now());
        state.tail_end = Some(0);
    }
    let (_, capture) = look(&surface, &log);
    assert!(matches!(capture, Capture::None));
    assert_eq!(surface.mirror_scratch_builds(), 1, "the second pass rebuilt nothing");
    assert!(surface.mirror_parked());
}
