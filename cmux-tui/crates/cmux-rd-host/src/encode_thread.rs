//! A session's encode thread (`cmux-rd-encode`): capture and encode run here, so the session's
//! loop thread (stream.rs) keeps reading the viewer's datagrams and injecting input while a
//! frame encodes (a 4K encode takes 4-10 ms). The loop thread keeps everything else: the
//! engine's gate, packetizing, sending, and input.
//!
//! Bound and back-pressure: one frame at a time. The loop hands the thread a request only while
//! it is idle (one slot each way); a request the engine releases meanwhile waits in
//! [`EncodeThread::submit`]'s queue, and the session holds new damage back until the thread is
//! idle, so the next frame captures the newest picture (latest wins) instead of a backlog.

use crate::clock::now_ns;
use crate::desktop::FrameSource;
use crate::Res;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_engine::EncodeRequest;
use std::collections::VecDeque;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TryRecvError};
use std::sync::Arc;
use std::thread::JoinHandle;

/// One request for the encode thread.
struct Job {
    req: EncodeRequest,
    /// When the engine's gate released the request (protocol clock, µs).
    released_us: u64,
    /// Halve the encoder's bitrate before this frame's target is set (the engine dropped a
    /// frame too large to send).
    halve_first: bool,
}

/// One frame the encode thread finished.
pub struct Done {
    pub req: EncodeRequest,
    pub result: Res<Frame>,
}

/// An encoded frame and where its time went.
pub struct Frame {
    pub access_unit: Vec<u8>,
    pub idr: bool,
    /// When the capture started, on the protocol clock in µs: from here to `t_capture_us` is
    /// the frame's capture cost (Linux: the XShm readback and the I420 conversion; macOS:
    /// taking ScreenCaptureKit's newest frame).
    pub capture_start_us: u64,
    /// Why the encoder made this IDR on its own (`None` when asked for, or a delta frame).
    pub idr_cause: Option<&'static str>,
    /// When the capture ended, on the protocol clock in µs (the frame's timestamp).
    pub t_capture_us: u64,
    /// When the engine's gate released this frame's request, on the protocol clock in µs.
    pub released_us: u64,
    /// When the encoder was handed the picture, on the protocol clock in µs.
    pub encode_start_us: u64,
    /// When the encode ended (the bitstream was ready), on the protocol clock in µs.
    pub encoded_us: u64,
    /// The source's display and arrival times of the picture (measurement only).
    pub picked_times: Option<(u64, u64)>,
    pub encode_ms: f64,
    /// The encoder's bitrate after this frame.
    pub kbps: u32,
    pub ltr_token: Option<u64>,
    /// The profile this frame was encoded with, when the encoder applies one (None when it has
    /// no ultra mode and kept its settings).
    pub profile: Option<EncodeProfile>,
}

/// A nonblocking pipe: the encode thread writes a byte after each finished frame, so the loop
/// thread's poll(2) wakes for it.
struct Wake {
    read: OwnedFd,
    write: OwnedFd,
}

impl Wake {
    fn new() -> Res<Self> {
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: pipe fills two descriptors into the array we own.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: both descriptors are new and owned only here.
        let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        for fd in [fds[0], fds[1]] {
            // SAFETY: fcntl on descriptors we own.
            unsafe {
                let fl = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        Ok(Self { read, write })
    }

    fn signal(&self) {
        let one = 1u8;
        // SAFETY: writes one byte from a live local; a full pipe already wakes the reader.
        unsafe { libc::write(self.write.as_raw_fd(), (&one as *const u8).cast(), 1) };
    }

    fn clear(&self) {
        let mut scratch = [0u8; 64];
        // SAFETY: reads into a local buffer from our nonblocking read end.
        while unsafe { libc::read(self.read.as_raw_fd(), scratch.as_mut_ptr().cast(), 64) } > 0 {}
    }
}

pub struct EncodeThread {
    jobs: Option<SyncSender<Job>>,
    done: Receiver<Done>,
    wake: Arc<Wake>,
    thread: Option<JoinHandle<()>>,
    /// The thread has a job.
    busy: bool,
    /// Requests the engine released while the thread was busy, oldest first.
    queue: VecDeque<(EncodeRequest, u64)>,
    halve_next: bool,
    name: String,
    kbps: u32,
}

impl EncodeThread {
    pub fn spawn(mut source: Box<dyn FrameSource>) -> Res<Self> {
        let name = source.encoder_name();
        let kbps = source.kbps();
        let wake = Arc::new(Wake::new()?);
        let (jobs_tx, jobs_rx) = sync_channel::<Job>(1);
        let (done_tx, done_rx) = sync_channel::<Done>(1);
        let thread_wake = wake.clone();
        let thread =
            std::thread::Builder::new().name("cmux-rd-encode".into()).spawn(move || {
                while let Ok(job) = jobs_rx.recv() {
                    let result = encode_one(&mut *source, &job);
                    if done_tx.send(Done { req: job.req, result }).is_err() {
                        break;
                    }
                    thread_wake.signal();
                }
            })?;
        Ok(Self {
            jobs: Some(jobs_tx),
            done: done_rx,
            wake,
            thread: Some(thread),
            busy: false,
            queue: VecDeque::new(),
            halve_next: false,
            name,
            kbps,
        })
    }

    /// Readable when a finished frame waits in [`EncodeThread::take_done`].
    pub fn fd(&self) -> RawFd {
        self.wake.read.as_raw_fd()
    }

    pub fn encoder_name(&self) -> String {
        self.name.clone()
    }

    /// The encoder's bitrate after its last frame.
    pub fn kbps(&self) -> u32 {
        self.kbps
    }

    /// No frame encodes and none waits.
    pub fn is_idle(&self) -> bool {
        !self.busy && self.queue.is_empty()
    }

    /// Encodes `req` after the frames already handed over; never waits.
    pub fn submit(&mut self, req: EncodeRequest) {
        self.queue.push_back((req, now_ns() / 1000));
        self.start_next();
    }

    /// The next frame's encoder starts at half its current bitrate.
    pub fn halve_bitrate(&mut self) {
        self.halve_next = true;
    }

    /// The finished frame, if one is ready; never waits. Starts the next queued request.
    pub fn take_done(&mut self) -> Result<Option<Done>, String> {
        self.wake.clear();
        match self.done.try_recv() {
            Ok(done) => {
                self.busy = false;
                if let Ok(frame) = &done.result {
                    self.kbps = frame.kbps;
                }
                self.start_next();
                Ok(Some(done))
            }
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err("the encode thread ended".into()),
        }
    }

    fn start_next(&mut self) {
        if self.busy {
            return;
        }
        let Some((req, released_us)) = self.queue.pop_front() else { return };
        let job = Job { req, released_us, halve_first: std::mem::take(&mut self.halve_next) };
        // The thread has no job (busy is false), so the one slot is free: this never waits.
        // A send error means the thread ended; take_done reports it.
        if let Some(jobs) = &self.jobs {
            if jobs.send(job).is_ok() {
                self.busy = true;
            }
        }
    }
}

impl Drop for EncodeThread {
    /// Ends the thread after its current frame (at most one encode) and waits for it, so the
    /// encoder and capture handle are released with the session.
    fn drop(&mut self) {
        self.jobs.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The bitrate this frame encodes at: the engine's target, at most half the encoder's
/// current rate after the engine dropped a frame too large to send (the halve used to be
/// set and then overwritten by the target on the next line, so the retry was as large).
fn frame_kbps(job: &Job, current_kbps: u32) -> u32 {
    if job.halve_first {
        job.req.target_kbps.min(current_kbps / 2)
    } else {
        job.req.target_kbps
    }
}

fn encode_one(source: &mut dyn FrameSource, job: &Job) -> Res<Frame> {
    let req = &job.req;
    source.set_picture(req.picture);
    let capture_start_us = now_ns() / 1000;
    source.capture(req.damage)?;
    source.set_acknowledged_ltr_tokens(&req.acknowledged_ltr_tokens);
    source.set_force_ltr_refresh(req.force_ltr_refresh);
    let t_capture_us = now_ns() / 1000;
    source.set_profile(req.profile, req.refine);
    source.set_changed_pixels(u64::from(req.damage.width) * u64::from(req.damage.height));
    source.set_bitrate(frame_kbps(job, source.kbps()));
    let t0 = now_ns();
    let mut access_unit = Vec::new();
    let idr = source.encode(req.force_idr, t_capture_us as i64, &mut access_unit)?;
    let t1 = now_ns();
    Ok(Frame {
        access_unit,
        idr,
        capture_start_us,
        idr_cause: if idr { source.idr_cause() } else { None },
        t_capture_us,
        released_us: job.released_us,
        encode_start_us: t0 / 1000,
        encoded_us: t1 / 1000,
        picked_times: source.picked_times(),
        encode_ms: (t1 - t0) as f64 / 1e6,
        kbps: source.kbps(),
        ltr_token: source.ltr_token(),
        profile: source.applies_profile().then_some(req.profile),
    })
}

#[cfg(test)]
#[path = "encode_thread_tests.rs"]
mod tests;
