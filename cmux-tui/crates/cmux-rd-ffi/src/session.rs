//! The viewer side of one `cmux.rd/1` session with several display streams
//! (rd change C6, plans/cmux-next/remote-tab-protocol.md section 7): every
//! video or parity datagram goes to the reassembler of the stream its header
//! names, so streams with the same frame numbers never mix; feedback and
//! keyframe requests are per stream. Only streams the caller opened are
//! accepted (stream 0 is open from the start); other datagrams are queued as
//! messages for the caller. The C ABI in `session_ffi.rs` is a thin shell.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_core::clock::ClockEstimator;
use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_proto::{
    ClockEstimate, ClockPong, DatagramHeader, DatagramKind, LocalCounters, LocalFrame, LocalReport,
    REF_NONE, STREAM_BULK, STREAM_CONTROL, STREAM_DATAGRAM, STREAM_LOCAL_FRAME,
    STREAM_LOCAL_REPORT, StreamDeframer, encode_stream_frame, flags,
};

use crate::receiver::{
    Carrier, MAX_MESSAGE_BYTES, MESSAGE_OVERHEAD, Message, Receiver, ReceiverError, Stats,
};

/// Most open streams per session (main surface, popups, tiles).
pub const MAX_STREAMS: usize = 16;
/// Whole frames of an upstream-assembled stream held for the caller. The connect process
/// sends the next frame only after the caller consumed the last, so more than one here
/// means it ran ahead: the oldest is dropped and counted, never queued without bound.
pub const MAX_LOCAL_READY: usize = 2;
/// Reports held for the connect process; the oldest go when the caller outruns it.
pub const MAX_LOCAL_REPORTS: usize = 64;

/// A stream the viewer's connect process reassembles (design D7, screen-share-under-100ms):
/// its frames arrive whole ([`LocalFrame`]) and its feedback is the connect process's.
#[derive(Debug, Default)]
struct LocalStream {
    frames: VecDeque<LocalFrame>,
    counters: LocalCounters,
    /// Frames dropped here because the caller fell behind (added to `frames_lost`).
    dropped: u64,
}

/// Why a session call was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionError {
    /// The bytes or the call failed in the stream's receiver.
    Receiver(ReceiverError),
    /// The stream is not open, or opening it would pass [`MAX_STREAMS`].
    Stream(u16),
}

impl From<ReceiverError> for SessionError {
    fn from(e: ReceiverError) -> Self {
        Self::Receiver(e)
    }
}

/// Viewer state for all streams of one session.
#[derive(Debug)]
pub struct Session {
    carrier: Carrier,
    deadline_us: u64,
    nack_after_us: u64,
    /// One datagram-mode receiver per open stream; the session does the
    /// stream carrier's framing itself.
    streams: BTreeMap<u16, Receiver>,
    deframer: StreamDeframer,
    messages: VecDeque<Message>,
    message_bytes: usize,
    /// Streams of ready frames in release order (one entry per frame).
    ready: VecDeque<u16>,
    /// The session clock (rd change C8), once the host accepted the `clock` cap.
    clock: Option<ClockEstimator>,
    /// Streams the connect process reassembles ([`Self::assemble_upstream`]).
    local: BTreeMap<u16, LocalStream>,
    /// Reports for the connect process, sent through [`Self::feedback`].
    local_reports: VecDeque<LocalReport>,
    /// When the connect process released the frame [`Self::pop_frame`] returned last
    /// (`CLOCK_UPTIME_RAW` microseconds), or `None` for a frame reassembled here.
    last_release_us: Option<u64>,
    failed: bool,
}

impl Session {
    /// A session with stream 0 open.
    pub fn new(carrier: Carrier, deadline_us: u64, nack_after_us: u64) -> Self {
        let mut s = Self {
            carrier,
            deadline_us,
            nack_after_us,
            streams: BTreeMap::new(),
            deframer: StreamDeframer::default(),
            messages: VecDeque::new(),
            message_bytes: 0,
            ready: VecDeque::new(),
            clock: None,
            local: BTreeMap::new(),
            local_reports: VecDeque::new(),
            last_release_us: None,
            failed: false,
        };
        let _ = s.open_stream(0);
        s
    }

    /// `stream` is reassembled by the viewer's connect process (stream carrier only): its
    /// frames arrive whole on the stream, this session sends no feedback for it, and
    /// [`Self::note_consumed`], [`Self::note_presented`] and [`Self::request_keyframe`]
    /// go to the connect process instead. Call before the connect process starts
    /// sending (the app asks for it in its answer line). Idempotent.
    pub fn assemble_upstream(&mut self, stream: u16) -> Result<(), SessionError> {
        if self.carrier != Carrier::Stream {
            return Err(ReceiverError::Carrier.into());
        }
        self.open_stream(stream)?;
        self.deframer.accept_local();
        self.local.entry(stream).or_default();
        Ok(())
    }

    /// When the connect process released the frame [`Self::pop_frame`] returned last.
    pub fn last_release_us(&self) -> Option<u64> {
        self.last_release_us
    }

    /// The caller is done with `frame` of `stream` (decoded in `decode_us`, or 0 when it
    /// was skipped). An upstream-assembled stream's connect process sends its next frame
    /// on this; any other stream records the decode time for its feedback.
    pub fn note_consumed(
        &mut self,
        stream: u16,
        frame: u32,
        decode_us: u32,
    ) -> Result<(), SessionError> {
        if self.local.contains_key(&stream) {
            self.report(LocalReport::Consumed { stream, frame, decode_us });
            return Ok(());
        }
        if decode_us > 0 {
            self.receiver(stream)?.note_decode(decode_us);
        }
        Ok(())
    }

    /// `frame` of `stream` reached the glass at `presented_us` (`CLOCK_UPTIME_RAW`
    /// microseconds). Goes to the connect process of an upstream-assembled stream.
    pub fn note_presented(
        &mut self,
        stream: u16,
        frame: u32,
        presented_us: u64,
    ) -> Result<(), SessionError> {
        if self.local.contains_key(&stream) {
            self.report(LocalReport::Presented { stream, frame, presented_us });
            return Ok(());
        }
        self.receiver(stream).map(|_| ())
    }

    fn report(&mut self, report: LocalReport) {
        if self.local_reports.len() >= MAX_LOCAL_REPORTS {
            self.local_reports.pop_front();
        }
        self.local_reports.push_back(report);
    }

    fn on_local_frame(&mut self, payload: &[u8]) {
        // A frame that does not parse, or of a stream not assembled upstream, is skipped
        // like an invalid datagram: the reliable stream itself is fine.
        let Ok(frame) = LocalFrame::decode(payload) else { return };
        let stream = frame.stream;
        let Some(local) = self.local.get_mut(&stream) else { return };
        let resumes = frame.flags & (flags::KEYFRAME | flags::RECOVERY) != 0
            || frame.body.ref_frame == REF_NONE;
        let mut keyframe_wanted = false;
        if local.frames.len() >= MAX_LOCAL_READY {
            // The connect process ran ahead of the caller: the dropped frame breaks the
            // chain unless the new one starts a new one.
            local.frames.pop_front();
            local.dropped += 1;
            keyframe_wanted = !resumes;
            if let Some(i) = self.ready.iter().position(|s| *s == stream) {
                self.ready.remove(i);
            }
        }
        local.counters = frame.counters;
        local.counters.frames_lost = local.counters.frames_lost.saturating_add(local.dropped);
        local.frames.push_back(frame);
        self.ready.push_back(stream);
        if keyframe_wanted {
            self.report(LocalReport::KeyframeWanted { stream });
        }
    }

    /// Starts clock probes (only when welcome lists the `clock` cap: an
    /// older host refuses the probe kinds). Idempotent.
    pub fn enable_clock(&mut self) {
        self.clock.get_or_insert_with(ClockEstimator::new);
    }

    /// The host clock's offset from this viewer's and the best sample's RTT.
    pub fn clock(&self) -> Option<ClockEstimate> {
        self.clock.as_ref().and_then(ClockEstimator::estimate)
    }

    /// Accepts datagrams of `stream` from now on (idempotent).
    pub fn open_stream(&mut self, stream: u16) -> Result<(), SessionError> {
        if self.streams.contains_key(&stream) {
            return Ok(());
        }
        if self.streams.len() >= MAX_STREAMS {
            return Err(SessionError::Stream(stream));
        }
        let r =
            Receiver::for_stream(Carrier::Datagram, stream, self.deadline_us, self.nack_after_us);
        self.streams.insert(stream, r);
        Ok(())
    }

    /// Stops accepting `stream` and drops its frames and state.
    pub fn close_stream(&mut self, stream: u16) -> Result<(), SessionError> {
        self.streams.remove(&stream).ok_or(SessionError::Stream(stream))?;
        self.local.remove(&stream);
        self.local_reports.retain(|r| r.stream() != stream);
        self.ready.retain(|s| *s != stream);
        Ok(())
    }

    /// Adds one datagram (datagram carrier).
    pub fn push_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), SessionError> {
        if self.carrier != Carrier::Datagram {
            return Err(ReceiverError::Carrier.into());
        }
        self.check_alive()?;
        self.on_datagram(datagram, now_us)
    }

    /// Adds received stream bytes (stream carrier). A datagram inside the
    /// stream that is invalid or names a stream that is not open is skipped.
    pub fn push_stream(&mut self, bytes: &[u8], now_us: u64) -> Result<(), SessionError> {
        if self.carrier != Carrier::Stream {
            return Err(ReceiverError::Carrier.into());
        }
        self.check_alive()?;
        self.deframer.extend(bytes);
        loop {
            match self.deframer.next_frame() {
                Ok(None) => break,
                Ok(Some((STREAM_DATAGRAM, payload))) => {
                    // One bad datagram does not end a reliable stream.
                    let _ = self.on_datagram(&payload, now_us);
                }
                Ok(Some((STREAM_LOCAL_FRAME, payload))) => self.on_local_frame(&payload),
                // Only the app writes reports; one coming back is skipped.
                Ok(Some((STREAM_LOCAL_REPORT, _))) => {}
                Ok(Some((kind, payload))) => self.queue_message(kind, payload)?,
                Err(_) => return Err(self.fail()),
            }
            if self.failed {
                return Err(ReceiverError::StreamFailed.into());
            }
        }
        self.tick(now_us);
        Ok(())
    }

    /// Drops frames past their deadline in every stream.
    pub fn tick(&mut self, now_us: u64) {
        let ids: Vec<u16> = self.streams.keys().copied().collect();
        for id in ids {
            if let Some(r) = self.streams.get_mut(&id) {
                let before = r.ready_frames();
                r.tick(now_us);
                let after = r.ready_frames();
                self.track(id, before, after);
            }
        }
    }

    /// The oldest ready frame of any stream, with its stream.
    pub fn pop_frame(&mut self) -> Option<(u16, CompleteFrame)> {
        self.last_release_us = None;
        while let Some(stream) = self.ready.pop_front() {
            if let Some(local) = self.local.get_mut(&stream) {
                if let Some(f) = local.frames.pop_front() {
                    self.last_release_us = Some(f.release_us);
                    let frame = CompleteFrame { frame: f.frame, flags: f.flags, body: f.body };
                    return Some((stream, frame));
                }
                continue;
            }
            if let Some(frame) = self.streams.get_mut(&stream).and_then(Receiver::pop_frame) {
                return Some((stream, frame));
            }
        }
        None
    }

    /// Frames ready in all streams.
    pub fn ready_frames(&self) -> usize {
        let local: usize = self.local.values().map(|l| l.frames.len()).sum();
        self.streams.values().map(Receiver::ready_frames).sum::<usize>() + local
    }

    /// The oldest queued message (control JSON or a non-video datagram).
    pub fn pop_message(&mut self) -> Option<Message> {
        let m = self.messages.pop_front()?;
        self.message_bytes = self.message_bytes.saturating_sub(m.bytes.len() + MESSAGE_OVERHEAD);
        Some(m)
    }

    /// Records one decode time of `stream` (an upstream-assembled stream's connect process
    /// gets it from [`Self::note_consumed`], which names the frame).
    pub fn note_decode(&mut self, stream: u16, decode_us: u32) -> Result<(), SessionError> {
        self.receiver(stream)?.note_decode(decode_us);
        Ok(())
    }

    /// Asks the host for a keyframe on `stream` until one is released there (through the
    /// connect process for an upstream-assembled stream).
    pub fn request_keyframe(&mut self, stream: u16) -> Result<(), SessionError> {
        if self.local.contains_key(&stream) {
            let wanted = LocalReport::KeyframeWanted { stream };
            if !self.local_reports.contains(&wanted) {
                self.report(wanted);
            }
            return Ok(());
        }
        self.receiver(stream)?.request_keyframe();
        Ok(())
    }

    /// Counters of `stream` (the connect process's, for an upstream-assembled stream).
    pub fn stats(&self, stream: u16) -> Result<Stats, SessionError> {
        if let Some(local) = self.local.get(&stream) {
            let c = local.counters;
            return Ok(Stats {
                acked_frame: c.acked_frame,
                need_recovery: c.need_recovery,
                frames_released: c.frames_released,
                frames_lost: c.frames_lost,
            });
        }
        self.streams.get(&stream).map(Receiver::stats).ok_or(SessionError::Stream(stream))
    }

    /// The next due feedback datagram of any stream (lowest stream first),
    /// framed for the carrier. Call again until it returns `None`.
    pub fn feedback(&mut self, now_us: u64) -> Option<Vec<u8>> {
        if self.failed {
            return None;
        }
        if let Some(report) = self.local_reports.pop_front() {
            let mut out = Vec::new();
            // A report is 16 bytes, far below the stream frame limit.
            let _ = encode_stream_frame(STREAM_LOCAL_REPORT, &report.encode(), &mut out);
            return Some(out);
        }
        let ping = self.clock.as_mut().and_then(|c| c.ping(now_us)).map(|ping| {
            let mut d = DatagramHeader {
                flags: 0,
                kind: DatagramKind::ClockPing,
                stream: 0,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode()
            .to_vec();
            d.extend_from_slice(&ping.encode());
            d
        });
        // An upstream-assembled stream's feedback is the connect process's.
        let local = &self.local;
        let datagram = ping.or_else(|| {
            self.streams
                .iter_mut()
                .filter(|(id, _)| !local.contains_key(id))
                .find_map(|(_, r)| r.feedback(now_us))
        })?;
        Some(match self.carrier {
            Carrier::Datagram => datagram,
            Carrier::Stream => {
                let mut out = Vec::with_capacity(datagram.len() + 5);
                // A feedback datagram is far below the stream frame limit.
                let _ = encode_stream_frame(STREAM_DATAGRAM, &datagram, &mut out);
                out
            }
        })
    }

    /// When `tick` and `feedback` must run next: the earliest of every stream.
    pub fn next_deadline_us(&self) -> u64 {
        if self.failed {
            return u64::MAX;
        }
        if !self.local_reports.is_empty() {
            return 0;
        }
        let ping = self.clock.as_ref().map_or(u64::MAX, ClockEstimator::next_ping_us);
        self.streams
            .iter()
            .filter(|(id, _)| !self.local.contains_key(id))
            .map(|(_, r)| r.next_deadline_us())
            .min()
            .unwrap_or(u64::MAX)
            .min(ping)
    }

    fn receiver(&mut self, stream: u16) -> Result<&mut Receiver, SessionError> {
        self.streams.get_mut(&stream).ok_or(SessionError::Stream(stream))
    }

    fn check_alive(&self) -> Result<(), SessionError> {
        if self.failed { Err(ReceiverError::StreamFailed.into()) } else { Ok(()) }
    }

    fn fail(&mut self) -> SessionError {
        self.failed = true;
        ReceiverError::StreamFailed.into()
    }

    /// One entry in `ready` per frame a receiver newly released.
    fn track(&mut self, stream: u16, before: usize, after: usize) {
        for _ in before..after {
            self.ready.push_back(stream);
        }
    }

    fn on_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), SessionError> {
        let (header, _) = DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
        match header.kind {
            DatagramKind::Video | DatagramKind::Fec => {
                let r = self.receiver(header.stream)?;
                let before = r.ready_frames();
                let pushed = r.push_datagram(datagram, now_us);
                let after = r.ready_frames();
                self.track(header.stream, before, after);
                pushed.map_err(SessionError::from)
            }
            DatagramKind::ClockPong if self.clock.is_some() => {
                let (_, payload) =
                    DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
                let pong = ClockPong::decode(payload).map_err(ReceiverError::Invalid)?;
                if let Some(clock) = self.clock.as_mut() {
                    clock.on_pong(&pong, now_us);
                }
                Ok(())
            }
            _ => self.queue_message(STREAM_DATAGRAM, datagram.to_vec()),
        }
    }

    fn queue_message(&mut self, kind: u8, bytes: Vec<u8>) -> Result<(), SessionError> {
        debug_assert!(matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM | STREAM_BULK));
        let cost = bytes.len() + MESSAGE_OVERHEAD;
        if self.message_bytes + cost > MAX_MESSAGE_BYTES {
            return Err(self.fail());
        }
        self.message_bytes += cost;
        self.messages.push_back(Message { kind, bytes });
        Ok(())
    }
}
