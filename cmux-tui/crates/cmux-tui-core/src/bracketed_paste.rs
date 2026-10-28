//! Bracketed paste framing (xterm DEC mode 2004): `ESC [ 200 ~` text `ESC [ 201 ~`.
//!
//! A program that turned the mode on treats everything between the markers as
//! pasted text, never as keys. An end marker inside the text would end the
//! paste early and make the rest typed input, so [`frame`] removes every end
//! marker from the text first, until none is left: removing one may join the
//! bytes around it into another.

/// The start marker.
pub const START: &[u8] = b"\x1b[200~";
/// The end marker.
pub const END: &[u8] = b"\x1b[201~";

/// `text` without any paste end marker, also none that removal rebuilds.
#[must_use]
pub fn without_end_markers(text: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    if !contains(text, END) {
        return std::borrow::Cow::Borrowed(text);
    }
    let mut out = text.to_vec();
    while let Some(at) = find(&out, END) {
        out.drain(at..at + END.len());
    }
    std::borrow::Cow::Owned(out)
}

/// `text` framed as one bracketed paste, with no end marker inside.
#[must_use]
pub fn frame(text: &[u8]) -> Vec<u8> {
    let body = without_end_markers(text);
    let mut out = Vec::with_capacity(body.len() + START.len() + END.len());
    out.extend_from_slice(START);
    out.extend_from_slice(&body);
    out.extend_from_slice(END);
    out
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    find(haystack, needle).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_plain_text() {
        assert_eq!(frame(b"hi"), b"\x1b[200~hi\x1b[201~".to_vec());
    }

    #[test]
    fn removes_end_markers_also_rebuilt_ones() {
        assert_eq!(frame(b"a\x1b[201~b"), b"\x1b[200~ab\x1b[201~".to_vec());
        assert_eq!(frame(b"a\x1b[20\x1b[201~1~b"), b"\x1b[200~ab\x1b[201~".to_vec());
        assert_eq!(frame(b"\x1b[201~\x1b[201~"), b"\x1b[200~\x1b[201~".to_vec());
    }

    #[test]
    fn keeps_other_escapes() {
        assert_eq!(&*without_end_markers(b"\x1b[200~x\x1b[31m"), b"\x1b[200~x\x1b[31m");
    }
}
