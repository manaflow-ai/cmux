//! Whether this process keeps the process ids of its ended children.
//!
//! The system keeps the process id of a child that ended until its parent
//! waits for it, so a parent that holds a child, not yet waited for, knows
//! that the child's id names no other process. That is not so for a parent
//! that ignores `SIGCHLD` or that set `SA_NOCLDWAIT`: the system then frees
//! a child's id at the child's end and can give it to another process. A
//! process can have an ignored `SIGCHLD` from the process that started it.

/// Whether the system keeps the process id of an ended child of this
/// process until this process waits for it. One read of this process's
/// `SIGCHLD` action.
#[cfg(unix)]
pub fn keep_their_ids() -> bool {
    // SAFETY: sigaction is plain old data; all-zero is valid.
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    // SAFETY: with no new action the call only writes the present one into
    // `action`.
    let read = unsafe { libc::sigaction(libc::SIGCHLD, std::ptr::null(), &raw mut action) };
    read == 0 && keeps_ended_children(&action)
}

/// Whether a process with this `SIGCHLD` action keeps its ended children
/// until it waits for them.
#[cfg(unix)]
fn keeps_ended_children(action: &libc::sigaction) -> bool {
    action.sa_sigaction != libc::SIG_IGN && action.sa_flags & libc::SA_NOCLDWAIT == 0
}

/// Windows keeps a process id while a handle of the process is open, and
/// the owner of a child holds one.
#[cfg(not(unix))]
pub fn keep_their_ids() -> bool {
    true
}

#[cfg(all(test, unix))]
mod tests;
