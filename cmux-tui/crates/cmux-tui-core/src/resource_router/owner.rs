//! Which owner answers each resource operation.

use crate::resource::ResourceOperation;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum OperationOwner {
    Machine,
    Session,
    Snapshot,
    Topology,
    Content,
    Auxiliary,
    State,
    Git,
    Connection,
}

pub(super) const fn operation_owner(operation: ResourceOperation) -> OperationOwner {
    match operation {
        ResourceOperation::MachineList
        | ResourceOperation::MachineGet
        | ResourceOperation::SessionList
        | ResourceOperation::SessionOpen
        | ResourceOperation::SessionGet => OperationOwner::Machine,
        ResourceOperation::SessionCreationResolve
        | ResourceOperation::SessionReloadConfig
        | ResourceOperation::SessionTerminalDefaultsUpdate
        | ResourceOperation::SessionWindowTitleSet
        | ResourceOperation::SessionWindowTitleClear => OperationOwner::Session,
        ResourceOperation::SessionSnapshot
        | ResourceOperation::SessionPing
        | ResourceOperation::TerminalList
        | ResourceOperation::TerminalGet
        | ResourceOperation::BrowserList
        | ResourceOperation::BrowserGet
        | ResourceOperation::NotificationList
        | ResourceOperation::NotificationCreate
        | ResourceOperation::NotificationAck
        | ResourceOperation::NotificationClear => OperationOwner::Snapshot,
        ResourceOperation::WorkspaceList
        | ResourceOperation::WorkspaceGet
        | ResourceOperation::WorkspaceCreate
        | ResourceOperation::WorkspaceRename
        | ResourceOperation::WorkspaceMove
        | ResourceOperation::WorkspaceFocus
        | ResourceOperation::WorkspaceClose
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::WorkspaceLayoutApply
        | ResourceOperation::ScreenList
        | ResourceOperation::ScreenGet
        | ResourceOperation::ScreenCreate
        | ResourceOperation::ScreenRename
        | ResourceOperation::ScreenFocus
        | ResourceOperation::ScreenClose
        | ResourceOperation::ScreenLayoutExport
        | ResourceOperation::ScreenLayoutUndo
        | ResourceOperation::PaneList
        | ResourceOperation::PaneGet
        | ResourceOperation::PaneCreate
        | ResourceOperation::PaneSplit
        | ResourceOperation::PaneRename
        | ResourceOperation::PaneFocus
        | ResourceOperation::PaneFocusDirection
        | ResourceOperation::PaneNeighborGet
        | ResourceOperation::PaneSwap
        | ResourceOperation::PaneZoom
        | ResourceOperation::PaneSplitRatioSet
        | ResourceOperation::PaneViewportWidthSet
        | ResourceOperation::ColumnUpdate
        | ResourceOperation::PaneClose
        | ResourceOperation::PaneRun
        | ResourceOperation::TabList
        | ResourceOperation::TabGet
        | ResourceOperation::TabCreateTerminal
        | ResourceOperation::TabCreateBrowser
        | ResourceOperation::TabRename
        | ResourceOperation::TabMove
        | ResourceOperation::TabFocus
        | ResourceOperation::TabClose => OperationOwner::Topology,
        ResourceOperation::TerminalInputWrite
        | ResourceOperation::TerminalInputKeys
        | ResourceOperation::TerminalInputMouse
        | ResourceOperation::TerminalInputFocus
        | ResourceOperation::TerminalScreenRead
        | ResourceOperation::TerminalStateRead
        | ResourceOperation::TerminalHistoryRead
        | ResourceOperation::TerminalHistoryClear
        | ResourceOperation::TerminalOutputRead
        | ResourceOperation::TerminalWait
        | ResourceOperation::TerminalWaitExit
        | ResourceOperation::TerminalCopy
        | ResourceOperation::TerminalProcessGet
        | ResourceOperation::TerminalViewportScroll
        | ResourceOperation::TerminalMove
        | ResourceOperation::TerminalProject
        | ResourceOperation::TerminalClose
        | ResourceOperation::BrowserNavigate
        | ResourceOperation::BrowserBack
        | ResourceOperation::BrowserForward
        | ResourceOperation::BrowserReload
        | ResourceOperation::BrowserActivate
        | ResourceOperation::BrowserInputKey
        | ResourceOperation::BrowserInputText
        | ResourceOperation::BrowserInputMouse
        | ResourceOperation::BrowserInputWheel
        | ResourceOperation::BrowserClose => OperationOwner::Content,
        ResourceOperation::AgentList
        | ResourceOperation::AgentReport
        | ResourceOperation::FrontendProjectionGet
        | ResourceOperation::FrontendProjectionPut
        | ResourceOperation::SidebarViewGet
        | ResourceOperation::SidebarViewEnsure
        | ResourceOperation::SidebarViewInput
        | ResourceOperation::SidebarViewResize
        | ResourceOperation::SidebarViewReload => OperationOwner::Auxiliary,
        ResourceOperation::GitCheckpointCreate
        | ResourceOperation::GitCheckpointDiff
        | ResourceOperation::GitCheckpointGet
        | ResourceOperation::GitCheckpointList
        | ResourceOperation::GitCheckpointPin
        | ResourceOperation::GitCheckpointUnpin
        | ResourceOperation::GitDiff
        | ResourceOperation::GitFilesSearch
        | ResourceOperation::GitStatus => OperationOwner::Git,
        ResourceOperation::WorkspaceUpdate
        | ResourceOperation::TabPin
        | ResourceOperation::TabUnpin
        | ResourceOperation::TabUpdate
        | ResourceOperation::TabGroupList
        | ResourceOperation::TabGroupGet
        | ResourceOperation::TabGroupCreate
        | ResourceOperation::TabGroupUpdate
        | ResourceOperation::TabGroupAddTabs
        | ResourceOperation::TabGroupRemoveTabs
        | ResourceOperation::TabGroupMove
        | ResourceOperation::TabGroupUngroup
        | ResourceOperation::TabGroupClose
        | ResourceOperation::WorkspaceGroupList
        | ResourceOperation::WorkspaceGroupCreate
        | ResourceOperation::WorkspaceGroupUpdate
        | ResourceOperation::WorkspaceGroupDelete
        | ResourceOperation::WorkspaceGroupMove
        | ResourceOperation::WorkspacePlacementList
        | ResourceOperation::WorkspacePlace
        | ResourceOperation::RoomList
        | ResourceOperation::RoomCreate
        | ResourceOperation::RoomUpdate
        | ResourceOperation::RoomDelete
        | ResourceOperation::RoomMove
        | ResourceOperation::RoomFollow
        | ResourceOperation::RoomPin
        | ResourceOperation::RoomUnpin
        | ResourceOperation::SavedTabGroupList
        | ResourceOperation::SavedTabGroupSave
        | ResourceOperation::SavedTabGroupReopen
        | ResourceOperation::SavedTabGroupDelete
        | ResourceOperation::ScreenUpdate
        | ResourceOperation::ScreenMove
        | ResourceOperation::ScreenGroupList
        | ResourceOperation::ScreenGroupGet
        | ResourceOperation::ScreenGroupCreate
        | ResourceOperation::ScreenGroupUpdate
        | ResourceOperation::ScreenGroupAddScreens
        | ResourceOperation::ScreenGroupRemoveScreens
        | ResourceOperation::ScreenGroupUngroup
        | ResourceOperation::ClosedList
        | ResourceOperation::ClosedReopen
        | ResourceOperation::WindowRecordList
        | ResourceOperation::WindowRecordPut
        | ResourceOperation::WorkspaceEnsureHome
        | ResourceOperation::WindowRecordDelete
        | ResourceOperation::WorkspaceStatusList
        | ResourceOperation::WorkspaceStatusSet
        | ResourceOperation::WorkspaceStatusClear
        | ResourceOperation::WorkspaceProgressSet
        | ResourceOperation::WorkspaceProgressClear
        | ResourceOperation::WorkspaceLogAppend
        | ResourceOperation::WorkspaceLogList
        | ResourceOperation::WorkspaceLogClear => OperationOwner::State,
        ResourceOperation::SessionEvents
        | ResourceOperation::SessionJournalSubscribe
        | ResourceOperation::SessionJournalProducerList
        | ResourceOperation::SessionJournalProducerPut
        | ResourceOperation::SessionJournalAppend
        | ResourceOperation::SessionJournalHookList
        | ResourceOperation::SessionJournalHookPut
        | ResourceOperation::SessionJournalCheckpointCreate
        | ResourceOperation::SessionJournalCheckpointList
        | ResourceOperation::SessionJournalRestorePreview
        | ResourceOperation::SessionJournalSegmentList
        | ResourceOperation::SessionJournalSegmentSeal
        | ResourceOperation::SessionShutdown
        | ResourceOperation::PairingRequestList
        | ResourceOperation::PairingRequestResolve
        | ResourceOperation::RequestCancel
        | ResourceOperation::ClientList
        | ResourceOperation::ClientGet
        | ResourceOperation::ClientMetadataUpdate
        | ResourceOperation::ClientSizingSet
        | ResourceOperation::ClientSizingRelease
        | ResourceOperation::ClientCellPixelsSet
        | ResourceOperation::ClientDetach
        | ResourceOperation::TerminalRendererGrantCreate
        | ResourceOperation::TerminalViewerResize
        | ResourceOperation::TerminalViewerRelease
        | ResourceOperation::TerminalAttach
        | ResourceOperation::BrowserViewerResize
        | ResourceOperation::BrowserViewerRelease
        | ResourceOperation::BrowserAttach
        | ResourceOperation::SidebarViewAttach
        | ResourceOperation::StreamCancel
        | ResourceOperation::OriginConfirmationIssue => OperationOwner::Connection,
    }
}

pub(crate) const fn requires_connection_context(operation: ResourceOperation) -> bool {
    matches!(operation_owner(operation), OperationOwner::Connection)
}
