//! The viewer side of one `cmux.rd/1` session with several display streams
//! (rd change C6, plans/cmux-next/remote-tab-protocol.md section 7): every
//! video or parity datagram goes to the reassembler of the stream its header
//! names, so streams with the same frame numbers never mix; feedback and
//! keyframe requests are per stream. Only streams the caller opened are
//! accepted (stream 0 is open from the start); other datagrams are queued as
//! messages for the caller. The C ABI in `session_ffi.rs` is a thin shell.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_core::clock::ClockEstimator;
use cmux_rd_core::ledger::StageLedger;
use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_proto::{
    ClockEstimate, ClockPong, DatagramHeader, DatagramKind, FrameTimes, STREAM_BULK,
    STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame,
};

use crate::receiver::{
    Carrier, MAX_MESSAGE_BYTES, MESSAGE_OVERHEAD, Message, Receiver, ReceiverError, Stats,
};

/// Most open streams per session (main surface, popups, tiles).
/// Measured: the host's bound, `cmux_rd_engine::MAX_STREAMS` (16: one encoder each, popups'
/// 300 kbps floors fill a 24 Mbps target's 20 % share), exported to the app as
/// `CMUX_RD_SESSION_MAX_STREAMS`.
pub const MAX_STREAMS: usize = 16;

/// Silence after which a session that hears heartbeats is stalled (the
/// network dropped; the picture is frozen). A live host sends a heartbeat at
/// least every 1.1 s even on a still screen: its cursor channel resends the
/// position every second (cmux-rd-host `cursor.rs` `KEEPALIVE_US`, sampled
/// every 100 ms when still) and clock pongs answer pings sent every second
/// (cmux-rd-core `clock.rs`). Frames and stats come faster while the screen
/// changes. 1.5 s is that worst cadence plus margin for path jitter.
pub const STALL_AFTER_US: u64 = 1_500_000;

/// Whether the host still talks: when bytes last arrived, and whether the
/// host sends heartbeats at all. Only a host that does (a cursor position or
/// a clock pong was heard) can be called stalled: an idle, unchanging screen
/// sends no frames and no stats, so silence alone means nothing.
#[derive(Debug, Default)]
struct Liveness {
    last_heard_us: Option<u64>,
    heartbeats: bool,
    stalled: bool,
}

impl Liveness {
    /// Bytes from the host arrived: the session is live again.
    fn heard(&mut self, now_us: u64) {
        self.last_heard_us = Some(now_us);
        self.stalled = false;
    }

    /// Notes a datagram kind a live host sends at least every second.
    fn heartbeat(&mut self, kind: DatagramKind) {
        if matches!(kind, DatagramKind::CursorPos | DatagramKind::ClockPong) {
            self.heartbeats = true;
        }
    }

    /// When the session counts as stalled if nothing more arrives; `None`
    /// without heartbeats and once the stall is reported (no wake in the past).
    fn deadline_us(&self) -> Option<u64> {
        if !self.heartbeats || self.stalled {
            return None;
        }
        self.last_heard_us.map(|t| t.saturating_add(STALL_AFTER_US))
    }

    fn tick(&mut self, now_us: u64) {
        if self.deadline_us().is_some_and(|deadline| now_us >= deadline) {
            self.stalled = true;
        }
    }
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
    /// Whether the host was heard in the last [`STALL_AFTER_US`].
    liveness: Liveness,
    /// Every frame's stage times (D8): the host's from its `FrameTimes`
    /// datagrams (cap `ledger`), this viewer's from reassembly and the
    /// caller's decode and present notes. Bounded.
    ledger: StageLedger,
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
            liveness: Liveness::default(),
            ledger: StageLedger::new(),
            failed: false,
        };
        let _ = s.open_stream(0);
        s
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

    /// The round trip from clock probes, which sizes every stream's repair wait.
    fn rtt_us(&self) -> Option<u64> {
        self.clock().map(|c| u64::from(c.rtt_us))
    }

    /// Accepts datagrams of `stream` from now on (idempotent).
    pub fn open_stream(&mut self, stream: u16) -> Result<(), SessionError> {
        if self.streams.contains_key(&stream) {
            return Ok(());
        }
        if self.streams.len() >= MAX_STREAMS {
            return Err(SessionError::Stream(stream));
        }
        let mut r =
            Receiver::for_stream(Carrier::Datagram, stream, self.deadline_us, self.nack_after_us);
        r.set_path_rtt_us(self.rtt_us());
        self.streams.insert(stream, r);
        Ok(())
    }

    /// Stops accepting `stream` and drops its frames and state.
    pub fn close_stream(&mut self, stream: u16) -> Result<(), SessionError> {
        self.streams.remove(&stream).ok_or(SessionError::Stream(stream))?;
        self.ready.retain(|s| *s != stream);
        Ok(())
    }

    /// Adds one datagram (datagram carrier).
    pub fn push_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), SessionError> {
        if self.carrier != Carrier::Datagram {
            return Err(ReceiverError::Carrier.into());
        }
        self.check_alive()?;
        self.liveness.heard(now_us);
        self.on_datagram(datagram, now_us)
    }

    /// Adds received stream bytes (stream carrier). A datagram inside the
    /// stream that is invalid or names a stream that is not open is skipped.
    pub fn push_stream(&mut self, bytes: &[u8], now_us: u64) -> Result<(), SessionError> {
        if self.carrier != Carrier::Stream {
            return Err(ReceiverError::Carrier.into());
        }
        self.check_alive()?;
        if !bytes.is_empty() {
            self.liveness.heard(now_us);
        }
        self.deframer.extend(bytes);
        loop {
            match self.deframer.next_frame() {
                Ok(None) => break,
                Ok(Some((STREAM_DATAGRAM, payload))) => {
                    // One bad datagram does not end a reliable stream.
                    let _ = self.on_datagram(&payload, now_us);
                }
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

    /// Drops frames past their deadline in every stream and notes a stall.
    pub fn tick(&mut self, now_us: u64) {
        self.liveness.tick(now_us);
        let ids: Vec<u16> = self.streams.keys().copied().collect();
        for id in ids {
            if let Some(r) = self.streams.get_mut(&id) {
                let before = r.frames_queued();
                r.tick(now_us);
                let after = r.frames_queued();
                self.track(id, before, after);
            }
        }
    }

    /// Whether the host went silent for [`STALL_AFTER_US`] (as of the last
    /// `tick`) while it sends heartbeats; cleared by the next bytes heard.
    pub fn is_stalled(&self) -> bool {
        self.liveness.stalled
    }

    /// The oldest ready frame of any stream, with its stream.
    pub fn pop_frame(&mut self) -> Option<(u16, CompleteFrame)> {
        while let Some(stream) = self.ready.pop_front() {
            if let Some(frame) = self.streams.get_mut(&stream).and_then(Receiver::pop_frame) {
                self.ledger.on_released(
                    stream,
                    frame.frame,
                    frame.last_shard_us,
                    frame.released_us,
                );
                return Some((stream, frame));
            }
        }
        None
    }

    /// Frames ready in all streams.
    pub fn ready_frames(&self) -> usize {
        self.streams.values().map(Receiver::ready_frames).sum()
    }

    /// The oldest queued message (control JSON or a non-video datagram).
    pub fn pop_message(&mut self) -> Option<Message> {
        let m = self.messages.pop_front()?;
        self.message_bytes = self.message_bytes.saturating_sub(m.bytes.len() + MESSAGE_OVERHEAD);
        Some(m)
    }

    /// Records one decode time of `stream`.
    pub fn note_decode(&mut self, stream: u16, decode_us: u32) -> Result<(), SessionError> {
        self.receiver(stream)?.note_decode(decode_us);
        Ok(())
    }

    /// Frame `frame` of `stream` finished decoding at `decoded_at_us` (the
    /// session's clock, as passed to `push_*`) after `decode_us`: feeds the
    /// feedback median and the stage ledger.
    pub fn note_decoded(
        &mut self,
        stream: u16,
        frame: u32,
        decode_us: u32,
        decoded_at_us: u64,
    ) -> Result<(), SessionError> {
        self.receiver(stream)?.note_decode(decode_us);
        self.ledger.on_decoded(stream, frame, decoded_at_us);
        Ok(())
    }

    /// Frame `frame` of `stream` reached the glass at `presented_at_us` (the
    /// session's clock: the drawable's presented time).
    pub fn note_presented(
        &mut self,
        stream: u16,
        frame: u32,
        presented_at_us: u64,
    ) -> Result<(), SessionError> {
        self.receiver(stream)?;
        self.ledger.on_presented(stream, frame, presented_at_us);
        Ok(())
    }

    /// The stage ledger of the frames kept so far, as one JSON object
    /// (`cmux.rd-stage-ledger/1`), on the host's clock.
    pub fn stage_ledger_json(&self) -> String {
        let offset = self.clock().map(|c| c.offset_us);
        self.ledger.summary(offset, &[]).to_json()
    }

    /// Asks the host for a keyframe on `stream` until one is released there.
    pub fn request_keyframe(&mut self, stream: u16) -> Result<(), SessionError> {
        self.receiver(stream)?.request_keyframe();
        Ok(())
    }

    /// How long `stream` waits for a NACKed frame before asking for recovery.
    pub fn repair_window_us(&self, stream: u16) -> Result<u64, SessionError> {
        self.streams
            .get(&stream)
            .map(Receiver::repair_window_us)
            .ok_or(SessionError::Stream(stream))
    }

    /// Counters of `stream`.
    pub fn stats(&self, stream: u16) -> Result<Stats, SessionError> {
        self.streams.get(&stream).map(Receiver::stats).ok_or(SessionError::Stream(stream))
    }

    /// The next due feedback datagram of any stream (lowest stream first),
    /// framed for the carrier. Call again until it returns `None`.
    pub fn feedback(&mut self, now_us: u64) -> Option<Vec<u8>> {
        if self.failed {
            return None;
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
        let datagram =
            ping.or_else(|| self.streams.values_mut().find_map(|r| r.feedback(now_us)))?;
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
        let ping = self.clock.as_ref().map_or(u64::MAX, ClockEstimator::next_ping_us);
        let stall = self.liveness.deadline_us().unwrap_or(u64::MAX);
        let streams = self.streams.values().map(Receiver::next_deadline_us).min();
        streams.unwrap_or(u64::MAX).min(ping).min(stall)
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

    /// One entry in `ready` per frame a receiver newly queued. A frame a newer
    /// keyframe replaced leaves its entry behind; `pop_frame` skips it.
    fn track(&mut self, stream: u16, before: u64, after: u64) {
        for _ in before..after {
            self.ready.push_back(stream);
        }
    }

    fn on_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), SessionError> {
        let (header, _) = DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
        // Every stream shares the link: any datagram shows it is not on hold.
        self.streams.values_mut().for_each(|r| r.note_link_datagram(now_us));
        self.liveness.heartbeat(header.kind);
        match header.kind {
            DatagramKind::FrameTimes => {
                let (_, payload) =
                    DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
                let times = FrameTimes::decode(payload).map_err(ReceiverError::Invalid)?;
                self.ledger.on_host(header.stream, header.frame, times);
                Ok(())
            }
            DatagramKind::Video | DatagramKind::Fec => {
                if self.streams.contains_key(&header.stream) {
                    self.ledger.on_shard(header.stream, header.frame, datagram.len(), now_us);
                }
                let r = self.receiver(header.stream)?;
                let before = r.frames_queued();
                let pushed = r.push_datagram(datagram, now_us);
                let after = r.frames_queued();
                self.track(header.stream, before, after);
                pushed.map_err(SessionError::from)
            }
            // An ultra capacity probe: its stream's receiver reports the arrival in that
            // stream's feedback. A probe for a stream that is not open is dropped.
            DatagramKind::Probe => match self.streams.get_mut(&header.stream) {
                Some(r) => r.push_datagram(datagram, now_us).map_err(SessionError::from),
                None => Ok(()),
            },
            DatagramKind::ClockPong if self.clock.is_some() => {
                let (_, payload) =
                    DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
                let pong = ClockPong::decode(payload).map_err(ReceiverError::Invalid)?;
                if let Some(clock) = self.clock.as_mut()
                    && clock.on_pong(&pong, now_us)
                {
                    let rtt = self.rtt_us();
                    self.streams.values_mut().for_each(|r| r.set_path_rtt_us(rtt));
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
