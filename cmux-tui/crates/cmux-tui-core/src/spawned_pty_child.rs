//! Immediate ownership of a spawned PTY child until its reaper completes.

#[cfg(unix)]
use std::time::Duration;

#[cfg(unix)]
const FAILED_SPAWN_SESSION_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);

#[cfg(unix)]
fn signal_owned_child_for_cleanup(session: libc::pid_t) -> std::io::Result<()> {
    loop {
        // SAFETY: callers retain the sole unreaped Child handle for `session`,
        // so the numeric PID cannot be reused before the final wait.
        if unsafe { libc::kill(session, libc::SIGKILL) } == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(error);
    }
}

pub(crate) struct SpawnedPtyChild {
    child: Option<Box<dyn portable_pty::Child + Send + Sync>>,
    #[cfg(unix)]
    reaper: Option<crate::process_session::ReservedChildReaperLease>,
}

impl SpawnedPtyChild {
    pub(crate) fn new(child: Box<dyn portable_pty::Child + Send + Sync>) -> Self {
        Self {
            child: Some(child),
            #[cfg(unix)]
            reaper: None,
        }
    }

    #[cfg(unix)]
    pub(crate) fn with_reaper(
        mut self,
        reaper: crate::process_session::ReservedChildReaperLease,
    ) -> Self {
        assert!(self.reaper.replace(reaper).is_none(), "spawned PTY child already has a reaper");
        self
    }

    #[cfg(unix)]
    pub(crate) fn take_reaper(
        &mut self,
    ) -> Option<crate::process_session::ReservedChildReaperLease> {
        self.reaper.take()
    }

    pub(crate) fn process_id(&self) -> Option<u32> {
        self.child.as_ref().expect("spawned PTY child is present").process_id()
    }

    pub(crate) fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
        self.child.as_ref().expect("spawned PTY child is present").clone_killer()
    }

    pub(crate) fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
        let result = self.child.as_mut().expect("spawned PTY child is present").wait();
        if result.is_ok() {
            self.child.take();
        }
        result
    }

    /// Release a child only after stable identity proves that this process no
    /// longer owns its wait handle and the numeric PID belongs to no live
    /// process from the original publication.
    pub(crate) fn abandon_wait_ownership(mut self) {
        self.child.take();
    }
}

#[cfg(unix)]
fn enqueue_failed_spawn_cleanup(
    child: Box<dyn portable_pty::Child + Send + Sync>,
    reaper: crate::process_session::ReservedChildReaperLease,
    session: libc::pid_t,
) {
    // The unreaped Child handle reserves this numeric PID, so this raw signal
    // cannot retarget a reused process. Keep the leader waitable while the
    // shared reaper enumerates and removes every other session member.
    let _ = signal_owned_child_for_cleanup(session);

    let (finished_sender, finished_receiver) = std::sync::mpsc::sync_channel(1);
    let mut finished_sender = Some(finished_sender);
    let mut child = Some(child);
    crate::process_session::enqueue_reserved_session_leader(
        reaper,
        session,
        FAILED_SPAWN_SESSION_CLEANUP_TIMEOUT,
        move || match crate::process_session::observe_child_without_reaping(session, true)? {
            crate::process_session::ChildWaitState::Running => {
                signal_owned_child_for_cleanup(session)?;
                Ok(false)
            }
            crate::process_session::ChildWaitState::Waitable => Ok(true),
            crate::process_session::ChildWaitState::OwnershipLost => {
                Err(std::io::Error::from(std::io::ErrorKind::NotFound))
            }
        },
        || true,
        || true,
        move |cleanup_succeeded| {
            if !cleanup_succeeded {
                return crate::process_session::NaturalReapFinish::Pending;
            }
            let Some(owned_child) = child.as_mut() else {
                return crate::process_session::NaturalReapFinish::Complete;
            };
            match owned_child.wait() {
                Ok(_) => {
                    child.take();
                    if let Some(sender) = finished_sender.take() {
                        let _ = sender.send(());
                    }
                    crate::process_session::NaturalReapFinish::Complete
                }
                Err(_) => crate::process_session::NaturalReapFinish::Failed,
            }
        },
    );
    let _ = finished_receiver
        .recv_timeout(FAILED_SPAWN_SESSION_CLEANUP_TIMEOUT + Duration::from_millis(250));
}

impl Drop for SpawnedPtyChild {
    fn drop(&mut self) {
        let Some(child) = self.child.take() else { return };
        #[cfg(unix)]
        let child = match self.reaper.take() {
            Some(reaper) => {
                let Some(session) =
                    child.process_id().and_then(|pid| libc::pid_t::try_from(pid).ok())
                else {
                    drop(reaper);
                    let mut child = child;
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                };
                enqueue_failed_spawn_cleanup(child, reaper, session);
                return;
            }
            None => child,
        };
        let mut child = child;
        let _ = child.kill();
        let _ = child.wait();
    }
}
