//! The live paths of one peer link (`peer.rs`): every carrier that reaches the peer is a path
//! that is kept open and probed, not a fallback tried after another failed.
//!
//! - A path is probed on a fixed heartbeat: a WebSocket ping each [`PROBE_EVERY`]. Its pong
//!   makes it alive and measures its round trip.
//! - A path with no pong for [`DOUBT_AFTER`] is in doubt; one with no pong for [`TRUST_FOR`]
//!   is dead. A dead path is probed again on a growing backoff ([`RECOVERY_FIRST`] doubling to
//!   [`RECOVERY_CAP`]), and comes back with its next pong.
//! - Which alive path carries the session is the transport selector's call
//!   (`cmux_transport::Selector`): the lower smoothed round trip wins, with hysteresis, and any
//!   direct path beats the hub relay.
//! - Relay first: a peer whose paths include a streaming hub relay opens on the relay and its
//!   remembered path at once, so no link waits on a direct path that may never answer (a
//!   punch that fails, a black-holed WireGuard endpoint). A direct path takes the session from
//!   the relay only after [`UPGRADE_AFTER`] probe answers in a row at no worse a round trip,
//!   and gives it back when it fails or the relay beats it (the selector's relay-first rules).
//!   A peer without a hub relay keeps the direct-first order.
//!
//! This file is pure: times are milliseconds the caller passes in, so the rules are tested
//! without clocks or sockets.

use crate::peer_path_stats::LinkStats;
use cmux_transport::{
    PathId, PathKind, PathState as SelectorState, ProbeOutcome, Selector, SelectorConfig,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

/// A ping goes out on every open path this often.
pub const PROBE_EVERY: Duration = Duration::from_secs(3);
/// A path with no pong for longer than this is in doubt.
pub const DOUBT_AFTER: Duration = Duration::from_secs(3);
/// A path is trusted this long after its last pong; then it is dead.
pub const TRUST_FOR: Duration = Duration::from_millis(6_500);
/// A dead path's first recovery probe comes this long after it died...
pub const RECOVERY_FIRST: Duration = Duration::from_secs(3);
/// ...and the gap doubles up to this.
pub const RECOVERY_CAP: Duration = Duration::from_secs(60);
/// A path's recovery backoff starts over only once it stayed up this long (the link's own
/// `stable_after`). A path that answers one probe and drops again (a flapping relay circuit,
/// a tunnel the remote cuts) keeps doubling to [`RECOVERY_CAP`] instead of being redialed
/// every [`RECOVERY_FIRST`] for as long as it flaps.
pub const RECOVERY_STABLE: Duration = Duration::from_secs(60);
/// Relay first: probe answers in a row a direct path needs before it takes the session from
/// the hub relay (doubled each time it was dropped back to the relay).
pub const UPGRADE_AFTER: u8 = 2;

/// What carries the peer link, as clients see it (`carrier` in `_acpmux/peers` and
/// `_acpmux/peer_state_changed`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Carrier {
    /// Straight to the peer over WireGuard: the cmux link, acpmux's own Labs transport, or a
    /// configured `ws://`/`wss://` URL.
    Direct,
    /// An `ssh -W` stdio channel to the peer's listener.
    Ssh,
    /// The hub relay. It carries mailbox sends today, not a live session; the path is here so
    /// a hub stream carrier becomes one more path when it lands.
    Hub,
    /// The cmux Cloud carrier (a Cloud machine's link).
    Cloud,
}

impl Carrier {
    /// The same carrier on the wire (`_acpmux/peer_state_changed`, `peer_carrier.rs`).
    pub fn wire(self) -> crate::protocol::peer_state::Carrier {
        use crate::protocol::peer_state::Carrier as Wire;
        match self {
            Self::Direct => Wire::Direct,
            Self::Ssh => Wire::Ssh,
            Self::Hub => Wire::Hub,
            Self::Cloud => Wire::Cloud,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Ssh => "ssh",
            Self::Hub => "hub",
            Self::Cloud => "cloud",
        }
    }
}

/// How one path reaches the peer. Several may be [`Carrier::Direct`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Via {
    /// A `link.dial` of the `acpmux` service through this machine's cmux link.
    Link,
    /// acpmux's own Labs WireGuard transport (only while it holds the key lock).
    Wireguard,
    /// The configured `ws://` or `wss://` URL.
    Url,
    /// `ssh -W` to the configured `ssh://` URL.
    Ssh,
    /// The hub relay: the hub carrier's stream with the `hub-carrier` feature, else mailbox
    /// sends only and never dialed (see [`Via::streams`]).
    Hub,
}

impl Via {
    pub fn carrier(self) -> Carrier {
        match self {
            Self::Link | Self::Wireguard | Self::Url => Carrier::Direct,
            Self::Ssh => Carrier::Ssh,
            Self::Hub => Carrier::Hub,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Link => "link",
            Self::Wireguard => "wireguard",
            Self::Url => "url",
            Self::Ssh => "ssh",
            Self::Hub => "hub",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        [Self::Link, Self::Wireguard, Self::Url, Self::Ssh, Self::Hub]
            .into_iter()
            .find(|via| via.as_str() == text)
    }

    /// Whether this path can carry the peer's WebSocket. The hub relay does through the hub
    /// carrier (`hub_carrier.rs`, the `hub-carrier` feature), and then it is dialed and probed
    /// like the rest; without it the relay carries mailbox sends only.
    pub fn streams(self) -> bool {
        !matches!(self, Self::Hub) || cfg!(feature = "hub-carrier")
    }

    /// The selector compares paths by class first and only then by round trip: every path
    /// that reaches the peer itself (link, WireGuard, a URL, ssh) is one class, so the round
    /// trip picks among them; the hub relay is the relayed class, which a direct path replaces
    /// once it is up (under relay first, once it proved itself: [`UPGRADE_AFTER`]).
    fn kind(self) -> PathKind {
        match self {
            Self::Hub => PathKind::DoRelay,
            _ => PathKind::DirectLan,
        }
    }
}

/// One path's health at a moment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Health {
    /// Not answered yet (since it was added or came back).
    Probing,
    Alive,
    /// Alive, but no pong for more than [`DOUBT_AFTER`].
    Doubt,
    Dead,
}

impl Health {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Probing => "probing",
            Self::Alive => "alive",
            Self::Doubt => "doubt",
            Self::Dead => "dead",
        }
    }
}

#[derive(Debug, Clone)]
struct Path {
    via: Via,
    id: PathId,
    /// When its last pong came.
    last_pong: Option<u64>,
    /// When it was found dead, while it is.
    dead_at: Option<u64>,
    /// Recovery probes since it last stayed up [`RECOVERY_STABLE`].
    recoveries: u32,
    /// When it last came up (a pong or an open after it was dead or untried), while it is up.
    up_since: Option<u64>,
    /// When the next recovery probe of a dead path is due.
    recover_at: Option<u64>,
}

impl Path {
    /// It answers (a pong, or the link opened on it): no longer dead, and up from now unless
    /// it already was. Its recovery count stays until it has been up [`RECOVERY_STABLE`].
    fn up(&mut self, now: u64) {
        if self.dead_at.is_some() || self.up_since.is_none() {
            self.up_since = Some(now);
        }
        self.dead_at = None;
        self.recover_at = None;
    }
}

/// The paths of one peer and the one that carries its session.
#[derive(Debug, Clone)]
pub struct Paths {
    selector: Selector,
    paths: Vec<Path>,
    /// Remembered from an earlier run (`peer_last_good.rs`): dialed first while no path has
    /// answered yet.
    remembered: Option<Via>,
    /// What this link's paths did (`peer_path_stats.rs`).
    stats: LinkStats,
    /// Relay first: the hub relay streams, so a cold connect opens on it at once.
    relay_first: bool,
}

/// The selector's rules with this file's clock: a path is reported lost once, when its trust
/// ran out (or its connection failed), so one loss makes it dead. Relay first, a direct path
/// takes the session from the relay after [`UPGRADE_AFTER`] answers.
fn selector_config(relay_first: bool) -> SelectorConfig {
    SelectorConfig {
        dead_after_lost: 1,
        upgrade_streak: if relay_first { UPGRADE_AFTER } else { 0 },
        ..SelectorConfig::default()
    }
}

impl Paths {
    /// The paths `vias` (duplicates and order do not matter; the hub without the hub carrier
    /// has no stream and is listed, never dialed). With a streaming hub they are relay first.
    pub fn new(vias: &[Via]) -> Self {
        let relay_first = vias.iter().any(|via| *via == Via::Hub && via.streams());
        let mut selector = Selector::new(selector_config(relay_first));
        let mut paths = Vec::new();
        let mut sorted = vias.to_vec();
        sorted.sort();
        sorted.dedup();
        for (n, via) in sorted.into_iter().enumerate() {
            let id = PathId(u16::try_from(n).unwrap_or(u16::MAX));
            if selector.add_path(id, via.kind()).is_ok() {
                paths.push(Path {
                    via,
                    id,
                    last_pong: None,
                    dead_at: None,
                    recoveries: 0,
                    up_since: None,
                    recover_at: None,
                });
            }
        }
        Self { selector, paths, remembered: None, stats: LinkStats::default(), relay_first }
    }

    /// Whether a cold connect opens on the hub relay at once (see the module rules).
    pub fn relay_first(&self) -> bool {
        self.relay_first
    }

    /// How many paths of [`Self::dial_order`] a cold connect dials at once before it
    /// staggers the rest: when the relay leads, the relay and the path after it (the
    /// remembered or measured one); else one.
    pub fn dial_together(&self, now: u64) -> usize {
        if self.relay_leads(now) { 2 } else { 1 }
    }

    /// Whether the hub relay leads a cold connect: relay first, the relay is not dead, and no
    /// direct path carries the session (a link moving to the direct path the selector picked
    /// dials that path alone first, so the relay never wins it back in the race).
    fn relay_leads(&self, now: u64) -> bool {
        self.relay_first
            && self.health(Via::Hub, now) != Some(Health::Dead)
            && self.active().is_none_or(|via| via == Via::Hub)
    }

    /// A cold connect opened `via` and the link runs on it: it is alive now, before any pong
    /// measured it, so it holds the session until probes show a better path. Returns the new
    /// active path when this changed it. Relay first only: a direct-first peer's paths wait
    /// for their pongs, as before.
    pub fn opened(&mut self, via: Via, now: u64) -> Option<Option<Via>> {
        if !self.relay_first {
            return None;
        }
        let path = self.find_mut(via)?;
        path.last_pong = Some(now);
        path.up(now);
        let id = path.id;
        let switch = self.selector.on_opened(id).ok()??;
        Some(switch.to.and_then(|id| self.via_of(id)))
    }

    /// Add path `via` to a live set (a backup path found after the first dial,
    /// `peer_overlay.rs`). It starts unprobed, like every path of [`Paths::new`]. False when
    /// it is already one of these or the selector has no room for it.
    pub fn add(&mut self, via: Via) -> bool {
        if self.find(via).is_some() {
            return false;
        }
        let next =
            self.paths.iter().map(|path| path.id.0).max().map_or(Some(0), |id| id.checked_add(1));
        let Some(next) = next else { return false };
        let id = PathId(next);
        if self.selector.add_path(id, via.kind()).is_err() {
            return false;
        }
        self.paths.push(Path {
            via,
            id,
            last_pong: None,
            dead_at: None,
            recoveries: 0,
            up_since: None,
            recover_at: None,
        });
        true
    }

    /// The path that carried the session last time (`peer_last_good.rs`), if it is still one
    /// of these.
    pub fn remember(&mut self, via: Option<Via>) {
        self.remembered = via.filter(|via| self.find(*via).is_some());
    }

    pub fn vias(&self) -> impl Iterator<Item = Via> + '_ {
        self.paths.iter().map(|path| path.via)
    }

    /// The paths that can carry a WebSocket (every one but the hub without the hub carrier).
    pub fn stream_vias(&self) -> Vec<Via> {
        self.vias().filter(|via| via.streams()).collect()
    }

    fn find(&self, via: Via) -> Option<&Path> {
        self.paths.iter().find(|path| path.via == via)
    }

    fn find_mut(&mut self, via: Via) -> Option<&mut Path> {
        self.paths.iter_mut().find(|path| path.via == via)
    }

    fn via_of(&self, id: PathId) -> Option<Via> {
        self.paths.iter().find(|path| path.id == id).map(|path| path.via)
    }

    /// The path that carries the session now: the selector's pick among alive paths.
    pub fn active(&self) -> Option<Via> {
        self.selector.current().and_then(|id| self.via_of(id))
    }

    /// The smoothed round trip of `via`, once it answered.
    pub fn rtt(&self, via: Via) -> Option<Duration> {
        let id = self.find(via)?.id;
        self.selector.path(id)?.rtt_us.map(Duration::from_micros)
    }

    /// A pong on `via` after `rtt`. Returns the new active path when this changed it.
    pub fn pong(&mut self, via: Via, rtt: Duration, now: u64) -> Option<Option<Via>> {
        let answering = self.answering(via)?;
        let rtt_us = u64::try_from(rtt.as_micros()).unwrap_or(u64::MAX).max(1);
        self.stats.pong(via, rtt_us, answering);
        let path = self.find_mut(via)?;
        path.last_pong = Some(now);
        path.up(now);
        let id = path.id;
        let switch = self.selector.on_probe(id, ProbeOutcome::Answered { rtt_us }).ok()??;
        Some(switch.to.and_then(|id| self.via_of(id)))
    }

    /// `via`'s connection failed or closed (a dial that did not open, a probe socket that
    /// ended): it is dead now, without waiting out its trust. Returns the new active path when
    /// this changed it.
    pub fn failed(&mut self, via: Via, now: u64) -> Option<Option<Via>> {
        let answering = self.answering(via)?;
        self.stats.failed(via, answering);
        let path = self.find_mut(via)?;
        let id = path.id;
        if path.dead_at.is_none() {
            path.dead_at = Some(now);
            // Up long enough to count as recovered: its backoff starts over. One that dropped
            // soon after it came back keeps the backoff it had (`RECOVERY_STABLE`).
            if path.up_since.is_some_and(|at| now.saturating_sub(at) >= millis(RECOVERY_STABLE)) {
                path.recoveries = 0;
            }
            path.up_since = None;
        }
        path.recover_at = Some(now.saturating_add(recovery_gap(path.recoveries)));
        let switch = self.selector.on_probe(id, ProbeOutcome::Lost).ok()??;
        Some(switch.to.and_then(|id| self.via_of(id)))
    }

    /// Whether `via` answered and is not dead (alive, or alive and since silent); None when it
    /// is not one of these paths.
    fn answering(&self, via: Via) -> Option<bool> {
        let state = self.selector.path(self.find(via)?.id).map(|path| path.state);
        Some(matches!(state, Some(SelectorState::Alive | SelectorState::Suspect)))
    }

    /// This link's counters (`peer_path_stats.rs`).
    pub fn stats(&self) -> &LinkStats {
        &self.stats
    }

    /// A cold connect that started at `started` dialed `order` and opened on `winner` at `now`.
    pub fn record_opened(&mut self, order: &[Via], winner: Via, started: u64, now: u64) {
        self.stats.opened(order, winner, started, now);
    }

    /// The live link runs on `via` from `now` (None: it ended).
    pub fn serving(&mut self, via: Option<Via>, now: u64) {
        self.stats.serving(via, now);
    }

    /// `linkStats` of `_acpmux/peers` (`LinkStats::view`).
    pub fn stats_view(&self, now: u64) -> Value {
        self.stats.view(now)
    }

    /// The clock moved: every alive path whose trust ran out is dead. Returns the new active
    /// path when this changed it.
    pub fn tick(&mut self, now: u64) -> Option<Option<Via>> {
        let trust = millis(TRUST_FOR);
        let expired: Vec<Via> = self
            .paths
            .iter()
            .filter(|path| {
                path.dead_at.is_none()
                    && path.last_pong.is_some_and(|at| now.saturating_sub(at) > trust)
            })
            .map(|path| path.via)
            .collect();
        let mut changed = None;
        for via in expired {
            if let Some(to) = self.failed(via, now) {
                changed = Some(to);
            }
        }
        changed
    }

    /// `via`'s health at `now`.
    pub fn health(&self, via: Via, now: u64) -> Option<Health> {
        let path = self.find(via)?;
        let state = self.selector.path(path.id)?.state;
        Some(match state {
            SelectorState::Dead => Health::Dead,
            SelectorState::Probing => Health::Probing,
            SelectorState::Alive
                if path
                    .last_pong
                    .is_some_and(|at| now.saturating_sub(at) > millis(DOUBT_AFTER)) =>
            {
                Health::Doubt
            }
            SelectorState::Alive => Health::Alive,
            // Answered before, then missed a probe or went silent, not dead yet: the
            // selector still holds it (`chosen`) while senders use every path, which is this
            // file's doubt (`in_doubt`).
            SelectorState::Suspect => Health::Doubt,
        })
    }

    /// Whether the active path is in doubt (or there is none): the moment a sender would use
    /// every path at once.
    pub fn in_doubt(&self, now: u64) -> bool {
        self.active().is_none_or(|via| self.health(via, now) != Some(Health::Alive))
    }

    /// The path to send on as well while `serving` (the path the live link runs on) is in
    /// doubt: no pong on it for more than [`DOUBT_AFTER`] (or past its trust), and another path
    /// answers. The other path with the lowest round trip; None while `serving` answers, or
    /// when no other path does (`peer_dual.rs`).
    pub fn dual_partner(&self, serving: Via, now: u64) -> Option<Via> {
        self.dual_partner_among(serving, now, |_| true)
    }

    /// [`Self::dual_partner`] among the paths `eligible` takes.
    pub fn dual_partner_among(
        &self,
        serving: Via,
        now: u64,
        eligible: impl Fn(Via) -> bool,
    ) -> Option<Via> {
        if !matches!(self.health(serving, now)?, Health::Doubt | Health::Dead) {
            return None;
        }
        self.stream_vias()
            .into_iter()
            .filter(|via| *via != serving && eligible(*via))
            .filter(|via| matches!(self.health(*via, now), Some(Health::Alive | Health::Doubt)))
            .min_by_key(|via| (self.rtt(*via).map_or(u64::MAX, millis), *via))
    }

    /// Whether a dead `via` is due for its recovery probe at `now`; it is then scheduled for
    /// the next one, further out. An alive or probing path is always due (its own heartbeat).
    pub fn recovery_due(&mut self, via: Via, now: u64) -> bool {
        let Some(path) = self.find_mut(via) else { return false };
        match path.recover_at {
            None => true,
            Some(at) if now >= at => {
                path.recoveries = path.recoveries.saturating_add(1);
                path.recover_at = Some(now.saturating_add(recovery_gap(path.recoveries)));
                true
            }
            Some(_) => false,
        }
    }

    /// When the next recovery probe of `via` is due, if it is dead.
    pub fn recover_at(&self, via: Via) -> Option<u64> {
        self.find(via)?.recover_at
    }

    /// The order a cold connect dials the stream paths in: the active path, the alive ones by
    /// round trip, the one remembered from an earlier run, then the rest (dead ones last).
    /// Relay first, the hub relay leads (unless it is dead or a direct path carries the
    /// session), and the rest follow in that order.
    pub fn dial_order(&self, now: u64) -> Vec<Via> {
        let mut order = self.direct_first_order(now);
        if self.relay_leads(now)
            && let Some(at) = order.iter().position(|via| *via == Via::Hub)
        {
            order.remove(at);
            order.insert(0, Via::Hub);
        }
        order
    }

    fn direct_first_order(&self, now: u64) -> Vec<Via> {
        let rank = |via: Via| -> (u8, u64) {
            let health = self.health(via, now);
            let rtt = self.rtt(via).map_or(u64::MAX, millis);
            if Some(via) == self.active() {
                (0, 0)
            } else if matches!(health, Some(Health::Alive | Health::Doubt)) {
                (1, rtt)
            } else if Some(via) == self.remembered {
                (2, 0)
            } else if health == Some(Health::Dead) {
                (4, 0)
            } else {
                (3, 0)
            }
        };
        let mut order = self.stream_vias();
        order.sort_by_key(|via| (rank(*via), *via));
        order
    }

    /// The paths for `_acpmux/peers`: each one's carrier, how it reaches the peer, its health
    /// and its smoothed round trip in milliseconds (fractional).
    pub fn view(&self, now: u64) -> Value {
        let paths: Vec<Value> = self
            .paths
            .iter()
            .map(|path| {
                json!({
                    "carrier": path.via.carrier().as_str(),
                    "via": path.via.as_str(),
                    "state": self.health(path.via, now).map_or("probing", Health::as_str),
                    "rttMs": self.rtt(path.via).map(|rtt| rtt.as_micros() as f64 / 1000.0),
                    "lastPong": path.last_pong,
                    "active": Some(path.via) == self.active(),
                })
            })
            .collect();
        Value::Array(paths)
    }
}

/// The gap before the `n`th recovery probe of a dead path: [`RECOVERY_FIRST`], doubling, at
/// most [`RECOVERY_CAP`].
pub fn recovery_gap(n: u32) -> u64 {
    millis(RECOVERY_FIRST).saturating_mul(1u64 << n.min(16)).min(millis(RECOVERY_CAP))
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "peer_paths_tests.rs"]
mod tests;
