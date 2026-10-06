//! The viewer side of one `cmux.rd/1` session with several display streams
//! (rd change C6, plans/cmux-next/remote-tab-protocol.md section 7): every
//! video or parity datagram goes to the reassembler of the stream its header
//! names, so streams with the same frame numbers never mix; feedback and
//! keyframe requests are per stream. Only streams the caller opened are
//! accepted (stream 0 is open from the start); other datagrams are queued as
//! messages for the caller. The C ABI in `session_ffi.rs` is a thin shell.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer,
    encode_stream_frame,
};

use crate::receiver::{
    Carrier, MAX_MESSAGE_BYTES, MESSAGE_OVERHEAD, Message, Receiver, ReceiverError, Stats,
};

/// Most open streams per session (main surface, popups, tiles).
pub const MAX_STREAMS: usize = 16;

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
            failed: false,
        };
        let _ = s.open_stream(0);
        s
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
        while let Some(stream) = self.ready.pop_front() {
            if let Some(frame) = self.streams.get_mut(&stream).and_then(Receiver::pop_frame) {
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

    /// Asks the host for a keyframe on `stream` until one is released there.
    pub fn request_keyframe(&mut self, stream: u16) -> Result<(), SessionError> {
        self.receiver(stream)?.request_keyframe();
        Ok(())
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
        let datagram = self.streams.values_mut().find_map(|r| r.feedback(now_us))?;
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
        self.streams.values().map(Receiver::next_deadline_us).min().unwrap_or(u64::MAX)
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
            _ => self.queue_message(STREAM_DATAGRAM, datagram.to_vec()),
        }
    }

    fn queue_message(&mut self, kind: u8, bytes: Vec<u8>) -> Result<(), SessionError> {
        debug_assert!(matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM));
        let cost = bytes.len() + MESSAGE_OVERHEAD;
        if self.message_bytes + cost > MAX_MESSAGE_BYTES {
            return Err(self.fail());
        }
        self.message_bytes += cost;
        self.messages.push_back(Message { kind, bytes });
        Ok(())
    }
}
