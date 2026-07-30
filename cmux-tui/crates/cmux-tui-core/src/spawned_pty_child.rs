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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    #[derive(Debug)]
    struct FailedKiller;

    impl portable_pty::ChildKiller for FailedKiller {
        fn kill(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "forced child kill failure",
            ))
        }

        fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
            Box::new(Self)
        }
    }

    #[derive(Debug)]
    struct BlockingWaitChild {
        try_waits: Arc<AtomicUsize>,
        wait_called: Arc<AtomicBool>,
    }

    impl portable_pty::ChildKiller for BlockingWaitChild {
        fn kill(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "forced child kill failure",
            ))
        }

        fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
            Box::new(FailedKiller)
        }
    }

    impl portable_pty::Child for BlockingWaitChild {
        fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
            self.try_waits.fetch_add(1, Ordering::AcqRel);
            Ok(None)
        }

        fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
            self.wait_called.store(true, Ordering::Release);
            loop {
                std::thread::park();
            }
        }

        fn process_id(&self) -> Option<u32> {
            None
        }
    }

    #[test]
    fn failed_kill_does_not_block_spawned_child_drop() {
        const CHILD_ENV: &str = "CMUX_TUI_TEST_NONBLOCKING_CHILD_DROP";
        const TEST_NAME: &str =
            "spawned_pty_child::tests::failed_kill_does_not_block_spawned_child_drop";
        if std::env::var_os(CHILD_ENV).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST_NAME])
                .env(CHILD_ENV, "1")
                .status()
                .unwrap();
            assert!(status.success(), "nonblocking child-drop subprocess failed: {status}");
            return;
        }

        let try_waits = Arc::new(AtomicUsize::new(0));
        let wait_called = Arc::new(AtomicBool::new(false));
        let child = SpawnedPtyChild::new(Box::new(BlockingWaitChild {
            try_waits: try_waits.clone(),
            wait_called: wait_called.clone(),
        }));
        let (dropped_sender, dropped_receiver) = std::sync::mpsc::sync_channel(1);
        std::thread::spawn(move || {
            drop(child);
            let _ = dropped_sender.send(());
        });

        dropped_receiver
            .recv_timeout(Duration::from_millis(250))
            .expect("spawned PTY child Drop blocked after kill failed");
        let deadline = Instant::now() + Duration::from_millis(250);
        while try_waits.load(Ordering::Acquire) == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(try_waits.load(Ordering::Acquire) > 0, "cleanup owner never polled the child");
        assert!(!wait_called.load(Ordering::Acquire), "cleanup owner called blocking child wait");
    }
}
