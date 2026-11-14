//! What a new tab or pane opens, where, and on which engine; which tab and
//! pane moves, numbers, duplicates and restarts do; and the terminal verbs'
//! tables. The app reads the facts (its pane and tab models, the settings,
//! the URL resolver's answers), asks here, and acts on the answer: the
//! daemon command, the strip change, the refusal's localized text.
//!
//! Each refusal is a key the app maps to its `RefusalStrings` text.

use serde::{Deserialize, Serialize};

#[path = "tabs_panes.rs"]
pub mod panes;

// MARK: New tab kind

/// What a pane's selected tab is, as a new tab reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SelectedKind {
    Pty,
    Browser,
    /// Any other tab, or none (an empty pane).
    #[default]
    #[serde(other)]
    Other,
}

/// What Cmd-T opens in a pane.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum NewTabKind {
    Terminal,
    /// A browser tab on `engine` (None: `browser.defaultEngine`).
    Browser {
        engine: Option<String>,
    },
    Agent,
    /// The New Tab page, to pick the kind.
    Page,
}

/// The facts of the tab a new tab opens next to.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewTabFacts {
    pub selected_kind: SelectedKind,
    /// The selected browser tab's engine.
    pub engine: Option<String>,
    /// A session-local browser tab (no daemon record).
    pub local_browser: bool,
    /// An agent chat tab (counted only where the caller counts it: a person's run).
    pub agent: bool,
    /// That agent tab still shows its New Tab page.
    pub new_tab_page: bool,
    /// A person's run (not the CLI, MCP or a script).
    pub user: bool,
    /// Cmd-T itself (`newTab.default`), which gives a person the New Tab page.
    pub follows_setting: bool,
    /// A shown pane whose daemon holds agent tabs (so also the New Tab page).
    pub can_host_agent: bool,
}

/// The kind of the selected tab, as the person sees it: an agent tab gets an
/// agent tab (its New Tab page, the page), a browser tab (daemon or
/// session-local) a browser tab on its engine, so cookies and extensions
/// stay in that engine; a terminal, a remote terminal or an empty pane a
/// terminal tab.
pub fn same_kind(facts: &NewTabFacts) -> NewTabKind {
    if facts.agent {
        return if facts.new_tab_page { NewTabKind::Page } else { NewTabKind::Agent };
    }
    if facts.selected_kind == SelectedKind::Browser {
        return NewTabKind::Browser { engine: facts.engine.clone() };
    }
    if facts.local_browser {
        return NewTabKind::Browser { engine: None };
    }
    NewTabKind::Terminal
}

/// What a new tab opens: a person's Cmd-T always the New Tab page (Leo
/// 2026-10-12), else [`same_kind`]. An agent tab or the page needs a pane
/// that hosts agent tabs; elsewhere a terminal.
pub fn new_tab_kind(facts: &NewTabFacts) -> NewTabKind {
    let kind =
        if facts.user && facts.follows_setting { NewTabKind::Page } else { same_kind(facts) };
    match kind {
        NewTabKind::Agent | NewTabKind::Page if !facts.can_host_agent => NewTabKind::Terminal,
        kind => kind,
    }
}

// MARK: Browser open plan

/// One resolution of typed text into a URL, as the app's URL resolver read
/// it for one engine.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Resolution {
    /// The URL to load (absolute string).
    pub url: String,
    /// The agent URL policy refuses it (Chromium's own pages).
    pub agent_refuses: bool,
    /// Where a `chrome://` page opens (ChromiumPageRoute); None for any other URL.
    pub route: Option<PageRoute>,
    /// The cmux page of a [`PageRoute::CmuxPage`].
    pub page: Option<String>,
}

/// Where a Chromium internal page opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageRoute {
    /// cmux's own page for the same data, in a browser tab.
    CmuxPage,
    /// Settings, Browser section.
    BrowserSettings,
    /// cmux's Passwords page.
    PasswordsPage,
    /// Chromium's own page, in a Chromium tab.
    Chromium,
}

/// The facts of an `openBrowser` run's `url` and `engine` arguments.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowserOpenFacts {
    /// The `url` argument was given.
    pub has_text: bool,
    /// The `engine` argument.
    pub engine: Option<String>,
    /// An agent's run (anything but a person's).
    pub agent: bool,
    /// The typed text names a Chromium internal page.
    pub chromium_internal: bool,
    /// That page is one cmux shows itself (any tab opens it).
    pub cmux_owned: bool,
    /// The text resolved for a WebKit tab; None: not a URL there.
    pub webkit: Option<Resolution>,
    /// The text resolved for a Chromium tab; None: not a URL there.
    pub chromium: Option<Resolution>,
}

/// What `openBrowser` does with its arguments, before any pane or daemon work.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "plan")]
pub enum BrowserOpen {
    Refuse {
        reason: BrowserRefusal,
    },
    /// A tab loading `url` (None: the default page) on `engine`.
    Open {
        url: Option<String>,
        engine: Option<String>,
    },
    /// `chrome://settings`: Settings > Browser opens instead of a tab.
    BrowserSettings,
    /// `chrome://password-manager`: the Passwords page opens instead of a tab.
    PasswordsPage,
}

/// Why `openBrowser` refuses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BrowserRefusal {
    /// The text is no URL on the engine.
    InvalidUrl,
    /// Agents never open Chromium's own pages (plans/cmux-next/passwords.md, section 2).
    AgentChromiumPage,
}

/// The engine tag of Chromium tabs.
pub const CHROMIUM: &str = "cef";
/// The engine tag of WebKit tabs.
pub const WEBKIT: &str = "webkit";

/// The plan of an `openBrowser` run. A Chromium internal page opens in a
/// Chromium tab (never searched in WebKit); a page cmux shows itself opens in
/// any tab. An explicit Chromium request never silently becomes WebKit.
pub fn browser_open(facts: &BrowserOpenFacts) -> BrowserOpen {
    let mut engine = facts.engine.clone();
    if engine.is_none() && facts.has_text && facts.chromium_internal && !facts.cmux_owned {
        engine = Some(CHROMIUM.to_owned());
    }
    if !facts.has_text {
        return BrowserOpen::Open { url: None, engine };
    }
    let resolved =
        if engine.as_deref() == Some(CHROMIUM) { &facts.chromium } else { &facts.webkit };
    let Some(resolved) = resolved else {
        return BrowserOpen::Refuse { reason: BrowserRefusal::InvalidUrl };
    };
    if facts.agent && resolved.agent_refuses {
        return BrowserOpen::Refuse { reason: BrowserRefusal::AgentChromiumPage };
    }
    let url = match resolved.route {
        Some(PageRoute::CmuxPage) => resolved.page.clone().or_else(|| Some(resolved.url.clone())),
        Some(PageRoute::BrowserSettings) => return BrowserOpen::BrowserSettings,
        Some(PageRoute::PasswordsPage) => return BrowserOpen::PasswordsPage,
        Some(PageRoute::Chromium) | None => Some(resolved.url.clone()),
    };
    BrowserOpen::Open { url, engine }
}

/// The facts of where a new browser tab opens.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowserPlacementFacts {
    /// The CLI, MCP or a script runs it.
    pub scripted: bool,
    /// The run may change the view.
    pub allows_view_change: bool,
    /// The tab opens in the pane that has the person's focus.
    pub focused_here: bool,
    /// An agent's tab beside its chat.
    pub beside_caller: bool,
    /// That tab goes into a new column beside the chat.
    pub new_column_beside: bool,
    /// The run asked for a background tab.
    pub opens_in_background: bool,
}

/// How a new browser tab opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserPlacement {
    /// Unselected: an agent never swaps out the page the person works in
    /// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.1).
    pub background: bool,
    /// An agent's tab: no saved password fills in it (plans/cmux-next/browser.md).
    pub agent_driven: bool,
}

pub fn browser_placement(facts: BrowserPlacementFacts) -> BrowserPlacement {
    let person_is_here = facts.scripted && !facts.allows_view_change && facts.focused_here;
    BrowserPlacement {
        background: (facts.beside_caller && facts.new_column_beside)
            || facts.opens_in_background
            || person_is_here,
        agent_driven: facts.scripted,
    }
}

/// The facts of Open in Chromium / Open in WebKit on a tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReopenFacts {
    pub is_browser: bool,
    /// The tab's engine tag (anything but `cef` is WebKit).
    pub current: Option<String>,
    /// The engine asked for.
    pub target: String,
    /// The tab reaches this Mac's localhost through Chromium's proxy.
    pub proxied: bool,
    /// Chromium is not available here.
    pub chromium_unavailable: bool,
}

/// What reopening a tab on the other engine does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision", content = "reason")]
pub enum Reopen {
    Refuse(ReopenRefusal),
    /// Already on that engine: nothing to do.
    Same,
    /// Opens the page on the other engine, then closes the original.
    Reopen,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReopenRefusal {
    NotABrowserTab,
    ProxiedTabStaysInChromium,
    /// The app names Chromium's own reason.
    ChromiumUnavailable,
}

pub fn reopen(facts: &ReopenFacts) -> Reopen {
    if !facts.is_browser {
        return Reopen::Refuse(ReopenRefusal::NotABrowserTab);
    }
    let current = if facts.current.as_deref() == Some(CHROMIUM) { CHROMIUM } else { WEBKIT };
    let target = if facts.target == CHROMIUM { CHROMIUM } else { WEBKIT };
    if current == target {
        return Reopen::Same;
    }
    if target == WEBKIT && facts.proxied {
        return Reopen::Refuse(ReopenRefusal::ProxiedTabStaysInChromium);
    }
    if target == CHROMIUM && facts.chromium_unavailable {
        return Reopen::Refuse(ReopenRefusal::ChromiumUnavailable);
    }
    Reopen::Reopen
}

// MARK: Open Terminal as Chat

/// What Open Terminal as Chat does with the focused terminal's agent status.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "route")]
pub enum TerminalChat {
    /// The terminal reports no agent session.
    NoSession,
    /// The terminal's agent is not one acpmux can resume (only Claude Code and Codex).
    UnsupportedHarness,
    /// A chat resumes this session over ACP (acpmux adopt); the app shows the
    /// tab that already resumes it, else opens one.
    Adopt { harness: String, session: String },
}

/// The route of a terminal whose agent is `agent` with the harness's own
/// session id `session` (a hook report's `agent_session_id`).
pub fn terminal_chat(agent: Option<&str>, session: Option<&str>) -> TerminalChat {
    let Some(session) = session.map(str::trim).filter(|s| !s.is_empty()) else {
        return TerminalChat::NoSession;
    };
    match harness(agent) {
        Some(harness) => {
            TerminalChat::Adopt { harness: harness.to_owned(), session: session.to_owned() }
        }
        None => TerminalChat::UnsupportedHarness,
    }
}

/// The acpmux harness of a terminal agent's name; None for agents acpmux does not adopt.
pub fn harness(agent: Option<&str>) -> Option<&'static str> {
    match agent?.to_lowercase().as_str() {
        "claude" | "claude-code" | "claude_code" => Some("claude"),
        "codex" => Some("codex"),
        _ => None,
    }
}

// MARK: Duplicate Tab

/// The facts of one tab Duplicate Tab acts on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DuplicateFacts {
    /// A daemon browser tab.
    pub browser: bool,
    /// A session-local browser tab.
    pub local_browser: bool,
    pub agent: bool,
    /// A session-local page tab (Settings, History, ...).
    pub local_page: bool,
    /// A daemon tab that shows an internal page.
    pub page: bool,
}

/// What Duplicate Tab does with one tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Duplicate {
    /// Same engine as the original, next to it, with its history.
    Browser,
    /// A new browser tab on the session-local tab's page.
    LocalBrowser,
    Agent,
    /// One tab per page per window: the page is already there.
    Skip,
    /// A terminal in the original's folder.
    Terminal,
}

/// A page tab, which Duplicate Tab leaves alone; a browser or agent tab
/// duplicates even when it shows a page.
pub fn is_page_tab(tab: DuplicateFacts) -> bool {
    !(tab.browser || tab.local_browser || tab.agent) && (tab.local_page || tab.page)
}

/// What Duplicate Tab does with each tab; None (a refusal: a page tab opens
/// once) when every tab is a page tab, or there is none.
pub fn duplicate(tabs: &[DuplicateFacts]) -> Option<Vec<Duplicate>> {
    if tabs.iter().all(|tab| is_page_tab(*tab)) {
        return None;
    }
    Some(
        tabs.iter()
            .map(|tab| {
                if tab.browser {
                    Duplicate::Browser
                } else if tab.local_browser {
                    Duplicate::LocalBrowser
                } else if tab.agent {
                    Duplicate::Agent
                } else if is_page_tab(*tab) {
                    Duplicate::Skip
                } else {
                    Duplicate::Terminal
                }
            })
            .collect(),
    )
}

// MARK: Numbers and moves

/// The tab a select-by-number picks among `count` shown tabs: 9 is always the
/// last, a number past the end the last too, a number below 1 the first.
/// None when there is no tab.
pub fn tab_by_number(number: i64, count: usize) -> Option<usize> {
    let last = count.checked_sub(1)?;
    if number >= 9 {
        return Some(last);
    }
    let index = usize::try_from(number.max(1).saturating_sub(1)).unwrap_or(0);
    Some(index.min(last))
}

/// The pane a focus-by-number picks among `count` panes in Focus Next Pane's
/// order: 9 is always the last; None for a number with no pane.
pub fn pane_by_number(number: i64, count: usize) -> Option<usize> {
    let index = if number >= 9 {
        count.checked_sub(1)?
    } else {
        usize::try_from(number.checked_sub(1)?).ok()?
    };
    (index < count).then_some(index)
}

/// A pane edge, as the daemon's split names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

/// The edge of a move's `direction` argument (`left`, `up`, `down`; anything
/// else is right).
pub fn edge_of_argument(direction: Option<&str>) -> Edge {
    match direction {
        Some("left") => Edge::Left,
        Some("up") => Edge::Top,
        Some("down") => Edge::Bottom,
        _ => Edge::Right,
    }
}

/// The facts of a Move Tab (or Tab Group) to New Split.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MoveToSplitFacts {
    /// The `direction` argument.
    pub direction: Option<String>,
    /// A whole tab group moves.
    pub group: bool,
    /// The tabs of the source pane.
    pub tabs_in_pane: usize,
    /// The source pane is the chat dock.
    pub chat_dock: bool,
    /// The moving tab is an agent chat.
    pub chat: bool,
    /// The dock's column handle is known.
    pub dock_column: bool,
}

/// Where a Move to New Split goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision")]
pub enum MoveToSplit {
    /// The chat dock never splits (ChatDockRules).
    Refuse,
    /// A new split on `edge` of the source pane.
    Split { edge: Edge },
    /// A chat moved out of the dock to its right while the dock keeps another
    /// tab: a new column right after the dock, so a docked chat's subagents
    /// open beside it.
    ColumnAfterDock,
}

pub fn move_to_split(facts: &MoveToSplitFacts) -> MoveToSplit {
    let edge = edge_of_argument(facts.direction.as_deref());
    if facts.group {
        return if facts.chat_dock { MoveToSplit::Refuse } else { MoveToSplit::Split { edge } };
    }
    if edge == Edge::Right
        && facts.tabs_in_pane > 1
        && facts.chat_dock
        && facts.chat
        && facts.dock_column
    {
        return MoveToSplit::ColumnAfterDock;
    }
    // Every other split of the dock, a lone docked chat's too (the dock would close).
    if facts.chat_dock {
        return MoveToSplit::Refuse;
    }
    MoveToSplit::Split { edge }
}

/// The collapsed state a collapse, expand or toggle (`value` None) sets on a
/// group now `current`; None when it would change nothing.
pub fn group_collapse(value: Option<bool>, current: bool) -> Option<bool> {
    let collapsed = value.unwrap_or(!current);
    (collapsed != current).then_some(collapsed)
}

// MARK: Restart, icons, identifiers

/// A tab's kind as Restart reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RestartFacts {
    /// A daemon terminal tab.
    pub pty: bool,
    /// Its shell ended.
    pub dead: bool,
    /// Its host link failed.
    pub failed: bool,
}

/// Why a tab cannot restart.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RestartRefusal {
    NotATerminal,
    TabNotDead,
}

/// `tab.restart`: a daemon terminal tab whose shell ended, or whose host link
/// failed, restarts; None when it can.
pub fn restart_refusal(tab: RestartFacts) -> Option<RestartRefusal> {
    if !tab.pty {
        return Some(RestartRefusal::NotATerminal);
    }
    if !(tab.dead || tab.failed) {
        return Some(RestartRefusal::TabNotDead);
    }
    None
}

/// The undo an icon change offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum IconUndo {
    /// "Icon Set".
    Set,
    /// "Icon Removed".
    Remove,
}

/// The undo step of a change from `previous` to `icon` (None removes it): a
/// person's change that changed something offers its inverse; automation
/// offers none (RECOVERABLE-BY-DEFAULT).
pub fn icon_undo(user: bool, previous: Option<&str>, icon: Option<&str>) -> Option<IconUndo> {
    if !user || previous == icon {
        return None;
    }
    Some(if icon.is_none() { IconUndo::Remove } else { IconUndo::Set })
}

/// Copy Workspace ID (and with `refs`, the `--target` form first): one block
/// per workspace public id, a blank line between them (classic's
/// `WorkspaceSurfaceIdentifierClipboardText`).
pub fn workspace_id_text(workspaces: &[String], refs: bool) -> String {
    workspaces
        .iter()
        .map(|id| {
            if refs {
                format!("workspace_ref=workspace:{id}\nworkspace_id={id}")
            } else {
                format!("workspace_id={id}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Copy IDs on a tab: its workspace (when known), pane and tab ids.
pub fn identifiers_text(workspace: Option<&str>, pane: &str, surface: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    if let Some(workspace) = workspace {
        lines.push(format!("workspace_id={workspace}"));
    }
    lines.push(format!("pane_id={pane}"));
    lines.push(format!("surface_id={surface}"));
    lines.join("\n")
}

#[cfg(test)]
#[path = "tabs_tests.rs"]
mod tests;
