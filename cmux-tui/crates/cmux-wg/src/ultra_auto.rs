//! Ultra mode "Auto": no repair data while the link is clean, and repair
//! data within about one round trip of the first loss.
//!
//! A tunnel in Auto starts with ultra mode off, so a clean link sends exactly
//! the bytes it sends with the mode off. Two things count as loss:
//!
//! - a gap in the WireGuard counters of the datagrams this side receives
//!   (the peer's datagrams are numbered one by one; [`LossMeter`]), seen the
//!   moment the next datagram arrives;
//! - a TCP segment the tunnel's stack sends again (`crate::pacing`), which
//!   with SACK happens about one round trip after a loss on the way out.
//!
//! On the first loss this side sends in [`UltraMode::SETTING`] at once and
//! tells the peer in its in-tunnel hello (`crate::ultra_hello`), which takes
//! the stronger mode of the two, so both directions are protected half a
//! round trip later. A gap that a late datagram fills (reordering across
//! paths) is not loss: when every gap since turning on was filled late, and
//! no segment was sent again, Auto turns off at once. Otherwise it stays on
//! until the link has been clean for [`HOLD`] and [`CLEAN_DATAGRAMS`]
//! datagrams; a datagram rebuilt from parity is a loss, so a lossy link that
//! ultra mode repairs keeps it on.
//!
//! On a metered network (the iPhone on cellular) Auto still turns on, but
//! each group's repair bytes stay within its data bytes ([`METERED_OVERHEAD`]),
//! and the hello asks the peer to keep to that too, since the phone pays for
//! what it receives. "Always" ([`UltraChoice::Always`]) is never capped.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::time::Instant;

use crate::ultra::{ENV, UltraMode};

/// How long a link must be clean before Auto turns the repair data off.
pub(crate) const HOLD: Duration = Duration::from_secs(30);
/// And how many datagrams must have arrived since the last loss, so a lossy
/// link that went quiet is still protected when it wakes.
pub(crate) const CLEAN_DATAGRAMS: u64 = 1000;
/// On a metered network: bytes sent per data byte, repair included, at most.
pub(crate) const METERED_OVERHEAD: u32 = 2;
/// Counters behind the newest one whose arrival [`LossMeter`] remembers.
const WINDOW: u64 = 64;
/// A jump this far is a new counter epoch, not loss.
const MAX_GAP: u64 = 1 << 16;

/// What a person's setting asks of a tunnel: Off, Auto or Always.
#[derive(Debug, Clone, Copy, Default)]
pub enum UltraChoice {
    /// No repair data.
    #[default]
    Off,
    /// No repair data on a clean link; [`UltraMode::SETTING`] from the first
    /// loss. While `metered` is set and true (the app says the network is
    /// cellular), repair bytes stay within the data bytes.
    Auto { metered: Option<&'static AtomicBool> },
    /// This mode on every datagram ("Always", or `CMUX_WG_ULTRA=rs:4:4`).
    Always(UltraMode),
}

impl PartialEq for UltraChoice {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Off, Self::Off) => true,
            (Self::Auto { metered: a }, Self::Auto { metered: b }) => match (a, b) {
                (None, None) => true,
                (Some(a), Some(b)) => std::ptr::eq(*a, *b),
                _ => false,
            },
            (Self::Always(a), Self::Always(b)) => a == b,
            _ => false,
        }
    }
}

impl Eq for UltraChoice {}

impl UltraChoice {
    /// Auto on a network that is never metered (a desktop).
    pub const AUTO: Self = Self::Auto { metered: None };
    /// What "Always" turns on.
    pub const ALWAYS: Self = Self::Always(UltraMode::SETTING);

    /// `auto`, `always`, or any [`UltraMode::parse`] mode (`off` is Off);
    /// `None` for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        match text.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Self::AUTO),
            "always" | "on" => Some(Self::ALWAYS),
            other => UltraMode::parse(other).map(Self::from),
        }
    }

    /// The choice a tunnel starts with: [`ENV`] when it is set and not empty
    /// (`CMUX_WG_ULTRA=off` turns a setting off for one run, `auto` and any
    /// mode override it), else the app's `setting`. An unreadable [`ENV`] is
    /// reported and the setting applies.
    pub fn resolve(setting: Self) -> Self {
        Self::resolve_with(std::env::var(ENV).ok().as_deref(), setting)
    }

    pub(crate) fn resolve_with(env: Option<&str>, setting: Self) -> Self {
        match env.map(str::trim).filter(|text| !text.is_empty()) {
            None => setting,
            Some(text) => Self::parse(text).unwrap_or_else(|| {
                eprintln!(
                    "{ENV}={text:?} is not off, auto, always, dup, dupN, fec, fec:K:M, rs or rs:K:M; using {setting:?}"
                );
                setting
            }),
        }
    }

    /// The mode a tunnel starts sending in: Auto starts off.
    pub(crate) fn start_mode(self) -> UltraMode {
        match self {
            Self::Always(mode) => mode,
            Self::Off | Self::Auto { .. } => UltraMode::Off,
        }
    }

    /// The Auto controller, for an Auto choice.
    pub(crate) fn auto(self) -> Option<AutoUltra> {
        match self {
            Self::Auto { metered } => Some(AutoUltra::new(metered)),
            Self::Off | Self::Always(_) => None,
        }
    }
}

impl From<UltraMode> for UltraChoice {
    fn from(mode: UltraMode) -> Self {
        if mode == UltraMode::Off { Self::Off } else { Self::Always(mode) }
    }
}

/// What [`LossMeter`] saw since it was last read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct LossSample {
    /// Counters skipped: lost, or still on their way.
    pub(crate) gaps: u64,
    /// Skipped counters that arrived late as the genuine datagram.
    pub(crate) late: u64,
    /// Skipped counters known lost: rebuilt from parity, or never arrived
    /// while [`WINDOW`] newer ones did.
    pub(crate) lost: u64,
    /// Authenticated datagrams received.
    pub(crate) received: u64,
}

/// Loss on the way in, from the counters of the peer's authenticated
/// WireGuard data datagrams (one session, the newest, at a time).
#[derive(Debug, Default)]
pub(crate) struct LossMeter {
    /// The session's receiver index and the newest counter seen in it.
    current: Option<([u8; 4], u64)>,
    /// The session before it, whose late datagrams are not counted.
    previous: Option<[u8; 4]>,
    /// Bit `i`: counter `newest - 1 - i` has not arrived.
    missing: u64,
    sample: LossSample,
}

impl LossMeter {
    /// An authenticated datagram arrived; `rebuilt` when parity rebuilt it.
    pub(crate) fn observe(&mut self, index: [u8; 4], counter: u64, rebuilt: bool) {
        self.sample.received += 1;
        if self.previous == Some(index) {
            return;
        }
        let Some((current, newest)) = self.current.filter(|(current, _)| *current == index) else {
            self.previous = self.current.map(|(current, _)| current);
            self.current = Some((index, counter));
            self.missing = 0;
            return;
        };
        if counter > newest {
            let gap = counter - newest - 1;
            if gap >= MAX_GAP {
                self.current = Some((current, counter));
                self.missing = 0;
                return;
            }
            let shift = gap + 1;
            // Gaps shifted out of the window never arrived: lost.
            let leaving =
                if shift >= WINDOW { self.missing } else { self.missing >> (WINDOW - shift) };
            self.sample.lost += u64::from(leaving.count_ones());
            let kept = if shift >= WINDOW { 0 } else { self.missing << shift };
            let fresh = if gap >= WINDOW { u64::MAX } else { (1u64 << gap) - 1 };
            self.missing = kept | fresh;
            self.sample.gaps += gap;
            self.current = Some((current, counter));
            return;
        }
        let Some(behind) = (newest - counter).checked_sub(1).filter(|behind| *behind < WINDOW)
        else {
            return;
        };
        let bit = 1u64 << behind;
        if self.missing & bit == 0 {
            return;
        }
        self.missing &= !bit;
        if rebuilt {
            self.sample.lost += 1;
        } else {
            self.sample.late += 1;
        }
    }

    /// What arrived since the last call.
    pub(crate) fn take(&mut self) -> LossSample {
        std::mem::take(&mut self.sample)
    }
}

/// One tunnel's Auto: whether it wants repair data now.
#[derive(Debug)]
pub(crate) struct AutoUltra {
    metered: Option<&'static AtomicBool>,
    on: bool,
    /// Gaps not yet filled or known lost since Auto turned on.
    suspect: u64,
    /// A loss since Auto turned on that a late datagram cannot explain.
    confirmed: bool,
    last_loss: Option<Instant>,
    /// Datagrams received since the last loss.
    clean: u64,
    /// What [`AutoUltra::observe`] last reported wanting.
    told: (UltraMode, bool),
}

impl AutoUltra {
    fn new(metered: Option<&'static AtomicBool>) -> Self {
        Self {
            metered,
            on: false,
            suspect: 0,
            confirmed: false,
            last_loss: None,
            clean: 0,
            told: (UltraMode::Off, false),
        }
    }

    /// The mode this side asks for now, and whether its network is metered.
    pub(crate) fn wanted(&self) -> (UltraMode, bool) {
        let mode = if self.on { UltraMode::SETTING } else { UltraMode::Off };
        (mode, self.metered.is_some_and(|metered| metered.load(Ordering::Relaxed)))
    }

    /// Whether repair data is on.
    pub(crate) fn is_on(&self) -> bool {
        self.on
    }

    /// Take what the meter saw and the segments the stack sent again.
    /// Returns true when [`AutoUltra::wanted`] changed since the last call
    /// (repair turned on or off, or the network became metered or not).
    pub(crate) fn observe(&mut self, now: Instant, sample: LossSample, resent: u64) -> bool {
        let loss = sample.gaps > 0 || sample.lost > 0 || resent > 0;
        if loss {
            self.last_loss = Some(now);
            self.clean = 0;
            if !self.on {
                self.on = true;
                self.suspect = 0;
                self.confirmed = false;
            }
        } else {
            self.clean = self.clean.saturating_add(sample.received);
        }
        if self.on {
            self.suspect = (self.suspect + sample.gaps).saturating_sub(sample.late + sample.lost);
            self.confirmed |= sample.lost > 0 || resent > 0;
            let reordered = !self.confirmed && self.suspect == 0;
            let quiet = self.last_loss.is_none_or(|at| now.duration_since(at) >= HOLD)
                && self.clean >= CLEAN_DATAGRAMS;
            if reordered || quiet {
                self.on = false;
            }
        }
        let wanted = self.wanted();
        std::mem::replace(&mut self.told, wanted) != wanted
    }
}

#[cfg(test)]
#[path = "ultra_auto_tests.rs"]
mod tests;
