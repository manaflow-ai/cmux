//! A pool machine as both providers describe it.

use serde_json::{Value, json};

/// Where a machine runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Provider {
    /// Freestyle VMs (`/v5/vms`): a resume keeps memory and answers in under a second.
    Freestyle,
    /// GCE instances (`cmux-runner-pool-*`): a resume from SUSPENDED takes about 14.5 s to RUNNING.
    Gcp,
}

impl Provider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Freestyle => "freestyle",
            Self::Gcp => "gcp",
        }
    }

    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "freestyle" | "fs" => Some(Self::Freestyle),
            "gcp" | "gce" => Some(Self::Gcp),
            _ => None,
        }
    }
}

/// A machine's power state, folded from the provider's own words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Power {
    Running,
    /// Starting or resuming: a call is already on its way.
    Starting,
    /// Paused (Freestyle) or SUSPENDED (GCE): memory kept, resumes fast.
    Paused,
    /// Pausing or suspending.
    Pausing,
    /// Stopped (Freestyle) or TERMINATED (GCE): disk kept, boots again.
    Stopped,
    /// A state this crate does not act on.
    Other,
}

impl Power {
    pub fn of_freestyle(state: &str) -> Self {
        match state {
            "running" => Self::Running,
            "starting" | "resuming" | "creating" => Self::Starting,
            "paused" | "suspended" => Self::Paused,
            "pausing" | "suspending" => Self::Pausing,
            "stopped" => Self::Stopped,
            _ => Self::Other,
        }
    }

    pub fn of_gce(status: &str) -> Self {
        match status {
            "RUNNING" => Self::Running,
            "PROVISIONING" | "STAGING" | "REPAIRING" => Self::Starting,
            "SUSPENDED" => Self::Paused,
            "SUSPENDING" | "STOPPING" => Self::Pausing,
            "TERMINATED" | "STOPPED" => Self::Stopped,
            _ => Self::Other,
        }
    }

    /// Whether `up` may resume or start it.
    pub fn resumable(self) -> bool {
        matches!(self, Self::Paused | Self::Stopped)
    }
}

/// The opt-in value of the schedule key (Freestyle metadata `cmux_schedule`, GCE label `cmux-schedule`).
pub const SCHEDULE_PAUSE: &str = "pause";

/// One pool machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Machine {
    pub provider: Provider,
    /// Freestyle VM id, or the GCE instance name.
    pub id: String,
    /// The name its runners are named after: Freestyle metadata `fsp_runner`, or the GCE instance name.
    pub name: String,
    /// GCE zone (`us-west1-a`); `None` on Freestyle.
    pub zone: Option<String>,
    pub power: Power,
    /// The provider's own word for the state.
    pub state: String,
    /// How many runners it carries (metadata; 1 when unsaid).
    pub slots: u32,
    /// vCPUs (GCE machineType, Freestyle metadata `fsp_vcpu`); 0 when unknown.
    pub vcpu: u32,
    /// Opted into the scheduler's idle pause (Freestyle metadata `cmux_schedule=pause`, GCE label
    /// `cmux-schedule=pause`). The persistent pools stay running unless a machine says so (hq#15393).
    pub schedule_pause: bool,
}

impl Machine {
    /// Whether a GitHub runner name belongs to this machine: the machine's name itself, or `NAME-<k>`.
    pub fn owns_runner(&self, runner: &str) -> bool {
        runner == self.name
            || runner
                .strip_prefix(self.name.as_str())
                .and_then(|rest| rest.strip_prefix('-'))
                .is_some_and(|k| !k.is_empty() && k.bytes().all(|b| b.is_ascii_digit()))
    }

    pub fn to_json(&self) -> Value {
        json!({
            "provider": self.provider.as_str(),
            "id": self.id,
            "name": self.name,
            "zone": self.zone,
            "state": self.state,
            "slots": self.slots,
            "vcpu": self.vcpu,
            "schedule_pause": self.schedule_pause,
        })
    }
}

/// A runner as GitHub lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Runner {
    pub name: String,
    pub online: bool,
    pub busy: bool,
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}
