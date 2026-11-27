//! Auto on reserve (cmuxterm-hq RFD 0072, stage 1: shadow). The person keeps a
//! share of this computer ("Keep for me", `cloud.autoReservePercent`); agents
//! run here inside the rest, and Auto would move one agent to its own Cloud VM
//! only while the agents themselves use more than that rest. Leo, 2026-11-23:
//! "we should be able to auto-detect if your computer is under load, true load,
//! OR if they're affecting interactive speed".
//!
//! The verdict is about agents' own use, never the machine's total: a machine
//! busy with the person's own build while agents idle moves nothing.
//!
//! [`ReserveTracker::judge`] is the one function. It is pure: the time, the
//! setting and one [`ReserveSample`] in, a [`ReserveVerdict`] out. Rule 1 of
//! the RFD:
//! - the person is present (input within [`PRESENT_MS`]), and
//! - agents use more cores than their budget (performance cores minus the
//!   reserve) or more resident memory than theirs (RAM minus the reserve),
//! - held for [`HOLD_SAMPLES`] samples in a row (30 s at 3 s a sample).
//!
//! The other rules (RFD 0072 "The trigger"), each held the same 30 s:
//! 2. the person is present, CPU busy is at or over [`BUSY_SHARE`], agents use
//!    at least one core, and timer lateness p50 is over [`LATE_P50_MS`] or the
//!    app reports frames over 50 ms ([`ReserveReason::Interactive`]);
//! 3. memory pressure is above normal or swap grows faster than
//!    [`SWAP_GROWTH_MB_PER_MIN`], and agents hold at least a quarter of used
//!    memory; this one holds with the person away too
//!    ([`ReserveReason::MemoryPressure`]);
//! 4. thermal pressure is serious or worse and agents use at least one core
//!    ([`ReserveReason::Thermal`]).
//!
//! Rule 5 (sleep, lid, battery, disk) is `place.rs`'s in cmux-cloud-start-core.
//! With the person away agents may use up to [`AWAY_SHARE`] of the machine:
//! away is no reason to move, but past that line rule 1 judges against it.
//!
//! Then one agent would move out: among the agents that may move unasked, the
//! one using the largest share of the budget. So agents do not ping-pong:
//! - one move out per [`MOVE_GAP_MS`] at most;
//! - a moved agent stays out at least [`MIN_STAY_MS`] and returns only between
//!   turns, once agents' use plus what it last used fits in [`RETURN_FRACTION`]
//!   of the budget, with memory pressure normal, for [`RETURN_HOLD_MS`]; one
//!   return per [`RETURN_GAP_MS`] at most;
//! - an agent moved out twice within [`PIN_WINDOW_MS`] stays out until the
//!   person brings it back ([`ReserveTracker::brought_back`]).
//!
//! Stage 1 moves nothing: the tracker treats a would-be move as made, so its
//! hysteresis is the one a real Auto would have, and [`ShadowLine`] records
//! each verdict that is not a hold to `auto-shadow.jsonl` ([`append_shadow`]).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Names this rule in every shadow line; a change to a threshold bumps it.
pub const RESERVE_RULE_VERSION: &str = "auto-reserve/1";

/// The reserve's stops, as the slider offers them.
pub const RESERVE_STOPS: [u8; 4] = [0, 25, 50, 75];
/// The default reserve.
pub const DEFAULT_RESERVE_PERCENT: u8 = 50;

/// Rule 2: CPU busy at or over this share of the machine ...
pub const BUSY_SHARE: f64 = 0.90;
/// ... with timer lateness p50 over this.
pub const LATE_P50_MS: f64 = 1.0;
/// Rule 3: swap growing faster than this is memory pressure.
pub const SWAP_GROWTH_MB_PER_MIN: f64 = 64.0;
/// Away, agents may use this share of the machine.
pub const AWAY_SHARE: f64 = 0.90;

/// Present: input within this long.
pub const PRESENT_MS: u64 = 10 * 60 * 1000;
/// Rule 1 holds for this many samples in a row before a move.
pub const HOLD_SAMPLES: u32 = 10;
/// A sample this soon after the last one counted moves no streak.
pub const MIN_SAMPLE_GAP_MS: u64 = 2_500;
/// A gap longer than this breaks the streak: the readings did not cover it.
pub const MAX_SAMPLE_GAP_MS: u64 = 10_000;
/// One move out per this long.
pub const MOVE_GAP_MS: u64 = 60 * 1000;
/// A moved agent stays out at least this long.
pub const MIN_STAY_MS: u64 = 10 * 60 * 1000;
/// It returns when use fits in this share of the budget ...
pub const RETURN_FRACTION: f64 = 0.70;
/// ... held this long.
pub const RETURN_HOLD_MS: u64 = 10 * 60 * 1000;
/// One return per this long.
pub const RETURN_GAP_MS: u64 = 5 * 60 * 1000;
/// Two moves out within this long pin the agent out.
pub const PIN_WINDOW_MS: u64 = 60 * 60 * 1000;

/// The person's setting (`cloud.auto`, `cloud.autoReservePercent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReserveSetting {
    pub enabled: bool,
    /// The share of the machine kept for the person, in percent: one of
    /// [`RESERVE_STOPS`]; any other value is taken to the stop at or below it.
    pub reserve_percent: u8,
}

impl Default for ReserveSetting {
    fn default() -> Self {
        Self { enabled: false, reserve_percent: DEFAULT_RESERVE_PERCENT }
    }
}

impl ReserveSetting {
    /// The reserve, snapped to a stop.
    pub fn reserve(&self) -> u8 {
        RESERVE_STOPS.iter().rev().copied().find(|s| *s <= self.reserve_percent).unwrap_or(0)
    }
}

/// One agent's own use: its session's process tree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUse {
    pub session: String,
    pub cpu_cores: f64,
    pub rss_bytes: u64,
    /// A turn is running (a return waits for its end).
    #[serde(default)]
    pub in_turn: bool,
    /// Auto may move it unasked: not the chat in front, not a local-only
    /// project, nothing only this machine has, its changes can be carried.
    #[serde(default)]
    pub movable: bool,
}

/// One reading of this computer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReserveSample {
    pub at_ms: u64,
    pub performance_cores: f64,
    pub ram_bytes: u64,
    /// Time since the person's last input; `None` when not read (never present).
    pub idle_ms: Option<u64>,
    /// Memory pressure is normal (a return needs it).
    #[serde(default = "yes")]
    pub memory_normal: bool,
    /// The whole machine's CPU busy share, 0 to 1 (rule 2); `None` unread.
    #[serde(default)]
    pub cpu_busy: Option<f64>,
    /// Timer lateness p50 in ms (rule 2); `None` unread.
    #[serde(default)]
    pub lateness_p50_ms: Option<f64>,
    /// The app reported a frame over 50 ms in the last window (rule 2).
    #[serde(default)]
    pub slow_frames: bool,
    /// Swap-outs in MB a minute (rule 3); `None` unread.
    #[serde(default)]
    pub swap_growth_mb_per_min: Option<f64>,
    /// Memory in use on the whole machine (rule 3); `None` unread.
    #[serde(default)]
    pub used_ram_bytes: Option<u64>,
    /// Thermal pressure is serious or worse (rule 4).
    #[serde(default)]
    pub thermal_serious: bool,
    pub agents: Vec<AgentUse>,
}

fn yes() -> bool {
    true
}

/// What the agents may use: the rest after the reserve.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentBudget {
    pub cores: f64,
    pub rss_bytes: u64,
}

impl AgentBudget {
    #[allow(
        clippy::cast_possible_truncation,
        reason = "f64 to u64 saturates; RAM times a share in [0, 1] fits"
    )]
    pub fn of(setting: &ReserveSetting, sample: &ReserveSample) -> Self {
        let rest = f64::from(100u8.saturating_sub(setting.reserve())) / 100.0;
        Self {
            cores: sample.performance_cores.max(0.0) * rest,
            rss_bytes: (sample.ram_bytes as f64 * rest) as u64,
        }
    }
}

/// Why a would-be move.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReserveReason {
    /// Agents use more cores than their budget.
    Cpu,
    /// Agents use more memory than their budget.
    Memory,
    /// The machine is saturated and interactive speed suffers (rule 2).
    Interactive,
    /// Memory pressure or swap growth, agents holding a quarter of used memory (rule 3).
    MemoryPressure,
    /// Thermal pressure is serious (rule 4).
    Thermal,
    /// Agents' use fits again (a return).
    Fits,
}

/// Why nothing moves now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoldWhy {
    Off,
    /// Agents fit in their budget.
    Within,
    /// The person is away or not read: away is no reason to move.
    Away,
    /// Over, but not for [`HOLD_SAMPLES`] in a row yet.
    Holding,
    /// Over, but a move out happened under [`MOVE_GAP_MS`] ago.
    Paced,
    /// Over, and no agent may move unasked.
    NoneMovable,
}

/// The verdict for one sample.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "do", rename_all_fields = "camelCase")]
pub enum ReserveVerdict {
    Hold { why: HoldWhy },
    MoveOut { session: String, reason: ReserveReason },
    BringBack { session: String, reason: ReserveReason },
}

#[derive(Debug, Clone, PartialEq)]
struct Moved {
    at_ms: u64,
    /// What it used when it left, charged to the agents' use for its return.
    cpu_cores: f64,
    rss_bytes: u64,
    pinned: bool,
}

/// The rule's memory between samples.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ReserveTracker {
    last_sample_ms: Option<u64>,
    over_streak: u32,
    last_out_ms: Option<u64>,
    last_back_ms: Option<u64>,
    /// Since when agents' use (with the returning agent's) has fit for a return.
    fits_since_ms: Option<u64>,
    moved: BTreeMap<String, Moved>,
    /// Each agent's moves out within [`PIN_WINDOW_MS`].
    outs: BTreeMap<String, Vec<u64>>,
}

impl ReserveTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Agents Auto (would have) moved out.
    pub fn moved(&self) -> impl Iterator<Item = &str> {
        self.moved.keys().map(String::as_str)
    }

    /// The person brought an agent back: it is no longer Auto's, pinned or not.
    pub fn brought_back(&mut self, session: &str) {
        self.moved.remove(session);
        self.outs.remove(session);
    }

    /// Judges one sample.
    pub fn judge(&mut self, setting: &ReserveSetting, sample: &ReserveSample) -> ReserveVerdict {
        if !setting.enabled {
            *self = Self::default();
            return ReserveVerdict::Hold { why: HoldWhy::Off };
        }
        let counts = match self.last_sample_ms {
            Some(last) if sample.at_ms < last.saturating_add(MIN_SAMPLE_GAP_MS) => false,
            Some(last) if sample.at_ms > last.saturating_add(MAX_SAMPLE_GAP_MS) => {
                self.over_streak = 0;
                true
            }
            _ => true,
        };
        if counts {
            self.last_sample_ms = Some(sample.at_ms);
        }

        let budget = AgentBudget::of(setting, sample);
        let here: Vec<&AgentUse> =
            sample.agents.iter().filter(|a| !self.moved.contains_key(&a.session)).collect();
        let cores: f64 = here.iter().map(|a| a.cpu_cores.max(0.0)).sum();
        let rss: u64 = here.iter().map(|a| a.rss_bytes).sum();
        let present = sample.idle_ms.is_some_and(|idle| idle < PRESENT_MS);
        let over_reserve = cores > budget.cores || rss > budget.rss_bytes;
        let Some(reason) = Self::reason(sample, present, &budget, cores, rss) else {
            self.over_streak = 0;
            if over_reserve && !present {
                self.fits_since_ms = None;
                return ReserveVerdict::Hold { why: HoldWhy::Away };
            }
            return self.maybe_return(sample, &budget, cores, rss);
        };
        self.fits_since_ms = None;
        if counts {
            self.over_streak = self.over_streak.saturating_add(1);
        }
        if self.over_streak < HOLD_SAMPLES {
            return ReserveVerdict::Hold { why: HoldWhy::Holding };
        }
        if self.last_out_ms.is_some_and(|t| sample.at_ms < t.saturating_add(MOVE_GAP_MS)) {
            return ReserveVerdict::Hold { why: HoldWhy::Paced };
        }
        let share = |a: &AgentUse| {
            a.cpu_cores.max(0.0) / budget.cores.max(f64::MIN_POSITIVE)
                + a.rss_bytes as f64 / (budget.rss_bytes.max(1) as f64)
        };
        let Some(pick) = here
            .iter()
            .filter(|a| a.movable)
            .max_by(|a, b| share(a).total_cmp(&share(b)).then_with(|| b.session.cmp(&a.session)))
        else {
            return ReserveVerdict::Hold { why: HoldWhy::NoneMovable };
        };
        let outs = self.outs.entry(pick.session.clone()).or_default();
        outs.retain(|t| sample.at_ms < t.saturating_add(PIN_WINDOW_MS));
        outs.push(sample.at_ms);
        let pinned = outs.len() >= 2;
        self.moved.insert(
            pick.session.clone(),
            Moved {
                at_ms: sample.at_ms,
                cpu_cores: pick.cpu_cores,
                rss_bytes: pick.rss_bytes,
                pinned,
            },
        );
        self.last_out_ms = Some(sample.at_ms);
        self.over_streak = 0;
        ReserveVerdict::MoveOut { session: pick.session.clone(), reason }
    }

    /// The first rule that holds on this sample, if any.
    fn reason(
        sample: &ReserveSample,
        present: bool,
        budget: &AgentBudget,
        cores: f64,
        rss: u64,
    ) -> Option<ReserveReason> {
        // Rule 1, against the reserve while present, against AWAY_SHARE while away.
        let (cpu_line, ram_line) = if present {
            (budget.cores, budget.rss_bytes as f64)
        } else {
            (sample.performance_cores.max(0.0) * AWAY_SHARE, sample.ram_bytes as f64 * AWAY_SHARE)
        };
        if cores > cpu_line {
            return Some(ReserveReason::Cpu);
        }
        if rss as f64 > ram_line {
            return Some(ReserveReason::Memory);
        }
        // Rule 2.
        if present
            && cores >= 1.0
            && sample.cpu_busy.is_some_and(|b| b >= BUSY_SHARE)
            && (sample.lateness_p50_ms.is_some_and(|l| l > LATE_P50_MS) || sample.slow_frames)
        {
            return Some(ReserveReason::Interactive);
        }
        // Rule 3, present or away.
        let pressured = !sample.memory_normal
            || sample.swap_growth_mb_per_min.is_some_and(|g| g > SWAP_GROWTH_MB_PER_MIN);
        if pressured
            && sample.used_ram_bytes.is_some_and(|used| used > 0 && rss.saturating_mul(4) >= used)
        {
            return Some(ReserveReason::MemoryPressure);
        }
        // Rule 4.
        if sample.thermal_serious && cores >= 1.0 {
            return Some(ReserveReason::Thermal);
        }
        None
    }

    fn maybe_return(
        &mut self,
        sample: &ReserveSample,
        budget: &AgentBudget,
        cores: f64,
        rss: u64,
    ) -> ReserveVerdict {
        let within = ReserveVerdict::Hold { why: HoldWhy::Within };
        // The longest-out agent that may return: stayed long enough, not pinned, between turns.
        let candidate = self
            .moved
            .iter()
            .filter(|(session, m)| {
                !m.pinned
                    && sample.at_ms >= m.at_ms.saturating_add(MIN_STAY_MS)
                    && !sample.agents.iter().any(|a| &a.session == *session && a.in_turn)
            })
            .min_by_key(|(_, m)| m.at_ms)
            .map(|(s, m)| (s.clone(), m.cpu_cores, m.rss_bytes));
        let Some((session, its_cores, its_rss)) = candidate else {
            self.fits_since_ms = None;
            return within;
        };
        let fits = sample.memory_normal
            && cores + its_cores <= budget.cores * RETURN_FRACTION
            && rss.saturating_add(its_rss) as f64 <= budget.rss_bytes as f64 * RETURN_FRACTION;
        if !fits {
            self.fits_since_ms = None;
            return within;
        }
        let since = *self.fits_since_ms.get_or_insert(sample.at_ms);
        if sample.at_ms < since.saturating_add(RETURN_HOLD_MS)
            || self.last_back_ms.is_some_and(|t| sample.at_ms < t.saturating_add(RETURN_GAP_MS))
        {
            return within;
        }
        self.moved.remove(&session);
        self.last_back_ms = Some(sample.at_ms);
        self.fits_since_ms = None;
        ReserveVerdict::BringBack { session, reason: ReserveReason::Fits }
    }
}

/// One line of `auto-shadow.jsonl`: what Auto would have done, and the numbers it judged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShadowLine {
    pub rule: String,
    pub at_ms: u64,
    pub reserve_percent: u8,
    pub budget: AgentBudget,
    pub agents_cpu_cores: f64,
    pub agents_rss_bytes: u64,
    pub verdict: ReserveVerdict,
}

impl ShadowLine {
    pub fn new(setting: &ReserveSetting, sample: &ReserveSample, verdict: ReserveVerdict) -> Self {
        Self {
            rule: RESERVE_RULE_VERSION.to_string(),
            at_ms: sample.at_ms,
            reserve_percent: setting.reserve(),
            budget: AgentBudget::of(setting, sample),
            agents_cpu_cores: sample.agents.iter().map(|a| a.cpu_cores.max(0.0)).sum(),
            agents_rss_bytes: sample.agents.iter().map(|a| a.rss_bytes).sum(),
            verdict,
        }
    }
}

/// Names the shadow log; else `auto-shadow.jsonl` in the build's state folder.
pub const SHADOW_LOG_ENV: &str = "CMUX_AUTO_SHADOW_LOG";

/// Where the shadow lines go: [`SHADOW_LOG_ENV`], else `auto-shadow.jsonl` in
/// `state_dir`, the build's own state folder its caller names (the daemon's,
/// from its build identity), so one build never writes another's log.
pub fn shadow_log_path(state_dir: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(SHADOW_LOG_ENV).filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(path));
    }
    state_dir.map(|d| d.join("auto-shadow.jsonl"))
}

/// The log stops growing at this size; the oldest half is dropped then.
pub const SHADOW_LOG_MAX_BYTES: u64 = 4 << 20;

/// Appends one line unless the verdict is a hold (holds are every 3 s; the
/// tracker's state says enough between moves).
pub fn append_shadow(path: &Path, line: &ShadowLine) -> std::io::Result<bool> {
    if matches!(line.verdict, ReserveVerdict::Hold { .. }) {
        return Ok(false);
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if std::fs::metadata(path).is_ok_and(|m| m.len() >= SHADOW_LOG_MAX_BYTES) {
        let old = std::fs::read(path)?;
        // Keep the newer half, starting at a line boundary.
        let half = old.len() / 2;
        let tail = old.get(half..).unwrap_or_default();
        let kept = tail
            .iter()
            .position(|b| *b == b'\n')
            .and_then(|i| tail.get(i.saturating_add(1)..))
            .unwrap_or_default();
        std::fs::write(path, kept)?;
    }
    let mut text = serde_json::to_string(line).map_err(std::io::Error::other)?;
    text.push('\n');
    std::fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(text.as_bytes())?;
    Ok(true)
}

#[cfg(test)]
#[path = "reserve_tests.rs"]
mod tests;
