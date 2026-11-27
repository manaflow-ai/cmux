//! Kitty graphics control data (`key=value,...`) and the chunked direct
//! transmission that replaces a file-medium command.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

use crate::CHUNK_BASE64_BYTES;

/// Raw bytes per chunk: 4096 base64 characters, a multiple of 3 so chunks
/// concatenate to one valid encoding.
const CHUNK_RAW_BYTES: usize = CHUNK_BASE64_BYTES / 4 * 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Medium {
    Direct,
    File,
    TempFile,
    SharedMemory,
    /// A medium this rewriter does not know; passed through.
    Unknown,
}

/// Parsed control data. Keys are the single bytes the protocol defines.
pub(crate) struct Control<'a> {
    pairs: Vec<(u8, &'a [u8])>,
}

impl<'a> Control<'a> {
    /// `None` when any pair is not `k=v` with a one-byte key.
    pub(crate) fn parse(control: &'a [u8]) -> Option<Self> {
        let mut pairs = Vec::new();
        if control.is_empty() {
            return Some(Self { pairs });
        }
        for pair in control.split(|&byte| byte == b',') {
            match pair {
                [key, b'=', value @ ..] => pairs.push((*key, value)),
                _ => return None,
            }
        }
        Some(Self { pairs })
    }

    pub(crate) fn value(&self, key: u8) -> Option<&'a [u8]> {
        self.pairs.iter().rev().find(|(k, _)| *k == key).map(|(_, v)| *v)
    }

    pub(crate) fn medium(&self) -> Medium {
        match self.value(b't') {
            None | Some(b"d") => Medium::Direct,
            Some(b"f") => Medium::File,
            Some(b"t") => Medium::TempFile,
            Some(b"s") => Medium::SharedMemory,
            Some(_) => Medium::Unknown,
        }
    }

    /// An unsigned integer key; absent is 0, malformed is `None`.
    pub(crate) fn number(&self, key: u8) -> Option<u64> {
        match self.value(key) {
            None => Some(0),
            Some(digits) if !digits.is_empty() && digits.iter().all(u8::is_ascii_digit) => {
                std::str::from_utf8(digits).ok()?.parse().ok()
            }
            Some(_) => None,
        }
    }

    /// Whether this command transmits image or frame data, so a direct one
    /// opens or continues a chunked load (`a` absent means `t`).
    pub(crate) fn transmits(&self) -> bool {
        matches!(self.value(b'a'), None | Some(b"t" | b"T" | b"f" | b"q"))
    }

    /// Whether a direct command leaves a chunked load open (`m=1`).
    pub(crate) fn more_chunks(&self) -> bool {
        self.value(b'm') == Some(b"1")
    }
}

/// Appends the direct transmission of `data` that replaces a file-medium
/// command with this control data. The caller already wrote the first
/// `ESC _ G`; every later chunk carries its own.
pub(crate) fn write_direct(out: &mut Vec<u8>, control: &Control<'_>, data: &[u8]) {
    let quiet = control.value(b'q');
    let mut first_keys = Vec::with_capacity(64);
    for (key, value) in &control.pairs {
        // The medium, its size and offset describe the file; `m` belongs to
        // the chunking written here.
        if matches!(key, b't' | b'S' | b'O' | b'm') {
            continue;
        }
        if !first_keys.is_empty() {
            first_keys.push(b',');
        }
        first_keys.push(*key);
        first_keys.push(b'=');
        first_keys.extend_from_slice(value);
    }
    out.reserve(data.len().div_ceil(3).saturating_mul(4).saturating_add(64));
    let mut chunks = data.chunks(CHUNK_RAW_BYTES).peekable();
    let mut first = true;
    loop {
        let chunk = chunks.next().unwrap_or(&[]);
        let last = chunks.peek().is_none();
        if !first {
            out.extend_from_slice(b"\x1b_G");
        }
        let mut keys_written = false;
        if first {
            out.extend_from_slice(&first_keys);
            keys_written = !first_keys.is_empty();
        } else if let Some(quiet) = quiet {
            out.extend_from_slice(b"q=");
            out.extend_from_slice(quiet);
            keys_written = true;
        }
        // A single chunk needs no `m`; a chunked load marks every chunk.
        if !(first && last) {
            if keys_written {
                out.push(b',');
            }
            out.extend_from_slice(if last { b"m=0" } else { b"m=1" });
        }
        out.push(b';');
        let start = out.len();
        out.resize(start.saturating_add(chunk.len().div_ceil(3).saturating_mul(4)), 0);
        if let Some(target) = out.get_mut(start..) {
            let written = STANDARD.encode_slice(chunk, target).unwrap_or(0);
            out.truncate(start.saturating_add(written));
        }
        out.extend_from_slice(b"\x1b\\");
        first = false;
        if last {
            break;
        }
    }
}

/// Closes a direct chunked load another command interrupts: Kitty abandons
/// it (ghostty-org/ghostty#14811), and a rewritten command is direct, so the
/// terminal would otherwise take its first chunk as the next piece of that
/// load. The empty final chunk ends the load quietly.
pub(crate) const CLOSE_OPEN_LOAD: &[u8] = b"m=0,q=2;\x1b\\\x1b_G";
