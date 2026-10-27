//! A hidden terminal's reader thread (it reads and parses) runs at utility
//! after its next byte and at the echo class after a byte once shown, with
//! no wake of its own for either change.

use std::time::{Duration, Instant};

use cmux_threads::{QosChange, ThreadInfo, ThreadQos};

use super::*;
use crate::mux::Mux;

fn reader_row(name: &str) -> ThreadInfo {
    cmux_threads::snapshot()
        .into_iter()
        .find(|row| row.name == name)
        .unwrap_or_else(|| panic!("no registry row {name}"))
}

/// Waits until the reader acted on a request for `qos`: it runs at it, or
/// (an unprivileged Linux thread that could never come back from a raised
/// nice) it refused it once more.
fn wait_acted(name: &str, qos: ThreadQos, refused_before: u32) -> ThreadInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let row = reader_row(name);
        if row.effective == Some(qos) || row.refused_changes > refused_before {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never applied {qos:?}: {row:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
#[test]
fn a_hidden_terminals_reader_applies_utility_after_one_byte_and_returns_when_shown() {
    // The reader's progress publication writes sqlite (surface/directory.rs,
    // a known MQ-13 site): record it, as store_lock_blocking_tests does.
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let options = SurfaceOptions { command: Some(vec!["cat".into()]), ..SurfaceOptions::default() };
    let mux = Mux::new(format!("thread-qos-{}-{nanos}", std::process::id()), options);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let name = format!("surface-{}-reader", surface.id);
    surface.write_bytes(b"a").unwrap();
    let start = wait_acted(&name, ThreadQos::UserInteractive, u32::MAX);
    assert_eq!(start.desired, ThreadQos::UserInteractive);

    surface.set_threads_shown(false);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility));
    // The request alone wakes nothing: the idle reader has not acted on it.
    let idle = reader_row(&name);
    assert_eq!(idle.desired, ThreadQos::Utility);
    assert_eq!((idle.effective, idle.refused_changes), (start.effective, start.refused_changes));

    surface.write_bytes(b"b").unwrap();
    let hidden = wait_acted(&name, ThreadQos::Utility, start.refused_changes);
    let demoted = if cmux_threads::reversible(ThreadQos::Utility) {
        QosChange::Applied
    } else {
        QosChange::Refused
    };
    if demoted == QosChange::Applied {
        assert_eq!(hidden.effective, Some(ThreadQos::Utility));
        #[cfg(target_vendor = "apple")]
        assert_eq!(hidden.live, cmux_threads::LiveQos::Class(ThreadQos::Utility));
    } else {
        assert_eq!(hidden.refused_changes, start.refused_changes + 1);
    }

    surface.set_threads_shown(true);
    surface.write_bytes(b"c").unwrap();
    if demoted == QosChange::Applied {
        let shown = wait_acted(&name, ThreadQos::UserInteractive, u32::MAX);
        assert_eq!(shown.effective, Some(ThreadQos::UserInteractive));
        #[cfg(target_vendor = "apple")]
        assert_eq!(shown.live, cmux_threads::LiveQos::Class(ThreadQos::UserInteractive));
    }
    assert_eq!(reader_row(&name).desired, ThreadQos::UserInteractive);
    mux.shutdown();
}

#[test]
fn an_unchanged_class_is_no_request() {
    let mux = Mux::new_for_test("thread-qos-unchanged", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.set_threads_shown(true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
    surface.set_threads_shown(false);
    surface.set_threads_shown(false);
    assert_eq!(surface.thread_qos(), Some(HIDDEN_TERMINAL_QOS));
}
