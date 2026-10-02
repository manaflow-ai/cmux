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
//! - Inside a class the lower smoothed RTT wins, but only after the
//!   challenger beat the current path by the margin on `switch_streak`
//!   consecutive answers (hysteresis), so jitter never flaps the path.
//! - A local network change sends direct paths back to probing and keeps
//!   relays, so traffic moves to a relay until a direct path answers again.

use crate::path::{PathId, PathKind};

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
    pub state: PathState,
    /// Smoothed RTT (EWMA, weight 1/4 for each new answer).
    pub rtt_us: Option<u64>,
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
    current: Option<PathId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectorError {
    DuplicatePath(PathId),
    UnknownPath(PathId),
}

impl Selector {
    pub fn new(config: SelectorConfig) -> Self {
        Self { config, paths: Vec::new(), current: None }
    }

    pub fn current(&self) -> Option<PathId> {
        self.current
    }

    pub fn paths(&self) -> impl Iterator<Item = PathView> + '_ {
        self.paths.iter().map(|path| path.view)
    }

    pub fn path(&self, id: PathId) -> Option<PathView> {
        self.find(id).map(|index| self.paths[index].view)
    }

    pub fn add_path(&mut self, id: PathId, kind: PathKind) -> Result<(), SelectorError> {
        if self.find(id).is_some() {
            return Err(SelectorError::DuplicatePath(id));
        }
        self.paths.push(Path {
            view: PathView { id, kind, state: PathState::Probing, rtt_us: None },
            lost: 0,
            better_streak: 0,
        });
        Ok(())
    }

    pub fn remove_path(&mut self, id: PathId) -> Result<Option<Switch>, SelectorError> {
        let index = self.find(id).ok_or(SelectorError::UnknownPath(id))?;
        self.paths.remove(index);
        Ok(self.reselect())
    }

    pub fn on_probe(&mut self, id: PathId, outcome: ProbeOutcome) -> Result<Option<Switch>, SelectorError> {
        let index = self.find(id).ok_or(SelectorError::UnknownPath(id))?;
        let dead_after = self.config.dead_after_lost;
        let path = &mut self.paths[index];
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
                }
            }
        }
        Ok(self.reselect())
    }

    /// The local network changed (interface, address, or wake from sleep).
    pub fn on_network_change(&mut self) -> Option<Switch> {
        for path in &mut self.paths {
            if path.view.kind.depends_on_local_address() {
                path.view.state = PathState::Probing;
                path.view.rtt_us = None;
                path.lost = 0;
                path.better_streak = 0;
            }
        }
        self.reselect()
    }

    fn find(&self, id: PathId) -> Option<usize> {
        self.paths.iter().position(|path| path.view.id == id)
    }

    fn alive(&self, id: Option<PathId>) -> Option<&Path> {
        let index = self.find(id?)?;
        let path = &self.paths[index];
        (path.view.state == PathState::Alive).then_some(path)
    }

    /// Whether `challenger` beats `incumbent` by the hysteresis margin.
    fn beats_by_margin(&self, challenger: &PathView, incumbent: &PathView) -> bool {
        let (Some(new), Some(old)) = (challenger.rtt_us, incumbent.rtt_us) else {
            return false;
        };
        let margin = self.config.min_gain_us.max(old.saturating_mul(self.config.min_gain_percent) / 100);
        new.saturating_add(margin) <= old
    }

    /// After an answer on `answered`, advance or reset the streak of every
    /// same-class challenger of the current path.
    fn update_streaks(&mut self, answered: PathId) {
        let Some(incumbent) = self.alive(self.current).map(|path| path.view) else {
            return;
        };
        let decisions: Vec<(usize, bool)> = self
            .paths
            .iter()
            .enumerate()
            .filter(|(_, path)| {
                path.view.id != incumbent.id
                    && path.view.state == PathState::Alive
                    && path.view.kind.class() == incumbent.kind.class()
                    && (path.view.id == answered || incumbent.id == answered)
            })
            .map(|(index, path)| (index, self.beats_by_margin(&path.view, &incumbent)))
            .collect();
        for (index, beats) in decisions {
            let path = &mut self.paths[index];
            path.better_streak = if beats { path.better_streak.saturating_add(1) } else { 0 };
        }
    }

    fn best_alive(&self) -> Option<&Path> {
        self.paths
            .iter()
            .filter(|path| path.view.state == PathState::Alive)
            .min_by_key(|path| (path.view.kind.class(), path.view.rtt_us.unwrap_or(u64::MAX), path.view.id))
    }

    fn reselect(&mut self) -> Option<Switch> {
        let from = self.current;
        let to = match (self.alive(from), self.best_alive()) {
            (_, None) => None,
            (None, Some(best)) => Some(best.view.id),
            (Some(current), Some(best)) => {
                let current_class = current.view.kind.class();
                let challenger = self
                    .paths
                    .iter()
                    .filter(|path| {
                        path.view.state == PathState::Alive
                            && path.view.kind.class() == current_class
                            && path.better_streak >= self.config.switch_streak
                            && self.beats_by_margin(&path.view, &current.view)
                    })
                    .min_by_key(|path| (path.view.rtt_us.unwrap_or(u64::MAX), path.view.id));
                if best.view.kind.class() < current_class {
                    Some(best.view.id)
                } else if let Some(challenger) = challenger {
                    Some(challenger.view.id)
                } else {
                    Some(current.view.id)
                }
            }
        };
        if to == from {
            return None;
        }
        self.current = to;
        for path in &mut self.paths {
            path.better_streak = 0;
        }
        Some(Switch { from, to })
    }
}
