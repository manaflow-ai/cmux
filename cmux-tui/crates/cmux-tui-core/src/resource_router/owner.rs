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
    /// The daemon history module (history_ops.rs).
    History,
    /// `browser.tab.set_profile` and `browser.profile.*`
    /// (browser_profile_ops.rs).
    BrowserProfile,
    Credential,
    Connection,
    /// Settings (the settings file): the config owner (resource_router/config.rs).
    Config,
    /// `workspace.open_url` (resource_router/open_url.rs), composed of topology
    /// and content operations.
    OpenUrl,
    /// `stash.*` (state/stash_router.rs).
    Stash,
}

pub(super) const fn operation_owner(operation: ResourceOperation) -> OperationOwner {
    match operation {
        ResourceOperation::MachineList
        | ResourceOperation::MachineGet
        | ResourceOperation::SessionList
        | ResourceOperation::SessionOpen
        | ResourceOperation::SessionGet => OperationOwner::Machine,
        ResourceOperation::CredentialVerify
        | ResourceOperation::CredentialMint
        | ResourceOperation::CredentialRotate => OperationOwner::Credential,
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
        | ResourceOperation::GitBranches
        | ResourceOperation::GitCommit
        | ResourceOperation::GitDiff
        | ResourceOperation::GitFilesList
        | ResourceOperation::GitFilesSearch
        | ResourceOperation::GitPush
        | ResourceOperation::GitWorktreeCreate
        | ResourceOperation::GitWorktreeApply
        | ResourceOperation::GitWorktreeRemove
        | ResourceOperation::GitStatus => OperationOwner::Git,
        ResourceOperation::HistoryEntriesList
        | ResourceOperation::HistoryEntriesRemove
        | ResourceOperation::HistorySiteRemove
        | ResourceOperation::HistoryClear
        | ResourceOperation::HistoryRestore
        | ResourceOperation::HistoryBackupsPurge
        | ResourceOperation::HistoryVisitRecord
        | ResourceOperation::HistoryVisitTitle
        | ResourceOperation::HistoryVisitRemove
        | ResourceOperation::HistoryVisitSummaries
        | ResourceOperation::HistoryVisitImport
        | ResourceOperation::HistoryTrailRecord => OperationOwner::History,
        ResourceOperation::BrowserTabSetProfile
        | ResourceOperation::BrowserProfileList
        | ResourceOperation::BrowserProfileCreate
        | ResourceOperation::BrowserProfileOpen => OperationOwner::BrowserProfile,
        ResourceOperation::WorkspaceOpenUrl => OperationOwner::OpenUrl,
        ResourceOperation::StashCreate
        | ResourceOperation::StashList
        | ResourceOperation::StashRestore
        | ResourceOperation::StashDelete
        | ResourceOperation::StashImport => OperationOwner::Stash,
        ResourceOperation::WorkspaceUpdate
        | ResourceOperation::WorkspaceAgentFolderSet
        | ResourceOperation::WorkspaceAgentStartGet
        | ResourceOperation::TabPin
        | ResourceOperation::TabUnpin
        | ResourceOperation::TabUpdate
        | ResourceOperation::BrowserDevicesList
        | ResourceOperation::BrowserDevicesAddCustom
        | ResourceOperation::BrowserDevicesRemoveCustom
        | ResourceOperation::BrowserTabEmulate
        | ResourceOperation::BrowserTabEmulateClear
        | ResourceOperation::TabGroupList
        | ResourceOperation::TabGroupGet
        | ResourceOperation::TabGroupCreate
        | ResourceOperation::TabGroupUpdate
        | ResourceOperation::TabGroupAddTabs
        | ResourceOperation::TabGroupRemoveTabs
        | ResourceOperation::TabGroupMove
        | ResourceOperation::TabGroupUngroup
        | ResourceOperation::TabGroupClose
        | ResourceOperation::LayoutBulk
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
        | ResourceOperation::ClosedDelete
        | ResourceOperation::WindowRecordList
        | ResourceOperation::WindowRecordPut
        | ResourceOperation::WorkspaceEnsureHome
        | ResourceOperation::WorkspaceEnsureApp
        | ResourceOperation::WindowRecordDelete
        | ResourceOperation::SidebarLayoutGet
        | ResourceOperation::SidebarLayoutUpdate
        | ResourceOperation::SidebarGet
        | ResourceOperation::SidebarMove
        | ResourceOperation::SidebarPin
        | ResourceOperation::SidebarUnpin
        | ResourceOperation::SidebarItemAdd
        | ResourceOperation::SidebarItemRemove
        | ResourceOperation::SidebarItemUpdate
        | ResourceOperation::SidebarItemRemoveRef
        | ResourceOperation::SidebarSectionAdd
        | ResourceOperation::SidebarSectionUpdate
        | ResourceOperation::SidebarSectionMove
        | ResourceOperation::SidebarSectionRemove
        | ResourceOperation::SidebarGroupCreate
        | ResourceOperation::SidebarGroupUpdate
        | ResourceOperation::SidebarGroupUngroup
        | ResourceOperation::SidebarAdopt
        | ResourceOperation::SidebarApply
        | ResourceOperation::SidebarReset
        | ResourceOperation::ProjectList
        | ResourceOperation::ProjectObserve
        | ResourceOperation::ProjectAdd
        | ResourceOperation::ProjectUpdate
        | ResourceOperation::ProjectRemove
        | ResourceOperation::ProjectSync
        | ResourceOperation::ProjectSourceUpdate
        | ResourceOperation::PaletteUsageGet
        | ResourceOperation::PaletteUsageRecord
        | ResourceOperation::PaletteUsageImport
        | ResourceOperation::PaletteUsageHide
        | ResourceOperation::PaletteUsageForget
        | ResourceOperation::WorkspaceStatusList
        | ResourceOperation::WorkspaceStatusSet
        | ResourceOperation::WorkspaceStatusClear
        | ResourceOperation::WorkspaceProgressSet
        | ResourceOperation::WorkspaceProgressClear
        | ResourceOperation::WorkspaceLogAppend
        | ResourceOperation::WorkspaceLogList
        | ResourceOperation::WorkspaceLogClear
        | ResourceOperation::WorkspaceChecklistList
        | ResourceOperation::WorkspaceChecklistAdd
        | ResourceOperation::WorkspaceChecklistUpdate
        | ResourceOperation::WorkspaceChecklistRemove
        | ResourceOperation::AgentMessageSend
        | ResourceOperation::AgentMessageList
        | ResourceOperation::AgentMessageMark
        | ResourceOperation::AgentMessageRelease
        | ResourceOperation::AgentMessageUnsend => OperationOwner::State,
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
        | ResourceOperation::ChiefEngineGet
        | ResourceOperation::ChiefEngineSet
        | ResourceOperation::ChiefStop
        | ResourceOperation::ChiefContinue
        | ResourceOperation::ChiefRetry
        | ResourceOperation::ChiefProfileList
        | ResourceOperation::ChiefProfileGet
        | ResourceOperation::ChiefProfileCreate
        | ResourceOperation::ChiefProfileAdopt
        | ResourceOperation::ChiefProfileUpdate
        | ResourceOperation::ChiefProfileDelete
        | ResourceOperation::ChiefProfileAvatarSet
        | ResourceOperation::ChiefProfileAvatarGet
        | ResourceOperation::ChiefProfileHistory
        | ResourceOperation::ChiefProfileUndo
        | ResourceOperation::ParticipantAvatarSet
        | ResourceOperation::ParticipantAvatarGet
        | ResourceOperation::ConversationList
        | ResourceOperation::ConversationGet
        | ResourceOperation::ConversationHistory
        | ResourceOperation::ConversationSearch
        | ResourceOperation::ConversationSend
        | ResourceOperation::ConversationTyping
        | ResourceOperation::ConversationDraft
        | ResourceOperation::ConversationEvents
        | ResourceOperation::OriginConfirmationIssue => OperationOwner::Connection,
        ResourceOperation::SettingsSchema
        | ResourceOperation::SettingsList
        | ResourceOperation::SettingsGet
        | ResourceOperation::SettingsSnapshot
        | ResourceOperation::SettingsSet
        | ResourceOperation::SettingsReset
        | ResourceOperation::SettingsResetAll
        | ResourceOperation::KeybindingsGet
        | ResourceOperation::KeybindingsSet
        | ResourceOperation::KeybindingsRemove
        | ResourceOperation::KeybindingsReset => OperationOwner::Config,
    }
}

pub(crate) const fn requires_connection_context(operation: ResourceOperation) -> bool {
    matches!(operation_owner(operation), OperationOwner::Connection)
}
