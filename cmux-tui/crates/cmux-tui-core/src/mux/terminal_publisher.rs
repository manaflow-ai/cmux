//! The terminal publisher: one thread per mux makes the durable commits a
//! terminal's output asks for, so the terminal's output reader never waits
//! for the workspace registry (#35413, L6 typing echo stall).
//!
//! A terminal's output reader applies the host's (or the PTY's) output to the
//! daemon's terminal and hands it to the attached views. The same output can
//! change durable facts: the shell's directory (OSC 7), the progress and
//! program status (OSC 9;4, OSC 7501), the command and prompt facts, and
//! "last output", pushed at most every 5 s while the terminal prints
//! (`terminal_activity.rs`). Each is a resource commit under the workspace
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
//! publication commits. Notifications and bell marks queue one by one, in
//! output order. Callers on other threads (adoption, a reconnect's
//! settlement, a terminal read) still publish directly.

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
    /// Wakes the worker (a job, or the close) and a finish waiting for it.
    changed: Condvar,
}

#[derive(Default)]
struct PublisherQueue {
    jobs: VecDeque<PublisherJob>,
    /// The worker thread, while one runs. It waits on `changed` for jobs.
    worker: Option<std::thread::ThreadId>,
    /// The worker runs a job it took off `jobs`.
    busy: bool,
    /// The terminal readers stopped (shutdown or drop): no job is taken.
    closed: bool,
}

enum PublisherJob {
    /// The terminal's pending directory, progress, activity and program
    /// status (`Surface::publish_pending_directory`, `publish_pending_progress`).
    Publish(Arc<Surface>),
    /// The notifications its output asked for (OSC 9, OSC 777, OSC 99).
    Notify(SurfaceId, Vec<TerminalNotification>),
    /// The attention mark of a bell.
    Bell(SurfaceId),
}

impl PublisherJob {
    /// Whether this is `surface`'s queued publication.
    fn publishes(&self, surface: &Arc<Surface>) -> bool {
        matches!(self, Self::Publish(queued) if Arc::ptr_eq(queued, surface))
    }

    fn run(self, mux: &Weak<Mux>) {
        match self {
            Self::Publish(surface) => {
                surface.publish_pending_directory();
                surface.publish_pending_progress();
            }
            Self::Notify(surface, notifications) => {
                if let Some(mux) = mux.upgrade() {
                    mux.post_terminal_notifications(surface, notifications);
                }
            }
            Self::Bell(surface) => {
                if let Some(mux) = mux.upgrade() {
                    mux.post_bell_notification(surface);
                }
            }
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
                eprintln!("cmux-tui: terminal publisher did not start: {error}");
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
                    if let Some(job) = queue.jobs.pop_front() {
                        queue.busy = true;
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
            // A panicking publication must not stop the publications after it.
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| job.run(mux))).is_err() {
                eprintln!("cmux-tui: a terminal publication panicked");
            }
            let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
            queue.busy = false;
            if queue.jobs.is_empty() {
                // A finish may wait for the queue to drain.
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

    /// After the terminal readers stopped: let what they queued commit (until
    /// `deadline`), then take no more.
    pub(super) fn finish_terminal_publications(&self, deadline: Instant) {
        self.terminal_publisher.finish(deadline);
    }
}
