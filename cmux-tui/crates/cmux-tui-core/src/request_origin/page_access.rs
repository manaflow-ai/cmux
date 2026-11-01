//! What origin `page` may call (plans/cmux-next/request-origin.md, "Page
//! access"; coordinator decisions 2026-10-04 and 2026-10-05; page-router-v1,
//! cmux-tui/spec/page-router.md).
//!
//! A page's JS reaches the daemon only through a page relay or a page
//! connection, and what an operation returns reaches that JS. The match
//! below names every catalog operation with no wildcard, so a new operation
//! does not compile until someone classifies it.
//!
//! A connection with no page id (a page relay without `page` in its hello)
//! is refused EVERY catalog operation. A connection with a page id gets its
//! page's allow list (spec/page-router.json, the one source): `read`
//! operations, and `gesture` operations only with a host confirmation for
//! exactly that request. The hard classes (input, screen reads, attach,
//! renderer grants, the file system) stay refused whatever a list names:
//! only a [`Denied::NotAllowed`] operation can be allow-listed.

use serde_json::{Value, json};

use super::page_router_table::{self, PageGrant};
use super::{RequestOrigin, forbidden};
use crate::resource::{ResourceError, ResourceOperation as Op};
use cmux_json::JsonSet as _;

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
    /// Every other catalog operation: not on the allow list.
    NotAllowed,
}

impl Denied {
    const fn message(self) -> &'static str {
        match self {
            Self::Input => "a page cannot send terminal input",
            Self::ScreenRead => "a page cannot read a terminal's screen, history or process",
            Self::Attach => "a page cannot attach or detach a view or a client",
            Self::Renderer => "a page cannot get a renderer grant",
            Self::FileSystem => "a page cannot reach the file system",
            Self::NotAllowed => "a page may call only allow-listed operations",
        }
    }
}

enum Access {
    Denied(Denied),
    /// A terminal spawn: refused as file system access when the page sends
    /// `cwd` (as R5 does on legacy `new-screen`), else as not allowed.
    DeniedWithCwd,
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
        | Op::BrowserInputWheel
        // A message becomes an agent's input at its next turn; a release
        // lets a held one through, and an unsend sends the agent a notice.
        | Op::AgentMessageSend
        | Op::AgentMessageRelease
        | Op::AgentMessageUnsend => Access::Denied(Denied::Input),
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
        | Op::GitBranches
        | Op::GitDiff
        | Op::GitFilesList
        | Op::GitFilesSearch
        | Op::GitCommit
        | Op::GitPush
        | Op::GitWorktreeCreate
        | Op::GitWorktreeApply
        | Op::GitWorktreeRemove
        | Op::GitCheckpointCreate
        | Op::GitCheckpointDiff
        | Op::GitCheckpointGet
        | Op::GitCheckpointList
        | Op::GitCheckpointPin
        | Op::GitCheckpointUnpin
        | Op::SessionJournalHookPut
        // It tells whether a path exists and is a folder (cx-9aps).
        | Op::WorkspaceAgentStartGet
        // The user's folders (project-list-v1): read and edited by the app, never a page.
        | Op::ProjectList
        | Op::ProjectObserve
        | Op::ProjectAdd
        | Op::ProjectUpdate
        | Op::ProjectRemove
        | Op::ProjectSync
        | Op::ProjectSourceUpdate => Access::Denied(Denied::FileSystem),
        // A browser profile's visited pages: never a page's to read or delete.
        Op::HistoryEntriesList
        | Op::HistoryEntriesRemove
        | Op::HistorySiteRemove
        | Op::HistoryClear
        | Op::HistoryRestore
        | Op::HistoryBackupsPurge
        | Op::HistoryVisitRecord
        | Op::HistoryVisitTitle
        | Op::HistoryVisitRemove
        | Op::HistoryVisitSummaries
        | Op::HistoryVisitImport
        | Op::HistoryTrailRecord => Access::Denied(Denied::NotAllowed),
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
        | Op::WorkspaceEnsureApp
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
        | Op::AgentMessageList
        | Op::AgentMessageMark
        | Op::SidebarViewGet
        | Op::SidebarViewEnsure
        | Op::SidebarViewResize
        | Op::SidebarViewReload
        | Op::StreamCancel
        | Op::OriginConfirmationIssue
        | Op::ClosedList
        | Op::ClosedDelete
        | Op::ClosedReopen
        | Op::StashCreate
        | Op::StashList
        | Op::StashRestore
        | Op::StashDelete
        | Op::StashImport
        | Op::WindowRecordList
        | Op::SettingsSchema
        | Op::SettingsList
        | Op::SettingsGet
        | Op::SettingsSnapshot
        | Op::SettingsSet
        | Op::SettingsReset
        | Op::SettingsResetAll
        | Op::KeybindingsGet
        | Op::KeybindingsSet
        | Op::KeybindingsRemove
        | Op::KeybindingsReset
        | Op::WindowRecordPut
        | Op::WindowRecordDelete
        | Op::SidebarLayoutGet
        | Op::SidebarLayoutUpdate
        | Op::SidebarGet
        | Op::SidebarMove
        | Op::SidebarPin
        | Op::SidebarUnpin
        | Op::SidebarItemAdd
        | Op::SidebarItemRemove
        | Op::SidebarItemUpdate
        | Op::SidebarItemRemoveRef
        | Op::SidebarSectionAdd
        | Op::SidebarSectionUpdate
        | Op::SidebarSectionMove
        | Op::SidebarSectionRemove
        | Op::SidebarGroupCreate
        | Op::SidebarGroupUpdate
        | Op::SidebarGroupUngroup
        | Op::SidebarAdopt
        | Op::SidebarApply
        | Op::SidebarReset
        | Op::BrowserDevicesList
        | Op::BrowserDevicesAddCustom
        | Op::BrowserDevicesRemoveCustom
        | Op::BrowserTabEmulate
        | Op::BrowserTabEmulateClear
        | Op::BrowserTabSetProfile
        | Op::BrowserProfileList
        | Op::BrowserProfileCreate
        | Op::BrowserProfileOpen
        | Op::PaletteUsageGet
        | Op::PaletteUsageRecord
        | Op::PaletteUsageImport
        | Op::PaletteUsageHide
        | Op::PaletteUsageForget
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
        | Op::LayoutBulk
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
        | Op::WorkspaceAgentFolderSet
        // Page home-channels opens a clicked web link on the person's gesture.
        | Op::WorkspaceOpenUrl
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
        | Op::WorkspaceStatusSet
        | Op::WorkspaceChecklistList
        | Op::WorkspaceChecklistAdd
        | Op::WorkspaceChecklistUpdate
        | Op::WorkspaceChecklistRemove
        // A page never sees, mints or rotates launch credentials.
        | Op::CredentialVerify
        | Op::CredentialMint
        | Op::CredentialRotate
        // A page never controls the Chief (including owner-only Continue and
        // Retry turn actions).
        | Op::ChiefEngineGet
        | Op::ChiefEngineSet
        | Op::ChiefStop
        | Op::ChiefContinue
        | Op::ChiefRetry
        // A page reads and edits the person's Chiefs only where its
        // page-router entry lists the operation (home-channels,
        // chief-profile-ws-v1); create, delete, the grant, instructions and
        // personality need a gesture.
        | Op::ChiefProfileList
        | Op::ChiefProfileGet
        | Op::ChiefProfileCreate
        | Op::ChiefProfileUpdate
        | Op::ChiefProfileDelete
        | Op::ChiefProfileAvatarSet
        | Op::ChiefProfileAvatarGet
        | Op::ChiefProfileHistory
        | Op::ChiefProfileUndo
        // Adopting an agent as a Chief: no page route at all (owner only,
        // from a terminal; chief_registry_resource.rs refuses any page).
        | Op::ChiefProfileAdopt
        // Avatars: a page reads them only through its allow list
        // (page-router.json: home-channels reads participant.avatar.get).
        | Op::ParticipantAvatarSet
        | Op::ParticipantAvatarGet
        // A page never reads or writes the person's conversations.
        | Op::ConversationList
        | Op::ConversationGet
        | Op::ConversationHistory
        | Op::ConversationSearch
        | Op::ConversationSend
        | Op::ConversationTyping
        | Op::ConversationDraft
        | Op::ConversationEvents => Access::Denied(Denied::NotAllowed),
    }
}

/// The refusal of `operation` with `params` for a page. Every catalog
/// operation has one today (the allow list is empty); a line that names no
/// catalog operation never reaches here (the parser refuses it).
pub(super) fn refusal(operation: Op, params: &Value) -> Option<ResourceError> {
    let denied = match access(operation) {
        Access::Denied(denied) => denied,
        Access::DeniedWithCwd if params.get("cwd").is_some_and(|cwd| !cwd.is_null()) => {
            Denied::FileSystem
        }
        Access::DeniedWithCwd => Denied::NotAllowed,
    };
    let details = json!({
        "required": RequestOrigin::Agent.wire_name(),
        "derived": RequestOrigin::Page.wire_name(),
    });
    Some(forbidden(denied.message(), details))
}

/// The refusal of `operation` with `params` for a connection of page
/// `page` whose request origin (after its claim) is `origin`, or `None`
/// when the page's allow list admits it.
pub(super) fn page_refusal(
    page: &str,
    operation: Op,
    params: &Value,
    origin: RequestOrigin,
) -> Option<ResourceError> {
    // A hard class is refused whatever the list names (fail closed).
    let hard = match access(operation) {
        Access::Denied(Denied::NotAllowed) => false,
        Access::Denied(_) => true,
        Access::DeniedWithCwd => params.get("cwd").is_some_and(|cwd| !cwd.is_null()),
    };
    if hard {
        // The connection's own origin (a WebSocket page derives agent).
        let mut error = refusal(operation, params)?;
        error.details.set("derived", json!(origin.wire_name()));
        return Some(error);
    }
    let grant = match page_router_table::grant(page, operation.wire_name()) {
        // A Chief edit that names a gesture field (the grant, instructions,
        // personality) needs the person's gesture even where the page may
        // edit Chiefs (chief-profile-ws-v1).
        PageGrant::Read if writes_chief_gesture_field(operation, params) => PageGrant::Gesture,
        grant => grant,
    };
    if matches!(grant, PageGrant::Gesture | PageGrant::Confirm) && origin == RequestOrigin::User {
        return None;
    }
    let reason = page_router_table::missing_confirmation_reason(grant)?;
    Some(page_forbidden(page, operation.wire_name(), reason, origin))
}

/// Whether `operation` is a Chief create or edit whose params name a gesture
/// field (chief_registry.rs `GESTURE_FIELDS`). Create and delete are on the
/// page's gesture list themselves (page-router.json).
fn writes_chief_gesture_field(operation: Op, params: &Value) -> bool {
    matches!(operation, Op::ChiefProfileCreate | Op::ChiefProfileUpdate)
        && params.as_object().is_some_and(crate::chief_registry::names_gesture_field)
}

/// `origin.forbidden` for page `page`: `page_not_allowed` (not on its
/// list), `gesture_required` or `confirmation_required` (on its list,
/// without the person's gesture or confirmation).
pub(crate) fn page_forbidden(
    page: &str,
    operation: &str,
    reason: &str,
    origin: RequestOrigin,
) -> ResourceError {
    let message = match reason {
        "gesture_required" => {
            format!("page {page} may call {operation} only on the person's gesture")
        }
        "confirmation_required" => {
            format!("page {page} may call {operation} only after the person confirms it")
        }
        _ => format!("page {page} may not call {operation}"),
    };
    let mut details = json!({"derived": origin.wire_name(), "reason": reason});
    if reason != "page_not_allowed" {
        details.set("required", json!(RequestOrigin::User.wire_name()));
    }
    ResourceError::new(super::ORIGIN_FORBIDDEN, message, details, false)
}
