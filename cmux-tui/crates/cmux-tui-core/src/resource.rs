//! Opaque public resource identities and protocol-v2 shared types.

use std::fmt;
use std::sync::OnceLock;

use scope::canonical_resource_scope;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

mod selector_tokens;
pub use selector_tokens::is_reserved_selector_token;
mod error;
mod idempotency;
mod request_id;
pub use error::*;
pub use idempotency::{MAX_IDEMPOTENCY_KEY_BYTES, validate_idempotency_key};
pub use request_id::RequestId;

pub const PROTOCOL: &str = "cmux.protocol/2";
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
pub const STREAM_EVENT_CAPACITY: usize = 256;
pub const STREAM_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
pub const JOURNAL_CAPACITY: usize = 4096;
pub const JOURNAL_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EnvelopeType {
    #[serde(rename = "request")]
    Request,
    #[serde(rename = "response")]
    Response,
    #[serde(rename = "stream_item")]
    StreamItem,
    #[serde(rename = "stream_end")]
    StreamEnd,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ResourceOperation {
    #[serde(rename = "machine.list")]
    MachineList,
    #[serde(rename = "machine.get")]
    MachineGet,
    #[serde(rename = "session.list")]
    SessionList,
    #[serde(rename = "session.open")]
    SessionOpen,
    #[serde(rename = "session.get")]
    SessionGet,
    #[serde(rename = "session.snapshot")]
    SessionSnapshot,
    #[serde(rename = "session.creation.resolve")]
    SessionCreationResolve,
    #[serde(rename = "session.events")]
    SessionEvents,
    #[serde(rename = "session.journal.subscribe")]
    SessionJournalSubscribe,
    #[serde(rename = "session.journal.producer.list")]
    SessionJournalProducerList,
    #[serde(rename = "session.journal.producer.put")]
    SessionJournalProducerPut,
    #[serde(rename = "session.journal.append")]
    SessionJournalAppend,
    #[serde(rename = "session.journal.checkpoint.create")]
    SessionJournalCheckpointCreate,
    #[serde(rename = "session.journal.checkpoint.list")]
    SessionJournalCheckpointList,
    #[serde(rename = "session.journal.hook.list")]
    SessionJournalHookList,
    #[serde(rename = "session.journal.hook.put")]
    SessionJournalHookPut,
    #[serde(rename = "session.journal.restore.preview")]
    SessionJournalRestorePreview,
    #[serde(rename = "session.journal.segment.list")]
    SessionJournalSegmentList,
    #[serde(rename = "session.journal.segment.seal")]
    SessionJournalSegmentSeal,
    #[serde(rename = "session.ping")]
    SessionPing,
    #[serde(rename = "session.shutdown")]
    SessionShutdown,
    #[serde(rename = "session.reload_config")]
    SessionReloadConfig,
    #[serde(rename = "session.terminal_defaults.update")]
    SessionTerminalDefaultsUpdate,
    #[serde(rename = "client.list")]
    ClientList,
    #[serde(rename = "client.get")]
    ClientGet,
    #[serde(rename = "client.metadata.update")]
    ClientMetadataUpdate,
    #[serde(rename = "client.sizing.set")]
    ClientSizingSet,
    #[serde(rename = "client.sizing.release")]
    ClientSizingRelease,
    #[serde(rename = "client.cell_pixels.set")]
    ClientCellPixelsSet,
    #[serde(rename = "client.detach")]
    ClientDetach,
    #[serde(rename = "session.window.title.set")]
    SessionWindowTitleSet,
    #[serde(rename = "session.window.title.clear")]
    SessionWindowTitleClear,
    #[serde(rename = "pairing_request.list")]
    PairingRequestList,
    #[serde(rename = "pairing_request.resolve")]
    PairingRequestResolve,
    #[serde(rename = "request.cancel")]
    RequestCancel,
    #[serde(rename = "frontend_projection.get")]
    FrontendProjectionGet,
    #[serde(rename = "frontend_projection.put")]
    FrontendProjectionPut,
    #[serde(rename = "git.checkpoint.create")]
    GitCheckpointCreate,
    #[serde(rename = "git.checkpoint.diff")]
    GitCheckpointDiff,
    #[serde(rename = "git.checkpoint.get")]
    GitCheckpointGet,
    #[serde(rename = "git.checkpoint.list")]
    GitCheckpointList,
    #[serde(rename = "git.checkpoint.pin")]
    GitCheckpointPin,
    #[serde(rename = "git.checkpoint.unpin")]
    GitCheckpointUnpin,
    #[serde(rename = "chief.engine.get")]
    ChiefEngineGet,
    #[serde(rename = "chief.engine.set")]
    ChiefEngineSet,
    #[serde(rename = "chief.stop")]
    ChiefStop,
    #[serde(rename = "chief.automation.list")]
    ChiefAutomationList,
    #[serde(rename = "chief.automation.update")]
    ChiefAutomationUpdate,
    #[serde(rename = "chief.continue")]
    ChiefContinue,
    #[serde(rename = "chief.retry")]
    ChiefRetry,
    #[serde(rename = "chief.profile.list")]
    ChiefProfileList,
    #[serde(rename = "chief.profile.get")]
    ChiefProfileGet,
    #[serde(rename = "chief.profile.create")]
    ChiefProfileCreate,
    #[serde(rename = "chief.profile.adopt")]
    ChiefProfileAdopt,
    #[serde(rename = "chief.profile.update")]
    ChiefProfileUpdate,
    #[serde(rename = "chief.profile.delete")]
    ChiefProfileDelete,
    #[serde(rename = "chief.profile.avatar.set")]
    ChiefProfileAvatarSet,
    #[serde(rename = "chief.profile.avatar.get")]
    ChiefProfileAvatarGet,
    #[serde(rename = "chief.profile.history")]
    ChiefProfileHistory,
    #[serde(rename = "chief.profile.undo")]
    ChiefProfileUndo,
    #[serde(rename = "participant.avatar.set")]
    ParticipantAvatarSet,
    #[serde(rename = "participant.avatar.get")]
    ParticipantAvatarGet,
    #[serde(rename = "credential.verify")]
    CredentialVerify,
    #[serde(rename = "credential.mint")]
    CredentialMint,
    #[serde(rename = "credential.rotate")]
    CredentialRotate,
    #[serde(rename = "conversation.list")]
    ConversationList,
    #[serde(rename = "conversation.get")]
    ConversationGet,
    #[serde(rename = "conversation.history")]
    ConversationHistory,
    #[serde(rename = "conversation.search")]
    ConversationSearch,
    #[serde(rename = "conversation.send")]
    ConversationSend,
    #[serde(rename = "conversation.typing")]
    ConversationTyping,
    #[serde(rename = "conversation.draft")]
    ConversationDraft,
    #[serde(rename = "conversation.events")]
    ConversationEvents,
    #[serde(rename = "diff.comments.delete")]
    DiffCommentsDelete,
    #[serde(rename = "diff.comments.list")]
    DiffCommentsList,
    #[serde(rename = "diff.comments.save")]
    DiffCommentsSave,
    #[serde(rename = "diff.comments.send")]
    DiffCommentsSend,
    #[serde(rename = "diff.comments.thread")]
    DiffCommentsThread,
    #[serde(rename = "git.branches")]
    GitBranches,
    #[serde(rename = "git.review.comment")]
    GitReviewComment,
    #[serde(rename = "git.review.post")]
    GitReviewPost,
    #[serde(rename = "git.review.start")]
    GitReviewStart,
    #[serde(rename = "git.commit")]
    GitCommit,
    #[serde(rename = "git.diff")]
    GitDiff,
    #[serde(rename = "git.files.list")]
    GitFilesList,
    #[serde(rename = "git.fingerprint")]
    GitFingerprint,
    #[serde(rename = "git.files.search")]
    GitFilesSearch,
    #[serde(rename = "git.push")]
    GitPush,
    #[serde(rename = "git.status")]
    GitStatus,
    #[serde(rename = "git.worktree.create")]
    GitWorktreeCreate,
    #[serde(rename = "git.worktree.apply")]
    GitWorktreeApply,
    #[serde(rename = "git.worktree.remove")]
    GitWorktreeRemove,
    #[serde(rename = "git.worktree.setup")]
    GitWorktreeSetup,
    #[serde(rename = "git.worktree.setup.run")]
    GitWorktreeSetupRun,
    #[serde(rename = "history.entries.list")]
    HistoryEntriesList,
    #[serde(rename = "history.entries.remove")]
    HistoryEntriesRemove,
    #[serde(rename = "history.site.remove")]
    HistorySiteRemove,
    #[serde(rename = "history.clear")]
    HistoryClear,
    #[serde(rename = "history.restore")]
    HistoryRestore,
    #[serde(rename = "history.backups.purge")]
    HistoryBackupsPurge,
    #[serde(rename = "history.visit.record")]
    HistoryVisitRecord,
    #[serde(rename = "history.visit.title")]
    HistoryVisitTitle,
    #[serde(rename = "history.visit.remove")]
    HistoryVisitRemove,
    #[serde(rename = "history.visit.summaries")]
    HistoryVisitSummaries,
    #[serde(rename = "history.visit.import")]
    HistoryVisitImport,
    #[serde(rename = "history.trail.record")]
    HistoryTrailRecord,
    #[serde(rename = "workspace.list")]
    WorkspaceList,
    #[serde(rename = "workspace.get")]
    WorkspaceGet,
    #[serde(rename = "workspace.create")]
    WorkspaceCreate,
    #[serde(rename = "workspace.ensure_home")]
    WorkspaceEnsureHome,
    #[serde(rename = "workspace.ensure_app")]
    WorkspaceEnsureApp,
    #[serde(rename = "workspace.rename")]
    WorkspaceRename,
    #[serde(rename = "workspace.move")]
    WorkspaceMove,
    #[serde(rename = "workspace.focus")]
    WorkspaceFocus,
    #[serde(rename = "workspace.close")]
    WorkspaceClose,
    #[serde(rename = "workspace.run")]
    WorkspaceRun,
    #[serde(rename = "workspace.layout.apply")]
    WorkspaceLayoutApply,
    #[serde(rename = "screen.list")]
    ScreenList,
    #[serde(rename = "screen.get")]
    ScreenGet,
    #[serde(rename = "screen.create")]
    ScreenCreate,
    #[serde(rename = "screen.rename")]
    ScreenRename,
    #[serde(rename = "screen.focus")]
    ScreenFocus,
    #[serde(rename = "screen.close")]
    ScreenClose,
    #[serde(rename = "screen.layout.export")]
    ScreenLayoutExport,
    #[serde(rename = "screen.layout.undo")]
    ScreenLayoutUndo,
    #[serde(rename = "pane.list")]
    PaneList,
    #[serde(rename = "pane.get")]
    PaneGet,
    #[serde(rename = "pane.create")]
    PaneCreate,
    #[serde(rename = "pane.split")]
    PaneSplit,
    #[serde(rename = "pane.rename")]
    PaneRename,
    #[serde(rename = "pane.focus")]
    PaneFocus,
    #[serde(rename = "pane.focus_direction")]
    PaneFocusDirection,
    #[serde(rename = "pane.neighbor.get")]
    PaneNeighborGet,
    #[serde(rename = "pane.swap")]
    PaneSwap,
    #[serde(rename = "pane.move")]
    PaneMove,
    #[serde(rename = "pane.zoom")]
    PaneZoom,
    #[serde(rename = "pane.split_ratio.set")]
    PaneSplitRatioSet,
    #[serde(rename = "pane.viewport_width.set")]
    PaneViewportWidthSet,
    #[serde(rename = "column.update")]
    ColumnUpdate,
    #[serde(rename = "pane.close")]
    PaneClose,
    #[serde(rename = "pane.run")]
    PaneRun,
    #[serde(rename = "tab.list")]
    TabList,
    #[serde(rename = "tab.get")]
    TabGet,
    #[serde(rename = "tab.create_terminal")]
    TabCreateTerminal,
    #[serde(rename = "tab.create_browser")]
    TabCreateBrowser,
    #[serde(rename = "tab.rename")]
    TabRename,
    #[serde(rename = "tab.move")]
    TabMove,
    #[serde(rename = "tab.focus")]
    TabFocus,
    #[serde(rename = "tab.close")]
    TabClose,
    #[serde(rename = "terminal.list")]
    TerminalList,
    #[serde(rename = "terminal.get")]
    TerminalGet,
    #[serde(rename = "terminal.input.write")]
    TerminalInputWrite,
    #[serde(rename = "terminal.input.keys")]
    TerminalInputKeys,
    #[serde(rename = "terminal.input.mouse")]
    TerminalInputMouse,
    #[serde(rename = "terminal.input.focus")]
    TerminalInputFocus,
    #[serde(rename = "terminal.screen.read")]
    TerminalScreenRead,
    #[serde(rename = "terminal.state.read")]
    TerminalStateRead,
    #[serde(rename = "terminal.history.read")]
    TerminalHistoryRead,
    #[serde(rename = "terminal.history.clear")]
    TerminalHistoryClear,
    #[serde(rename = "terminal.output_read")]
    TerminalOutputRead,
    #[serde(rename = "terminal.wait")]
    TerminalWait,
    #[serde(rename = "terminal.wait_exit")]
    TerminalWaitExit,
    #[serde(rename = "terminal.copy")]
    TerminalCopy,
    #[serde(rename = "terminal.process.get")]
    TerminalProcessGet,
    #[serde(rename = "terminal.renderer_grant.create")]
    TerminalRendererGrantCreate,
    #[serde(rename = "terminal.viewer.resize")]
    TerminalViewerResize,
    #[serde(rename = "terminal.viewer.release")]
    TerminalViewerRelease,
    #[serde(rename = "terminal.viewport.scroll")]
    TerminalViewportScroll,
    #[serde(rename = "terminal.move")]
    TerminalMove,
    #[serde(rename = "terminal.project")]
    TerminalProject,
    #[serde(rename = "terminal.attach")]
    TerminalAttach,
    #[serde(rename = "terminal.close")]
    TerminalClose,
    #[serde(rename = "browser.list")]
    BrowserList,
    #[serde(rename = "browser.get")]
    BrowserGet,
    #[serde(rename = "browser.navigate")]
    BrowserNavigate,
    #[serde(rename = "browser.back")]
    BrowserBack,
    #[serde(rename = "browser.forward")]
    BrowserForward,
    #[serde(rename = "browser.reload")]
    BrowserReload,
    #[serde(rename = "browser.activate")]
    BrowserActivate,
    #[serde(rename = "browser.input.key")]
    BrowserInputKey,
    #[serde(rename = "browser.input.text")]
    BrowserInputText,
    #[serde(rename = "browser.input.mouse")]
    BrowserInputMouse,
    #[serde(rename = "browser.input.wheel")]
    BrowserInputWheel,
    #[serde(rename = "browser.viewer.resize")]
    BrowserViewerResize,
    #[serde(rename = "browser.viewer.release")]
    BrowserViewerRelease,
    #[serde(rename = "browser.attach")]
    BrowserAttach,
    #[serde(rename = "browser.close")]
    BrowserClose,
    #[serde(rename = "notification.list")]
    NotificationList,
    #[serde(rename = "notification.create")]
    NotificationCreate,
    #[serde(rename = "notification.ack")]
    NotificationAck,
    #[serde(rename = "notification.clear")]
    NotificationClear,
    #[serde(rename = "agent.list")]
    AgentList,
    #[serde(rename = "agent.report")]
    AgentReport,
    #[serde(rename = "agent.message.send")]
    AgentMessageSend,
    #[serde(rename = "agent.message.list")]
    AgentMessageList,
    #[serde(rename = "agent.message.mark")]
    AgentMessageMark,
    #[serde(rename = "agent.message.release")]
    AgentMessageRelease,
    #[serde(rename = "agent.message.unsend")]
    AgentMessageUnsend,
    #[serde(rename = "chat.list")]
    ChatList,
    #[serde(rename = "chat.mark_read")]
    ChatMarkRead,
    #[serde(rename = "chat.pin")]
    ChatPin,
    #[serde(rename = "sidebar_view.get")]
    SidebarViewGet,
    #[serde(rename = "sidebar_view.ensure")]
    SidebarViewEnsure,
    #[serde(rename = "sidebar_view.attach")]
    SidebarViewAttach,
    #[serde(rename = "sidebar_view.input")]
    SidebarViewInput,
    #[serde(rename = "sidebar_view.resize")]
    SidebarViewResize,
    #[serde(rename = "sidebar_view.reload")]
    SidebarViewReload,
    #[serde(rename = "stream.cancel")]
    StreamCancel,
    #[serde(rename = "origin.confirmation.issue")]
    OriginConfirmationIssue,
    #[serde(rename = "closed.list")]
    ClosedList,
    #[serde(rename = "closed.delete")]
    ClosedDelete,
    #[serde(rename = "closed.reopen")]
    ClosedReopen,
    #[serde(rename = "settings.schema")]
    SettingsSchema,
    #[serde(rename = "settings.list")]
    SettingsList,
    #[serde(rename = "settings.get")]
    SettingsGet,
    #[serde(rename = "settings.snapshot")]
    SettingsSnapshot,
    #[serde(rename = "settings.set")]
    SettingsSet,
    #[serde(rename = "settings.reset")]
    SettingsReset,
    #[serde(rename = "settings.reset_all")]
    SettingsResetAll,
    #[serde(rename = "settings.edit")]
    SettingsEdit,
    #[serde(rename = "settings.history")]
    SettingsHistory,
    #[serde(rename = "settings.undo")]
    SettingsUndo,
    #[serde(rename = "settings.restore")]
    SettingsRestore,
    #[serde(rename = "settings.reset_group")]
    SettingsResetGroup,
    #[serde(rename = "keybindings.get")]
    KeybindingsGet,
    #[serde(rename = "keybindings.set")]
    KeybindingsSet,
    #[serde(rename = "keybindings.remove")]
    KeybindingsRemove,
    #[serde(rename = "keybindings.reset")]
    KeybindingsReset,
    #[serde(rename = "language_packs.ensure")]
    LanguagePacksEnsure,
    #[serde(rename = "window_record.list")]
    WindowRecordList,
    #[serde(rename = "window_record.put")]
    WindowRecordPut,
    #[serde(rename = "window_record.delete")]
    WindowRecordDelete,
    #[serde(rename = "sidebar_layout.get")]
    SidebarLayoutGet,
    #[serde(rename = "sidebar_layout.update")]
    SidebarLayoutUpdate,
    #[serde(rename = "sidebar.get")]
    SidebarGet,
    #[serde(rename = "sidebar.move")]
    SidebarMove,
    #[serde(rename = "sidebar.pin")]
    SidebarPin,
    #[serde(rename = "sidebar.unpin")]
    SidebarUnpin,
    #[serde(rename = "sidebar.item.add")]
    SidebarItemAdd,
    #[serde(rename = "sidebar.item.remove")]
    SidebarItemRemove,
    #[serde(rename = "sidebar.item.update")]
    SidebarItemUpdate,
    #[serde(rename = "sidebar.item.remove_ref")]
    SidebarItemRemoveRef,
    #[serde(rename = "sidebar.section.add")]
    SidebarSectionAdd,
    #[serde(rename = "sidebar.section.update")]
    SidebarSectionUpdate,
    #[serde(rename = "sidebar.section.move")]
    SidebarSectionMove,
    #[serde(rename = "sidebar.section.remove")]
    SidebarSectionRemove,
    #[serde(rename = "sidebar.group.create")]
    SidebarGroupCreate,
    #[serde(rename = "sidebar.group.update")]
    SidebarGroupUpdate,
    #[serde(rename = "sidebar.group.ungroup")]
    SidebarGroupUngroup,
    #[serde(rename = "sidebar.adopt")]
    SidebarAdopt,
    #[serde(rename = "sidebar.apply")]
    SidebarApply,
    #[serde(rename = "sidebar.reset")]
    SidebarReset,
    #[serde(rename = "project.list")]
    ProjectList,
    #[serde(rename = "project.actions.list")]
    ProjectActionsList,
    #[serde(rename = "project.observe")]
    ProjectObserve,
    #[serde(rename = "project.add")]
    ProjectAdd,
    #[serde(rename = "project.update")]
    ProjectUpdate,
    #[serde(rename = "project.remove")]
    ProjectRemove,
    #[serde(rename = "project.sync")]
    ProjectSync,
    #[serde(rename = "project.source.update")]
    ProjectSourceUpdate,
    #[serde(rename = "browser.devices.list")]
    BrowserDevicesList,
    #[serde(rename = "browser.devices.add_custom")]
    BrowserDevicesAddCustom,
    #[serde(rename = "browser.devices.remove_custom")]
    BrowserDevicesRemoveCustom,
    #[serde(rename = "browser.tab.emulate")]
    BrowserTabEmulate,
    #[serde(rename = "browser.tab.emulate.clear")]
    BrowserTabEmulateClear,
    #[serde(rename = "browser.tab.set_profile")]
    BrowserTabSetProfile,
    #[serde(rename = "browser.profile.list")]
    BrowserProfileList,
    #[serde(rename = "browser.profile.create")]
    BrowserProfileCreate,
    #[serde(rename = "browser.profile.open")]
    BrowserProfileOpen,
    #[serde(rename = "palette_usage.get")]
    PaletteUsageGet,
    #[serde(rename = "palette_usage.record")]
    PaletteUsageRecord,
    #[serde(rename = "palette_usage.import")]
    PaletteUsageImport,
    #[serde(rename = "palette_usage.hide")]
    PaletteUsageHide,
    #[serde(rename = "palette_usage.forget")]
    PaletteUsageForget,
    #[serde(rename = "palette.rank")]
    PaletteRank,
    #[serde(rename = "theme.scheme.convert")]
    ThemeSchemeConvert,
    #[serde(rename = "theme.scheme.export")]
    ThemeSchemeExport,
    #[serde(rename = "theme.scheme.from_image")]
    ThemeSchemeFromImage,
    #[serde(rename = "theme.slots.resolve")]
    ThemeSlotsResolve,
    #[serde(rename = "stash.create")]
    StashCreate,
    #[serde(rename = "stash.list")]
    StashList,
    #[serde(rename = "stash.restore")]
    StashRestore,
    #[serde(rename = "stash.delete")]
    StashDelete,
    #[serde(rename = "stash.import")]
    StashImport,
    #[serde(rename = "classic_import.plan")]
    ClassicImportPlan,
    #[serde(rename = "classic_import.record")]
    ClassicImportRecord,
    #[serde(rename = "conductor_import.plan")]
    ConductorImportPlan,
    #[serde(rename = "conductor_import.record")]
    ConductorImportRecord,
    #[serde(rename = "browser_import.read")]
    BrowserImportRead,
    #[serde(rename = "cloud.vm.scp_endpoint")]
    CloudVmScpEndpoint,
    #[serde(rename = "cloud.vm.tunnel_enroll")]
    CloudVmTunnelEnroll,
    #[serde(rename = "cloud.vm.tunnel_revoke")]
    CloudVmTunnelRevoke,
    #[serde(rename = "cloud.vm.tunnel_attach")]
    CloudVmTunnelAttach,
    #[serde(rename = "cloud.vm.tunnel_detach")]
    CloudVmTunnelDetach,
    #[serde(rename = "cloud.vm.tunnel_rotate_key")]
    CloudVmTunnelRotateKey,
    #[serde(rename = "cloud.vm.firewall_list")]
    CloudVmFirewallList,
    #[serde(rename = "cloud.vm.firewall_get")]
    CloudVmFirewallGet,
    #[serde(rename = "cloud.vm.firewall_create")]
    CloudVmFirewallCreate,
    #[serde(rename = "cloud.vm.firewall_delete")]
    CloudVmFirewallDelete,
    #[serde(rename = "cloud.vm.networks")]
    CloudVmNetworks,
    #[serde(rename = "cloud.vm.domains")]
    CloudVmDomains,
    #[serde(rename = "cloud.vm.publications")]
    CloudVmPublications,
    #[serde(rename = "cloud.vm.provision_api")]
    CloudVmProvisionApi,
    #[serde(rename = "cloud.vm.publication_api_keys")]
    CloudVmPublicationApiKeys,
    #[serde(rename = "cloud.vm.revoke_publication_api_key")]
    CloudVmRevokePublicationApiKey,
    #[serde(rename = "cloud.runs.create")]
    CloudRunsCreate,
    #[serde(rename = "cloud.runs.start")]
    CloudRunsStart,
    #[serde(rename = "cloud.runs.wait")]
    CloudRunsWait,
    #[serde(rename = "cloud.runs.cancel")]
    CloudRunsCancel,
    #[serde(rename = "cloud.runs.sandbox")]
    CloudRunsSandbox,
    #[serde(rename = "cloud.owner.acpmux_person_holds")]
    CloudOwnerAcpmuxPersonHolds,
    #[serde(rename = "cloud.owner.acpmux_keyed_start")]
    CloudOwnerAcpmuxKeyedStart,
    #[serde(rename = "cloud.owner.fork_run")]
    CloudOwnerForkRun,
    #[serde(rename = "cloud.owner.handoff_wait")]
    CloudOwnerHandoffWait,
    #[serde(rename = "cloud.owner.handoffs")]
    CloudOwnerHandoffs,
    #[serde(rename = "cloud.owner.handoff_open")]
    CloudOwnerHandoffOpen,
    #[serde(rename = "cloud.owner.handoff_begin_turn")]
    CloudOwnerHandoffBeginTurn,
    #[serde(rename = "cloud.owner.harness_login_copy")]
    CloudOwnerHarnessLoginCopy,
    #[serde(rename = "cloud.owner.github_app")]
    CloudOwnerGithubApp,
    #[serde(rename = "cloud.owner.github_repos")]
    CloudOwnerGithubRepos,
    #[serde(rename = "cloud.owner.github_connect")]
    CloudOwnerGithubConnect,
    #[serde(rename = "cloud.owner.op")]
    CloudOwnerOp,
    #[serde(rename = "cloud.owner.github_complete")]
    CloudOwnerGithubComplete,
    #[serde(rename = "cloud.owner.github_list")]
    CloudOwnerGithubList,
    #[serde(rename = "cloud.owner.github_clone_token")]
    CloudOwnerGithubCloneToken,
    #[serde(rename = "cloud.owner.slack")]
    CloudOwnerSlack,
    #[serde(rename = "cloud.owner.slack_awake")]
    CloudOwnerSlackAwake,
    #[serde(rename = "cloud.owner.turn_checkpoint")]
    CloudOwnerTurnCheckpoint,
    #[serde(rename = "cloud.owner.turn_rewind")]
    CloudOwnerTurnRewind,
    #[serde(rename = "cloud.owner.turns")]
    CloudOwnerTurns,
    #[serde(rename = "cloud.previews.refresh")]
    CloudPreviewsRefresh,
    #[serde(rename = "cloud.previews.create_link")]
    CloudPreviewsCreateLink,
    #[serde(rename = "cloud.previews.revoke_link")]
    CloudPreviewsRevokeLink,
    #[serde(rename = "cloud.machine.io")]
    CloudMachineIo,
    #[serde(rename = "cloud.machine.chat_access")]
    CloudMachineChatAccess,
    #[serde(rename = "cloud.machine.share_chat")]
    CloudMachineShareChat,
    #[serde(rename = "cloud.machine.chief_start")]
    CloudMachineChiefStart,
    #[serde(rename = "cloud.machine.chief_resize")]
    CloudMachineChiefResize,
    #[serde(rename = "cloud.machine.setup_desktop")]
    CloudMachineSetupDesktop,
    #[serde(rename = "cloud.machine.fork")]
    CloudMachineFork,
    #[serde(rename = "room.create")]
    RoomCreate,
    #[serde(rename = "room.delete")]
    RoomDelete,
    #[serde(rename = "room.follow")]
    RoomFollow,
    #[serde(rename = "room.list")]
    RoomList,
    #[serde(rename = "room.move")]
    RoomMove,
    #[serde(rename = "room.pin")]
    RoomPin,
    #[serde(rename = "room.unpin")]
    RoomUnpin,
    #[serde(rename = "room.update")]
    RoomUpdate,
    #[serde(rename = "saved_tab_group.delete")]
    SavedTabGroupDelete,
    #[serde(rename = "saved_tab_group.list")]
    SavedTabGroupList,
    #[serde(rename = "saved_tab_group.reopen")]
    SavedTabGroupReopen,
    #[serde(rename = "saved_tab_group.save")]
    SavedTabGroupSave,
    #[serde(rename = "screen.move")]
    ScreenMove,
    #[serde(rename = "screen.update")]
    ScreenUpdate,
    #[serde(rename = "screen_group.add_screens")]
    ScreenGroupAddScreens,
    #[serde(rename = "screen_group.create")]
    ScreenGroupCreate,
    #[serde(rename = "screen_group.get")]
    ScreenGroupGet,
    #[serde(rename = "screen_group.list")]
    ScreenGroupList,
    #[serde(rename = "screen_group.remove_screens")]
    ScreenGroupRemoveScreens,
    #[serde(rename = "screen_group.ungroup")]
    ScreenGroupUngroup,
    #[serde(rename = "screen_group.update")]
    ScreenGroupUpdate,
    #[serde(rename = "tab.pin")]
    TabPin,
    #[serde(rename = "tab.unpin")]
    TabUnpin,
    #[serde(rename = "tab.update")]
    TabUpdate,
    #[serde(rename = "tab_group.add_tabs")]
    TabGroupAddTabs,
    #[serde(rename = "tab_group.close")]
    TabGroupClose,
    #[serde(rename = "layout.bulk")]
    LayoutBulk,
    #[serde(rename = "tab_group.create")]
    TabGroupCreate,
    #[serde(rename = "tab_group.get")]
    TabGroupGet,
    #[serde(rename = "tab_group.list")]
    TabGroupList,
    #[serde(rename = "tab_group.move")]
    TabGroupMove,
    #[serde(rename = "tab_group.remove_tabs")]
    TabGroupRemoveTabs,
    #[serde(rename = "tab_group.ungroup")]
    TabGroupUngroup,
    #[serde(rename = "tab_group.update")]
    TabGroupUpdate,
    #[serde(rename = "workspace.place")]
    WorkspacePlace,
    #[serde(rename = "workspace.placement.list")]
    WorkspacePlacementList,
    #[serde(rename = "workspace.update")]
    WorkspaceUpdate,
    #[serde(rename = "workspace.agent_folder.set")]
    WorkspaceAgentFolderSet,
    #[serde(rename = "workspace.agent_start.get")]
    WorkspaceAgentStartGet,
    #[serde(rename = "workspace.open_url")]
    WorkspaceOpenUrl,
    #[serde(rename = "workspace_group.create")]
    WorkspaceGroupCreate,
    #[serde(rename = "workspace_group.delete")]
    WorkspaceGroupDelete,
    #[serde(rename = "workspace_group.list")]
    WorkspaceGroupList,
    #[serde(rename = "workspace_group.move")]
    WorkspaceGroupMove,
    #[serde(rename = "workspace_group.update")]
    WorkspaceGroupUpdate,
    #[serde(rename = "workspace_log.append")]
    WorkspaceLogAppend,
    #[serde(rename = "workspace_log.clear")]
    WorkspaceLogClear,
    #[serde(rename = "workspace_log.list")]
    WorkspaceLogList,
    #[serde(rename = "workspace_checklist.add")]
    WorkspaceChecklistAdd,
    #[serde(rename = "workspace_checklist.list")]
    WorkspaceChecklistList,
    #[serde(rename = "workspace_checklist.remove")]
    WorkspaceChecklistRemove,
    #[serde(rename = "workspace_checklist.update")]
    WorkspaceChecklistUpdate,
    #[serde(rename = "workspace_progress.clear")]
    WorkspaceProgressClear,
    #[serde(rename = "workspace_progress.set")]
    WorkspaceProgressSet,
    #[serde(rename = "workspace_status.clear")]
    WorkspaceStatusClear,
    #[serde(rename = "workspace_status.list")]
    WorkspaceStatusList,
    #[serde(rename = "workspace_status.set")]
    WorkspaceStatusSet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationClass {
    Read,
    Mutation,
    StreamOpen,
    ConnectionControl,
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LocalOperation {
    #[serde(rename = "sidebar_plugin.list")]
    SidebarPluginList,
    #[serde(rename = "sidebar_plugin.install")]
    SidebarPluginInstall,
    #[serde(rename = "sidebar_plugin.use")]
    SidebarPluginUse,
    #[serde(rename = "sidebar_plugin.update")]
    SidebarPluginUpdate,
    #[serde(rename = "sidebar_plugin.remove")]
    SidebarPluginRemove,
    #[serde(rename = "sidebar_plugin.use_builtin")]
    SidebarPluginUseBuiltin,
}

impl LocalOperation {
    pub const fn class(self) -> OperationClass {
        OperationClass::Local
    }
}

mod class;
mod envelope;
mod hex;
mod journal;
mod name_index;
pub use name_index::{PublicSlotIndexes, resolve_name};
#[cfg(test)]
#[path = "resource/wire_name_tests.rs"]
mod resource_operation_wire_name_tests;
mod scope;
mod wire_decimal;
mod wire_name;

pub use envelope::{
    RequestEnvelope, ResourceCursor, ResponseEnvelope, StreamEndEnvelope, StreamEndReason,
    StreamItemEnvelope,
};
use hex::encode_hex;
pub use journal::{ResourceDelta, ResourceDeltaBatch, ResourceJournal};
pub use wire_decimal::WireDecimal;

macro_rules! public_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub const PREFIX: &'static str = $prefix;

            pub fn random() -> Result<Self, ResourceError> {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes).map_err(|_| ResourceError::allocation($prefix))?;
                Ok(Self(format!("{}_{}", $prefix, encode_hex(bytes))))
            }

            pub fn parse(value: impl Into<String>) -> Result<Self, ResourceError> {
                let value = value.into();
                let payload = value
                    .strip_prefix(concat!($prefix, "_"))
                    .ok_or_else(|| ResourceError::invalid_id(stringify!($name), &value))?;
                if payload.len() != 32
                    || !payload
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                {
                    return Err(ResourceError::invalid_id(stringify!($name), &value));
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.debug_tuple(stringify!($name)).field(&self.0).finish()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                Self::parse(value).map_err(serde::de::Error::custom)
            }
        }
    };
}

public_id!(MachinePublicId, "machine");
public_id!(SessionPublicId, "session");
public_id!(WorkspacePublicId, "ws");
public_id!(ScreenPublicId, "screen");
public_id!(PanePublicId, "pane");
public_id!(TabPublicId, "tab");
public_id!(TerminalPublicId, "term");
public_id!(BrowserPublicId, "browser");
public_id!(ClientPublicId, "client");
public_id!(SplitPublicId, "split");
public_id!(StreamPublicId, "stream");
public_id!(NotificationPublicId, "notification");
public_id!(AgentPublicId, "agent");
public_id!(FrontendProjectionPublicId, "projection");
public_id!(PairingRequestPublicId, "pairing");
public_id!(SidebarViewPublicId, "sidebar_view");
public_id!(SidebarPluginPublicId, "sidebar_plugin");

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabResourceIdentity {
    pub tab_id: TabPublicId,
    pub content_id: ContentPublicId,
}

impl TabResourceIdentity {
    pub fn new(tab_id: TabPublicId, content_id: ContentPublicId) -> Self {
        Self { tab_id, content_id }
    }

    pub fn persisted_terminal(tab_id: TabPublicId, terminal_id: TerminalPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Terminal(terminal_id))
    }

    pub fn persisted_browser(tab_id: TabPublicId, browser_id: BrowserPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Browser(browser_id))
    }

    pub fn terminal(terminal_id: Option<TerminalPublicId>) -> Result<Self, ResourceError> {
        let terminal_id = match terminal_id {
            Some(terminal_id) => terminal_id,
            None => TerminalPublicId::random()?,
        };
        Ok(Self::persisted_terminal(TabPublicId::random()?, terminal_id))
    }

    pub fn browser() -> Result<Self, ResourceError> {
        Ok(Self::persisted_browser(TabPublicId::random()?, BrowserPublicId::random()?))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "lowercase")]
pub enum ContentPublicId {
    Terminal(TerminalPublicId),
    Browser(BrowserPublicId),
}

impl ContentPublicId {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Terminal(id) => id.as_str(),
            Self::Browser(id) => id.as_str(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    Current,
    Id(String),
    Name(String),
}

impl Selector {
    /// Parses one selector word. `current` is the session's focused object
    /// (the daemon has no caller; the CLI puts the caller's ids in place of
    /// `current` itself). A full public id and a unique id prefix of at
    /// least [`MIN_ID_PREFIX_DIGITS`] hex digits (`pane_3f0a`, which was
    /// never a name) are ids: the resolver expands a
    /// prefix to the full id ([`id_prefix_parts`]). `focused`, a bare id
    /// (the 32 hex digits without the prefix, [`is_bare_id`]) and a
    /// terminal's host id stay names, as they were: the resolver takes them
    /// as `current` or as ids only when no object has that name, so a
    /// request that selected a named object still selects it. `name:`
    /// forces a name.
    pub fn parse(value: &str) -> Result<Self, ResourceError> {
        if let Some(name) = value.strip_prefix("name:") {
            return Ok(Self::Name(name.to_string()));
        }
        if value == "current" {
            return Ok(Self::Current);
        }
        if is_registered_public_id(value) || id_prefix_parts(value).is_some() {
            return Ok(Self::Id(value.to_string()));
        }
        if let Some(reason) = mistyped_id_reason(value) {
            return Err(ResourceError::validation_invalid(None, reason));
        }
        if value.contains('_') || is_reserved_selector_token(value) {
            return Err(ResourceError::validation_invalid(
                None,
                format!(
                    "{value} is not an id, and a name with _ or a command word needs the \
                     name: prefix: pass name:{value}"
                ),
            ));
        }
        Ok(Self::Name(value.to_string()))
    }
}

/// Every public id prefix, with the CLI scope that lists such ids (if any).
const PUBLIC_ID_PREFIXES: &[(&str, Option<&str>)] = &[
    ("machine", Some("machine")),
    ("session", Some("session")),
    ("ws", Some("workspace")),
    ("screen", Some("screen")),
    ("pane", Some("pane")),
    ("tab", Some("tab")),
    ("term", Some("terminal")),
    ("browser", Some("browser")),
    ("client", None),
    ("split", None),
    ("stream", None),
    ("notification", Some("notification")),
    ("agent", Some("agent")),
    ("projection", None),
    ("pairing", None),
    ("sidebar_view", None),
    ("sidebar_plugin", None),
];

<<<<<<< ours
/// The longest id payload: 32 lowercase hex digits.
const ID_PAYLOAD_LEN: usize = 32;
=======
/// Every public id prefix, with the CLI scope that lists such ids (if any).
const PUBLIC_ID_PREFIXES: &[(&str, Option<&str>)] = &[
    ("machine", Some("machine")),
    ("session", Some("session")),
    ("ws", Some("workspace")),
    ("screen", Some("screen")),
    ("pane", Some("pane")),
    ("tab", Some("tab")),
    ("term", Some("terminal")),
    ("browser", Some("browser")),
    ("client", None),
    ("split", None),
    ("stream", None),
    ("notification", Some("notification")),
    ("agent", Some("agent")),
    ("projection", None),
    ("pairing", None),
    ("sidebar_view", None),
    ("sidebar_plugin", None),
];

fn is_registered_public_id(value: &str) -> bool {
    let Some((prefix, payload)) = value.rsplit_once('_') else {
        return false;
    };
    PUBLIC_ID_PREFIXES.iter().any(|(known, _)| *known == prefix)
        && payload.len() == 32
        && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
>>>>>>> theirs

<<<<<<< ours
/// The fewest hex digits of an id prefix (`pane_3f0a`), as acpmux's chat
/// ids: a shorter prefix could select another object once its own closes.
pub const MIN_ID_PREFIX_DIGITS: usize = 4;
=======
/// Why `value`, which starts with a public id prefix (`term_`, `ws_`, ...),
/// is not an id (wrong length, uppercase or other characters), with where
/// real ids come from; `None` for a value without such a prefix. An agent
/// that copies an id wrong gets this instead of the name rules.
fn mistyped_id_reason(value: &str) -> Option<String> {
    let (prefix, payload) = value.rsplit_once('_')?;
    let (_, scope) = PUBLIC_ID_PREFIXES.iter().find(|(known, _)| *known == prefix)?;
    let hex = payload.bytes().all(|byte| byte.is_ascii_hexdigit());
    let shape = if !hex || payload.is_empty() {
        format!("an id is {prefix}_ and 32 hex digits (0-9 and a-f, lowercase)")
    } else if payload.len() == 32 {
        format!("ids are lowercase: {prefix}_ and 32 hex digits in lowercase")
    } else {
        format!("an id is {prefix}_ and 32 hex digits, and this one has {}", payload.len())
    };
    let source = match scope {
        Some(scope) => format!("copy one from `cmux {scope} list --json`, or "),
        None => String::new(),
    };
    Some(format!("{value} is not an id: {shape}; {source}pass name:{value} for a name"))
}

pub fn resolve_name<T: Clone>(
    kind: &str,
    selector: &str,
    candidates: impl IntoIterator<Item = (String, Option<String>, T)>,
) -> Result<T, ResourceError> {
    let mut matches = candidates
        .into_iter()
        .filter(|(_, name, _)| name.as_deref() == Some(selector))
        .collect::<Vec<_>>();
    match matches.len() {
        0 => Err(ResourceError::not_found(kind, selector)),
        1 => Ok(matches.pop().expect("one match").2),
        _ => {
            let mut ids = matches.into_iter().map(|(id, _, _)| id).collect::<Vec<_>>();
            ids.sort();
            Err(ResourceError::ambiguous(kind, selector, ids))
        }
    }
}
>>>>>>> theirs

/// The id prefixes whose ids the resolver expands from a unique prefix:
/// the topology and content kinds. A session, machine, notification or
/// agent id with digits missing stays a mistyped id.
pub const EXPANDED_ID_PREFIXES: &[&str] = &["ws", "screen", "pane", "tab", "term", "browser"];

fn is_lower_hex(payload: &str) -> bool {
    payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `(prefix, payload)` of a unique-prefix selector: one of
/// [`EXPANDED_ID_PREFIXES`] and [`MIN_ID_PREFIX_DIGITS`] to 31 lowercase
/// hex digits (`pane_3f0a`). `None` for a full id, a shorter or longer
/// payload, another prefix, or other characters.
pub fn id_prefix_parts(value: &str) -> Option<(&str, &str)> {
    let (prefix, payload) = value.rsplit_once('_')?;
    (EXPANDED_ID_PREFIXES.contains(&prefix)
        && (MIN_ID_PREFIX_DIGITS..ID_PAYLOAD_LEN).contains(&payload.len())
        && is_lower_hex(payload))
    .then_some((prefix, payload))
}

/// Whether `value` is a bare id: 32 lowercase hex digits with no prefix.
/// It names the object whose public id has that payload (`pane_<value>`)
/// or, for a terminal, the terminal whose host id it is (the raw protocol's
/// `terminal_id`).
pub fn is_bare_id(value: &str) -> bool {
    value.len() == ID_PAYLOAD_LEN && is_lower_hex(value)
}

/// The message for a unique-prefix selector that no id starts with. A
/// mistyped id (one digit dropped) reads as a prefix, so the message names
/// the id shape and where such ids come from, as the old refusal did.
pub fn unmatched_id_prefix_message(kind: &str, value: &str) -> String {
    let (prefix, payload) = value.rsplit_once('_').unwrap_or((kind, value));
    let source = PUBLIC_ID_PREFIXES
        .iter()
        .find(|(known, _)| *known == prefix)
        .and_then(|(_, scope)| *scope)
        .map(|scope| format!("; copy one from `cmux {scope} list --json`"))
        .unwrap_or_default();
    format!(
        "no {kind} id starts with {value}: an id is {prefix}_ and 32 hex digits, and this \
         one has {}{source}, or pass name:{value} for a name",
        payload.len()
    )
}

<<<<<<< ours
fn is_registered_public_id(value: &str) -> bool {
    let Some((prefix, payload)) = value.rsplit_once('_') else {
        return false;
    };
    PUBLIC_ID_PREFIXES.iter().any(|(known, _)| *known == prefix)
        && payload.len() == 32
        && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
=======
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locally_emittable_error_codes_exactly_match_the_catalog() {
        let catalog: Value =
            serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json"))
                .unwrap();
        let mut declared =
            catalog["errors"].as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>();
        let mut emitted = RESOURCE_ERROR_CODES.to_vec();
        declared.sort_unstable();
        emitted.sort_unstable();
        assert_eq!(emitted, declared);
        for code in declared {
            assert!(is_catalog_error_code(code));
        }
    }

    #[test]
    fn catalog_error_details_and_retryability_are_recursively_enforced() {
        let cursor = json!({"generation":"generation","revision":"4"});
        let cases = [
            (
                "confirmation.required",
                json!({
                    "confirmation_token":"layout-confirmation-token",
                    "revision":"4",
                    "closes_panes":[format!("pane_{}", "0".repeat(32))]
                }),
                false,
            ),
            (
                "creation.conflict",
                json!({
                    "correlation_key":"create-42",
                    "existing_operation":"workspace.create",
                    "requested_operation":"screen.create",
                    "existing_fingerprint":"fingerprint-a",
                    "requested_fingerprint":"fingerprint-b",
                }),
                false,
            ),
            (
                "cursor.gap",
                json!({
                    "requested":cursor,
                    "current":cursor,
                    "oldest_revision":"2",
                }),
                true,
            ),
            (
                "cursor.invalid",
                json!({"requested":cursor,"current":cursor,"reason":"ahead"}),
                false,
            ),
            (
                "idempotency.conflict",
                json!({"idempotency_key":"key","committed_operation":"workspace.rename"}),
                false,
            ),
            ("local.io", json!({"path":"/tmp/socket","reason":"closed"}), false),
            (
                "mutation.indeterminate",
                json!({
                    "idempotency_key":"key",
                    "operation":"browser.navigate",
                    "recovery":"inspect_state_then_retry_with_new_key",
                }),
                false,
            ),
            (
                "operation.failed",
                json!({"operation":"workspace.close","reason":"failed","extra":{"errno":5}}),
                false,
            ),
            (
                "operation.unsupported",
                json!({"capability":"session-journal-v1","action":"restart_session"}),
                false,
            ),
            (
                "resource.not_found",
                json!({"scope":"terminal","id":format!("term_{}", "0".repeat(32))}),
                false,
            ),
            ("revision.conflict", json!({"expected":"3","actual":"4"}), true),
            (
                "selector.ambiguous",
                json!({"scope":"workspace","selector":"name:api","candidates":["a","b"]}),
                false,
            ),
            (
                "selector.invalid",
                json!({"scope":"workspace","selector":"_","reason":"invalid"}),
                false,
            ),
            ("selector.not_found", json!({"scope":"workspace","selector":"name:missing"}), false),
            (
                "selector.wrong_parent",
                json!({
                    "scope":"pane",
                    "selector":"current",
                    "parent_scope":"screen",
                    "expected_parent":"screen-a",
                    "actual_parent":"screen-b",
                }),
                false,
            ),
            ("transport.closed", json!({"reason":"closed"}), true),
            ("validation.invalid", json!({"field":"rows","reason":"must be positive"}), false),
        ];
        for (code, details, retryable) in cases {
            assert!(catalog_error_contract_matches(code, &details, retryable), "{code}: {details}");
        }
        assert!(!catalog_error_contract_matches(
            "operation.failed",
            &json!({"operation":"workspace.close","required_context":"connection"}),
            false,
        ));
        assert!(!catalog_error_contract_matches(
            "transport.closed",
            &json!({"reason":"closed"}),
            false,
        ));
    }

    #[test]
    fn ids_reject_uppercase_wrong_prefix_and_wrong_width() {
        let id = WorkspacePublicId::random().unwrap();
        assert_eq!(WorkspacePublicId::parse(id.to_string()).unwrap(), id);
        assert!(WorkspacePublicId::parse(format!("ws_{}", "A".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("term_{}", "a".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("ws_{}", "a".repeat(31))).is_err());
    }

    #[test]
    fn projection_and_pairing_ids_use_the_canonical_prefix_registry() {
        let payload = "0".repeat(32);
        assert_eq!(
            FrontendProjectionPublicId::parse(format!("projection_{payload}")).unwrap().as_str(),
            format!("projection_{payload}")
        );
        assert!(PairingRequestPublicId::parse(format!("pairing_{payload}")).is_ok());
    }

    #[test]
    fn w4j_a_mistyped_id_says_it_is_not_an_id_and_where_ids_come_from() {
        // A Codex interop proof run dropped the last digit of a terminal id and
        // got "reserved or ambiguous names must use the name: prefix", then
        // guessed `terminal_id:`, `id:` and bare hex forms for minutes.
        let short = format!("term_{}", "6".repeat(31));
        let error = Selector::parse(&short).unwrap_err();
        assert_eq!(error.code, "validation.invalid");
        assert!(error.message.contains(&short), "{}", error.message);
        assert!(error.message.contains("32 hex"), "{}", error.message);
        assert!(error.message.contains("cmux terminal list"), "{}", error.message);
        let upper = format!("ws_{}", "A".repeat(32));
        let error = Selector::parse(&upper).unwrap_err();
        assert!(error.message.contains("lowercase"), "{}", error.message);
        assert!(error.message.contains("cmux workspace list"), "{}", error.message);
        // A name with an underscore still names the escape.
        let error = Selector::parse("hello_world").unwrap_err();
        assert!(error.message.contains("name:"), "{}", error.message);
    }

    /// `cmux terminal term_zzz show` (bench rounds 1 and 3) said "reserved or
    /// ambiguous names must use the name: prefix". A word with an id prefix is
    /// a mistyped id: say so, and where ids come from.
    #[test]
    fn w4j_an_id_prefix_with_a_bad_payload_is_a_mistyped_id() {
        for value in ["term_zzz", "pane_", "ws_Q1", "tab_0123456789abcdef0123456789abcdeg"] {
            let error = Selector::parse(value).unwrap_err();
            assert_eq!(error.code, "validation.invalid");
            assert!(error.message.contains(&format!("{value} is not an id")), "{}", error.message);
            assert!(error.message.contains("32 hex"), "{}", error.message);
            assert!(error.message.contains(&format!("name:{value}")), "{}", error.message);
        }
        let error = Selector::parse("term_zzz").unwrap_err();
        assert!(error.message.contains("cmux terminal list"), "{}", error.message);
        // A name with an underscore and no id prefix still names the escape.
        let error = Selector::parse("my_tab").unwrap_err();
        assert!(error.message.contains("name:my_tab"), "{}", error.message);
    }

    #[test]
    fn name_escape_selects_reserved_and_id_shaped_names() {
        assert_eq!(Selector::parse("current").unwrap(), Selector::Current);
        assert_eq!(Selector::parse("name:current").unwrap(), Selector::Name("current".into()));
        assert!(matches!(
            Selector::parse(&WorkspacePublicId::random().unwrap().to_string()).unwrap(),
            Selector::Id(_)
        ));
        assert_eq!(
            Selector::parse(&format!("name:ws_{}", "a".repeat(32))).unwrap(),
            Selector::Name(format!("ws_{}", "a".repeat(32)))
        );
        assert_eq!(
            Selector::parse("name:hello_world").unwrap(),
            Selector::Name("hello_world".into())
        );
        assert_eq!(Selector::parse("hello_world").unwrap_err().code, "validation.invalid");
        for reserved in ["create", "show", "close", "screen", "pane", "tab"] {
            assert_eq!(Selector::parse(reserved).unwrap_err().code, "validation.invalid");
            assert_eq!(
                Selector::parse(&format!("name:{reserved}")).unwrap(),
                Selector::Name(reserved.into())
            );
        }
        for legacy in ["send-key", "clear-history", "vt-state", "focus-direction"] {
            assert_eq!(Selector::parse(legacy).unwrap(), Selector::Name(legacy.into()));
        }
    }

    #[test]
    fn terminal_public_identity_is_independent_from_host_uuid_bits() {
        let terminal = TerminalPublicId::parse("term_ffffffffffffffffffffffffffffffff").unwrap();
        let tab = TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
        let identity = TabResourceIdentity::persisted_terminal(tab, terminal.clone());
        assert_eq!(identity.content_id, ContentPublicId::Terminal(terminal));
    }

    #[test]
    fn duplicate_names_return_every_candidate_without_selecting() {
        let result = resolve_name(
            "workspace",
            "api",
            [("ws_1".into(), Some("api".into()), 1), ("ws_2".into(), Some("api".into()), 2)],
        )
        .unwrap_err();
        assert_eq!(result.code, "selector.ambiguous");
        assert_eq!(result.details["candidates"], json!(["ws_1", "ws_2"]));
    }

    #[test]
    fn journal_revision_is_per_atomic_commit_and_detects_gaps() {
        let mut journal = ResourceJournal::new("generation".into(), 8);
        assert_eq!(
            journal
                .commit(vec![
                    ("pane.created".into(), json!({"id":"pane"})),
                    ("tab.created".into(), json!({"id":"tab"})),
                ])
                .unwrap(),
            9
        );
        let batches = journal.after(8).unwrap();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].previous_revision.get(), 8);
        assert_eq!(batches[0].revision.get(), 9);
        assert_eq!(batches[0].deltas[0].sequence, 0);
        assert_eq!(batches[0].deltas[1].sequence, 1);
    }

    #[test]
    fn wire_decimals_are_strings_and_reject_noncanonical_values() {
        assert_eq!(serde_json::to_value(WireDecimal::new(42)).unwrap(), json!("42"));
        assert_eq!(serde_json::from_value::<WireDecimal>(json!("0")).unwrap().get(), 0);
        for invalid in
            [json!(42), json!(""), json!("01"), json!("-1"), json!("18446744073709551616")]
        {
            assert!(serde_json::from_value::<WireDecimal>(invalid).is_err());
        }
    }

    #[test]
    fn terminal_multiview_uses_a_new_public_protocol_version() {
        assert_eq!(PROTOCOL, "cmux.protocol/2");
    }

    #[test]
    fn requests_enforce_envelope_and_idempotency_rules() {
        let read: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "read-1",
            "operation": "workspace.list",
            "params": {}
        }))
        .unwrap();
        read.validate().unwrap();

        let mutation: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "write-1",
            "operation": "workspace.create",
            "params": {"name":"api"},
            "idempotency_key": "create-api"
        }))
        .unwrap();
        mutation.validate().unwrap();

        let mut missing_key = mutation;
        missing_key.idempotency_key = None;
        assert_eq!(missing_key.validate().unwrap_err().code, "validation.invalid");

        let mut read_with_key = read;
        read_with_key.idempotency_key = Some("unexpected".into());
        assert_eq!(read_with_key.validate().unwrap_err().code, "validation.invalid");

        for invalid in [
            "".to_string(),
            " \u{00a0}\u{3000}".to_string(),
            "key\nwith-control".to_string(),
            "key\u{0085}with-control".to_string(),
            "\u{00e9}".repeat(65),
        ] {
            let invalid_request: RequestEnvelope = serde_json::from_value(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "write-invalid",
                "operation": "workspace.create",
                "params": {"name":"api"},
                "idempotency_key": invalid,
            }))
            .unwrap();
            let error = invalid_request.validate().unwrap_err();
            assert_eq!(error.code, "validation.invalid");
            assert_eq!(error.details["field"], "idempotency_key");
        }

        for valid in [
            "key".to_string(),
            " \u{00a0}key\u{3000} ".to_string(),
            "\u{feff}".to_string(),
            "\u{00e9}".repeat(64),
        ] {
            let request: RequestEnvelope = serde_json::from_value(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "write-valid",
                "operation": "workspace.create",
                "params": {"name":"api"},
                "idempotency_key": valid,
            }))
            .unwrap();
            request.validate().unwrap();
        }
    }

    #[test]
    fn operation_classes_keep_stream_and_connection_control_out_of_durable_idempotency() {
        for operation in [
            ResourceOperation::SessionEvents,
            ResourceOperation::SessionJournalSubscribe,
            ResourceOperation::TerminalAttach,
            ResourceOperation::BrowserAttach,
            ResourceOperation::SidebarViewAttach,
        ] {
            assert_eq!(operation.class(), OperationClass::StreamOpen);
        }
        assert_eq!(ResourceOperation::RequestCancel.class(), OperationClass::ConnectionControl);
        assert_eq!(ResourceOperation::StreamCancel.class(), OperationClass::ConnectionControl);
        let connection_control = [
            ResourceOperation::ClientMetadataUpdate,
            ResourceOperation::ClientSizingSet,
            ResourceOperation::ClientSizingRelease,
            ResourceOperation::ClientCellPixelsSet,
            ResourceOperation::ClientDetach,
            ResourceOperation::TerminalRendererGrantCreate,
            ResourceOperation::TerminalViewerResize,
            ResourceOperation::TerminalViewerRelease,
            ResourceOperation::BrowserViewerResize,
            ResourceOperation::BrowserViewerRelease,
        ];
        for operation in connection_control {
            assert_eq!(operation.class(), OperationClass::ConnectionControl);
        }
        assert_eq!(ResourceOperation::WorkspaceList.class(), OperationClass::Read);
        assert_eq!(ResourceOperation::WorkspaceCreate.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TabCreateTerminal.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TabCreateBrowser.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TerminalCopy.class(), OperationClass::Read);
        assert_eq!(LocalOperation::SidebarPluginUseBuiltin.class(), OperationClass::Local);

        for operation in [
            ResourceOperation::SessionEvents,
            ResourceOperation::SessionJournalSubscribe,
            ResourceOperation::RequestCancel,
            ResourceOperation::StreamCancel,
            ResourceOperation::ClientMetadataUpdate,
            ResourceOperation::ClientDetach,
        ] {
            let request = RequestEnvelope {
                protocol: PROTOCOL.into(),
                envelope_type: EnvelopeType::Request,
                id: RequestId::parse("class").unwrap(),
                operation,
                params: json!({}),
                idempotency_key: None,
            };
            request.validate().unwrap();
            let mut keyed = request;
            keyed.idempotency_key = Some("forbidden".into());
            assert_eq!(keyed.validate().unwrap_err().code, "validation.invalid");
        }
    }

    #[test]
    fn envelopes_reject_unknown_fields_and_non_string_request_ids() {
        assert!(
            serde_json::from_value::<RequestEnvelope>(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "request",
                "operation": "workspace.list",
                "params": {},
                "extra": true
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<RequestEnvelope>(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": 1,
                "operation": "workspace.list",
                "params": {}
            }))
            .is_err()
        );
    }
>>>>>>> theirs

/// Why `value`, which starts with a public id prefix (`term_`, `ws_`, ...),
/// is not an id (wrong length, uppercase or other characters), with where
/// real ids come from; `None` for a value without such a prefix. An agent
/// that copies an id wrong gets this instead of the name rules.
fn mistyped_id_reason(value: &str) -> Option<String> {
    let (prefix, payload) = value.rsplit_once('_')?;
    let (_, scope) = PUBLIC_ID_PREFIXES.iter().find(|(known, _)| *known == prefix)?;
    let hex = payload.bytes().all(|byte| byte.is_ascii_hexdigit());
    let short_prefix = EXPANDED_ID_PREFIXES.contains(&prefix)
        && is_lower_hex(payload)
        && (1..MIN_ID_PREFIX_DIGITS).contains(&payload.len());
    let shape = if short_prefix {
        format!(
            "an id prefix needs at least {MIN_ID_PREFIX_DIGITS} hex digits of the id, and this \
             one has {}",
            payload.len()
        )
    } else if !hex || payload.is_empty() {
        format!("an id is {prefix}_ and 32 hex digits (0-9 and a-f, lowercase)")
    } else if payload.len() == 32 {
        format!("ids are lowercase: {prefix}_ and 32 hex digits in lowercase")
    } else {
        format!("an id is {prefix}_ and 32 hex digits, and this one has {}", payload.len())
    };
    let source = match scope {
        Some(scope) => format!("copy one from `cmux {scope} list --json`, or "),
        None => String::new(),
    };
    Some(format!("{value} is not an id: {shape}; {source}pass name:{value} for a name"))
}

#[cfg(test)]
mod tests;
