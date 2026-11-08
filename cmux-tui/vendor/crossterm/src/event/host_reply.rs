//! Host terminal replies to OSC queries (cmux patch, `CMUX_PATCH.md`).
//!
//! A program that asks its terminal `ESC ] 10 ; ? ST` (default foreground) or
//! `ESC ] 11 ; ? ST` (background) gets `ESC ] 10 ; rgb:… ST` back on its
//! input. Upstream Crossterm has no OSC grammar: it read `ESC ]` as Alt+] and
//! the rest as typed text, so a reply that came after the program stopped
//! waiting for it was delivered as keys. A person cannot type an OSC
//! sequence, so a complete reply is never input.

/// The longest reply this scanner waits for. An OSC 52 clipboard reply is
/// the longest a terminal sends to a query; anything longer is no reply.
const MAX_HOST_REPLY_BYTES: usize = 16 * 1024;

/// What the start of a byte buffer is, as a host OSC reply.
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostReply {
    /// A whole reply, `ESC ] digits ; text` ended by BEL or `ESC \`, of
    /// this many bytes.
    Complete(usize),
    /// The start of a reply whose end has not arrived (or only `ESC ]`).
    Partial,
    /// Not a reply: input to parse as keys.
    NotAReply,
}

/// Scans `bytes` for a host OSC reply at their start.
#[doc(hidden)]
pub fn scan_host_reply(bytes: &[u8]) -> HostReply {
    let Some(rest) = bytes.strip_prefix(b"\x1b]") else { return HostReply::NotAReply };
    let digits = rest.iter().take_while(|byte| byte.is_ascii_digit()).count();
    match rest.get(digits) {
        None => return HostReply::Partial,
        Some(b';') if digits > 0 => {}
        Some(_) => return HostReply::NotAReply,
    }
    let body = 2 + digits + 1;
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
            0x00..=0x1f | 0x7f => return HostReply::NotAReply,
            _ => index += 1,
        }
        if index >= MAX_HOST_REPLY_BYTES {
            return HostReply::NotAReply;
        }
    }
    HostReply::Partial
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_replies_with_either_terminator_are_complete() {
        let st = b"\x1b]11;rgb:2727/2828/2222\x1b\\a";
        assert_eq!(scan_host_reply(st), HostReply::Complete(st.len() - 1));
        let bel = b"\x1b]10;rgb:fdfd/ffff/f1f1\x07";
        assert_eq!(scan_host_reply(bel), HostReply::Complete(bel.len()));
    }

    #[test]
    fn a_reply_without_its_end_is_partial_and_keys_are_not_replies() {
        assert_eq!(scan_host_reply(b"\x1b]"), HostReply::Partial);
        assert_eq!(scan_host_reply(b"\x1b]11"), HostReply::Partial);
        assert_eq!(scan_host_reply(b"\x1b]11;rgb:27"), HostReply::Partial);
        assert_eq!(scan_host_reply(b"\x1b]11;rgb:27\x1b"), HostReply::Partial);
        assert_eq!(scan_host_reply(b"\x1b]a"), HostReply::NotAReply);
        assert_eq!(scan_host_reply(b"\x1b];x\x07"), HostReply::NotAReply);
        assert_eq!(scan_host_reply(b"\x1b]11;x\rmore"), HostReply::NotAReply);
        assert_eq!(scan_host_reply(b"\x1b[A"), HostReply::NotAReply);
        assert_eq!(scan_host_reply(b"a"), HostReply::NotAReply);
    }
}
