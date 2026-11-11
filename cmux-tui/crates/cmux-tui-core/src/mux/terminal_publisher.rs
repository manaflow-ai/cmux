//! The terminal publisher: one thread per mux makes the durable commits a
//! terminal's output asks for, so the terminal's output reader never waits
//! for the workspace registry (#35413, L6 typing echo stall).
//!
//! A terminal's output reader applies the host's (or the PTY's) output to the
//! daemon's terminal and hands it to the attached views. The same output can
//! change durable facts: the shell's directory (OSC 7), a program status
//! record's state (OSC 7501) and the command and prompt facts. (The OSC 9;4
//! progress and "last output", pushed at most every 5 s while the terminal
//! prints, are live facts with no commit: `terminal_live.rs`.) Each is a resource commit under the workspace
//! registry lock, and so is a notification the output posts (OSC 9, 777, 99)
//! or a bell's attention mark. The reader made them itself, between two
//! output frames. Under load the registry lock waits up to 1.5 s, and the next
//! frame, the echo of a key the person typed, waited in the reader's queue:
//! in the s17d diagnostic rounds every echo gap over 20 ms (16, to 501 ms)
//! began inside one of those commits, with the input lane on and off.
//!
//! The reader now only checks, in memory, whether a publication is due, and
//! queues it here. The publisher runs the queue in order on its own thread. A
//! terminal has at most one publication queued: changes that arrive while it
//! waits are published with it, as the latest state, which is what every
//! publication commits. The reader still takes and rate-limits the
//! notifications itself (OSC 9, 777 and 99, OSC 7501 alerts, bell marks), at
//! the output that asked for them; they queue one by one, in output order,
//! each after the publication of the records it names. Adoption, the first
//! view of an app terminal, a terminal read (`terminal.get`) and the topology
//! commits still publish directly on their own threads. When a terminal's
//! output ends (an exit, a lost host, a closed PTY), its reader or the exit
//! takes the terminal's queued jobs back and runs them itself, in order,
//! before the terminal leaves Running (`Mux::settle_terminal_publications`):
//! an ended terminal commits no publication, and a notification posted after
//! its tab closed names no terminal.
//!
//! The queue is unbounded, but bounded in practice: one publication per
//! terminal, and a terminal's notifications are rate-limited (at most one a
//! second, a bell mark one per 10 s).

use std::io::Write as _;

use super::*;
use crate::terminal_metadata::TerminalNotification;

/// The publisher's queue and its one worker thread.
#[derive(Default)]
pub(crate) struct TerminalPublisher {
    shared: Arc<PublisherShared>,
}

#[derive(Default)]
struct PublisherShared {
    queue: Mutex<PublisherQueue>,
    /// Wakes the worker (a job, or the close), a finish waiting for it, and a
    /// settle waiting for the worker's job of its terminal.
    changed: Condvar,
}

#[derive(Default)]
struct PublisherQueue {
    jobs: VecDeque<PublisherJob>,
    /// The worker thread, while one runs. It waits on `changed` for jobs.
    worker: Option<std::thread::ThreadId>,
    /// The worker runs a job it took off `jobs`.
    busy: bool,
    /// The terminal runtime (its id) of the job the worker runs now, if it runs
    /// one: a reader whose stream ended waits for it (`settle`). An id, not the
    /// surface: the worker clears it under the queue lock, and dropping the last
    /// reference to a surface there would run its teardown under that lock.
    running: Option<SurfaceId>,
    /// The terminal readers stopped (shutdown or drop): no new job is
    /// queued. The worker still runs the jobs queued before, then exits.
    closed: bool,
    /// Test seam: the worker takes no job while a test holds the publisher.
    #[cfg(test)]
    held: bool,
}

enum PublisherJob {
    /// The terminal's pending directory, progress, activity and program
    /// status (`Surface::publish_pending_directory`, `publish_pending_state`).
    Publish(Arc<Surface>),
    /// The notifications its output asked for (OSC 9, OSC 777, OSC 99, and
    /// the alerts of its OSC 7501 records).
    Notify(SurfaceId, Vec<TerminalNotification>),
    /// The attention mark of a bell.
    Bell(SurfaceId),
}

impl PublisherJob {
    /// Whether this is the queued publication of `surface`'s terminal (any
    /// view of it: they share one runtime, and its publications).
    fn publishes(&self, surface: &Surface) -> bool {
        matches!(self, Self::Publish(queued) if queued.shares_terminal_runtime(surface))
    }

    /// The terminal runtime this job is for (its id): the reader queues a
    /// terminal's notifications and bell marks under its runtime's surface id.
    fn runtime(&self) -> Option<SurfaceId> {
        match self {
            Self::Publish(surface) => surface.terminal_runtime_id(),
            Self::Notify(surface, _) | Self::Bell(surface) => Some(*surface),
        }
    }

    fn run(self, mux: &Weak<Mux>) {
        match self {
            Self::Publish(surface) => {
                surface.publish_pending_directory();
                surface.publish_pending_state();
            }
            other => {
                if let Some(mux) = mux.upgrade() {
                    other.post(&mux);
                }
            }
        }
    }

    /// A notification's or a bell mark's post; nothing for a publication.
    fn post(self, mux: &Mux) {
        match self {
            Self::Publish(_) => {}
            Self::Notify(surface, notifications) => {
                mux.post_terminal_notifications(surface, notifications);
            }
            Self::Bell(surface) => mux.post_bell_notification(surface),
        }
    }
}

impl TerminalPublisher {
    fn push(&self, mux: &Arc<Mux>, job: PublisherJob) {
        let mut queue = self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        if queue.closed {
            return;
        }
        if let PublisherJob::Publish(surface) = &job
            && queue.jobs.iter().any(|queued| queued.publishes(surface))
        {
            return;
        }
        queue.jobs.push_back(job);
        if queue.worker.is_some() {
            self.shared.changed.notify_all();
            return;
        }
        let shared = self.shared.clone();
        let weak = Arc::downgrade(mux);
        match std::thread::Builder::new()
            .name("terminal-publisher".into())
            .spawn(move || PublisherShared::run(&shared, &weak))
        {
            Ok(worker) => queue.worker = Some(worker.thread().id()),
            Err(error) => {
                // No thread: publish here, as the reader did before.
                // Not eprintln: a failed stderr write must not end this reader.
                let _ = writeln!(
                    std::io::stderr(),
                    "cmux-tui: terminal publisher did not start: {error}"
                );
                let jobs = std::mem::take(&mut queue.jobs);
                drop(queue);
                let weak = Arc::downgrade(mux);
                for job in jobs {
                    job.run(&weak);
                }
            }
        }
    }

    /// Close the queue, then wait (until `deadline`) for the worker to finish
    /// the jobs already queued. Called after the terminal readers stopped, so
    /// their publications commit before the journal stops, as when the
    /// readers made them. On the worker itself (its job dropped the last mux
    /// reference) it only closes.
    fn finish(&self, deadline: Instant) {
        let mut queue = self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.closed = true;
        self.shared.changed.notify_all();
        if queue.worker == Some(std::thread::current().id()) {
            return;
        }
        while queue.worker.is_some() && (queue.busy || !queue.jobs.is_empty()) {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { return };
            queue = self
                .shared
                .changed
                .wait_timeout(queue, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl TerminalPublisher {
    /// Take every job of `surface`'s terminal off the queue (its publication,
    /// notifications and bell marks, in queue order), and wait while the worker
    /// runs one of them, so the caller runs them itself, in order. On the worker
    /// itself it only takes the queued ones. The jobs are returned, not dropped
    /// here: they hold surfaces, which must not be dropped under the queue lock.
    fn settle(&self, surface: &Surface) -> Vec<PublisherJob> {
        let Some(runtime) = surface.terminal_runtime_id() else { return Vec::new() };
        let mut queue = self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let (taken, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut queue.jobs)
            .into_iter()
            .partition(|job| job.publishes(surface) || job.runtime() == Some(runtime));
        queue.jobs = kept.into();
        if queue.jobs.is_empty() {
            // A finish may wait for the queue to drain.
            self.shared.changed.notify_all();
        }
        if queue.worker != Some(std::thread::current().id()) {
            while queue.running == Some(runtime) {
                queue = self.shared.changed.wait(queue).unwrap_or_else(PoisonError::into_inner);
            }
        }
        drop(queue);
        taken
    }
}

impl Drop for TerminalPublisher {
    fn drop(&mut self) {
        let mut queue = self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.closed = true;
        self.shared.changed.notify_all();
    }
}

impl PublisherShared {
    /// The worker: run jobs in order until the queue is closed and empty.
    fn run(&self, mux: &Weak<Mux>) {
        loop {
            let job = {
                let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
                loop {
                    #[cfg(test)]
                    let held = queue.held && !queue.closed;
                    #[cfg(not(test))]
                    let held = false;
                    if !held && let Some(job) = queue.jobs.pop_front() {
                        queue.busy = true;
                        queue.running = job.runtime();
                        break job;
                    }
                    if queue.closed {
                        queue.worker = None;
                        self.changed.notify_all();
                        return;
                    }
                    queue = self.changed.wait(queue).unwrap_or_else(PoisonError::into_inner);
                }
            };
            // A panicking publication must not stop the publications after it,
            // nor may its report (not eprintln, which panics when stderr fails).
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| job.run(mux))).is_err() {
                let _ = writeln!(std::io::stderr(), "cmux-tui: a terminal publication panicked");
            }
            let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
            queue.busy = false;
            // A settle waits for this terminal's job, a finish for the queue to
            // drain.
            if queue.running.take().is_some() || queue.jobs.is_empty() {
                self.changed.notify_all();
            }
        }
    }
}

impl Mux {
    /// Queue `surface`'s pending publication (its reader found one due). A
    /// publication already queued for it publishes this change too.
    pub(crate) fn queue_terminal_publication(self: &Arc<Self>, surface: &Arc<Surface>) {
        self.terminal_publisher.push(self, PublisherJob::Publish(surface.clone()));
    }

    /// Queue the notifications `surface`'s output asked for, after the
    /// publications its earlier output queued.
    pub(crate) fn queue_terminal_notifications(
        self: &Arc<Self>,
        surface: SurfaceId,
        notifications: Vec<TerminalNotification>,
    ) {
        if !notifications.is_empty() {
            self.terminal_publisher.push(self, PublisherJob::Notify(surface, notifications));
        }
    }

    /// Queue the attention mark of a bell in `surface`'s terminal.
    pub(crate) fn queue_bell_notification(self: &Arc<Self>, surface: SurfaceId) {
        self.terminal_publisher.push(self, PublisherJob::Bell(surface));
    }

    /// `surface`'s output ended (its host exited or was lost, or its PTY
    /// closed): commit its pending directory, progress, activity and program
    /// status now, on this thread, before its lifecycle leaves Running, then
    /// post the notifications and bell marks its output queued, in order. An
    /// ended or adopting terminal commits no publication, so one still queued
    /// for the publisher would be lost (`cd x; exit`, or a host lost just
    /// after a report, kept the old directory on the tab, its exit record and
    /// its respawn), and a notification posted after the exit removed the tab
    /// names no terminal. The output reader published and posted inline
    /// before it read the end of its stream; this keeps that order. No output
    /// frame waits behind it: the stream has ended.
    pub(crate) fn settle_terminal_publications(&self, surface: &Arc<Surface>) {
        let jobs = self.terminal_publisher.settle(surface);
        self.forget_terminal_tail(surface);
        surface.publish_pending_directory();
        surface.publish_pending_state();
        // The latest state is published above: a queued publication of the
        // terminal is part of it. Its notifications follow, in queue order.
        for job in jobs {
            job.post(self);
        }
    }

    /// After the terminal readers stopped: let what they queued commit (until
    /// `deadline`), then take no more.
    pub(super) fn finish_terminal_publications(&self, deadline: Instant) {
        self.terminal_publisher.finish(deadline);
    }
}

/// Releases a held publisher when dropped (`Mux::hold_terminal_publisher_for_test`).
#[cfg(test)]
pub(crate) struct TerminalPublisherHold<'a>(&'a TerminalPublisher);

#[cfg(test)]
impl Drop for TerminalPublisherHold<'_> {
    fn drop(&mut self) {
        self.0.shared.queue.lock().unwrap_or_else(PoisonError::into_inner).held = false;
        self.0.shared.changed.notify_all();
    }
}

#[cfg(test)]
impl Mux {
    /// The publisher takes no job until the returned hold drops: what readers queue meanwhile waits.
    pub(crate) fn hold_terminal_publisher_for_test(&self) -> TerminalPublisherHold<'_> {
        self.terminal_publisher.shared.queue.lock().unwrap_or_else(PoisonError::into_inner).held =
            true;
        TerminalPublisherHold(&self.terminal_publisher)
    }

    /// Waits (at most `timeout`) until the publisher ran every job queued so far. False on the timeout.
    pub(crate) fn wait_for_terminal_publisher_for_test(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let shared = &self.terminal_publisher.shared;
        let mut queue = shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        while queue.busy || !queue.jobs.is_empty() {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { return false };
            queue =
                shared.changed.wait_timeout(queue, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        true
    }
}
