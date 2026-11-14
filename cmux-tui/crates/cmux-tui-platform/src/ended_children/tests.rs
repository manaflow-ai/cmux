use super::{keep_their_ids, keeps_ended_children};

fn action(handler: libc::sighandler_t, flags: libc::c_int) -> libc::sigaction {
    // SAFETY: sigaction is plain old data; all-zero is valid.
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    action.sa_sigaction = handler;
    action.sa_flags = flags;
    action
}

/// The system frees an ended child's process id at once for a process
/// that ignores `SIGCHLD` or that set `SA_NOCLDWAIT`; with the default
/// action it keeps the id until the process waits for the child.
#[test]
fn a_process_that_ignores_its_ended_children_does_not_keep_their_ids() {
    assert!(keeps_ended_children(&action(libc::SIG_DFL, 0)));
    assert!(keeps_ended_children(&action(libc::SIG_DFL, libc::SA_RESTART)));
    assert!(!keeps_ended_children(&action(libc::SIG_IGN, 0)));
    assert!(!keeps_ended_children(&action(libc::SIG_DFL, libc::SA_NOCLDWAIT)));
    assert!(!keeps_ended_children(&action(libc::SIG_IGN, libc::SA_NOCLDWAIT)));
    // The test's own process has the default action.
    assert!(keep_their_ids());
}
