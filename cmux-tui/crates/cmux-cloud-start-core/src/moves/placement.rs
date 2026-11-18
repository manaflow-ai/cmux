//! Where a person's New Workspace runs: this Mac, a new Cloud machine of its own, or a machine a
//! folder is pinned to. One decision over the person's options (cmux.json `cloud.*`) and what the
//! app knows now, so Cmd-N never waits on a read (Leo, 2026-11-18: "you also want to be able to
//! like have configurable options for that, right? Like what's our current logic?").
//!
//! The order, first match wins:
//!
//! 1. A run that is not the person's own gesture, or that names a machine or a command, stays
//!    where it asked (`folder::plan`'s rule).
//! 2. A pin (`cloud.workspacePins`): the deepest pinned folder at or above the workspace's folder
//!    decides, `thisMac`, `cloud` or `machine:<id>`, whatever the toggle says.
//! 3. The toggle (`cloud.newWorkspacesInCloud`): on prefers Cloud, off prefers this Mac.
//!
//! A new Cloud machine is one workspace's alone, small and paused when idle (`folder.rs`
//! `new_workspace_machine`; the server sizes it and pauses it). Before one is made, Cloud must be
//! able to make it where its progress shows (`folder::route`: available, signed in, a window),
//! and the cap is checked: `cloud.autoMachineCap` (0: the plan's own limit) counts the Cloud
//! machines running now. Otherwise the workspace opens on this Mac and says why. A pin to a
//! machine that already runs makes nothing new, so neither applies to it.

use serde::Serialize;
use serde_json::Value;

/// The settings keys this reads, under `cloud`.
pub const IN_CLOUD: &str = "newWorkspacesInCloud";
pub const PINS: &str = "workspacePins";
pub const MACHINE_CAP: &str = "autoMachineCap";

/// Where a pin sends a workspace.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum Pin {
    ThisMac,
    Cloud,
    /// A machine the app lists, by its app machine id (`cmux machine list`).
    Machine(String),
}

impl Pin {
    /// `thisMac`, `cloud` or `machine:<id>`; anything else pins nothing.
    pub fn parse(text: &str) -> Option<Self> {
        match text.trim() {
            "thisMac" => Some(Self::ThisMac),
            "cloud" => Some(Self::Cloud),
            other => other
                .strip_prefix("machine:")
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(|id| Self::Machine(id.to_owned())),
        }
    }
}

/// The person's placement options, read from cmux.json's `cloud` object.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Options {
    pub in_cloud: bool,
    /// Pinned folders (absolute, normalized) and where each sends its workspaces.
    pub pins: Vec<(String, Pin)>,
    /// At most this many Cloud machines running before new ones stop; none: the plan's limit.
    pub machine_cap: Option<u32>,
}

impl Options {
    /// The options in `cloud` (cmux.json's `cloud` object). A missing or malformed value is its
    /// default; a pin whose folder is not absolute or whose target cannot be read is skipped.
    pub fn from_settings(cloud: &Value) -> Self {
        let pins = cloud
            .get(PINS)
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
            .filter_map(|(folder, target)| {
                Some((super::folder::normalized(folder)?, Pin::parse(target.as_str()?)?))
            })
            .collect();
        let machine_cap = cloud
            .get(MACHINE_CAP)
            .and_then(Value::as_u64)
            .filter(|cap| *cap > 0)
            .map(|cap| u32::try_from(cap).unwrap_or(u32::MAX));
        Self {
            in_cloud: cloud.get(IN_CLOUD).and_then(Value::as_bool).unwrap_or(false),
            pins,
            machine_cap,
        }
    }

    /// The pin of the deepest pinned folder at or above `folder`, and that folder.
    pub fn pin_for(&self, folder: &str) -> Option<(&str, &Pin)> {
        let folder = super::folder::normalized(folder)?;
        self.pins
            .iter()
            .filter(|(pinned, _)| {
                pinned == "/" || folder == *pinned || folder.starts_with(&format!("{pinned}/"))
            })
            .max_by_key(|(pinned, _)| pinned.len())
            .map(|(pinned, pin)| (pinned.as_str(), pin))
    }
}

/// What the app knows when the person asks for a New Workspace, with no read to wait on.
#[derive(Clone, Debug, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    /// The person's own gesture; a script, the CLI or an agent keeps its workspace where it asked.
    pub by_person: bool,
    /// The run names a machine (it opens there) or a command (it runs here).
    pub names_machine_or_command: bool,
    /// The folder the workspace starts in, when known.
    pub cwd: Option<String>,
    /// Cloud machines of this account running now (the app's machine list).
    pub running_machines: u32,
    /// Why Cloud cannot run in this build or for this account, as Cloud says it.
    pub unavailable_reason: Option<String>,
    pub signed_in: bool,
    /// A window is open to show the new machine's progress.
    pub has_window: bool,
}

/// Where the workspace goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum Target {
    ThisMac,
    /// A new Cloud machine of the workspace's own.
    NewCloudMachine,
    /// A machine already listed, by its app machine id.
    Machine(String),
}

/// Why a workspace the options sent to Cloud opens on this Mac instead; the app words it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    /// Cloud cannot run in this build or for this account (the reason as Cloud says it).
    Unavailable {
        reason: String,
    },
    SignedOut,
    /// No open window to show the new machine's progress (Cmd-N with every window closed).
    NoWindow,
    /// `running` Cloud machines run, at or over the person's `cap` (`cloud.autoMachineCap`).
    MachineCap {
        running: u32,
        cap: u32,
    },
}

/// The decision, why (for logs and `cmux` answers), and what to tell the person when it is not
/// what their options asked for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Placement {
    pub target: Target,
    pub why: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
}

fn placed(target: Target, why: impl Into<String>) -> Placement {
    Placement { target, why: why.into(), refusal: None }
}

/// Where a New Workspace goes under `options`, given `facts`.
pub fn decide(options: &Options, facts: &Facts) -> Placement {
    if !facts.by_person || facts.names_machine_or_command {
        return placed(Target::ThisMac, "the run names where it goes, or is not a person's own");
    }
    let pin = facts.cwd.as_deref().and_then(|cwd| options.pin_for(cwd));
    let why = match pin {
        Some((folder, Pin::ThisMac)) => {
            return placed(Target::ThisMac, format!("{folder} is pinned to this Mac"));
        }
        Some((folder, Pin::Machine(id))) => {
            return placed(Target::Machine(id.clone()), format!("{folder} is pinned to {id}"));
        }
        Some((folder, Pin::Cloud)) => format!("{folder} is pinned to Cloud"),
        None if options.in_cloud => "Run New Workspaces in Cloud is on".to_owned(),
        None => return placed(Target::ThisMac, "Run New Workspaces in Cloud is off"),
    };
    // A machine costs money, so one is asked for only where Cloud can make it and a window shows
    // its progress, Cancel and Retry (`folder::route`); otherwise here, and the person is told.
    let route = super::folder::route(
        facts.unavailable_reason.as_deref(),
        facts.signed_in,
        facts.has_window,
    );
    let running = facts.running_machines;
    let refusal = match route {
        super::folder::Route::ThisMac { refusal } => match refusal {
            super::folder::Refusal::Unavailable { reason } => Refusal::Unavailable { reason },
            super::folder::Refusal::SignedOut => Refusal::SignedOut,
            super::folder::Refusal::NoWindow => Refusal::NoWindow,
        },
        super::folder::Route::Cloud => match options.machine_cap {
            Some(cap) if running >= cap => Refusal::MachineCap { running, cap },
            _ => return placed(Target::NewCloudMachine, why),
        },
    };
    Placement {
        target: Target::ThisMac,
        why: format!("{why}, but {refusal:?}"),
        refusal: Some(refusal),
    }
}

#[cfg(test)]
mod tests;
