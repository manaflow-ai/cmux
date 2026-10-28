//! The departed-view grid hold: after a phone or tablet view leaves, the PTY
//! grid may shrink but not grow for `DEPARTED_GRID_HOLD`, so a reattach finds
//! the grid it left (docs/shared-terminal-sizing.md, "Phone viewers").

use super::*;

impl Mux {
    /// The grid to apply for an engine decision `decided`. When a phone or
    /// tablet view has departed since the last decision and the decision would grow the grid,
    /// the grid keeps its size for `DEPARTED_GRID_HOLD` (it may still shrink):
    /// a phone whose link drops and reattaches finds the grid it left, so the
    /// PTY is not resized twice and an inline TUI (Codex) does not rebuild its
    /// scrollback for a width change that undoes itself (cnx-ios termqa
    /// V2-5). A disconnect by another participant ends the hold at once
    /// (`release_terminal_grid_holds`).
    pub(in crate::mux) fn terminal_grid_target(
        &self,
        entry: &TerminalSizingEntry,
        runtime: SurfaceId,
        decided: (u16, u16),
    ) -> (u16, u16) {
        let now = Instant::now();
        let present = entry
            .engine
            .participant_ids()
            .map(|id| {
                let participant = entry.engine.participant(id);
                let seat = AppliedSeat {
                    handheld: participant
                        .is_some_and(|participant| participant.device_kind.is_handheld()),
                    sized: participant.is_some_and(|participant| participant.viewport.is_some()),
                };
                (id.to_owned(), seat)
            })
            .collect::<std::collections::BTreeMap<String, AppliedSeat>>();
        let (departed, returned) = {
            let previous = entry.applied_participants.borrow();
            let departed =
                previous.iter().any(|(id, seat)| seat.handheld && !present.contains_key(id));
            // A phone or tablet view with a size that was not one before: a
            // handheld came (back). Its own size counts now, larger or not; a
            // hold kept for the view it replaces would cap it for the rest of
            // the grace and resize the PTY a second time when that ends.
            let returned = present.iter().any(|(id, seat)| {
                seat.handheld
                    && seat.sized
                    && !previous.get(id).is_some_and(|previous| previous.sized)
            });
            (departed, returned)
        };
        *entry.applied_participants.borrow_mut() = present;
        if returned {
            entry.hold.set(None);
        }
        let grace = departed_grid_hold();
        if departed
            && !returned
            && !grace.is_zero()
            && let Some(applied) = entry.applied.get()
            && (decided.0 > applied.0 || decided.1 > applied.1)
            && self.schedule_terminal_grid_hold_end(runtime, grace)
        {
            let held = match entry.hold.get() {
                Some((held, until)) if now < until => {
                    (held.0.min(applied.0), held.1.min(applied.1))
                }
                _ => applied,
            };
            entry.hold.set(Some((held, now + grace)));
        }
        let target = match entry.hold.get() {
            Some((held, until)) if now < until => (decided.0.min(held.0), decided.1.min(held.1)),
            Some(_) => {
                entry.hold.set(None);
                decided
            }
            None => decided,
        };
        self.cap_to_fixed_grid_handhelds(entry, target)
    }

    /// What `terminal_grid_target` changes besides its result, to put back
    /// when the resize it decided fails.
    pub(in crate::mux) fn terminal_grid_hold_snapshot(
        entry: &TerminalSizingEntry,
    ) -> TerminalGridHoldSnapshot {
        TerminalGridHoldSnapshot {
            participants: entry.applied_participants.borrow().clone(),
            hold: entry.hold.get(),
        }
    }

    pub(in crate::mux) fn restore_terminal_grid_hold(
        entry: &TerminalSizingEntry,
        snapshot: TerminalGridHoldSnapshot,
    ) {
        *entry.applied_participants.borrow_mut() = snapshot.participants;
        entry.hold.set(snapshot.hold);
    }

    /// Ends the hold at its deadline (an intentional bounded delay, the
    /// hold's own). False when no timer can run (the mux is not owned yet, or
    /// no thread): then no hold is set, since nothing would end it.
    fn schedule_terminal_grid_hold_end(&self, runtime: SurfaceId, grace: Duration) -> bool {
        let Some(mux) = self.exit_settles.owner() else { return false };
        let mux = Arc::downgrade(&mux);
        std::thread::Builder::new()
            .name("terminal-grid-hold".into())
            .spawn(move || {
                std::thread::sleep(grace);
                if let Some(mux) = mux.upgrade() {
                    mux.end_expired_terminal_grid_hold(runtime);
                }
            })
            .is_ok()
    }

    fn end_expired_terminal_grid_hold(&self, runtime: SurfaceId) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(entry) = sizing.terminal_sizing.get(&runtime) else { return };
        if entry.hold.get().is_some_and(|(_, until)| Instant::now() < until) {
            return; // Extended by a later departure; its own timer ends it.
        }
        self.apply_terminal_grid(&sizing, runtime);
        drop(sizing);
        self.publish_size_states();
    }

    /// The terminals (placements) `client` has a view of, for
    /// `release_terminal_grid_holds` after it is disconnected.
    pub(crate) fn terminal_placements_of_client(&self, client: u64) -> Vec<SurfaceId> {
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        sizing
            .surfaces
            .iter()
            .filter(|(_, viewers)| viewers.contains_key(&client))
            .map(|(placement, _)| *placement)
            .collect()
    }

    /// End the grid holds of the terminals shown at `placements` now: a
    /// participant disconnected a view of them on purpose, so their grids
    /// follow the remaining views at once. Other terminals keep theirs.
    pub(crate) fn release_terminal_grid_holds(&self, placements: &[SurfaceId]) {
        if placements.is_empty() {
            return;
        }
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let held = sizing
            .terminal_sizing
            .iter()
            .filter(|(runtime, entry)| {
                placements.iter().any(|placement| {
                    *placement == **runtime
                        || entry.placements.contains(placement)
                        || sizing.terminal_runtime_by_placement.get(placement) == Some(*runtime)
                })
            })
            .filter(|(_, entry)| entry.hold.take().is_some())
            .map(|(runtime, _)| *runtime)
            .collect::<Vec<_>>();
        for runtime in held {
            self.apply_terminal_grid(&sizing, runtime);
        }
        drop(sizing);
        self.publish_size_states();
    }
}

impl Mux {
    /// Ends the grid hold of the terminal shown at `placement` when it is the
    /// hold a view that left at `left_at` set (or an older one): the hold
    /// ends no later than `left_at` plus the grace. A later departure's hold
    /// (a phone that reattached and dropped again) runs on. The size lease
    /// calls this when a departed view's lease ends.
    pub(crate) fn end_terminal_grid_hold_of_departure(
        &self,
        placement: SurfaceId,
        left_at: Instant,
    ) {
        // A hold set while the departure was being recorded may end a moment later.
        let latest = left_at + departed_grid_hold() + Duration::from_millis(250);
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let held = sizing
            .terminal_sizing
            .iter()
            .filter(|(runtime, entry)| {
                placement == **runtime
                    || entry.placements.contains(&placement)
                    || sizing.terminal_runtime_by_placement.get(&placement) == Some(*runtime)
            })
            .filter(|(_, entry)| match entry.hold.get() {
                Some((_, until)) if until <= latest => {
                    entry.hold.set(None);
                    true
                }
                _ => false,
            })
            .map(|(runtime, _)| *runtime)
            .collect::<Vec<_>>();
        for runtime in held {
            self.apply_terminal_grid(&sizing, runtime);
        }
        drop(sizing);
        self.publish_size_states();
    }
}

/// How long a departed view holds the grid from growing (see
/// `Mux::terminal_grid_target`). Long enough for a phone's link drop,
/// transport switch or brief app switch; short enough that a Mac whose phone
/// left gets its own width back soon.
const DEPARTED_GRID_HOLD: Duration = Duration::from_secs(30);
/// Debug builds only: the hold in milliseconds (0 turns it off), read once.
/// Release builds ignore it.
#[cfg(debug_assertions)]
const DEPARTED_GRID_HOLD_ENV: &str = "CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS";

fn departed_grid_hold() -> Duration {
    #[cfg(debug_assertions)]
    {
        static HOLD: OnceLock<Duration> = OnceLock::new();
        *HOLD.get_or_init(|| {
            std::env::var(DEPARTED_GRID_HOLD_ENV)
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .map_or(DEPARTED_GRID_HOLD, Duration::from_millis)
        })
    }
    #[cfg(not(debug_assertions))]
    DEPARTED_GRID_HOLD
}

/// One participant as `Mux::terminal_grid_target` last saw it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::mux) struct AppliedSeat {
    /// A phone or tablet: only a handheld's departure holds the grid.
    handheld: bool,
    /// It has reported a viewport.
    sized: bool,
}

/// `Mux::terminal_grid_hold_snapshot`.
pub(in crate::mux) struct TerminalGridHoldSnapshot {
    participants: std::collections::BTreeMap<String, AppliedSeat>,
    hold: Option<((u16, u16), Instant)>,
}
