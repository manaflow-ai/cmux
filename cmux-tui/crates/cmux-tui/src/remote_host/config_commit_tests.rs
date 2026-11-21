use super::{Listener, commit_with};
use std::cell::Cell;

/// One commit: whether the write fails and a listener runs; returns (result, restarts).
fn commit(
    listener: Listener,
    save_fails: bool,
    running: bool,
) -> (anyhow::Result<Option<String>>, usize) {
    let restarts = Cell::new(0);
    let result = commit_with(
        listener,
        || if save_fails { anyhow::bail!("disk full") } else { Ok(()) },
        || running,
        || {
            restarts.set(restarts.get() + 1);
            Ok("restarted".to_owned())
        },
    );
    (result, restarts.get())
}

#[test]
fn a_write_restarts_a_running_listener_every_time() {
    // The same write twice (a retry after a failed restart) restarts twice: no comparison.
    for _ in 0..2 {
        let (result, restarts) = commit(Listener::Restart, false, true);
        assert_eq!(result.unwrap().as_deref(), Some("restarted"));
        assert_eq!(restarts, 1);
    }
}

#[test]
fn nothing_restarts_without_a_listener_or_for_the_verbs_that_handle_it() {
    let (result, restarts) = commit(Listener::Restart, false, false);
    assert!(result.unwrap().is_none() && restarts == 0);
    let (result, restarts) = commit(Listener::Caller, false, true);
    assert!(result.unwrap().is_none() && restarts == 0, "enable and disable replace it themselves");
}

#[test]
fn a_failed_write_or_restart_is_an_error() {
    let (result, restarts) = commit(Listener::Restart, true, true);
    assert!(result.is_err() && restarts == 0, "nothing restarts for a write that did not happen");
    let failed =
        commit_with(Listener::Restart, || Ok(()), || true, || anyhow::bail!("still running"));
    assert!(failed.is_err(), "a listener that did not stop is never reported restarted");
}
