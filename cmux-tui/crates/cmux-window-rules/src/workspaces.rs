//! The rules of the workspace, screen, space and workspace group verbs: what
//! a bulk close closes and asks, which window keeps its undo toast, what a
//! screen close or move takes, a space's terminal defaults, a workspace's
//! description and status, going to a group, a group's parent chain, the
//! question a space delete asks, and which question a destructive action
//! asks at all. The app reads its models, asks here, and acts: the daemon
//! command, the dialog with its localized text, the toast.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::targets::trim_spaces;

// MARK: Bulk closes

/// What a bulk close of workspaces takes, by its action id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BulkPlan {
    /// Every workspace of the window that lists the target row, else the
    /// targeted window (`workspace.closeAll`).
    WindowWorkspaces,
    /// Every workspace of every open window.
    AllWindows,
    /// The workspaces a sidebar section lists.
    Section,
    /// Every other group of the window that lists the target group, each as
    /// Close Workspaces in Group closes it.
    OtherGroups,
    /// The other members of the target workspace's group.
    OthersInGroup,
    /// The rows outside the kept selection, in sidebar order (others, above,
    /// below).
    AroundSelection,
}

/// What a refused bulk close says when it finds nothing to close.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NothingToClose {
    NoOtherWorkspaces,
    NoWorkspacesBelow,
    NoWorkspacesAbove,
    NoOtherWorkspacesInGroup,
}

/// One bulk close of workspaces: how it finds what closes, what it says when
/// that is nothing (None: it runs and closes nothing), and whether its closes
/// go group by group (Undo reopens each group's workspaces, then its record).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkClose {
    pub id: &'static str,
    pub plan: BulkPlan,
    pub nothing_to_close: Option<NothingToClose>,
    pub by_group: bool,
}

const fn bulk(
    id: &'static str,
    plan: BulkPlan,
    nothing_to_close: Option<NothingToClose>,
) -> BulkClose {
    BulkClose { id, plan, nothing_to_close, by_group: matches!(plan, BulkPlan::OtherGroups) }
}

/// The workspace closes that take several at once (RECOVERABLE-BY-DEFAULT,
/// Lawrence 2026-10-07): they run at once, and a person's close of two or
/// more gets an undo toast in a window that stays open.
pub const BULK_CLOSES: [BulkClose; 8] = [
    bulk(
        "palette.closeOtherWorkspaces",
        BulkPlan::AroundSelection,
        Some(NothingToClose::NoOtherWorkspaces),
    ),
    bulk(
        "palette.closeWorkspacesBelow",
        BulkPlan::AroundSelection,
        Some(NothingToClose::NoWorkspacesBelow),
    ),
    bulk(
        "palette.closeWorkspacesAbove",
        BulkPlan::AroundSelection,
        Some(NothingToClose::NoWorkspacesAbove),
    ),
    bulk(
        "workspace.closeOthersInGroup",
        BulkPlan::OthersInGroup,
        Some(NothingToClose::NoOtherWorkspacesInGroup),
    ),
    bulk("workspace.closeAll", BulkPlan::WindowWorkspaces, None),
    bulk("workspace.closeAllInAllWindows", BulkPlan::AllWindows, None),
    bulk("sidebar.section.closeWorkspaces", BulkPlan::Section, None),
    bulk("workspaceGroup.closeOthers", BulkPlan::OtherGroups, None),
];

/// The bulk close `id` names, if it is one.
pub fn bulk_close(id: &str) -> Option<&'static BulkClose> {
    BULK_CLOSES.iter().find(|close| close.id == id)
}

/// The open window that keeps a workspace after `closing` closes, where the
/// undo toast shows: the active one first, then each window in order. Each
/// entry of `windows` lists one window's workspaces; `active` is the active
/// window's index. None when every window closes.
pub fn survivor(
    active: Option<usize>,
    windows: &[Vec<String>],
    closing: &[String],
) -> Option<usize> {
    let stays = |index: usize| {
        windows.get(index).is_some_and(|window| window.iter().any(|id| !closing.contains(id)))
    };
    active
        .filter(|&index| index < windows.len() && stays(index))
        .or_else(|| (0..windows.len()).find(|&index| stays(index)))
}

/// The one window that lists every closing row: `owners` holds each row's
/// window (None for a row no window lists). None when they span windows;
/// Some(None) when no window lists any (the active one then).
pub fn rows_window(owners: &[Option<String>]) -> Option<Option<String>> {
    let mut found: Option<&String> = None;
    for owner in owners.iter().flatten() {
        match found {
            Some(first) if first != owner => return None,
            _ => found = Some(owner),
        }
    }
    Some(found.cloned())
}

/// The title of a workspace close's question.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum CloseTitle {
    /// The caller's own title (a group's workspaces).
    Given,
    /// "Close “name”?" for the one closing workspace.
    One,
    /// "Close N workspaces?".
    Count { count: usize },
}

/// The body of a workspace close's question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum CloseBody {
    /// The foreground programs still running, unique and sorted.
    Running { programs: Vec<String> },
    /// No window stays open to undo it; an incognito workspace cannot be
    /// reopened at all.
    NoUndo { incognito: bool },
}

/// A workspace close's question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClosePrompt {
    pub title: CloseTitle,
    pub body: CloseBody,
    /// "Don't ask again" turns `app.warnBeforeClosingTab` off (only for the
    /// running programs' question).
    pub suppresses_warning: bool,
}

/// The facts of a workspace close's question.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CloseFacts {
    /// How many workspaces close.
    pub count: usize,
    /// The foreground programs their terminals run (read only while
    /// `app.warnBeforeClosingTab` is on).
    pub programs: Vec<String>,
    /// No window stays open to show the undo toast.
    pub ask_without_undo: bool,
    pub incognito: bool,
    /// The caller gives its own title.
    pub titled: bool,
}

/// The question before a workspace close, or None to close at once: a
/// terminal running a program asks, and so do two or more closing with no
/// window left to undo them.
pub fn close_prompt(facts: &CloseFacts) -> Option<ClosePrompt> {
    if facts.count == 0
        || (facts.programs.is_empty() && !(facts.ask_without_undo && facts.count > 1))
    {
        return None;
    }
    let title = if facts.titled {
        CloseTitle::Given
    } else if facts.count == 1 {
        CloseTitle::One
    } else {
        CloseTitle::Count { count: facts.count }
    };
    let mut programs = facts.programs.clone();
    programs.sort();
    programs.dedup();
    let suppresses_warning = !programs.is_empty();
    let body = if programs.is_empty() {
        CloseBody::NoUndo { incognito: facts.incognito }
    } else {
        CloseBody::Running { programs }
    };
    Some(ClosePrompt { title, body, suppresses_warning })
}

// MARK: Destructive questions

/// Which question a destructive action's run asks (the app builds it, with
/// its reads and localized text). The Cloud deletes are asked in the app
/// before this table.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Confirmation {
    /// Close Workspace asks in its own handler (its row stays while the
    /// terminals answer).
    InHandler,
    /// Close Workspaces in Group: only a foreground program asks.
    GroupWorkspaces,
    /// Save and Close of workspaces asks as their close does.
    Stash,
    /// A bulk close of workspaces ([`close_prompt`]).
    BulkClose,
    BrowserProfileDelete,
    AgentExtensions,
    /// Delete Space ([`space_delete`]).
    SpaceDelete,
    /// Clear Space Terminal Defaults ([`space_clear_defaults`]).
    SpaceClearDefaults,
    RemoteInstall,
    UpdateRollback,
    /// A tab group's close follows the tab close rule.
    TabGroupClose,
    KillProcess,
    DeleteChief,
    LeaveConversation,
    /// No question: the action runs.
    None,
}

/// The question action `id` asks; `stash` says the app's stash actions list it.
pub fn confirmation(id: &str, stash: bool) -> Confirmation {
    match id {
        "closeWorkspace" => Confirmation::InHandler,
        "workspaceGroup.closeWorkspaces" => Confirmation::GroupWorkspaces,
        _ if stash => Confirmation::Stash,
        _ if bulk_close(id).is_some() => Confirmation::BulkClose,
        "browserProfile.delete" => Confirmation::BrowserProfileDelete,
        "browser.allowAgentWithExtensions" => Confirmation::AgentExtensions,
        "space.delete" => Confirmation::SpaceDelete,
        "space.clearDefaults" => Confirmation::SpaceClearDefaults,
        "remote.install" => Confirmation::RemoteInstall,
        "updates.rollback" => Confirmation::UpdateRollback,
        "tabGroup.close" => Confirmation::TabGroupClose,
        "taskManager.killProcess" => Confirmation::KillProcess,
        "home.deleteChief" => Confirmation::DeleteChief,
        "home.leaveConversation" => Confirmation::LeaveConversation,
        _ => Confirmation::None,
    }
}

/// What a Delete Space run asks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "ask")]
pub enum SpaceDelete {
    /// Runs without asking.
    None,
    /// The app reads what the closing workspaces' terminals run, then asks again.
    ReadPrograms,
    /// "Delete “X”?" naming how many workspaces close and what still runs.
    Prompt { programs: Vec<String> },
}

/// The facts of a Delete Space run.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SpaceDeleteFacts {
    /// `app.warnBeforeClosingTab`.
    pub warn: bool,
    /// The space resolved; false: the handler refuses it with its reason.
    pub resolved: bool,
    /// The Default space (never deleted).
    pub default_space: bool,
    /// The run moves the workspaces to another space: nothing closes.
    pub moves: bool,
    /// What the closing terminals run, once read.
    pub programs: Option<Vec<String>>,
}

/// Delete Space asks only while a closing workspace runs a program and
/// `app.warnBeforeClosingTab` is on (the rule of every close); a move closes
/// nothing and never asks.
pub fn space_delete(facts: &SpaceDeleteFacts) -> SpaceDelete {
    if !facts.warn || !facts.resolved || facts.default_space || facts.moves {
        return SpaceDelete::None;
    }
    match &facts.programs {
        None => SpaceDelete::ReadPrograms,
        Some(programs) if programs.is_empty() => SpaceDelete::None,
        Some(programs) => SpaceDelete::Prompt { programs: programs.clone() },
    }
}

/// What the daemon said of a space's held terminal defaults.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HeldDefaults {
    /// Not asked yet.
    #[default]
    NotAsked,
    /// No answer: it asks.
    Unanswered,
    /// The space holds defaults.
    Held,
    /// It holds none.
    Empty,
}

/// What a Clear Space Terminal Defaults run does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ClearDefaults {
    Ask,
    Run,
    /// The app asks the daemon (`list-personal`) and asks here again.
    ReadDaemon,
}

/// The facts of a Clear Space Terminal Defaults run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClearDefaultsFacts {
    pub resolved: bool,
    /// The app's mirror shows defaults on the space.
    pub shown: bool,
    /// A defaults run for the space has not finished.
    pub in_flight: bool,
    /// The local daemon is connected.
    pub connected: bool,
    pub held: HeldDefaults,
}

/// Clear asks while the space has defaults; one with none runs at once. The
/// mirror lags a reply, so a space shown without defaults still asks while a
/// run is in flight, and asks the daemon before running unasked; a daemon
/// that does not answer asks.
pub fn space_clear_defaults(facts: ClearDefaultsFacts) -> ClearDefaults {
    if !facts.resolved {
        return ClearDefaults::Run;
    }
    if facts.shown || facts.in_flight {
        return ClearDefaults::Ask;
    }
    match facts.held {
        HeldDefaults::NotAsked if facts.connected => ClearDefaults::ReadDaemon,
        HeldDefaults::NotAsked | HeldDefaults::Empty => ClearDefaults::Run,
        HeldDefaults::Unanswered | HeldDefaults::Held => ClearDefaults::Ask,
    }
}

// MARK: Space terminal defaults

/// One `space.setDefaults` argument as the run passed it: `text` None when
/// the value is not text.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DefaultsArgument {
    pub text: Option<String>,
}

/// A change to a space's directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum CwdChange {
    Clear,
    Set { path: String },
}

/// The fields a `space.setDefaults` run names; None leaves a field as the
/// space has it. An empty `env` clears it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultsPatch {
    pub cwd: Option<CwdChange>,
    pub env: Option<BTreeMap<String, String>>,
}

/// Why a `space.setDefaults` run is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DefaultsRefusal {
    DefaultsMustBeText,
    CwdMustBeAbsolute,
    EnvMustBeObject,
}

/// `space.setDefaults` arguments: `cwd` (an absolute directory; the app
/// expands `~` and `~user` before it asks, a platform lookup) and `env` (a
/// JSON object of strings). A named argument replaces
/// its field and an empty one clears it; a field the run does not name keeps
/// the space's value. A value that is not text, or a relative `cwd` (the
/// socket makes a bare `--cwd` the string "true"), is refused rather than
/// clearing or setting a bad directory.
pub fn defaults_patch(
    cwd: Option<&DefaultsArgument>,
    env: Option<&DefaultsArgument>,
) -> Result<DefaultsPatch, DefaultsRefusal> {
    let cwd = match cwd {
        None => None,
        Some(argument) => Some(match argument_text(argument)? {
            "" => CwdChange::Clear,
            path if path.starts_with('/') => CwdChange::Set { path: path.to_owned() },
            _ => return Err(DefaultsRefusal::CwdMustBeAbsolute),
        }),
    };
    let env = match env {
        None => None,
        Some(argument) => Some(match argument_text(argument)? {
            "" => BTreeMap::new(),
            json => serde_json::from_str::<BTreeMap<String, String>>(json)
                .map_err(|_| DefaultsRefusal::EnvMustBeObject)?,
        }),
    };
    Ok(DefaultsPatch { cwd, env })
}

/// An argument's text without its spaces; refused when it is not text.
fn argument_text(argument: &DefaultsArgument) -> Result<&str, DefaultsRefusal> {
    argument.text.as_deref().map(trim_spaces).ok_or(DefaultsRefusal::DefaultsMustBeText)
}

// MARK: Workspace description and status

/// A workspace's manual task status lanes, in cycle order (classic cmux's).
pub const STATUS_LANES: [&str; 5] = ["todo", "working", "needs-attention", "review", "done"];

/// One field of `workspace.update`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum FieldUpdate {
    #[default]
    Unchanged,
    /// Clears the description, or makes the status automatic again.
    Clear,
    Set {
        value: String,
    },
}

/// A description or status action's run.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "verb")]
pub enum NotesVerb {
    /// Edit Description: the text, trimmed; empty clears it.
    Describe {
        #[serde(default)]
        text: Option<String>,
    },
    ClearDescription,
    MarkDone,
    /// Cycle Workspace Status: the lane after `current`; To Do from automatic.
    CycleStatus {
        #[serde(default)]
        current: Option<String>,
    },
    /// Set Workspace Status: `auto` clears the pinned lane, a lane pins it.
    SetStatus {
        #[serde(default)]
        status: Option<String>,
    },
}

/// What a description or status action writes, and the daemon capabilities
/// its fields need.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesUpdate {
    pub description: FieldUpdate,
    pub task_status: FieldUpdate,
    pub capabilities: Vec<&'static str>,
}

/// The values Set Workspace Status takes: `auto`, then the lanes.
pub fn status_choices() -> Vec<&'static str> {
    std::iter::once("auto").chain(STATUS_LANES).collect()
}

/// The write a description or status action makes; Err with the choices
/// for a status that is none of them.
pub fn notes(verb: &NotesVerb) -> Result<NotesUpdate, Vec<&'static str>> {
    let set = |value: &str| FieldUpdate::Set { value: value.to_owned() };
    let (description, task_status) = match verb {
        NotesVerb::Describe { text } => match text.as_deref().map(str::trim).unwrap_or("") {
            "" => (FieldUpdate::Clear, FieldUpdate::Unchanged),
            text => (set(text), FieldUpdate::Unchanged),
        },
        NotesVerb::ClearDescription => (FieldUpdate::Clear, FieldUpdate::Unchanged),
        NotesVerb::MarkDone => (FieldUpdate::Unchanged, set("done")),
        NotesVerb::CycleStatus { current } => {
            let next = current
                .as_deref()
                .and_then(|lane| STATUS_LANES.iter().position(|known| *known == lane))
                .and_then(|index| STATUS_LANES.get(index.checked_add(1)?))
                .map_or(STATUS_LANES[0], |lane| *lane);
            (FieldUpdate::Unchanged, set(next))
        }
        NotesVerb::SetStatus { status } => match status.as_deref().unwrap_or("") {
            "auto" => (FieldUpdate::Unchanged, FieldUpdate::Clear),
            lane if STATUS_LANES.contains(&lane) => (FieldUpdate::Unchanged, set(lane)),
            _ => return Err(status_choices()),
        },
    };
    let mut capabilities = Vec::new();
    if description != FieldUpdate::Unchanged {
        capabilities.push("workspace-description-v1");
    }
    if task_status != FieldUpdate::Unchanged {
        capabilities.push("workspace-status-v1");
    }
    Ok(NotesUpdate { description, task_status, capabilities })
}

// MARK: Workspaces and groups

/// One tab, as a workspace's directory reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DirectoryTab {
    pub id: String,
    pub cwd: Option<String>,
    pub terminal: bool,
}

/// A workspace's directory: the selected tab's of its focused pane while a
/// window shows it (`selected`), else its first tab's that reports one.
/// `terminals_only` reads only terminal tabs (New Workspace Like This, Copy
/// Path); Reveal in Finder reads every tab.
pub fn directory(
    tabs: &[DirectoryTab],
    selected: Option<&str>,
    terminals_only: bool,
) -> Option<String> {
    let mut read = tabs.iter().filter(|tab| tab.terminal || !terminals_only);
    if let Some(selected) = selected
        && let Some(cwd) =
            read.clone().find(|tab| tab.id == selected).and_then(|tab| tab.cwd.clone())
    {
        return Some(cwd);
    }
    read.find_map(|tab| tab.cwd.clone())
}

/// One sidebar group, as going to it reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FocusGroup {
    pub collapsed: bool,
    pub pinned: bool,
    /// Its workspaces in sidebar order, each with whether it is still being created.
    pub workspaces: Vec<FocusWorkspace>,
    /// How many other items (pages, links) it lists.
    pub items: usize,
}

/// One workspace row of a group.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FocusWorkspace {
    pub id: String,
    pub pending: bool,
}

/// What going to a sidebar group does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusPlan {
    /// The group is collapsed and opens.
    pub expands: bool,
    /// The workspace to show: its first not still being created.
    pub workspace: Option<String>,
    /// An empty saved group reopens (its header's click).
    pub reopens: bool,
}

/// Going to a group (Go to Workspace's group rows, Next and Previous
/// Workspace Group) shows its first workspace; a collapsed group opens first
/// so that row is visible; an empty saved group reopens.
pub fn group_focus(group: &FocusGroup) -> FocusPlan {
    let workspace = group
        .workspaces
        .iter()
        .find(|workspace| !workspace.pending)
        .map(|workspace| workspace.id.clone());
    FocusPlan {
        expands: group.collapsed && workspace.is_some(),
        reopens: group.pinned && group.workspaces.is_empty() && group.items == 0,
        workspace,
    }
}

/// The deepest a group chain is read: a malformed parent loop cannot spin.
pub const GROUP_DEPTH: usize = 16;

/// The groups from `start` out through each one's parent, innermost first
/// (`parents` maps each known group to its parent), at most [`GROUP_DEPTH`].
pub fn group_chain(start: Option<&str>, parents: &BTreeMap<String, Option<String>>) -> Vec<String> {
    let mut chain = Vec::new();
    let mut next = start.map(str::to_owned);
    while let Some(id) = next {
        if chain.len() >= GROUP_DEPTH {
            break;
        }
        let Some(parent) = parents.get(&id) else { break };
        next = parent.clone();
        chain.push(id);
    }
    chain
}

// MARK: Screens

/// Which screens a screen close verb takes besides the target.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenClose {
    /// Every other screen that is not pinned.
    Others,
    /// Every screen after the target.
    ToRight,
    /// Every screen before the target that is not pinned.
    ToLeft,
}

/// The screens (indices) `verb` closes around screen `index`; `pinned` says
/// which screens are pinned. Empty: the app refuses it (no other screens).
pub fn screen_close(verb: ScreenClose, index: usize, pinned: &[bool]) -> Vec<usize> {
    pinned
        .iter()
        .enumerate()
        .filter(|&(other, &is_pinned)| match verb {
            ScreenClose::Others => other != index && !is_pinned,
            ScreenClose::ToRight => other > index,
            ScreenClose::ToLeft => other < index && !is_pinned,
        })
        .map(|(other, _)| other)
        .collect()
}

/// Where Move Screen Left/Right puts screen `index`, or None at the edge.
pub fn screen_move(index: usize, offset: i64, count: usize) -> Option<usize> {
    let target = i64::try_from(index).ok()?.checked_add(offset)?;
    usize::try_from(target).ok().filter(|&target| target < count)
}

/// One screen, as moving a screen group reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GroupedScreen {
    pub group: Option<String>,
    pub pinned: bool,
}

/// Where Move Screen Group Left/Right puts group `group`: past the
/// neighboring screen or group on that side, never into the pinned run.
/// None at the edge or for a group with no screen.
pub fn screen_group_move(group: &str, forward: bool, screens: &[GroupedScreen]) -> Option<usize> {
    let member = |screen: &GroupedScreen| screen.group.as_deref() == Some(group);
    let first = screens.iter().position(member)?;
    let last = screens.iter().rposition(member)?;
    let span = |neighbor: &GroupedScreen| {
        neighbor.group.as_ref().map_or(1, |id| {
            screens.iter().filter(|screen| screen.group.as_ref() == Some(id)).count()
        })
    };
    if forward {
        let neighbor = screens.get(last.checked_add(1)?)?;
        return first.checked_add(span(neighbor));
    }
    let neighbor = screens.get(first.checked_sub(1)?)?;
    if neighbor.pinned {
        return None;
    }
    first.checked_sub(span(neighbor))
}

#[cfg(test)]
#[path = "workspaces_tests.rs"]
mod tests;
