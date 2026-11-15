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
//! - Any alive direct path beats every relay, at once.
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
}

impl Default for SelectorConfig {
    fn default() -> Self {
        Self { dead_after_lost: 3, switch_streak: 3, min_gain_us: 3_000, min_gain_percent: 10 }
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
}

impl PathView {
    /// The rank compared before any RTT: class, then medium.
    pub fn rank(&self) -> (PathClass, Medium) {
        (self.kind.class(), self.medium)
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
            view: PathView { id, kind, medium, state: PathState::Probing, rtt_us: None },
            lost: 0,
            better_streak: 0,
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
            path.lost = 0;
            path.better_streak = 0;
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

/// Whether `challenger` beats `incumbent` by the hysteresis margin.
fn beats_by_margin(config: &SelectorConfig, challenger: &PathView, incumbent: &PathView) -> bool {
    let (Some(new), Some(old)) = (challenger.rtt_us, incumbent.rtt_us) else {
        return false;
    };
    let margin = config.min_gain_us.max(old.saturating_mul(config.min_gain_percent) / 100);
    new.saturating_add(margin) <= old
}

#[cfg(test)]
mod tests;
