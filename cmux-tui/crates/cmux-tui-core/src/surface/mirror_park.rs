//! A hosted terminal's daemon-side mirror, parked while nobody looks.
//!
//! The daemon keeps a parsed copy of every hosted terminal. A terminal whose
//! host link went quiet and that has no viewer needs none of it: the mirror
//! is written down as the same snapshot a host sends at reconnect (a bounded,
//! theme-portable VT replay plus the color overrides) and the parsed terminal
//! is dropped: a parked mirror holds no Ghostty terminal, so no page pool
//! (about 2 MB mapped each). The first lock afterwards
//! rebuilds it from that snapshot the way a reconnect does, under the
//! terminal lock alone, so every caller of `lock`/`try_lock` sees the real
//! terminal and none of them changed.
//!
//! An ended terminal whose tab stays (a parked or kept tab, an exited pane,
//! a never-started lazy tab) parks the same way once nobody views it, with
//! its last render frame: nothing writes to it again, and a thousand of them
//! kept their whole parsed screens (infinite-items).
//!
//! The snapshot lives in the daemon rather than being asked of the host at
//! attach: a lock site cannot wait on a host round trip under the lock ranks,
//! a reconnect has side effects (journal gap, resize broadcast), and a host
//! whose shell exited while parked could no longer answer.

use super::*;
use ghostty_vt::{TerminalColorOverrides, VtReplay};
use std::ops::{Deref, DerefMut};
use std::sync::atomic::AtomicUsize;
use std::sync::{LockResult, PoisonError, TryLockResult};

use crate::lock_rank::{LockRank, RankedGuard, RankedMutex};
use color_overrides::terminal_color_override_full_state;
use options::replace_ghostty_cursor_defaults;

/// What a parked mirror is rebuilt from.
struct ParkedMirror {
    replay: VtReplay,
    colors: TerminalColorOverrides,
    geometry: PtyGeometry,
    scrollback: usize,
    defaults: DefaultColors,
    callbacks: Callbacks,
    title_changed: Arc<AtomicBool>,
    look: ParkedLook,
}

/// What a look at the screen reads, written down at the park: nothing
/// changes a parked screen, so a reader that only asks this (the output
/// store's snapshot pass deciding that no snapshot is due) rebuilds nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ParkedLook {
    /// The output store's content digest of the screen (`None`: unreadable).
    pub(crate) digest: Option<u64>,
    /// Columns and rows.
    pub(crate) size: (u16, u16),
    /// The alternate screen is active.
    pub(crate) alternate: bool,
    /// A Kitty image upload was being assembled.
    pub(crate) upload: bool,
}

impl ParkedLook {
    fn of(term: &mut Terminal) -> Self {
        Self {
            digest: crate::output_store::snapshot::content_digest(term),
            size: (term.cols(), term.rows()),
            alternate: term.active_screen() != ghostty_vt::Screen::Primary,
            upload: term.kitty_upload_in_progress(),
        }
    }
}

/// What [`TerminalMirror::park`] needs from the reader that owns the mirror.
pub(super) struct ParkMirror<'a> {
    pub(super) geometry: PtyGeometry,
    pub(super) scrollback: usize,
    pub(super) defaults: DefaultColors,
    pub(super) callbacks: Callbacks,
    pub(super) title_changed: &'a Arc<AtomicBool>,
}

/// The `pty.term` lock, with a mirror that may be parked behind it.
pub(crate) struct TerminalMirror {
    /// `None` while parked: the parsed terminal is gone, `parked` holds its
    /// snapshot. Every guard handed out holds `Some`.
    term: RankedMutex<Option<Box<Terminal>>>,
    /// Only touched with `term` held.
    parked: Mutex<Option<ParkedMirror>>,
    /// The scrollback budget the terminal was made with, for parking an
    /// ended terminal, which has no reader to say it.
    scrollback: usize,
    /// Scratch terminals built for a look at the parked mirror.
    scratch_builds: AtomicUsize,
}

impl TerminalMirror {
    pub(crate) fn new(term: Box<Terminal>, scrollback: usize) -> Self {
        Self {
            term: RankedMutex::new(LockRank::Terminal, "pty.term", Some(term)),
            parked: Mutex::new(None),
            scrollback,
            scratch_builds: AtomicUsize::new(0),
        }
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<MirrorGuard<'_>> {
        match self.term.lock() {
            Ok(guard) => Ok(self.unparked(guard)),
            Err(poison) => Err(PoisonError::new(self.unparked(poison.into_inner()))),
        }
    }

    pub(crate) fn try_lock(&self) -> TryLockResult<MirrorGuard<'_>> {
        match self.term.try_lock() {
            Ok(guard) => Ok(self.unparked(guard)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(self.unparked(poison.into_inner()))))
            }
        }
    }

    /// Locks the mirror only while it is not parked; a parked one stays
    /// parked and gives `None`. Parking happens under this lock, so the
    /// answer cannot go stale before the caller reads the terminal.
    pub(crate) fn lock_unparked(&self) -> Option<MirrorGuard<'_>> {
        let guard = self.term.lock().unwrap_or_else(PoisonError::into_inner);
        guard.is_some().then_some(MirrorGuard { guard })
    }

    /// Runs `f` on the terminal and leaves a parked mirror parked. For
    /// readers that only look (the output store's snapshot of a log that
    /// went dirty just before the park): a lock would rebuild the mirror for
    /// good and undo the park.
    ///
    /// A parked mirror first gets `look` with what the park wrote down of
    /// its screen; an answer there is the answer, and nothing is rebuilt
    /// (a thousand parked tabs cost the pass nothing). Only when `look` needs
    /// the terminal itself (a snapshot replay) is a scratch terminal rebuilt
    /// for `f`, with the same [`ParkedLook`], and dropped after, so its page
    /// pool goes with it. A replay that cannot be rebuilt unparks, as a lock
    /// would.
    pub(crate) fn with_terminal_kept_parked<R>(
        &self,
        look: impl FnOnce(&ParkedLook) -> Option<R>,
        f: impl FnOnce(&mut Terminal, Option<&ParkedLook>) -> R,
    ) -> R {
        let mut guard = self.term.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(term) = guard.as_mut() {
            return f(term, None);
        }
        let parked = self.parked.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(seen) = parked.as_ref().map(|parked| parked.look) else {
            drop(parked);
            return f(&mut self.unparked(guard), None);
        };
        if let Some(answer) = look(&seen) {
            return answer;
        }
        self.scratch_builds.fetch_add(1, Ordering::Relaxed);
        let scratch = parked.as_ref().and_then(|parked| build(parked, Callbacks::default()).ok());
        drop(parked);
        match scratch {
            Some(mut scratch) => f(&mut scratch, Some(&seen)),
            None => f(&mut self.unparked(guard), None),
        }
    }

    /// Scratch terminals built so far for looks at the parked mirror.
    #[cfg(test)]
    pub(crate) fn scratch_builds(&self) -> usize {
        self.scratch_builds.load(Ordering::Relaxed)
    }

    fn unparked<'a>(&self, mut guard: RankedGuard<'a, Option<Box<Terminal>>>) -> MirrorGuard<'a> {
        if guard.is_none() {
            *guard = Some(self.unpark());
        }
        MirrorGuard { guard }
    }

    /// Whether the mirror is parked now. A lock rebuilds it.
    #[cfg(test)]
    pub(crate) fn is_parked(&self) -> bool {
        self.term.lock().unwrap_or_else(PoisonError::into_inner).is_none()
    }

    /// Writes the mirror down and drops it. Returns false (and keeps the
    /// mirror) when it is already parked or cannot be encoded.
    pub(super) fn park(&self, park: ParkMirror<'_>) -> bool {
        let Ok(mut slot) = self.term.lock() else { return false };
        let Some(term) = slot.as_mut() else { return false };
        let replay = match term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES) {
            Ok(replay) => replay,
            Err(_) => return false,
        };
        // Park only when the snapshot is the smaller copy: a replay near its
        // byte bound can outweigh a small screen.
        if !replay_pays(&replay, term.primary_resident_bytes()) {
            return false;
        }
        let colors = term.color_overrides();
        let look = ParkedLook::of(term);
        *self.parked.lock().unwrap_or_else(PoisonError::into_inner) = Some(ParkedMirror {
            replay,
            colors,
            geometry: park.geometry,
            scrollback: park.scrollback,
            defaults: park.defaults,
            callbacks: park.callbacks,
            title_changed: park.title_changed.clone(),
            look,
        });
        // The terminal and its page pool are freed here, under the lock.
        *slot = None;
        true
    }

    /// Rebuilds the parked terminal; the caller holds the (empty) slot.
    fn unpark(&self) -> Box<Terminal> {
        let Some(parked) = self.parked.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return Box::new(blank_terminal(None));
        };
        // Replaying the title must not read as a new title.
        let title_changed = parked.title_changed.clone();
        let was_changed = title_changed.load(Ordering::Relaxed);
        let fallback = (parked.geometry, parked.scrollback);
        let term = rebuild(parked).unwrap_or_else(|error| {
            eprintln!("cmux-tui: parked terminal mirror could not be rebuilt: {error:?}");
            blank_terminal(Some(fallback))
        });
        title_changed.store(was_changed, Ordering::Relaxed);
        Box::new(term)
    }
}

/// A held lock on an unparked mirror: derefs to the terminal like the
/// guard it wraps did.
pub(crate) struct MirrorGuard<'a> {
    guard: RankedGuard<'a, Option<Box<Terminal>>>,
}

impl Deref for MirrorGuard<'_> {
    type Target = Box<Terminal>;

    #[allow(
        clippy::expect_used,
        reason = "every MirrorGuard is built with Some: `unparked` fills the slot first, `lock_unparked` checks it"
    )]
    fn deref(&self) -> &Box<Terminal> {
        // crash-allow: every MirrorGuard is built with Some (`unparked` fills the slot first, `lock_unparked` checks it).
        self.guard.as_ref().expect("a mirror guard holds an unparked terminal")
    }
}

impl DerefMut for MirrorGuard<'_> {
    #[allow(
        clippy::expect_used,
        reason = "every MirrorGuard is built with Some: `unparked` fills the slot first, `lock_unparked` checks it"
    )]
    fn deref_mut(&mut self) -> &mut Box<Terminal> {
        // crash-allow: every MirrorGuard is built with Some (`unparked` fills the slot first, `lock_unparked` checks it).
        self.guard.as_mut().expect("a mirror guard holds an unparked terminal")
    }
}

/// Parking frees the terminal and keeps `replay`: worth it only when the
/// replay is smaller than what the terminal holds (`resident`: its primary
/// screen's page bytes; unknown counts as a page pool's first page).
fn replay_pays(replay: &VtReplay, resident: Option<u64>) -> bool {
    const PAGE_FLOOR: u64 = 64 * 1024;
    let replay_bytes = replay.bytes.len() + replay.pending_sequence.len();
    (replay_bytes as u64) < resident.unwrap_or(0).max(PAGE_FLOOR)
}

/// What a lock gets when a rebuild fails: an empty terminal at the size it
/// had, or one cell when even that fails, so no reader ever finds no
/// terminal.
#[allow(
    clippy::expect_used,
    reason = "a one-cell, no-scrollback terminal fails only when allocation fails, which aborts anyway"
)]
fn blank_terminal(size: Option<(PtyGeometry, usize)>) -> Terminal {
    size.and_then(|(geometry, scrollback)| {
        Terminal::new(geometry.cols, geometry.rows, scrollback, Callbacks::default()).ok()
    })
    .or_else(|| Terminal::new(1, 1, 0, Callbacks::default()).ok())
    // crash-allow: a one-cell, no-scrollback Ghostty terminal fails only when allocation fails, which aborts anyway.
    .expect("a one-cell terminal")
}

/// The reconnect recipe (`hosted_reader/reconnect.rs`) on a held snapshot.
fn rebuild(mut parked: ParkedMirror) -> ghostty_vt::Result<Terminal> {
    let callbacks = std::mem::take(&mut parked.callbacks);
    build(&parked, callbacks)
}

/// A terminal with the parked screen and history, reporting to `callbacks`.
fn build(parked: &ParkedMirror, callbacks: Callbacks) -> ghostty_vt::Result<Terminal> {
    let ParkedMirror { replay, colors, geometry, scrollback, defaults, .. } = parked;
    let (geometry, defaults) = (*geometry, *defaults);
    let mut term = Terminal::new(geometry.cols, geometry.rows, *scrollback, callbacks)?;
    term.resize(
        geometry.cols,
        geometry.rows,
        u32::from(geometry.cell_width),
        u32::from(geometry.cell_height),
    )?;
    term.replace_default_colors(defaults.fg, defaults.bg, defaults.cursor);
    term.set_default_palette(&defaults.palette);
    replace_ghostty_cursor_defaults(&mut term, defaults);
    term.apply_vt_replay_parts(&replay.bytes, &replay.kitty_image_aliases, replay.kitty_state)?;
    let color_delta = terminal_color_override_full_state(colors);
    if !color_delta.is_empty() {
        term.vt_write(&color_delta);
    }
    term.vt_write(&replay.pending_sequence);
    Ok(term)
}

impl PtySurface {
    /// An ended terminal's mirror parks once nobody views it: no reader
    /// writes to it again, and a kept or exited tab can sit for days. A
    /// shown tab locks it, which rebuilds it with the same screen and
    /// history. Returns whether it parked.
    pub(crate) fn park_exited_mirror(&self) -> bool {
        if !self.dead.load(Ordering::Acquire)
            || self.stream_progress.has_resource_waiters()
            || !self.taps.lock().map(|taps| taps.is_empty()).unwrap_or(false)
            || !self.render.lock().map(|render| render.taps.is_empty()).unwrap_or(false)
        {
            return false;
        }
        let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        // Geometry ranks before the terminal (as in `park_mirror`).
        let Ok(geometry) = self.geometry.lock() else { return false };
        // An ended terminal parses no more output: its rebuild needs no
        // reply, title, bell or status sink.
        let parked = self.term.park(ParkMirror {
            geometry: *geometry,
            scrollback: self.term.scrollback,
            defaults,
            callbacks: Callbacks::default(),
            title_changed: &Arc::new(AtomicBool::new(false)),
        });
        drop(geometry);
        // Its last frame (about 100 bytes a cell) goes too: an exited attach
        // builds one from the terminal first (`attach_render_stream`).
        if let Ok(mut render) = self.render.lock() {
            render.release_when_unviewed();
        }
        if parked
            && let Some(terminal_id) = self.terminal_public_id.as_deref()
            && let Some(mux) = self.mux.upgrade()
        {
            mux.output_store.forget_scrollback_budget(terminal_id);
        }
        parked
    }

    /// Nothing reads this terminal's mirror on its own: no attach or render
    /// viewer and no resource subscriber. Anyone who comes later locks the
    /// mirror, which rebuilds it.
    fn mirror_unviewed(&self) -> bool {
        !self.dead.load(Ordering::Acquire)
            && !self.stream_progress.has_resource_waiters()
            && self.taps.lock().map(|taps| taps.is_empty()).unwrap_or(false)
            && self.render.lock().map(|render| render.taps.is_empty()).unwrap_or(false)
    }
}

impl HostedReader {
    /// The reader goes idle behind its parked link: park the mirror too when
    /// nobody views it. Returns whether it parked.
    pub(super) fn park_mirror(&self, pty: &PtySurface) -> bool {
        if !pty.mirror_unviewed() {
            return false;
        }
        let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let callbacks = hosted_terminal_callbacks(
            &self.pending_bells,
            self.title_changed.clone(),
            pty.program_status_records(),
        );
        // Geometry ranks before the terminal: held across the park so a
        // resize cannot slip between the size read and the swap.
        let Ok(geometry) = pty.geometry.lock() else { return false };
        let parked = pty.term.park(ParkMirror {
            geometry: *geometry,
            scrollback: self.scrollback,
            defaults,
            callbacks,
            title_changed: &self.title_changed,
        });
        drop(geometry);
        if parked
            && let Some(terminal_id) = pty.terminal_public_id.as_deref()
            && let Some(mux) = self.mux.upgrade()
        {
            // The rebuilt mirror starts at the configured scrollback: the
            // store's budget measures it afresh when it grows.
            mux.output_store.forget_scrollback_budget(terminal_id);
        }
        parked
    }

    /// The reader reads again after its mirror was parked: rebuild it now
    /// (output is coming) and take the rebuilt parser's revisions as the
    /// applied ones, since a rebuild is no color change.
    pub(super) fn mirror_resumed(&mut self, pty: &PtySurface) {
        let Ok(term) = pty.term.lock() else { return };
        self.applied_color_revision = term.color_revision();
        self.applied_cursor_activity = term.cursor_activity().ok();
    }
}

impl Surface {
    /// See [`PtySurface::park_exited_mirror`].
    pub(crate) fn park_exited_mirror(&self) -> bool {
        self.as_pty().is_some_and(PtySurface::park_exited_mirror)
    }

    /// Runs `f` on the terminal unless its mirror is parked, which it leaves
    /// parked. For upkeep that must not rebuild what nobody views (the
    /// scrollback budget); `None` for a parked mirror or a browser.
    pub(crate) fn try_with_live_terminal<R>(
        &self,
        f: impl FnOnce(&mut Terminal) -> R,
    ) -> Option<R> {
        let mut term = self.as_pty()?.term.lock_unparked()?;
        Some(f(&mut term))
    }

    /// The terminal's daemon mirror is parked (rebuilt by the next lock).
    #[cfg(test)]
    pub(crate) fn mirror_parked(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.term.is_parked())
    }

    /// Scratch terminals built for looks at this terminal's parked mirror.
    #[cfg(test)]
    pub(crate) fn mirror_scratch_builds(&self) -> usize {
        self.as_pty().map_or(0, |pty| pty.term.scratch_builds())
    }
}

#[cfg(test)]
#[path = "mirror_park_tests.rs"]
mod tests;
