//! The face of a workspace's sidebar row, moved from the app's
//! `SidebarMapping` (CmuxNextBridge) with the same inputs and outputs: the
//! tab the row stands for and the tab it is named for, its folder line and
//! Group by Folder bucket, its kinds, its program, its status line, its
//! unread mark and notice, its progress bar, and each listed tab's
//! shortened title and folder.
//!
//! Pure, no I/O. The app maps one row per changed workspace (its row feed),
//! so one call costs O(that workspace's tabs), never O(session). What reads
//! app-only state stays in the app: a page's title and favicon (the browser
//! runtime), a chat's turn and model (acpmux's turn store), the harness icon
//! catalog (it reaches this rule as [`Tab::branded`]), the status merge
//! (`StatusMapping`) and the drawing types. The app applies those to the
//! tabs this module picks.

pub mod text;

use std::borrow::Cow;

pub use text::{
    BARE_SHELLS, DEFAULT_NAME_PREFIX, Entry, PORTS_KEY, PULL_REQUEST_KEY, abbreviate,
    abbreviate_remote, default_workspace_name, entries_status_line, entry, is_status_entry,
    shorten, status_line, trim_slash, trim_whitespace,
};

/// A tab's record kind (`TabKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabKind {
    Pty,
    Browser,
    RemoteTerminal,
    Conversation,
    Other,
}

/// A terminal agent's state as its hooks report it; only working and
/// waiting (blocked) decide anything here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Other,
}

/// A terminal's OSC 9;4 progress state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressState {
    Normal,
    Error,
    Indeterminate,
    Paused,
}

/// A terminal's OSC 9;4 progress (`TerminalProgressReport`): `value` is
/// 0...100, none when the program reported none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalProgress {
    pub state: ProgressState,
    pub value: Option<i64>,
}

/// One tab of a workspace, as the row rules read it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab<'a> {
    pub kind: TabKind,
    /// The title the terminal or page reports (`TabModel.titleText`).
    pub title: &'a str,
    /// The title the tab list shows before a folder title is shortened: the
    /// app's `TabTitleResolver`, a New Tab page's title, else the tab's
    /// display title.
    pub list_title: &'a str,
    pub cwd: Option<&'a str>,
    /// The person named the tab (`TabModel.name` is not empty).
    pub named: bool,
    /// It shows an agent chat (`TabModel.agentSession`).
    pub chat: bool,
    /// A terminal agent's hooks report on it (`TabModel.agent`).
    pub agent: Option<AgentState>,
    /// Its shell integration reports a running command (`commandSinceMs`).
    pub command_running: bool,
    /// Its title reports activity (`titleActivity`).
    pub title_activity: bool,
    /// It shows a page (Settings, a diff: `TabModel.page`).
    pub page: bool,
    /// It shows an app (`TabModel.appTab`).
    pub app_tab: bool,
    /// It is still on the New Tab page.
    pub new_tab_page: bool,
    /// Its agent has a brand mark, or its chat's harness has its own icon
    /// (`agentBrand`, `HarnessIconLookup`).
    pub branded: bool,
    /// It holds an unread notification (`hasUnread`).
    pub has_unread: bool,
    /// Its notification's id (daemon ids grow); 0 for none.
    pub notification: u64,
    /// Marked unread by hand (Mark Tab Unread).
    pub marked_unread: bool,
    /// When an agent asked for the person there (tab-attention-v1).
    pub attention_at_ms: Option<u64>,
    /// Its terminal agent's last update; 0 for none.
    pub agent_updated_ms: u64,
    /// Its notification's creation; 0 for none.
    pub notification_created_ms: u64,
    pub progress: Option<TerminalProgress>,
}

/// One pane: its tabs are the next `tabs` tabs of [`Workspace::tabs`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pane {
    pub focused_at: u64,
    pub tabs: usize,
    /// The daemon's default tab of the pane (`defaultTabIndex`).
    pub default_tab: i64,
    /// The window's selected tab, a position among the pane's tabs; none
    /// for the daemon's default tab.
    pub selected: Option<usize>,
}

/// One workspace: its panes in screen order and their tabs in pane order.
#[derive(Debug, Clone, PartialEq)]
pub struct Workspace<'a> {
    pub panes: Vec<Pane>,
    pub tabs: Vec<Tab<'a>>,
    /// Its machine is this Mac: its folders shorten against the home folder.
    pub local: bool,
    pub unread_count: u64,
    pub marked_unread: bool,
    /// The status line its hooks reported (`set_status`).
    pub status: Option<&'a str>,
    /// The daemon's workspace status entries.
    pub entries: Vec<Entry<'a>>,
    /// The workspace's reported progress (0...1; an inner none while
    /// indeterminate).
    pub reported_progress: Option<Option<f64>>,
}

/// What every row of one window shares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Context<'a> {
    /// This Mac's home folder.
    pub home: &'a str,
    /// The sidebar shows unread state (`notifications.attention.showOnSidebar`).
    pub shows_unread: bool,
    /// The New Tab page has a title to list (the app's localized one).
    pub new_tab_titled: bool,
}

/// What a row shows of its face tab.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Terminal,
    Browser,
    /// An agent: a chat, a Home conversation or an agent terminal.
    Harness,
}

/// What a workspace's tabs are: one kind, or mixed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RowKind {
    Terminal,
    Browser,
    Agent,
    Mixed,
}

/// A tab's kind in the tab list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListedKind {
    NewTab,
    AgentChat,
    /// The tab's record kind.
    Record,
}

/// The row's unread mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unread {
    None,
    Dot,
    Count(u64),
}

/// Why the row is marked, by tab index: an agent's "needs you here" reason
/// first, else the newest unread notification's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Notice {
    Attention(usize),
    Notification(usize),
}

/// A progress bar: `value` 0...1, none while indeterminate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bar {
    pub value: Option<f64>,
    pub is_error: bool,
}

/// One tab as the tab list draws it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListedTab<'a> {
    pub title: Cow<'a, str>,
    /// Its own folder as its machine's prompt writes it; none for a New Tab
    /// page.
    pub folder: Option<Cow<'a, str>>,
    pub kind: ListedKind,
    /// A New Tab page with a title: no folder, idle, no host.
    pub blank: bool,
    pub last_activity_ms: u64,
}

/// The face of one row. Tab fields are indexes into [`Workspace::tabs`].
#[derive(Debug, Clone, PartialEq)]
pub struct Face<'a> {
    /// The tab the row stands for (`frontTab`): the selected tab of the
    /// most recently focused pane.
    pub front: Option<usize>,
    /// The tab the row is named for (`labelTab`).
    pub label: Option<usize>,
    /// The tab whose name and icon the row and the window titlebar read
    /// (`faceTab`).
    pub face: Option<usize>,
    /// The work a browser front tab yields its name to (`workTab`); the app
    /// hands it to the page face of a browser tab.
    pub work: Option<usize>,
    /// The agent chat whose last message the row shows (`chatTab`).
    pub chat: Option<usize>,
    /// The tab whose folder and branch the row shows (`folderTab`).
    pub folder_tab: Option<usize>,
    /// The tab whose folder is the row's Group by Folder bucket.
    pub bucket_tab: Option<usize>,
    /// The tab whose agent the row names (`agentTab`).
    pub agent: Option<usize>,
    pub notice: Option<Notice>,
    pub kind: Kind,
    pub row_kind: RowKind,
    pub directory: Option<Cow<'a, str>>,
    pub bucket: Option<Cow<'a, str>>,
    /// The label terminal's program as its title names it (`process`).
    pub process: Option<&'a str>,
    pub status_line: Option<Cow<'a, str>>,
    /// Entry indexes of the ports and pull request elements.
    pub ports: Option<usize>,
    pub pull_request: Option<usize>,
    /// Entry indexes the status block lists.
    pub status_entries: Vec<usize>,
    /// The newest agent update or notification; 0 for none.
    pub last_activity_ms: u64,
    pub unread: Unread,
    pub progress: Option<Bar>,
    pub tabs: Vec<ListedTab<'a>>,
}

impl Workspace<'_> {
    /// Each pane with tabs and the position of its first tab.
    fn panes_with_tabs(&self) -> impl Iterator<Item = (usize, &Pane)> {
        self.panes
            .iter()
            .scan(0usize, |start, pane| {
                let first = *start;
                *start += pane.tabs;
                Some((first, pane))
            })
            .filter(|(_, pane)| pane.tabs > 0)
    }

    /// The tab `pane` (first tab at `first`) shows: the window's selection,
    /// else the daemon's default tab.
    fn selected(first: usize, pane: &Pane) -> usize {
        if let Some(selected) = pane.selected.filter(|selected| *selected < pane.tabs) {
            return first + selected;
        }
        let last = i64::try_from(pane.tabs - 1).unwrap_or(i64::MAX);
        first + usize::try_from(pane.default_tab.clamp(0, last)).unwrap_or(0)
    }

    /// The selected tab of the most recently focused pane (the first stored
    /// one on a tie); none for a workspace with no tabs.
    pub fn front_tab(&self) -> Option<usize> {
        let mut best: Option<(usize, &Pane)> = None;
        for (first, pane) in self.panes_with_tabs() {
            if best.is_none_or(|(_, current)| pane.focused_at > current.focused_at) {
                best = Some((first, pane));
            }
        }
        best.map(|(first, pane)| Self::selected(first, pane))
    }

    /// The tab a browser front tab yields its row's name to (a PR opened in
    /// a split, cmux#22249): the selected tab of the most recently focused
    /// pane that shows a chat or terminal (the first stored one on a tie).
    /// A Home, page or app tab gives no name, so it is passed over too.
    pub fn work_tab(&self) -> Option<usize> {
        let mut work: Option<(usize, u64)> = None;
        for (first, pane) in self.panes_with_tabs() {
            if work.is_some_and(|(_, focused_at)| pane.focused_at <= focused_at) {
                continue;
            }
            let index = Self::selected(first, pane);
            let Some(tab) = self.tabs.get(index) else { continue };
            let named =
                tab.chat || (tab.kind != TabKind::Conversation && !tab.page && !tab.app_tab);
            if tab.kind != TabKind::Browser && named {
                work = Some((index, pane.focused_at));
            }
        }
        work.map(|(index, _)| index)
    }

    /// The tab a row and its window's titlebar are named for: `front`,
    /// unless it is an idle shell or a New Tab page while the workspace has
    /// an agent chat; then that chat (a working or waiting one first).
    pub fn label_tab(&self, front: Option<usize>, home: &str) -> Option<usize> {
        let front = front?;
        if !self.tabs.get(front).is_some_and(|tab| is_idle(tab, home, true)) {
            return Some(front);
        }
        let mut chats =
            self.tabs.iter().enumerate().filter(|(_, tab)| tab.chat && !tab.new_tab_page);
        let first = chats.clone().next().map(|(index, _)| index);
        let busy = chats.find(|(_, tab)| tab.agent.is_some_and(AgentState::is_busy));
        Some(busy.map(|(index, _)| index).or(first).unwrap_or(front))
    }

    /// The one tab the row and the window titlebar read their name and icon
    /// from: the label tab, or for a browser one the work it yields to.
    pub fn face_tab(&self, home: &str) -> Option<usize> {
        let label = self.label_tab(self.front_tab(), home);
        if label
            .is_none_or(|index| self.tabs.get(index).is_none_or(|tab| tab.kind != TabKind::Browser))
        {
            return label;
        }
        self.work_tab().or(label)
    }

    /// The row's agent chat: `label`'s when it is one, else the first chat.
    pub fn chat_tab(&self, label: Option<usize>) -> Option<usize> {
        if let Some(label) = label.filter(|index| self.tabs.get(*index).is_some_and(|tab| tab.chat))
        {
            return Some(label);
        }
        self.tabs.iter().position(|tab| tab.chat)
    }

    /// The first tab that reports a folder. While `label` is a chat, an idle
    /// shell at home gives none: its "~" never names the row.
    pub fn folder_tab(&self, label: Option<usize>, home: &str) -> Option<usize> {
        let chat = label.is_some_and(|index| self.tabs.get(index).is_some_and(|tab| tab.chat));
        self.tabs.iter().position(|tab| {
            let Some(cwd) = tab.cwd else { return false };
            !(chat && is_idle(tab, home, false) && abbreviate(cwd, home) == "~")
        })
    }

    /// The tab whose agent the row names: a working or waiting branded one
    /// first, else the first branded one.
    pub fn agent_tab(&self) -> Option<usize> {
        let mut branded = self.tabs.iter().enumerate().filter(|(_, tab)| tab.branded);
        let first = branded.clone().next().map(|(index, _)| index);
        branded
            .find(|(_, tab)| tab.agent.is_some_and(AgentState::is_busy))
            .map(|(index, _)| index)
            .or(first)
    }

    /// Why the row is marked: the newest "needs you here" mark (the first
    /// on a tie), else the newest unread notification (the first on a tie).
    pub fn notice(&self) -> Option<Notice> {
        let attention = first_max(
            self.tabs
                .iter()
                .enumerate()
                .filter_map(|(index, tab)| Some((index, tab.attention_at_ms?))),
        );
        if let Some(index) = attention {
            return Some(Notice::Attention(index));
        }
        let unread = self.tabs.iter().enumerate().filter(|(_, tab)| tab.has_unread);
        first_max(unread.map(|(index, tab)| (index, tab.notification))).map(Notice::Notification)
    }

    /// The row's unread mark: the unread count, else a dot for a workspace
    /// or tab marked unread or a tab that needs the person; none while the
    /// sidebar hides unread state.
    pub fn unread(&self, shows_unread: bool) -> Unread {
        if !shows_unread {
            return Unread::None;
        }
        if self.unread_count > 0 {
            return Unread::Count(self.unread_count);
        }
        let marked = self.marked_unread
            || self.tabs.iter().any(|tab| tab.marked_unread || tab.attention_at_ms.is_some());
        if marked { Unread::Dot } else { Unread::None }
    }

    /// The workspace's reported progress, else the first terminal progress
    /// of its tabs.
    pub fn progress(&self) -> Option<Bar> {
        if let Some(value) = self.reported_progress {
            return Some(Bar { value, is_error: false });
        }
        self.tabs.iter().find_map(|tab| tab.progress).and_then(terminal_progress)
    }

    /// What the tabs are: one kind, or mixed; a workspace without tabs is a
    /// terminal one.
    pub fn row_kind(&self) -> RowKind {
        let mut kinds = self.tabs.iter().map(|tab| match kind(Some(tab)) {
            Kind::Harness => RowKind::Agent,
            Kind::Browser => RowKind::Browser,
            Kind::Terminal => RowKind::Terminal,
        });
        let Some(first) = kinds.next() else { return RowKind::Terminal };
        if kinds.all(|other| other == first) { first } else { RowKind::Mixed }
    }
}

impl AgentState {
    fn is_busy(self) -> bool {
        matches!(self, Self::Working | Self::Blocked)
    }
}

/// The index of the greatest value, the first one on a tie (Swift's
/// `max(by:)`).
fn first_max(items: impl Iterator<Item = (usize, u64)>) -> Option<usize> {
    let mut best: Option<(usize, u64)> = None;
    for (index, value) in items {
        if best.is_none_or(|(_, current)| value > current) {
            best = Some((index, value));
        }
    }
    best.map(|(index, _)| index)
}

/// What a tab shows: an agent (chat, Home conversation or agent terminal),
/// a page, else a terminal; a workspace with no tab is a terminal one.
pub fn kind(tab: Option<&Tab<'_>>) -> Kind {
    let Some(tab) = tab else { return Kind::Terminal };
    if tab.kind == TabKind::Conversation || tab.agent.is_some() {
        Kind::Harness
    } else if tab.kind == TabKind::Browser {
        Kind::Browser
    } else {
        Kind::Terminal
    }
}

/// A New Tab page (when `new_tab_pages` counts them), or a terminal with no
/// agent and no running command whose title is empty, a bare shell or its
/// own folder.
pub fn is_idle(tab: &Tab<'_>, home: &str, new_tab_pages: bool) -> bool {
    if new_tab_pages && tab.new_tab_page {
        return true;
    }
    if tab.kind != TabKind::Pty || tab.agent.is_some() || tab.command_running || tab.title_activity
    {
        return false;
    }
    let title = trim_whitespace(tab.title);
    let shell = title.strip_prefix('-').unwrap_or(title);
    if title.is_empty() || BARE_SHELLS.contains(&shell) {
        return true;
    }
    tab.cwd.is_some_and(|cwd| title == cwd || abbreviate(cwd, home) == title)
}

/// The front terminal's program as the shell or program titles it (OSC
/// 0/2); none for other tabs, an untitled terminal, or a title that only
/// repeats the folder (against this Mac's home, on every machine).
pub fn process<'a>(tab: &Tab<'a>, home: &str) -> Option<&'a str> {
    if tab.kind != TabKind::Pty || tab.agent.is_some() {
        return None;
    }
    let title = trim_whitespace(tab.title);
    if title.is_empty() {
        return None;
    }
    if tab.cwd.is_some_and(|cwd| title == cwd || abbreviate(cwd, home) == title) {
        return None;
    }
    Some(title)
}

/// A terminal tab titled by its own folder reads as its prompt writes it:
/// this Mac's home and another computer's home both as `~`. A title naming
/// another path, a name the person gave the tab and an agent's tab stay as
/// they are.
pub fn shortened_title<'a>(title: &'a str, tab: &Tab<'a>, local: bool, home: &str) -> Cow<'a, str> {
    let shell = !tab.chat
        && tab.agent.is_none()
        && matches!(tab.kind, TabKind::Pty | TabKind::RemoteTerminal)
        && !tab.named;
    match tab.cwd {
        Some(cwd) if shell && trim_slash(title) == trim_slash(cwd) => {
            shorten(trim_slash(cwd), local, home)
        }
        _ => Cow::Borrowed(title),
    }
}

/// A terminal's OSC 9;4 progress as a bar; none for a paused one with no
/// value.
pub fn terminal_progress(report: TerminalProgress) -> Option<Bar> {
    let value = report.value.map(|value| value as f64 / 100.0);
    match report.state {
        ProgressState::Normal => Some(Bar { value, is_error: false }),
        ProgressState::Error => Some(Bar { value: Some(value.unwrap_or(1.0)), is_error: true }),
        ProgressState::Indeterminate => Some(Bar { value: None, is_error: false }),
        ProgressState::Paused => value.map(|value| Bar { value: Some(value), is_error: false }),
    }
}

/// A tab's kind in the tab list: a New Tab page, an agent chat, else its
/// record's kind.
pub fn listed_kind(tab: &Tab<'_>) -> ListedKind {
    if tab.new_tab_page {
        ListedKind::NewTab
    } else if tab.chat {
        ListedKind::AgentChat
    } else {
        ListedKind::Record
    }
}

/// The newest agent update or notification of one tab; 0 for none.
pub fn last_activity(tab: &Tab<'_>) -> u64 {
    tab.agent_updated_ms.max(tab.notification_created_ms)
}

/// The face of `workspace`'s row.
pub fn face<'a>(workspace: &Workspace<'a>, context: &Context<'_>) -> Face<'a> {
    let home = context.home;
    let front = workspace.front_tab();
    let label = workspace.label_tab(front, home);
    let face = workspace.face_tab(home);
    let folder_tab = workspace.folder_tab(label, home);
    // Group by Folder's bucket: the front tab's folder, else any tab's.
    let bucket_tab = front
        .filter(|index| workspace.tabs.get(*index).is_some_and(|tab| tab.cwd.is_some()))
        .or_else(|| workspace.tabs.iter().position(|tab| tab.cwd.is_some()));
    let folder_of = |index: Option<usize>| {
        index
            .and_then(|index| workspace.tabs.get(index))
            .and_then(|tab| tab.cwd)
            .map(|cwd| shorten(cwd, workspace.local, home))
    };
    let tabs = workspace
        .tabs
        .iter()
        .map(|tab| {
            let blank = tab.new_tab_page && context.new_tab_titled;
            ListedTab {
                title: shortened_title(tab.list_title, tab, workspace.local, home),
                folder: if blank {
                    None
                } else {
                    tab.cwd
                        .filter(|cwd| !cwd.is_empty())
                        .map(|cwd| shorten(cwd, workspace.local, home))
                },
                kind: listed_kind(tab),
                blank,
                last_activity_ms: last_activity(tab),
            }
        })
        .collect();
    Face {
        front,
        label,
        face,
        work: workspace.work_tab(),
        chat: workspace.chat_tab(label),
        folder_tab,
        bucket_tab,
        agent: workspace.agent_tab(),
        notice: if context.shows_unread { workspace.notice() } else { None },
        kind: kind(face.and_then(|index| workspace.tabs.get(index))),
        row_kind: workspace.row_kind(),
        directory: folder_of(folder_tab),
        bucket: folder_of(bucket_tab),
        process: label
            .and_then(|index| workspace.tabs.get(index))
            .and_then(|tab| process(tab, home)),
        status_line: status_line(workspace.status, &workspace.entries),
        ports: entry(PORTS_KEY, &workspace.entries),
        pull_request: entry(PULL_REQUEST_KEY, &workspace.entries),
        status_entries: workspace
            .entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| is_status_entry(entry.key))
            .map(|(index, _)| index)
            .collect(),
        last_activity_ms: workspace.tabs.iter().map(last_activity).max().unwrap_or(0),
        unread: workspace.unread(context.shows_unread),
        progress: workspace.progress(),
        tabs,
    }
}
