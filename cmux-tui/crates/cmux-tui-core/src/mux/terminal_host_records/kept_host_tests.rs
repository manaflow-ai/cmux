use super::{TerminalHostLiveness, host_read_before_the_answer, host_that_lives};
use crate::diagnostics::KeptHost;
use crate::process_resources::ProcessStart;

/// The host of a record gets a seat only for the answer that it lives. A
/// host that is gone and a host for which the daemon could not read the
/// answer get none, and no answer makes a seat for a process that the daemon
/// did not read.
#[test]
fn only_the_answer_that_the_host_lives_gives_a_kept_host() {
    fn started_at_7(_process: u32) -> Option<ProcessStart> {
        Some(ProcessStart(7))
    }
    let host = KeptHost::read_by(4_100_001, Some(ProcessStart(9)), started_at_7);
    assert!(host.is_some(), "a process that started before the daemon");
    assert!(host_that_lives(TerminalHostLiveness::Live, host).is_some(), "the host lives");
    assert!(host_that_lives(TerminalHostLiveness::Dead, host).is_none(), "the host is gone");
    let not_read = TerminalHostLiveness::Indeterminate;
    assert!(host_that_lives(not_read, host).is_none(), "the answer was not read");
    for liveness in [
        TerminalHostLiveness::Live,
        TerminalHostLiveness::Dead,
        TerminalHostLiveness::Indeterminate,
    ] {
        assert!(host_that_lives(liveness, None).is_none(), "no process was read");
    }
}

/// The process of a host is read before the answer for its record, and the
/// answer is asked one time. When the answer is that the host lives, the host
/// had its process id for the whole time between the two, so the start that
/// was read is the host's.
#[test]
fn the_host_is_read_before_the_answer_for_its_record() {
    fn started_at_7(_process: u32) -> Option<ProcessStart> {
        Some(ProcessStart(7))
    }
    let order = std::cell::RefCell::new(Vec::new());
    let (liveness, host) = host_read_before_the_answer(
        || {
            order.borrow_mut().push("host");
            KeptHost::read_by(4_100_001, Some(ProcessStart(9)), started_at_7)
        },
        || {
            order.borrow_mut().push("answer");
            TerminalHostLiveness::Live
        },
    );
    assert_eq!(order.into_inner(), ["host", "answer"]);
    assert_eq!(liveness, TerminalHostLiveness::Live);
    assert!(host.is_some(), "the host lives");
}

/// [`super::Mux::kept_host`] with a record on disk. The process with the recorded
/// id lives and started before this daemon. While the host of the record
/// lives, that process has the seat of the terminal. For a record whose host
/// is gone, the same process has no seat.
#[cfg(unix)]
#[test]
fn a_record_whose_host_is_gone_gives_no_seat() {
    const SESSION: u32 = 4_000_001;
    let mux = super::Mux::new_for_test("kept-host-record", crate::SurfaceOptions::default());
    let (record_path, mut record, lease) =
        crate::terminal_host_runtime::record_fixture("kept-host");
    // A process that lives and that started before this one.
    record.host_pid = std::os::unix::process::parent_id();
    let terminal = crate::resource::TerminalPublicId::random().unwrap();
    let seated = || mux.connection_stats().seated_terminal(SESSION, |_| Some(record.host_pid));

    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&terminal));
    assert_eq!(liveness, TerminalHostLiveness::Live);
    assert_eq!(
        seated().and_then(|seated| seated.id).as_deref(),
        Some(terminal.as_str()),
        "the host of the record lives"
    );
    drop(seat);
    assert_eq!(seated(), None, "the seat ended");

    drop(lease);
    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&terminal));
    assert_eq!(liveness, TerminalHostLiveness::Dead);
    assert_eq!(seated(), None, "the host of the record is gone");
    drop(seat);
    if let Some(root) = record_path.parent() {
        let _ = std::fs::remove_dir_all(root);
    }
    mux.shutdown();
}
