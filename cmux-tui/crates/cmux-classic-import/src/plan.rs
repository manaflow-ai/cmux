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
use crate::model::{Group, Rect, Snapshot, Tab, Workspace};
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
    /// Terminals whose scrollback was cut to its newest lines so the plan
    /// fits one reply ([`Plan::fit`]); classic's own file and its backup
    /// keep all of it.
    #[serde(default)]
    pub scrollback_trimmed: usize,
}

/// The plan does not fit its reply even with no scrollback: `needed` bytes of
/// JSON against a budget of `budget`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooLarge {
    pub needed: usize,
    pub budget: usize,
}

impl std::fmt::Display for TooLarge {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "classic's save is too large to import: its plan takes {} bytes without scrollback, over the {}-byte reply limit",
            self.needed, self.budget
        )
    }
}

/// Bytes room for `scrollback_trimmed`'s digits, which [`Plan::fit`] sets after measuring.
const COUNT_ROOM: usize = 24;

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

    /// Fits the plan's JSON in `budget` bytes, so one reply carries it
    /// (the daemon's control replies are bounded). Scrollback is shared out
    /// fairly: a terminal under its share keeps all of its own, and the rest
    /// split what is left, each keeping its newest lines. Sizes are counted
    /// as JSON writes them (an escape byte takes six), so the budget holds
    /// for the encoded reply. Too large when the plan without any scrollback
    /// is over `budget`; the plan then holds no scrollback.
    pub fn fit(&mut self, budget: usize) -> Result<(), TooLarge> {
        // Every tab's scrollback, in tab order, taken out to be measured apart.
        let mut texts: Vec<Option<String>> = Vec::new();
        for tab in self.tabs_mut() {
            texts.push(tab.scrollback.take());
        }
        self.scrollback_trimmed = 0;
        let needed = json_len(self).saturating_add(COUNT_ROOM);
        if needed > budget {
            return Err(TooLarge { needed, budget });
        }
        // A tab's `null` becomes a string: its quotes and its escaped text.
        let costs: Vec<usize> = texts
            .iter()
            .map(|text| text.as_deref().map_or(0, |text| escaped_len(text) + 2))
            .collect();
        let shares = fair_shares(&costs, budget - needed);
        let mut trimmed = 0;
        let fitted: Vec<Option<String>> = texts
            .into_iter()
            .zip(costs.iter().zip(shares))
            .map(|(text, (cost, share))| {
                let text = text?;
                if share >= *cost {
                    return Some(text);
                }
                trimmed += 1;
                newest(&text, share.saturating_sub(2))
            })
            .collect();
        for (tab, text) in self.tabs_mut().into_iter().zip(fitted) {
            tab.scrollback = text;
        }
        self.scrollback_trimmed = trimmed;
        Ok(())
    }

    fn tabs_mut(&mut self) -> Vec<&mut Tab> {
        self.windows
            .iter_mut()
            .flat_map(|window| window.workspaces.iter_mut())
            .flat_map(|workspace| workspace.layout.tabs_mut())
            .collect()
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

/// The bytes `value`'s JSON takes, counted without keeping it.
fn json_len<T: Serialize>(value: &T) -> usize {
    struct Count(usize);
    impl std::io::Write for Count {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 += bytes.len();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut count = Count(0);
    // Writing to a counter fails only for a value that has no JSON, which a plan always has.
    let _ = serde_json::to_writer(&mut count, value);
    count.0
}

/// The bytes one byte of a string takes inside a JSON string, as serde_json writes it.
fn escaped_byte_len(byte: u8) -> usize {
    match byte {
        b'"' | b'\\' | b'\n' | b'\r' | b'\t' | 0x08 | 0x0c => 2,
        0x00..=0x1f => 6,
        _ => 1,
    }
}

/// The bytes `text` takes inside a JSON string, quotes left out.
fn escaped_len(text: &str) -> usize {
    text.bytes().map(escaped_byte_len).sum()
}

/// Each cost's share of `budget`: the smallest costs are met in full and the
/// rest split what is left evenly, so no terminal's scrollback crowds out the others'.
fn fair_shares(costs: &[usize], budget: usize) -> Vec<usize> {
    let mut order: Vec<(usize, usize)> = costs.iter().copied().enumerate().collect();
    order.sort_by_key(|(_, cost)| *cost);
    let mut shares = vec![0; costs.len()];
    let mut left = budget;
    let count = order.len();
    for (done, (index, cost)) in order.into_iter().enumerate() {
        let share = cost.min(left / (count - done));
        left -= share;
        if let Some(slot) = shares.get_mut(index) {
            *slot = share;
        }
    }
    shares
}

/// The newest part of `text` that takes at most `budget` escaped bytes,
/// starting on a line of its own when it holds a line break (a cut line's
/// half could start inside a color sequence); none when nothing fits.
fn newest(text: &str, budget: usize) -> Option<String> {
    let mut start = text.len();
    let mut spent = 0usize;
    for (index, character) in text.char_indices().rev() {
        let cost = if character.is_ascii() {
            escaped_byte_len(character as u8)
        } else {
            character.len_utf8()
        };
        if spent + cost > budget {
            break;
        }
        spent += cost;
        start = index;
    }
    let kept = text.get(start..)?;
    let kept = match kept.find('\n') {
        Some(line) if start > 0 => kept.get(line + 1..)?,
        _ => kept,
    };
    (!kept.is_empty()).then(|| kept.to_string())
}
