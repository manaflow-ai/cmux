//! Cuts a byte stream into JSON lines and frames without copying.
//!
//! The reader owns one `BytesMut`. A frame's payload is split off that buffer
//! as `Bytes` (a reference count, no copy) and may outlive the reader; a JSON
//! line is lent as `&str` until the next call, which zeroes and releases it
//! (lines can carry credentials; the daemon zeroed them before this crate).
//! A frame's payload carries the same request bodies, so its bytes are zeroed
//! when the last `Bytes` that shares them drops (`WipedOnDrop`).
//!
//! It follows Mojo's channel read loop (chromium mojo/core/channel.cc,
//! `Channel::OnReadComplete`): bytes accumulate until a whole message is
//! present, a header is validated as soon as its 16 bytes arrive, and the
//! first bad message stops the reader for good.

use std::io::{self, Read};
use std::mem::MaybeUninit;

use bytes::{Buf, Bytes, BytesMut};

use crate::frame::{BadMessage, Frame, FrameHeader, HEADER_LEN, MAGIC, MAX_FRAME_PAYLOAD};

/// Largest JSON line payload, delimiter excluded: the daemon's existing
/// 16 MiB Unix ingress limit (spec/transports.md).
pub const MAX_JSON_LINE: usize = 16 * 1024 * 1024;

const READ_CHUNK_MIN: usize = 64 * 1024;
const READ_CHUNK_MAX: usize = 1024 * 1024;

/// Per-connection size limits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReaderLimits {
    /// Largest JSON line payload, delimiter excluded.
    pub max_line: usize,
    /// Largest frame payload; capped at `MAX_FRAME_PAYLOAD`.
    pub max_frame_payload: u32,
}

impl Default for ReaderLimits {
    fn default() -> Self {
        ReaderLimits { max_line: MAX_JSON_LINE, max_frame_payload: MAX_FRAME_PAYLOAD }
    }
}

/// One message cut from the stream.
#[derive(Debug, PartialEq, Eq)]
pub enum Message<'a> {
    /// A JSON line without its `\n`, verbatim (empty lines included).
    Json(&'a str),
    /// A validated frame whose payload shares the read buffer.
    Frame(Frame),
}

enum Next {
    Pending,
    Line { len: usize, consumed: usize },
    Frame(Frame),
}

/// A frame payload's own region of the read buffer, zeroed when the last
/// `Bytes` that shares it drops, as a lent line is zeroed on the next call.
/// The region is this value's alone (`split_to` hands out disjoint ranges),
/// so zeroing it never touches bytes another message still holds.
struct WipedOnDrop(BytesMut);

impl AsRef<[u8]> for WipedOnDrop {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for WipedOnDrop {
    fn drop(&mut self) {
        self.0.fill(0);
        #[cfg(test)]
        WIPED_BYTES.with(|wiped| wiped.set(wiped.get() + self.0.len()));
    }
}

#[cfg(test)]
thread_local! {
    /// Bytes this thread's dropped frame payloads zeroed, for the tests:
    /// safe code cannot read a region once its owner is gone.
    pub(crate) static WIPED_BYTES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// The reader. Feed it with `push`, `read_from` or `read_with`, then call `next_message`
/// until it returns `Ok(None)`.
#[derive(Debug)]
pub struct FrameReader {
    buf: BytesMut,
    limits: ReaderLimits,
    frames_negotiated: bool,
    eof: bool,
    /// Bytes of the pending line already searched for `\n`, so a line that
    /// arrives in many reads is scanned once.
    scanned: usize,
    /// The lent line plus its delimiter, released by the next call.
    lent: usize,
    /// The validated header of the frame in progress.
    header: Option<FrameHeader>,
    failed: Option<BadMessage>,
}

impl FrameReader {
    /// A reader that accepts only JSON lines until `negotiate_frames`.
    pub fn new(limits: ReaderLimits) -> FrameReader {
        FrameReader {
            buf: BytesMut::new(),
            limits,
            frames_negotiated: false,
            eof: false,
            scanned: 0,
            lent: 0,
            header: None,
            failed: None,
        }
    }

    /// Accept frames from now on. Until then a frame is a bad message.
    pub fn negotiate_frames(&mut self) {
        self.frames_negotiated = true;
    }

    /// Appends bytes received elsewhere (recvmsg, a test).
    pub fn push(&mut self, bytes: &[u8]) {
        self.release_lent_line();
        self.buf.extend_from_slice(bytes);
    }

    /// The peer closed: a trailing line without `\n` is still a message (as
    /// `BufRead::read_line` returns it), a partial frame is `Truncated`.
    pub fn mark_eof(&mut self) {
        self.eof = true;
    }

    /// One `read` from `source` into the buffer. `Ok(0)` marks EOF.
    pub fn read_from<R: Read + ?Sized>(&mut self, source: &mut R) -> io::Result<usize> {
        self.read_with(|room| source.read(room))
    }

    /// One read straight into the buffer, for a source `Read` cannot
    /// describe (`recvmsg` with its descriptors). `read` gets the room the
    /// next message needs, at least 64 KiB and at most 1 MiB, writes from
    /// its start and returns how many bytes it wrote. `Ok(0)` marks EOF.
    ///
    /// The bytes land in the buffer messages are cut from, with no copy in
    /// between, as Mojo's `Channel::GetReadBuffer` sizes its read buffer to
    /// the pending message and lends it to the platform read
    /// (chromium mojo/core/channel.cc).
    pub fn read_with(
        &mut self,
        read: impl FnOnce(&mut [u8]) -> io::Result<usize>,
    ) -> io::Result<usize> {
        self.release_lent_line();
        let frame_rest =
            self.header.map_or(0, |header| header.frame_len().saturating_sub(self.buf.len()));
        let want = frame_rest.clamp(READ_CHUNK_MIN, READ_CHUNK_MAX);
        let start = self.buf.len();
        self.buf.resize(start.saturating_add(want), 0);
        let result = self.buf.get_mut(start..).map_or(Ok(0), read);
        let read = result.as_ref().map_or(0, |read| (*read).min(want));
        self.buf.truncate(start.saturating_add(read));
        if read == 0 && result.is_ok() {
            self.eof = true;
        }
        result.map(|_| read)
    }

    /// Whether the next message starts with the frame byte: a frame, or a
    /// bad message while frames are not negotiated. Lets the owner decide
    /// whether the connection may send a frame now, before it is cut.
    pub fn next_is_frame(&self) -> bool {
        self.buf.get(self.lent) == Some(&MAGIC)
    }

    /// Bytes the reader holds allocated: what an idle connection costs.
    pub fn capacity(&self) -> usize {
        self.buf.capacity()
    }

    /// Bytes received and not yet returned.
    pub fn buffered_len(&self) -> usize {
        self.buf.len().saturating_sub(self.lent)
    }

    /// The next whole message, `Ok(None)` when more bytes are needed (or the
    /// stream ended cleanly), or the bad message that stopped the reader.
    pub fn next_message(&mut self) -> Result<Option<Message<'_>>, BadMessage> {
        if let Some(bad) = self.failed {
            return Err(bad);
        }
        self.release_lent_line();
        let next = match self.cut() {
            Ok(next) => next,
            Err(bad) => {
                self.failed = Some(bad);
                return Err(bad);
            }
        };
        match next {
            Next::Pending => Ok(None),
            Next::Frame(frame) => Ok(Some(Message::Frame(frame))),
            Next::Line { len, consumed } => {
                self.lent = consumed;
                let line = self.buf.get(..len).unwrap_or_default();
                match std::str::from_utf8(line) {
                    Ok(text) => Ok(Some(Message::Json(text))),
                    Err(error) => {
                        let bad = BadMessage::InvalidUtf8 { valid_up_to: error.valid_up_to() };
                        self.failed = Some(bad);
                        Err(bad)
                    }
                }
            }
        }
    }

    fn cut(&mut self) -> Result<Next, BadMessage> {
        match self.buf.first() {
            None => Ok(Next::Pending),
            Some(&MAGIC) => self.cut_frame(),
            Some(_) => self.cut_line(),
        }
    }

    fn cut_frame(&mut self) -> Result<Next, BadMessage> {
        if !self.frames_negotiated {
            return Err(BadMessage::FramesNotNegotiated);
        }
        let header = match self.header {
            Some(header) => header,
            None => {
                let Some(bytes) = self
                    .buf
                    .get(..HEADER_LEN)
                    .and_then(|bytes| <[u8; HEADER_LEN]>::try_from(bytes).ok())
                else {
                    return self.pending_frame(HEADER_LEN);
                };
                let header = FrameHeader::decode(bytes, self.limits.max_frame_payload)?;
                self.header = Some(header);
                self.buf.reserve(header.frame_len().saturating_sub(self.buf.len()));
                header
            }
        };
        if self.buf.len() < header.frame_len() {
            return self.pending_frame(header.frame_len());
        }
        let mut whole = self.buf.split_to(header.frame_len());
        if self.buf.is_empty() && header.frame_len() > READ_CHUNK_MAX {
            // Otherwise the next read reclaims the long frame's allocation
            // once the frame drops, and the idle connection keeps it.
            self.buf = BytesMut::new();
        }
        whole.advance(HEADER_LEN);
        self.header = None;
        Frame::from_parts(header, Bytes::from_owner(WipedOnDrop(whole))).map(Next::Frame)
    }

    fn pending_frame(&self, need: usize) -> Result<Next, BadMessage> {
        if self.eof {
            return Err(BadMessage::Truncated { have: self.buf.len(), need });
        }
        Ok(Next::Pending)
    }

    fn cut_line(&mut self) -> Result<Next, BadMessage> {
        let unsearched = self.buf.get(self.scanned..).unwrap_or_default();
        let max = self.limits.max_line;
        match memchr::memchr(b'\n', unsearched) {
            Some(offset) => {
                let len = self.scanned.saturating_add(offset);
                self.scanned = 0;
                if len > max {
                    return Err(BadMessage::LineTooLong { max });
                }
                Ok(Next::Line { len, consumed: len.saturating_add(1) })
            }
            None => {
                let len = self.buf.len();
                if len > max {
                    return Err(BadMessage::LineTooLong { max });
                }
                if self.eof {
                    self.scanned = 0;
                    return Ok(Next::Line { len, consumed: len });
                }
                self.scanned = len;
                Ok(Next::Pending)
            }
        }
    }

    /// Zeroes and releases the lent line. A buffer left empty after growing
    /// past the largest read (a long line or frame) is freed, so an idle
    /// connection holds a read's worth of memory, not its largest message.
    fn release_lent_line(&mut self) {
        if self.lent > 0 {
            let lent = self.lent.min(self.buf.len());
            if let Some(line) = self.buf.get_mut(..lent) {
                line.fill(0);
            }
            self.buf.advance(lent);
            self.lent = 0;
        }
        if self.buf.is_empty() && self.buf.capacity() > READ_CHUNK_MAX {
            // A reserve that moved bytes to the front left their old copy in
            // the spare room: zero it before the allocation is freed.
            self.buf.spare_capacity_mut().fill(MaybeUninit::new(0));
            self.buf = BytesMut::new();
        }
    }
}
