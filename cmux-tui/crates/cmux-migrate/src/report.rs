//! A measurement of real migrations that is safe to share (RFD 0173, "Measured on every apply"):
//! counts and durations only. A [`Report`] keeps no project key, path, repo, machine id, name or
//! error text, so a person can hand it on and a team can add everyone's together ([`Report::add`])
//! into one success rate and one time to first working chat.
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put
//! in fleet wide pauses, esp when this is stuff that materially improves the app".

use serde::{Deserialize, Serialize};

use crate::ledger::{Ledger, Stage};

pub const VERSION: u32 = 1;

/// The ten-minute line the RFD holds a typical move to.
pub const TEN_MINUTES_MS: i64 = 10 * 60 * 1000;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub version: u32,
    /// Ledgers added in: one per person for a team roll-up.
    pub people: usize,
    /// Projects a move was started for and not undone.
    pub attempted: usize,
    pub done: usize,
    pub failed: usize,
    /// Started, neither done nor failed: a run cut off, resumed next time.
    pub pending: usize,
    /// Move start to first working chat, per measured project, ascending.
    pub first_chat_ms: Vec<i64>,
}

/// What a report says, worked out.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Summary {
    pub people: usize,
    pub attempted: usize,
    pub done: usize,
    pub failed: usize,
    pub pending: usize,
    /// Done over attempted, in percent; none before any attempt.
    pub success_pct: Option<f64>,
    /// Projects whose first working chat was timed.
    pub measured: usize,
    pub median_first_chat_ms: Option<i64>,
    pub p90_first_chat_ms: Option<i64>,
    pub max_first_chat_ms: Option<i64>,
    /// Measured moves at or under [`TEN_MINUTES_MS`].
    pub under_ten_minutes: usize,
}

impl Report {
    /// One person's ledger. Only projects count: the `_machine-wide` carry entry is left out, as
    /// in [`Ledger::stats`].
    pub fn of(ledger: &Ledger) -> Self {
        let wide = format!("/{}", crate::apply::MACHINE_WIDE);
        let mut report = Self { version: VERSION, people: 1, ..Self::default() };
        for (_, entry) in ledger.projects.iter().filter(|(key, _)| !key.ends_with(&wide)) {
            match entry.stage {
                Stage::Undone => continue,
                Stage::Done => report.done += 1,
                Stage::Failed => report.failed += 1,
                Stage::Pending => report.pending += 1,
            }
            report.attempted += 1;
            if let Some(ms) =
                entry.first_chat_ms.zip(entry.started_ms).and_then(|(f, s)| f.checked_sub(s))
                && ms >= 0
            {
                report.first_chat_ms.push(ms);
            }
        }
        report.first_chat_ms.sort_unstable();
        report
    }

    /// Adds `other` in (a team roll-up).
    pub fn add(&mut self, other: &Report) {
        self.version = VERSION;
        self.people += other.people;
        self.attempted += other.attempted;
        self.done += other.done;
        self.failed += other.failed;
        self.pending += other.pending;
        self.first_chat_ms.extend(other.first_chat_ms.iter().copied().filter(|ms| *ms >= 0));
        self.first_chat_ms.sort_unstable();
    }

    pub fn summary(&self) -> Summary {
        let times = &self.first_chat_ms;
        // Nearest rank: the smallest time at or above `pct` percent of the measured ones.
        let rank = |pct: usize| {
            let n = times.len();
            (n > 0).then(|| times[(n * pct).div_ceil(100).clamp(1, n) - 1])
        };
        Summary {
            people: self.people,
            attempted: self.attempted,
            done: self.done,
            failed: self.failed,
            pending: self.pending,
            success_pct: (self.attempted > 0)
                .then(|| (self.done as f64 * 1000.0 / self.attempted as f64).round() / 10.0),
            measured: times.len(),
            median_first_chat_ms: rank(50),
            p90_first_chat_ms: rank(90),
            max_first_chat_ms: times.last().copied(),
            under_ten_minutes: times.iter().filter(|ms| **ms <= TEN_MINUTES_MS).count(),
        }
    }

    /// One line for a person.
    pub fn line(&self) -> String {
        let s = self.summary();
        let mut line = format!("{} of {} projects moved", s.done, s.attempted);
        if let Some(pct) = s.success_pct {
            line.push_str(&format!(" ({pct}%)"));
        }
        if self.people > 1 {
            line.push_str(&format!(" across {} people", self.people));
        }
        if let (Some(median), Some(p90)) = (s.median_first_chat_ms, s.p90_first_chat_ms) {
            line.push_str(&format!(
                "; time to first chat median {:.1} s, p90 {:.1} s, {} of {} under ten minutes",
                median as f64 / 1000.0,
                p90 as f64 / 1000.0,
                s.under_ten_minutes,
                s.measured
            ));
        }
        line
    }
}

#[cfg(test)]
#[path = "report_tests.rs"]
mod tests;
