//! The wire name and the method class of every daemon [`Command`].
//!
//! The table below was generated once from the `Command` enum: each variant's
//! name under its `rename_all = "kebab-case"` tag. A new variant gets its row
//! by hand; `wire_name` and `method_class` are matches with no wildcard, so the
//! build fails until the row exists. command_names_tests.rs checks the table
//! against serde's own list of tags.
#![cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "the hang deadlines and wire names are read by hang-watch (p09 073)"
    )
)]

use std::time::Duration;

use super::Command;

/// The kind of work a daemon request does. It picks the request's hang
/// deadline and its latency histogram.
///
/// Chrome watches each unit of work with its own deadline
/// (base/threading/hang_watcher.h, `WatchHangsInScope`, default 10 s); here a
/// request is the unit, and its class sets the deadline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum MethodClass {
    /// Model changes to workspaces, screens, panes and tabs: move, close,
    /// rename, select, group.
    Topology,
    /// Input to, output from and sizing of one terminal.
    TerminalIo,
    /// New terminals, browsers, panes and workspaces; may spawn a process.
    Create,
    /// Read-only state from memory, the registry or a kernel read of a
    /// known process. A read that runs a child process or opens a network
    /// connection is `Other`.
    Query,
    /// Browser tabs, the browser host and the profile and bookmark stores.
    Browser,
    /// Agent sessions, conversations and the Chief.
    Agent,
    /// cmux Cloud: sessions, inbox, conversations and attachments over the
    /// network.
    Cloud,
    /// Streams, lifecycle, machine probes that run child processes or open
    /// local connections (`machine-listening-tcp`, `terminal-ports`) and the
    /// rest.
    Other,
}

impl MethodClass {
    pub(crate) const ALL: [Self; 8] = [
        Self::Topology,
        Self::TerminalIo,
        Self::Create,
        Self::Query,
        Self::Browser,
        Self::Agent,
        Self::Cloud,
        Self::Other,
    ];

    /// The class's name in histogram keys (`request_latency_us.<name>`).
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Topology => "topology",
            Self::TerminalIo => "terminal_io",
            Self::Create => "create",
            Self::Query => "query",
            Self::Browser => "browser",
            Self::Agent => "agent",
            Self::Cloud => "cloud",
            Self::Other => "other",
        }
    }

    /// How long one request of this class may run on its dispatch thread
    /// before the hang watcher reports it. A wait that `may_wait` allows is
    /// not counted (`invalidate_active` around it).
    pub(crate) const fn hang_deadline(self) -> Duration {
        match self {
            Self::TerminalIo | Self::Query => Duration::from_secs(1),
            Self::Topology | Self::Browser => Duration::from_secs(2),
            Self::Create => Duration::from_secs(5),
            Self::Agent | Self::Cloud | Self::Other => Duration::from_secs(10),
        }
    }

    /// Whether a handler of this class may wait on the network, another
    /// process or a stream. Such a handler marks the wait so the hang watcher
    /// does not blame it; the other classes never wait.
    pub(crate) const fn may_wait(self) -> bool {
        match self {
            Self::Create | Self::Browser | Self::Agent | Self::Cloud | Self::Other => true,
            Self::Topology | Self::TerminalIo | Self::Query => false,
        }
    }
}

/// One row of the command table.
#[derive(Clone, Copy, Debug)]
pub(super) struct CommandName {
    /// The `Command` variant, as written in the enum.
    pub(super) variant: &'static str,
    /// The `cmd` tag on the wire.
    pub(super) wire: &'static str,
    /// Other tags serde accepts for the variant (`#[serde(alias)]`).
    pub(super) aliases: &'static [&'static str],
    pub(super) class: MethodClass,
}

macro_rules! command_table {
    ($($variant:ident => $wire:literal $(| $alias:literal)*, $class:ident;)*) => {
        /// The position of each command's row in [`COMMANDS`].
        #[repr(u16)]
        enum CommandIndex {
            $($variant,)*
        }

        impl Command {
            /// The canonical `cmd` tag of this command.
            pub(super) fn wire_name(&self) -> &'static str {
                match self {
                    $(Self::$variant { .. } => $wire,)*
                }
            }

            /// This command's row in [`COMMANDS`].
            pub(super) fn wire_index(&self) -> u16 {
                match self {
                    $(Self::$variant { .. } => CommandIndex::$variant as u16,)*
                }
            }

            pub(super) fn method_class(&self) -> MethodClass {
                match self {
                    $(Self::$variant { .. } => MethodClass::$class,)*
                }
            }

            /// This command's row in [`COMMANDS`]: the method id its
            /// `daemon.request` trace slice carries.
            pub(super) fn method_id(&self) -> u16 {
                match self {
                    $(Self::$variant { .. } => MethodIndex::$variant as u16,)*
                }
            }
        }

        impl Command {
            /// The method id and class of the command whose `cmd` tag (or
            /// alias) is `name`; None for a name no command has.
            pub(super) fn method_of_wire(name: &str) -> Option<(u16, MethodClass)> {
                match name {
                    $($wire $(| $alias)* => {
                        Some((MethodIndex::$variant as u16, MethodClass::$class))
                    })*
                    _ => None,
                }
            }
        }

        /// Each variant's index in [`COMMANDS`], numbered by the compiler.
        enum MethodIndex {
            $($variant,)*
        }

        /// Every command, in the enum's order.
        pub(super) const COMMANDS: &[CommandName] = &[
            $(CommandName {
                variant: stringify!($variant),
                wire: $wire,
                aliases: &[$($alias),*],
                class: MethodClass::$class,
            },)*
        ];
    };
}

impl Command {
    /// Whether the handler blocks by design for a time the request names
    /// (`wait-for` waits up to its `timeout_ms`). The request watchdog does
    /// not count such a run as slow (Chrome: a `ScopedBlockingCall` with
    /// `WILL_BLOCK` invalidates the hang watch, base/threading/hang_watcher.cc).
    pub(super) fn waits_by_design(&self) -> bool {
        matches!(self, Self::WaitFor { .. })
    }
}

// `Variant => "wire-name" | "alias", Class;`
command_table! {
    Identify => "identify", Query;
    BrowserHostProvider => "browser-host-provider", Query;
    SubscribeActivity => "subscribe-activity", Other;
    UrlOpenSubscribe => "url-open-subscribe", Browser;
    UrlOpen => "url-open", Browser;
    ChiefInspect => "chief-inspect", Agent;
    UrlOpenClaim => "url-open-claim", Browser;
    UrlOpenResult => "url-open-result", Browser;
    TerminalClipboardSubscribe => "terminal-clipboard-subscribe", TerminalIo;
    TerminalClipboardReply => "terminal-clipboard-reply", TerminalIo;
    PasteImage => "paste-image", TerminalIo;
    ServerStats => "server-stats", Query;
    DebugDaemonLocks => "debug-daemon-locks", Query;
    ServerThreads => "server-threads", Query;
    ServerBlocking => "server-blocking", Query;
    TraceStart => "trace-start", Other;
    TraceStop => "trace-stop", Other;
    TraceStatus => "trace-status", Other;
    SetTerminalCommandHistory => "set-terminal-command-history", TerminalIo;
    ListTerminalCommands => "list-terminal-commands", Query;
    DeleteTerminalCommands => "delete-terminal-commands", TerminalIo;
    ShutdownDaemon => "shutdown-daemon", Other;
    Ping => "ping", Query;
    SetClientInfo => "set-client-info", Other;
    ListClients => "list-clients", Query;
    MachineUsage => "machine-usage", Query;
    MachineListeningTcp => "machine-listening-tcp", Other;
    RegisterBrowserProvider => "register-browser-provider", Browser;
    GetBrowserProvider => "get-browser-provider", Browser;
    UnregisterBrowserProvider => "unregister-browser-provider", Browser;
    ListTerminals => "list-terminals", Query;
    TerminalEvents => "terminal-events", TerminalIo;
    SetClientSizing => "set-client-sizing", TerminalIo;
    PairingResponse => "pairing-response", Other;
    DetachClient => "detach-client", Other;
    ReattachView => "reattach-view", TerminalIo;
    SetSizePolicy => "set-size-policy", TerminalIo;
    SetSizeCounts => "set-size-counts", TerminalIo;
    GetSizeState => "get-size-state", Query;
    GetHostSizePolicy => "get-host-size-policy", Query;
    SetHostSizePolicy => "set-host-size-policy", TerminalIo;
    NoteSizeActivity => "note-size-activity", TerminalIo;
    ReloadConfig => "reload-config", Other;
    SetWindowTitle => "set-window-title", Topology;
    ClearWindowTitle => "clear-window-title", Topology;
    ListWorkspaces => "list-workspaces", Query;
    GetFrontendProjection => "get-frontend-projection", Query;
    PutFrontendProjection => "put-frontend-projection", Topology;
    JournalFrontendEvent => "journal-frontend-event", Other;
    ExportLayout => "export-layout", Query;
    ApplyLayout => "apply-layout", Topology;
    Send => "send", TerminalIo;
    ReadScreen => "read-screen", TerminalIo;
    ClearHistory => "clear-history", TerminalIo;
    ReadScrollback => "read-scrollback", TerminalIo;
    SidebarPlugin => "sidebar-plugin", Create;
    WaitFor => "wait-for", Other;
    Run => "run", Create;
    CreateSurfaceWithReceipt => "create-surface-with-receipt", Create;
    SendKey => "send-key", TerminalIo;
    Copy => "copy", TerminalIo;
    Ids => "ids", Query;
    Notify => "notify", Topology;
    ListAgents => "list-agents", Query;
    ReportAgent => "report-agent", Agent;
    VtState => "vt-state", TerminalIo;
    MintTerminalRenderer => "mint-terminal-renderer", TerminalIo;
    MintTerminalRendererByTerminal => "mint-terminal-renderer-by-terminal", TerminalIo;
    ResolveTerminal => "resolve-terminal", Query;
    CloseTerminal => "close-terminal", Topology;
    SetTerminalIdlePolicy => "set-terminal-idle-policy", TerminalIo;
    SetTerminalKeep => "set-terminal-keep", TerminalIo;
    TerminalResumeCommand => "terminal-resume-command", TerminalIo;
    NewTab => "new-tab", Create;
    NewConversationTab => "new-conversation-tab", Create;
    BindConversationTabSession => "bind-conversation-tab-session", Agent;
    NewFrontendBrowserTab => "new-frontend-browser-tab", Create;
    RestartTab => "restart-tab", Create;
    ParkTabs => "park-tabs", Topology;
    UpdateFrontendBrowserTab => "update-frontend-browser-tab", Browser;
    SetFrontendBrowserHistory => "set-frontend-browser-history", Browser;
    GetFrontendBrowserHistory => "get-frontend-browser-history", Browser;
    NewRemoteTerminalTab => "new-remote-terminal-tab", Create;
    UpdateRemoteTerminalTab => "update-remote-terminal-tab", TerminalIo;
    RemoteTerminalSnapshot => "remote-terminal-snapshot", TerminalIo;
    NewBrowserTab => "new-browser-tab", Create;
    SetCellPixels => "set-cell-pixels", TerminalIo;
    GetCellPixels => "get-cell-pixels", Query;
    BrowserFramePresented => "browser-frame-presented", Browser;
    BrowserMouse => "browser-mouse", Browser;
    BrowserMouseGuarded => "browser-mouse-guarded", Browser;
    BrowserWheel => "browser-wheel", Browser;
    BrowserWheelGuarded => "browser-wheel-guarded", Browser;
    BrowserKey => "browser-key", Browser;
    BrowserKeyPress => "browser-key-press", Browser;
    BrowserInsertText => "browser-insert-text", Browser;
    BrowserNavigate => "browser-navigate", Browser;
    BrowserBack => "browser-back", Browser;
    BrowserForward => "browser-forward", Browser;
    BrowserReload => "browser-reload", Browser;
    BrowserActivate => "browser-activate", Browser;
    NewWorkspace => "new-workspace", Create;
    CreateWorkspace => "create-workspace", Create;
    CreateTerminal => "create-terminal", Create;
    NewScreen => "new-screen", Create;
    SetScreenMetadata => "set-screen-metadata", Topology;
    SetScreenPinned => "set-screen-pinned", Topology;
    MoveScreen => "move-screen", Topology;
    CreateScreenGroup => "create-screen-group", Topology;
    UpdateScreenGroup => "update-screen-group", Topology;
    AddScreensToScreenGroup => "add-screens-to-screen-group", Topology;
    RemoveScreensFromScreenGroup => "remove-screens-from-screen-group", Topology;
    MoveScreenGroup => "move-screen-group", Topology;
    UngroupScreenGroup => "ungroup-screen-group", Topology;
    CloseScreenGroup => "close-screen-group", Topology;
    ListSavedScreenGroups => "list-saved-screen-groups", Query;
    SaveScreenGroup => "save-screen-group", Topology;
    UnsaveScreenGroup => "unsave-screen-group", Topology;
    DeleteSavedScreenGroup => "delete-saved-screen-group", Topology;
    ReopenSavedScreenGroup => "reopen-saved-screen-group", Create;
    NewPane => "new-pane", Create;
    NewPaneRight => "new-pane-right", Create;
    Split => "split", Create;
    SetRatio => "set-ratio", Topology;
    SetSplitRatio => "set-split-ratio", Topology;
    SetViewportPaneWidth => "set-viewport-pane-width", Topology;
    SetColumnDock => "set-column-dock", Topology;
    UndoLayout => "undo-layout", Topology;
    PaneNeighbor => "pane-neighbor", Query;
    FocusDirection => "focus-direction", Topology;
    SwapPane => "swap-pane", Topology;
    ZoomPane => "zoom-pane", Topology;
    ProcessInfo => "process-info", Query;
    TerminalPorts => "terminal-ports", Other;
    TerminalResources => "terminal-resources", Query;
    MoveTerminal => "move-terminal", Topology;
    MoveTab => "move-tab", Topology;
    ListTabGroups => "list-tab-groups", Query;
    CreateTabGroup => "create-tab-group", Topology;
    UpdateTabGroup => "update-tab-group", Topology;
    AddTabsToTabGroup => "add-tabs-to-tab-group", Topology;
    RemoveTabsFromTabGroup => "remove-tabs-from-tab-group", Topology;
    MoveTabGroup => "move-tab-group", Topology;
    MoveTabGroupToSplit => "move-tab-group-to-split", Topology;
    MoveTabGroupToColumn => "move-tab-group-to-column", Topology;
    MoveTabGroupToNewWorkspace => "move-tab-group-to-new-workspace", Create;
    UngroupTabGroup => "ungroup-tab-group", Topology;
    CloseTabGroup => "close-tab-group", Topology;
    ListSavedTabGroups => "list-saved-tab-groups", Query;
    SaveTabGroup => "save-tab-group", Topology;
    UnsaveTabGroup => "unsave-tab-group", Topology;
    DeleteSavedTabGroup => "delete-saved-tab-group", Topology;
    ReopenSavedTabGroup => "reopen-saved-tab-group", Create;
    AckTabNotifications => "ack-tab-notifications", Topology;
    ListNotifications => "list-notifications", Query;
    SetTabPinned => "set-tab-pinned", Topology;
    MoveTabToWorkspace => "move-tab-to-workspace", Topology;
    MoveTabToSplit => "move-tab-to-split", Topology;
    MoveTabToColumn => "move-tab-to-column", Topology;
    NewRow => "new-row", Create;
    SetRowHeights => "set-row-heights", Topology;
    MoveColumn => "move-column", Topology;
    MoveTabToNewWorkspace => "move-tab-to-new-workspace", Create;
    MoveWorkspace => "move-workspace", Topology;
    SetWorkspaceMetadata => "set-workspace-metadata", Topology;
    ListPersonal => "list-personal", Query;
    CreateBrowserProfile => "create-browser-profile", Browser;
    UpdateBrowserProfile => "update-browser-profile", Browser;
    MoveBrowserProfile => "move-browser-profile", Browser;
    DeleteBrowserProfile => "delete-browser-profile", Browser;
    ListBookmarks => "list-bookmarks", Browser;
    CreateBookmark => "create-bookmark", Browser;
    UpdateBookmark => "update-bookmark", Browser;
    MoveBookmark => "move-bookmark", Browser;
    DeleteBookmark => "delete-bookmark", Browser;
    ImportBookmarks => "import-bookmarks", Browser;
    FeedLocalList => "feed-local-list", Other;
    FeedLocalRead => "feed-local-read", Other;
    FeedLocalHandoffBegin => "feed-local-handoff-begin", Other;
    FeedLocalHandoffAbort => "feed-local-handoff-abort", Other;
    FeedLocalHandoffDone => "feed-local-handoff-done", Other;
    PutBlob => "put-blob", Other;
    GetBlob => "get-blob", Query;
    ConversationList => "conversation-list", Agent;
    ConversationCreate => "conversation-create", Agent;
    ConversationSnapshot => "conversation-snapshot", Agent;
    ConversationHistory => "conversation-history", Agent;
    ConversationThread => "conversation-thread", Agent;
    ConversationLinkResolve => "conversation-link-resolve", Agent;
    ConversationInboxOp => "conversation-inbox-op", Agent;
    HomeInbox => "home-inbox", Agent;
    ConversationSearch => "conversation-search", Agent;
    HistorySearch => "history-search", Agent;
    ConversationOp => "conversation-op", Agent;
    ConversationTyping => "conversation-typing", Agent;
    ConversationDraft => "conversation-draft", Agent;
    ConversationBind => "conversation-bind", Agent;
    ConversationAgentToken => "conversation-agent-token", Agent;
    CloudSessionSet => "cloud-session-set", Cloud;
    CloudSessionClear => "cloud-session-clear", Cloud;
    CloudSessionStatus => "cloud-session-status", Cloud;
    CloudHostReplicaSet => "cloud-host-replica-set", Cloud;
    CloudHostReplicaClear => "cloud-host-replica-clear", Cloud;
    CloudHostReplicaStatus => "cloud-host-replica-status", Cloud;
    PageCredential => "page-credential", Browser;
    WsListen => "ws-listen", Browser;
    CloudInboxList => "cloud-inbox-list", Cloud;
    CloudRequestsList => "cloud-requests-list", Cloud;
    CloudSelfhostInfo => "cloud-selfhost-info", Cloud;
    CloudConversationSnapshot => "cloud-conversation-snapshot", Cloud;
    CloudConversationHistory => "cloud-conversation-history", Cloud;
    CloudConversationThread => "cloud-conversation-thread", Cloud;
    CloudConversationRuns => "cloud-conversation-runs", Cloud;
    CloudConversationRun => "cloud-conversation-run", Cloud;
    CloudParticipantAvatarGet => "cloud-participant-avatar-get", Cloud;
    CloudConversationOp => "cloud-conversation-op", Cloud;
    CloudInboxOp => "cloud-inbox-op", Cloud;
    CloudInboxSubscribe => "cloud-inbox-subscribe", Cloud;
    CloudInboxUnsubscribe => "cloud-inbox-unsubscribe", Cloud;
    CloudConversationSubscribe => "cloud-conversation-subscribe", Cloud;
    CloudConversationUnsubscribe => "cloud-conversation-unsubscribe", Cloud;
    CloudConversationLive => "cloud-conversation-live", Cloud;
    CloudConversationTyping => "cloud-conversation-typing", Cloud;
    CloudConversationPresence => "cloud-conversation-presence", Cloud;
    CloudMuxSubscribe => "cloud-mux-subscribe", Cloud;
    CloudMuxUnsubscribe => "cloud-mux-unsubscribe", Cloud;
    CloudMuxAck => "cloud-mux-ack", Cloud;
    ConversationAttachmentUpload => "conversation-attachment-upload", Agent;
    ConversationAttachmentRead => "conversation-attachment-read", Agent;
    ConversationAttachmentLink => "conversation-attachment-link", Agent;
    CloudAttachmentUpload => "cloud-attachment-upload", Cloud;
    CloudAttachmentRead => "cloud-attachment-read", Cloud;
    CloudAttachmentLink => "cloud-attachment-link", Cloud;
    ConversationRunAppend => "conversation-run-append", Agent;
    ConversationRuns => "conversation-runs", Agent;
    ConversationRun => "conversation-run", Agent;
    ConversationLivePublish => "conversation-live-publish", Agent;
    ConversationLive => "conversation-live", Agent;
    ConversationImport => "conversation-import", Agent;
    CreateProfile => "create-profile", Topology;
    UpdateProfile => "update-profile", Topology;
    MoveProfile => "move-profile", Topology;
    DeleteProfile => "delete-profile", Topology;
    SetProfileFollows => "set-profile-follows", Topology;
    PinWorkspace => "pin-workspace", Topology;
    UnpinWorkspace => "unpin-workspace", Topology;
    PutSession => "put-session", Topology;
    ForgetSession => "forget-session", Topology;
    SetSessionIcon => "set-session-icon", Topology;
    ImportSessionOrganization => "import-session-organization", Topology;
    CreatePersonalGroup => "create-personal-group", Topology;
    UpdatePersonalGroup => "update-personal-group", Topology;
    DeletePersonalGroup => "delete-personal-group", Topology;
    MovePersonalGroup => "move-personal-group", Topology;
    SetPersonalWorkspace => "set-personal-workspace", Topology;
    SetPersonalTerminal => "set-personal-terminal", Topology;
    ListWorkspaceGroups => "list-workspace-groups", Query;
    CreateWorkspaceGroup => "create-workspace-group", Topology;
    UpdateWorkspaceGroup => "update-workspace-group", Topology;
    DeleteWorkspaceGroup => "delete-workspace-group", Topology;
    MoveWorkspaceGroup => "move-workspace-group", Topology;
    MoveWorkspaceToGroup => "move-workspace-to-group", Topology;
    SetDefaultColors => "set-default-colors", Topology;
    CloseSurface => "close-surface", Topology;
    CloseTabs => "close-tabs", Topology;
    ClosePane => "close-pane", Topology;
    CloseScreen => "close-screen", Topology;
    CloseWorkspace => "close-workspace", Topology;
    MarkWorkspacesProviderManaged => "mark-workspaces-provider-managed", Topology;
    CloseProviderManagedWorkspace => "close-provider-managed-workspace", Topology;
    RenamePane => "rename-pane", Topology;
    RenameSurface => "rename-surface", Topology;
    RenameScreen => "rename-screen", Topology;
    RenameWorkspace => "rename-workspace", Topology;
    RenameProviderManagedWorkspace => "rename-provider-managed-workspace", Topology;
    ResizeSurface => "resize-surface", TerminalIo;
    ResizeAttachedView => "resize-attached-view", TerminalIo;
    ReleaseSurfaceSize => "release-surface-size", TerminalIo;
    ReleaseAttachedViewSize => "release-attached-view-size", TerminalIo;
    DetachAttachedView => "detach-attached-view", TerminalIo;
    FocusPane => "focus-pane", Topology;
    SelectTab => "select-tab", Topology;
    SelectScreen => "select-screen", Topology;
    SelectWorkspace => "select-workspace", Topology;
    ReportFocus => "report-focus", Topology;
    ClientFocus => "client-focus", Topology;
    Subscribe => "subscribe", Other;
    AttachSurface => "attach-surface", Other;
    CancelStream => "cancel-stream", TerminalIo;
    SetStreamPriority => "set-stream-priority", TerminalIo;
    SnapshotRequest => "snapshot-request", Other;
    TerminalHistory => "terminal-history", TerminalIo;
    TerminalReadRange => "terminal-read-range", TerminalIo;
    ScrollSurface => "scroll-surface", TerminalIo;
    MemoryReport => "memory-report", Query;
}

#[cfg(test)]
#[path = "command_names_tests.rs"]
mod tests;
