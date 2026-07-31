//! Immediate ownership of a spawned PTY child until its reaper completes.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(unix)]
const FAILED_SPAWN_SESSION_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const PORTABLE_CHILD_REAP_CAPACITY: usize = 4_096;
const PORTABLE_CHILD_REAP_RETRY_INITIAL: Duration = Duration::from_millis(25);
const PORTABLE_CHILD_REAP_RETRY_MAX: Duration = Duration::from_secs(1);

static PORTABLE_CHILD_REAPER: OnceLock<Mutex<Option<PortableChildReaper>>> = OnceLock::new();
static STRANDED_PORTABLE_CHILDREN: OnceLock<Mutex<Vec<StrandedPortableChild>>> = OnceLock::new();

struct PortableChildReaper {
    sender: mpsc::Sender<PortableChildReapRequest>,
    active: Arc<AtomicUsize>,
    _worker: std::thread::JoinHandle<()>,
}

pub(crate) struct ReservedPortableChildReaperLease {
    sender: mpsc::Sender<PortableChildReapRequest>,
    active: Arc<AtomicUsize>,
}

impl Drop for ReservedPortableChildReaperLease {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

struct PortableChildReapRequest {
    child: Box<dyn portable_pty::Child + Send + Sync>,
    _lease: ReservedPortableChildReaperLease,
    next_attempt: Instant,
    retry_delay: Duration,
}

struct StrandedPortableChild {
    _child: Box<dyn portable_pty::Child + Send + Sync>,
    _lease: Option<ReservedPortableChildReaperLease>,
}

impl PortableChildReapRequest {
    fn schedule_retry(&mut self) {
        self.next_attempt = Instant::now() + self.retry_delay;
        self.retry_delay = (self.retry_delay * 2).min(PORTABLE_CHILD_REAP_RETRY_MAX);
    }
}

impl PortableChildReaper {
    fn start() -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let active = Arc::new(AtomicUsize::new(0));
        let worker = std::thread::Builder::new()
            .name("cmux-portable-child-reaper".into())
            .spawn(move || run_portable_child_reaper(receiver))?;
        Ok(Self { sender, active, _worker: worker })
    }

    fn lease(&self) -> std::io::Result<ReservedPortableChildReaperLease> {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < PORTABLE_CHILD_REAP_CAPACITY).then_some(active + 1)
            })
            .map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "portable child reaper capacity exhausted",
                )
            })?;
        Ok(ReservedPortableChildReaperLease {
            sender: self.sender.clone(),
            active: self.active.clone(),
        })
    }
}

pub(crate) fn reserve_portable_child_reaper() -> std::io::Result<ReservedPortableChildReaperLease> {
    let mut slot = PORTABLE_CHILD_REAPER.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if slot.is_none() {
        *slot = Some(PortableChildReaper::start()?);
    }
    slot.as_ref().expect("portable child reaper initialized").lease()
}

#[cfg(test)]
fn portable_child_reaper_active_for_test() -> usize {
    let Some(slot) = PORTABLE_CHILD_REAPER.get() else { return 0 };
    let slot = slot.lock().unwrap();
    slot.as_ref().map_or(0, |reaper| reaper.active.load(Ordering::Acquire))
}

fn enqueue_portable_child_cleanup(
    child: Box<dyn portable_pty::Child + Send + Sync>,
    lease: ReservedPortableChildReaperLease,
) {
    let sender = lease.sender.clone();
    let request = PortableChildReapRequest {
        child,
        _lease: lease,
        next_attempt: Instant::now(),
        retry_delay: PORTABLE_CHILD_REAP_RETRY_INITIAL,
    };
    if let Err(mpsc::SendError(request)) = sender.send(request) {
        retain_stranded_portable_child(request.child, Some(request._lease));
    }
}

fn retain_stranded_portable_child(
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    lease: Option<ReservedPortableChildReaperLease>,
) {
    // A Windows child always reserves the shared worker before spawn, so this
    // path requires the already-started worker to have failed unexpectedly.
    // Retain the handle without calling blocking wait; bounded capacity then
    // prevents later spawns from silently compounding the ownership failure.
    let _ = child.kill();
    STRANDED_PORTABLE_CHILDREN
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap()
        .push(StrandedPortableChild { _child: child, _lease: lease });
}

fn run_portable_child_reaper(receiver: mpsc::Receiver<PortableChildReapRequest>) {
    let mut pending = Vec::<PortableChildReapRequest>::new();
    loop {
        let received = if pending.is_empty() {
            receiver.recv().map_err(|_| RecvTimeoutError::Disconnected)
        } else {
            let now = Instant::now();
            let wait = pending
                .iter()
                .map(|request| request.next_attempt.saturating_duration_since(now))
                .min()
                .unwrap_or(PORTABLE_CHILD_REAP_RETRY_MAX);
            receiver.recv_timeout(wait)
        };
        match received {
            Ok(request) => pending.push(request),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) if pending.is_empty() => return,
            Err(RecvTimeoutError::Disconnected) => {
                std::thread::sleep(PORTABLE_CHILD_REAP_RETRY_MAX);
            }
        }
        while let Ok(request) = receiver.try_recv() {
            pending.push(request);
        }

        let now = Instant::now();
        let mut index = 0;
        while index < pending.len() {
            if pending[index].next_attempt > now {
                index += 1;
                continue;
            }
            let mut request = pending.swap_remove(index);
            let _ = request.child.kill();
            match request.child.try_wait() {
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    request.schedule_retry();
                    pending.push(request);
                }
            }
        }
    }
}

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
    portable_reaper: Option<ReservedPortableChildReaperLease>,
}

impl SpawnedPtyChild {
    pub(crate) fn new(child: Box<dyn portable_pty::Child + Send + Sync>) -> Self {
        Self {
            child: Some(child),
            #[cfg(unix)]
            reaper: None,
            portable_reaper: None,
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

    #[cfg(not(unix))]
    pub(crate) fn with_reaper(mut self, reaper: ReservedPortableChildReaperLease) -> Self {
        assert!(
            self.portable_reaper.replace(reaper).is_none(),
            "spawned PTY child already has a reaper"
        );
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

    let (finished_sender, finished_receiver) = mpsc::sync_channel(1);
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
        if let Some(reaper) = self.reaper.take() {
            if let Some(session) =
                child.process_id().and_then(|pid| libc::pid_t::try_from(pid).ok())
            {
                enqueue_failed_spawn_cleanup(child, reaper, session);
                return;
            }
            drop(reaper);
        }
        let reaper = self.portable_reaper.take().or_else(|| reserve_portable_child_reaper().ok());
        if let Some(reaper) = reaper {
            enqueue_portable_child_cleanup(child, reaper);
        } else {
            retain_stranded_portable_child(child, None);
        }
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
            let attempt = self.try_waits.fetch_add(1, Ordering::AcqRel) + 1;
            Ok((attempt >= 2).then(|| portable_pty::ExitStatus::with_exit_code(1)))
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

        #[cfg(windows)]
        fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
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
        let (dropped_sender, dropped_receiver) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            drop(child);
            let _ = dropped_sender.send(());
        });

        dropped_receiver
            .recv_timeout(Duration::from_millis(250))
            .expect("spawned PTY child Drop blocked after kill failed");
        let deadline = Instant::now() + Duration::from_millis(500);
        while (try_waits.load(Ordering::Acquire) < 2
            || portable_child_reaper_active_for_test() != 0)
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(try_waits.load(Ordering::Acquire) >= 2, "cleanup owner did not retry the child");
        assert_eq!(
            portable_child_reaper_active_for_test(),
            0,
            "cleanup owner retained its reservation after the child exited"
        );
        assert!(!wait_called.load(Ordering::Acquire), "cleanup owner called blocking child wait");
    }
}
