//! What origin `page` may not call (plans/cmux-next/request-origin.md,
//! "Page access"; coordinator decision 2026-10-04).
//!
//! A page's JS reaches the daemon only through a page relay, and what an
//! operation returns reaches that JS. So every terminal input, screen or
//! history read, attach/detach, renderer and file system operation is
//! refused for a page, by default. The match below names every catalog
//! operation, so a new operation does not compile until someone decides
//! whether a page may call it.
//!
//! The allow list is empty: no shipped cmux-next page calls one of these
//! operations (the page relay carries only `history.*` and `apps.*`). An
//! entry may be added only for a shipped page, with a rule that limits it
//! to that page's own object (never "any terminal by id") and its own test.

use serde_json::{Value, json};

use super::{RequestOrigin, forbidden};
use crate::resource::{ResourceError, ResourceOperation as Op};

/// The classes of operations a page may not call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Denied {
    /// Bytes, keys, mouse or focus into a terminal, a sidebar view or a
    /// browser, and commands run in a new terminal.
    Input,
    /// A terminal's screen, history, output, state or process.
    ScreenRead,
    /// Attaching to, or detaching, a view or a client.
    Attach,
    /// A renderer grant (a credential to view a terminal).
    Renderer,
    /// Files and repositories on the machine, and hook commands.
    FileSystem,
}

impl Denied {
    const fn message(self) -> &'static str {
        match self {
            Self::Input => "a page cannot send terminal input",
            Self::ScreenRead => "a page cannot read a terminal's screen, history or process",
            Self::Attach => "a page cannot attach or detach a view or a client",
            Self::Renderer => "a page cannot get a renderer grant",
            Self::FileSystem => "a page cannot reach the file system",
        }
    }
}

enum Access {
    Denied(Denied),
    /// A terminal spawn: denied (file system) when the page sends `cwd`,
    /// as R5 does on legacy `new-screen`.
    DeniedWithCwd,
    /// Outside the decision's classes.
    Outside,
}

const fn access(operation: Op) -> Access {
    match operation {
        Op::TerminalInputWrite
        | Op::TerminalInputKeys
        | Op::TerminalInputMouse
        | Op::TerminalInputFocus
        | Op::PaneRun
        | Op::WorkspaceRun
        | Op::SidebarViewInput
        | Op::BrowserInputText
        | Op::BrowserInputKey
        | Op::BrowserInputMouse
        | Op::BrowserInputWheel => Access::Denied(Denied::Input),
        Op::TerminalScreenRead
        | Op::TerminalHistoryRead
        | Op::TerminalHistoryClear
        | Op::TerminalOutputRead
        | Op::TerminalStateRead
        | Op::TerminalCopy
        | Op::TerminalWait
        | Op::TerminalWaitExit
        | Op::TerminalProcessGet => Access::Denied(Denied::ScreenRead),
        Op::TerminalAttach
        | Op::TerminalViewerResize
        | Op::TerminalViewerRelease
        | Op::TerminalViewportScroll
        | Op::BrowserAttach
        | Op::BrowserViewerResize
        | Op::BrowserViewerRelease
        | Op::SidebarViewAttach
        | Op::ClientDetach => Access::Denied(Denied::Attach),
        Op::TerminalRendererGrantCreate => Access::Denied(Denied::Renderer),
        Op::GitStatus
        | Op::GitDiff
        | Op::GitFilesSearch
        | Op::GitCheckpointCreate
        | Op::GitCheckpointDiff
        | Op::GitCheckpointGet
        | Op::GitCheckpointList
        | Op::GitCheckpointPin
        | Op::GitCheckpointUnpin
        | Op::SessionJournalHookPut => Access::Denied(Denied::FileSystem),
        Op::PaneCreate | Op::PaneSplit | Op::TabCreateTerminal => Access::DeniedWithCwd,
        Op::MachineList
        | Op::MachineGet
        | Op::SessionList
        | Op::SessionOpen
        | Op::SessionGet
        | Op::SessionSnapshot
        | Op::SessionCreationResolve
        | Op::SessionEvents
        | Op::SessionJournalSubscribe
        | Op::SessionJournalProducerList
        | Op::SessionJournalProducerPut
        | Op::SessionJournalAppend
        | Op::SessionJournalCheckpointCreate
        | Op::SessionJournalCheckpointList
        | Op::SessionJournalHookList
        | Op::SessionJournalRestorePreview
        | Op::SessionJournalSegmentList
        | Op::SessionJournalSegmentSeal
        | Op::SessionPing
        | Op::SessionShutdown
        | Op::SessionReloadConfig
        | Op::SessionTerminalDefaultsUpdate
        | Op::ClientList
        | Op::ClientGet
        | Op::ClientMetadataUpdate
        | Op::ClientSizingSet
        | Op::ClientSizingRelease
        | Op::ClientCellPixelsSet
        | Op::SessionWindowTitleSet
        | Op::SessionWindowTitleClear
        | Op::PairingRequestList
        | Op::PairingRequestResolve
        | Op::RequestCancel
        | Op::FrontendProjectionGet
        | Op::FrontendProjectionPut
        | Op::WorkspaceList
        | Op::WorkspaceGet
        | Op::WorkspaceCreate
        | Op::WorkspaceEnsureHome
        | Op::WorkspaceRename
        | Op::WorkspaceMove
        | Op::WorkspaceFocus
        | Op::WorkspaceClose
        | Op::WorkspaceLayoutApply
        | Op::ScreenList
        | Op::ScreenGet
        | Op::ScreenCreate
        | Op::ScreenRename
        | Op::ScreenFocus
        | Op::ScreenClose
        | Op::ScreenLayoutExport
        | Op::ScreenLayoutUndo
        | Op::PaneList
        | Op::PaneGet
        | Op::PaneRename
        | Op::PaneFocus
        | Op::PaneFocusDirection
        | Op::PaneNeighborGet
        | Op::PaneSwap
        | Op::PaneZoom
        | Op::PaneSplitRatioSet
        | Op::PaneViewportWidthSet
        | Op::ColumnUpdate
        | Op::PaneClose
        | Op::TabList
        | Op::TabGet
        | Op::TabCreateBrowser
        | Op::TabRename
        | Op::TabMove
        | Op::TabFocus
        | Op::TabClose
        | Op::TerminalList
        | Op::TerminalGet
        | Op::TerminalMove
        | Op::TerminalProject
        | Op::TerminalClose
        | Op::BrowserList
        | Op::BrowserGet
        | Op::BrowserNavigate
        | Op::BrowserBack
        | Op::BrowserForward
        | Op::BrowserReload
        | Op::BrowserActivate
        | Op::BrowserClose
        | Op::NotificationList
        | Op::NotificationCreate
        | Op::NotificationAck
        | Op::NotificationClear
        | Op::AgentList
        | Op::AgentReport
        | Op::SidebarViewGet
        | Op::SidebarViewEnsure
        | Op::SidebarViewResize
        | Op::SidebarViewReload
        | Op::StreamCancel
        | Op::OriginConfirmationIssue
        | Op::ClosedList
        | Op::ClosedReopen
        | Op::WindowRecordList
        | Op::WindowRecordPut
        | Op::WindowRecordDelete
        | Op::RoomCreate
        | Op::RoomDelete
        | Op::RoomFollow
        | Op::RoomList
        | Op::RoomMove
        | Op::RoomPin
        | Op::RoomUnpin
        | Op::RoomUpdate
        | Op::SavedTabGroupDelete
        | Op::SavedTabGroupList
        | Op::SavedTabGroupReopen
        | Op::SavedTabGroupSave
        | Op::ScreenMove
        | Op::ScreenUpdate
        | Op::ScreenGroupAddScreens
        | Op::ScreenGroupCreate
        | Op::ScreenGroupGet
        | Op::ScreenGroupList
        | Op::ScreenGroupRemoveScreens
        | Op::ScreenGroupUngroup
        | Op::ScreenGroupUpdate
        | Op::TabPin
        | Op::TabUnpin
        | Op::TabUpdate
        | Op::TabGroupAddTabs
        | Op::TabGroupClose
        | Op::TabGroupCreate
        | Op::TabGroupGet
        | Op::TabGroupList
        | Op::TabGroupMove
        | Op::TabGroupRemoveTabs
        | Op::TabGroupUngroup
        | Op::TabGroupUpdate
        | Op::WorkspacePlace
        | Op::WorkspacePlacementList
        | Op::WorkspaceUpdate
        | Op::WorkspaceGroupCreate
        | Op::WorkspaceGroupDelete
        | Op::WorkspaceGroupList
        | Op::WorkspaceGroupMove
        | Op::WorkspaceGroupUpdate
        | Op::WorkspaceLogAppend
        | Op::WorkspaceLogClear
        | Op::WorkspaceLogList
        | Op::WorkspaceProgressClear
        | Op::WorkspaceProgressSet
        | Op::WorkspaceStatusClear
        | Op::WorkspaceStatusList
        | Op::WorkspaceStatusSet => Access::Outside,
    }
}

/// The refusal of `operation` with `params` for a page, or `None`. An
/// operation the catalog does not have is not refused here; the resource
/// parser refuses it.
pub(super) fn refusal(operation: &str, params: &Value) -> Option<ResourceError> {
    let operation = serde_json::from_value::<Op>(Value::String(operation.to_string())).ok()?;
    let denied = match access(operation) {
        Access::Denied(denied) => denied,
        Access::DeniedWithCwd if params.get("cwd").is_some_and(|cwd| !cwd.is_null()) => {
            Denied::FileSystem
        }
        Access::DeniedWithCwd | Access::Outside => return None,
    };
    let details = json!({
        "required": RequestOrigin::Agent.wire_name(),
        "derived": RequestOrigin::Page.wire_name(),
    });
    Some(forbidden(denied.message(), details))
}
