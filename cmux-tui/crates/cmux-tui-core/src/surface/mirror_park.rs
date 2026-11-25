//! A hosted terminal's daemon-side mirror, parked while nobody looks.
//!
//! The daemon keeps a parsed copy of every hosted terminal. A terminal whose
//! host link went quiet and that has no viewer needs none of it: the mirror
//! is written down as the same snapshot a host sends at reconnect (a bounded,
//! theme-portable VT replay plus the color overrides) and swapped for a
//! one-screen placeholder with no scrollback. The first lock afterwards
//! rebuilds it from that snapshot the way a reconnect does, under the
//! terminal lock alone, so every caller of `lock`/`try_lock` sees the real
//! terminal and none of them changed.
//!
//! The snapshot lives in the daemon rather than being asked of the host at
//! attach: a lock site cannot wait on a host round trip under the lock ranks,
//! a reconnect has side effects (journal gap, resize broadcast), and a host
//! whose shell exited while parked could no longer answer.

use super::*;
use ghostty_vt::{TerminalColorOverrides, VtReplay};
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
    term: RankedMutex<Box<Terminal>>,
    /// Only touched with `term` held.
    parked: Mutex<Option<ParkedMirror>>,
    is_parked: AtomicBool,
}

impl TerminalMirror {
    pub(crate) fn new(term: Box<Terminal>) -> Self {
        Self {
            term: RankedMutex::new(LockRank::Terminal, "pty.term", term),
            parked: Mutex::new(None),
            is_parked: AtomicBool::new(false),
        }
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<RankedGuard<'_, Box<Terminal>>> {
        match self.term.lock() {
            Ok(mut guard) => {
                self.unpark(&mut guard);
                Ok(guard)
            }
            Err(poison) => {
                let mut guard = poison.into_inner();
                self.unpark(&mut guard);
                Err(PoisonError::new(guard))
            }
        }
    }

    pub(crate) fn try_lock(&self) -> TryLockResult<RankedGuard<'_, Box<Terminal>>> {
        match self.term.try_lock() {
            Ok(mut guard) => {
                self.unpark(&mut guard);
                Ok(guard)
            }
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                let mut guard = poison.into_inner();
                self.unpark(&mut guard);
                Err(TryLockError::Poisoned(PoisonError::new(guard)))
            }
        }
    }

    /// Whether the mirror is parked now. A lock rebuilds it.
    pub(crate) fn is_parked(&self) -> bool {
        self.is_parked.load(Ordering::Acquire)
    }

    /// Writes the mirror down and drops it. Returns false (and keeps the
    /// mirror) when it is already parked or cannot be encoded.
    pub(super) fn park(&self, park: ParkMirror<'_>) -> bool {
        let Ok(mut term) = self.term.lock() else { return false };
        if self.is_parked() {
            return false;
        }
        let replay = match term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES) {
            Ok(replay) => replay,
            Err(_) => return false,
        };
        let colors = term.color_overrides();
        let Ok(placeholder) =
            Terminal::new(park.geometry.cols, park.geometry.rows, 0, Callbacks::default())
        else {
            return false;
        };
        *self.parked.lock().unwrap_or_else(PoisonError::into_inner) = Some(ParkedMirror {
            replay,
            colors,
            geometry: park.geometry,
            scrollback: park.scrollback,
            defaults: park.defaults,
            callbacks: park.callbacks,
            title_changed: park.title_changed.clone(),
        });
        // The old mirror is freed here, under the lock, before anyone can
        // see the placeholder.
        **term = placeholder;
        self.is_parked.store(true, Ordering::Release);
        true
    }

    fn unpark(&self, term: &mut Box<Terminal>) {
        if !self.is_parked() {
            return;
        }
        let Some(parked) = self.parked.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            self.is_parked.store(false, Ordering::Release);
            return;
        };
        self.is_parked.store(false, Ordering::Release);
        // Replaying the title must not read as a new title.
        let title_changed = parked.title_changed.clone();
        let was_changed = title_changed.load(Ordering::Relaxed);
        match rebuild(parked) {
            Ok(rebuilt) => **term = rebuilt,
            Err(error) => {
                eprintln!("cmux-tui: parked terminal mirror could not be rebuilt: {error:?}");
            }
        }
        title_changed.store(was_changed, Ordering::Relaxed);
    }
}

/// The reconnect recipe (`hosted_reader/reconnect.rs`) on a held snapshot.
fn rebuild(parked: ParkedMirror) -> ghostty_vt::Result<Terminal> {
    let ParkedMirror { replay, colors, geometry, scrollback, defaults, callbacks, .. } = parked;
    let mut term = Terminal::new(geometry.cols, geometry.rows, scrollback, callbacks)?;
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
    let color_delta = terminal_color_override_full_state(&colors);
    if !color_delta.is_empty() {
        term.vt_write(&color_delta);
    }
    term.vt_write(&replay.pending_sequence);
    Ok(term)
}

impl PtySurface {
    /// The terminal has ended and no reader can rebuild it from a host. Keep
    /// the bounded replay and zero-scrollback placeholder so the final tab
    /// still rebuilds its screen on the next lock without retaining the full
    /// VT runtime.
    pub(super) fn park_dead_mirror(&self) -> bool {
        let Some(mux) = self.mux.upgrade() else { return false };
        let defaults = mux.default_colors();
        let scrollback =
            mux.surface_options.lock().unwrap_or_else(PoisonError::into_inner).scrollback;
        let title_changed = Arc::new(AtomicBool::new(false));
        let Ok(geometry) = self.geometry.lock() else { return false };
        self.term.park(ParkMirror {
            geometry: *geometry,
            scrollback,
            defaults,
            callbacks: Callbacks::default(),
            title_changed: &title_changed,
        })
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
    /// The terminal's daemon mirror is parked (rebuilt by the next lock).
    pub(crate) fn mirror_parked(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.term.is_parked())
    }
}

#[cfg(test)]
#[path = "mirror_park_tests.rs"]
mod tests;
