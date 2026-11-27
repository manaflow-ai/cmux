//! The close handlers' decisions still made in the App's Swift (Handlers/: TabCloseGuard,
//! TabLifecycle, CloseUndoToasts, WorkspaceBulkClose, WorkspaceGroupClose,
//! WorkspaceSelectionClose, DestructiveConfirmation, DaemonClosedHistory, TabRestart,
//! HistoryHandlers). The App reads its windows, panes, daemons and settings, sends the facts,
//! and acts on the answer: the AppKit, the daemon requests and the strings stay there.

use serde::{Deserialize, Serialize};

use crate::close::Warning;

// MARK: TabCloseGuard

/// One pane a closing selection leaves, as the hide before the daemon's read reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LeavingPart {
    /// The pane is on the daemon of the close.
    pub same_daemon: bool,
    /// The close leaves the pane with no tab.
    pub emptied: bool,
    /// The pane's layout can show it leaving (never a screen's last pane).
    pub can_show_pane_close: bool,
    /// One of its closing tabs is a browser tab (asking starts its close).
    pub closes_browser: bool,
    /// One of its closing tabs is a page that decides its own close (beforeunload).
    pub page_decides: bool,
}

/// Whether a person's close hides its tabs (terminals alive) while the daemon is read: only
/// when every part is on its daemon, an emptied pane can show itself leaving and holds no
/// browser tab, no page decides its close, and the close is not already known to ask.
pub fn hides(parts: &[LeavingPart], known_to_ask: bool) -> bool {
    !parts.is_empty()
        && !known_to_ask
        && parts.iter().all(|part| {
            part.same_daemon
                && (!part.emptied || (part.can_show_pane_close && !part.closes_browser))
                && !part.page_decides
        })
}

/// The input event AppKit is dispatching when Close Tab runs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PressEvent {
    KeyDown,
    KeyUp,
    /// A mouse button down or up (left, right, other).
    Mouse,
    /// No event, or one of another type.
    #[default]
    #[serde(other)]
    None,
}

/// A Close Tab press as the aim at an emptied pane reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Press {
    /// The press's time is the event's; false: the invocation's input time, else now.
    pub event_time: bool,
    pub is_key: bool,
    pub is_repeat: bool,
}

/// How the press of `event` reads: a key down keeps its repeat flag, a key up or a mouse
/// press is not a key, and with no event the time is the gated run's press.
pub fn press(event: PressEvent, is_repeat: bool) -> Press {
    match event {
        PressEvent::KeyDown => Press { event_time: true, is_key: true, is_repeat },
        PressEvent::KeyUp | PressEvent::Mouse => {
            Press { event_time: true, is_key: false, is_repeat: false }
        }
        PressEvent::None => Press { event_time: false, is_key: false, is_repeat: false },
    }
}

/// The title of a tab close's question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum TabCloseTitle {
    /// "Close “title”?": the one closing tab's title.
    One { title: String },
    /// "Close N tabs?".
    Count { count: usize },
}

/// One sentence of a tab close's question's body.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum TabCloseLine {
    /// "NAME is still working." (None: the agent unnamed).
    AgentWorking { agent: Option<String> },
    /// "Still running: a, b.".
    StillRunning { joined: String },
    /// "No answer from: a, b.".
    NoAnswer { joined: String },
}

/// Which "Don't ask again" toggle the question turns off.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Suppresses {
    /// `app.warnBeforeClosingAgentSession`.
    AgentSession,
    /// `app.warnBeforeClosingTab`.
    Tab,
}

/// A tab close's question, its strings still to look up.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabClosePrompt {
    pub title: TabCloseTitle,
    /// The body's sentences, joined with a space.
    pub body: Vec<TabCloseLine>,
    pub suppresses: Suppresses,
}

/// The question `warning` asks for closing `titles` (each closing tab's title).
pub fn tab_close_prompt(warning: &Warning, titles: &[String]) -> TabClosePrompt {
    let title = match titles {
        [one] => TabCloseTitle::One { title: one.clone() },
        _ => TabCloseTitle::Count { count: titles.len() },
    };
    match warning {
        Warning::Agent { name } => TabClosePrompt {
            title,
            body: vec![TabCloseLine::AgentWorking { agent: name.clone() }],
            suppresses: Suppresses::AgentSession,
        },
        Warning::Programs { programs, unanswered } => {
            let mut body = Vec::new();
            if !programs.is_empty() {
                body.push(TabCloseLine::StillRunning { joined: programs.join(", ") });
            }
            if !unanswered.is_empty() {
                body.push(TabCloseLine::NoAnswer { joined: unanswered.join(", ") });
            }
            TabClosePrompt { title, body, suppresses: Suppresses::Tab }
        }
    }
}

// MARK: TabLifecycle

/// The kind `tabs::new_tab_kind` picked, when it is a chat or the New Tab page.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatKind {
    #[default]
    Agent,
    Page,
}

/// The facts of a new agent tab or New Tab page.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatTabFacts {
    pub kind: ChatKind,
    /// A person's press (not a script's).
    pub user: bool,
    /// The pane has a controller (it is shown).
    pub shown: bool,
    /// Option-click on the +: the chat opens as a tab here.
    pub plus_chat_is_tab: bool,
    /// The pane keeps a person's New Tab page in it (`ChatColumnPlacement.keepsNewTabPage`).
    pub keeps_new_tab_page: bool,
    /// The new chat's placement from this pane is here (`NewChatPlacement.resolve == .here`).
    pub placed_here: bool,
}

/// Where a new agent tab or New Tab page goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatTabRoute {
    /// The chat is a tab of this pane (Option-click on the +).
    pub as_tab: bool,
    /// The chat column's placement picks the strip first (`ChatColumnPlacement.route`).
    pub column: bool,
    /// The chat is bound for the chat dock: it is not moved to a slot.
    pub docks: bool,
}

/// Where a chat or page from `facts` opens: a docked chat gets no tools, so a person's chat
/// opens in the strip, except a New Tab page the pane keeps; a person's Option-click opens a tab.
pub fn chat_tab_route(facts: ChatTabFacts) -> ChatTabRoute {
    let as_tab = facts.kind == ChatKind::Agent && facts.user && facts.plus_chat_is_tab;
    let column = facts.user
        && !as_tab
        && facts.shown
        && !(facts.kind == ChatKind::Page && facts.keeps_new_tab_page);
    let docks = !as_tab && facts.kind == ChatKind::Agent && facts.shown && !facts.placed_here;
    ChatTabRoute { as_tab, column, docks }
}

/// What `tabs::reopen` answered for a reopen on the other engine (None: no answer).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReopenAnswer {
    pub decision: Option<String>,
    pub reason: Option<String>,
    /// The tab is in the pane.
    pub has_tab: bool,
}

/// What the reopen on the other engine does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "refusal")]
pub enum ReopenStep {
    /// Open the page on the other engine, then close the original.
    Reopen,
    /// The tab is on that engine already: nothing to do.
    Same,
    /// Refused with this reason.
    Refuse(ReopenRefusal),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReopenRefusal {
    ProxiedTabStaysInChromium,
    /// Chromium's own reason when it has one, else not a browser tab.
    ChromiumUnavailable,
    NotABrowserTab,
}

/// The reopen's step from its answer.
pub fn reopen_step(answer: &ReopenAnswer) -> ReopenStep {
    let Some(decision) = answer.decision.as_deref().filter(|_| answer.has_tab) else {
        return ReopenStep::Refuse(ReopenRefusal::NotABrowserTab);
    };
    match (decision, answer.reason.as_deref()) {
        ("reopen", _) => ReopenStep::Reopen,
        ("same", _) => ReopenStep::Same,
        (_, Some("proxiedTabStaysInChromium")) => {
            ReopenStep::Refuse(ReopenRefusal::ProxiedTabStaysInChromium)
        }
        (_, Some("chromiumUnavailable")) => ReopenStep::Refuse(ReopenRefusal::ChromiumUnavailable),
        _ => ReopenStep::Refuse(ReopenRefusal::NotABrowserTab),
    }
}

/// Where a caller terminal's link opens (`LinkTarget`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum LinkTarget {
    /// A pane: `other` when it is not the invoked one.
    Pane {
        other: bool,
    },
    SplitRight,
    NewColumn,
    #[default]
    #[serde(other)]
    Other,
}

/// How a link's target opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkOpen {
    /// The browser opens in the target pane, not the invoked one.
    pub in_target_pane: bool,
    /// The new column goes beside the caller.
    pub new_column_beside: bool,
}

/// The link's pane and column.
pub fn link_open(target: LinkTarget) -> LinkOpen {
    LinkOpen {
        in_target_pane: matches!(target, LinkTarget::Pane { other: true }),
        new_column_beside: matches!(target, LinkTarget::SplitRight | LinkTarget::NewColumn),
    }
}

// MARK: TabRestart

/// What Restart does with `tabs::restart_refusal`'s answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RestartStep {
    Restart,
    RefuseNotATerminal,
    RefuseTabNotDead,
}

/// Restart runs only on a sure "no refusal"; a tab not a terminal says so; any other answer
/// (a live shell, no answer) is not dead.
pub fn restart_step(refusal: Option<&str>, answered: bool) -> RestartStep {
    match (refusal, answered) {
        (None, true) => RestartStep::Restart,
        (Some("notATerminal"), _) => RestartStep::RefuseNotATerminal,
        _ => RestartStep::RefuseTabNotDead,
    }
}

// MARK: HistoryHandlers

/// What `history.open` found for an entry.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Lookup {
    Found,
    StillLoading,
    #[default]
    #[serde(other)]
    Gone,
}

/// What `history.open` does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HistoryOpening {
    Open,
    /// Unavailable: the history still loads.
    StillLoading,
    /// The entry is gone (or found but no longer available).
    EntryGone,
}

pub fn history_opening(lookup: Lookup, available: bool) -> HistoryOpening {
    match lookup {
        Lookup::Found if available => HistoryOpening::Open,
        Lookup::StillLoading => HistoryOpening::StillLoading,
        Lookup::Found | Lookup::Gone => HistoryOpening::EntryGone,
    }
}

// MARK: CloseUndoToasts

/// How many recent daemon closed items the toasts keep for their diagnostics.
pub const RECENT_DAEMON_ITEMS: usize = 8;

/// How many of `count` recent items to drop from the front to keep the newest
/// [`RECENT_DAEMON_ITEMS`].
pub fn recent_overflow(count: usize) -> usize {
    count.saturating_sub(RECENT_DAEMON_ITEMS)
}

/// The undo toast's message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ToastMessage {
    /// "Closed N tabs".
    TabsClosed { count: usize },
    /// "Closed “title”".
    TabClosed { title: String },
    /// "Closed “Untitled”".
    Untitled,
}

/// The message of a toast for `tabs` closed tabs, the first titled `title`.
pub fn toast_message(tabs: usize, title: &str) -> ToastMessage {
    if tabs > 1 {
        ToastMessage::TabsClosed { count: tabs }
    } else if title.is_empty() {
        ToastMessage::Untitled
    } else {
        ToastMessage::TabClosed { title: title.to_owned() }
    }
}

/// Whether the closes of `daemons` (each part's daemon index) are one group: two or more
/// parts, all on one daemon. Else each pane's part is its own.
pub fn one_group(daemons: &[usize]) -> bool {
    match daemons {
        [first, rest @ ..] => !rest.is_empty() && rest.iter().all(|daemon| daemon == first),
        [] => false,
    }
}

// MARK: Workspace closes

/// The facts of a bulk workspace close's run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BulkRunFacts {
    /// Close Others in Group: each other group closes whole.
    pub by_group: bool,
    pub user: bool,
    /// The workspaces that close.
    pub count: usize,
    /// One window lists every row that closes.
    pub one_window: bool,
    /// A window stays open to show the undo toast.
    pub survivor: bool,
    /// The close says why when it finds nothing.
    pub refuses_empty: bool,
}

/// What a bulk workspace close does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BulkRun {
    /// Refused with its nothing-to-close reason.
    NothingToClose,
    /// The selection close's path (rows stay closing until the daemon answers).
    Selection,
    /// Close here, then the undo toast.
    CloseWithUndo,
    /// Close here, no toast (automation, one workspace, or no window stays).
    Close,
}

pub fn bulk_run(facts: BulkRunFacts) -> BulkRun {
    if facts.count == 0 && facts.refuses_empty {
        return BulkRun::NothingToClose;
    }
    if !facts.by_group && facts.user && facts.count > 1 && facts.one_window {
        return BulkRun::Selection;
    }
    if facts.user && facts.count > 1 && facts.survivor {
        BulkRun::CloseWithUndo
    } else {
        BulkRun::Close
    }
}

/// Whether Close Workspaces in Group offers its undo: a person's close of a group that
/// listed workspaces, with a window that stays open.
pub fn group_close_offers_undo(user: bool, names: usize, survivor: bool) -> bool {
    user && names > 0 && survivor
}

/// Whether a selection close's settled batch offers its undo: two or more closed and a
/// window stays open (one workspace's close has its own toast).
pub fn selection_offers_undo(names: usize, survivor: bool) -> bool {
    names > 1 && survivor
}

// MARK: DestructiveConfirmation

/// The fixed questions (title, body and button from one strings table) an action asks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FixedPrompt {
    KillMachine,
    DeleteSnapshot,
    RemoveFile,
    DeleteFirewallRule,
    /// `cloud.secret.remove`: its own question, Return does not confirm it.
    SecretRemove,
    /// `git.worktree.remove`: asked once its tab and folder are pinned; Return does not confirm.
    WorktreeRemove,
}

/// The fixed question of action `id`, None for one `workspaces::confirmation` picks.
pub fn fixed_prompt(id: &str) -> Option<FixedPrompt> {
    Some(match id {
        "cloudKillMachine" => FixedPrompt::KillMachine,
        "palette.cloud.deleteSnapshot" => FixedPrompt::DeleteSnapshot,
        "cloudFileRemove" => FixedPrompt::RemoveFile,
        "cloud.secret.remove" => FixedPrompt::SecretRemove,
        "cloudFirewallDelete" => FixedPrompt::DeleteFirewallRule,
        "git.worktree.remove" => FixedPrompt::WorktreeRemove,
        _ => return None,
    })
}

/// Whether Return confirms the fixed question (false for a question that comes up after a read).
pub fn fixed_returns_confirm(prompt: FixedPrompt) -> bool {
    !matches!(prompt, FixedPrompt::SecretRemove | FixedPrompt::WorktreeRemove)
}

// MARK: DaemonClosedHistory

const HISTORY_PREFIX: &str = "daemon:";

/// The id a history list gives a daemon-recorded item.
pub fn history_id(id: &str) -> String {
    format!("{HISTORY_PREFIX}{id}")
}

/// The daemon item id of a history list id, None for the app's trackers.
pub fn daemon_id(history_id: &str) -> Option<&str> {
    history_id.strip_prefix(HISTORY_PREFIX)
}

/// The window id of a window record `install/window` (the record itself when it has no `/`).
pub fn record_window(record: &str) -> &str {
    record.split_once('/').map_or(record, |(_, window)| window)
}

/// `since` (seconds since 1970, this Mac's clock) as the daemon's milliseconds, never negative.
pub fn since_ms(seconds: f64) -> u64 {
    // The clamp keeps the cast in range (a NaN casts to 0); the fraction of a millisecond goes.
    (seconds * 1000.0).max(0.0) as u64
}

/// Whether Clear History since `since` clears an item closed at `closed_at_ms`.
pub fn clears(closed_at_ms: u64, since: Option<u64>) -> bool {
    since.is_none_or(|since| closed_at_ms >= since)
}

/// A closed item's kind.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    #[default]
    Tab,
    Screen,
    Workspace,
    Window,
}

/// What a failed `closed.reopen` says.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReopenFailure {
    /// A workspace (not a group's record) the daemon no longer has: "No recently closed workspace".
    NoRecentlyClosedWorkspace,
    /// The error itself.
    Error,
}

pub fn reopen_failure(kind: ItemKind, grouped: bool, code: Option<&str>) -> ReopenFailure {
    if kind == ItemKind::Workspace && !grouped && code == Some("resource.not_found") {
        ReopenFailure::NoRecentlyClosedWorkspace
    } else {
        ReopenFailure::Error
    }
}

/// Whether a failed `closed.delete` still reached its goal: an item already gone.
pub fn delete_done(code: Option<&str>) -> bool {
    code == Some("resource.not_found")
}

/// What the app shows after a reopen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReopenShow {
    /// A workspace group forms again in the sidebar; no window changes.
    Nothing,
    /// The closed window shows again.
    Window,
    /// The tab is selected in its pane, once reported.
    SelectTab,
    /// The reopened workspace shows, once the store has it.
    Workspace,
    /// The item shows once the store has it (`show`).
    Show,
}

/// What a reopened item of `kind` shows. `tab_in_pane`: a tab that came back to a shown pane.
pub fn reopen_show(kind: ItemKind, grouped: bool, tab_in_pane: bool) -> ReopenShow {
    if grouped {
        return ReopenShow::Nothing;
    }
    match kind {
        ItemKind::Window => ReopenShow::Window,
        ItemKind::Tab if tab_in_pane => ReopenShow::SelectTab,
        ItemKind::Workspace => ReopenShow::Workspace,
        ItemKind::Tab | ItemKind::Screen => ReopenShow::Show,
    }
}

#[cfg(test)]
#[path = "handlers_close_tests.rs"]
mod tests;
