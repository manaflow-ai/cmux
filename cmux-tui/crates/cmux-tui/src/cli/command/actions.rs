//! Per-action flag catalog for the public resource grammar.
//!
//! One table describes every action's path and flags. The tokenizer reads it
//! to decide which flags take a value, `parse` reads it to reject flags the
//! action does not accept and to report every missing required flag at once,
//! and `<path> --help` renders it. Debug builds assert that the parser only
//! reads flags listed here, so the help cannot silently fall behind it.

use std::collections::BTreeSet;

use cmux_tui_core::resource::{OperationClass, ResourceOperation as Op};

pub(in crate::cli) struct ActionSpec {
    /// Display path. `<word>` matches one word, `<word>...` any remaining
    /// words, and everything from ` -- ` on is display only.
    pub path: &'static str,
    /// The operation the action sends, which decides the request-level flags
    /// (`--correlation-key`, `--expected-revision`, `--idempotency-key`,
    /// `--stream-id`) exactly as `request` and `finalize_request` do.
    pub operation: Option<Op>,
    pub about: &'static str,
    pub options: &'static [OptionSpec],
}

#[derive(Clone, Copy)]
pub(in crate::cli) struct OptionSpec {
    /// Flag name without dashes, except a compatibility flag whose bare
    /// name is outside the public vocabulary (`--surface`), as `take_dashed`.
    spelling: &'static str,
    pub value: Option<&'static str>,
    pub required: bool,
    pub about: &'static str,
}

const fn req(name: &'static str, value: &'static str, about: &'static str) -> OptionSpec {
    OptionSpec { spelling: name, value: Some(value), required: true, about }
}

const fn opt(name: &'static str, value: &'static str, about: &'static str) -> OptionSpec {
    OptionSpec { spelling: name, value: Some(value), required: false, about }
}

const fn switch(name: &'static str, about: &'static str) -> OptionSpec {
    OptionSpec { spelling: name, value: None, required: false, about }
}

const fn action(
    path: &'static str,
    operation: Option<Op>,
    about: &'static str,
    options: &'static [OptionSpec],
) -> ActionSpec {
    ActionSpec { path, operation, about, options }
}

/// Accepted by every action and validated by `finalize_request`, which
/// rejects it for anything but a mutation.
const IDEMPOTENCY_KEY: OptionSpec =
    opt("idempotency-key", "<key>", "Replay-safe key; a retry with the same key is applied once");
const CORRELATION_KEY: OptionSpec = opt(
    "correlation-key",
    "<key>",
    "Name this creation so `session <selector> creation <key> resolve` can find it",
);
const EXPECTED_REVISION: OptionSpec = opt(
    "expected-revision",
    "<revision>",
    "Apply only if the session topology is still at this revision",
);
const STREAM_ID: OptionSpec =
    opt("stream-id", "<stream_id>", "Stream ID to use (default: a new random ID)");

const PARENT_SELECTORS: [OptionSpec; 3] = [
    opt("workspace", "<selector>", "Workspace that holds the pane (default: current)"),
    opt("screen", "<selector>", "Screen that holds the pane (default: current)"),
    opt("pane", "<selector>", "Pane to add the tab to (default: current)"),
];
const DESTINATION: [OptionSpec; 4] = [
    req("workspace", "<selector>", "Destination workspace"),
    req("screen", "<selector>", "Destination screen"),
    req("pane", "<selector>", "Destination pane"),
    req("index", "<n>", "Zero-based tab position in the destination pane"),
];
const SIZE: [OptionSpec; 2] = [
    opt("cols", "<n>", "Initial columns; requires --rows"),
    opt("rows", "<n>", "Initial rows; requires --cols"),
];
const RUN: [OptionSpec; 6] = [
    opt("shell", "<script>", "Run a shell script instead of argv after --"),
    opt("cwd", "<path>", "Working directory"),
    opt("name", "<value>", "Tab name"),
    opt("on-exit", "<close|keep>", "What happens to the tab when the command exits"),
    opt("cols", "<n>", "Initial columns; requires --rows"),
    opt("rows", "<n>", "Initial rows; requires --cols"),
];
const JOURNAL_FILTERS: [OptionSpec; 10] = [
    opt("from", "<tail|beginning>", "Where to start when no cursor is given"),
    opt("cursor-session", "<session_id>", "Resume after a cursor; requires --sequence"),
    opt("sequence", "<decimal>", "Cursor sequence; requires --cursor-session"),
    opt("kinds", "<kind[,kind...]>", "Only these event kinds"),
    opt("classes", "<class[,class...]>", "Only state, observation, effect, or checkpoint events"),
    opt("subjects", "<kind:id[,kind:id...]>", "Only events about these subjects"),
    opt("max-sensitivity", "<public|metadata|sensitive>", "Highest sensitivity to include"),
    opt("regex", "<pattern>", "Only events matching this regular expression"),
    opt(
        "regex-field",
        "<kind|subjects|payload|record|terminal_output>",
        "Field --regex matches (default: record)",
    ),
    switch("ignore-case", "Match --regex case-insensitively"),
];
const DEFAULT_COLORS: [OptionSpec; 17] = [
    opt("foreground", "<color>", "Default foreground color"),
    switch("clear-foreground", "Remove the foreground override"),
    opt("background", "<color>", "Default background color"),
    switch("clear-background", "Remove the background override"),
    opt("cursor", "<color>", "Cursor color"),
    switch("clear-cursor", "Remove the cursor color override"),
    opt("selection-background", "<color>", "Selection background color"),
    switch("clear-selection-background", "Remove the selection background override"),
    opt("selection-foreground", "<color>", "Selection foreground color"),
    switch("clear-selection-foreground", "Remove the selection foreground override"),
    opt("cursor-style", "<style>", "Cursor style"),
    switch("clear-cursor-style", "Remove the cursor style override"),
    opt("cursor-blink", "<bool>", "Whether the cursor blinks"),
    switch("clear-cursor-blink", "Remove the cursor blink override"),
    opt("palette", "<json>", "Palette overrides as a JSON object"),
    switch("clear-palette", "Remove the palette overrides"),
    switch("complete", "Replace every default, clearing the ones not given"),
];
const CLIENT_LABEL: [OptionSpec; 4] = [
    opt("name", "<value>", "Client display name"),
    switch("clear-name", "Remove the client name"),
    opt("kind", "<value>", "Client kind"),
    switch("clear-kind", "Remove the client kind"),
];
const TAB_RENAME: [OptionSpec; 7] = [
    req("name", "<value>", "New name"),
    PARENT_SELECTORS[0],
    PARENT_SELECTORS[1],
    PARENT_SELECTORS[2],
    opt("source", "<user|auto>", "Who chose the name (default: user)"),
    opt("expected-generation", "<value>", "Rename only if the tab is still this generation"),
    opt("expected-name-revision", "<decimal>", "Rename only if the name is still this revision"),
];
const PROJECTION_PUT: [OptionSpec; 5] = [
    req("projection", "<json>", "Projection document"),
    req("frontend-id", "<value>", "Frontend that owns the projection"),
    req("window-id", "<value>", "Window the projection describes"),
    req("generation", "<value>", "Frontend generation"),
    opt("expected-projection-revision", "<decimal>", "Write only if still at this revision"),
];
const PLUGIN_INSTALL: [OptionSpec; 2] = [
    opt("name", "<value>", "Install under this name instead of the manifest name"),
    switch("force", "Replace an installed plugin with the same name"),
];
const SIDEBAR_VIEW: OptionSpec = opt("view", "<selector>", "Sidebar view (default: current)");
const MOUSE_MODIFIERS: OptionSpec =
    opt("modifiers", "<shift,control,alt,meta>", "Held modifier keys, comma separated");

pub(in crate::cli) const ACTIONS: &[ActionSpec] = &[
    // server
    action("server status", None, "Report whether the local session owner is running", &[]),
    action("server stats", None, "Report where the session owner spends its time", &[]),
    action("server ensure", None, "Start a detached session owner unless one is running", &[]),
    action(
        "server stop",
        None,
        "Stop the local session owner",
        &[switch("force", "Force the owner to stop")],
    ),
    action("server reload-config", None, "Reload the session owner's configuration", &[]),
    // machine
    action("machine list", Some(Op::MachineList), "List machines", &[]),
    action("machine <selector> show", Some(Op::MachineGet), "Show one machine", &[]),
    action(
        "machine <selector> session list",
        Some(Op::SessionList),
        "List a machine's sessions",
        &[],
    ),
    action(
        "machine <selector> session <selector> open",
        Some(Op::SessionOpen),
        "Open a session on a machine",
        &[],
    ),
    // session
    action("session list", Some(Op::SessionList), "List sessions", &[]),
    action("session <selector> show", Some(Op::SessionGet), "Show one session", &[]),
    action(
        "session <selector> snapshot",
        Some(Op::SessionSnapshot),
        "Print the session's full topology",
        &[],
    ),
    action(
        "session <selector> creation <correlation-key> resolve",
        Some(Op::SessionCreationResolve),
        "Find the resource a correlated creation made",
        &[],
    ),
    action("session <selector> open", Some(Op::SessionOpen), "Open a session", &[]),
    action(
        "session <selector> events",
        Some(Op::SessionEvents),
        "Stream topology events",
        &[
            opt("generation", "<value>", "Resume after this generation; requires --revision"),
            opt("revision", "<decimal>", "Resume after this revision; requires --generation"),
        ],
    ),
    action(
        "session <selector> journal subscribe",
        Some(Op::SessionJournalSubscribe),
        "Follow the session journal",
        &JOURNAL_FILTERS,
    ),
    action(
        "session <selector> journal read",
        Some(Op::SessionJournalSubscribe),
        "Read the session journal without following it",
        &JOURNAL_FILTERS,
    ),
    action(
        "session <selector> journal producer list",
        Some(Op::SessionJournalProducerList),
        "List journal producers",
        &[],
    ),
    action(
        "session <selector> journal producer put",
        Some(Op::SessionJournalProducerPut),
        "Register or update a journal producer",
        &[req("manifest-json", "<json>", "Producer manifest")],
    ),
    action(
        "session <selector> journal append",
        Some(Op::SessionJournalAppend),
        "Append an event to the session journal",
        &[req("event-json", "<json>", "Event to append")],
    ),
    action(
        "session <selector> journal hook list",
        Some(Op::SessionJournalHookList),
        "List journal hooks",
        &[],
    ),
    action(
        "session <selector> journal hook put",
        Some(Op::SessionJournalHookPut),
        "Register or update a journal hook",
        &[req("manifest-json", "<json>", "Hook manifest")],
    ),
    action(
        "session <selector> journal checkpoint create",
        Some(Op::SessionJournalCheckpointCreate),
        "Create a journal checkpoint",
        &[],
    ),
    action(
        "session <selector> journal checkpoint list",
        Some(Op::SessionJournalCheckpointList),
        "List journal checkpoints",
        &[],
    ),
    action(
        "session <selector> journal restore preview",
        Some(Op::SessionJournalRestorePreview),
        "Preview what restoring a checkpoint would do",
        &[opt("checkpoint", "<latest|checkpoint-id>", "Checkpoint to preview (default: latest)")],
    ),
    action(
        "session <selector> journal segment list",
        Some(Op::SessionJournalSegmentList),
        "List journal segments",
        &[],
    ),
    action(
        "session <selector> journal segment seal",
        Some(Op::SessionJournalSegmentSeal),
        "Seal the journal through a sequence",
        &[req("through", "<sequence>", "Last sequence to seal")],
    ),
    action("session <selector> ping", Some(Op::SessionPing), "Check that a session answers", &[]),
    action(
        "session <selector> shutdown",
        Some(Op::SessionShutdown),
        "Shut a session down",
        &[switch("force", "Shut down even if the session would refuse")],
    ),
    action(
        "session <name> reset-state",
        None,
        "Preview or confirm a scoped saved-state reset",
        &[
            opt("state", "<path>", "Session state root (default: platform state dir)"),
            switch("force", "Confirm the reset; requires --confirm-reset"),
            opt("confirm-reset", "<token>", "Confirmation token printed by the preview"),
        ],
    ),
    action(
        "session <name> stop",
        None,
        "Stop a named local session owner",
        &[switch("force", "Force the owner to stop")],
    ),
    action(
        "session <selector> config reload",
        Some(Op::SessionReloadConfig),
        "Reload the session's configuration",
        &[],
    ),
    action(
        "session <selector> window title set",
        Some(Op::SessionWindowTitleSet),
        "Set the outer terminal window title",
        &[req("title", "<value>", "Window title")],
    ),
    action(
        "session <selector> window title clear",
        Some(Op::SessionWindowTitleClear),
        "Clear the outer terminal window title",
        &[],
    ),
    action(
        "session <selector> terminal defaults set",
        Some(Op::SessionTerminalDefaultsUpdate),
        "Change default terminal colors and cursor; needs at least one flag",
        &DEFAULT_COLORS,
    ),
    // client
    action("client list", Some(Op::ClientList), "List connected clients", &[]),
    action("client <selector> show", Some(Op::ClientGet), "Show one client", &[]),
    action(
        "client <selector> label set",
        Some(Op::ClientMetadataUpdate),
        "Label a client; needs at least one flag",
        &CLIENT_LABEL,
    ),
    action(
        "client <selector> metadata set",
        Some(Op::ClientMetadataUpdate),
        "Label a client; needs at least one flag",
        &CLIENT_LABEL,
    ),
    action(
        "client <selector> sizing set",
        Some(Op::ClientSizingSet),
        "Choose whether a client's size counts for a terminal",
        &[
            req("terminal", "<selector>", "Terminal to size"),
            req("enabled", "<bool>", "Whether this client sizes the terminal"),
            opt("exclusive", "<bool>", "Make this client the only one that sizes it"),
        ],
    ),
    action(
        "client <selector> sizing release",
        Some(Op::ClientSizingRelease),
        "Stop a client from sizing a terminal",
        &[req("terminal", "<selector>", "Terminal to release")],
    ),
    action(
        "client <selector> cell pixels set",
        Some(Op::ClientCellPixelsSet),
        "Report a client's cell size in pixels",
        &[
            req("width-px", "<n>", "Cell width in pixels"),
            req("height-px", "<n>", "Cell height in pixels"),
        ],
    ),
    action("client <selector> detach", Some(Op::ClientDetach), "Detach a client", &[]),
    // workspace
    action("workspace list", Some(Op::WorkspaceList), "List workspaces", &[]),
    action(
        "workspace create",
        Some(Op::WorkspaceCreate),
        "Create a workspace",
        &[
            opt("name", "<value>", "Workspace name"),
            switch("empty", "Create it without a terminal"),
        ],
    ),
    action("workspace <selector> show", Some(Op::WorkspaceGet), "Show one workspace", &[]),
    action(
        "workspace <selector> rename",
        Some(Op::WorkspaceRename),
        "Rename a workspace",
        &[req("name", "<value>", "New name")],
    ),
    action(
        "workspace <selector> move",
        Some(Op::WorkspaceMove),
        "Move a workspace in the workspace list",
        &[req("index", "<n>", "Zero-based position")],
    ),
    action("workspace <selector> focus", Some(Op::WorkspaceFocus), "Focus a workspace", &[]),
    action("workspace <selector> close", Some(Op::WorkspaceClose), "Close a workspace", &[]),
    action(
        "workspace <selector> run -- <argv...>",
        Some(Op::WorkspaceRun),
        "Run a command in a new workspace tab",
        &RUN,
    ),
    action(
        "workspace <selector> run shell <script>",
        Some(Op::WorkspaceRun),
        "Run a shell script in a new workspace tab",
        &RUN,
    ),
    action(
        "workspace <selector> layout apply",
        Some(Op::WorkspaceLayoutApply),
        "Replace a workspace's layout",
        &[req("layout", "<json>", "Layout document")],
    ),
    // screen
    action("screen list", Some(Op::ScreenList), "List screens", &[]),
    action(
        "screen create",
        Some(Op::ScreenCreate),
        "Create a screen",
        &[opt("name", "<value>", "Screen name")],
    ),
    action("screen <selector> show", Some(Op::ScreenGet), "Show one screen", &[]),
    action(
        "screen <selector> rename",
        Some(Op::ScreenRename),
        "Rename a screen",
        &[req("name", "<value>", "New name")],
    ),
    action("screen <selector> focus", Some(Op::ScreenFocus), "Focus a screen", &[]),
    action("screen <selector> close", Some(Op::ScreenClose), "Close a screen", &[]),
    action(
        "screen <selector> layout export",
        Some(Op::ScreenLayoutExport),
        "Print a screen's layout",
        &[],
    ),
    action(
        "screen <selector> layout undo",
        Some(Op::ScreenLayoutUndo),
        "Undo the last layout change",
        &[
            switch("confirm-close", "Allow the undo to close terminals"),
            opt("confirmation-token", "<value>", "Token from a refused undo"),
        ],
    ),
    // pane
    action("pane list", Some(Op::PaneList), "List panes", &[]),
    action(
        "pane create",
        Some(Op::PaneCreate),
        "Create a pane",
        &[SIZE[0], SIZE[1], opt("cwd", "<path>", "Working directory")],
    ),
    action("pane <selector> show", Some(Op::PaneGet), "Show one pane", &[]),
    action(
        "pane <selector> split",
        Some(Op::PaneSplit),
        "Split a pane",
        &[
            switch("right", "New pane to the right (default)"),
            switch("down", "New pane below"),
            switch("left", "New pane to the left"),
            switch("up", "New pane above"),
            opt("ratio", "<value>", "Share of the space the existing pane keeps"),
            opt("viewport-width", "<fraction>", "Viewport width; requires --right"),
            opt("cwd", "<path>", "Working directory"),
            SIZE[0],
            SIZE[1],
        ],
    ),
    action(
        "pane <selector> rename",
        Some(Op::PaneRename),
        "Rename a pane",
        &[req("name", "<value>", "New name")],
    ),
    action("pane <selector> focus", Some(Op::PaneFocus), "Focus a pane", &[]),
    action(
        "pane <selector> focus direction <left|right|up|down>",
        Some(Op::PaneFocusDirection),
        "Focus the neighboring pane",
        &[],
    ),
    action(
        "pane <selector> neighbor <left|right|up|down>",
        Some(Op::PaneNeighborGet),
        "Show the neighboring pane",
        &[],
    ),
    action(
        "pane <selector> swap",
        Some(Op::PaneSwap),
        "Swap two panes",
        &[
            req("other-workspace", "<selector>", "Workspace of the other pane"),
            req("other-screen", "<selector>", "Screen of the other pane"),
            req("other-pane", "<selector>", "The other pane"),
        ],
    ),
    action(
        "pane <selector> zoom",
        Some(Op::PaneZoom),
        "Zoom or unzoom a pane",
        &[opt("enabled", "<bool>", "Zoom state (default: toggle)")],
    ),
    action(
        "pane <selector> split ratio set",
        Some(Op::PaneSplitRatioSet),
        "Change a split's ratio",
        &[req("split", "<split_id>", "Split to change"), req("ratio", "<value>", "New ratio")],
    ),
    action(
        "pane <selector> viewport width set",
        Some(Op::PaneViewportWidthSet),
        "Set a pane's viewport width",
        &[req("columns", "<n>", "Width in columns")],
    ),
    action("pane <selector> close", Some(Op::PaneClose), "Close a pane", &[]),
    action(
        "pane <selector> run -- <argv...>",
        Some(Op::PaneRun),
        "Run a command in a new tab of a pane",
        &RUN,
    ),
    action(
        "pane <selector> run shell <script>",
        Some(Op::PaneRun),
        "Run a shell script in a new tab of a pane",
        &RUN,
    ),
    // tab
    action("tab list", Some(Op::TabList), "List tabs", &[]),
    action("tab <selector> show", Some(Op::TabGet), "Show one tab", &[]),
    action(
        "tab create terminal",
        Some(Op::TabCreateTerminal),
        "Create a terminal tab",
        &[
            opt("cwd", "<path>", "Working directory"),
            opt("name", "<value>", "Tab name"),
            PARENT_SELECTORS[0],
            PARENT_SELECTORS[1],
            PARENT_SELECTORS[2],
            SIZE[0],
            SIZE[1],
        ],
    ),
    action(
        "tab create browser",
        Some(Op::TabCreateBrowser),
        "Create a browser tab",
        &[
            req("url", "<url>", "Page to open"),
            opt("name", "<value>", "Tab name"),
            PARENT_SELECTORS[0],
            PARENT_SELECTORS[1],
            PARENT_SELECTORS[2],
            opt("width-px", "<n>", "Initial width in pixels; requires --height-px"),
            opt("height-px", "<n>", "Initial height in pixels; requires --width-px"),
        ],
    ),
    action("tab <selector> rename", Some(Op::TabRename), "Rename a tab", &TAB_RENAME),
    action(
        "tab <selector> move",
        Some(Op::TabMove),
        "Move a tab to a position in a pane",
        &DESTINATION,
    ),
    action("tab <selector> focus", Some(Op::TabFocus), "Focus a tab", &[]),
    action("tab <selector> close", Some(Op::TabClose), "Close a tab", &[]),
    // terminal
    action("terminal list", Some(Op::TerminalList), "List terminals", &[]),
    action("terminal <selector> show", Some(Op::TerminalGet), "Show one terminal", &[]),
    action(
        "terminal <selector> write",
        Some(Op::TerminalInputWrite),
        "Write input to a terminal (default: read it from stdin)",
        &[
            opt("text", "<value>", "Text to write"),
            opt("bytes-base64", "<base64>", "Raw bytes to write"),
        ],
    ),
    action(
        "terminal <selector> keys <key...>",
        Some(Op::TerminalInputKeys),
        "Send key presses such as ctrl+c or enter",
        &[],
    ),
    action(
        "terminal <selector> mouse <down|up|move|wheel>",
        Some(Op::TerminalInputMouse),
        "Send a mouse event",
        &[
            req("row", "<n>", "Cell row"),
            req("column", "<n>", "Cell column"),
            opt("button", "<left|middle|right>", "Button; required for down and up"),
            opt("delta-rows", "<n>", "Rows to scroll; required for wheel"),
            MOUSE_MODIFIERS,
        ],
    ),
    action(
        "terminal <selector> focus <in|out>",
        Some(Op::TerminalInputFocus),
        "Send a focus event",
        &[],
    ),
    action(
        "terminal <selector> screen read",
        Some(Op::TerminalScreenRead),
        "Print the visible screen",
        &[],
    ),
    action(
        "terminal <selector> read",
        Some(Op::TerminalScreenRead),
        "Print the visible screen",
        &[],
    ),
    action(
        "terminal <selector> screen wait",
        Some(Op::TerminalWait),
        "Wait until the screen matches a pattern; exits 1 on timeout",
        &[
            req("pattern", "<regex>", "Pattern to wait for"),
            opt("timeout-ms", "<n>", "Give up after this many milliseconds"),
        ],
    ),
    action(
        "terminal <selector> state read",
        Some(Op::TerminalStateRead),
        "Print terminal modes and cursor state",
        &[],
    ),
    action(
        "terminal <selector> history read",
        Some(Op::TerminalHistoryRead),
        "Print scrollback",
        &[
            opt("before", "<decimal>", "Only lines before this position"),
            opt("limit", "<n>", "Most lines to print (1-10000)"),
            switch("styled", "Include styles"),
        ],
    ),
    action(
        "terminal <selector> history clear",
        Some(Op::TerminalHistoryClear),
        "Clear scrollback",
        &[],
    ),
    action(
        "terminal <selector> output read",
        Some(Op::TerminalOutputRead),
        "Print raw output bytes",
        &[
            opt("after", "<offset>", "Only output after this offset"),
            opt("max-bytes", "<n>", "Most bytes to print"),
        ],
    ),
    action(
        "terminal <selector> copy",
        Some(Op::TerminalCopy),
        "Copy terminal text",
        &[opt("mode", "<screen|selection|scrollback>", "What to copy")],
    ),
    action(
        "terminal <selector> process show",
        Some(Op::TerminalProcessGet),
        "Show the terminal's process",
        &[],
    ),
    action(
        "terminal <selector> process wait",
        Some(Op::TerminalWaitExit),
        "Wait for the terminal's process to exit",
        &[opt("timeout-ms", "<n>", "Give up after this many milliseconds")],
    ),
    action(
        "terminal <selector> viewport scroll",
        Some(Op::TerminalViewportScroll),
        "Scroll the viewport",
        &[req("delta-rows", "<n>", "Rows to scroll; negative scrolls up")],
    ),
    action(
        "terminal <selector> move",
        Some(Op::TerminalMove),
        "Move a terminal to a position in a pane",
        &DESTINATION,
    ),
    action(
        "terminal <selector> project",
        Some(Op::TerminalProject),
        "Show a terminal in another pane too",
        &[
            DESTINATION[0],
            DESTINATION[1],
            DESTINATION[2],
            DESTINATION[3],
            opt("name", "<value>", "Name of the new tab"),
        ],
    ),
    action(
        "terminal <selector> attach",
        Some(Op::TerminalAttach),
        "Attach to one terminal",
        &[SIZE[0], SIZE[1], switch("read-only", "Do not send input")],
    ),
    action("terminal <selector> close", Some(Op::TerminalClose), "Close a terminal", &[]),
    // browser
    action("browser list", Some(Op::BrowserList), "List browsers", &[]),
    action("browser <selector> show", Some(Op::BrowserGet), "Show one browser", &[]),
    action(
        "browser <selector> navigate",
        Some(Op::BrowserNavigate),
        "Open a URL",
        &[req("url", "<url>", "Page to open")],
    ),
    action("browser <selector> back", Some(Op::BrowserBack), "Go back", &[]),
    action("browser <selector> forward", Some(Op::BrowserForward), "Go forward", &[]),
    action("browser <selector> reload", Some(Op::BrowserReload), "Reload the page", &[]),
    action("browser <selector> activate", Some(Op::BrowserActivate), "Activate a browser", &[]),
    action(
        "browser <selector> key",
        Some(Op::BrowserInputKey),
        "Send a key event",
        &[
            req("key", "<name>", "Key name"),
            opt("kind", "<down|up|press>", "Event kind"),
            MOUSE_MODIFIERS,
        ],
    ),
    action(
        "browser <selector> text",
        Some(Op::BrowserInputText),
        "Type text",
        &[req("text", "<value>", "Text to type")],
    ),
    action(
        "browser <selector> mouse",
        Some(Op::BrowserInputMouse),
        "Send a mouse event",
        &[
            req("kind", "<down|up|move>", "Event kind"),
            req("x-px", "<value>", "X position in pixels"),
            req("y-px", "<value>", "Y position in pixels"),
            req("pointer-frame-seq", "<decimal>", "Pointer frame sequence"),
            opt("button", "<left|middle|right|back|forward>", "Button; required for down and up"),
            opt("click-count", "<n>", "Click count for down and up"),
        ],
    ),
    action(
        "browser <selector> wheel",
        Some(Op::BrowserInputWheel),
        "Send a wheel event",
        &[
            req("delta-x", "<value>", "Horizontal scroll"),
            req("delta-y", "<value>", "Vertical scroll"),
            req("x-px", "<value>", "X position in pixels"),
            req("y-px", "<value>", "Y position in pixels"),
            req("pointer-frame-seq", "<decimal>", "Pointer frame sequence"),
        ],
    ),
    action(
        "browser <selector> attach",
        Some(Op::BrowserAttach),
        "Attach to one browser",
        &[
            opt("width-px", "<n>", "Width in pixels; requires --height-px"),
            opt("height-px", "<n>", "Height in pixels; requires --width-px"),
        ],
    ),
    action("browser <selector> close", Some(Op::BrowserClose), "Close a browser", &[]),
    // notification
    action(
        "notification list",
        Some(Op::NotificationList),
        "List notifications",
        &[opt("limit", "<n>", "Most notifications to list (1-256)")],
    ),
    action(
        "notification create",
        Some(Op::NotificationCreate),
        "Create a notification",
        &[
            req("title", "<value>", "Title"),
            req("body", "<value>", "Body"),
            opt("subtitle", "<value>", "Subtitle"),
            opt("level", "<info|success|warning|error>", "Level"),
            opt("terminal", "<term_id>", "Terminal the notification is about"),
        ],
    ),
    action(
        "notification clear",
        Some(Op::NotificationClear),
        "Clear notifications",
        &[opt("terminal", "<term_id>", "Only this terminal's notifications")],
    ),
    action(
        "notification ack <notification_id...>",
        Some(Op::NotificationAck),
        "Acknowledge notifications",
        &[req("client", "<value>", "Client that saw them")],
    ),
    action(
        "notify",
        Some(Op::NotificationCreate),
        "Notify about the caller's terminal, with the flags of the macOS app's notify",
        &[
            opt("title", "<value>", "Title (default: Notification)"),
            opt("subtitle", "<value>", "Subtitle"),
            opt("body", "<value>", "Body"),
            opt("--surface", "<term_id|current>", "Terminal to notify about"),
            opt("workspace", "<ws_id|current>", "Make a session-level notification"),
            switch("clear", "Clear notifications instead"),
            switch("reply", "Not available on a machine"),
            opt("window", "<value>", "Accepted for compatibility; ignored"),
            opt("id-format", "<value>", "Accepted for compatibility; ignored"),
            opt("desktop", "<bool>", "Accepted for compatibility; ignored"),
        ],
    ),
    // agent
    action(
        "agent list",
        Some(Op::AgentList),
        "List agents",
        &[
            opt("terminal", "<term_id>", "Only this terminal's agent"),
            opt("state", "<working|blocked|idle|done|unknown>", "Only agents in this state"),
        ],
    ),
    action(
        "agent report",
        Some(Op::AgentReport),
        "Report an agent's state",
        &[
            req("terminal", "<term_id>", "Terminal the agent runs in"),
            req("state", "<working|blocked|idle|done|unknown>", "Agent state"),
            req("source", "<hook|socket>", "Where the report comes from"),
            opt("source-session", "<value>", "Agent session ID"),
        ],
    ),
    action(
        "agent hook install <provider...>",
        None,
        "Install agent hooks (default: every provider)",
        &[],
    ),
    action(
        "agent hook uninstall <provider...>",
        None,
        "Remove agent hooks (default: every provider)",
        &[],
    ),
    action("agent hook status <provider...>", None, "Show installed agent hooks", &[]),
    action(
        "agent hook emit",
        Some(Op::SessionJournalAppend),
        "Record an agent hook event (payload from stdin by default)",
        &[
            req("source", "<agent>", "Agent that ran the hook"),
            req("event", "<native-event>", "Agent's own event name"),
            opt("payload-json", "<json>", "Hook payload"),
            opt("terminal", "<term_id>", "Terminal (default: CMUX_TUI_TERMINAL_ID)"),
        ],
    ),
    action("agent plugin list", None, "List agent plugins", &[]),
    action("agent plugin install <git-url>", None, "Install an agent plugin", &PLUGIN_INSTALL),
    action("agent plugin use <name-or-id>", None, "Use an agent plugin", &[]),
    action(
        "agent plugin use",
        None,
        "Use the built-in agent plugin",
        &[switch("builtin", "Use the built-in plugin")],
    ),
    action("agent plugin update <name-or-id>", None, "Update an agent plugin", &[]),
    action("agent plugin remove <name-or-id>", None, "Remove an agent plugin", &[]),
    // sidebar
    action("sidebar view show", Some(Op::SidebarViewGet), "Show a sidebar view", &[SIDEBAR_VIEW]),
    action(
        "sidebar view ensure",
        Some(Op::SidebarViewEnsure),
        "Start the sidebar view unless it is running",
        &[
            req("cols", "<n>", "Columns"),
            req("rows", "<n>", "Rows"),
            switch("relaunch", "Restart it if it is running"),
        ],
    ),
    action(
        "sidebar view attach",
        Some(Op::SidebarViewAttach),
        "Attach to a sidebar view",
        &[SIDEBAR_VIEW],
    ),
    action(
        "sidebar view input",
        Some(Op::SidebarViewInput),
        "Send input to a sidebar view; needs --text or --data-base64",
        &[
            SIDEBAR_VIEW,
            opt("text", "<value>", "Text to send"),
            opt("data-base64", "<base64>", "Raw bytes to send"),
        ],
    ),
    action(
        "sidebar view resize",
        Some(Op::SidebarViewResize),
        "Resize a sidebar view",
        &[SIDEBAR_VIEW, req("cols", "<n>", "Columns"), req("rows", "<n>", "Rows")],
    ),
    action(
        "sidebar view reload",
        Some(Op::SidebarViewReload),
        "Reload a sidebar view",
        &[SIDEBAR_VIEW],
    ),
    action("sidebar plugin list", None, "List sidebar plugins", &[]),
    action("sidebar plugin install <git-url>", None, "Install a sidebar plugin", &PLUGIN_INSTALL),
    action("sidebar plugin use <name-or-id>", None, "Use a sidebar plugin", &[]),
    action(
        "sidebar plugin use",
        None,
        "Use the built-in sidebar",
        &[switch("builtin", "Use the built-in sidebar")],
    ),
    action("sidebar plugin update <name-or-id>", None, "Update a sidebar plugin", &[]),
    action("sidebar plugin remove <name-or-id>", None, "Remove a sidebar plugin", &[]),
    // pairing
    action("pairing request list", Some(Op::PairingRequestList), "List pairing requests", &[]),
    action(
        "pairing request <selector> respond <accept|reject>",
        Some(Op::PairingRequestResolve),
        "Accept or reject a pairing request",
        &[],
    ),
    // projection
    action(
        "projection show",
        Some(Op::FrontendProjectionGet),
        "Show a frontend projection",
        &[opt("projection-id", "<selector>", "Projection (default: current)")],
    ),
    action(
        "projection <selector> show",
        Some(Op::FrontendProjectionGet),
        "Show a frontend projection",
        &[],
    ),
    action(
        "projection put",
        Some(Op::FrontendProjectionPut),
        "Write a frontend projection",
        &[
            opt("projection-id", "<selector>", "Projection (default: current)"),
            PROJECTION_PUT[0],
            PROJECTION_PUT[1],
            PROJECTION_PUT[2],
            PROJECTION_PUT[3],
            PROJECTION_PUT[4],
        ],
    ),
    action(
        "projection <selector> put",
        Some(Op::FrontendProjectionPut),
        "Write a frontend projection",
        &PROJECTION_PUT,
    ),
    // provider
    action(
        "provider authority install",
        None,
        "Install private provider authority",
        &[
            req("generation", "<decimal>", "Authority generation, above zero"),
            req("authority-file", "<root-private-path>", "Authority file"),
        ],
    ),
    // raw
    action(
        "raw operation <dotted.name>",
        None,
        "Send one cmux.protocol/2 operation",
        &[
            opt("params-json", "<object>", "Operation parameters"),
            switch("mutation", "Send it as a mutation"),
            switch("stream", "Open it as a stream"),
            IDEMPOTENCY_KEY,
        ],
    ),
    action(
        "raw command",
        None,
        "Send a legacy control request (unsafe, no compatibility promise)",
        &[req("request-json", "<full-object>", "Full request"), switch("stream", "Stream replies")],
    ),
];

impl OptionSpec {
    pub(in crate::cli) fn name(&self) -> &'static str {
        self.spelling.trim_start_matches('-')
    }
}

impl ActionSpec {
    fn pattern(&self) -> impl Iterator<Item = &'static str> {
        self.path.split(" -- ").next().unwrap_or_default().split_whitespace()
    }

    pub(in crate::cli) fn matches(&self, words: &[&str]) -> bool {
        let mut words = words.iter();
        for part in self.pattern() {
            if part.starts_with('<') && part.ends_with("...>") {
                return true;
            }
            match words.next() {
                Some(word) if part.starts_with('<') || part == *word => {}
                _ => return false,
            }
        }
        words.next().is_none()
    }

    /// Request-level flags the parser takes for this action's operation.
    fn request_options(&self) -> Vec<OptionSpec> {
        let Some(operation) = self.operation else { return Vec::new() };
        let mut options = Vec::new();
        if operation.class() == OperationClass::StreamOpen {
            options.push(STREAM_ID);
        }
        if super::correlated_creation(operation) {
            options.push(CORRELATION_KEY);
        }
        if super::supports_expected_revision(operation) {
            options.push(EXPECTED_REVISION);
        }
        if operation.class() == OperationClass::Mutation {
            options.push(IDEMPOTENCY_KEY);
        }
        options
    }

    /// Every flag this action accepts, in help order.
    pub(in crate::cli) fn all_options(&self) -> Vec<OptionSpec> {
        let mut options = self.options.to_vec();
        for option in self.request_options() {
            if !options.iter().any(|known| known.name() == option.name()) {
                options.push(option);
            }
        }
        options
    }

    pub(in crate::cli) fn accepts(&self, name: &str) -> bool {
        // `finalize_request` reads --idempotency-key for every operation and
        // gives its own error for a non-mutation.
        name == IDEMPOTENCY_KEY.name()
            || self.all_options().iter().any(|option| option.name() == name)
    }

    /// One usage line: the path, its required flags, and `[OPTIONS]` when it
    /// has optional ones.
    /// Options go before ` -- `, which forwards everything after it.
    pub(in crate::cli) fn usage(&self, program: &str) -> String {
        let (path, forwarded) = match self.path.split_once(" -- ") {
            Some((path, forwarded)) => (path, Some(forwarded)),
            None => (self.path, None),
        };
        let mut line = format!("{program} {path}");
        let options = self.all_options();
        for option in options.iter().filter(|option| option.required) {
            line.push_str(&format!(" --{}", option.name()));
            if let Some(value) = option.value {
                line.push(' ');
                line.push_str(value);
            }
        }
        if options.iter().any(|option| !option.required) {
            line.push_str(" [OPTIONS]");
        }
        if let Some(forwarded) = forwarded {
            line.push_str(" -- ");
            line.push_str(forwarded);
        }
        line
    }

    pub(in crate::cli) fn help(&self, program: &str) -> String {
        let mut text = format!("USAGE\n  {}\n\n{}.\n", self.usage(program), self.about);
        let options = self.all_options();
        if !options.is_empty() {
            let labels = options
                .iter()
                .map(|option| match option.value {
                    Some(value) => format!("--{} {value}", option.name()),
                    None => format!("--{}", option.name()),
                })
                .collect::<Vec<_>>();
            let width = labels.iter().map(String::len).max().unwrap_or(0);
            text.push_str("\nOPTIONS\n");
            for (label, option) in labels.iter().zip(&options) {
                let required = if option.required { " (required)" } else { "" };
                text.push_str(&format!("  {label:<width$}  {}{required}\n", option.about));
            }
        }
        text
    }
}

/// The action a word path names, after shorthand normalization. Nested
/// parents (`workspace <ws> screen <screen> pane ...`) are peeled until the
/// innermost scope names an action.
pub(in crate::cli) fn resolve(words: &[String]) -> Option<&'static ActionSpec> {
    let mut words = words.iter().map(String::as_str).collect::<Vec<_>>();
    loop {
        if let Some(spec) = ACTIONS.iter().find(|spec| spec.matches(&words)) {
            return Some(spec);
        }
        if words.len() >= 3 && super::super::shorthand::child(words[0], words[2]) {
            words.drain(..2);
        } else {
            return None;
        }
    }
}

/// How the tokenizer treats a flag name, from every action's flags.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Arity {
    Switch,
    Value,
}

pub(in crate::cli) fn arity(name: &str) -> Option<Arity> {
    ACTIONS
        .iter()
        .flat_map(ActionSpec::all_options)
        .find(|option| option.name() == name)
        .map(|option| if option.value.is_some() { Arity::Value } else { Arity::Switch })
}

pub(in crate::cli) fn known_flag_names() -> BTreeSet<&'static str> {
    ACTIONS.iter().flat_map(ActionSpec::all_options).map(|option| option.name()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One word that each path placeholder accepts.
    fn sample_word(part: &str) -> &'static str {
        match part {
            "<name>" => "main",
            "<correlation-key>" => "key",
            "<left|right|up|down>" => "left",
            "<down|up|move|wheel>" => "move",
            "<in|out>" => "in",
            "<accept|reject>" => "accept",
            "<key...>" => "enter",
            "<notification_id...>" => "notification_77777777777777777777777777777777",
            "<provider...>" => "claude",
            "<git-url>" => "https://example.com/plugin.git",
            "<name-or-id>" => "plugin",
            "<dotted.name>" => "workspace.list",
            "<script>" => "true",
            _ => "current",
        }
    }

    /// One value that each option placeholder accepts.
    fn sample_value(value: &str) -> String {
        let value = match value {
            "<json>" | "<object>" | "<full-object>" => "{}",
            "<n>" | "<decimal>" | "<sequence>" | "<revision>" => "1",
            "<bool>" => "true",
            "<url>" => "https://example.com",
            "<term_id>" => "term_55555555555555555555555555555555",
            "<split_id>" => "split_88888888888888888888888888888888",
            choices if choices.contains('|') => {
                return choices.trim_matches(['<', '>']).split('|').next().unwrap().to_owned();
            }
            _ => "x",
        };
        value.to_owned()
    }

    fn sample_words(action: &ActionSpec) -> Vec<String> {
        action
            .pattern()
            .map(|part| if part.starts_with('<') { sample_word(part) } else { part }.to_owned())
            .collect()
    }

    #[test]
    fn every_action_path_resolves_to_its_own_entry() {
        for action in ACTIONS {
            let resolved = resolve(&sample_words(action)).map(|resolved| resolved.path);
            assert_eq!(resolved, Some(action.path), "{} is shadowed", action.path);
        }
    }

    #[test]
    fn a_flag_has_one_arity_across_actions() {
        for name in known_flag_names() {
            let arities = ACTIONS
                .iter()
                .flat_map(ActionSpec::all_options)
                .filter(|option| option.name() == name)
                .map(|option| option.value.is_some())
                .collect::<BTreeSet<_>>();
            assert_eq!(
                arities.len(),
                1,
                "--{name} is a switch in one action and takes a value in another"
            );
        }
    }

    #[test]
    fn no_action_lists_a_flag_twice() {
        for action in ACTIONS {
            let options = action.all_options();
            let names = options.iter().map(|option| option.name()).collect::<BTreeSet<_>>();
            assert_eq!(names.len(), options.len(), "{} lists a flag twice", action.path);
        }
    }

    /// Parse every action with its required flags. `Flags` asserts in debug
    /// builds that the parser reads only flags the action lists, so a flag
    /// added to the parser without a catalog entry fails here.
    #[test]
    fn the_parser_reads_only_listed_flags() {
        for action in ACTIONS {
            let mut args = sample_words(action);
            let mut options = action.all_options();
            // Without one of these the action reads stdin.
            match action.path {
                "terminal <selector> write" | "sidebar view input" => {
                    options.retain(|option| option.name() == "text" || option.required);
                }
                "agent hook emit" => {
                    options.retain(|option| option.name() == "payload-json" || option.required);
                }
                _ => options.retain(|option| option.required),
            }
            for option in options {
                args.push(format!("--{}", option.name()));
                if let Some(value) = option.value {
                    args.push(sample_value(value));
                }
            }
            if action.path.contains(" -- ") {
                args.extend(["--".to_owned(), "true".to_owned()]);
            }
            let _ = super::super::parse(&args);
        }
    }

    #[test]
    fn action_help_marks_required_flags_and_request_options() {
        let action = ACTIONS.iter().find(|action| action.path == "tab <selector> move").unwrap();
        let help = action.help("cmux");
        assert!(help.starts_with(
            "USAGE\n  cmux tab <selector> move --workspace <selector> --screen <selector> \
             --pane <selector> --index <n> [OPTIONS]\n"
        ));
        assert!(help.contains("--index <n>"));
        assert!(help.contains("(required)"));
        assert!(help.contains("--idempotency-key <key>"));
        assert!(help.contains("--expected-revision <revision>"));
        let create = ACTIONS
            .iter()
            .find(|action| action.path == "tab create terminal")
            .unwrap()
            .help("cmux");
        assert!(create.contains("--correlation-key <key>"));
        let run = ACTIONS.iter().find(|action| action.path == "pane <selector> run -- <argv...>");
        assert_eq!(
            run.unwrap().usage("cmux"),
            "cmux pane <selector> run [OPTIONS] -- <argv...>",
            "options after -- would be forwarded to the command"
        );
        let list = ACTIONS.iter().find(|action| action.path == "tab list").unwrap().help("cmux");
        assert_eq!(list, "USAGE\n  cmux tab list\n\nList tabs.\n");
    }
}
