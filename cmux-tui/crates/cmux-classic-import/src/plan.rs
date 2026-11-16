//! Whether a classic migration runs and what it makes. Pure: no files, no daemon.
//!
//! The rules that keep the migration one-time and duplicate-free:
//! - A workspace key the ledger has as done never comes over again in an
//!   automatic run, even when classic changed it later (cmux NEXT's copy
//!   wins). A manual run (Import Workspaces from Classic cmux) brings it
//!   back only when its cmux NEXT workspace was closed.
//! - A key the ledger has as pending or created was cut off: its half-made
//!   workspace is closed and it is made again.
//! - A group an earlier run made is reused while it exists, so a merge after
//!   a downgrade puts new workspaces into the same group.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::ledger::{Entry, Ledger, Load, Stage, State};
use crate::model::{Group, Rect, Snapshot, Workspace};
use crate::source::Source;

/// Who started the run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    /// At launch, by itself.
    Automatic,
    /// The person or an agent ran Import Workspaces from Classic cmux.
    Manual,
}

/// Why an automatic run does not start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    /// Classic saved no session for any channel.
    NoClassicSession,
    /// Classic has not saved since the last run.
    Unchanged,
    /// Classic is running and may still save.
    ClassicRunning,
    /// The ledger is from a newer cmux NEXT, or does not decode.
    LedgerNotUsable,
    /// cmux NEXT held workspaces before its first migration: classic's were
    /// recorded as seen ([`baseline`]), none made.
    InUseBefore,
    /// The person cancelled the launch's import preview
    /// ([`Ledger::declined_at`]); a manual run still imports.
    Declined,
}

/// Whether an automatic run starts at launch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "decision", content = "reason")]
pub enum Decision {
    FirstRun,
    /// The last run was cut off.
    Resume,
    /// Classic saved again since the last run (a downgrade, then this upgrade).
    Merge,
    Skip(SkipReason),
}

/// Whether an automatic run starts, from what the ledger file held, the save
/// that would be read (none when classic has none) and whether classic runs.
pub fn decision(load: &Load, source: Option<&Source>, classic_running: bool) -> Decision {
    let ledger = match load {
        Load::Newer(_) | Load::Unreadable | Load::Failed(_) => {
            return Decision::Skip(SkipReason::LedgerNotUsable);
        }
        Load::None => None,
        Load::Ledger(ledger) => Some(ledger),
    };
    let Some(source) = source else { return Decision::Skip(SkipReason::NoClassicSession) };
    let Some(ledger) = ledger else {
        return if classic_running {
            Decision::Skip(SkipReason::ClassicRunning)
        } else {
            Decision::FirstRun
        };
    };
    // A cut-off run finishes from the save it started with, even while classic runs.
    if ledger.state == State::InProgress {
        return Decision::Resume;
    }
    // A No stands until the person imports by hand.
    if ledger.declined_at.is_some() {
        return Decision::Skip(SkipReason::Declined);
    }
    if ledger.source.as_ref().is_some_and(|last| last.is_same_save(source)) {
        return Decision::Skip(SkipReason::Unchanged);
    }
    if classic_running { Decision::Skip(SkipReason::ClassicRunning) } else { Decision::Merge }
}

/// One classic window's workspaces that come over in this run, in sidebar order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanWindow {
    pub frame: Option<Rect>,
    /// The key of the workspace classic had selected, when it comes over in this run.
    pub selected_key: Option<String>,
    pub workspaces: Vec<Workspace>,
}

/// A classic group the run needs: one to make, or one an earlier run made.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanGroup {
    pub classic: Group,
    /// The cmux NEXT group an earlier run made for it that still exists; none makes one.
    pub existing: Option<String>,
}

/// Why a classic workspace does not come over in this run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Skip {
    /// An earlier run brought it over (and, for a manual run, it is still open).
    AlreadyMigrated,
    /// The snapshot names its key twice; the first one comes over.
    Duplicate,
    /// A Cloud VM workspace: cmux NEXT cannot attach a classic VM.
    CloudVm,
}

/// What one run makes, worked out before anything is made.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub windows: Vec<PlanWindow>,
    pub groups: Vec<PlanGroup>,
    /// cmux NEXT workspaces a cut-off run left half made: closed before they are made again.
    pub cleanup: Vec<String>,
    pub skipped: BTreeMap<String, Skip>,
}

impl Plan {
    /// Every workspace that comes over, window after window.
    pub fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.windows.iter().flat_map(|window| window.workspaces.iter())
    }

    /// Whether the run has nothing to make.
    pub fn is_empty(&self) -> bool {
        self.windows.is_empty()
            && self.groups.iter().all(|group| group.existing.is_some())
            && self.cleanup.is_empty()
    }

    /// This plan without any terminal's scrollback: what a caller that only
    /// counts or lists folders needs, at a fraction of the size.
    pub fn outline(mut self) -> Plan {
        for window in &mut self.windows {
            for workspace in &mut window.workspaces {
                workspace.layout.for_each_tab(&mut |tab| tab.scrollback = None);
            }
        }
        self
    }

    /// The keys of the Cloud VM workspaces it leaves, recorded as skipped.
    pub fn cloud_vm_keys(&self) -> Vec<String> {
        self.skipped
            .iter()
            .filter(|(_, skip)| **skip == Skip::CloudVm)
            .map(|(key, _)| key.clone())
            .collect()
    }
}

/// What a run makes from `snapshot`, given the last run's `ledger` (none for
/// the first), the cmux NEXT workspaces open now (`live`) and the groups
/// that exist now (`live_groups`).
pub fn plan(
    snapshot: &Snapshot,
    ledger: Option<&Ledger>,
    live: &BTreeSet<String>,
    live_groups: &BTreeSet<String>,
    mode: Mode,
) -> Plan {
    let mut plan = Plan::default();
    let mut seen = BTreeSet::new();
    let mut needed: Vec<&str> = Vec::new();
    let mut by_id: HashMap<&str, &Group> = HashMap::new();
    for group in snapshot.windows.iter().flat_map(|window| window.groups.iter()) {
        by_id.entry(group.id.as_str()).or_insert(group);
    }
    for window in &snapshot.windows {
        let mut coming = Vec::new();
        for workspace in &window.workspaces {
            if !seen.insert(workspace.key.as_str()) {
                plan.skipped.entry(workspace.key.clone()).or_insert(Skip::Duplicate);
                continue;
            }
            if workspace.cloud_vm.is_some() {
                plan.skipped.insert(workspace.key.clone(), Skip::CloudVm);
                continue;
            }
            if let Some(entry) = ledger.and_then(|ledger| ledger.workspaces.get(&workspace.key)) {
                match entry.stage {
                    Stage::Done | Stage::Skipped => {
                        let open =
                            entry.next_workspace.as_ref().is_some_and(|made| live.contains(made));
                        let reopen = mode == Mode::Manual && entry.stage == Stage::Done && !open;
                        if !reopen {
                            plan.skipped.insert(workspace.key.clone(), Skip::AlreadyMigrated);
                            continue;
                        }
                    }
                    Stage::Pending | Stage::Created => {
                        if let Some(half) =
                            entry.next_workspace.as_ref().filter(|half| live.contains(*half))
                        {
                            plan.cleanup.push(half.clone());
                        }
                    }
                }
            }
            coming.push(workspace.clone());
            if let Some(group) = workspace.group_id.as_deref()
                && by_id.contains_key(group)
                && !needed.contains(&group)
            {
                needed.push(group);
            }
        }
        // A pinned group comes over even with no member in this run, once.
        for group in &window.groups {
            let made_before = ledger.is_some_and(|ledger| ledger.groups.contains_key(&group.id));
            if group.pinned && !needed.contains(&group.id.as_str()) && !made_before {
                needed.push(&group.id);
            }
        }
        if coming.is_empty() {
            continue;
        }
        let selected = window
            .selected_workspace
            .and_then(|index| usize::try_from(index).ok())
            .and_then(|index| window.workspaces.get(index))
            .map(|workspace| workspace.key.clone())
            .filter(|key| coming.iter().any(|workspace| &workspace.key == key));
        plan.windows.push(PlanWindow {
            frame: window.frame,
            selected_key: selected,
            workspaces: coming,
        });
    }
    plan.groups = needed
        .into_iter()
        .filter_map(|id| {
            let classic = (*by_id.get(id)?).clone();
            let existing = ledger
                .and_then(|ledger| ledger.groups.get(id))
                .filter(|made| live_groups.contains(*made))
                .cloned();
            Some(PlanGroup { classic, existing })
        })
        .collect();
    plan
}

/// `ledger` with every classic workspace in `snapshot` recorded as seen,
/// none made: for a cmux NEXT that was in use before its first migration.
/// A manual run still brings each one over; an automatic merge brings only
/// later ones.
pub fn baseline(snapshot: &Snapshot, mut ledger: Ledger) -> Ledger {
    for workspace in snapshot.workspaces() {
        ledger.workspaces.entry(workspace.key.clone()).or_insert_with(|| {
            if workspace.cloud_vm.is_some() {
                Entry::new(Stage::Skipped, None, Some("cloud-vm"))
            } else {
                Entry::new(Stage::Done, None, Some("baseline"))
            }
        });
    }
    ledger.state = State::Completed;
    ledger
}

/// Which classic channel a save came from, for the confirmation's wording.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Channel {
    Stable,
    Nightly,
    ReleaseCandidate,
    Staging,
    Debug,
}

impl Channel {
    pub fn of(bundle: &str) -> Channel {
        let is = |channel: &str| {
            bundle == channel
                || bundle.strip_prefix(channel).is_some_and(|rest| rest.starts_with('.'))
        };
        if bundle == crate::decode::STABLE_BUNDLE_ID {
            Channel::Stable
        } else if is("com.cmuxterm.app.nightly") {
            Channel::Nightly
        } else if is("com.cmuxterm.app.rc") {
            Channel::ReleaseCandidate
        } else if is("com.cmuxterm.app.staging") {
            Channel::Staging
        } else {
            Channel::Debug
        }
    }
}

/// What the confirmation shows before a run writes anything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Preview {
    pub channel: Channel,
    pub workspaces: usize,
    pub skipped_cloud_vms: usize,
    /// Half-made workspaces of a cut-off run that are made again.
    pub cleanup_workspaces: usize,
    pub browser_tabs: usize,
    /// Browser tabs on `file:` pages.
    pub local_file_pages: usize,
    pub ssh_workspaces: usize,
    /// Local agent sessions that resume as chats.
    pub agent_chats: usize,
}

impl Preview {
    pub fn new(source: &Source, plan: &Plan) -> Preview {
        let tabs: Vec<_> =
            plan.workspaces().flat_map(|workspace| workspace.layout.tabs()).collect();
        let is_file = |url: &str| {
            url.split_once(':').is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case("file"))
        };
        Preview {
            channel: Channel::of(&source.bundle_id),
            workspaces: plan.workspaces().count(),
            skipped_cloud_vms: plan.cloud_vm_keys().len(),
            cleanup_workspaces: plan.cleanup.len(),
            browser_tabs: tabs.iter().filter(|tab| tab.url.is_some()).count(),
            local_file_pages: tabs
                .iter()
                .filter(|tab| tab.url.as_deref().is_some_and(is_file))
                .count(),
            ssh_workspaces: plan
                .workspaces()
                .filter(|workspace| workspace.remote.is_some())
                .count(),
            agent_chats: plan
                .workspaces()
                .filter(|workspace| workspace.remote.is_none() && workspace.cloud_vm.is_none())
                .flat_map(|workspace| workspace.layout.tabs())
                .filter(|tab| tab.agent.is_some())
                .count(),
        }
    }
}
