//! The workspace hover card's choice and order, moved from the app's CmuxNextSidebar
//! `WorkspaceHoverCardContent` with the same inputs and outputs:
//!
//! - [`card`]: which facts the card shows and in which order (`make` over `facts`): the wait,
//!   the usage warnings, the notes, the agent, the place, the pull request, the machine, the
//!   status entries and checklist, then the preview line; the layout's cut (`classic`,
//!   `compact`, `timeline`, `log`, `minimal`), the history it lists and its stats, the ports.
//! - [`preview`]: what the card's last line says (a wait, the pull request, the last reply).
//! - [`meaningful_folder`], [`repository_name`], [`place`]: where the workspace works, as one
//!   line, never a home folder.
//! - [`newest_pull_request`], [`pull_request_tone`], [`connection`], [`resource_row`],
//!   [`stats`]: the pull request named, a state's and a machine link's color, the resource
//!   row's tone and bars, the history's prompt count and worked time.
//!
//! The words stay in the app: every text here is one the app passed in (a note, a reply, a
//! status entry, a localized line it formatted), or one built from them without words (the
//! place's "cmux · main", a pull request's "#12 title"). A fact whose words are a fixed
//! localized phrase ("Notifications muted", "3 more", "Needs you") comes back with its `kind`
//! (and `count`) and no text; the app words it. Icons stay in the app too, by `kind` and `index`.
//!
//! Pure, no I/O. The app asks over `cmux_layout_reducer_json` op `sidebar_hover_card_rules`
//! ([`respond`]), one rule per call tagged by `rule`.

use serde::{Deserialize, Serialize};

/// Separates the place's and the agent's parts (`WorkspaceRowContent.separator`).
pub const SEPARATOR: &str = " · ";
/// The card lists this many status entries, then how many more (`SidebarWorkspaceStatus.visibleEntryLimit`).
pub const VISIBLE_ENTRY_LIMIT: usize = 3;
/// The card lists this many checklist items, then how many more (`visibleChecklistLimit`).
pub const VISIBLE_CHECKLIST_LIMIT: usize = 6;
/// The card names at most this many agents present (`workspace.presence.prefix(2)`).
pub const PRESENCE_LIMIT: usize = 2;

/// The fact kinds the card's rules read (`Fact.kind`).
pub mod kind {
    pub const NEEDS_INPUT: &str = "needsInput";
    pub const USAGE_WARNING: &str = "usageWarning";
    pub const MUTED: &str = "muted";
    pub const DESCRIPTION: &str = "description";
    pub const TASK_STATUS: &str = "taskStatus";
    pub const NOTIFICATION: &str = "notification";
    pub const UNREAD: &str = "unread";
    pub const AGENT: &str = "agent";
    pub const USAGE: &str = "usage";
    pub const TASK: &str = "task";
    pub const FREED: &str = "freed";
    pub const PRESENCE: &str = "presence";
    pub const COMMAND: &str = "command";
    pub const BRANCH: &str = "branch";
    pub const FOLDER: &str = "folder";
    pub const PULL_REQUEST: &str = "pullRequest";
    pub const MACHINE: &str = "machine";
    pub const MACHINE_STATUS: &str = "machineStatus";
    pub const STATUS: &str = "status";
    pub const MORE: &str = "more";
    pub const CHECKLIST: &str = "checklist";
    pub const LAST_REPLY: &str = "lastReply";
    pub const NEEDS_YOU: &str = "needsYou";
    pub const SINCE_LOOKED: &str = "sinceLooked";
    pub const PORTS: &str = "ports";
}

/// The facts the history-first layouts (`log`, `minimal`) keep above it (`keptOverHistory`).
pub const KEPT_OVER_HISTORY: [&str; 5] =
    [kind::NEEDS_INPUT, kind::USAGE_WARNING, kind::MUTED, kind::NEEDS_YOU, kind::SINCE_LOOKED];

/// What someone said or asked: it reads in the primary ink (`Fact.messageKinds`).
pub const MESSAGE_KINDS: [&str; 5] =
    [kind::NEEDS_INPUT, kind::NOTIFICATION, kind::TASK, kind::DESCRIPTION, kind::LAST_REPLY];

// MARK: Inputs

/// The card's layout (`WorkspaceHoverCardOptions.Layout`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    #[default]
    Timeline,
    Compact,
    Log,
    Classic,
    Minimal,
}

fn yes() -> bool {
    true
}

fn twenty() -> i64 {
    20
}

/// The card's options (`WorkspaceHoverCardOptions`), its defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Options {
    #[serde(default)]
    pub layout: Layout,
    #[serde(default = "yes")]
    pub shows_timings: bool,
    #[serde(default = "yes")]
    pub shows_prompts: bool,
    #[serde(default = "yes")]
    pub shows_waiting: bool,
    #[serde(default = "yes")]
    pub shows_git: bool,
    #[serde(default = "yes")]
    pub shows_ports: bool,
    #[serde(default = "twenty")]
    pub max_rows: i64,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            layout: Layout::Timeline,
            shows_timings: true,
            shows_prompts: true,
            shows_waiting: true,
            shows_git: true,
            shows_ports: true,
            max_rows: 20,
        }
    }
}

impl Options {
    /// How many lines the history lists (`historyRows`): none for classic and minimal, three
    /// at most for compact.
    pub fn history_rows(&self) -> usize {
        let rows = match self.layout {
            Layout::Classic | Layout::Minimal => 0,
            Layout::Compact => self.max_rows.min(3),
            Layout::Timeline | Layout::Log => self.max_rows,
        };
        usize::try_from(rows).unwrap_or(0)
    }
}

/// A history line's kind (`SidebarTimelineEntry.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    Prompt,
    Started,
    Waiting,
    Finished,
    Failed,
}

/// One history line (`SidebarTimelineEntry`), newest first in a timeline.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub kind: EntryKind,
    /// Seconds since 1970.
    pub date: f64,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub is_notice: bool,
}

/// A pull request's state (`SidebarPullRequestItem.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrState {
    Passing,
    Merged,
    Failing,
    Conflict,
    Draft,
    Closed,
}

/// One pull request of the row's badge (`SidebarPullRequestItem`), in the badge's order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PrItem {
    pub state: PrState,
    pub number: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub additions: i64,
    #[serde(default)]
    pub deletions: i64,
    #[serde(default)]
    pub repository: String,
}

/// A machine's kind (`SidebarMachine.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineKind {
    Local,
    Cloud,
    Ssh,
    Server,
}

/// A machine's link (`SidebarMachine.Status`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineStatus {
    Connected,
    UpdateAvailable,
    Connecting,
    Reconnecting,
    Installing,
    UpdateRequired,
    InstallRequired,
    Pausing,
    Resuming,
    Deleting,
    Disconnected,
    Offline,
    AuthFailed,
    Unreachable,
    Failed,
    Paused,
    PausedIdle,
}

/// The workspace's machine (`SidebarMachine`), as the card reads it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Machine {
    pub kind: MachineKind,
    pub name: String,
    pub status: MachineStatus,
}

/// A fact another part of the card made, with its own kind and words
/// (`WorkspaceHoverCardWork.facts`, `WorkspaceHoverCardOrigin.facts`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Listed {
    pub kind: String,
    pub text: String,
}

/// One workspace as the card reads it (`SidebarWorkspace` and its detail). Texts are as the
/// workspace holds them; `formerly` and `usage` are the app's own words for the agent's former
/// name and the usage line, given when the workspace has them.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Workspace {
    pub title: String,
    /// `detail.needsInput`, untrimmed.
    pub needs_input: Option<String>,
    pub usage_warnings: Vec<String>,
    pub muted: bool,
    /// `workspaceDescription`, untrimmed.
    pub description: Option<String>,
    /// `taskStatus.title`, when the workspace has a task status.
    pub task_status: Option<String>,
    pub notification_text: Option<String>,
    /// `unread`'s count; zero or a dot is none.
    pub unread: i64,
    pub agent_display_name: Option<String>,
    pub agent_former_name: Option<String>,
    /// `Strings.formerlyKnownAs(display, former)`, given with both names.
    pub formerly: Option<String>,
    pub agent_name: Option<String>,
    pub model: Option<String>,
    /// `usageFact`'s words, given when acpmux reported the context or the cost.
    pub usage: Option<String>,
    pub context_tokens: Option<f64>,
    pub context_window: Option<f64>,
    pub task: Option<String>,
    pub work: Vec<Listed>,
    pub origin: Vec<Listed>,
    /// `WorkspaceHoverCardOrigin.isFooter(shipped)`: the origin goes after the preview.
    pub origin_footer: bool,
    /// How many of its terminals the freeing tier ended.
    pub freed: i64,
    /// `Strings.presenceLine` of each agent present, in order.
    pub presence: Vec<String>,
    pub command: Option<String>,
    pub command_since: bool,
    pub directory: Option<String>,
    pub branch: Option<String>,
    /// The hook's `pr` status entry.
    pub pull_request: Option<String>,
    pub ports: Option<String>,
    pub last_message: Option<String>,
    /// `reported.entries`' display texts.
    pub reported: Vec<String>,
    /// `checklist`'s item texts.
    pub checklist: Vec<String>,
    /// `activity` is `.waiting`.
    pub waits_for_person: bool,
    /// `agentChip == .needsYou`.
    pub needs_you_chip: bool,
    pub activity_since: bool,
    /// `lastActivity`, seconds since 1970.
    pub last_activity: Option<f64>,
}

// MARK: Output

/// A color the card draws (`HoverCardTone`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tone {
    Primary,
    Secondary,
    Tertiary,
    Success,
    Attention,
    Danger,
    Merged,
}

/// What a machine that is not plainly connected is doing (`connectionWord`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Word {
    Offline,
    Installing,
    /// `Strings.attentionStatus(status)`.
    Attention,
}

/// One row of the card (`WorkspaceHoverCardContent.Fact`), without its icon or its words when
/// those are the app's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fact {
    pub kind: String,
    /// The row's text, when it is not a localized phrase the app words from `kind`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// The entry of its source list it shows: a usage warning, a work or origin fact, a
    /// presence, a status entry, a checklist item, the badge's pull request, a port link, or
    /// the timeline's prompt a minimal card's task reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
    /// How many: unread items, freed terminals, entries past the limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    pub lines: i64,
    /// The card's preview line.
    #[serde(default, skip_serializing_if = "is_false")]
    pub preview: bool,
    /// A running fact: the card appends how long it has run.
    #[serde(default, skip_serializing_if = "is_false")]
    pub timed: bool,
    /// A pull request's state color (its icon and status word), a machine's dot, a machine
    /// status's or the "Needs you" line's ink, a wait's icon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tone: Option<Tone>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word: Option<Word>,
    /// The usage line's context share of its window, for the ring.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub share: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additions: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i64>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Fact {
    fn new(kind: &str, text: Option<String>) -> Fact {
        Fact {
            kind: kind.to_owned(),
            text,
            index: None,
            count: None,
            lines: 1,
            preview: false,
            timed: false,
            tone: None,
            word: None,
            share: None,
            additions: None,
            deletions: None,
        }
    }

    fn text(kind: &str, text: &str) -> Fact {
        Fact::new(kind, Some(text.to_owned()))
    }

    fn lines(mut self, lines: i64) -> Fact {
        self.lines = lines;
        self
    }

    fn index(mut self, index: usize) -> Fact {
        self.index = Some(index);
        self
    }

    fn count(mut self, count: i64) -> Fact {
        self.count = Some(count);
        self
    }

    fn tone(mut self, tone: Tone) -> Fact {
        self.tone = Some(tone);
        self
    }

    /// What someone said or asked (`Fact.isMessage`).
    pub fn is_message(&self) -> bool {
        MESSAGE_KINDS.contains(&self.kind.as_str())
    }
}

/// One history line the card lists: the timeline's entry and its text (a wait's reason
/// filled in).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Listing {
    pub index: usize,
    #[serde(default)]
    pub text: Option<String>,
}

/// The history's stats (`stats`): the app words "Prompts: 4 · Worked 12m".
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Stats {
    pub prompts: usize,
    /// Seconds worked; the app names it only from one second.
    pub worked: f64,
}

/// What the card shows (`WorkspaceHoverCardContent`), in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Card {
    pub facts: Vec<Fact>,
    /// The machine row stays visible above the details (`host`): the workspace is not local.
    pub host: bool,
    /// The card says how long ago the workspace was last active (`age`).
    pub age: bool,
    /// The status row appends how long it has held (`activitySince` kept).
    pub activity_since: bool,
    pub timeline: Vec<Listing>,
    pub stats: Option<Stats>,
    /// One port row per link, in order (`ports`); the facts keep no ports line then.
    pub ports: Vec<Fact>,
    /// The ports entry the port rows come from, for the user's card (`portsText`).
    pub ports_text: bool,
}

// MARK: Rules

/// Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`.
fn trimmed(text: &str) -> &str {
    text.trim_matches(char::is_whitespace)
}

fn non_empty_trimmed(text: Option<&str>) -> Option<&str> {
    text.map(trimmed).filter(|t| !t.is_empty())
}

/// Not a local host plus the same title, nor empty (`WorkspaceRowContent.nonRedundantDetail`).
pub fn non_redundant(text: &str, title: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let parts: Vec<&str> = text.split(SEPARATOR).map(trimmed).collect();
    !(parts.len() == 2
        && parts[0].to_lowercase() == "local"
        && parts[1].to_lowercase() == trimmed(title).to_lowercase())
}

/// Why the workspace waits on the person, trimmed; a blank reason is none (`needsInputReason`).
pub fn needs_input_reason(workspace: &Workspace) -> Option<&str> {
    non_empty_trimmed(workspace.needs_input.as_deref())
}

/// The agent chat's last reply worth a line: none while a task says more (`lastReply`).
fn last_reply(workspace: &Workspace) -> Option<&str> {
    if workspace.task.is_some() {
        return None;
    }
    non_empty_trimmed(workspace.last_message.as_deref())
}

/// What the card's last line says (`Preview`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "preview", rename_all = "snake_case")]
pub enum Preview {
    NeedsYou,
    PullRequest,
    Message { message: String },
    Empty,
}

/// The preview: a wait first, then a pull request (unless `shows_git` is off), then the last
/// reply (`preview`).
pub fn preview(
    workspace: &Workspace,
    pull_requests: Option<&[PrItem]>,
    shows_git: bool,
) -> Preview {
    if needs_input_reason(workspace).is_some() || workspace.needs_you_chip {
        return Preview::NeedsYou;
    }
    if workspace.waits_for_person {
        return Preview::NeedsYou;
    }
    if shows_git
        && (newest_pull_request(pull_requests).is_some()
            || workspace.pull_request.as_deref().is_some_and(|p| !p.is_empty()))
    {
        return Preview::PullRequest;
    }
    if let Some(message) = last_reply(workspace) {
        return Preview::Message { message: message.to_owned() };
    }
    Preview::Empty
}

/// The pull request the card names: the newest open or merged one, else the newest
/// (`newestPullRequest`); its index in the badge.
pub fn newest_pull_request(items: Option<&[PrItem]>) -> Option<usize> {
    let items = items?;
    items.iter().position(|i| i.state != PrState::Closed).or(if items.is_empty() {
        None
    } else {
        Some(0)
    })
}

/// A pull request state's color (`pullRequestTone`).
pub fn pull_request_tone(state: PrState) -> Tone {
    match state {
        PrState::Passing => Tone::Success,
        PrState::Merged => Tone::Merged,
        PrState::Failing => Tone::Danger,
        PrState::Conflict | PrState::Draft => Tone::Attention,
        PrState::Closed => Tone::Tertiary,
    }
}

/// A machine's link as a color (`connectionTone`).
pub fn connection_tone(status: MachineStatus) -> Tone {
    use MachineStatus::*;
    match status {
        Connected | UpdateAvailable | Connecting | Reconnecting => Tone::Success,
        Installing | UpdateRequired | InstallRequired | Pausing | Resuming | Deleting
        | Disconnected => Tone::Attention,
        Offline | AuthFailed | Unreachable | Failed => Tone::Danger,
        Paused | PausedIdle => Tone::Secondary,
    }
}

/// What a machine that is not plainly connected is doing, nil when connected (`connectionWord`).
pub fn connection_word(status: MachineStatus) -> Option<Word> {
    use MachineStatus::*;
    match status {
        Connected | UpdateAvailable | Connecting | Reconnecting => None,
        Offline => Some(Word::Offline),
        Installing => Some(Word::Installing),
        _ => Some(Word::Attention),
    }
}

/// `path`'s components as `NSString.standardizingPath` leaves them, lexically: no empty or `.`
/// parts, an absolute path's `..` taking its parent.
fn standardized(path: &str) -> Vec<&str> {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if absolute => {
                parts.pop();
            }
            _ => parts.push(part),
        }
    }
    parts
}

/// The folder worth a line: its own name, or nil for none, `~`, `home`, a machine's home
/// (`/home/<user>`, `/Users/<user>`, `/root`) or `/` (`meaningfulFolder`).
pub fn meaningful_folder(directory: Option<&str>, home: &str) -> Option<String> {
    let mut path = trimmed(directory?).to_owned();
    if path.is_empty() {
        return None;
    }
    if path == "~" || path.starts_with("~/") {
        let rest = &path[1..];
        path = if rest.is_empty() { home.to_owned() } else { format!("{home}/{rest}") };
    }
    let parts = standardized(&path);
    let home_parts = standardized(home);
    if parts.is_empty() || parts == home_parts || parts == ["root"] {
        return None;
    }
    if parts.len() == 2 && (parts[0] == "home" || parts[0] == "Users") {
        return None;
    }
    parts.last().map(|p| (*p).to_owned())
}

fn letters(text: &str) -> String {
    text.to_lowercase().chars().filter(|c| c.is_alphabetic() || c.is_numeric()).collect()
}

/// The repository's name: the newest pull request's, else the folder's on a branch, unless
/// the folder spells the whole branch (`repositoryName`).
pub fn repository_name(
    pull_requests: Option<&[PrItem]>,
    folder: Option<&str>,
    branch: Option<&str>,
) -> Option<String> {
    if let (Some(items), Some(index)) = (pull_requests, newest_pull_request(pull_requests))
        && let Some(item) = items.get(index)
        && let Some(name) = item.repository.split('/').rfind(|s| !s.is_empty())
    {
        return Some(name.to_owned());
    }
    let branch = branch.filter(|b| !b.is_empty())?;
    let folder = folder?;
    if letters(folder) == letters(branch) { None } else { Some(folder.to_owned()) }
}

/// Where the workspace works, as one line (`place`): "cmux · main" on a branch, the folder off
/// one; without `shows_git`, the folder only.
pub fn place(
    workspace: &Workspace,
    pull_requests: Option<&[PrItem]>,
    home: &str,
    shows_git: bool,
) -> Option<Fact> {
    let folder = meaningful_folder(workspace.directory.as_deref(), home);
    if shows_git && let Some(branch) = workspace.branch.as_deref().filter(|b| !b.is_empty()) {
        let repository = repository_name(pull_requests, folder.as_deref(), Some(branch));
        let text = match repository {
            Some(repository) => format!("{repository}{SEPARATOR}{branch}"),
            None => branch.to_owned(),
        };
        return Some(Fact::new(kind::BRANCH, Some(text)));
    }
    folder.map(|f| Fact::new(kind::FOLDER, Some(f)))
}

/// The pull request row: the newest one's number and title in its color with its size, else
/// the hook's `pr` entry as reported (`pullRequestFact`).
pub fn pull_request_fact(workspace: &Workspace, pull_requests: Option<&[PrItem]>) -> Option<Fact> {
    if let (Some(items), Some(index)) = (pull_requests, newest_pull_request(pull_requests))
        && let Some(item) = items.get(index)
    {
        let tone = pull_request_tone(item.state);
        let text = if item.title.is_empty() {
            format!("#{}", item.number)
        } else {
            format!("#{} {}", item.number, item.title)
        };
        let mut fact = Fact::new(kind::PULL_REQUEST, Some(text)).index(index).tone(tone);
        fact.additions = (item.additions > 0).then_some(item.additions);
        fact.deletions = (item.deletions > 0).then_some(item.deletions);
        return Some(fact);
    }
    let pr = workspace.pull_request.as_deref().filter(|p| !p.is_empty())?;
    Some(Fact::text(kind::PULL_REQUEST, pr))
}

/// The usage line's context share (`usageFact`'s ring): at most the whole window.
fn usage_share(workspace: &Workspace) -> Option<f64> {
    let tokens = workspace.context_tokens?;
    let window = workspace.context_window?;
    Some((tokens / window).min(1.0))
}

/// The facts card, the classic layout (`facts`): one row per meaningful fact.
fn facts(
    workspace: &Workspace,
    machine: Option<&Machine>,
    pull_requests: Option<&[PrItem]>,
    home: &str,
    shows_git: bool,
) -> Vec<Fact> {
    let remote = machine.filter(|m| m.kind != MachineKind::Local);
    let mut facts: Vec<Fact> = Vec::new();
    let preview_line = preview(workspace, pull_requests, shows_git);
    let reason = needs_input_reason(workspace);
    if let Some(reason) = reason {
        facts.push(Fact::text(kind::NEEDS_INPUT, reason).lines(3).tone(Tone::Attention));
    }
    for (index, warning) in workspace.usage_warnings.iter().enumerate() {
        facts.push(
            Fact::text(kind::USAGE_WARNING, warning).lines(2).index(index).tone(Tone::Attention),
        );
    }
    if workspace.muted {
        facts.push(Fact::new(kind::MUTED, None));
    }
    if let Some(notes) = non_empty_trimmed(workspace.description.as_deref()) {
        facts.push(Fact::text(kind::DESCRIPTION, notes).lines(6));
    }
    if let Some(status) = workspace.task_status.as_deref() {
        facts.push(Fact::text(kind::TASK_STATUS, status));
    }
    if let Some(text) = workspace.notification_text.as_deref().filter(|t| !t.is_empty()) {
        facts.push(Fact::text(kind::NOTIFICATION, text).lines(2));
    } else if workspace.unread > 0 {
        facts.push(Fact::new(kind::UNREAD, None).count(workspace.unread));
    }
    let identity = workspace.agent_display_name.as_deref().map(|name| {
        match workspace.agent_former_name.as_deref() {
            Some(former) if former != name => {
                workspace.formerly.clone().unwrap_or_else(|| name.to_owned())
            }
            _ => name.to_owned(),
        }
    });
    if workspace.agent_name.is_some() || identity.is_some() {
        let text = [identity, workspace.agent_name.clone(), workspace.model.clone()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(SEPARATOR);
        facts.push(Fact::new(kind::AGENT, Some(text)));
    }
    if let Some(usage) = workspace.usage.as_deref() {
        let mut fact = Fact::text(kind::USAGE, usage);
        fact.share = usage_share(workspace);
        facts.push(fact);
    }
    if let Some(task) = workspace.task.as_deref() {
        facts.push(Fact::text(kind::TASK, task).lines(3));
    }
    for (index, work) in workspace.work.iter().enumerate() {
        facts.push(Fact::text(&work.kind, &work.text).index(index));
    }
    let origin: Vec<Fact> = workspace
        .origin
        .iter()
        .enumerate()
        .map(|(index, origin)| Fact::text(&origin.kind, &origin.text).index(index))
        .collect();
    if !workspace.origin_footer {
        facts.extend(origin.iter().cloned());
    }
    if workspace.freed > 0 {
        facts.push(Fact::new(kind::FREED, None).count(workspace.freed).lines(2));
    }
    for (index, presence) in workspace.presence.iter().take(PRESENCE_LIMIT).enumerate() {
        facts.push(Fact::text(kind::PRESENCE, presence).index(index));
    }
    if let Some(command) = workspace.command.as_deref() {
        let mut fact = Fact::text(kind::COMMAND, command);
        fact.timed = workspace.command_since;
        facts.push(fact);
    }
    if let Some(place) =
        place(workspace, if shows_git { pull_requests } else { None }, home, shows_git)
    {
        facts.push(place);
    }
    let pull_request = pull_request_fact(workspace, pull_requests);
    if preview_line != Preview::PullRequest
        && let Some(pull_request) = pull_request.clone()
    {
        facts.push(pull_request);
    }
    if let Some(remote) = remote {
        let tone = connection_tone(remote.status);
        let text = (remote.kind != MachineKind::Cloud).then(|| remote.name.clone());
        facts.push(Fact::new(kind::MACHINE, text).tone(tone));
        if let Some(word) = connection_word(remote.status) {
            let mut fact = Fact::new(kind::MACHINE_STATUS, None).tone(tone);
            fact.word = Some(word);
            facts.push(fact);
        }
    }
    let entries = &workspace.reported;
    for (index, entry) in entries.iter().take(VISIBLE_ENTRY_LIMIT).enumerate() {
        facts.push(Fact::text(kind::STATUS, entry).index(index));
    }
    if entries.len() > VISIBLE_ENTRY_LIMIT {
        facts.push(Fact::new(kind::MORE, None).count(more(entries.len(), VISIBLE_ENTRY_LIMIT)));
    }
    let checklist = &workspace.checklist;
    for (index, item) in checklist.iter().take(VISIBLE_CHECKLIST_LIMIT).enumerate() {
        facts.push(Fact::text(kind::CHECKLIST, item).index(index));
    }
    if checklist.len() > VISIBLE_CHECKLIST_LIMIT {
        facts.push(
            Fact::new(kind::MORE, None).count(more(checklist.len(), VISIBLE_CHECKLIST_LIMIT)),
        );
    }
    match preview_line {
        Preview::PullRequest => {
            if let Some(mut pull_request) = pull_request {
                pull_request.preview = true;
                facts.push(pull_request);
            }
        }
        Preview::Message { message } => {
            let mut fact = Fact::new(kind::LAST_REPLY, Some(message)).lines(2);
            fact.preview = true;
            facts.push(fact);
        }
        Preview::NeedsYou => {
            if reason.is_none() && !workspace.waits_for_person {
                let mut fact = Fact::new(kind::NEEDS_YOU, None).tone(Tone::Attention);
                fact.preview = true;
                facts.push(fact);
            }
        }
        Preview::Empty => {}
    }
    if workspace.origin_footer {
        facts.extend(origin);
    }
    facts
}

fn more(len: usize, limit: usize) -> i64 {
    i64::try_from(len - limit).unwrap_or(i64::MAX)
}

/// The history's prompt count and worked time (`stats`) over `timeline` (newest first): from
/// each prompt or start to the next later wait, finish, failure or prompt, a running turn until
/// `now`. Nil with neither prompts nor worked time.
pub fn stats(timeline: &[Entry], now: f64) -> Option<Stats> {
    let prompts = timeline.iter().filter(|e| e.kind == EntryKind::Prompt).count();
    let mut worked = 0.0f64;
    let mut end = Some(now);
    for entry in timeline {
        match entry.kind {
            EntryKind::Waiting | EntryKind::Finished | EntryKind::Failed => end = Some(entry.date),
            EntryKind::Prompt | EntryKind::Started => {
                if let Some(stop) = end {
                    worked += (stop - entry.date).max(0.0);
                }
                end = Some(entry.date);
            }
        }
    }
    (prompts > 0 || worked > 0.0).then_some(Stats { prompts, worked })
}

/// What the agents did since the person last looked (`sinceLooked`): how many turns finished,
/// asked for them and failed after `looked`; the app words "Since you looked: 2 done".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SinceLooked {
    pub done: usize,
    pub asked: usize,
    pub failed: usize,
}

/// The counts since `looked`, nil when nothing finished, waited or failed after it.
pub fn since_looked(timeline: &[Entry], looked: f64) -> Option<SinceLooked> {
    let count =
        |kind: EntryKind| timeline.iter().filter(|e| e.date > looked && e.kind == kind).count();
    let counts = SinceLooked {
        done: count(EntryKind::Finished),
        asked: count(EntryKind::Waiting),
        failed: count(EntryKind::Failed),
    };
    (counts.done + counts.asked + counts.failed > 0).then_some(counts)
}

/// How long since `date` the card says, in whole seconds, at least one (`elapsed`).
pub fn elapsed(date: f64, now: f64) -> f64 {
    (now - date).floor().max(1.0)
}

/// `card`'s request: the workspace, its machine and pull requests, the card's options and
/// history, and the app's words for what changed since the person looked.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CardRequest {
    pub workspace: Workspace,
    #[serde(default)]
    pub machine: Option<Machine>,
    /// Seconds since 1970.
    #[serde(default)]
    pub now: f64,
    /// Nil: the classic card's facts (`make` without options).
    #[serde(default)]
    pub options: Option<Options>,
    #[serde(default)]
    pub timeline: Vec<Entry>,
    #[serde(default)]
    pub pull_requests: Option<Vec<PrItem>>,
    #[serde(default)]
    pub home: String,
    /// The app's words for [`since_looked`]'s counts (`sinceLooked(timeline, after: looked)`), given when the person looked and something happened.
    #[serde(default)]
    pub since_looked: Option<String>,
    /// How many links `WorkspacePortLinks` found in the ports entry; nil when it gave no answer.
    #[serde(default)]
    pub port_links: Option<usize>,
}

/// The card for one request (`make`).
pub fn card(request: &CardRequest) -> Card {
    let workspace = &request.workspace;
    let options = request
        .options
        .clone()
        .unwrap_or(Options { layout: Layout::Classic, ..Options::default() });
    let pull_requests = request.pull_requests.as_deref();
    let all =
        facts(workspace, request.machine.as_ref(), pull_requests, &request.home, options.shows_git);
    let host = all.iter().any(|f| f.kind == kind::MACHINE);
    let mut facts: Vec<Fact> = all
        .into_iter()
        .filter(|f| f.text.as_deref().is_none_or(|t| non_redundant(t, &workspace.title)))
        .collect();
    if let Some(text) = request.since_looked.as_deref() {
        facts.insert(0, Fact::text(kind::SINCE_LOOKED, text));
    }
    let mut texts: Vec<Option<String>> = request.timeline.iter().map(|e| e.text.clone()).collect();
    if let (Some(first), Some(slot)) = (request.timeline.first(), texts.first_mut())
        && first.kind == EntryKind::Waiting
        && first.text.is_none()
        && workspace.waits_for_person
    {
        *slot = needs_input_reason(workspace).map(str::to_owned);
    }
    if !options.shows_git {
        facts.retain(|f| f.kind != kind::BRANCH && f.kind != kind::PULL_REQUEST);
    }
    let ports = workspace.ports.as_deref().filter(|p| !p.is_empty());
    let mut port_rows: Vec<Fact> = Vec::new();
    let mut ports_text = false;
    if options.shows_ports
        && let Some(ports) = ports
    {
        match request.port_links.filter(|n| *n > 0) {
            Some(links) => {
                port_rows = (0..links).map(|i| Fact::new(kind::PORTS, None).index(i)).collect();
                ports_text = true;
            }
            None => {
                let at = facts
                    .iter()
                    .position(|f| {
                        f.kind == kind::MACHINE
                            || f.kind == kind::STATUS
                            || f.kind == kind::MORE
                            || f.preview
                    })
                    .unwrap_or(facts.len());
                facts.insert(at, Fact::text(kind::PORTS, ports));
            }
        }
    }
    let mut activity_since = workspace.activity_since;
    if !options.shows_timings {
        activity_since = false;
        for fact in &mut facts {
            fact.timed = false;
        }
    }
    let shown: Vec<Listing> = request
        .timeline
        .iter()
        .zip(texts.iter())
        .enumerate()
        .filter(|(_, (entry, _))| {
            !entry.is_notice
                && match entry.kind {
                    EntryKind::Prompt | EntryKind::Started => options.shows_prompts,
                    EntryKind::Waiting | EntryKind::Finished | EntryKind::Failed => {
                        options.shows_waiting
                    }
                }
        })
        .map(|(index, (_, text))| Listing { index, text: text.clone() })
        .take(options.history_rows())
        .collect();
    let mut timeline: Vec<Listing> = Vec::new();
    let mut card_stats = None;
    let stats_now =
        || if options.shows_timings { stats(&request.timeline, request.now) } else { None };
    match options.layout {
        Layout::Classic => {}
        Layout::Compact => timeline = shown,
        Layout::Timeline => {
            timeline = shown;
            card_stats = stats_now();
        }
        Layout::Log => {
            facts.retain(|f| KEPT_OVER_HISTORY.contains(&f.kind.as_str()));
            timeline = shown;
            card_stats = stats_now();
        }
        Layout::Minimal => {
            facts.retain(|f| KEPT_OVER_HISTORY.contains(&f.kind.as_str()) || f.kind == kind::TASK);
            if !facts.iter().any(|f| f.kind == kind::TASK)
                && let Some((index, prompt)) =
                    request.timeline.iter().zip(texts.iter()).enumerate().find_map(|(i, (e, t))| {
                        (e.kind == EntryKind::Prompt)
                            .then_some(t.as_ref())
                            .flatten()
                            .map(|t| (i, t))
                    })
            {
                let at =
                    facts.iter().position(|f| f.kind == kind::NEEDS_YOU).unwrap_or(facts.len());
                facts.insert(at, Fact::text(kind::TASK, prompt).lines(2).index(index));
            }
        }
    }
    Card {
        facts,
        host,
        age: workspace.last_activity.is_some_and(|last| request.now - last >= 60.0),
        activity_since,
        timeline,
        stats: card_stats,
        ports: port_rows,
        ports_text,
    }
}

/// The resource row's tone and bars (`resourceRow`): warm when hot, each bar against the
/// busiest sample (at least one core).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceRow {
    pub tone: Tone,
    pub bars: Option<Vec<f64>>,
}

/// The resource row for a report's total CPU (nil before the first sample) and the CPU of
/// each sample since the card showed, newest last.
pub fn resource_row(report: bool, cpu: Option<f64>, history: &[f64]) -> Option<ResourceRow> {
    if !report {
        return None;
    }
    let cpu = cpu.unwrap_or(0.0);
    let tone = if cpu >= 2.0 {
        Tone::Danger
    } else if cpu >= 1.0 {
        Tone::Attention
    } else {
        Tone::Secondary
    };
    let peak = history.iter().copied().fold(0.0f64, f64::max).max(1.0);
    let bars = (!history.is_empty()).then(|| history.iter().map(|v| v / peak).collect());
    Some(ResourceRow { tone, bars })
}

// MARK: Wire

/// One `sidebar_hover_card_rules` call, tagged by `rule`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    Card(Box<CardRequest>),
    Preview {
        workspace: Box<Workspace>,
        #[serde(default)]
        pull_requests: Option<Vec<PrItem>>,
        #[serde(default = "yes")]
        shows_git: bool,
    },
    MeaningfulFolder {
        #[serde(default)]
        directory: Option<String>,
        home: String,
    },
    RepositoryName {
        #[serde(default)]
        pull_requests: Option<Vec<PrItem>>,
        #[serde(default)]
        folder: Option<String>,
        #[serde(default)]
        branch: Option<String>,
    },
    Stats {
        timeline: Vec<Entry>,
        now: f64,
    },
    Elapsed {
        date: f64,
        now: f64,
    },
    SinceLooked {
        timeline: Vec<Entry>,
        looked: f64,
    },
    ResourceRow {
        report: bool,
        #[serde(default)]
        cpu: Option<f64>,
        #[serde(default)]
        history: Vec<f64>,
    },
    Connection {
        status: MachineStatus,
    },
    PullRequestTone {
        state: PrState,
    },
}

/// The answer to one [`Request`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    Card(Box<Card>),
    Preview(Preview),
    Folder { folder: Option<String> },
    Repository { repository: Option<String> },
    Stats { stats: Option<Stats> },
    Elapsed { seconds: f64 },
    SinceLooked { since_looked: Option<SinceLooked> },
    ResourceRow { row: Option<ResourceRow> },
    Connection { tone: Tone, word: Option<Word> },
    Tone { tone: Tone },
}

/// The op's answer.
pub fn respond(request: &Request) -> Reply {
    match request {
        Request::Card(r) => Reply::Card(Box::new(card(r))),
        Request::Preview { workspace, pull_requests, shows_git } => {
            Reply::Preview(preview(workspace, pull_requests.as_deref(), *shows_git))
        }
        Request::MeaningfulFolder { directory, home } => {
            Reply::Folder { folder: meaningful_folder(directory.as_deref(), home) }
        }
        Request::RepositoryName { pull_requests, folder, branch } => Reply::Repository {
            repository: repository_name(
                pull_requests.as_deref(),
                folder.as_deref(),
                branch.as_deref(),
            ),
        },
        Request::Stats { timeline, now } => Reply::Stats { stats: stats(timeline, *now) },
        Request::Elapsed { date, now } => Reply::Elapsed { seconds: elapsed(*date, *now) },
        Request::SinceLooked { timeline, looked } => {
            Reply::SinceLooked { since_looked: since_looked(timeline, *looked) }
        }
        Request::ResourceRow { report, cpu, history } => {
            Reply::ResourceRow { row: resource_row(*report, *cpu, history) }
        }
        Request::Connection { status } => {
            Reply::Connection { tone: connection_tone(*status), word: connection_word(*status) }
        }
        Request::PullRequestTone { state } => Reply::Tone { tone: pull_request_tone(*state) },
    }
}

#[cfg(test)]
#[path = "sidebar_hover_card_rules_tests.rs"]
mod tests;
