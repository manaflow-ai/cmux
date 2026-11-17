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
use cmux_rd_engine::EncodeRequest;
use std::collections::VecDeque;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TryRecvError};
use std::sync::Arc;
use std::thread::JoinHandle;

/// One request for the encode thread.
struct Job {
    req: EncodeRequest,
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
    /// When the capture ended, on the protocol clock in µs (the frame's timestamp).
    pub t_capture_us: u64,
    /// When the encode ended, on the protocol clock in µs.
    pub encoded_us: u64,
    /// The source's display and arrival times of the picture (measurement only).
    pub picked_times: Option<(u64, u64)>,
    pub encode_ms: f64,
    /// The encoder's bitrate after this frame.
    pub kbps: u32,
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
    queue: VecDeque<EncodeRequest>,
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
        self.queue.push_back(req);
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
        let Some(req) = self.queue.pop_front() else { return };
        let job = Job { req, halve_first: std::mem::take(&mut self.halve_next) };
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
    source.capture(req.damage)?;
    let t_capture_us = now_ns() / 1000;
    source.set_bitrate(frame_kbps(job, source.kbps()));
    let t0 = now_ns();
    let mut access_unit = Vec::new();
    let idr = source.encode(req.force_idr, t_capture_us as i64, &mut access_unit)?;
    let t1 = now_ns();
    eprintln!(
        "DIAG enc us={} target={} kbps={} force={} idr={} bytes={} enc_ms={:.1} cam={}",
        t1 / 1000,
        req.target_kbps,
        source.kbps(),
        req.force_idr,
        idr,
        access_unit.len(),
        (t1 - t0) as f64 / 1e6,
        source.encoder_name().contains("camera")
    ); // DIAG
    Ok(Frame {
        access_unit,
        idr,
        t_capture_us,
        encoded_us: t1 / 1000,
        picked_times: source.picked_times(),
        encode_ms: (t1 - t0) as f64 / 1e6,
        kbps: source.kbps(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::flow::Rect;

    /// Records every bitrate it is given.
    struct Recorder {
        kbps: u32,
        set: Vec<u32>,
    }

    impl FrameSource for Recorder {
        fn capture(&mut self, _damage: Rect) -> Res<()> {
            Ok(())
        }
        fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
            out.extend_from_slice(&[0, 0, 0, 1, 0x65]);
            Ok(true)
        }
        fn set_bitrate(&mut self, kbps: u32) {
            self.kbps = kbps;
            self.set.push(kbps);
        }
        fn kbps(&self) -> u32 {
            self.kbps
        }
        fn encoder_name(&self) -> String {
            "recorder".into()
        }
    }

    fn job(target_kbps: u32, halve_first: bool) -> Job {
        let damage = Rect { x: 0, y: 0, width: 16, height: 16 };
        let req = EncodeRequest {
            stream: 0,
            frame: 1,
            damage,
            force_idr: true,
            idr_reason: None,
            target_kbps,
        };
        Job { req, halve_first }
    }

    #[test]
    fn the_frame_after_a_drop_encodes_at_half_the_rate() {
        let mut source = Recorder { kbps: 8_000, set: Vec::new() };
        let frame = encode_one(&mut source, &job(8_000, true)).expect("encode");
        assert_eq!(frame.kbps, 4_000, "the halve holds for this frame: {:?}", source.set);
        assert_eq!(source.set.last(), Some(&4_000));
        // A target already under half wins.
        let mut source = Recorder { kbps: 8_000, set: Vec::new() };
        encode_one(&mut source, &job(3_000, true)).expect("encode");
        assert_eq!(source.kbps, 3_000);
        // Without a drop the engine's target applies.
        let mut source = Recorder { kbps: 8_000, set: Vec::new() };
        encode_one(&mut source, &job(9_000, false)).expect("encode");
        assert_eq!(source.kbps, 9_000);
    }
}
