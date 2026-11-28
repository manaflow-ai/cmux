//! `newTab`'s decisions (`AppActions.newWorkspace`, `NewWorkspaceFocus`): who asked, whether the
//! workspace shows, where it starts, which window lists it, and where the person's keys go while it
//! is made. The window lookups, the Cloud route and the create itself stay in Swift.

use crate::spawn::{AgentTabFacts, Spawn, USER_ORIGIN};
use serde::{Deserialize, Serialize};

/// The refusal text of a `machine` with no connection (`WorkspaceVerbStrings.machineNotConnected`).
pub const MACHINE_NOT_CONNECTED: &str = "the machine is not connected";

/// `newTab`'s `focus` and `activate` arguments (`NewWorkspaceFocus`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewWorkspaceFocus {
    /// Selected in the active window; false: the most recent window lists it unshown.
    pub shows: bool,
    /// Its window becomes key and the app activates.
    pub activates_app: bool,
}

impl NewWorkspaceFocus {
    /// The keyboard, menu and palette pass neither and show it in the key window; only
    /// `activate: true` with focus takes the Mac's focus.
    pub fn new(focus: Option<bool>, activate: Option<bool>) -> NewWorkspaceFocus {
        let shows = focus.unwrap_or(true);
        NewWorkspaceFocus { shows, activates_app: shows && activate == Some(true) }
    }
}

/// What `newTab` reads of the invocation and the app.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewWorkspaceFacts {
    /// The invocation's origin.
    pub origin: Option<String>,
    /// The current run scope's origin (a script's nested run is not the person's).
    pub run_origin: Option<String>,
    /// `focus`.
    pub focus: Option<bool>,
    /// `activate`.
    pub activate: Option<bool>,
    /// The invocation names a `machine`.
    pub has_machine: bool,
    /// That machine's daemon has a connection.
    pub machine_connected: bool,
    /// `window-inherit-working-directory` is on (`NewTerminalStart.inherits(.window)`).
    pub inherits_window_cwd: bool,
    /// The source window's focused pane is on the app's own daemon.
    pub focused_on_home: bool,
    /// Some window is open.
    pub has_open_window: bool,
    /// The source window's id (the invocation's window target, else the active window).
    pub source_window: Option<String>,
    /// The window the app picked (`targetWindow`), when it picked one.
    pub target_window: Option<String>,
    /// The agent tab facts of the daemon it is born on.
    pub tabs: AgentTabFacts,
}

/// `newTab`'s decisions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewWorkspaceDecision {
    /// The person's own run.
    pub by_person: bool,
    /// The spawn opens the New Tab page (only the person's own run does).
    pub opens_new_tab_page: bool,
    /// Show and activate.
    pub focus: NewWorkspaceFocus,
    /// It starts in the folder of the focused terminal or chat.
    pub inherits_cwd: bool,
    /// The app picks a target window (shown, or no window open).
    pub picks_target: bool,
    /// Refused before anything: the named machine has no connection.
    pub refusal: Option<String>,
    /// The New Tab page opens: the person's keys wait for its field.
    pub opens_page: bool,
    /// The keys from now wait for the page's field (it opens in the window they type in).
    pub holds_page_keys: bool,
    /// The keys from now go to its first terminal, in the source window.
    pub holds_terminal_keys: bool,
    /// Automation's shown create: made and listed unshown, shown once made unless a text input
    /// has the keyboard.
    pub quiet: bool,
}

/// Whether the target window should be picked: shown, or no window open (a workspace never lives
/// in no window).
pub fn picks_target(shows: bool, has_open_window: bool) -> bool {
    shows || !has_open_window
}

/// `newTab`'s decisions for `spawn` (from the invocation) and `facts`.
pub fn decide(spawn: &Spawn, facts: &NewWorkspaceFacts) -> NewWorkspaceDecision {
    let by_person = facts.run_origin.as_deref().or(facts.origin.as_deref()) == Some(USER_ORIGIN);
    let mut spawn = spawn.clone();
    if !by_person {
        spawn.opens_new_tab_page = false;
    }
    let focus = NewWorkspaceFocus::new(facts.focus, facts.activate);
    let show = focus.shows;
    let inherits_cwd =
        by_person && !facts.has_machine && facts.inherits_window_cwd && facts.focused_on_home;
    let picks = picks_target(show, facts.has_open_window);
    let target = if picks { facts.target_window.as_deref() } else { None };
    let refused = facts.has_machine && !facts.machine_connected;
    let refusal = refused.then(|| MACHINE_NOT_CONNECTED.to_owned());
    // As Swift compares optionals: no target and no source window are the same window.
    let in_source = target == facts.source_window.as_deref();
    let opens_page = !refused
        && show
        && facts.has_open_window
        && spawn.opens_new_tab_page
        && spawn.command.is_none()
        && !spawn.has_first_chat
        && spawn.first_session.is_none()
        && facts.tabs.opens_first_page(false);
    let holds_page_keys = opens_page && in_source;
    let holds_terminal_keys = !refused
        && by_person
        && show
        && facts.has_open_window
        && in_source
        && !spawn.opens_page(&facts.tabs);
    let quiet = !refused && !by_person && show && facts.has_open_window;
    NewWorkspaceDecision {
        by_person,
        opens_new_tab_page: spawn.opens_new_tab_page,
        focus,
        inherits_cwd,
        picks_target: picks,
        refusal,
        opens_page,
        holds_page_keys,
        holds_terminal_keys,
        quiet,
    }
}
