//! A running brain's exit: the mux's one child reaper waits for it (no
//! thread per brain), ends what is left of its process
//! group, reaps it and tells the supervisor.

use std::sync::{Arc, Mutex, PoisonError, mpsc};

use super::Signal;

/// Hands brain `child` of Chief `chief` to `reaper`. Its exit runs as a work
/// item with the leader still unreaped: SIGTERM to what is left of its group,
/// `reaped` marked, the reap, then [`Signal::Exited`] on `sender`. When
/// nothing can wait for it, the brain is killed and reaped here and this
/// fails, so no brain runs unseen.
pub(super) fn watch(
    reaper: &cmux_threads::reaper::Reaper,
    mut child: cmux_process::Child,
    chief: String,
    reaped: Arc<Mutex<bool>>,
    sender: mpsc::Sender<Signal>,
) -> anyhow::Result<()> {
    let pid = child.id();
    let watched = reaper.watch_exited(
        pid,
        Box::new(move |zombie| {
            // `zombie` is false only when no wait sees the leader (it was
            // reaped elsewhere): its id is not ours to signal either way.
            {
                // The leader is a zombie now (its id is still taken): end
                // what is left of its own group (a crashed host's turn
                // processes; its acpmux has a group of its own), then mark
                // it reaped before the reap frees the id.
                let mut reaped = reaped.lock().unwrap_or_else(PoisonError::into_inner);
                if zombie && let Ok(group) = i32::try_from(pid) {
                    // SAFETY: as Process::signal; the leader is not reaped yet.
                    unsafe { libc::kill(-group, libc::SIGTERM) };
                }
                *reaped = true;
            }
            // Only a zombie is waited for, and its wait returns at once.
            let success = zombie && child.wait().is_ok_and(|status| status.success());
            let _ = sender.send(Signal::Exited { chief, pid, success });
        }),
    );
    let Err(unwatched) = watched else { return Ok(()) };
    // Nothing would see this brain end: stop it now, while its unreaped id
    // is still ours, and reap it.
    if let Ok(group) = i32::try_from(pid) {
        // SAFETY: as Process::signal; nothing has reaped the leader.
        unsafe { libc::kill(-group, libc::SIGKILL) };
        reap_killed(group);
    }
    Err(anyhow::Error::new(unwatched.into_error()).context("watch the Chief brain's exit"))
}

/// Reaps child `pid` after a SIGKILL; it ends at once.
fn reap_killed(pid: libc::pid_t) {
    loop {
        // SAFETY: waitpid writes nothing with a null status pointer.
        let reaped = unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) };
        if reaped >= 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
        {
            return;
        }
    }
}
