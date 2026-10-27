//! The Hermes reaper's state is used again after a panic in another holder.

use super::*;

#[test]
fn hermes_reaper_reaps_after_a_holder_panicked_with_its_locks() {
    let child = cmux_process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
    let pid = libc::pid_t::try_from(child.id()).unwrap();
    let child_exit = UnixChildExitSignal::observe(child.id()).unwrap();
    let state = Arc::new(HermesReapState::new(child, Some(child_exit)));
    let holder = Arc::clone(&state);
    let panicked = std::thread::spawn(move || {
        let _child = holder.child.lock().unwrap();
        let _child_exit = holder.child_exit.lock().unwrap();
        panic!("a holder panics with the reaper state locked");
    })
    .join();
    assert!(panicked.is_err());
    assert!(state.child.is_poisoned() && state.child_exit.is_poisoned());

    state.reap();

    assert!(state.child.lock().unwrap_or_else(PoisonError::into_inner).is_none());
    assert!(state.child_exit.lock().unwrap_or_else(PoisonError::into_inner).is_none());
    let mut status = 0;
    // SAFETY: `pid` is this test's direct child; WNOHANG never blocks.
    let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
    assert_eq!(waited, -1, "the reaper already waited for the child");
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ECHILD));
}
