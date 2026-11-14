use super::{TerminalHostLiveness, host_that_lives};
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
