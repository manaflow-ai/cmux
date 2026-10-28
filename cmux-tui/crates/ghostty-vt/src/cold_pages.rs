//! Lossless cold-scrollback codec (gated by the kernel
//! compressor measurement p07-memory-112; plans/cmux-next/chrome-parity/p07-memory.md).
//!
//! [`Terminal::into_cold`] turns a terminal nobody reads into a
//! [`ColdTerminal`]: the libghostty-vt terminal is encoded as one GHOSTSNP
//! COMPLETE snapshot (every page of both screens with its cells, styles,
//! hyperlinks, graphemes and semantic-prompt marks; modes, colors, cursor,
//! title, PWD, scrollback policy and the unfinished VT sequence), streamed
//! through zlib, plus libghostty's Kitty replay stream (images and
//! placements; its pixels are zlib already). Then the libghostty terminal is
//! freed. The Rust wrapper stays as it was: callbacks, row markers (epoch
//! and evicted rows), history epoch, override trackers. [`ColdTerminal::thaw`]
//! decodes the snapshot into a new libghostty terminal and gives it back.
//!
//! Exact or refused: what the codec cannot restore exactly makes
//! [`Terminal::into_cold`] refuse with a [`ColdPagesError`] and hand the
//! terminal back unchanged, as Chrome refuses to discard a tab in a state it
//! cannot rebuild (`chrome/browser/performance_manager/policies/page_discarding_helper.cc`,
//! `CanDiscard`). Refused: a Kitty upload in progress, deferred clipboard reads
//! (their tokens live in libghostty), and Kitty state the replay stream does
//! not carry (an image without a showing placement keeps no pixels in it, and
//! a placement only in scrollback is not in it), and any image on the
//! inactive screen (libghostty-vt reads the Kitty state of the active screen
//! only, so the inactive one cannot be compared). For a terminal that ever
//! held an image, cheap checks without an encode refuse the usual cases
//! first; then a scratch terminal restored from the pages is compared.
//!
//! A thawed terminal is a new libghostty instance: renderers and mouse
//! encoders rebind (new instance id) and [`super::TrackedScreenPoint`]s of the
//! old one resolve to `None`. Chrome keeps such state in user space only on
//! platforms without a kernel compressor; on macOS it relies on the kernel
//! (p07-memory.md, "Memory"), so this codec is used only where 112 measured
//! a gain of 2x or more over WKdm.
//!
//! libghostty-vt's own page compression ([`Terminal::compress_scrollback`],
//! LZ4 per history page, restored on access, terminal stays live) is the
//! cheaper first step, but it holds about 5x more: a filled 10 MB scrollback
//! (120x40, `cold_pages_compare_with_native_page_compression`) stays at
//! 1.0 MB resident for the corpus text and 2.2 MB for varied logs, against
//! 0.21 MB and 0.39 MB held here (release build, Linux). Its active page
//! stays uncompressed and its LZ4 sees one page of raw cells at a time. The
//! price here is the freeze (50-90 ms) and a full decode (9-10 ms) before
//! any read, where a read of native compressed pages costs 30-40 us for the
//! viewport.

use std::ffi::c_void;
use std::io::{Read as _, Write as _};
use std::ptr;
use std::sync::atomic::Ordering;

use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;

use super::{
    Callbacks, KittyReplayState, NEXT_TERMINAL_ID, SNAPSHOT_CONTINUATION_MAX_BYTES, Screen,
    Terminal, callbacks, configure_kitty_graphics, sys,
};
use crate::{Error, KittyGraphicsSnapshot, Result, check, kitty};

/// Settings this wrapper writes to libghostty-vt that GHOSTSNP does not
/// carry. Their setters record them here; a thaw writes them again.
#[derive(Debug, Default)]
pub(super) struct RawSettings {
    pub(super) terminfo_name: Option<Box<str>>,
    pub(super) clipboard_reads_deferred: bool,
}

/// Why [`Terminal::into_cold`] refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColdPagesError {
    /// A chunked Kitty upload is being assembled; the replay stream drops it.
    KittyUploadInProgress,
    /// Clipboard reads are deferred to an owner; pending tokens would be lost.
    ClipboardReadsDeferred,
    /// The Kitty replay stream would not restore every image and placement.
    KittyNotReplayable,
    /// libghostty-vt failed (for example an unfinished sequence longer than
    /// [`crate::SNAPSHOT_CONTINUATION_MAX_BYTES`] cannot be encoded).
    Vt(Error),
}

impl std::fmt::Display for ColdPagesError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::KittyUploadInProgress => write!(f, "cold pages: Kitty upload in progress"),
            Self::ClipboardReadsDeferred => write!(f, "cold pages: clipboard reads deferred"),
            Self::KittyNotReplayable => write!(f, "cold pages: Kitty state not replayable"),
            Self::Vt(error) => write!(f, "cold pages: {error}"),
        }
    }
}

impl std::error::Error for ColdPagesError {}

impl From<Error> for ColdPagesError {
    fn from(error: Error) -> Self {
        Self::Vt(error)
    }
}

/// [`Terminal::into_cold`] refused: the terminal, unchanged, and the reason.
pub struct ColdRefused {
    pub terminal: Terminal,
    pub reason: ColdPagesError,
}

impl std::fmt::Debug for ColdRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ColdRefused").field("reason", &self.reason).finish_non_exhaustive()
    }
}

/// [`ColdTerminal::thaw`] failed: the cold terminal, unchanged, and the error.
pub struct ThawFailed {
    pub cold: ColdTerminal,
    pub error: Error,
}

impl std::fmt::Debug for ThawFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThawFailed").field("error", &self.error).finish_non_exhaustive()
    }
}

/// What a cold terminal holds in place of its libghostty terminal.
struct ColdPages {
    /// zlib of the GHOSTSNP COMPLETE snapshot.
    snapshot: Box<[u8]>,
    /// Bytes of the snapshot before compression.
    snapshot_len: u64,
    /// libghostty's Kitty replay stream (no byte cap).
    kitty_replay: Box<[u8]>,
    /// Kitty limits and implicit image-ID cursors.
    kitty_state: KittyReplayState,
    /// Rows below a scrolled-back viewport (GHOSTSNP restores at the bottom).
    rows_below_viewport: u64,
}

/// A terminal whose libghostty state is compressed. Nothing can read it
/// until [`ColdTerminal::thaw`].
pub struct ColdTerminal {
    /// The wrapper with a NULL libghostty handle (see [`Terminal::release_raw`]).
    shell: Terminal,
    pages: ColdPages,
}

impl std::fmt::Debug for ColdTerminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ColdTerminal")
            .field("snapshot_bytes", &self.pages.snapshot_len)
            .field("held_bytes", &self.held_bytes())
            .finish_non_exhaustive()
    }
}

impl ColdTerminal {
    /// Restore the terminal. On failure the cold terminal comes back
    /// unchanged, so the caller can retry (for example after memory frees).
    pub fn thaw(mut self) -> std::result::Result<Terminal, Box<ThawFailed>> {
        match self.shell.adopt_cold(&self.pages) {
            Ok(()) => Ok(self.shell),
            Err(error) => {
                self.shell.release_raw();
                Err(Box::new(ThawFailed { cold: self, error }))
            }
        }
    }

    /// Bytes this cold terminal holds for the libghostty state.
    pub fn held_bytes(&self) -> usize {
        self.pages.snapshot.len() + self.pages.kitty_replay.len()
    }

    /// Bytes of the compressed snapshot.
    pub fn compressed_snapshot_bytes(&self) -> usize {
        self.pages.snapshot.len()
    }

    /// Bytes of the snapshot before compression.
    pub fn snapshot_bytes(&self) -> u64 {
        self.pages.snapshot_len
    }
}

/// What one [`Terminal::compress_scrollback`] pass left to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollbackCompression {
    /// This platform cannot free memory by compressing pages.
    Unsupported,
    /// More incremental work remains while the terminal stays idle.
    Pending,
    /// Nothing more to do until the terminal changes.
    Complete,
}

/// Page memory of both screens (`GhosttyTerminalMemoryUsage`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageMemory {
    /// Physical bytes of the pages; a compressed page counts its compressed size.
    pub resident_bytes: u64,
    /// Bytes of compressed page data, included in `resident_bytes`.
    pub compressed_bytes: u64,
    /// Pages, compressed ones included.
    pub pages: u64,
    /// Pages that are compressed.
    pub compressed_pages: u64,
    /// Kitty image bytes of the primary and the alternate screen.
    pub image_bytes: (u64, u64),
}

impl Terminal {
    /// Names the terminfo entry this terminal's program runs as (its TERM),
    /// which an XTGETTCAP "TN" query reports, as Ghostty does. An empty name
    /// leaves the query unanswered; libghostty refuses names over 128 bytes.
    pub fn set_terminfo_name(&mut self, name: &str) -> Result<()> {
        let value = sys::GhosttyString { ptr: name.as_ptr(), len: name.len() };
        // SAFETY: libghostty copies the string before the call returns.
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_TERMINFO_NAME,
                (&value as *const sys::GhosttyString).cast(),
            )
        })?;
        self.raw_settings.terminfo_name = (!name.is_empty()).then(|| name.into());
        Ok(())
    }

    /// Compress this terminal (see the module documentation). Call it only
    /// for a terminal nobody reads: a thaw costs a full decode.
    pub fn into_cold(mut self) -> std::result::Result<ColdTerminal, Box<ColdRefused>> {
        match self.cold_pages() {
            Ok(pages) => {
                self.release_raw();
                Ok(ColdTerminal { shell: self, pages })
            }
            Err(reason) => Err(Box::new(ColdRefused { terminal: self, reason })),
        }
    }

    fn cold_pages(&self) -> std::result::Result<ColdPages, ColdPagesError> {
        if self.kitty_upload_in_progress() {
            return Err(ColdPagesError::KittyUploadInProgress);
        }
        if self.raw_settings.clipboard_reads_deferred {
            return Err(ColdPagesError::ClipboardReadsDeferred);
        }
        // Zero: the image storage of both screens never changed, so the
        // replay stream (resets and cursors) is exact without a check.
        let kitty_changed = self.kitty_image_generation()? != 0;
        if kitty_changed {
            self.precheck_kitty()?;
        }
        let (snapshot, snapshot_len) = deflate_snapshot(self.raw)?;
        let (kitty_replay, _) = self.encode_kitty_replay(u64::MAX)?;
        let rows_below_viewport = self
            .scrollbar()
            .map_or(0, |bar| bar.total.saturating_sub(bar.offset).saturating_sub(bar.len));
        let pages = ColdPages {
            snapshot,
            snapshot_len,
            kitty_replay: kitty_replay.into_boxed_slice(),
            kitty_state: self.kitty_replay_state(0)?,
            rows_below_viewport,
        };
        if kitty_changed {
            self.check_kitty_replay(&pages)?;
        }
        Ok(pages)
    }

    /// Refusals found without an encode. libghostty-vt reads the Kitty state
    /// of the active screen only, so the inactive screen must hold no image:
    /// its placements cannot be compared, and the replay drops some (one only
    /// in the primary scrollback while the alternate screen is active).
    fn precheck_kitty(&self) -> std::result::Result<(), ColdPagesError> {
        let (primary, alternate) = self.page_memory()?.image_bytes;
        let inactive = match self.active_screen() {
            Screen::Primary => alternate,
            Screen::Alternate => primary,
        };
        if inactive > 0 || kitty::active_scene_drops_from_replay(self)? {
            return Err(ColdPagesError::KittyNotReplayable);
        }
        Ok(())
    }

    /// Restore `pages` into a scratch terminal and compare its Kitty state:
    /// the replay stream it encodes, the image bytes of each screen (an
    /// image the stream sent as metadata holds none) and every placement of
    /// the active screen, scrollback included. The stream must also store no
    /// image on the inactive screen: one without pixels, which the precheck
    /// cannot see, can still hold placements the replay drops.
    fn check_kitty_replay(&self, pages: &ColdPages) -> std::result::Result<(), ColdPagesError> {
        let inactive = match self.active_screen() {
            Screen::Primary => REPLAY_SCREEN_ALTERNATE,
            Screen::Alternate => REPLAY_SCREEN_PRIMARY,
        };
        if replay_stores_image_on(&pages.kitty_replay, inactive) {
            return Err(ColdPagesError::KittyNotReplayable);
        }
        let mut scratch = Terminal::new(1, 1, 0, Callbacks::default())?;
        scratch.release_raw();
        if scratch.adopt_cold(pages).is_err() {
            return Err(ColdPagesError::KittyNotReplayable);
        }
        let same = scratch.encode_kitty_replay(u64::MAX)?.0[..] == pages.kitty_replay[..]
            && scratch.page_memory()?.image_bytes == self.page_memory()?.image_bytes
            && kitty_scene(scratch.kitty_graphics_snapshot()?)
                == kitty_scene(self.kitty_graphics_snapshot()?);
        if same { Ok(()) } else { Err(ColdPagesError::KittyNotReplayable) }
    }

    /// Page memory of both screens.
    pub fn page_memory(&self) -> Result<PageMemory> {
        let usage = self.memory_usage()?;
        let (primary, alternate) = (usage.primary, usage.alternate);
        Ok(PageMemory {
            resident_bytes: primary.resident_bytes + alternate.resident_bytes,
            compressed_bytes: primary.compressed_bytes + alternate.compressed_bytes,
            pages: primary.pages + alternate.pages,
            compressed_pages: primary.compressed_pages + alternate.compressed_pages,
            image_bytes: (primary.image_bytes, alternate.image_bytes),
        })
    }

    /// libghostty-vt's own scrollback compression: each history page is
    /// compressed in place and restored when something reads it, so the
    /// terminal stays live. `full` does every page in one call; otherwise
    /// one bounded step for an idle callback.
    pub fn compress_scrollback(&mut self, full: bool) -> Result<ScrollbackCompression> {
        let mode = if full {
            sys::GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL
        } else {
            sys::GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL
        };
        let mut result = sys::GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED;
        // SAFETY: `raw` is this wrapper's live terminal, serialized by
        // `&mut self`; the out-pointer is valid for the call.
        check(unsafe { sys::ghostty_terminal_compress(self.raw, mode, &mut result) })?;
        Ok(match result {
            sys::GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING => ScrollbackCompression::Pending,
            sys::GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE => ScrollbackCompression::Complete,
            _ => ScrollbackCompression::Unsupported,
        })
    }

    /// Free the libghostty terminal and everything that points into it. The
    /// handle is NULL afterwards; every libghostty call the wrapper's Drop
    /// makes accepts NULL as a no-op.
    fn release_raw(&mut self) {
        self.history_markers.release();
        // SAFETY: `raw` is this wrapper's live terminal or NULL. The anchor
        // belongs to it and is freed first; the trampolines are cleared
        // before the terminal is freed, so none can run on freed hooks.
        unsafe {
            sys::ghostty_tracked_grid_ref_free(self.history_anchor);
            if !self.raw.is_null() {
                callbacks::uninstall(self.raw);
            }
            sys::ghostty_terminal_free(self.raw);
        }
        self.history_anchor = ptr::null_mut();
        self.raw = ptr::null_mut();
        // Keyed by image generations of the freed terminal; the restored one
        // numbers its images again.
        self.kitty_replay_pixel_cache.0.clear();
    }

    /// Decode `pages` into a new libghostty terminal owned by this wrapper,
    /// whose handle is NULL. On error the handle may be set; the caller
    /// releases it.
    fn adopt_cold(&mut self, pages: &ColdPages) -> Result<()> {
        let raw = inflate_terminal(&pages.snapshot)?;
        self.raw = raw;
        self.instance_id = NEXT_TERMINAL_ID.fetch_add(1, Ordering::Relaxed);
        // SAFETY: `hooks` is heap-pinned for the wrapper's lifetime, and
        // Drop and `release_raw` uninstall the trampolines before the
        // terminal is freed.
        unsafe { callbacks::install(raw, &mut self.hooks) };
        configure_kitty_graphics(raw)?;
        if let Some(name) = self.raw_settings.terminfo_name.clone() {
            self.set_terminfo_name(&name)?;
        }
        // Limits first: the replay is admitted under them, as the source's
        // images were.
        self.set_kitty_graphics_limits(pages.kitty_state.limits)?;
        if !pages.kitty_replay.is_empty() {
            self.apply_kitty_replay(&pages.kitty_replay)?;
        }
        self.set_kitty_image_id_cursors(pages.kitty_state.next_image_ids)?;
        if pages.rows_below_viewport > 0 {
            let rows = isize::try_from(pages.rows_below_viewport).unwrap_or(isize::MAX);
            self.scroll_delta(-rows);
        }
        self.reset_history_anchor();
        Ok(())
    }
}

/// Values of the replay stream's private screen key `E`
/// (`ghostty_terminal_kitty_replay_encode`).
const REPLAY_SCREEN_PRIMARY: u8 = b'0';
const REPLAY_SCREEN_ALTERNATE: u8 = b'1';

/// Whether `stream` transmits an image (`a=t`, with or without pixels) to
/// `screen`. Every command is `ESC _ G <keys> [; payload] ESC \`; base64
/// payloads hold no ESC, and continuation chunks carry no `a=`.
fn replay_stores_image_on(stream: &[u8], screen: u8) -> bool {
    let screen_key = [b'E', b'=', screen];
    stream.split(|&byte| byte == 0x1b).filter_map(|part| part.strip_prefix(b"_G")).any(|command| {
        let keys = command.split(|&byte| byte == b';').next().unwrap_or_default();
        let (mut transmit, mut on_screen) = (false, false);
        for key in keys.split(|&byte| byte == b',') {
            transmit |= key == b"a=t";
            on_screen |= key == screen_key;
        }
        transmit && on_screen
    })
}

/// Images and placements without the process-local generations.
fn kitty_scene(mut snapshot: KittyGraphicsSnapshot) -> KittyGraphicsSnapshot {
    snapshot.generation = 0;
    for image in &mut snapshot.images {
        image.generation = 0;
    }
    snapshot
}

struct DeflateSink {
    encoder: ZlibEncoder<Vec<u8>>,
    len: u64,
}

unsafe extern "C" fn deflate_write(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    // SAFETY: `userdata` is the DeflateSink that `deflate_snapshot` owns for
    // the duration of the encode, and `data` holds `len` readable bytes for
    // the duration of the callback (GhosttyWriterFn).
    let sink = unsafe { &mut *(userdata as *mut DeflateSink) };
    if len == 0 {
        return true;
    }
    // SAFETY: `len` is non-zero, and libghostty passes `len` readable bytes at
    // `data` for the duration of the callback.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    sink.len += len as u64;
    sink.encoder.write_all(bytes).is_ok()
}

/// Encode the COMPLETE snapshot of `raw` straight into zlib, so the
/// uncompressed snapshot never exists in memory.
fn deflate_snapshot(raw: sys::GhosttyTerminal) -> Result<(Box<[u8]>, u64)> {
    let mut sink =
        DeflateSink { encoder: ZlibEncoder::new(Vec::new(), Compression::default()), len: 0 };
    let writer = sys::GhosttyWriter {
        write: Some(deflate_write),
        userdata: (&mut sink as *mut DeflateSink).cast(),
    };
    // SAFETY: `raw` is the caller's live terminal, serialized by `&self`;
    // `sink` outlives the call.
    check(unsafe { sys::ghostty_snapshot_encode(raw, writer) })?;
    let compressed = sink.encoder.finish().map_err(|_| Error::OutOfMemory)?;
    Ok((compressed.into_boxed_slice(), sink.len))
}

unsafe extern "C" fn inflate_read(
    userdata: *mut c_void,
    buffer: *mut u8,
    capacity: usize,
    out_read: *mut usize,
) -> bool {
    // SAFETY: `userdata` is the ZlibDecoder that `inflate_terminal` owns
    // until it frees the decoder; `buffer` has `capacity` writable bytes and
    // `out_read` is valid for the duration of the callback (GhosttyReaderFn).
    let source = unsafe { &mut *(userdata as *mut ZlibDecoder<&[u8]>) };
    // SAFETY: libghostty passes `capacity` writable bytes at `buffer` for the
    // duration of the callback (GhosttyReaderFn).
    let buffer = unsafe { std::slice::from_raw_parts_mut(buffer, capacity) };
    match source.read(buffer) {
        Ok(read) => {
            // SAFETY: libghostty passes a writable `out_read` for the callback.
            unsafe { *out_read = read };
            true
        }
        Err(_) => false,
    }
}

/// Decode a zlib GHOSTSNP COMPLETE snapshot into a new terminal, inflating
/// as the decoder reads. The terminal keeps tracking its unfinished
/// sequence with the same limit [`Terminal::new`] sets.
fn inflate_terminal(compressed: &[u8]) -> Result<sys::GhosttyTerminal> {
    let mut source = ZlibDecoder::new(compressed);
    let reader = sys::GhosttyReader {
        read: Some(inflate_read),
        userdata: (&mut source as *mut ZlibDecoder<&[u8]>).cast(),
    };
    let mut decoder: sys::GhosttySnapshotDecoder = ptr::null_mut();
    // SAFETY: `source` outlives the decoder, which is freed below.
    check(unsafe { sys::ghostty_snapshot_decoder_new(ptr::null(), &mut decoder, reader) })?;
    let max_continuation = SNAPSHOT_CONTINUATION_MAX_BYTES;
    let retain = true;
    let mut raw: sys::GhosttyTerminal = ptr::null_mut();
    // SAFETY: the option pointers have the documented input types (size_t,
    // bool) and outlive the calls; the decoder is freed exactly once.
    let result = check(unsafe {
        sys::ghostty_snapshot_decoder_set(
            decoder,
            sys::GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
            (&max_continuation as *const usize).cast(),
        )
    })
    .and_then(|()| {
        // SAFETY: `decoder` is live; RETAIN_CONTINUATION reads a bool from the live
        // `retain`.
        check(unsafe {
            sys::ghostty_snapshot_decoder_set(
                decoder,
                sys::GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
                (&retain as *const bool).cast(),
            )
        })
    })
    // SAFETY: `decoder` is live and `raw` a writable local.
    .and_then(|()| check(unsafe { sys::ghostty_snapshot_decoder_decode(decoder, &mut raw) }));
    // SAFETY: `decoder` came from decoder_new above and is freed once here,
    // after its last use; `source` outlives it.
    unsafe { sys::ghostty_snapshot_decoder_free(decoder) };
    result.map(|()| raw)
}
