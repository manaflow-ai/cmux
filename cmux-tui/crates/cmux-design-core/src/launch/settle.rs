//! `LaunchLayoutSettle`'s pure parts (Windows/LaunchLayoutSettle.swift): the mark name of a view
//! and the tally that decides when the launch layout settled and which marks it writes.

use serde::{Deserialize, Serialize};

/// `markName(_:)`: a view description's first word (to a space or `<`), `view` when empty.
pub fn mark_name(name: &str) -> String {
    let word: String = name.chars().take_while(|c| *c != ' ' && *c != '<').collect();
    if word.is_empty() { "view".into() } else { word }
}

pub const QUIET_MS: f64 = 1_500.;
pub const CAP_MS: f64 = 5_000.;

/// The largest move: a view's mark name and how far it moved (points).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Move {
    pub name: String,
    pub points: f64,
}

/// `LaunchLayoutSettleTally`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tally {
    pub first_ms: Option<f64>,
    pub last_change_ms: Option<f64>,
    pub last_changed: String,
    pub changed_frames: u64,
    pub largest: Option<Move>,
}

impl Tally {
    /// `first(at:)`.
    pub fn first(&mut self, ms: f64) {
        if self.first_ms.is_none() {
            self.first_ms = Some(ms);
        }
    }

    /// `note(at:change:move:)`: a frame whose layout changed (the first frame only starts the tally).
    pub fn note(&mut self, ms: f64, change: &str, mv: Option<Move>) {
        if self.first_ms.is_none() {
            return self.first(ms);
        }
        self.changed_frames += 1;
        self.last_change_ms = Some(ms);
        self.last_changed = change.to_string();
        if let Some(mv) = mv.filter(|m| m.points > self.largest.as_ref().map_or(0., |l| l.points)) {
            self.largest = Some(mv);
        }
    }

    /// `isOver(at:)`: quiet for 1.5 s, or 5 s since the first frame.
    pub fn is_over(&self, ms: f64) -> bool {
        let Some(first) = self.first_ms else { return false };
        ms - self.last_change_ms.unwrap_or(first) >= QUIET_MS || ms - first >= CAP_MS
    }

    /// `marks()`: the trace marks, in order.
    pub fn marks(&self) -> Vec<(String, f64)> {
        let Some(first) = self.first_ms else { return Vec::new() };
        let settle = self.last_change_ms.unwrap_or(first);
        let mut marks = vec![
            ("layout.first_frame".to_string(), first),
            ("layout.settle".to_string(), settle),
            ("layout.max_move".to_string(), self.largest.as_ref().map_or(0., |l| l.points)),
            ("layout.changed_frames".to_string(), self.changed_frames as f64),
        ];
        if let Some(l) = &self.largest {
            marks.push((format!("layout.max_move.{}", l.name), l.points));
        }
        if let Some(last) = self.last_change_ms {
            marks.push((format!("layout.last.{}", self.last_changed), settle));
            if last - first > CAP_MS - QUIET_MS {
                marks.push(("layout.capped".to_string(), settle));
            }
        }
        marks
    }
}
