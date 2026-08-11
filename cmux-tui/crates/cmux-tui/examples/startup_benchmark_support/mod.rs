mod args;
mod lifecycle;
mod process;
mod report;

use std::str::FromStr;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use serde::Serialize;

pub use args::Args;
pub use lifecycle::{LifecycleRecorder, PhaseMetric, RunPhases, SampleKind};
pub use process::{Fixture, Target, TargetInput, run_sample};
pub use report::{
    ComparisonReport, HostMetadata, InfrastructureMetadata, Pair, ProfileReport, SampleSet,
    ScenarioReport, SignedSummary, TargetMetadata, now_unix_ms,
};

#[derive(Debug, Clone, Copy)]
pub struct SuiteDeadline {
    expires_at: Option<Instant>,
}

impl SuiteDeadline {
    pub fn at(expires_at: Instant) -> Self {
        Self { expires_at: Some(expires_at) }
    }

    pub fn unbounded() -> Self {
        // This removes only the suite cap. Each operation still supplies its
        // fixed local limit, which bounds failure cleanup.
        Self { expires_at: None }
    }

    pub fn ensure(self, operation: &str) -> Result<()> {
        self.timeout(Duration::MAX, operation).map(|_| ())
    }

    pub fn timeout(self, maximum: Duration, operation: &str) -> Result<Duration> {
        self.timeout_at(Instant::now(), maximum, operation)
    }

    pub fn instant(self, maximum: Duration, operation: &str) -> Result<Instant> {
        self.instant_at(Instant::now(), maximum, operation)
    }

    fn instant_at(self, now: Instant, maximum: Duration, operation: &str) -> Result<Instant> {
        now.checked_add(self.timeout_at(now, maximum, operation)?)
            .ok_or_else(|| anyhow::anyhow!("{operation} deadline overflow"))
    }

    fn timeout_at(self, now: Instant, maximum: Duration, operation: &str) -> Result<Duration> {
        let Some(expires_at) = self.expires_at else {
            return Ok(maximum);
        };
        let remaining = expires_at.checked_duration_since(now).filter(|value| !value.is_zero());
        match remaining {
            Some(remaining) => Ok(remaining.min(maximum)),
            None => bail!("benchmark suite deadline expired while {operation}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TargetKind {
    Baseline,
    Candidate,
}

impl TargetKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Baseline => "baseline",
            Self::Candidate => "candidate",
        }
    }
}

impl FromStr for TargetKind {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "baseline" => Ok(Self::Baseline),
            "candidate" => Ok(Self::Candidate),
            _ => bail!("unknown profile target {value}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Scenario {
    Cold,
    Warm,
    Headless,
    Restored,
    Incompatible,
}

impl Scenario {
    pub const ALL: [Self; 5] =
        [Self::Cold, Self::Warm, Self::Headless, Self::Restored, Self::Incompatible];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cold => "cold",
            Self::Warm => "warm",
            Self::Headless => "headless",
            Self::Restored => "restored",
            Self::Incompatible => "incompatible",
        }
    }

    pub fn event(self) -> &'static str {
        match self {
            Self::Cold => {
                "PTY process spawn to unique session marker followed by a frame-end cursor control"
            }
            Self::Warm => {
                "attach PTY process spawn to unique session marker followed by a frame-end cursor control"
            }
            Self::Headless => "process spawn to readiness line and successful session ping RPC",
            Self::Restored => {
                "process spawn to readiness line and topology RPC containing the saved terminal"
            }
            Self::Incompatible => {
                "process spawn to nonzero exit with the exact public incompatible-state error"
            }
        }
    }
}

impl FromStr for Scenario {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "cold" => Ok(Self::Cold),
            "warm" => Ok(Self::Warm),
            "headless" => Ok(Self::Headless),
            "restored" => Ok(Self::Restored),
            "incompatible" => Ok(Self::Incompatible),
            _ => bail!("unknown startup scenario {value}"),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Evidence {
    pub warmups_completed: usize,
    pub samples_completed: usize,
    pub render_markers: usize,
    pub frame_completions: usize,
    pub readiness_lines: usize,
    pub socket_rpcs: usize,
    pub restored_topologies: usize,
    pub schema_rejections: usize,
    pub process_exits: usize,
    pub supervisor_ready_events: usize,
    pub supervisor_t0_records: usize,
    pub containment_cleanups: usize,
    pub terminal_probe_responses: usize,
    pub terminal_cpr_responses: usize,
    pub terminal_foreground_color_responses: usize,
    pub terminal_background_color_responses: usize,
    pub terminal_window_pixel_responses: usize,
    pub terminal_kitty_responses: usize,
    pub terminal_da1_responses: usize,
    pub terminal_keyboard_responses: usize,
    pub frame_cursor_shows: usize,
    pub frame_cursor_hides: usize,
    pub frame_cursor_positions: usize,
}

impl Evidence {
    pub fn add(&mut self, other: &Self) {
        let Self {
            warmups_completed,
            samples_completed,
            render_markers,
            frame_completions,
            readiness_lines,
            socket_rpcs,
            restored_topologies,
            schema_rejections,
            process_exits,
            supervisor_ready_events,
            supervisor_t0_records,
            containment_cleanups,
            terminal_probe_responses,
            terminal_cpr_responses,
            terminal_foreground_color_responses,
            terminal_background_color_responses,
            terminal_window_pixel_responses,
            terminal_kitty_responses,
            terminal_da1_responses,
            terminal_keyboard_responses,
            frame_cursor_shows,
            frame_cursor_hides,
            frame_cursor_positions,
        } = other;
        self.warmups_completed += *warmups_completed;
        self.samples_completed += *samples_completed;
        self.render_markers += *render_markers;
        self.frame_completions += *frame_completions;
        self.readiness_lines += *readiness_lines;
        self.socket_rpcs += *socket_rpcs;
        self.restored_topologies += *restored_topologies;
        self.schema_rejections += *schema_rejections;
        self.process_exits += *process_exits;
        self.supervisor_ready_events += *supervisor_ready_events;
        self.supervisor_t0_records += *supervisor_t0_records;
        self.containment_cleanups += *containment_cleanups;
        self.terminal_probe_responses += *terminal_probe_responses;
        self.terminal_cpr_responses += *terminal_cpr_responses;
        self.terminal_foreground_color_responses += *terminal_foreground_color_responses;
        self.terminal_background_color_responses += *terminal_background_color_responses;
        self.terminal_window_pixel_responses += *terminal_window_pixel_responses;
        self.terminal_kitty_responses += *terminal_kitty_responses;
        self.terminal_da1_responses += *terminal_da1_responses;
        self.terminal_keyboard_responses += *terminal_keyboard_responses;
        self.frame_cursor_shows += *frame_cursor_shows;
        self.frame_cursor_hides += *frame_cursor_hides;
        self.frame_cursor_positions += *frame_cursor_positions;
    }
}

#[derive(Debug)]
pub struct RunResult {
    pub duration_ns: u64,
    pub evidence: Evidence,
    pub phases: RunPhases,
}

fn duration_ns(duration: Duration) -> Result<u64> {
    u64::try_from(duration.as_nanos()).map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suite_deadline_caps_each_blocking_wait_to_remaining_time() {
        let now = Instant::now();
        let deadline = SuiteDeadline::at(now + Duration::from_secs(7));

        assert_eq!(
            deadline.timeout_at(now, Duration::from_secs(30), "test wait").unwrap(),
            Duration::from_secs(7)
        );
        assert_eq!(
            deadline.timeout_at(now, Duration::from_secs(3), "test wait").unwrap(),
            Duration::from_secs(3)
        );
        assert_eq!(
            deadline.instant_at(now, Duration::from_secs(30), "test wait").unwrap(),
            now + Duration::from_secs(7)
        );
        assert!(
            deadline.timeout_at(now + Duration::from_secs(7), Duration::MAX, "test wait").is_err()
        );
    }

    #[test]
    fn unbounded_deadline_preserves_the_operation_cleanup_limit() {
        assert_eq!(
            SuiteDeadline::unbounded()
                .timeout_at(Instant::now(), Duration::from_secs(30), "cleanup")
                .unwrap(),
            Duration::from_secs(30)
        );
    }
}
