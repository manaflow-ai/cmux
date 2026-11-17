//! Which path the next datagram to one peer takes.
//!
//! A pure state machine, one per peer session. The engine feeds it probe
//! outcomes and network changes; it answers with the current path and
//! reports every switch. `current() == None` means no path is known to work
//! yet (a dial, or after every path died): the engine then sends on every
//! path at once, and the first answer decides.
//!
//! Rules (plans/cmux-next/transport.md section 4):
//! - Only an answered probe makes a path alive. A path that loses
//!   `dead_after_lost` probes in a row is dead until it answers again.
//! - Any alive direct path beats every relay, at once, unless it is lossy.
//! - A path is lossy when the throughput one TCP stream could hold on it,
//!   from its measured loss and smoothed RTT (Mathis et al.,
//!   `MSS / RTT * 1.22 / sqrt(p)`), falls below [`LossRule::lossy_below_kbps`].
//!   A lossy path ranks below every path that is not, relays included, so a
//!   lossy direct path hands the session to the relay at once. A relay on
//!   kernel TCP (the Durable Object WebSocket) repairs its own loss and is
//!   never lossy here; a TURN relay over UDP can be. cmux-wg's userspace TCP sits at that loss limit: at
//!   50 ms / 2 % loss it holds 1.6 Mbit/s and delivers 0.1 on-time frames a
//!   second where kernel TCP on the relay delivers 55 (cmuxterm-hq
//!   connectivity-map 3.2). Loss comes from the engine
//!   ([`Selector::on_loss_sample`]: datagrams delivered and lost on the path),
//!   never from probes alone, which come too rarely to see 2 %.
//! - Hysteresis on loss: a path is judged only after
//!   [`LossRule::min_samples`] datagrams. A lossy path carries no traffic, so
//!   its verdict is retried after [`LossRule::retry_after_answers`] answered
//!   probes, doubling with each demotion in a row (at most
//!   [`LossRule::max_retry_after_answers`]): the estimate starts over and the
//!   path ranks by its class again until its new samples judge it. A path
//!   that stays healthy for four windows starts the backoff over.
//! - Inside a class a better [`Medium`] wins at once: a Thunderbolt Bridge
//!   beats the office LAN, which beats a routed or tailnet address. The
//!   medium comes from this machine's own interface table, never from the
//!   peer, and only orders paths that already answered.
//! - Among paths of one class and medium the lower smoothed RTT wins, but
//!   only after the challenger beat the current path by the margin on
//!   `switch_streak` of its own consecutive answers (hysteresis), so
//!   neither jitter nor one lucky sample flaps the path.
//! - The current path that misses a probe, or that the engine reports
//!   silent ([`Selector::on_silence`]), is suspect: `current()` answers
//!   `None`, so the engine sends on every path until the suspect answers
//!   again or dies. A dropped fast path therefore costs one silence window,
//!   not the `dead_after_lost` probe timeouts it takes to declare it dead,
//!   and a false alarm costs only duplicates the peer's replay window drops.
//! - A local network change sends every path back to probing: direct
//!   mappings changed, the relay WebSocket died with the old interface, and
//!   the tunnel gateway learns the new source only from the next datagram.
//!   The engine sends on every path until the first answers.
//! - Path ids are never reused: a late answer for a removed path must not
//!   make a new path alive.

use crate::medium::Medium;
use crate::path::{PathClass, PathId, PathKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectorConfig {
    pub dead_after_lost: u8,
    pub switch_streak: u8,
    /// A challenger must be faster by at least this many microseconds...
    pub min_gain_us: u64,
    /// ...and by at least this share of the current RTT, in percent.
    pub min_gain_percent: u64,
    /// When a direct path loses to a relay on loss; `None` never.
    pub loss: Option<LossRule>,
}

impl Default for SelectorConfig {
    fn default() -> Self {
        Self {
            dead_after_lost: 3,
            switch_streak: 3,
            min_gain_us: 3_000,
            min_gain_percent: 10,
            loss: Some(LossRule::default()),
        }
    }
}

/// When a direct path's loss makes it lose to a relay (see the module rules).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LossRule {
    /// The segment size in the loss-limited throughput estimate: cmux-wg's
    /// TCP MSS inside a 1420-byte tunnel MTU over a relay-sized path.
    pub segment_bytes: u64,
    /// A path turns lossy when its loss-limited throughput is below this.
    pub lossy_below_kbps: u64,
    /// Datagrams the estimate needs before it may turn a path lossy.
    pub min_samples: u32,
    /// Each datagram weighs `1 / window` of the estimate (exponential decay).
    pub window: u32,
    /// Answered probes on a lossy path before its verdict is retried...
    pub retry_after_answers: u32,
    /// ...doubling on each demotion in a row, up to this.
    pub max_retry_after_answers: u32,
}

impl Default for LossRule {
    fn default() -> Self {
        // A desktop stream needs about 1.7 Mbit/s (60 fps of 3.5 KB frames);
        // 3 Mbit/s leaves headroom. 50 ms / 2 % estimates 1.6 Mbit/s,
        // 150 ms / 1 % 0.75 and 100 ms / 3 % 0.65: all lossy. 50 ms / 0.5 %
        // (3.2) and 20 ms / 2 % (4.0) stay direct.
        Self {
            segment_bytes: 1160,
            lossy_below_kbps: 3_000,
            min_samples: 512,
            window: 2048,
            retry_after_answers: 2,
            max_retry_after_answers: 32,
        }
    }
}

impl LossRule {
    /// The throughput one TCP stream holds at loss `p` (0..1) and `rtt_us`,
    /// in kbit/s (Mathis et al. 1997); `None` without loss or an RTT.
    pub fn limited_kbps(&self, p: f64, rtt_us: u64) -> Option<f64> {
        if p <= 0.0 || rtt_us == 0 {
            return None;
        }
        // bits per RTT, times 1000 / rtt_us = kbit/s.
        Some(self.segment_bytes as f64 * 8.0 * 1.22 * 1000.0 / (rtt_us as f64 * p.sqrt()))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathState {
    /// Never answered since it was added or since the last network change.
    Probing,
    Alive,
    /// Answered before, but missed its latest probe or went silent; not yet
    /// dead. While the current path is suspect, datagrams go on every path.
    Suspect,
    Dead,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    Answered { rtt_us: u64 },
    Lost,
}

/// A change of the current path. `to == None` means "send on every path".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Switch {
    pub from: Option<PathId>,
    pub to: Option<PathId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PathView {
    pub id: PathId,
    pub kind: PathKind,
    /// What the path rides; ranks paths inside a class.
    pub medium: Medium,
    pub state: PathState,
    /// Smoothed RTT (EWMA, weight 1/4 for each new answer).
    pub rtt_us: Option<u64>,
    /// Measured datagram loss in parts per million, once the engine reported
    /// [`LossRule::min_samples`] datagrams on the path.
    pub loss_ppm: Option<u32>,
    /// A path whose loss makes it rank below every path that is not.
    pub lossy: bool,
}

impl PathView {
    /// The rank compared before any RTT: lossy last, then class, then
    /// medium.
    pub fn rank(&self) -> (bool, PathClass, Medium) {
        (self.lossy, self.kind.class(), self.medium)
    }
}

/// The medium a path of `kind` rides when the engine does not know better.
pub fn default_medium(kind: PathKind) -> Medium {
    match kind {
        PathKind::DirectLan => Medium::Lan,
        _ => Medium::Routed,
    }
}

#[derive(Debug, Clone)]
struct Path {
    view: PathView,
    lost: u8,
    better_streak: u8,
    loss: LossEstimate,
}

/// Decayed counts of datagrams delivered and lost on one path, and the
/// lossy verdict's retry state.
#[derive(Debug, Clone, Copy, Default)]
struct LossEstimate {
    delivered: f64,
    lost: f64,
    /// Datagrams reported since the last reset, for `min_samples`.
    samples: u64,
    /// Answered probes since the path turned lossy.
    answers_while_lossy: u32,
    /// Demotions in a row (reset once the path stays healthy past its
    /// samples), for the retry backoff.
    demotions: u32,
}

impl LossEstimate {
    fn add(&mut self, rule: &LossRule, delivered: u64, lost: u64) {
        let total = delivered.saturating_add(lost);
        let keep = 1.0 - 1.0 / f64::from(rule.window.max(1));
        let scale = keep.powi(i32::try_from(total).unwrap_or(i32::MAX));
        self.delivered = self.delivered * scale + delivered as f64;
        self.lost = self.lost * scale + lost as f64;
        self.samples = self.samples.saturating_add(total);
    }

    fn ratio(&self) -> f64 {
        let total = self.delivered + self.lost;
        if total <= 0.0 { 0.0 } else { self.lost / total }
    }

    fn judged(&self, rule: &LossRule) -> bool {
        self.samples >= u64::from(rule.min_samples)
    }

    fn retry_after(&self, rule: &LossRule) -> u32 {
        let shift = self.demotions.saturating_sub(1).min(16);
        rule.retry_after_answers.saturating_mul(1 << shift).min(rule.max_retry_after_answers)
    }

    fn restart(&mut self) {
        let demotions = self.demotions;
        *self = Self { demotions, ..Self::default() };
    }
}

#[derive(Debug, Clone)]
pub struct Selector {
    config: SelectorConfig,
    paths: Vec<Path>,
    /// The held path (`chosen()`): `current()` is this path only while
    /// it is alive.
    held_id: Option<PathId>,
    retired: Vec<PathId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectorError {
    DuplicatePath(PathId),
    UnknownPath(PathId),
}

impl Selector {
    pub fn new(config: SelectorConfig) -> Self {
        Self { config, paths: Vec::new(), held_id: None, retired: Vec::new() }
    }

    /// The path the next datagram takes; `None` means every path (a dial,
    /// every path dead, or the chosen path is suspect).
    pub fn current(&self) -> Option<PathId> {
        let id = self.held_id?;
        let path = self.paths.iter().find(|path| path.view.id == id)?;
        (path.view.state == PathState::Alive).then_some(id)
    }

    /// The path the selector holds to, even while it is suspect.
    pub fn chosen(&self) -> Option<PathId> {
        self.held_id
    }

    pub fn paths(&self) -> impl Iterator<Item = PathView> + '_ {
        self.paths.iter().map(|path| path.view)
    }

    pub fn path(&self, id: PathId) -> Option<PathView> {
        self.paths.iter().find(|path| path.view.id == id).map(|path| path.view)
    }

    pub fn add_path(&mut self, id: PathId, kind: PathKind) -> Result<(), SelectorError> {
        self.add_path_on(id, kind, default_medium(kind))
    }

    /// Adds a path whose medium the engine read from its interface table.
    pub fn add_path_on(
        &mut self,
        id: PathId,
        kind: PathKind,
        medium: Medium,
    ) -> Result<(), SelectorError> {
        if self.find(id).is_some() || self.retired.contains(&id) {
            return Err(SelectorError::DuplicatePath(id));
        }
        self.paths.push(Path {
            view: PathView {
                id,
                kind,
                medium,
                state: PathState::Probing,
                rtt_us: None,
                loss_ppm: None,
                lossy: false,
            },
            lost: 0,
            better_streak: 0,
            loss: LossEstimate::default(),
        });
        Ok(())
    }

    pub fn remove_path(&mut self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        let index = self.find(id).ok_or(SelectorError::UnknownPath(id))?;
        let before = self.current();
        self.paths.remove(index);
        self.retired.push(id);
        Ok(self.reselect(before))
    }

    pub fn on_probe(
        &mut self,
        id: PathId,
        outcome: ProbeOutcome,
    ) -> Result<Option<Switch>, SelectorError> {
        let dead_after = self.config.dead_after_lost;
        let before = self.current();
        let path = self
            .paths
            .iter_mut()
            .find(|path| path.view.id == id)
            .ok_or(SelectorError::UnknownPath(id))?;
        match outcome {
            ProbeOutcome::Answered { rtt_us } => {
                path.lost = 0;
                path.view.state = PathState::Alive;
                path.view.rtt_us = Some(match path.view.rtt_us {
                    Some(old) => (old.saturating_mul(3).saturating_add(rtt_us)) / 4,
                    None => rtt_us,
                });
                if let Some(rule) = self.config.loss {
                    if path.view.lossy {
                        path.loss.answers_while_lossy =
                            path.loss.answers_while_lossy.saturating_add(1);
                        if path.loss.answers_while_lossy >= path.loss.retry_after(&rule) {
                            // Retry: the estimate starts over and the path
                            // ranks as direct until its new samples judge it.
                            path.loss.restart();
                            path.view.lossy = false;
                            path.view.loss_ppm = None;
                            path.better_streak = 0;
                        }
                    } else {
                        judge_loss(&rule, path);
                    }
                }
                self.update_streaks(id);
            }
            ProbeOutcome::Lost => {
                path.lost = path.lost.saturating_add(1);
                path.better_streak = 0;
                if path.lost >= dead_after {
                    path.view.state = PathState::Dead;
                } else if path.view.state != PathState::Probing {
                    path.view.state = PathState::Suspect;
                }
            }
        }
        Ok(self.reselect(before))
    }

    /// The engine sent on `id` and heard nothing back from it for longer
    /// than the path's round trip allows: an alive path turns suspect at
    /// once, without waiting for a probe to time out. The next answer on it
    /// makes it alive again.
    pub fn on_silence(&mut self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        let before = self.current();
        let path = self
            .paths
            .iter_mut()
            .find(|path| path.view.id == id)
            .ok_or(SelectorError::UnknownPath(id))?;
        if path.view.state == PathState::Alive {
            path.view.state = PathState::Suspect;
            path.better_streak = 0;
        }
        Ok(self.reselect(before))
    }

    /// The engine counted `delivered` datagrams and `lost` ones on `id`
    /// since its last report (gaps in what arrived on the path). With a
    /// [`LossRule`], this can make the path lossy, and the session then
    /// moves at once to an alive path that is not (a relay).
    pub fn on_loss_sample(
        &mut self,
        id: PathId,
        delivered: u64,
        lost: u64,
    ) -> Result<Option<Switch>, SelectorError> {
        let before = self.current();
        let rule = self.config.loss;
        let path = self
            .paths
            .iter_mut()
            .find(|path| path.view.id == id)
            .ok_or(SelectorError::UnknownPath(id))?;
        let Some(rule) = rule else { return Ok(None) };
        if path.view.lossy || delivered.saturating_add(lost) == 0 {
            // A demoted path's stragglers do not judge it again; its retry
            // does (`on_probe`).
            return Ok(None);
        }
        path.loss.add(&rule, delivered, lost);
        if !judge_loss(&rule, path) {
            return Ok(None);
        }
        for path in &mut self.paths {
            path.better_streak = 0;
        }
        Ok(self.reselect(before))
    }

    /// The peer stopped sending on `id` and sends on a relay instead: it
    /// judged the path lossy from its side (each end sees only the loss of
    /// what it receives). With a [`LossRule`], `id` turns lossy here too, with
    /// the same retry backoff, so both directions move together.
    pub fn on_peer_left(&mut self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        let before = self.current();
        let rule = self.config.loss;
        let path = self
            .paths
            .iter_mut()
            .find(|path| path.view.id == id)
            .ok_or(SelectorError::UnknownPath(id))?;
        if rule.is_none() || path.view.lossy {
            return Ok(None);
        }
        path.view.lossy = true;
        path.loss.answers_while_lossy = 0;
        path.loss.demotions = path.loss.demotions.saturating_add(1);
        for path in &mut self.paths {
            path.better_streak = 0;
        }
        Ok(self.reselect(before))
    }

    /// A path's medium, read again from a changed interface table. Takes
    /// effect at the next reselection (the network change that follows).
    pub fn set_medium(&mut self, id: PathId, medium: Medium) -> Result<(), SelectorError> {
        let path = self
            .paths
            .iter_mut()
            .find(|path| path.view.id == id)
            .ok_or(SelectorError::UnknownPath(id))?;
        path.view.medium = medium;
        Ok(())
    }

    /// The local network changed (interface, address, or wake from sleep).
    pub fn on_network_change(&mut self) -> Option<Switch> {
        let before = self.current();
        for path in &mut self.paths {
            path.view.state = PathState::Probing;
            path.view.rtt_us = None;
            path.view.loss_ppm = None;
            path.view.lossy = false;
            path.lost = 0;
            path.better_streak = 0;
            path.loss = LossEstimate::default();
        }
        self.reselect(before)
    }

    fn find(&self, id: PathId) -> Option<usize> {
        self.paths.iter().position(|path| path.view.id == id)
    }

    fn alive(&self, id: Option<PathId>) -> Option<&Path> {
        let id = id?;
        let path = self.paths.iter().find(|path| path.view.id == id)?;
        (path.view.state == PathState::Alive).then_some(path)
    }

    /// After an answer on `answered`: a challenger's own answer advances its
    /// streak when it beats the current path by the margin and resets it
    /// otherwise; an answer of the current path can only reset streaks (a
    /// challenger that no longer beats it starts over), never advance them.
    fn update_streaks(&mut self, answered: PathId) {
        let Some(incumbent) = self.alive(self.held_id).map(|path| path.view) else {
            return;
        };
        let config = self.config;
        for path in &mut self.paths {
            let view = path.view;
            if view.id == incumbent.id
                || view.state != PathState::Alive
                || view.rank() != incumbent.rank()
            {
                continue;
            }
            let beats = beats_by_margin(&config, &view, &incumbent);
            if view.id == answered {
                path.better_streak = if beats { path.better_streak.saturating_add(1) } else { 0 };
            } else if incumbent.id == answered && !beats {
                path.better_streak = 0;
            }
        }
    }

    fn best_alive(&self) -> Option<&Path> {
        self.paths.iter().filter(|path| path.view.state == PathState::Alive).min_by_key(|path| {
            (path.view.rank(), path.view.rtt_us.unwrap_or(u64::MAX), path.view.id)
        })
    }

    /// The chosen path while it is alive or suspect: a suspect is held (and
    /// sprayed around) until it answers or dies.
    fn held(&self) -> Option<&Path> {
        let id = self.held_id?;
        self.paths.iter().find(|path| {
            path.view.id == id && matches!(path.view.state, PathState::Alive | PathState::Suspect)
        })
    }

    /// Picks the chosen path and reports a change of what `current()`
    /// answers since `before`.
    fn reselect(&mut self, before: Option<PathId>) -> Option<Switch> {
        let chosen = self.held_id;
        let to = match (self.held(), self.best_alive()) {
            (held, None) => held.map(|path| path.view.id),
            (None, Some(best)) => Some(best.view.id),
            (Some(held), Some(best)) => {
                let rank = held.view.rank();
                let challenger = self
                    .paths
                    .iter()
                    .filter(|path| {
                        held.view.state == PathState::Alive
                            && path.view.state == PathState::Alive
                            && path.view.rank() == rank
                            && path.better_streak >= self.config.switch_streak
                            && beats_by_margin(&self.config, &path.view, &held.view)
                    })
                    .min_by_key(|path| (path.view.rtt_us.unwrap_or(u64::MAX), path.view.id));
                if best.view.rank() < rank {
                    Some(best.view.id)
                } else if let Some(challenger) = challenger {
                    Some(challenger.view.id)
                } else {
                    Some(held.view.id)
                }
            }
        };
        if to != chosen {
            self.held_id = to;
            for path in &mut self.paths {
                path.better_streak = 0;
            }
        }
        let after = self.current();
        // A held path that dies while it was being sprayed around changes
        // nothing visible (`current()` stays None) but is still news: it is
        // when callers learn the path is gone and what it lost.
        let held_died = chosen.is_some() && self.chosen().is_none();
        (after != before || held_died).then_some(Switch { from: before, to: after })
    }
}

/// Updates a path that is not lossy from its estimate and RTT; true when it
/// turned lossy.
fn judge_loss(rule: &LossRule, path: &mut Path) -> bool {
    if path.view.lossy || !path.loss.judged(rule) {
        return false;
    }
    let p = path.loss.ratio();
    path.view.loss_ppm = Some((p * 1_000_000.0).round() as u32);
    let Some(rtt_us) = path.view.rtt_us else { return false };
    let kbps = rule.limited_kbps(p, rtt_us).unwrap_or(f64::INFINITY);
    if kbps < rule.lossy_below_kbps as f64 {
        path.view.lossy = true;
        path.loss.answers_while_lossy = 0;
        path.loss.demotions = path.loss.demotions.saturating_add(1);
        return true;
    }
    if path.loss.demotions > 0 && path.loss.samples >= 4 * u64::from(rule.window) {
        // Healthy for four windows since its last demotion: the backoff
        // starts over.
        path.loss.demotions = 0;
    }
    false
}

/// Whether `challenger` beats `incumbent` by the hysteresis margin.
fn beats_by_margin(config: &SelectorConfig, challenger: &PathView, incumbent: &PathView) -> bool {
    let (Some(new), Some(old)) = (challenger.rtt_us, incumbent.rtt_us) else {
        return false;
    };
    let margin = config.min_gain_us.max(old.saturating_mul(config.min_gain_percent) / 100);
    new.saturating_add(margin) <= old
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAN: PathId = PathId(0);
    const LINK: PathId = PathId(1);
    const RELAY: PathId = PathId(2);

    fn answer(selector: &mut Selector, id: PathId, rtt_us: u64) -> Option<Switch> {
        selector.on_probe(id, ProbeOutcome::Answered { rtt_us }).unwrap()
    }

    fn lose(selector: &mut Selector, id: PathId) -> Option<Switch> {
        selector.on_probe(id, ProbeOutcome::Lost).unwrap()
    }

    /// Wired LAN, a Thunderbolt Bridge and a relay to the same peer.
    fn three_paths() -> Selector {
        let mut selector = Selector::new(SelectorConfig::default());
        selector.add_path_on(LAN, PathKind::DirectLan, Medium::Lan).unwrap();
        selector.add_path_on(LINK, PathKind::DirectLan, Medium::Link).unwrap();
        selector.add_path(RELAY, PathKind::DoRelay).unwrap();
        selector
    }

    #[test]
    fn a_thunderbolt_path_wins_at_once_though_the_rtt_margin_never_would() {
        let mut selector = three_paths();
        answer(&mut selector, LAN, 500);
        assert_eq!(selector.current(), Some(LAN));
        // 0.3 ms vs 0.5 ms is far inside the 3 ms hysteresis margin.
        let switch = answer(&mut selector, LINK, 300);
        assert_eq!(switch, Some(Switch { from: Some(LAN), to: Some(LINK) }));
        assert_eq!(selector.current(), Some(LINK));
    }

    #[test]
    fn a_slower_lan_answer_never_unseats_the_link() {
        let mut selector = three_paths();
        answer(&mut selector, LINK, 900);
        for _ in 0..10 {
            assert_eq!(answer(&mut selector, LAN, 100), None);
        }
        assert_eq!(selector.current(), Some(LINK));
    }

    #[test]
    fn a_lan_path_still_beats_the_relay_at_once() {
        let mut selector = three_paths();
        answer(&mut selector, RELAY, 40_000);
        assert_eq!(selector.current(), Some(RELAY));
        answer(&mut selector, LAN, 60_000);
        assert_eq!(selector.current(), Some(LAN), "class first, whatever the RTT");
    }

    #[test]
    fn a_silent_current_path_sprays_until_it_answers() {
        let mut selector = three_paths();
        answer(&mut selector, RELAY, 40_000);
        answer(&mut selector, LINK, 300);
        assert_eq!(selector.current(), Some(LINK));
        let switch = selector.on_silence(LINK).unwrap();
        assert_eq!(switch, Some(Switch { from: Some(LINK), to: None }), "every path at once");
        assert_eq!(selector.chosen(), Some(LINK));
        let switch = answer(&mut selector, LINK, 300);
        assert_eq!(switch, Some(Switch { from: None, to: Some(LINK) }));
    }

    #[test]
    fn a_dropped_fast_path_sprays_then_falls_back_when_it_dies() {
        let mut selector = three_paths();
        answer(&mut selector, RELAY, 40_000);
        answer(&mut selector, LINK, 300);
        assert_eq!(lose(&mut selector, LINK), Some(Switch { from: Some(LINK), to: None }));
        assert_eq!(lose(&mut selector, LINK), None, "still suspect: still every path");
        let switch = lose(&mut selector, LINK);
        assert_eq!(switch, Some(Switch { from: None, to: Some(RELAY) }));
        assert_eq!(selector.path(LINK).unwrap().state, PathState::Dead);
        // It comes back: the link wins again at once.
        assert_eq!(
            answer(&mut selector, LINK, 300),
            Some(Switch { from: Some(RELAY), to: Some(LINK) })
        );
    }

    #[test]
    fn a_suspect_with_nothing_else_alive_keeps_spraying() {
        let mut selector = three_paths();
        answer(&mut selector, LAN, 500);
        selector.on_silence(LAN).unwrap();
        assert_eq!(selector.current(), None);
        assert_eq!(selector.chosen(), Some(LAN));
        assert_eq!(lose(&mut selector, LAN), None, "still suspect, nothing visible changed");
        lose(&mut selector, LAN);
        let died = lose(&mut selector, LAN);
        assert_eq!(
            died,
            Some(Switch { from: None, to: None }),
            "the held path's death is reported"
        );
        assert_eq!(selector.chosen(), None);
    }

    #[test]
    fn silence_on_a_path_that_is_not_alive_changes_nothing() {
        let mut selector = three_paths();
        assert_eq!(selector.on_silence(LAN).unwrap(), None);
        assert_eq!(selector.path(LAN).unwrap().state, PathState::Probing);
    }

    #[test]
    fn rtt_hysteresis_still_decides_between_paths_of_one_medium() {
        let mut selector = Selector::new(SelectorConfig::default());
        selector.add_path_on(LAN, PathKind::DirectLan, Medium::Lan).unwrap();
        selector.add_path_on(LINK, PathKind::DirectLan, Medium::Lan).unwrap();
        answer(&mut selector, LAN, 20_000);
        answer(&mut selector, LINK, 2_000);
        assert_eq!(selector.current(), Some(LAN), "one answer is not a streak");
        answer(&mut selector, LINK, 2_000);
        answer(&mut selector, LINK, 2_000);
        assert_eq!(selector.current(), Some(LINK));
    }

    /// A direct WAN path and a relay, the WAN answering first.
    fn wan_and_relay() -> Selector {
        let mut selector = Selector::new(SelectorConfig::default());
        selector.add_path(LAN, PathKind::DirectWan).unwrap();
        selector.add_path(RELAY, PathKind::DoRelay).unwrap();
        answer(&mut selector, LAN, 50_000);
        answer(&mut selector, RELAY, 60_000);
        assert_eq!(selector.current(), Some(LAN));
        selector
    }

    /// Reports `n` datagrams on `id` at loss `percent`, in batches of 100.
    fn traffic(selector: &mut Selector, id: PathId, n: u64, percent: u64) -> Option<Switch> {
        let mut last = None;
        for _ in 0..n / 100 {
            if let Some(switch) = selector.on_loss_sample(id, 100 - percent, percent).unwrap() {
                last = Some(switch);
            }
        }
        last
    }

    #[test]
    fn the_loss_limit_matches_the_measured_wg_tcp_ceiling() {
        let rule = LossRule::default();
        // connectivity-map 3.2 measured 1.6 Mbit/s at 50 ms / 2 % and 0.7
        // at 150 ms / 1 %.
        let at = |p: f64, rtt_ms: u64| rule.limited_kbps(p, rtt_ms * 1000).unwrap();
        assert!((1_500.0..1_700.0).contains(&at(0.02, 50)), "{}", at(0.02, 50));
        assert!((700.0..800.0).contains(&at(0.01, 150)), "{}", at(0.01, 150));
        assert!(at(0.03, 100) < 3_000.0);
        assert!(at(0.005, 50) > 3_000.0, "50 ms / 0.5 % stays direct");
        assert!(at(0.02, 20) > 3_000.0, "20 ms / 2 % stays direct");
        assert_eq!(rule.limited_kbps(0.0, 50_000), None);
    }

    #[test]
    fn a_lossy_direct_path_loses_to_the_relay_at_once() {
        let mut selector = wan_and_relay();
        let switch = traffic(&mut selector, LAN, 1_000, 2);
        assert_eq!(switch, Some(Switch { from: Some(LAN), to: Some(RELAY) }));
        let view = selector.path(LAN).unwrap();
        assert!(view.lossy);
        assert_eq!(view.state, PathState::Alive, "lossy is not dead");
        assert!((15_000..25_000).contains(&view.loss_ppm.unwrap()), "{view:?}");
        // Its answers alone do not bring it back before the retry.
        assert_eq!(answer(&mut selector, LAN, 50_000), None);
        assert_eq!(selector.current(), Some(RELAY));
    }

    #[test]
    fn a_clean_or_short_direct_path_keeps_the_session() {
        let mut selector = wan_and_relay();
        assert_eq!(traffic(&mut selector, LAN, 10_000, 0), None);
        // 2 % on a 20 ms path still holds 4 Mbit/s.
        let mut short = Selector::new(SelectorConfig::default());
        short.add_path(LAN, PathKind::DirectWan).unwrap();
        short.add_path(RELAY, PathKind::DoRelay).unwrap();
        answer(&mut short, LAN, 20_000);
        answer(&mut short, RELAY, 30_000);
        assert_eq!(traffic(&mut short, LAN, 10_000, 2), None);
        assert_eq!(short.current(), Some(LAN));
    }

    #[test]
    fn too_few_datagrams_never_judge_a_path() {
        let mut selector = wan_and_relay();
        // 50 % loss, but only 400 datagrams.
        assert_eq!(traffic(&mut selector, LAN, 400, 50), None);
        assert_eq!(selector.current(), Some(LAN));
        assert!(!selector.path(LAN).unwrap().lossy);
    }

    #[test]
    fn without_a_loss_rule_loss_changes_nothing() {
        let mut selector =
            Selector::new(SelectorConfig { loss: None, ..SelectorConfig::default() });
        selector.add_path(LAN, PathKind::DirectWan).unwrap();
        selector.add_path(RELAY, PathKind::DoRelay).unwrap();
        answer(&mut selector, LAN, 50_000);
        answer(&mut selector, RELAY, 60_000);
        assert_eq!(traffic(&mut selector, LAN, 10_000, 5), None);
        assert_eq!(selector.current(), Some(LAN));
    }

    #[test]
    fn a_lossy_path_is_retried_with_a_growing_backoff() {
        let mut selector = wan_and_relay();
        traffic(&mut selector, LAN, 1_000, 2);
        assert_eq!(selector.current(), Some(RELAY));
        // First retry after two answers: the direct path wins again...
        answer(&mut selector, LAN, 50_000);
        let switch = answer(&mut selector, LAN, 50_000);
        assert_eq!(switch, Some(Switch { from: Some(RELAY), to: Some(LAN) }));
        assert_eq!(selector.path(LAN).unwrap().loss_ppm, None, "the estimate starts over");
        // ...until its new samples judge it again; the next retry waits four.
        traffic(&mut selector, LAN, 1_000, 2);
        assert_eq!(selector.current(), Some(RELAY));
        for _ in 0..3 {
            assert_eq!(answer(&mut selector, LAN, 50_000), None);
        }
        assert_eq!(
            answer(&mut selector, LAN, 50_000),
            Some(Switch { from: Some(RELAY), to: Some(LAN) })
        );
        // Healed: it stays, and four clean windows start the backoff over.
        assert_eq!(traffic(&mut selector, LAN, 10_000, 0), None);
        traffic(&mut selector, LAN, 1_000, 5);
        assert_eq!(selector.current(), Some(RELAY));
        answer(&mut selector, LAN, 50_000);
        assert_eq!(selector.current(), Some(RELAY));
        answer(&mut selector, LAN, 50_000);
        assert_eq!(selector.current(), Some(LAN), "two answers again after the reset");
    }

    #[test]
    fn a_lossy_relay_ranks_below_a_clean_one_and_a_lossy_direct_above_a_lossy_relay() {
        const TURN: PathId = PathId(3);
        let mut selector = Selector::new(SelectorConfig::default());
        selector.add_path(LAN, PathKind::DirectWan).unwrap();
        selector.add_path(TURN, PathKind::TurnRelay).unwrap();
        answer(&mut selector, LAN, 50_000);
        answer(&mut selector, TURN, 60_000);
        traffic(&mut selector, TURN, 1_000, 3);
        assert!(selector.path(TURN).unwrap().lossy);
        traffic(&mut selector, LAN, 1_000, 3);
        assert!(selector.path(LAN).unwrap().lossy);
        assert_eq!(selector.current(), Some(LAN), "both lossy: class decides again");
    }

    #[test]
    fn a_network_change_forgets_the_loss() {
        let mut selector = wan_and_relay();
        traffic(&mut selector, LAN, 1_000, 2);
        selector.on_network_change();
        answer(&mut selector, LAN, 50_000);
        let view = selector.path(LAN).unwrap();
        assert!(!view.lossy);
        assert_eq!(view.loss_ppm, None);
        assert_eq!(selector.current(), Some(LAN));
    }

    #[test]
    fn a_path_the_peer_left_turns_lossy_here_too() {
        let mut selector = wan_and_relay();
        let switch = selector.on_peer_left(LAN).unwrap();
        assert_eq!(switch, Some(Switch { from: Some(LAN), to: Some(RELAY) }));
        assert!(selector.path(LAN).unwrap().lossy);
        assert_eq!(selector.on_peer_left(LAN).unwrap(), None, "once");
        answer(&mut selector, LAN, 50_000);
        answer(&mut selector, LAN, 50_000);
        assert_eq!(selector.current(), Some(LAN), "retried like any lossy path");
    }
}
