//! A terminal host whose parser thread panics must end: it publishes its
//! exit and ends its process. Before this guard the host lived forever: the
//! parser was the only one that marks the PTY drained, so the exit was never
//! published (FLAKE-TERMINAL-HOST-RECOVERY-SIDECARS: "terminal host records
//! or exit sidecars remained after close").

use super::*;

#[test]
fn a_panicking_parser_publishes_the_exit_and_ends_the_host() {
    let host = exited_host_fixture();
    // The stuck state seen with gdb: the child is reaped, and the parser
    // died before it marked the PTY drained.
    host.pty_drained.store(false, Ordering::Release);
    let ended = Arc::new(AtomicBool::new(false));
    let parser = {
        let host = host.clone();
        let ended = ended.clone();
        thread::spawn(move || {
            let guarded = host.clone();
            let parse = move || {
                // As in the real failure: the panic happens while the
                // parser holds the terminal lock, so the lock is poisoned.
                let _term = host.term.lock().unwrap();
                panic!("test: the parser panicked while it held the terminal lock");
            };
            run_guarded_host_parser(&guarded, parse, move || ended.store(true, Ordering::Release));
        })
    };
    let _ = parser.join();
    assert!(host.dead.load(Ordering::Acquire), "the host did not publish its exit");
    assert!(host.exit_record_path.exists(), "the host wrote no exit sidecar");
    assert!(ended.load(Ordering::Acquire), "the host process was not ended");
}
