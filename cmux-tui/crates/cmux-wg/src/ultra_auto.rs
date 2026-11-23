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
//! round trip later. When a side's repair turns on, its TCP is told that the
//! link repairs its own losses from then on
//! (`crate::tcp_stack::TcpStack::link_repairs_losses`): the loss that turned
//! Auto on, and any other of data already in flight, is resent about one
//! round trip later but cuts no congestion window, so after that round trip
//! the tunnel runs as one that had "Always" from the start.
//!
//! Not every counter travels on the data path: a path probe, and the answer
//! to one, goes out on its own path (`crate::probing`), and a candidate path
//! that does not work never delivers it. Those gaps are not loss on the path
//! the data takes. Right behind the probes of a pass, on the data path, the
//! sender says which counters it sent elsewhere ([`off_path_packets`]), and
//! the receiver's meter skips them before it sees the gap
//! ([`LossMeter::off_path`]), so a clean link with a dead candidate stays at
//! no repair data. Every other datagram (data, ACKs, hellos, keepalives, these
//! notes) goes on the data path, and handshake messages carry no counter.
//!
//! A gap that a late datagram fills (reordering across
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

use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::time::Instant;

use crate::udp;
use crate::ultra::{ENV, UltraMode};
use crate::ultra_hello::HELLO_PORT;

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
/// Off-path counters the meter holds until the data path passes them.
const OFF_PATH_KEPT: usize = 64;
/// Magic of an off-path note: which counters the sender sent on another path.
const OFF_PATH_MAGIC: [u8; 4] = *b"CMXK";
const OFF_PATH_VERSION: u8 = 1;
/// Counters in one note. Its payload is 6 + 8n bytes, never the length of a
/// probe (15) or a hello (9 or 33), so neither reads it as one.
const OFF_PATH_MAX: usize = 16;

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
    /// Counters the peer sent off the data path that the data path has not
    /// passed yet, with their session: skipped, not missing.
    off_path: Vec<([u8; 4], u64)>,
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
            self.forget_passed();
            return;
        };
        if counter > newest {
            let gap = counter - newest - 1;
            if gap >= MAX_GAP {
                self.current = Some((current, counter));
                self.missing = 0;
                self.forget_passed();
                return;
            }
            let shift = gap + 1;
            // Gaps shifted out of the window never arrived: lost.
            let leaving =
                if shift >= WINDOW { self.missing } else { self.missing >> (WINDOW - shift) };
            self.sample.lost += u64::from(leaving.count_ones());
            let kept = if shift >= WINDOW { 0 } else { self.missing << shift };
            let mut fresh = if gap >= WINDOW { u64::MAX } else { (1u64 << gap) - 1 };
            let mut skipped = 0;
            for &(_, sent) in self.off_path.iter().filter(|(at, _)| *at == current) {
                if sent > newest && sent < counter {
                    skipped += 1;
                    let behind = counter - 1 - sent;
                    if behind < WINDOW {
                        fresh &= !(1u64 << behind);
                    }
                }
            }
            self.missing = kept | fresh;
            self.sample.gaps += gap - skipped.min(gap);
            self.current = Some((current, counter));
            self.forget_passed();
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

    /// The peer says it sent `counters` of session `index` on another path
    /// than the data path (path probes and their answers): a gap there is
    /// not loss. One already counted as a gap counts as late, as a datagram
    /// that arrived after its successor does; one still ahead is skipped
    /// when the data path passes it.
    pub(crate) fn off_path(&mut self, index: [u8; 4], counters: &[u64]) {
        for &counter in counters {
            if let Some((current, newest)) = self.current
                && current == index
                && counter < newest
            {
                let behind = newest - 1 - counter;
                if behind < WINDOW && self.missing & (1u64 << behind) != 0 {
                    self.missing &= !(1u64 << behind);
                    self.sample.late += 1;
                }
                continue;
            }
            if self.off_path.len() >= OFF_PATH_KEPT {
                self.off_path.remove(0);
            }
            self.off_path.push((index, counter));
        }
    }

    /// Drop the off-path counters the current session's data path passed.
    fn forget_passed(&mut self) {
        if let Some((current, newest)) = self.current {
            self.off_path.retain(|&(index, counter)| index != current || counter > newest);
        }
    }

    /// What arrived since the last call.
    pub(crate) fn take(&mut self) -> LossSample {
        std::mem::take(&mut self.sample)
    }
}

/// The overlay packets saying that `counters` went out on another path than
/// the data path, from and to the control port; empty for no counters. A
/// build without them drops them at the control port, as it drops a hello.
pub(crate) fn off_path_packets(
    source: IpAddr,
    destination: IpAddr,
    counters: &[u64],
) -> Vec<Vec<u8>> {
    let from = SocketAddr::new(source, HELLO_PORT);
    let to = SocketAddr::new(destination, HELLO_PORT);
    counters
        .chunks(OFF_PATH_MAX)
        .map(|chunk| {
            let mut payload = Vec::with_capacity(6 + 8 * chunk.len());
            payload.extend_from_slice(&OFF_PATH_MAGIC);
            payload.push(OFF_PATH_VERSION);
            payload.push(chunk.len() as u8);
            for counter in chunk {
                payload.extend_from_slice(&counter.to_le_bytes());
            }
            udp::packet(from, to, &payload)
        })
        .collect()
}

/// The counters an off-path note in a decrypted packet names, or `None` for
/// every other packet.
pub(crate) fn decode_off_path(packet: &[u8]) -> Option<Vec<u64>> {
    let (_, destination, payload) = udp::parse(packet)?;
    if destination.port() != HELLO_PORT {
        return None;
    }
    let ([m0, m1, m2, m3, version, count], rest) = payload.split_first_chunk::<6>()?;
    let count = usize::from(*count);
    if [*m0, *m1, *m2, *m3] != OFF_PATH_MAGIC
        || *version != OFF_PATH_VERSION
        || count == 0
        || count > OFF_PATH_MAX
        || rest.len() != 8 * count
    {
        return None;
    }
    Some(
        rest.chunks_exact(8)
            .map(|bytes| u64::from_le_bytes(bytes.try_into().unwrap_or_default()))
            .collect(),
    )
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
