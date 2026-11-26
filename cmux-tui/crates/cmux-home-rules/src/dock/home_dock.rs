//! `HomeDock` (CmuxNextHomeEngine/HomeDock.swift, HomeDock+KeptTabs.swift): Home's page tab in a
//! pinned left chat dock. The app sends the tree (after its own waits for the daemon's events) and
//! does the requests; these rules decide what is where and what each connect sends.

use super::tree::{AGENT_CHAT, Column, LEFT, Pane, Screen, Tab, Workspace};
use serde::{Deserialize, Serialize};

/// The page tab the dock holds: the Messages and Channels views of Home (`WorkspaceModel.homeDockPage`).
pub const PAGE: &str = "home-dock";
/// The page tab the dock held before the two views (hq-ec's `home-channels` page alone).
pub const LEGACY_PAGE: &str = "home-channels";

/// Where Home's page tab is: the tab, its pane and its screen.
#[derive(Debug, Clone, Copy)]
pub struct Placed<'a> {
    pub tab: &'a Tab,
    pub pane: &'a Pane,
    pub screen: &'a Screen,
}

/// The page tab of `home` and where it is, if any (`HomeDock.pageTab(in:)`).
pub fn page_tab(home: &Workspace) -> Option<Placed<'_>> {
    for screen in &home.screens {
        for pane in &screen.panes {
            if let Some(tab) = pane.tabs.iter().find(|tab| tab.page.as_deref() == Some(PAGE)) {
                return Some(Placed { tab, pane, screen });
            }
        }
    }
    None
}

/// The left chat dock column holding `pane` on `screen`, if any (`HomeDock.dockColumn`).
pub fn dock_column<'a>(pane: &Pane, screen: &'a Screen) -> Option<&'a Column> {
    screen.columns.iter().find(|column| {
        column.dock.as_ref().is_some_and(|dock| dock.edge == LEFT && dock.role == AGENT_CHAT)
            && column.pane_ids.contains(&pane.handle)
    })
}

/// Whether `pane` is in a left dock column with the agent chat role on `screen`.
pub fn is_docked(pane: &Pane, screen: &Screen) -> bool {
    dock_column(pane, screen).is_some()
}

/// Home's page tab is in its dock, where it stays.
pub fn page_is_docked(home: &Workspace) -> bool {
    page_tab(home).is_some_and(|placed| is_docked(placed.pane, placed.screen))
}

/// A Chief conversation tab: a conversation tab whose source is a conversation (not a page or an
/// agent session). In the home workspace only Home makes them (`new-conversation-tab`).
pub fn is_chief_tab(tab: &Tab) -> bool {
    tab.kind == "conversation"
        && tab.page.is_none()
        && !tab.has_agent_session
        && tab.conversation.is_some()
}

/// The old dock's `home-channels` page tab: only one in the left chat dock, so a Channels tab the
/// person opened on the right stays.
pub fn is_legacy_dock_tab(tab: &Tab, pane: &Pane, screen: &Screen) -> bool {
    tab.page.as_deref() == Some(LEGACY_PAGE) && is_docked(pane, screen)
}

/// Whether tab `id` of the home `workspace` is Home's own and stays in it: Home's page or a Chief
/// tab wherever it is, or any tab of a home without a pinned column (classic Home)
/// (`HomeDock.keepsTab(_:in:)`).
pub fn keeps_tab(id: &str, workspace: &Workspace) -> bool {
    let mut pinned = false;
    for screen in &workspace.screens {
        let own = screen.panes.iter().any(|pane| {
            pane.tabs
                .iter()
                .any(|tab| tab.id == id && (tab.page.as_deref() == Some(PAGE) || is_chief_tab(tab)))
        });
        if own {
            return true;
        }
        pinned = pinned
            || screen
                .columns
                .iter()
                .any(|column| column.dock.as_ref().is_some_and(|dock| dock.is_pinned));
    }
    !pinned
}

/// A shell nobody used: a live local terminal at a prompt in the home folder, unnamed, with no
/// agent, program status, running command, unread mark or keep-layout record, titled by its folder
/// (`HomeDock.isPlaceholderShell`).
pub fn is_placeholder_shell(tab: &Tab, home: &str) -> bool {
    if tab.kind != "pty"
        || tab.dead
        || tab.name.is_some()
        || tab.has_agent
        || tab.has_agent_session
        || tab.command_running
        || tab.has_program_status
        || tab.has_relaunch
        || tab.is_remote
        || tab.shows_unread
        || tab.pinned
        || tab.in_tab_group
    {
        return false;
    }
    let folder = home.strip_suffix('/').unwrap_or(home);
    // A shell whose folder is unknown is not known to be the placeholder.
    let at_home = tab
        .cwd
        .as_deref()
        .is_some_and(|cwd| cwd == folder || cwd.strip_suffix('/') == Some(folder));
    let title = tab.title.trim_matches(is_horizontal_space);
    at_home && (title.is_empty() || title == "~" || title == folder)
}

/// Foundation's `CharacterSet.whitespaces`: spaces (Unicode Zs) and the tab, not line breaks.
fn is_horizontal_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(c, '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The one tab right of the Home dock on `screen` when it is a placeholder shell, else none
/// (`HomeDock.placeholderShell(on:home:)`).
pub fn placeholder_shell<'a>(screen: &'a Screen, home: &str) -> Option<&'a Tab> {
    if !screen.columns.iter().any(|column| column.dock.as_ref().is_some_and(|dock| dock.is_pinned))
    {
        return None;
    }
    let dock_panes: Vec<u64> = screen
        .columns
        .iter()
        .filter(|column| column.dock.is_some())
        .flat_map(|column| column.pane_ids.iter().copied())
        .collect();
    let mut right = screen
        .panes
        .iter()
        .filter(|pane| !dock_panes.contains(&pane.handle))
        .flat_map(|pane| pane.tabs.iter());
    let tab = right.next()?;
    if right.next().is_some() || !is_placeholder_shell(tab, home) {
        return None;
    }
    Some(tab)
}

/// The daemon capabilities the plans read.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Capabilities {
    /// `pinned-dock-v1`.
    pub pinned_dock: bool,
    /// `pinned-dock-alone-v1`.
    pub pinned_dock_alone: bool,
}

/// What one connect does once the tree shows the page tab (`ensureDock`, after its waits).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "step", rename_all = "camelCase")]
pub enum EnsurePlan {
    /// The home workspace is gone: "home workspace gone".
    Gone,
    /// No page tab: one keyed `new-conversation-tab` for the page, then the tree again.
    CreatePage,
    /// The page tab is shown.
    #[serde(rename_all = "camelCase")]
    Place {
        /// The Chief and legacy dock tabs to close (`endTerminals: false`) first; empty: none.
        close_tabs: Vec<u64>,
        /// The page is in its dock already: pin, allow tabs and (when `alone`) the placeholder check.
        docked: bool,
        /// The daemon keeps a lone pinned dock (`pinned-dock-alone-v1`).
        alone: bool,
        /// Not docked: the move leaves a terminal in the pane it leaves (an older daemon's screen
        /// would undock with nothing else in it).
        respawn_terminal: bool,
        /// The page's surface and pane (the move's tab and anchor).
        surface: u64,
        pane: u64,
    },
}

/// One connect's plan for `home` (none: the workspace is gone).
pub fn ensure_plan(home: Option<&Workspace>, caps: Capabilities) -> EnsurePlan {
    let Some(home) = home else { return EnsurePlan::Gone };
    let Some(placed) = page_tab(home) else { return EnsurePlan::CreatePage };
    let mut chiefs: Vec<u64> = Vec::new();
    for screen in &home.screens {
        for pane in &screen.panes {
            for tab in &pane.tabs {
                if (is_chief_tab(tab) || is_legacy_dock_tab(tab, pane, screen))
                    && !chiefs.contains(&tab.surface)
                {
                    chiefs.push(tab.surface);
                }
            }
        }
    }
    let docked = is_docked(placed.pane, placed.screen);
    let alone = caps.pinned_dock && caps.pinned_dock_alone;
    // What stays on the dock's screen once the page and the Chief tabs leave it.
    let stays = placed
        .screen
        .panes
        .iter()
        .flat_map(|pane| pane.tabs.iter())
        .any(|tab| tab.surface != placed.tab.surface && !chiefs.contains(&tab.surface));
    let close_tabs = if !chiefs.is_empty() && (stays || !docked) { chiefs } else { Vec::new() };
    EnsurePlan::Place {
        close_tabs,
        docked,
        alone,
        respawn_terminal: !(stays || alone),
        surface: placed.tab.surface,
        pane: placed.pane.handle,
    }
}

/// The pin step (`pinned-dock-v1`): the page goes first in its column, then the column is pinned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PinPlan {
    /// `moveTab(surface, to: pane, index: 0)` first: the pinned tab is the column's first tab.
    pub move_first: bool,
    pub surface: u64,
    pub pane: u64,
    /// The dock to send in `SetColumnDockRequest` with `pinned: true`.
    pub edge: String,
    pub role: String,
}

/// The pin step for `home`; none when there is nothing to do (pinned already, an older daemon, the dock not shown).
pub fn pin_plan(home: Option<&Workspace>, caps: Capabilities) -> Option<PinPlan> {
    if !caps.pinned_dock {
        return None;
    }
    let placed = page_tab(home?)?;
    let dock = dock_column(placed.pane, placed.screen)?.dock.as_ref()?;
    if dock.is_pinned {
        return None;
    }
    Some(PinPlan {
        move_first: placed.pane.tabs.first().map(|tab| tab.surface) != Some(placed.tab.surface),
        surface: placed.tab.surface,
        pane: placed.pane.handle,
        edge: dock.edge.clone(),
        role: dock.role.clone(),
    })
}

/// The allow-tabs step (Leo 2026-10-21: "JUST MAKE THE TAB THING SHOW UP ON THE MAIN PANE TOO").
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum AllowTabsPlan {
    /// Nothing to do: the step is nil.
    None,
    /// The pinned dock takes tabs already: set `dockTakesTabsKey`, step nil.
    Record,
    /// The ids are not in the tree yet: wait for them (`allowTabsWhenIdentified`), step
    /// "home dock allow_tabs waits for resource ids".
    WaitForIds,
    /// Send `column.update {allow_tabs: true}` for this screen and pane, then set
    /// `dockTakesTabsKey`: step "home dock takes tabs".
    Allow { screen: String, pane: String },
}

/// The allow-tabs step for `home`. `fresh`: a dock made or pinned now; `dock_takes_tabs`: the
/// install's `dockTakesTabsKey`.
pub fn allow_tabs_plan(
    home: Option<&Workspace>,
    caps: Capabilities,
    fresh: bool,
    dock_takes_tabs: bool,
) -> AllowTabsPlan {
    if !caps.pinned_dock || !(fresh || !dock_takes_tabs) {
        return AllowTabsPlan::None;
    }
    let Some(placed) = home.and_then(page_tab) else { return AllowTabsPlan::None };
    let Some(dock) =
        dock_column(placed.pane, placed.screen).and_then(|column| column.dock.as_ref())
    else {
        return AllowTabsPlan::None;
    };
    // A dock just pinned may not show its pin in the tree yet; the daemon has it (the pin replied).
    if dock.allows_tabs && dock.is_pinned {
        return AllowTabsPlan::Record;
    }
    match (&placed.screen.resource_id, &placed.pane.resource_id) {
        (Some(screen), Some(pane)) => {
            AllowTabsPlan::Allow { screen: screen.clone(), pane: pane.clone() }
        }
        _ => AllowTabsPlan::WaitForIds,
    }
}

/// What the allow-tabs wait reads on each tree change: `Some(false)`, the page is gone (the wait
/// ends); `Some(true)`, the screen and pane have their ids (the step runs); `None`, keep waiting.
pub fn ids_ready(home: Option<&Workspace>) -> Option<bool> {
    let Some(placed) = home.and_then(page_tab) else { return Some(false) };
    (placed.screen.resource_id.is_some() && placed.pane.resource_id.is_some()).then_some(true)
}

/// The one-time placeholder check (`closePlaceholder`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaceholderPlan {
    /// Set `placeholderChecked` and `placeholderCheckedKey` (the check ran).
    pub mark_checked: bool,
    /// The shell to close (`endTerminals: true`): step "home placeholder shell closed".
    pub close: Option<u64>,
}

/// The placeholder check for `home`: `checked` is this launch's flag, `checked_ever` the install's key.
pub fn placeholder_plan(
    home: Option<&Workspace>,
    checked: bool,
    checked_ever: bool,
    home_dir: &str,
) -> PlaceholderPlan {
    let nothing = PlaceholderPlan { mark_checked: false, close: None };
    if checked || checked_ever {
        return nothing;
    }
    let Some(placed) = home.and_then(page_tab) else { return nothing };
    PlaceholderPlan {
        mark_checked: true,
        close: placeholder_shell(placed.screen, home_dir).map(|tab| tab.surface),
    }
}

/// Whether Home shows from its saved state now (`revealWhenDocked`): a `home` workspace, not
/// classic, not yet ready, its page docked.
pub fn reveal_when_docked(home: &Workspace, classic: bool, ready: bool) -> bool {
    home.kind.as_deref() == Some("home") && !classic && !ready && page_is_docked(home)
}

/// Whether a web link in the Home page opens (`openLink`): http and https only.
pub fn opens_link(scheme: Option<&str>) -> bool {
    scheme.is_some_and(|scheme| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}
