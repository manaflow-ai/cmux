//! Whether the agent composer draws its Stop button: the turn's running state
//! with hysteresis, so Stop never flickers when a turn ends and the next one
//! starts a few milliseconds later (a queued prompt, a steer, a subagent's
//! notice waking the chat).
//!
//! Leo, 2026-11-22: "when you are running, there's a stop button. ok, great,
//! cute. when you stop, there is no stop button. in fact, we don't have any
//! symbols. which is maybe fine ... anyways. we ought to have a better fade
//! in/fade out and maybe a pulse when you for some reason start stop quick. so
//! that the composer isn't flickering with the stop button."
//!
//! The rules, on the page's clock in milliseconds:
//! - A turn that starts shows Stop once it has run for [`TURN_PRESENCE_DWELL_MS`].
//!   A turn shorter than that never shows Stop. The person's own send shows it
//!   at once (`immediate`): they caused it and are looking at it.
//! - A turn that ends keeps Stop for [`TURN_PRESENCE_LINGER_MS`] after its end.
//!   A turn that starts again inside that window keeps Stop up and counts one
//!   pulse ([`TurnPresence::pulses`]): the page draws a short pulse on Stop in
//!   place of it going and coming back.
//! - Every change of what is drawn stands for at least [`TURN_PRESENCE_HOLD_MS`]:
//!   Stop that showed stays that long, and Stop that went stays gone that long
//!   (unless the person sends). So no frame shows or hides Stop for less.
//! - The first state, and the state after a chat switch, is drawn at once
//!   ([`TurnPresence::new`]): a chat's state arriving is not a change.
//!
//! The model is pure and holds no timer: the host calls [`TurnPresence::set`]
//! when the running state changes and [`TurnPresence::advance`] when the clock
//! reaches [`TurnPresence::next_wake`]. The agent pane page runs a line-for-line
//! TypeScript copy (`webviews/src/agent-session/acpmux/composer/turnPresence.ts`)
//! that the shared corpus `tests/cases/turn_presence.json` holds to this one.

/// How long a turn runs before Stop shows: the motion scale's `micro` step.
pub const TURN_PRESENCE_DWELL_MS: u64 = 120;
/// How long Stop stays after the turn ends, so a turn that starts right after
/// keeps it: the hold. A queued prompt or another agent's message opens its turn
/// 50-400 ms after it lands (Leo's 2026-11-22 22:05Z session: 49, 220 and
/// 400 ms), so a shorter linger drops Stop and draws it again half a second on.
pub const TURN_PRESENCE_LINGER_MS: u64 = TURN_PRESENCE_HOLD_MS;
/// The shortest time Stop is drawn, or not drawn, before it may change again.
pub const TURN_PRESENCE_HOLD_MS: u64 = 480;

/// One composer's Stop presence. A value, no handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TurnPresence {
    /// Whether a turn runs, as the chat says it now.
    running: bool,
    /// When `running` last changed.
    running_since: u64,
    /// Whether Stop is drawn.
    shown: bool,
    /// When `shown` last changed; `None` before the first change.
    shown_since: Option<u64>,
    /// The person's send started this turn: Stop shows without the dwell.
    immediate: bool,
    /// How many times a turn started again while Stop lingered.
    pulses: u32,
}

impl TurnPresence {
    /// The state at a chat's first draw or a chat switch: drawn as it is.
    #[must_use]
    pub const fn new(running: bool, at: u64) -> Self {
        Self {
            running,
            running_since: at,
            shown: running,
            shown_since: None,
            immediate: false,
            pulses: 0,
        }
    }

    /// Whether Stop is drawn.
    #[must_use]
    pub const fn shown(&self) -> bool {
        self.shown
    }

    /// Whether a turn runs, as last set.
    #[must_use]
    pub const fn running(&self) -> bool {
        self.running
    }

    /// Stop is drawn though no turn runs: the linger after a turn's end.
    #[must_use]
    pub const fn lingering(&self) -> bool {
        self.shown && !self.running
    }

    /// How many pulses Stop has drawn; the page plays one on each increase.
    #[must_use]
    pub const fn pulses(&self) -> u32 {
        self.pulses
    }

    /// The running state at `at`. `immediate`: the person's own send started
    /// it. Applies whatever is due, as [`Self::advance`] does.
    pub fn set(&mut self, running: bool, at: u64, immediate: bool) {
        if running != self.running {
            if running && self.shown {
                self.pulses = self.pulses.saturating_add(1);
            }
            self.running = running;
            self.running_since = at;
            self.immediate = running && immediate;
        } else if running && immediate {
            self.immediate = true;
        }
        self.advance(at);
    }

    /// Applies the change due by `at`, if any.
    pub fn advance(&mut self, at: u64) {
        if let Some(due) = self.due()
            && at >= due
        {
            self.shown = self.running;
            self.shown_since = Some(due);
            self.immediate = false;
        }
    }

    /// When the drawn state changes next with no new input, if it will.
    #[must_use]
    pub fn next_wake(&self) -> Option<u64> {
        self.due()
    }

    fn held_until(&self) -> u64 {
        self.shown_since.map_or(0, |since| since.saturating_add(TURN_PRESENCE_HOLD_MS))
    }

    fn due(&self) -> Option<u64> {
        match (self.shown, self.running) {
            (false, true) if self.immediate => Some(self.running_since),
            (false, true) => Some(
                self.running_since.saturating_add(TURN_PRESENCE_DWELL_MS).max(self.held_until()),
            ),
            (true, false) => Some(
                self.running_since.saturating_add(TURN_PRESENCE_LINGER_MS).max(self.held_until()),
            ),
            _ => None,
        }
    }
}

#[cfg(test)]
#[path = "turn_presence_tests.rs"]
mod tests;
