//! The decision rules of the macOS app's `SidebarBridge`, the main-actor
//! class that feeds one window's sidebar from the daemon stores and turns its
//! intents into daemon commands. The bridge keeps the plumbing (observation,
//! tasks, daemon calls, localized words); these are the choices it makes on
//! the way, over `cmux_layout_reducer_json` op `sidebar_bridge`, one rule per
//! call tagged by `rule`.
//!
//! Every rule runs once per intent, click, structural sidebar pass or machine
//! header, never per frame, hover or row status tick. Workspaces and daemons
//! travel as indexes or opaque numbers the caller chose; a reply names them
//! back by the same index.

use serde::{Deserialize, Serialize};

mod link;
pub use link::{Joined, PeerLink, Shown, joined_link, peer_link, status_link, status_links};

#[cfg(test)]
mod tests;

// MARK: Pins on a drop (SidebarBridge+Intents)

/// The section a reorder drops into.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DropSection {
    /// The Pinned section (the daemon's pin).
    Pinned,
    /// A custom section; it lists only on the sidebar document.
    Custom,
    /// A machine's section; `daemon` is its daemon (none when the app has no daemon for it).
    Machine {
        #[serde(default)]
        daemon: Option<u64>,
    },
}

/// One dropped workspace as its owning store has it: pinned or not, and its
/// daemon (none for a workspace no store holds).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Dropped {
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub daemon: Option<u64>,
}

/// What a reorder does with the daemon's pin before (or instead of) its move.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReorderPins {
    /// A drop on Pinned (or a custom section) of workspaces that all are pinned: they snap back.
    SnapBack,
    /// A drop on Pinned (or a custom section): these (the unpinned ones) get the pin; nothing else moves.
    Pin { workspaces: Vec<usize> },
    /// A drop on a machine's section: these (pinned, of that machine) lose the pin, then the move goes on.
    Reorder { unpin: Vec<usize> },
}

/// The pin side of a reorder of `workspaces` into `section`. Pinned order
/// follows the sidebar, so a drop of workspaces that all are pinned already
/// only snaps back; a pinned workspace dropped on its own machine unpins.
pub fn reorder_pins(section: DropSection, workspaces: &[Dropped]) -> ReorderPins {
    match section {
        DropSection::Pinned | DropSection::Custom => {
            let unpinned: Vec<usize> = indexes(workspaces, |w| !w.pinned);
            if unpinned.is_empty() {
                ReorderPins::SnapBack
            } else {
                ReorderPins::Pin { workspaces: unpinned }
            }
        }
        DropSection::Machine { daemon } => ReorderPins::Reorder {
            unpin: indexes(workspaces, |w| w.pinned && daemon.is_some() && w.daemon == daemon),
        },
    }
}

/// The pin commands for workspaces whose owning daemons do (`true`) or do
/// not (`false`) serve `workspace-pin-v1`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinCommands {
    /// The owners that get `set-workspace-metadata`, in order.
    pub send: Vec<usize>,
    /// Some owner cannot take the pin: the person is told it needs the capability.
    pub refused: bool,
    /// Nothing is sent: the pending edit settles and the rows show their owners' state again.
    pub snap_back: bool,
}

pub fn pin_commands(supports: &[bool]) -> PinCommands {
    let send: Vec<usize> = indexes(supports, |supported| *supported);
    PinCommands { refused: send.len() < supports.len(), snap_back: send.is_empty(), send }
}

/// The one daemon owning every workspace (`owners`, without the unknown
/// ones), or none when they span machines or none is known.
pub fn same_daemon(owners: &[Option<u64>]) -> Option<u64> {
    let mut known = owners.iter().flatten();
    let first = *known.next()?;
    known.all(|daemon| *daemon == first).then_some(first)
}

// MARK: New workspace (SidebarBridge+Intents)

/// Which daemon a sidebar New Workspace makes its workspace on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NewWorkspaceDaemon {
    /// The machine the intent named.
    Machine,
    /// The window's own machine.
    Window,
    /// None: the app's default (this Mac).
    Default,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NewWorkspace {
    /// The plain "+" in a local window: the person's New Workspace, as Cmd-N.
    NewTab,
    /// A machine turned off by policy: nothing, never a local stand-in.
    Nothing,
    /// A new workspace on `on`, in the intent's group when it names one.
    Create { on: NewWorkspaceDaemon },
}

/// A sidebar New Workspace (`newWorkspace(machine, group)`). `machine`:
/// whether the intent names a machine, and if so whether the app has its
/// daemon; `window_daemon`: whether the window's machine has a daemon.
pub fn new_workspace(
    machine: Option<bool>,
    group: bool,
    local_window: bool,
    window_daemon: bool,
) -> NewWorkspace {
    if machine.is_none() && !group && local_window {
        return NewWorkspace::NewTab;
    }
    let on = if machine == Some(true) {
        NewWorkspaceDaemon::Machine
    } else if window_daemon {
        NewWorkspaceDaemon::Window
    } else {
        NewWorkspaceDaemon::Default
    };
    if on == NewWorkspaceDaemon::Default && (machine.is_some() || !local_window) {
        return NewWorkspace::Nothing;
    }
    NewWorkspace::Create { on }
}

// MARK: New groups (SidebarGroupFlow)

/// What New Group does with a person's or an action's request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewGroup {
    /// The workspaces already are one whole group: its name editor opens, and no second group is made.
    pub edit_whole: bool,
    /// After the create, the new group's name editor opens once the sidebar shows it.
    pub edit_new: bool,
}

/// New Group never stacks a second group on workspaces that already are one
/// whole group when a person asks without a name (`whole`: they are, in
/// personal organization); automation, and a person who names the group,
/// get the group they asked for. A person's unnamed new group opens its editor.
pub fn new_group(by_user: bool, unnamed: bool, personal: bool, whole: bool) -> NewGroup {
    let asks_editor = by_user && unnamed;
    let edit_whole = asks_editor && personal && whole;
    NewGroup { edit_whole, edit_new: asks_editor && !edit_whole }
}

/// The index a personal group is created at: the sidebar's own place for it
/// (`placed`, where the model formed it) wins, else the caller's `requested`
/// index, where `i64::MAX` (`Int.max`) means last, the daemon's default.
pub fn group_create_index(placed: Option<i64>, requested: Option<i64>) -> Option<i64> {
    placed.or(requested.filter(|index| *index != i64::MAX))
}

/// The group editor's "More Actions" row: the group's full menu.
pub const MORE_ACTIONS_ITEM: &str = "sidebar.group.moreActions";
/// The group editor's "Keep Group" row: keeps a group made empty.
pub const KEEP_GROUP_ITEM: &str = "sidebar.group.keep";

/// Editor rows after which a group made empty stays when the editor closes:
/// it is about to get a member, the emoji picker or color panel edits it
/// after the editor closes, or the row ends the group itself.
const KEEPS_GROUP: [&str; 7] = [
    "workspaceGroup.newWorkspace",
    MORE_ACTIONS_ITEM,
    KEEP_GROUP_ITEM,
    "workspaceGroup.setIcon",
    "workspaceGroup.delete",
    "workspaceGroup.ungroup",
    "workspaceGroup.closeWorkspaces",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorItem {
    /// A group made empty no longer goes when its editor closes.
    pub keeps_group: bool,
    /// The row runs its action (with the group as target); More Actions and Keep Group run none.
    pub performs: bool,
}

pub fn editor_item(item: &str) -> EditorItem {
    EditorItem {
        keeps_group: KEEPS_GROUP.contains(&item),
        performs: item != MORE_ACTIONS_ITEM && item != KEEP_GROUP_ITEM,
    }
}

// MARK: Personal placement (SidebarBridge+Personal)

/// One step of a personal drop plan: whether its workspace joins the drop's
/// group (`moves`) and its personal order index.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub moves: bool,
    pub index: i64,
}

/// A step's group field in `workspace.place`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum GroupUpdate {
    Unchanged,
    Clear,
    Set { id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Place {
    pub step: usize,
    pub group: GroupUpdate,
    pub index: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Regroup {
    pub group: String,
    pub top_index: i64,
}

/// The home session's commands for a personal drop plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlacementCommands {
    /// The steps whose workspaces join (or leave for loose) the drop's group: the groups they empty may end.
    pub moving: Vec<usize>,
    /// One `workspace.place` per step, in plan order.
    pub places: Vec<Place>,
    /// The groups the plan moves to the drop's first slot (`topIndex`), after the places.
    pub regroups: Vec<Regroup>,
}

/// A moving step joins `group` (or goes loose without one); the others keep
/// theirs. The plan's `regroup` groups move to its `first` slot only on a home
/// session that serves personal state as v2 resources (`state_personal`).
pub fn placement_commands(
    steps: &[PlanStep],
    group: Option<&str>,
    state_personal: bool,
    regroup: &[String],
    first: Option<i64>,
) -> PlacementCommands {
    let moving = indexes(steps, |step| step.moves);
    let places = steps
        .iter()
        .enumerate()
        .map(|(step, plan)| Place {
            step,
            group: match (plan.moves, group) {
                (false, _) => GroupUpdate::Unchanged,
                (true, None) => GroupUpdate::Clear,
                (true, Some(id)) => GroupUpdate::Set { id: id.to_owned() },
            },
            index: plan.index,
        })
        .collect();
    let regroups = match (state_personal, first) {
        (true, Some(top_index)) => {
            regroup.iter().map(|group| Regroup { group: group.clone(), top_index }).collect()
        }
        _ => Vec::new(),
    };
    PlacementCommands { moving, places, regroups }
}

// MARK: Machine headers (SidebarBridge, Remote/SidebarBridge+SSH)

/// A sidebar machine header's status (`SidebarMachine.Status`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MachineStatus {
    Connected,
    Connecting,
    Reconnecting,
    Offline,
    UpdateAvailable,
    UpdateRequired,
    InstallRequired,
    Installing,
    AuthFailed,
    Unreachable,
    Failed,
    Disconnected,
    Paused,
    PausedIdle,
    Pausing,
    Resuming,
    Deleting,
}

impl MachineStatus {
    /// The header's detail names the daemon's compatibility.
    fn needs_update(self) -> bool {
        matches!(self, Self::UpdateRequired | Self::UpdateAvailable)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MachineKind {
    Local,
    Cloud,
    Ssh,
    Server,
}

/// A daemon store's connection state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Connection {
    Connecting,
    Connected,
    Disconnected,
    Failed,
}

/// The daemon's capability level (`DaemonCompatibility.Level`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Compatibility {
    Current,
    Limited,
    Incompatible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Header {
    pub status: MachineStatus,
    /// The header's detail is the daemon's compatibility line.
    pub compatibility_detail: bool,
}

/// A machine header from its daemon's connection: connected, else
/// connecting while the machine is live (offline when not). A remote
/// machine keeps its own cmux-tui build, so a daemon too old to connect
/// (its startup gave up) says Update Required, and a connected limited one
/// Update Available; this Mac's daemon has no such level.
pub fn machine_status(
    kind: MachineKind,
    connection: Connection,
    live: bool,
    compatibility: Option<Compatibility>,
    startup_unavailable: bool,
) -> Header {
    let mut status = match (connection, live) {
        (Connection::Connected, _) => MachineStatus::Connected,
        (_, true) => MachineStatus::Connecting,
        (_, false) => MachineStatus::Offline,
    };
    let compatibility = compatibility.filter(|_| kind != MachineKind::Local);
    if live {
        match compatibility {
            Some(Compatibility::Incompatible) if startup_unavailable => {
                status = MachineStatus::UpdateRequired;
            }
            Some(Compatibility::Limited) if status == MachineStatus::Connected => {
                status = MachineStatus::UpdateAvailable;
            }
            _ => {}
        }
    }
    Header { status, compatibility_detail: compatibility.is_some() && status.needs_update() }
}

/// An SSH machine's header: its link's status (`link`), except that a
/// connected machine whose newer cmux-tui is offered says Update Available;
/// an update status names the daemon's compatibility when one is known.
pub fn ssh_status(link: MachineStatus, update_offered: bool, compatibility: bool) -> Header {
    let status = if link == MachineStatus::Connected && update_offered {
        MachineStatus::UpdateAvailable
    } else {
        link
    };
    Header { status, compatibility_detail: compatibility && status.needs_update() }
}

/// A machine header's link as one word (`MachineLinkState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkState {
    Connected,
    Connecting,
    Offline,
    Paused,
    Attention,
}

/// What a chat that needs a machine finds its link doing (`AgentPaneMachineLink.Use`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneUse {
    Up,
    Coming,
    Down,
    Stuck,
}

/// Only a link that dropped or never came up reconnects on use
/// (`reconnects_on_use`); an SSH session waiting on its person, or a
/// machine the app does not know (`link` none), is stuck.
pub fn pane_use(waits_for_user: bool, link: Option<LinkState>, reconnects_on_use: bool) -> PaneUse {
    match link {
        _ if waits_for_user => PaneUse::Stuck,
        None => PaneUse::Stuck,
        Some(LinkState::Connected) => PaneUse::Up,
        Some(LinkState::Connecting) => PaneUse::Coming,
        Some(LinkState::Offline | LinkState::Paused | LinkState::Attention) => {
            if reconnects_on_use { PaneUse::Down } else { PaneUse::Stuck }
        }
    }
}

/// What a Cloud machine's server says when it is not simply running (`MachineServerState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ServerState {
    Paused,
    Resuming,
    Failed,
    Deleted,
}

/// A Machines section row's link as one word (`machine.list`, `MachineSectionRow`): a
/// connected link wins; a resume on its way or a link being made is connecting; a paused
/// machine is paused; a failed or deleted one, and every other down link, is offline.
pub fn row_link(connected: bool, connecting: bool, server_state: Option<ServerState>) -> LinkState {
    match server_state {
        _ if connected => LinkState::Connected,
        Some(ServerState::Resuming) => LinkState::Connecting,
        Some(ServerState::Paused) => LinkState::Paused,
        Some(ServerState::Failed | ServerState::Deleted) => LinkState::Offline,
        None if connecting => LinkState::Connecting,
        None => LinkState::Offline,
    }
}

// MARK: Bottom-left cards (SidebarBridge+Cards)

/// The update status notice (`SidebarCardFeed.updateCardID`).
pub const UPDATE_CARD: &str = "update";
/// The staged update card (`SidebarUpdateCard.cardID`).
pub const UPDATE_READY_CARD: &str = "update-ready";
pub const TEST_FEED_CARD: &str = "test-feed";
pub const USE_REAL_FEED_ACTION: &str = "use-real-feed";
pub const TIP_PREFIX: &str = "tip:";
pub const ANNOUNCEMENT_PREFIX: &str = "announcement:";

/// Where a notice button's press goes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NoticeAction {
    /// An update card's x menu (`UpdateCardCloseOption`).
    CloseUpdate,
    /// The update status's own action (`UpdateCardAction`).
    UpdateAction,
    UseRealFeed,
    /// An announcement's allow-listed Try It.
    AnnouncementTry,
    /// A tip's Try It or x menu, for tip `tip`.
    Tip {
        tip: String,
    },
    None,
}

/// A notice button: `close_option` / `card_action` say the action parses as
/// an update close option / update card action, `try_it` that it is an
/// allow-listed changelog action. The update card ids come first, then the
/// test feed, then announcements, then tips.
pub fn notice_action(
    card: &str,
    action: &str,
    close_option: bool,
    card_action: bool,
    try_it: bool,
) -> NoticeAction {
    if (card == UPDATE_CARD || card == UPDATE_READY_CARD) && close_option {
        NoticeAction::CloseUpdate
    } else if card == UPDATE_CARD && card_action {
        NoticeAction::UpdateAction
    } else if card == TEST_FEED_CARD && action == USE_REAL_FEED_ACTION {
        NoticeAction::UseRealFeed
    } else if card.starts_with(ANNOUNCEMENT_PREFIX) && try_it {
        NoticeAction::AnnouncementTry
    } else if let Some(tip) = card.strip_prefix(TIP_PREFIX) {
        NoticeAction::Tip { tip: tip.to_owned() }
    } else {
        NoticeAction::None
    }
}

/// What a notice's x does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DismissNotice {
    /// The update status hides.
    Update,
    /// The announcement never shows again.
    Announcement { id: String },
    /// The tip never shows again.
    Tip { id: String },
    /// The test-feed notice has no x; anything else is not a card of the feed.
    None,
}

pub fn dismiss_notice(card: &str) -> DismissNotice {
    if card == UPDATE_CARD {
        DismissNotice::Update
    } else if let Some(id) = card.strip_prefix(ANNOUNCEMENT_PREFIX) {
        DismissNotice::Announcement { id: id.to_owned() }
    } else if let Some(id) = card.strip_prefix(TIP_PREFIX) {
        DismissNotice::Tip { id: id.to_owned() }
    } else {
        DismissNotice::None
    }
}

// MARK: Sidebar items (SidebarBridge+Sections)

/// One action an app item's click may run, and whether it takes the app's id as `app`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppAction {
    pub action: String,
    pub app_argument: bool,
}

/// What an app item's click runs, best first: the caller runs the first one
/// its registry has, and the last always runs. `cmux.apps.open {app}` once it
/// is registered; INTERIM until then Home and the App Store keep their show
/// actions, and every other app opens its page (`app.open {app}`).
pub fn app_activation(app: &str) -> Vec<AppAction> {
    let interim = match app {
        "cmux/home" => Some("home.show"),
        "cmux/app-store" => Some("appStore.show"),
        _ => None,
    };
    let open = |action: &str| AppAction { action: action.to_owned(), app_argument: true };
    let mut actions = vec![open("cmux.apps.open")];
    actions
        .extend(interim.map(|action| AppAction { action: action.to_owned(), app_argument: false }));
    actions.push(open("app.open"));
    actions
}

// MARK: The JSON op

/// One `sidebar_bridge` call, tagged by `rule`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    ReorderPins {
        section: DropSection,
        workspaces: Vec<Dropped>,
    },
    PinCommands {
        supports: Vec<bool>,
    },
    SameDaemon {
        owners: Vec<Option<u64>>,
    },
    NewWorkspace {
        #[serde(default)]
        machine: Option<bool>,
        #[serde(default)]
        group: bool,
        local_window: bool,
        window_daemon: bool,
    },
    NewGroup {
        by_user: bool,
        unnamed: bool,
        personal: bool,
        #[serde(default)]
        whole: bool,
    },
    GroupCreateIndex {
        #[serde(default)]
        placed: Option<i64>,
        #[serde(default)]
        requested: Option<i64>,
    },
    EditorItem {
        item: String,
    },
    PlacementCommands {
        steps: Vec<PlanStep>,
        #[serde(default)]
        group: Option<String>,
        state_personal: bool,
        #[serde(default)]
        regroup: Vec<String>,
        #[serde(default)]
        first: Option<i64>,
    },
    MachineStatus {
        kind: MachineKind,
        connection: Connection,
        live: bool,
        #[serde(default)]
        compatibility: Option<Compatibility>,
        #[serde(default)]
        startup_unavailable: bool,
    },
    SshStatus {
        link: MachineStatus,
        #[serde(default)]
        update_offered: bool,
        #[serde(default)]
        compatibility: bool,
    },
    RowLink {
        connected: bool,
        #[serde(default)]
        connecting: bool,
        #[serde(default)]
        server_state: Option<ServerState>,
    },
    PaneUse {
        #[serde(default)]
        waits_for_user: bool,
        #[serde(default)]
        link: Option<LinkState>,
        #[serde(default)]
        reconnects_on_use: bool,
    },
    NoticeAction {
        card: String,
        action: String,
        #[serde(default)]
        close_option: bool,
        #[serde(default)]
        card_action: bool,
        #[serde(default)]
        try_it: bool,
    },
    DismissNotice {
        card: String,
    },
    AppActivation {
        app: String,
    },
    /// acpmux's whole link state as one dot (`link`).
    PeerLink {
        link: PeerLink,
    },
    /// Every app status's dot, keyed by its word.
    StatusLinks,
    /// A hub-joined machine's dot: its peer link when acpmux has one, else the hub's row.
    JoinedLink {
        hub: Joined,
        #[serde(default)]
        peer: Option<PeerLink>,
    },
}

/// Answers one request as JSON: the rule's reply (an index or daemon is null for none).
pub fn respond(request: &Request) -> serde_json::Result<Vec<u8>> {
    match request {
        Request::ReorderPins { section, workspaces } => {
            serde_json::to_vec(&reorder_pins(*section, workspaces))
        }
        Request::PinCommands { supports } => serde_json::to_vec(&pin_commands(supports)),
        Request::SameDaemon { owners } => serde_json::to_vec(&same_daemon(owners)),
        Request::NewWorkspace { machine, group, local_window, window_daemon } => {
            serde_json::to_vec(&new_workspace(*machine, *group, *local_window, *window_daemon))
        }
        Request::NewGroup { by_user, unnamed, personal, whole } => {
            serde_json::to_vec(&new_group(*by_user, *unnamed, *personal, *whole))
        }
        Request::GroupCreateIndex { placed, requested } => {
            serde_json::to_vec(&group_create_index(*placed, *requested))
        }
        Request::EditorItem { item } => serde_json::to_vec(&editor_item(item)),
        Request::PlacementCommands { steps, group, state_personal, regroup, first } => {
            serde_json::to_vec(&placement_commands(
                steps,
                group.as_deref(),
                *state_personal,
                regroup,
                *first,
            ))
        }
        Request::MachineStatus { kind, connection, live, compatibility, startup_unavailable } => {
            serde_json::to_vec(&machine_status(
                *kind,
                *connection,
                *live,
                *compatibility,
                *startup_unavailable,
            ))
        }
        Request::SshStatus { link, update_offered, compatibility } => {
            serde_json::to_vec(&ssh_status(*link, *update_offered, *compatibility))
        }
        Request::RowLink { connected, connecting, server_state } => {
            serde_json::to_vec(&row_link(*connected, *connecting, *server_state))
        }
        Request::PaneUse { waits_for_user, link, reconnects_on_use } => {
            serde_json::to_vec(&pane_use(*waits_for_user, *link, *reconnects_on_use))
        }
        Request::NoticeAction { card, action, close_option, card_action, try_it } => {
            serde_json::to_vec(&notice_action(card, action, *close_option, *card_action, *try_it))
        }
        Request::DismissNotice { card } => serde_json::to_vec(&dismiss_notice(card)),
        Request::AppActivation { app } => serde_json::to_vec(&app_activation(app)),
        Request::PeerLink { link } => serde_json::to_vec(&peer_link(*link)),
        Request::StatusLinks => serde_json::to_vec(&status_links()),
        Request::JoinedLink { hub, peer } => serde_json::to_vec(&joined_link(*hub, *peer)),
    }
}

fn indexes<T>(items: &[T], keep: impl Fn(&T) -> bool) -> Vec<usize> {
    items.iter().enumerate().filter(|(_, item)| keep(item)).map(|(index, _)| index).collect()
}
