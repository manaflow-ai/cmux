//! The class of every resource operation (read, mutation, stream open,
//! connection control), as the catalog states it.

use super::{OperationClass, ResourceOperation};

impl ResourceOperation {
    pub const fn class(self) -> OperationClass {
        if matches!(
            self,
            Self::SessionEvents
                | Self::SessionJournalSubscribe
                | Self::ConversationEvents
                | Self::TerminalAttach
                | Self::BrowserAttach
                | Self::SidebarViewAttach
        ) {
            OperationClass::StreamOpen
        } else if matches!(
            self,
            Self::RequestCancel
                | Self::StreamCancel
                | Self::OriginConfirmationIssue
                | Self::ClientMetadataUpdate
                | Self::ClientSizingSet
                | Self::ClientSizingRelease
                | Self::ClientCellPixelsSet
                | Self::ClientDetach
                | Self::TerminalRendererGrantCreate
                | Self::TerminalViewerResize
                | Self::TerminalViewerRelease
                | Self::BrowserViewerResize
                | Self::BrowserViewerRelease
        ) {
            OperationClass::ConnectionControl
        } else if matches!(
            self,
            Self::MachineList
                | Self::MachineGet
                | Self::SessionList
                | Self::SessionGet
                | Self::SessionSnapshot
                | Self::SessionCreationResolve
                | Self::SessionPing
                | Self::SessionJournalProducerList
                | Self::SessionJournalHookList
                | Self::SessionJournalCheckpointList
                | Self::SessionJournalRestorePreview
                | Self::SessionJournalSegmentList
                | Self::ClientList
                | Self::ClientGet
                | Self::PairingRequestList
                | Self::FrontendProjectionGet
                | Self::ChiefEngineGet
                | Self::ConversationList
                | Self::ConversationGet
                | Self::ConversationHistory
                | Self::ConversationSearch
                | Self::GitCheckpointDiff
                | Self::GitCheckpointGet
                | Self::GitCheckpointList
                | Self::GitDiff
                | Self::GitFilesSearch
                | Self::GitStatus
                | Self::HistoryEntriesList
                | Self::HistoryVisitSummaries
                | Self::WorkspaceList
                | Self::WorkspaceGet
                | Self::ScreenList
                | Self::ScreenGet
                | Self::ScreenLayoutExport
                | Self::PaneList
                | Self::PaneGet
                | Self::PaneNeighborGet
                | Self::TabList
                | Self::TabGet
                | Self::TerminalList
                | Self::TerminalGet
                | Self::TerminalScreenRead
                | Self::TerminalStateRead
                | Self::TerminalHistoryRead
                | Self::TerminalOutputRead
                | Self::TerminalWait
                | Self::TerminalWaitExit
                | Self::TerminalCopy
                | Self::TerminalProcessGet
                | Self::BrowserList
                | Self::BrowserGet
                | Self::NotificationList
                | Self::AgentList
                | Self::AgentMessageList
                | Self::SidebarViewGet
                | Self::ClosedList
                | Self::WindowRecordList
                | Self::SidebarLayoutGet
                | Self::ProjectList
                | Self::PaletteUsageGet
                | Self::RoomList
                | Self::SavedTabGroupList
                | Self::ScreenGroupGet
                | Self::ScreenGroupList
                | Self::TabGroupGet
                | Self::TabGroupList
                | Self::WorkspacePlacementList
                | Self::WorkspaceGroupList
                | Self::WorkspaceLogList
                | Self::WorkspaceStatusList
        ) {
            OperationClass::Read
        } else {
            OperationClass::Mutation
        }
    }

    pub const fn is_mutation(self) -> bool {
        matches!(self.class(), OperationClass::Mutation)
    }
}
