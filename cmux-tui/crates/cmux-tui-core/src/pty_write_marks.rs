//! The flow marks of a PTY write (`plans/cmux-next/trace.md`): `daemon.pty.write` when the daemon
//! writes the PTY itself (holder model), `host.pty.write` when a terminal host does. Each is marked
//! after the write, outside the writer's lock, and only when the bytes reached the PTY: input
//! dropped on an exited host's final screen, or refused for want of room, is no hop.

/// Bytes the daemon wrote to its own PTY.
pub(crate) fn daemon_wrote(terminal: &str) {
    cmux_flow_trace::hop("daemon.pty.write", 0, terminal);
    #[cfg(test)]
    MARKED.with(|marked| marked.borrow_mut().push("daemon.pty.write"));
}

/// Bytes a terminal host wrote to its PTY.
pub(crate) fn host_wrote(terminal: &[u8; 16]) {
    cmux_flow_trace::hop_id("host.pty.write", 0, terminal);
    #[cfg(test)]
    MARKED.with(|marked| marked.borrow_mut().push("host.pty.write"));
}

#[cfg(test)]
thread_local! {
    static MARKED: std::cell::RefCell<Vec<&'static str>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// The marks this thread made since the last call.
#[cfg(test)]
pub(crate) fn take_marked() -> Vec<&'static str> {
    MARKED.with(|marked| std::mem::take(&mut *marked.borrow_mut()))
}
