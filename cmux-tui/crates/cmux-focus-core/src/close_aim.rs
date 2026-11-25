//! The pane a person's Close Tab press is aimed at, after a close emptied a
//! pane and the focus moved to another one (Leo 2026-10-21; Lawrence
//! 2026-10-23). One per window: the app FFI's focus handle keeps it beside
//! the window's focus state.
//!
//! A press is aimed at what the person saw when they pressed. The close of a
//! pane's last tab moves the focus to a pane the person did not pick, so:
//! - a press made before the frame that shows the focus in the new pane was
//!   presented (queued behind the emptying press, or typed in the same
//!   refresh) is aimed at the emptied pane;
//! - a key repeat is the same press as the key-down it repeats: a repeat of
//!   the key that emptied the pane, or of a press aimed at it, is aimed at it
//!   too;
//! - a fresh press made after that frame was presented closes in the pane
//!   now focused, at once.
//!
//! A press aimed at the emptied pane closes nothing there and nothing
//! elsewhere; the app shows why (the refusal HUD), so no press is silent. No
//! time window: only the presented frame and the key's own repeat flag
//! decide. Times are seconds of system uptime (the clock of the platform's
//! input event timestamps).

/// The last move of the window's focused pane.
#[derive(Clone, Debug, PartialEq)]
pub struct Move {
    /// The pane the focus left, or none when no pane had it.
    pub from: Option<String>,
    /// The pane the focus moved to, or none when no pane has it now.
    pub to: Option<String>,
    /// Identifies the move, so a late presentation stamp never lands on a
    /// newer move.
    pub serial: u64,
    /// When the frame that shows this move was presented; none until its
    /// commit.
    pub presented_at: Option<f64>,
}

/// One Close Tab press.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Press {
    /// When the person made it.
    pub time: f64,
    /// A key-down: a held key may repeat it (a click or a menu run is not).
    pub is_key: bool,
    /// An auto-repeat of a held key.
    pub is_repeat: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PaneCloseAim {
    /// The last move of the window's focused pane, or none before the first.
    move_: Option<Move>,
    /// The pane the last press emptied while the focus has not been seen
    /// elsewhere yet.
    emptied: Option<String>,
    /// The held key's press was aimed at `emptied` (the key that emptied it,
    /// or a later press aimed at it): its repeats are aimed there too. A
    /// fresh key-down decides again.
    held: bool,
    serial: u64,
}

impl PaneCloseAim {
    /// No pane emptied and no move seen.
    pub fn new() -> PaneCloseAim {
        PaneCloseAim::default()
    }

    /// The last move of the window's focused pane.
    pub fn last_move(&self) -> Option<&Move> {
        self.move_.as_ref()
    }

    /// The pane the last press emptied, while the aim holds.
    pub fn emptied(&self) -> Option<&str> {
        self.emptied.as_deref()
    }

    /// The focused pane moved from `from` to `to`. Returns the move's
    /// serial, for [`PaneCloseAim::presented`].
    pub fn pane_moved(&mut self, from: Option<&str>, to: Option<&str>) -> u64 {
        self.serial = self.serial.wrapping_add(1);
        self.move_ = Some(Move {
            from: from.map(str::to_owned),
            to: to.map(str::to_owned),
            serial: self.serial,
            presented_at: None,
        });
        self.serial
    }

    /// The frame that shows move `serial` was presented at `time`; a stamp
    /// for an older move, or a second stamp, changes nothing.
    pub fn presented(&mut self, serial: u64, time: f64) {
        if let Some(last) = self.move_.as_mut()
            && last.serial == serial
            && last.presented_at.is_none()
        {
            last.presented_at = Some(time);
        }
    }

    /// `press` closed the last tab of `pane` (a held key's repeats are aimed
    /// at the pane).
    pub fn pane_emptied(&mut self, pane: &str, press: Press) {
        self.emptied = Some(pane.to_owned());
        self.held = press.is_key;
    }

    /// Whether `press` is aimed at the emptied pane (it closes nothing, and
    /// the caller shows why) rather than at `focused`, the pane the focus
    /// model has now.
    pub fn aims_at_emptied_pane(&mut self, press: Press, focused: Option<&str>) -> bool {
        let Some(pane) = self.emptied.clone() else { return false };
        if press.is_repeat {
            if self.held {
                return true;
            }
        } else if press.is_key {
            self.held = false;
        }
        // The focus has not left the emptied pane yet: the press acts on it
        // as on any pane.
        if focused == Some(pane.as_str()) {
            return false;
        }
        // The person moved the focus since (a click, a pane key): the press
        // is theirs to aim.
        let Some(last) = self
            .move_
            .as_ref()
            .filter(|m| m.from.as_deref() == Some(pane.as_str()) && m.to.as_deref() == focused)
        else {
            self.emptied = None;
            return false;
        };
        match last.presented_at {
            Some(shown) if press.time >= shown => {
                self.emptied = None;
                false
            }
            _ => {
                // Held, this key's repeats are the same press, aimed at the
                // emptied pane too.
                self.held = press.is_key;
                true
            }
        }
    }
}
