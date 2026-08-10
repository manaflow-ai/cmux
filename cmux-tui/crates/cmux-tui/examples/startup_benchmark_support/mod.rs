mod args;
mod process;
mod report;

use std::str::FromStr;

use anyhow::{Result, bail};
use serde::Serialize;

pub use args::Args;
pub use process::{Fixture, Target, run_sample};
pub use report::{
    ComparisonReport, HostMetadata, Pair, ProfileReport, SampleSet, ScenarioReport, SignedSummary,
    TargetMetadata, now_unix_ms,
};

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
                "PTY process spawn to unique session marker followed by frame-end cursor visibility"
            }
            Self::Warm => {
                "attach PTY process spawn to unique session marker followed by frame-end cursor visibility"
            }
            Self::Headless => "process spawn to readiness line and successful session ping RPC",
            Self::Restored => {
                "process spawn to readiness line and topology RPC containing the saved terminal"
            }
            Self::Incompatible => {
                "process spawn to nonzero exit with the exact unsupported-schema error"
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
    pub terminal_probe_responses: usize,
    pub frame_cursor_shows: usize,
    pub frame_cursor_hides: usize,
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
            terminal_probe_responses,
            frame_cursor_shows,
            frame_cursor_hides,
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
        self.terminal_probe_responses += *terminal_probe_responses;
        self.frame_cursor_shows += *frame_cursor_shows;
        self.frame_cursor_hides += *frame_cursor_hides;
    }
}

#[derive(Debug)]
pub struct RunResult {
    pub duration_ns: u64,
    pub evidence: Evidence,
}

fn duration_ns(duration: std::time::Duration) -> Result<u64> {
    u64::try_from(duration.as_nanos()).map_err(Into::into)
}
