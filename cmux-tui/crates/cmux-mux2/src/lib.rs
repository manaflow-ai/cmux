//! Wire protocol shared by `mux2d` (the server) and `mux2` (the client).
//!
//! One Unix stream socket per client. Every message is a frame:
//! `u32 little-endian length` (of what follows), `u8 kind`, payload.
//! Terminal output travels as raw bytes in [`OUTPUT`] frames: no base64,
//! no JSON, no copy beyond the socket write.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use std::io::{self, Read, Write};
use std::path::PathBuf;

// Client to server.
pub const CREATE: u8 = 1;
pub const WRITE: u8 = 2;
pub const SCREEN: u8 = 3;
pub const LIST: u8 = 4;
pub const KILL: u8 = 5;
pub const WAIT: u8 = 6;
pub const ATTACH: u8 = 7;
pub const RESIZE: u8 = 8;
pub const STATS: u8 = 9;
pub const SHUTDOWN: u8 = 10;
pub const REPLAY: u8 = 11;
/// Replace the running server with a new binary, keeping every terminal.
pub const UPGRADE: u8 = 12;

// Server to client.
pub const OK: u8 = 100;
pub const ERR: u8 = 101;
pub const OUTPUT: u8 = 102;
pub const EXIT: u8 = 103;
pub const SNAPSHOT: u8 = 104;

/// Largest frame either side accepts.
pub const MAX_FRAME: usize = 64 << 20;

pub fn socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("MUX2_SOCKET") {
        return PathBuf::from(path);
    }
    let base = std::env::var_os("TMPDIR").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    base.join(format!("mux2-{uid}")).join("sock")
}

/// Appends one frame to `out`.
pub fn put_frame(out: &mut Vec<u8>, kind: u8, payload: &[u8]) {
    let len = u32::try_from(payload.len() + 1).expect("frame fits u32");
    out.extend_from_slice(&len.to_le_bytes());
    out.push(kind);
    out.extend_from_slice(payload);
}

/// Splits the first complete frame off `buf`, returning `(kind, payload, consumed)`.
pub fn take_frame(buf: &[u8]) -> io::Result<Option<(u8, &[u8], usize)>> {
    if buf.len() < 5 {
        return Ok(None);
    }
    let len = u32::from_le_bytes(buf[..4].try_into().expect("4 bytes")) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad frame length"));
    }
    if buf.len() < 4 + len {
        return Ok(None);
    }
    Ok(Some((buf[4], &buf[5..4 + len], 4 + len)))
}

pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut out = Vec::with_capacity(payload.len() + 5);
    put_frame(&mut out, kind, payload);
    w.write_all(&out)
}

pub fn read_frame(r: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    r.read_exact(&mut head)?;
    let len = u32::from_le_bytes(head[..4].try_into().expect("4 bytes")) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad frame length"));
    }
    let mut payload = vec![0u8; len - 1];
    r.read_exact(&mut payload)?;
    Ok((head[4], payload))
}

/// Little-endian cursor over a request payload.
pub struct Reader<'a>(pub &'a [u8]);

impl Reader<'_> {
    pub fn u16(&mut self) -> Option<u16> {
        let (head, rest) = self.0.split_first_chunk::<2>()?;
        self.0 = rest;
        Some(u16::from_le_bytes(*head))
    }
    pub fn u32(&mut self) -> Option<u32> {
        let (head, rest) = self.0.split_first_chunk::<4>()?;
        self.0 = rest;
        Some(u32::from_le_bytes(*head))
    }
    pub fn bytes(&mut self) -> Option<&[u8]> {
        let len = self.u32()? as usize;
        if self.0.len() < len {
            return None;
        }
        let (head, rest) = self.0.split_at(len);
        self.0 = rest;
        Some(head)
    }
}

pub fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).expect("fits u32").to_le_bytes());
    out.extend_from_slice(bytes);
}

/// CREATE payload: cols, rows, cwd (empty inherits), argv.
pub fn create_payload(cols: u16, rows: u16, cwd: &[u8], argv: &[&[u8]]) -> Vec<u8> {
    let mut p = Vec::new();
    p.extend_from_slice(&cols.to_le_bytes());
    p.extend_from_slice(&rows.to_le_bytes());
    put_bytes(&mut p, cwd);
    p.extend_from_slice(&u16::try_from(argv.len()).expect("argc fits u16").to_le_bytes());
    for arg in argv {
        put_bytes(&mut p, arg);
    }
    p
}

/// Removes the queries a program sends to its terminal from a stream that a
/// viewer passes to its own outer terminal. The server already answered
/// them; if the outer terminal saw them too, its replies would come back on
/// the viewer's input as a second, wrong answer.
///
/// Works on the server's accepted stream, where C1 controls are in their
/// 7-bit forms. Sequences split across calls are held until complete.
#[derive(Default)]
pub struct QueryStripper {
    held: Vec<u8>,
    state: StripState,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum StripState {
    #[default]
    Ground,
    Esc,
    EscIntermediate,
    Csi,
    Str,
    StrEsc,
    /// A string too long to be a query: passed through as it arrives.
    StrPass,
    StrPassEsc,
}

/// Longest string sequence that can still be a query.
const STRIP_HOLD_MAX: usize = 4096;

impl QueryStripper {
    pub fn push(&mut self, input: &[u8], out: &mut Vec<u8>) {
        use StripState::*;
        for &b in input {
            match self.state {
                Ground => match b {
                    0x05 => {}
                    0x1b => self.hold(b, Esc),
                    _ => out.push(b),
                },
                Esc => match b {
                    b'[' => self.hold(b, Csi),
                    b']' | b'P' | b'_' | b'^' | b'X' => self.hold(b, Str),
                    b'Z' => self.drop_held(),
                    0x20..=0x2f => self.hold(b, EscIntermediate),
                    0x1b => {
                        out.append(&mut self.held);
                        self.hold(b, Esc);
                    }
                    _ => self.emit(b, out),
                },
                EscIntermediate => match b {
                    0x20..=0x2f => self.held.push(b),
                    _ => self.emit(b, out),
                },
                Csi => match b {
                    0x40..=0x7e => {
                        self.held.push(b);
                        if csi_is_query(&self.held) { self.drop_held() } else { self.flush(out) }
                    }
                    0x18 | 0x1a => self.emit(b, out),
                    0x1b => {
                        out.append(&mut self.held);
                        self.hold(b, Esc);
                    }
                    _ => self.held.push(b),
                },
                Str | StrEsc => {
                    self.held.push(b);
                    let osc = self.held.get(1) == Some(&b']');
                    let end = (b == 0x07 && osc) || (self.state == StrEsc && b == b'\\');
                    if end {
                        if string_is_query(&self.held) { self.drop_held() } else { self.flush(out) }
                    } else if b == 0x18 || b == 0x1a || self.state == StrEsc {
                        // CAN/SUB, or ESC not followed by `\`, aborts the
                        // string; the outer terminal sees the same bytes.
                        self.flush(out);
                    } else if self.held.len() > STRIP_HOLD_MAX {
                        out.append(&mut self.held);
                        self.state = if b == 0x1b { StrPassEsc } else { StrPass };
                    } else {
                        self.state = if b == 0x1b { StrEsc } else { Str };
                    }
                }
                StrPass | StrPassEsc => {
                    out.push(b);
                    let end = b == 0x07 || b == 0x18 || b == 0x1a || self.state == StrPassEsc;
                    self.state = if end {
                        Ground
                    } else if b == 0x1b {
                        StrPassEsc
                    } else {
                        StrPass
                    };
                }
            }
        }
    }

    fn hold(&mut self, b: u8, state: StripState) {
        self.held.push(b);
        self.state = state;
    }
    fn emit(&mut self, b: u8, out: &mut Vec<u8>) {
        self.held.push(b);
        self.flush(out);
    }
    fn flush(&mut self, out: &mut Vec<u8>) {
        out.append(&mut self.held);
        self.state = StripState::Ground;
    }
    fn drop_held(&mut self) {
        self.held.clear();
        self.state = StripState::Ground;
    }
}

/// `seq` is a complete CSI sequence, `ESC [ ... final`.
fn csi_is_query(seq: &[u8]) -> bool {
    let fin = seq[seq.len() - 1];
    let body = &seq[2..seq.len() - 1];
    let first = body.first().copied();
    match fin {
        b'c' | b'n' | b'x' => true,         // DA1/2/3, DSR/CPR, DECREQTPARM
        b'p' => body.last() == Some(&b'$'), // DECRQM
        b'q' => first == Some(b'>'),        // XTVERSION
        b'u' => first == Some(b'?'),        // kitty keyboard flags query
        b't' => {
            let ps: u32 = body
                .iter()
                .take_while(|c| c.is_ascii_digit())
                .fold(0, |a, c| a * 10 + u32::from(c - b'0'));
            matches!(ps, 11 | 13 | 14 | 15 | 16 | 18 | 19 | 20 | 21) // XTWINOPS reports
        }
        _ => false,
    }
}

/// `seq` is a complete string sequence, introducer through terminator.
fn string_is_query(seq: &[u8]) -> bool {
    let end = if seq.last() == Some(&0x07) { seq.len() - 1 } else { seq.len() - 2 };
    let body = &seq[2..end.max(2)];
    match seq[1] {
        b']' => body.split(|c| *c == b';').any(|field| field == b"?"), // OSC color/clipboard queries
        b'P' => body.starts_with(b"+q") || body.starts_with(b"$q"),    // XTGETTCAP, DECRQSS
        b'_' => body.first() == Some(&b'G') && body.windows(3).any(|w| w == b"a=q"), // kitty graphics query
        _ => false,
    }
}
