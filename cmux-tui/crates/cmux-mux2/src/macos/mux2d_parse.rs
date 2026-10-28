//! Unwatched batches: the parse workers, their in-flight accounting, and
//! the flush that orders every parse.

use super::*;

#[derive(Default)]
pub(super) struct Inflight {
    pub(super) count: Mutex<usize>,
    pub(super) done: std::sync::Condvar,
}

impl Inflight {
    pub(super) fn wait_idle(&self) {
        let mut count = self.count.lock().expect("inflight");
        while *count > 0 {
            count = self.done.wait(count).expect("inflight");
        }
    }
}

/// One unwatched batch for a parse worker. A terminal's batches always go
/// to the same worker, so they are parsed in order.
pub(super) struct ParseJob {
    pub(super) parser: Arc<Mutex<Terminal>>,
    pub(super) inflight: Arc<Inflight>,
    pub(super) bytes: Vec<u8>,
    /// Where to post the completion (EVFILT_USER on the loop's kqueue).
    pub(super) kq: RawFd,
    pub(super) term: u32,
}

impl Term {
    /// The parser, after every batch handed to a worker is parsed.
    pub(super) fn vt(&self) -> std::sync::MutexGuard<'_, Terminal> {
        self.inflight.wait_idle();
        self.parser.lock().expect("parser")
    }
}

/// Triggers the loop's EVFILT_USER event for terminal `t`.
pub(super) fn post_wake(kq: RawFd, t: u32) {
    // SAFETY: zeroed kevent is valid; one changelist entry, no event list.
    unsafe {
        let mut ev: libc::kevent = std::mem::zeroed();
        ev.ident = t as usize;
        ev.filter = libc::EVFILT_USER;
        ev.fflags = libc::NOTE_TRIGGER;
        // A trigger also replaces the event's stored udata: pass the token
        // again, or the wake arrives addressed to nobody.
        ev.udata = (KIND_WAKE | u64::from(t)) as usize as *mut libc::c_void;
        libc::kevent(kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null());
    }
}

pub(super) fn spawn_parse_workers() -> Vec<std::sync::mpsc::Sender<ParseJob>> {
    let cores = std::thread::available_parallelism().map_or(1, usize::from);
    let n = tunable("MUX2_PARSE_WORKERS", cores.saturating_sub(1).min(8));
    (0..n)
        .map(|i| {
            let (tx, rx) = std::sync::mpsc::channel::<ParseJob>();
            // Output parsing the person waits for: UserInitiated, not the
            // closed user-interactive list (threading-model.md).
            // supervise-allow: Fatal by hand: a parse that panics aborts mux2d below, never a server whose batch waits forever.
            cmux_threads::spawn(
                format!("mux2-parse-{i}"),
                cmux_threads::ThreadQos::UserInitiated,
                move || {
                    for job in rx {
                        // A parse that panics must not leave the loop
                        // waiting forever for this batch: stop the server.
                        let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            job.parser.lock().expect("parser").vt_write(&job.bytes);
                        }));
                        if parsed.is_err() {
                            eprintln!("mux2d: parse worker panicked; aborting");
                            std::process::abort();
                        }
                        {
                            let mut count = job.inflight.count.lock().expect("inflight");
                            *count -= 1;
                            job.inflight.done.notify_all();
                        }
                        post_wake(job.kq, job.term);
                    }
                },
            )
            .expect("parse worker");
            tx
        })
        .collect()
}

/// Writes queued input until the PTY is full, without touching kqueue; the
/// caller's flush_input arms EVFILT_WRITE for whatever is left.
pub(super) fn write_input_now(term: &mut Term) {
    while !term.input.is_empty() && term.pty_open {
        let (front, _) = term.input.as_slices();
        // SAFETY: front is a valid slice.
        let n = unsafe { libc::write(term.master, front.as_ptr().cast(), front.len()) };
        if n <= 0 {
            return;
        }
        term.input.drain(..n as usize);
    }
}

/// Parses every pending byte now, after the batches already handed out.
pub(super) fn flush_parse(term: &mut Term) {
    if !term.carry.is_empty() {
        let carry = std::mem::take(&mut term.carry);
        term.pending.extend_from_slice(&carry);
    }
    if !term.pending.is_empty() {
        let pending = std::mem::take(&mut term.pending);
        let mut vt = term.vt();
        vt.vt_write(&pending);
        // A carried CSI may now be open in the parser: the next read must
        // then parse at once, or a query completed by it would wait.
        let open = !vt.vt_stream_is_ground();
        drop(vt);
        term.open_seq = open;
        term.pending = pending;
        term.pending.clear();
    }
}

/// Hands the pending batch to `worker` while the loop keeps reading; parses
/// it inline when there is no worker.
pub(super) fn offload_parse(
    term: &mut Term,
    worker: Option<&std::sync::mpsc::Sender<ParseJob>>,
    kq: RawFd,
    t: u32,
) {
    let Some(worker) = worker else {
        return flush_parse(term);
    };
    let capacity = term.pending.capacity();
    let bytes = std::mem::replace(&mut term.pending, Vec::with_capacity(capacity));
    *term.inflight.count.lock().expect("inflight") += 1;
    let job = ParseJob {
        parser: term.parser.clone(),
        inflight: term.inflight.clone(),
        bytes,
        kq,
        term: t,
    };
    if let Err(std::sync::mpsc::SendError(job)) = worker.send(job) {
        // The worker is gone: parse here, keeping the order.
        *term.inflight.count.lock().expect("inflight") -= 1;
        term.vt().vt_write(&job.bytes);
    }
}
