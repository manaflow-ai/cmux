//! One create's plan from the press (`WorkspaceSpawner.start`, `shown`, `create`): the key, the
//! reserved workspace a plain Cmd-N shows, the row's name, whether the store shows the workspace in
//! this turn, and the route of the create's requests. The window, lane and store work stays in Swift.

use crate::naming::{ListedWorkspace, next_workspace_name};
use crate::request::{CreatePlan, create_plan};
use crate::spawn::{AgentTabFacts, Spawn, TerminalStart, TerminalStartFacts};
use serde::{Deserialize, Serialize};

/// What a press does with the daemon's reserved workspace (`ReservedWorkspaceUse`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ReservedUse {
    /// It takes the reservation's key.
    Hit {
        /// That key.
        key: String,
    },
    /// No reservation on the press's daemon; `elsewhere`: the home daemon holds one.
    Miss {
        /// The press went to another daemon than the one holding a reservation.
        elsewhere: bool,
    },
    /// Not a plain Cmd-N: it never takes a reservation.
    NotPlain,
}

impl ReservedUse {
    /// The key it takes.
    pub fn key(&self) -> Option<&str> {
        match self {
            ReservedUse::Hit { key } => Some(key),
            _ => None,
        }
    }

    /// Its bench span.
    pub fn span(&self) -> Option<&'static str> {
        match self {
            ReservedUse::Hit { .. } => Some("cmdN.reserved.hit"),
            ReservedUse::Miss { elsewhere: true } => Some("cmdN.reserved.miss.daemon"),
            ReservedUse::Miss { elsewhere: false } => Some("cmdN.reserved.miss.none"),
            ReservedUse::NotPlain => None,
        }
    }
}

/// The span of a reservation let go because a press took its key but did not show it.
pub const RELEASED_UNSHOWN_SPAN: &str = "cmdN.reserved.released.unshown";

/// What the press's daemon store holds (`DaemonStore.reservedWorkspaceUse(plain:home:)`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Reservation {
    /// The press's daemon's reserved key.
    pub reserved: Option<String>,
    /// The home daemon is another daemon than the press's.
    pub home_is_other: bool,
    /// The home daemon holds a reservation.
    pub home_reserved: bool,
}

/// The use of a press: only a plain press takes a reservation; with none, a miss says whether the
/// home daemon (another one) holds one.
pub fn reserved_use(plain: bool, reservation: &Reservation) -> ReservedUse {
    if !plain {
        return ReservedUse::NotPlain;
    }
    match &reservation.reserved {
        Some(key) => ReservedUse::Hit { key: key.clone() },
        None => {
            ReservedUse::Miss { elsewhere: reservation.home_is_other && reservation.home_reserved }
        }
    }
}

/// Where the create's key comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeySource {
    /// Its caller fixed it.
    Spawn,
    /// The daemon's reservation.
    Reserved,
    /// A new key.
    Generate,
}

/// What `start` reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StartFacts {
    /// The create goes into a window (it shows a row).
    pub in_window: bool,
    /// The daemon has a connection.
    pub connected: bool,
    /// The daemon is this Mac's.
    pub local: bool,
    /// The agent tab facts of the daemon.
    pub tabs: AgentTabFacts,
    /// The daemon's reservation.
    pub reservation: Reservation,
    /// The daemon's listed workspaces, for the next default name.
    pub workspaces: Vec<ListedWorkspace>,
    /// The names pending rows hold on the machine.
    pub reserved_names: Vec<String>,
    /// The spawn's first browser shows in this turn (`showFirstBrowser` made a stand-in).
    pub browser_shows: bool,
}

/// The plan of `start`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartPlan {
    /// The reservation's use; nil with no connection.
    pub reserved_use: Option<ReservedUse>,
    /// Where the key comes from.
    pub key_source: KeySource,
    /// The key, when it is not a new one.
    pub key: Option<String>,
    /// The window claims the workspace at the press.
    pub claims_window: bool,
    /// No connection: the create fails `notConnected` (after the claim).
    pub not_connected: bool,
    /// The name the create sends and its row shows; nil: the daemon's own numbering.
    pub name: Option<String>,
    /// The window shows a pending row from the press.
    pub pending_row: bool,
    /// The pending row shows the New Tab page (or a first chat).
    pub row_opens_page: bool,
    /// The store shows the workspace in this turn (`shown`), when its stand-in is made.
    pub tries_shown: bool,
    /// The reservation is let go (`unshown`) when the workspace is not shown in this turn.
    pub releases_reserved_unshown: bool,
}

/// The plan of `start` for `spawn`: a plain Cmd-N into a window on a daemon that shows its
/// workspace at once takes the reservation; the key is the caller's, else the reservation's, else
/// new; only a create with a row names itself from the press.
pub fn start_plan(spawn: &Spawn, facts: &StartFacts) -> StartPlan {
    let plain =
        facts.in_window && spawn.is_plain_new_tab_page() && facts.tabs.shows_workspace_at_once();
    let taken = facts.connected.then(|| reserved_use(plain, &facts.reservation));
    let reserved_key = taken.as_ref().and_then(ReservedUse::key).map(str::to_owned);
    let (key_source, key) = match (&spawn.key, &reserved_key) {
        (Some(key), _) => (KeySource::Spawn, Some(key.clone())),
        (None, Some(key)) => (KeySource::Reserved, Some(key.clone())),
        (None, None) => (KeySource::Generate, None),
    };
    let unconnected = StartPlan {
        reserved_use: taken,
        key_source,
        key,
        claims_window: facts.in_window,
        not_connected: true,
        name: None,
        pending_row: false,
        row_opens_page: false,
        tries_shown: false,
        releases_reserved_unshown: false,
    };
    if !facts.connected {
        return unconnected;
    }
    let name = spawn.row_name(facts.in_window, || {
        next_workspace_name(&facts.workspaces, &facts.reserved_names)
    });
    let pending_row = facts.in_window && name.is_some();
    let row_opens_page = pending_row && spawn.opens_page(&facts.tabs);
    let tries_shown =
        pending_row && shows_in_turn(spawn, facts.local, &facts.tabs, facts.browser_shows);
    StartPlan {
        not_connected: false,
        name,
        pending_row,
        row_opens_page,
        tries_shown,
        releases_reserved_unshown: reserved_key.is_some(),
        ..unconnected
    }
}

/// Whether `shown` makes a stand-in: a first browser that shows, or a spawn the store can show
/// before the daemon on a daemon that shows its workspace at once.
pub fn shows_in_turn(
    spawn: &Spawn,
    local: bool,
    tabs: &AgentTabFacts,
    browser_shows: bool,
) -> bool {
    browser_shows || (spawn.shows_before_daemon(local) && tabs.shows_workspace_at_once())
}

/// What `create` reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CreateFacts {
    /// The daemon has a connection.
    pub connected: bool,
    /// The agent tab facts of the daemon.
    pub tabs: AgentTabFacts,
    /// The daemon serves `workspace-first-tab-v1`.
    pub workspace_first_tab: bool,
    /// The daemon serves `create-terminal-workspace-v1`.
    pub makes_workspace_with_terminal: bool,
    /// The first terminal's start facts.
    pub start: TerminalStartFacts,
}

/// The route of `create`'s requests.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum CreateRoute {
    /// No connection: `notConnected`.
    NotConnected,
    /// The New Tab page (`newTabPage`): the workspace and its first tab.
    NewTabPage {
        /// Its first tab is the session's chat.
        session_tab: bool,
        /// The press's key hold goes to the page's field (`firstPageTokens`).
        stores_page_token: bool,
    },
    /// A browser workspace: one request, its only tab the browser.
    BrowserOneRequest,
    /// A terminal workspace (`WorkspaceCreation.create`), the first terminal keyed and waited for.
    Terminal {
        /// One request or two.
        plan: CreatePlan,
    },
}

/// The plan of `create`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateRoutePlan {
    /// The route.
    pub route: CreateRoute,
    /// The app sets the workspace's default browser profile first.
    pub sets_browser_profile: bool,
    /// The first terminal's start (its folder is the page's too); nil with no connection.
    pub start: Option<TerminalStart>,
}

/// The route of `create` for `spawn`: after the room's pin and the browser profile, the New Tab
/// page when it opens one, else a browser workspace in one request when the daemon makes a
/// workspace with its first tab, else a terminal workspace.
pub fn create_route(spawn: &Spawn, facts: &CreateFacts) -> CreateRoutePlan {
    if !facts.connected {
        return CreateRoutePlan {
            route: CreateRoute::NotConnected,
            sets_browser_profile: false,
            start: None,
        };
    }
    let start = spawn.terminal_start(&facts.start);
    let route = if spawn.opens_page(&facts.tabs) {
        let session_tab = spawn.first_session.is_some();
        CreateRoute::NewTabPage {
            session_tab,
            stores_page_token: !session_tab && spawn.input_token.is_some() && !spawn.has_first_chat,
        }
    } else if spawn.has_first_browser && facts.workspace_first_tab {
        CreateRoute::BrowserOneRequest
    } else {
        CreateRoute::Terminal { plan: create_plan(true, facts.makes_workspace_with_terminal) }
    };
    CreateRoutePlan {
        route,
        sets_browser_profile: spawn.browser_profile.is_some(),
        start: Some(start),
    }
}
