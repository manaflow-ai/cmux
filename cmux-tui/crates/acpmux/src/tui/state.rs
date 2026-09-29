//! Plain state types for the TUI `App`: layout areas, focus, overlays, forms, drafts.

use super::*;

#[derive(Debug, Default, Clone, Copy)]
pub struct Areas {
    pub sidebar: Rect,
    /// The sidebar's right rule; dragging it resizes the sidebar.
    pub sidebar_rule: Rect,
    pub transcript: Rect,
    /// The conversation column inside the transcript: rows, the composer
    /// and a permission card share it. Narrower than the pane on wide
    /// terminals, as the Codex app centers its conversation.
    pub column: Rect,
    pub composer: Rect,
    pub status: Rect,
}

pub(super) const WHEEL_ROWS: isize = 3;
pub(super) const MULTI_CLICK_MS: u128 = 500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptImage {
    pub name: String,
    pub mime_type: String,
    pub data: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Input,
    Sidebar,
    Command,
    /// The transcript pane: j/k scroll, Enter or Esc returns to the composer.
    Transcript,
}

/// A modal layer drawn over the main screen. Only one at a time.
/// A collapsible in the transcript: a whole turn (keyed by its user
/// message), a run of tool calls (keyed by its first tool), or one item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Toggle {
    Turn(usize),
    Group(usize),
    Item(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SidebarNav {
    Session(usize),
    ShowMore(String),
}

pub enum Overlay {
    None,
    /// Right-click context menu.
    Menu(Menu),
    Help,
    /// Add a remote daemon over ssh: one text field.
    AddHost { text: Editor },
    /// Change the working directory: one text field. On a live session this
    /// forks into a new draft, since a running agent cannot move.
    Directory { text: Editor },
    NewSession(NewForm),
    Picker(Picker),
    Confirm { title: String, action: ConfirmAction },
}

#[derive(Debug, Clone)]
pub enum ConfirmAction {
    Kill { id: String, purge: bool },
}

pub struct NewForm {
    pub harnesses: Vec<String>,
    pub agent: usize,
    pub name: Editor,
    pub cwd: Editor,
    pub policy: usize,
    pub prompt: Editor,
    /// 0 agent, 1 name, 2 directory, 3 permissions, 4 first message
    pub field: usize,
}

/// A pending session: shown in the sidebar, created on first send.
#[derive(Debug, Clone)]
pub struct Draft {
    pub id: u64,
    /// Create on this peer daemon instead of the local one.
    pub peer: Option<String>,
    pub harness: String,
    pub cwd: String,
    pub policy: String,
    pub model: Option<String>,
    pub creating: bool,
    /// The message typed so far, kept when switching between drafts.
    pub text: Editor,
    /// Failures while creating this draft, shown in red under the summary.
    pub errors: Vec<String>,
    /// Thinking effort to apply right after the session is created.
    pub effort: Option<String>,
    pub images: Vec<PromptImage>,
}

pub const POLICIES: [&str; 5] = ["ask", "approve-reads", "approve-edits", "approve-all", "deny-all"];

#[derive(Debug, Clone)]
pub enum PickTarget {
    /// A palette row: the action name.
    Action,
    /// Thinking effort for the current draft.
    DraftEffort,
    /// Session id. A model row from another harness forks into a draft.
    Model(Option<String>),
    Mode(String),
    /// Permission policy for a live session (Some) or the current draft (None).
    Policy(Option<String>),
    /// session id, config id
    Config(String, String),
    /// An inline `$skill-id` reference for the composer.
    Skill { replace_prefix: bool },
    DraftHarness,
    Agent,
}

pub enum AppMsg {
    DraftFailed,
    Models(Value),
    HarnessCatalog(u64, Value),
    Sessions(Vec<Value>),
    Attached { id: String, detail: Value, events: Vec<Value> },
    Agents(Vec<String>, Option<String>),
    Status(Value),
    Info(String),
    Error(String),
    Created(String),
}
