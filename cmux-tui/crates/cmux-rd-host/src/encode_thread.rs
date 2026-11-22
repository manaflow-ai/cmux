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
        profile: source.applies_profile().then_some(req.profile),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::flow::Rect;
    use cmux_rd_core::resolution::Picture;

    /// Records every bitrate it is given, and the picture each capture was made for.
    struct Recorder {
        kbps: u32,
        set: Vec<u32>,
        picture: Option<Picture>,
        captured_for: Vec<Option<Picture>>,
    }

    impl Recorder {
        fn new(kbps: u32) -> Self {
            Self { kbps, set: Vec::new(), picture: None, captured_for: Vec::new() }
        }
    }

    impl FrameSource for Recorder {
        fn capture(&mut self, _damage: Rect) -> Res<()> {
            self.captured_for.push(self.picture);
            Ok(())
        }
        fn set_picture(&mut self, picture: Option<Picture>) {
            self.picture = picture;
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
            picture: None,
            profile: Default::default(),
            refine: false,
        };
        Job { req, released_us: 0, halve_first }
    }

    #[test]
    fn the_frame_after_a_drop_encodes_at_half_the_rate() {
        let mut source = Recorder::new(8_000);
        let frame = encode_one(&mut source, &job(8_000, true)).expect("encode");
        assert_eq!(frame.kbps, 4_000, "the halve holds for this frame: {:?}", source.set);
        assert_eq!(source.set.last(), Some(&4_000));
        // A target already under half wins.
        let mut source = Recorder::new(8_000);
        encode_one(&mut source, &job(3_000, true)).expect("encode");
        assert_eq!(source.kbps, 3_000);
        // Without a drop the engine's target applies.
        let mut source = Recorder::new(8_000);
        encode_one(&mut source, &job(9_000, false)).expect("encode");
        assert_eq!(source.kbps, 9_000);
    }

    #[test]
    fn the_ladders_picture_reaches_the_source_before_its_capture() {
        let picture = Picture { width: 960, height: 540, eighths: 4, fps: 60, max_qp: Some(40) };
        let mut source = Recorder::new(8_000);
        let mut scaled = job(2_000, false);
        scaled.req.picture = Some(picture);
        encode_one(&mut source, &scaled).expect("encode");
        // Without a ladder the next frame is the full stream again.
        encode_one(&mut source, &job(2_000, false)).expect("encode");
        assert_eq!(source.captured_for, vec![Some(picture), None]);
    }

    /// Takes `ms` to capture, as an XShm readback and conversion of a large rect does.
    struct SlowCapture {
        ms: u64,
    }

    impl FrameSource for SlowCapture {
        fn capture(&mut self, _damage: Rect) -> Res<()> {
            std::thread::sleep(std::time::Duration::from_millis(self.ms));
            Ok(())
        }
        fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
            out.extend_from_slice(&[0, 0, 0, 1, 0x65]);
            Ok(true)
        }
        fn set_bitrate(&mut self, _kbps: u32) {}
        fn kbps(&self) -> u32 {
            1_000
        }
        fn encoder_name(&self) -> String {
            "slow-capture".into()
        }
    }

    /// The capture's own time is on the frame, from its start to `t_capture_us`.
    #[test]
    fn a_frame_carries_when_its_capture_started() {
        let mut source = SlowCapture { ms: 5 };
        let frame = encode_one(&mut source, &job(1_000, false)).expect("encode");
        let capture_us = frame.t_capture_us - frame.capture_start_us;
        assert!(capture_us >= 5_000, "capture took 5 ms, the frame says {capture_us} us");
        assert!(frame.t_capture_us <= frame.encoded_us);
    }

    /// The stats line names only a profile the encoder applied: one without an ultra mode
    /// (the Linux X11 source) reports none even for an ultra request.
    #[test]
    fn a_frame_names_only_the_profile_its_encoder_applied() {
        struct Ultra(Recorder);
        impl FrameSource for Ultra {
            fn capture(&mut self, damage: Rect) -> Res<()> {
                self.0.capture(damage)
            }
            fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
                self.0.encode(force_idr, pts_us, out)
            }
            fn set_bitrate(&mut self, kbps: u32) {
                self.0.set_bitrate(kbps);
            }
            fn applies_profile(&self) -> bool {
                true
            }
            fn kbps(&self) -> u32 {
                self.0.kbps()
            }
            fn encoder_name(&self) -> String {
                "ultra".into()
            }
        }
        let mut ultra_job = job(8_000, false);
        ultra_job.req.profile = EncodeProfile::Ultra;
        let mut plain = Recorder { kbps: 8_000, set: Vec::new() };
        assert_eq!(encode_one(&mut plain, &ultra_job).expect("encode").profile, None);
        let mut able = Ultra(Recorder { kbps: 8_000, set: Vec::new() });
        assert_eq!(
            encode_one(&mut able, &ultra_job).expect("encode").profile,
            Some(EncodeProfile::Ultra)
        );
    }
}
