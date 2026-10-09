//! Action identity: the Action enum and its bounded tab, screen and user-command indexes.

/// A validated zero-based index for the ten directly selectable tabs and
/// screens. Its private field prevents unregistered numbered actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ActionIndex(u8);

impl ActionIndex {
    pub const fn new(value: u8) -> Option<Self> {
        if value <= 9 { Some(Self(value)) } else { None }
    }

    pub const fn get(self) -> u8 {
        self.0
    }
}

/// The maximum number of configurable user commands. Chords bound past this
/// limit are rejected at config load with a visible warning.
pub const MAX_USER_COMMANDS: usize = 32;

/// The maximum number of chords one command may bind.
pub const MAX_USER_COMMAND_CHORDS: usize = 8;

/// A validated zero-based index into the configured `commands` list. Its
/// private field prevents unregistered command actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UserCommandIndex(pub(super) u8);

impl UserCommandIndex {
    pub const fn new(value: usize) -> Option<Self> {
        if value < MAX_USER_COMMANDS { Some(Self(value as u8)) } else { None }
    }

    pub const fn get(self) -> usize {
        self.0 as usize
    }
}

/// Every prefix-key action, so bindings are configurable end to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Action {
    SendPrefix,
    NewTab,
    NewBrowserTab,
    NewPaneSmart,
    NextTab,
    PrevTab,
    SelectTab(ActionIndex),
    SplitRight,
    SplitDown,
    CloseTab,
    ClosePane,
    RenameTab,
    RenameScreen,
    RenameWorkspace,
    CloseScreen,
    PrevScreen,
    NextScreen,
    SelectScreen(ActionIndex),
    NewScreen,
    PrevWorkspace,
    NextWorkspace,
    NewWorkspace,
    CloseWorkspace,
    ToggleSidebar,
    ToggleSidebarCompact,
    ToggleSidebarView,
    FocusSidebar,
    ProviderMenu,
    NewPaneRight,
    UndoLayout,
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    FocusNextPane,
    SwapPanePrev,
    SwapPaneNext,
    ZoomPane,
    ResizeGrow,
    ResizeShrink,
    ScrollUp,
    ScrollDown,
    ClearHistory,
    BrowserBack,
    BrowserForward,
    BrowserReload,
    BrowserEditUrl,
    ShowShortcuts,
    Detach,
    /// A user-configured command from the top-level `commands` section,
    /// opened as a new PTY tab through the mux `run` command.
    UserCommand(UserCommandIndex),
}
