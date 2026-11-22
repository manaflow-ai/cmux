//! The phone's claim on a Mac terminal's grid as one pure [`step`]: when the phone asks the
//! daemon for its size (`resize-surface`), when it gives it back (`release-surface-size`), and
//! what it asks for. The daemon's `host_policy.rs` stays the only decider of the grid; this
//! module decides only the phone's side (hq RFD "Remote link state", item 3; hq
//! `docs/design/ios-terminal-projection.md`).
//!
//! It is the Rust form of what is spread over the iOS Swift today, behaviour for behaviour:
//! `TerminalSizeClaimDebounce` (`CmuxMobileTerminal/Session/TerminalSizeClaim.swift`: claim while
//! the page is on screen and interactive, release 1 s after it leaves, at once when the app goes
//! to the background), `TerminalResizeSettle` (`Session/TerminalGridSizing.swift`: a measured
//! grid goes out once it held 250 ms; the first goes at once; duplicates are dropped), and
//! `DaemonTerminalSession` (`CmuxMobileLive/DaemonTerminalSession.swift`: a hidden page sends no
//! size and attaches without one, a claim's own round trip is not a lost claim for 1.5 s, an
//! on-screen grid the phone did not ask for is claimed again and kept by the Mac after 1.5 s, the
//! lease refresh every 15 s under `size-lease-v1` and 2 s under `size-lease-v2`). The written
//! contract is `cmux-next-ios/PROTOCOL.md`, "Terminal size claims". Nothing calls this yet.
//!
//! The grid in [`Event::Measured`] is the keyboard-down grid (`TerminalGridSizing.rows`: the
//! toolbar's bottom to the composer's resting top). There is deliberately no keyboard event: the
//! soft keyboard showing or closing cannot be expressed here, so it can never resize the PTY.
//!
//! Pure and without a clock: every timer is an [`Effect::StartTimer`] under a fresh
//! [`Generation`], and it comes back as [`Event::TimerFired`] carrying it. A timer that is not
//! armed is refused [`Refusal::NotArmed`]; one armed under another generation is refused
//! [`Refusal::StaleGeneration`]. A refusal leaves the claim unchanged. Starting a timer replaces
//! the one of the same kind (its old generation goes stale).
//!
//! The phase ([`Claim`]) is what the phone has at the Mac. Two things run beside it, because the
//! Swift runs them beside it: the release debounce (`release_timer`: while it runs the page
//! still claims, refreshes its lease and claims its grid again) and the settle (`settling`: it
//! sits in front of the session and runs whether the page claims or not).
//!
//! Every (phase, event) pair is written out in [`step`]: no arm falls through to a default, so
//! a new phase or event does not compile until each pair is decided. [`table`] is that table as
//! data, committed as `schemas/terminal-size-claim/table.json` (`CMUX_UPDATE_TERMINAL_SIZE_CLAIM_TABLE=1
//! cargo test -p cmux-terminal-sizing` rewrites it).

use serde::{Deserialize, Serialize};

use crate::TerminalGridSize;
use run::Run;

mod run;
mod table;

#[cfg(test)]
pub use table::table;
pub use table::{SAMPLE, sample_events, sample_states};

/// The release debounce: a page that leaves the screen (another tab, the tab grid, a sheet
/// over it) gives its size back only after this, so a quick switch away and back sends nothing.
/// `CmuxMobileTerminal/Session/TerminalSizeClaim.swift:18` (`defaultDelay`, `.seconds(1)`).
pub const RELEASE_DEBOUNCE_MS: u64 = 1_000;

/// How long a measured grid must hold before it goes to the Mac.
/// `CmuxMobileTerminal/Session/TerminalGridSizing.swift:116` (`TerminalResizeSettle.settle`).
pub const RESIZE_SETTLE_MS: u64 = 250;

/// How long an on-screen claim of the phone's grid again may take before the Mac's grid is
/// taken as kept. `CmuxMobileTerminal/Session/TerminalReclaimHold.swift:30` (`reclaimWait`).
pub const RECLAIM_WAIT_MS: u64 = 1_500;

/// How long after a `resize-surface` (or a sized attach) a grid other than the phone's is that
/// claim's own round trip, not a lost claim.
/// `CmuxMobileLive/DaemonTerminalSession.swift:304` (`claimAnswerWindow`).
pub const CLAIM_ANSWER_WINDOW_MS: u64 = 1_500;

/// The lease refresh under `size-lease-v1` (the daemon's lease is 45 s).
/// `CmuxMobileLive/DaemonTerminalSession.swift:286` (`sizeLeaseRefresh`).
pub const LEASE_REFRESH_V1_MS: u64 = 15_000;

/// The lease refresh under `size-lease-v2` (the daemon's lease is 8 s).
/// `CmuxMobileLive/DaemonTerminalSession.swift:289` (`shortLeaseRefresh`).
pub const LEASE_REFRESH_V2_MS: u64 = 2_000;

/// The id a timer was started under, and its firing carries back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Generation(pub u64);

/// Whether the phone claims a size at all. An input: the caller owns the default.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    /// The phone claims its grid while the page is on screen (today's behaviour).
    Fit,
    /// The projection: the phone never claims; it shows the Mac's grid.
    KeepHostSize,
}

/// Both modes, in the table's order.
pub const MODES: [Mode; 2] = [Mode::Fit, Mode::KeepHostSize];

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Fit => "fit",
            Mode::KeepHostSize => "keep_host_size",
        }
    }
}

/// The size lease the daemon listed in `identify`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lease {
    /// No lease: a claim lasts until released.
    None,
    /// `size-lease-v1`: refreshed every [`LEASE_REFRESH_V1_MS`].
    V1,
    /// `size-lease-v2`: refreshed every [`LEASE_REFRESH_V2_MS`].
    V2,
}

impl Lease {
    pub fn refresh_ms(self) -> Option<u64> {
        match self {
            Lease::None => None,
            Lease::V1 => Some(LEASE_REFRESH_V1_MS),
            Lease::V2 => Some(LEASE_REFRESH_V2_MS),
        }
    }
}

/// The timers the claim runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Timer {
    /// The release debounce ([`RELEASE_DEBOUNCE_MS`]).
    Release,
    /// A measured grid settling ([`RESIZE_SETTLE_MS`]).
    Settle,
    /// A claim's answer window ([`CLAIM_ANSWER_WINDOW_MS`]).
    Answer,
    /// An on-screen claim again ([`RECLAIM_WAIT_MS`]).
    Reclaim,
    /// The lease refresh ([`LEASE_REFRESH_V1_MS`], [`LEASE_REFRESH_V2_MS`]).
    Lease,
}

impl Timer {
    pub const ALL: [Timer; 5] =
        [Timer::Release, Timer::Settle, Timer::Answer, Timer::Reclaim, Timer::Lease];

    pub fn as_str(self) -> &'static str {
        match self {
            Timer::Release => "release",
            Timer::Settle => "settle",
            Timer::Answer => "answer",
            Timer::Reclaim => "reclaim",
            Timer::Lease => "lease",
        }
    }
}

/// What the phone has at the Mac, and the data only that phase has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "claim", rename_all = "snake_case")]
pub enum Claim {
    /// The phone gives the Mac no size (the page left past the debounce, the app is in the
    /// background, the session stopped, or [`Mode::KeepHostSize`]). Layout passes are
    /// remembered, never sent; an attach carries no size.
    Released,
    /// The phone claims, but nothing is at the Mac: no grid measured yet, or no link.
    Unsent,
    /// `resize-surface {grid}` (or a sized attach) went out under `asked`; inside the answer
    /// window a grid other than `grid` is the claim's own round trip.
    AwaitingAnswer { grid: TerminalGridSize, asked: Generation },
    /// The claim of `grid` stands.
    Claimed { grid: TerminalGridSize },
    /// On screen, the Mac sent a grid the phone did not ask for: `grid` was claimed again under
    /// `asked`, and the Mac has [`RECLAIM_WAIT_MS`] to bring it back.
    Reclaiming { grid: TerminalGridSize, asked: Generation },
    /// The Mac kept its own grid against the claim of `grid` (its policy): its grid changes are
    /// not claimed against until the phone's grid is back or the page claims again. The claim
    /// (and its lease) still stands.
    HostKeeps { grid: TerminalGridSize },
}

impl Claim {
    /// Every phase's name, in the table's order.
    pub const KINDS: [&'static str; 6] =
        ["released", "unsent", "awaiting_answer", "claimed", "reclaiming", "host_keeps"];

    pub fn kind(&self) -> &'static str {
        match self {
            Claim::Released => "released",
            Claim::Unsent => "unsent",
            Claim::AwaitingAnswer { .. } => "awaiting_answer",
            Claim::Claimed { .. } => "claimed",
            Claim::Reclaiming { .. } => "reclaiming",
            Claim::HostKeeps { .. } => "host_keeps",
        }
    }

    /// The grid the Mac holds for this phone (a size went out and no release after it).
    pub fn at_mac(&self) -> Option<TerminalGridSize> {
        match self {
            Claim::Released | Claim::Unsent => None,
            Claim::AwaitingAnswer { grid, .. }
            | Claim::Claimed { grid }
            | Claim::Reclaiming { grid, .. }
            | Claim::HostKeeps { grid } => Some(*grid),
        }
    }

    /// The session is told to claim (`setClaimsSize(true)`).
    pub fn claims(&self) -> bool {
        match self {
            Claim::Released => false,
            Claim::Unsent
            | Claim::AwaitingAnswer { .. }
            | Claim::Claimed { .. }
            | Claim::Reclaiming { .. }
            | Claim::HostKeeps { .. } => true,
        }
    }
}

/// A measured grid waiting out the settle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pending {
    pub grid: TerminalGridSize,
    pub timer: Generation,
}

/// One terminal page's size claim.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SizeClaim {
    pub claim: Claim,
    /// On screen, settled and taking input, and no sheet of its own over it.
    pub page_shown: bool,
    pub foreground: bool,
    /// The attach, with the lease its daemon listed; None: no link.
    pub link: Option<Lease>,
    /// The phone's grid as last given to the session (settled).
    pub grid: Option<TerminalGridSize>,
    pub settling: Option<Pending>,
    /// The Mac's grid as its stream last said; None before one on this link.
    pub host: Option<TerminalGridSize>,
    pub release_timer: Option<Generation>,
    pub lease_timer: Option<Generation>,
    /// The last generation issued.
    pub issued: Generation,
}

/// What happened.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// The page is on screen, settled and taking input, with no sheet of its own over it.
    PageShown,
    /// It is not: another tab, the tab grid, mid-swipe, the page menu, a sheet of its own.
    PageLeft,
    Foreground,
    Background,
    /// The layout measured the keyboard-down grid.
    Measured {
        grid: TerminalGridSize,
    },
    /// The Mac's stream reported its grid (`resized`, `vt-state`). The phone's own grid here
    /// answers its claim.
    HostGrid {
        grid: TerminalGridSize,
    },
    TimerFired {
        timer: Timer,
        generation: Generation,
    },
    /// Attached (again), to a daemon listing `lease`.
    LinkUp {
        lease: Lease,
    },
    LinkDown,
    /// The caller's [`Mode`] changed; the step is passed the new one.
    ModeChanged,
    /// The session stops (its tab cooled out of the warm set, closed): it releases first.
    Stop,
}

impl Event {
    /// Every event's name, in the table's order (a timer firing is one kind per timer).
    pub const KINDS: [&'static str; 15] = [
        "page_shown",
        "page_left",
        "foreground",
        "background",
        "measured",
        "host_grid",
        "timer_release",
        "timer_settle",
        "timer_answer",
        "timer_reclaim",
        "timer_lease",
        "link_up",
        "link_down",
        "mode_changed",
        "stop",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Event::PageShown => "page_shown",
            Event::PageLeft => "page_left",
            Event::Foreground => "foreground",
            Event::Background => "background",
            Event::Measured { .. } => "measured",
            Event::HostGrid { .. } => "host_grid",
            Event::TimerFired { timer, .. } => match timer {
                Timer::Release => "timer_release",
                Timer::Settle => "timer_settle",
                Timer::Answer => "timer_answer",
                Timer::Reclaim => "timer_reclaim",
                Timer::Lease => "timer_lease",
            },
            Event::LinkUp { .. } => "link_up",
            Event::LinkDown => "link_down",
            Event::ModeChanged => "mode_changed",
            Event::Stop => "stop",
        }
    }
}

/// What the caller runs after a step, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Effect {
    /// `resize-surface {cols, rows}`; on an attach just made, the attach's own size.
    SendResize {
        grid: TerminalGridSize,
    },
    /// `release-surface-size`, at once (never behind an unanswered request).
    SendRelease,
    /// A same-size `resize-surface`: renews the lease, resizes nothing.
    RefreshLease {
        grid: TerminalGridSize,
    },
    /// Start `timer` (replacing one of its kind); fire [`Event::TimerFired`] with `generation`.
    StartTimer {
        timer: Timer,
        after_ms: u64,
        generation: Generation,
    },
    CancelTimer {
        timer: Timer,
    },
}

impl Effect {
    pub fn kind(&self) -> &'static str {
        match self {
            Effect::SendResize { .. } => "send_resize",
            Effect::SendRelease => "send_release",
            Effect::RefreshLease { .. } => "refresh_lease",
            Effect::StartTimer { timer, .. } => match timer {
                Timer::Release => "start_release",
                Timer::Settle => "start_settle",
                Timer::Answer => "start_answer",
                Timer::Reclaim => "start_reclaim",
                Timer::Lease => "start_lease",
            },
            Effect::CancelTimer { timer } => match timer {
                Timer::Release => "cancel_release",
                Timer::Settle => "cancel_settle",
                Timer::Answer => "cancel_answer",
                Timer::Reclaim => "cancel_reclaim",
                Timer::Lease => "cancel_lease",
            },
        }
    }
}

/// Why an event was refused. The claim is unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// A timer fired that is not running.
    NotArmed,
    /// A timer fired under a generation other than the one it runs under.
    StaleGeneration,
    /// A measured grid with no columns or no rows.
    EmptyGrid,
}

impl Refusal {
    pub const ALL: [Refusal; 3] = [Refusal::NotArmed, Refusal::StaleGeneration, Refusal::EmptyGrid];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::NotArmed => "not_armed",
            Refusal::StaleGeneration => "stale_generation",
            Refusal::EmptyGrid => "empty_grid",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}

/// The claim after an event, and the effects to run in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Step {
    pub state: SizeClaim,
    pub effects: Vec<Effect>,
}

impl SizeClaim {
    /// A new page's claim. As in the Swift, a session starts claiming and a page that is never
    /// shown gives it up after the debounce (a neighbour laid out in the pager); under
    /// [`Mode::KeepHostSize`] it starts released.
    pub fn open(mode: Mode) -> Step {
        let state = SizeClaim {
            claim: Claim::Unsent,
            page_shown: false,
            foreground: true,
            link: None,
            grid: None,
            settling: None,
            host: None,
            release_timer: None,
            lease_timer: None,
            issued: Generation(0),
        };
        let mut run = Run { s: state, fx: Vec::new(), mode };
        run.debounce();
        Step { state: run.s, effects: run.fx }
    }

    /// The generation `timer` runs under, if it runs.
    pub fn armed(&self, timer: Timer) -> Option<Generation> {
        match timer {
            Timer::Release => self.release_timer,
            Timer::Settle => self.settling.map(|p| p.timer),
            Timer::Answer => match self.claim {
                Claim::AwaitingAnswer { asked, .. } => Some(asked),
                Claim::Released
                | Claim::Unsent
                | Claim::Claimed { .. }
                | Claim::Reclaiming { .. }
                | Claim::HostKeeps { .. } => None,
            },
            Timer::Reclaim => match self.claim {
                Claim::Reclaiming { asked, .. } => Some(asked),
                Claim::Released
                | Claim::Unsent
                | Claim::AwaitingAnswer { .. }
                | Claim::Claimed { .. }
                | Claim::HostKeeps { .. } => None,
            },
            Timer::Lease => self.lease_timer,
        }
    }
}

/// The claim after `event` under `mode`, and the effects to run; or why `event` is refused.
pub fn step(state: SizeClaim, mode: Mode, event: Event) -> Result<Step, Refusal> {
    let mut run = Run { s: state, fx: Vec::new(), mode };
    match event {
        Event::PageShown => {
            run.s.page_shown = true;
            run.debounce();
        }
        Event::PageLeft => {
            run.s.page_shown = false;
            run.debounce();
        }
        Event::Foreground => {
            run.s.foreground = true;
            run.debounce();
        }
        Event::Background => {
            run.s.foreground = false;
            run.debounce();
        }
        Event::ModeChanged => run.debounce(),
        Event::Measured { grid } => {
            if grid.cols == 0 || grid.rows == 0 {
                return Err(Refusal::EmptyGrid);
            }
            run.measured(grid);
        }
        Event::HostGrid { grid } => run.host_grid(grid),
        Event::TimerFired { timer, generation } => {
            match state.armed(timer) {
                None => return Err(Refusal::NotArmed),
                Some(armed) if armed != generation => return Err(Refusal::StaleGeneration),
                Some(_) => {}
            }
            run.fired(timer);
        }
        Event::LinkUp { lease } => {
            run.drop_link_timers();
            run.s.link = Some(lease);
            run.s.host = None;
            match run.s.claim {
                // Hidden: attach without a size, so the attach claims none.
                Claim::Released => {}
                Claim::Unsent
                | Claim::AwaitingAnswer { .. }
                | Claim::Claimed { .. }
                | Claim::Reclaiming { .. }
                | Claim::HostKeeps { .. } => {
                    run.s.claim = Claim::Unsent;
                    run.try_send();
                }
            }
        }
        Event::LinkDown => {
            run.drop_link_timers();
            run.s.link = None;
            run.s.host = None;
            match run.s.claim {
                Claim::Released | Claim::Unsent => {}
                // Nothing can be sent; the daemon's departed-view hold and lease end the size.
                Claim::AwaitingAnswer { .. }
                | Claim::Claimed { .. }
                | Claim::Reclaiming { .. }
                | Claim::HostKeeps { .. } => run.s.claim = Claim::Unsent,
            }
        }
        Event::Stop => {
            run.release();
            if run.s.release_timer.take().is_some() {
                run.cancel(Timer::Release);
            }
            if run.s.settling.take().is_some() {
                run.cancel(Timer::Settle);
            }
            run.s.link = None;
            run.s.host = None;
        }
    }
    Ok(Step { state: run.s, effects: run.fx })
}

#[cfg(test)]
mod tests;
