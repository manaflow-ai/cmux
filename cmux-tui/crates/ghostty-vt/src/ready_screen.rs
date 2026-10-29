//! Test support (feature `test-support`): what a GHOSTSNP READY holds, read
//! the way a snapshot viewer shows it. Stream checkers (the daemon's resize
//! fuzzer) compare it with the source terminal. It is a test reader, not a
//! usable terminal: it returns plain values, never a [`Terminal`].

use std::ptr;

use crate::render::{Cell, RenderState};
use crate::snapshot::SnapshotPhase;
use crate::{Result, SNAPSHOT_CONTINUATION_MAX_BYTES, Terminal, check, sys};

/// What a viewer shows after it restores a READY prefix (no history page:
/// a local-history READY never has one) and parses the stream bytes after
/// the READY's cut.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadyScreen {
    pub cols: u16,
    pub rows: u16,
    /// The viewport as plain text ([`Terminal::viewport_text`]).
    pub text: String,
    pub cursor: Option<(u16, u16)>,
    /// Every visible row, blank rows too, cell by cell with its style, as a
    /// renderer draws it.
    pub cells: Vec<Vec<Cell>>,
    /// The restored terminal's own READY encode (for a failure report).
    pub ready: Vec<u8>,
}

impl ReadyScreen {
    /// Restores the READY prefix of `snapshot` into a new libghostty
    /// terminal, writes `output` to it as raw stream bytes (the viewer's
    /// parser resumes inside the source's unfinished sequence, the
    /// CONTINUATION record) and reads its screen.
    pub fn read(snapshot: &[u8], output: &[u8]) -> Result<Self> {
        let raw = decode_ready(snapshot)?;
        if !output.is_empty() {
            // SAFETY: `raw` is the live terminal decode_ready returned, owned
            // here, and `output` is readable for `output.len()` bytes.
            unsafe { sys::ghostty_terminal_vt_write(raw, output.as_ptr(), output.len()) };
        }
        let mut reader = Terminal::reader_over(raw)?;
        let mut render = RenderState::new()?;
        render.update(&mut reader)?;
        Ok(Self {
            cols: reader.cols(),
            rows: reader.rows(),
            text: reader.viewport_text()?,
            cursor: reader.cursor_position(),
            cells: render.build_frame()?.styled_rows().to_vec(),
            ready: reader.encode_snapshot(SnapshotPhase::Ready)?,
        })
    }
}

/// Decodes the READY prefix of `snapshot` (GHOSTSNP, not compressed) into a
/// new caller-owned terminal that tracks its unfinished sequence.
fn decode_ready(snapshot: &[u8]) -> Result<sys::GhosttyTerminal> {
    let mut decoder: sys::GhosttySnapshotDecoder = ptr::null_mut();
    // SAFETY: the decoder borrows `snapshot` without copying, and `snapshot`
    // outlives it (freed below).
    check(unsafe {
        sys::ghostty_snapshot_decoder_new_buf(
            ptr::null(),
            &mut decoder,
            snapshot.as_ptr(),
            snapshot.len(),
        )
    })?;
    let max_continuation = SNAPSHOT_CONTINUATION_MAX_BYTES;
    let retain = true;
    let mut raw: sys::GhosttyTerminal = ptr::null_mut();
    // SAFETY: the option pointers have the documented input types (size_t,
    // bool) and outlive the calls; `raw` is a writable local.
    let result = check(unsafe {
        sys::ghostty_snapshot_decoder_set(
            decoder,
            sys::GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
            (&max_continuation as *const usize).cast(),
        )
    })
    .and_then(|()| {
        // SAFETY: as above.
        check(unsafe {
            sys::ghostty_snapshot_decoder_set(
                decoder,
                sys::GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
                (&retain as *const bool).cast(),
            )
        })
    })
    // SAFETY: `decoder` is live and `raw` a writable local.
    .and_then(|()| check(unsafe { sys::ghostty_snapshot_decoder_ready(decoder, &mut raw) }));
    // SAFETY: the decoder only borrows `raw` (caller-owned); it is freed once
    // here, after its last use.
    unsafe { sys::ghostty_snapshot_decoder_free(decoder) };
    match result {
        Ok(()) => Ok(raw),
        Err(error) => {
            // SAFETY: `raw` is null (allowed) or the terminal READY returned.
            unsafe { sys::ghostty_terminal_free(raw) };
            Err(error)
        }
    }
}
