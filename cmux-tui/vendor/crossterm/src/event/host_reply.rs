//! Host terminal replies to OSC queries (cmux patch, `CMUX_PATCH.md`).
//!
//! A program that asks its terminal `ESC ] 10 ; ? ST` (default foreground) or
//! `ESC ] 11 ; ? ST` (background) gets `ESC ] 10 ; rgb:… ST` back on its
//! input. Upstream Crossterm has no OSC grammar: it read `ESC ]` as Alt+] and
//! the rest as typed text, so a reply that came after the program stopped
//! waiting for it was delivered as keys. A person cannot type an OSC
//! sequence, so a complete reply is never input.

/// The longest color reply this scanner waits for. `ESC ] 11 ; rgba:` with
/// four 16-bit channels and its end is about 32 bytes; a longer start is
/// typed input, never held.
const MAX_HOST_REPLY_BYTES: usize = 64;

/// The replies the client asks for: OSC 10 (foreground) and OSC 11
/// (background). Any other `ESC ]` is Alt+] and typed text.
const REPLY_PREFIXES: [&[u8]; 2] = [b"10;", b"11;"];

/// What the start of a byte buffer is, as a host OSC reply.
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostReply {
    /// A whole OSC 10 or 11 reply, `ESC ] 1 0|1 ; text` ended by BEL or
    /// `ESC \`, of this many bytes.
    Complete(usize),
    /// The start of such a reply whose end has not arrived (or only
    /// `ESC ]`, `ESC ] 1`, ...).
    Partial,
    /// Not a reply: input to parse as keys.
    NotAReply,
}

/// Scans `bytes` for a host OSC 10/11 reply at their start. The reply text
/// is printable ASCII of a bounded length; anything else is no reply.
#[doc(hidden)]
pub fn scan_host_reply(bytes: &[u8]) -> HostReply {
    let Some(rest) = bytes.strip_prefix(b"\x1b]") else { return HostReply::NotAReply };
    let head = rest.get(..3).unwrap_or(rest);
    if !REPLY_PREFIXES.iter().any(|prefix| prefix.starts_with(head)) {
        return HostReply::NotAReply;
    }
    let body = 2 + 3;
    if bytes.len() < body {
        return HostReply::Partial;
    }
    let mut index = body;
    while let Some(&byte) = bytes.get(index) {
        match byte {
            0x07 => return HostReply::Complete(index + 1),
            0x1b => {
                return match bytes.get(index + 1) {
                    Some(b'\\') => HostReply::Complete(index + 2),
                    None => HostReply::Partial,
                    Some(_) => HostReply::NotAReply,
                };
            }
            0x20..=0x7e => index += 1,
            _ => return HostReply::NotAReply,
        }
        if index >= MAX_HOST_REPLY_BYTES {
            return HostReply::NotAReply;
        }
    }
    HostReply::Partial
}

#[cfg(test)]
#[path = "host_reply_tests.rs"]
mod tests;
