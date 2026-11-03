//! The Swift `SidebarMapping` tests, ported as the corpus of the Rust rule
//! (SidebarAbbreviateCostTests, SidebarTabHomeTitleTests,
//! SidebarChatFrontTests, SidebarWorkTabTests, SidebarWorkTabIconTests,
//! SidebarRowPageBesideChatTests, and the row facts `SidebarMapping.row`
//! derives). Each test names the Swift test it ports.

use super::sidebar_face::*;

const HOME: &str = "/Users/me";

fn context() -> Context<'static> {
    Context { home: HOME, shows_unread: true, new_tab_titled: true }
}

fn tab(kind: TabKind, title: &'static str) -> Tab<'static> {
    Tab {
        kind,
        title,
        list_title: title,
        cwd: None,
        named: false,
        chat: false,
        agent: None,
        command_running: false,
        title_activity: false,
        page: false,
        app_tab: false,
        new_tab_page: false,
        branded: false,
        has_unread: false,
        notification: 0,
        marked_unread: false,
        attention_at_ms: None,
        agent_updated_ms: 0,
        notification_created_ms: 0,
        progress: None,
    }
}

fn shell(title: &'static str, cwd: &'static str) -> Tab<'static> {
    Tab { cwd: Some(cwd), ..tab(TabKind::Pty, title) }
}

/// An agent chat tab (`ConversationTabRef(agentSession:)`).
fn chat(title: &'static str) -> Tab<'static> {
    Tab { chat: true, branded: true, ..tab(TabKind::Conversation, title) }
}

fn pane(focused_at: u64, tabs: usize) -> Pane {
    Pane { focused_at, tabs, default_tab: 0, selected: None }
}

/// One pane per tab, focused at the given times, on `local`.
fn workspace(tabs: Vec<(Tab<'static>, u64)>, local: bool) -> Workspace<'static> {
    Workspace {
        panes: tabs.iter().map(|(_, focused_at)| pane(*focused_at, 1)).collect(),
        tabs: tabs.into_iter().map(|(tab, _)| tab).collect(),
        local,
        unread_count: 0,
        marked_unread: false,
        status: None,
        entries: Vec::new(),
        reported_progress: None,
    }
}

// SidebarAbbreviateCostTests.shortensOnlyThisMacsHome
#[test]
fn abbreviate_shortens_only_this_macs_home() {
    assert_eq!(abbreviate(HOME, HOME), "~");
    assert_eq!(abbreviate("/Users/me/fun/cmux", HOME), "~/fun/cmux");
    assert_eq!(abbreviate("/Users/me-other/x", HOME), "/Users/me-other/x");
    assert_eq!(abbreviate("/tmp/x", HOME), "/tmp/x");
}

#[test]
fn abbreviate_remote_shortens_an_account_home() {
    assert_eq!(abbreviate_remote("/home/cmux"), "~");
    assert_eq!(abbreviate_remote("/home/cmux/app"), "~/app");
    assert_eq!(abbreviate_remote("/home/cmux/"), "~/");
    assert_eq!(abbreviate_remote("/Users/leo/src/x"), "~/src/x");
    assert_eq!(abbreviate_remote("/Users/Shared/x"), "/Users/Shared/x");
    assert_eq!(abbreviate_remote("/home"), "/home");
    assert_eq!(abbreviate_remote("/home/"), "/home/");
    assert_eq!(abbreviate_remote("/srv/app"), "/srv/app");
    assert_eq!(abbreviate_remote("home/cmux"), "home/cmux");
}

/// SidebarTabHomeTitleTests: the listed title of one terminal tab in `cwd`
/// titled `title` (empty: untitled, which the tab list shows as its folder
/// abbreviated against this Mac's home, `TabItemMapping.title`).
fn listed_title(
    cwd: &'static str,
    title: &'static str,
    name: Option<&'static str>,
    agent: bool,
    local: bool,
) -> String {
    let untitled = name.is_none() && title.is_empty();
    let list_title: &'static str = match name {
        Some(name) => name,
        None if untitled => abbreviate(cwd, HOME).into_owned().leak(),
        None => title,
    };
    let tab = Tab {
        list_title,
        named: name.is_some(),
        agent: agent.then_some(AgentState::Working),
        ..shell(title, cwd)
    };
    face(&workspace(vec![(tab, 1)], local), &context()).tabs[0].title.to_string()
}

#[test]
fn a_cloud_shell_at_its_home_reads_as_home() {
    assert_eq!(listed_title("/home/cmux", "", None, false, false), "~");
}

#[test]
fn a_cloud_shell_titled_by_its_home_reads_as_home() {
    assert_eq!(listed_title("/home/cmux", "/home/cmux", None, false, false), "~");
}

#[test]
fn a_cloud_shell_in_a_project_says_its_folder_as_its_prompt_does() {
    assert_eq!(listed_title("/home/cmux/app", "", None, false, false), "~/app");
}

#[test]
fn this_macs_shell_titled_by_its_raw_home_reads_as_home() {
    assert_eq!(listed_title(HOME, HOME, None, false, true), "~");
}

#[test]
fn a_title_that_is_not_a_folder_is_unchanged() {
    assert_eq!(listed_title("/home/cmux", "vim notes.md", None, false, false), "vim notes.md");
    assert_eq!(listed_title("/srv/app", "/srv/app", None, false, true), "/srv/app");
}

#[test]
fn a_title_naming_its_folder_with_a_trailing_slash_is_still_its_folder() {
    assert_eq!(listed_title("/home/cmux", "/home/cmux/", None, false, false), "~");
}

#[test]
fn a_title_naming_another_folder_is_unchanged() {
    assert_eq!(
        listed_title("/home/cmux/other", "/home/cmux/project", None, false, false),
        "/home/cmux/project"
    );
    assert_eq!(
        listed_title("/Users/me/other", "/Users/me/project", None, false, true),
        "/Users/me/project"
    );
}

#[test]
fn a_renamed_tab_keeps_its_name() {
    assert_eq!(
        listed_title("/home/cmux/other", "", Some("/home/cmux/project"), false, false),
        "/home/cmux/project"
    );
    assert_eq!(listed_title("/home/cmux", "", Some("/home/cmux"), false, false), "/home/cmux");
}

#[test]
fn a_terminal_agents_tab_keeps_its_title() {
    assert_eq!(listed_title("/home/cmux", "/home/cmux", None, true, false), "/home/cmux");
    assert_eq!(listed_title("/home/cmux/app", "", None, true, false), "/home/cmux/app");
}

/// SidebarChatFrontTests: a shell titled `title` in `cwd`, focused last (2),
/// beside an agent chat (focused 1) unless `with_chat` is false.
fn chat_front(title: &'static str, cwd: &'static str, with_chat: bool) -> Workspace<'static> {
    let mut tabs = vec![(shell(title, cwd), 2)];
    if with_chat {
        tabs.push((chat("about:blank"), 1));
    }
    workspace(tabs, true)
}

// SidebarChatFrontTests.anIdleShellAtHomeLeavesTheRowToTheChat
#[test]
fn an_idle_shell_at_home_leaves_the_row_to_the_chat() {
    for title in ["~", "zsh", "-zsh", ""] {
        let row = face(&chat_front(title, HOME, true), &context());
        assert_eq!(row.face, Some(1), "{title:?}: the chat names the row");
        assert_eq!(row.label, Some(1), "{title:?}");
        assert_eq!(row.kind, Kind::Harness, "{title:?}");
        assert_eq!(row.directory, None, "{title:?}: the idle shell's \"~\" still labels the row");
        // The window's selection is untouched: the shell stays the front tab.
        assert_eq!(row.front, Some(0), "{title:?}");
    }
}

// SidebarChatFrontTests.aShellDoingWorkStillNamesTheRow
#[test]
fn a_shell_doing_work_still_names_the_row() {
    let row = face(&chat_front("npm test", HOME, true), &context());
    assert_eq!(row.face, Some(0));
    assert_eq!(row.process, Some("npm test"));
    assert_eq!(row.directory.as_deref(), Some("~"));
}

// SidebarChatFrontTests.aRunningCommandUnderABareTitleStillNamesTheRow
#[test]
fn a_running_command_under_a_bare_title_still_names_the_row() {
    let mut workspace = chat_front("~", HOME, true);
    workspace.tabs[0].command_running = true;
    let row = face(&workspace, &context());
    assert_eq!(row.face, Some(0));
    assert_eq!(row.directory.as_deref(), Some("~"));
}

// SidebarChatFrontTests.anIdleShellInAProjectKeepsItsFolder
#[test]
fn an_idle_shell_in_a_project_keeps_its_folder() {
    let row = face(&chat_front("zsh", "/tmp/project", true), &context());
    assert_eq!(row.face, Some(1));
    assert_eq!(row.directory.as_deref(), Some("/tmp/project"));
}

// SidebarChatFrontTests.withoutAChatTheShellNamesTheRow
#[test]
fn without_a_chat_the_shell_names_the_row() {
    let row = face(&chat_front("~", HOME, false), &context());
    assert_eq!(row.face, Some(0));
    assert_eq!(row.directory.as_deref(), Some("~"));
}

// SidebarChatFrontTests.aNewTabPageInFrontLeavesTheRowToTheChat
#[test]
fn a_new_tab_page_in_front_leaves_the_row_to_the_chat() {
    let mut workspace = chat_front("npm test", HOME, true);
    workspace.tabs[0].new_tab_page = true;
    let row = face(&workspace, &context());
    assert_eq!(row.face, Some(1));
    assert_eq!(row.tabs[0].kind, ListedKind::NewTab);
    assert!(row.tabs[0].blank);
    assert_eq!(row.tabs[0].folder, None);
}

// SidebarChatFrontTests.theTitlebarReadsTheChatToo
#[test]
fn the_titlebar_reads_the_chat_too() {
    let workspace = chat_front("~", HOME, true);
    let front = workspace.front_tab();
    assert_eq!(front, Some(0));
    assert_eq!(workspace.label_tab(front, HOME), Some(1));
}

#[test]
fn a_working_chat_names_the_row_over_an_earlier_idle_one() {
    let mut busy = chat("b");
    busy.agent = Some(AgentState::Blocked);
    let workspace = workspace(vec![(shell("zsh", HOME), 3), (chat("a"), 1), (busy, 2)], true);
    assert_eq!(workspace.label_tab(workspace.front_tab(), HOME), Some(2));
    assert_eq!(workspace.agent_tab(), Some(2));
}

/// SidebarWorkTabTests: terminals `a` and `b` in their own panes and a page
/// in a third, each focused at the given time.
fn work_split(a: u64, b: u64, page: u64) -> Workspace<'static> {
    workspace(
        vec![
            (tab(TabKind::Pty, "a"), a),
            (tab(TabKind::Pty, "b"), b),
            (tab(TabKind::Browser, "PR"), page),
        ],
        true,
    )
}

// SidebarWorkTabTests.aPageInASplitYieldsToTheLastFocusedWork
#[test]
fn a_page_in_a_split_yields_to_the_last_focused_work() {
    let later_b = work_split(1, 2, 3);
    assert_eq!(later_b.front_tab(), Some(2));
    assert_eq!(later_b.work_tab(), Some(1));
    assert_eq!(work_split(2, 1, 3).work_tab(), Some(0));
    // The row hands the work tab to the page face, and the face is the work's.
    let row = face(&later_b, &context());
    assert_eq!((row.front, row.work, row.face), (Some(2), Some(1), Some(1)));
}

// SidebarWorkTabTests.aPageTabIsNotWork
#[test]
fn a_page_tab_is_not_work() {
    let settings = Tab { page: true, ..tab(TabKind::Conversation, "about:blank") };
    let workspace = workspace(
        vec![(tab(TabKind::Pty, "a"), 1), (settings, 2), (tab(TabKind::Browser, "PR"), 3)],
        true,
    );
    assert_eq!(workspace.work_tab(), Some(0));
}

#[test]
fn an_app_tab_is_not_work_but_a_chat_is() {
    let app = Tab { app_tab: true, ..tab(TabKind::Other, "app") };
    let only_app = workspace(vec![(app.clone(), 2), (tab(TabKind::Browser, "PR"), 3)], true);
    assert_eq!(only_app.work_tab(), None);
    assert_eq!(only_app.face_tab(HOME), Some(1), "a page with no work keeps the row");
    let with_chat =
        workspace(vec![(chat("c"), 1), (app, 2), (tab(TabKind::Browser, "PR"), 3)], true);
    assert_eq!(with_chat.work_tab(), Some(0));
}

// SidebarWorkTabIconTests.aPageBesideWorkLeavesTheRowIconToTheWork
#[test]
fn a_page_beside_work_leaves_the_row_to_the_work() {
    let workspace = workspace(
        vec![(tab(TabKind::Pty, "coordinator"), 1), (tab(TabKind::Browser, "PR"), 2)],
        true,
    );
    let row = face(&workspace, &context());
    assert_eq!(row.front, Some(1));
    assert_eq!(row.face, Some(0));
    assert_eq!(row.kind, Kind::Terminal);
}

// SidebarRowPageBesideChatTests.theRowShowsTheChatWhereverFocusIs
#[test]
fn the_row_shows_the_chat_wherever_focus_is() {
    for chat_focused_at in [3, 1] {
        let workspace = workspace(
            vec![
                (chat("GUI push · coordinator"), chat_focused_at),
                (tab(TabKind::Browser, "PR"), 2),
            ],
            true,
        );
        let row = face(&workspace, &context());
        assert_eq!(row.front, Some(if chat_focused_at > 2 { 0 } else { 1 }));
        assert_eq!(row.face, Some(0));
        assert_eq!(row.kind, Kind::Harness);
        assert_eq!(row.agent, Some(0));
        assert_eq!(row.row_kind, RowKind::Mixed);
    }
}

// SidebarRowPageBesideChatTests.aPageWithNoWorkBesideItKeepsItsFavicon
#[test]
fn a_page_with_no_work_beside_it_keeps_the_row() {
    let row = face(&workspace(vec![(tab(TabKind::Browser, "PR"), 2)], true), &context());
    assert_eq!(row.face, Some(0));
    assert_eq!(row.kind, Kind::Browser);
    assert_eq!(row.row_kind, RowKind::Browser);
}

#[test]
fn the_front_tab_is_the_selection_of_the_newest_pane_first_on_a_tie() {
    let mut workspace =
        workspace(vec![(tab(TabKind::Pty, "a"), 5), (tab(TabKind::Pty, "b"), 5)], true);
    assert_eq!(workspace.front_tab(), Some(0));
    // Two tabs in one pane: the window's selection, else the daemon's default (clamped).
    workspace.panes =
        vec![pane(1, 0), Pane { focused_at: 1, tabs: 2, default_tab: 9, selected: None }];
    assert_eq!(workspace.front_tab(), Some(1));
    workspace.panes[1].default_tab = -3;
    assert_eq!(workspace.front_tab(), Some(0));
    workspace.panes[1].selected = Some(1);
    assert_eq!(workspace.front_tab(), Some(1));
    workspace.panes[1].selected = Some(7);
    assert_eq!(workspace.front_tab(), Some(0), "a selection the pane does not hold falls back");
    assert_eq!(Workspace { panes: vec![pane(1, 0)], tabs: vec![], ..workspace }.front_tab(), None);
}

#[test]
fn the_folder_and_bucket_come_from_the_front_tab_then_any_tab() {
    let workspace = workspace(vec![(tab(TabKind::Pty, "a"), 2), (shell("b", "/srv/b"), 1)], false);
    let row = face(&workspace, &context());
    assert_eq!(row.folder_tab, Some(1));
    assert_eq!(row.bucket_tab, Some(1));
    assert_eq!(row.bucket.as_deref(), Some("/srv/b"));
    let cloud = workspace_with_cwd("/home/cmux/app");
    let row = face(&cloud, &context());
    assert_eq!(
        row.directory.as_deref(),
        Some("~/app"),
        "another computer's folder shortens against its home"
    );
}

fn workspace_with_cwd(cwd: &'static str) -> Workspace<'static> {
    workspace(vec![(shell("vim", cwd), 1)], false)
}

#[test]
fn the_program_is_the_terminal_title_unless_it_repeats_the_folder() {
    let terminal = shell("  htop\t", "/srv");
    assert_eq!(process(&terminal, HOME), Some("htop"));
    assert_eq!(process(&shell("/srv", "/srv"), HOME), None);
    assert_eq!(process(&shell("~/x", "/Users/me/x"), HOME), None);
    assert_eq!(process(&shell(" ", "/srv"), HOME), None);
    assert_eq!(process(&Tab { agent: Some(AgentState::Other), ..terminal.clone() }, HOME), None);
    assert_eq!(process(&Tab { kind: TabKind::RemoteTerminal, ..terminal }, HOME), None);
}

#[test]
fn a_bare_shell_or_its_folder_is_idle_and_work_is_not() {
    for title in ["zsh", "-bash", "login", " fish ", "~", "", "/Users/me", "~/x"] {
        let cwd = if title == "~/x" { "/Users/me/x" } else { HOME };
        assert!(is_idle(&shell(title, cwd), HOME, false), "{title:?}");
    }
    assert!(!is_idle(&shell("vim", HOME), HOME, false));
    assert!(!is_idle(&Tab { title_activity: true, ..shell("zsh", HOME) }, HOME, false));
    assert!(!is_idle(&tab(TabKind::Browser, ""), HOME, false));
    let page = Tab { new_tab_page: true, ..tab(TabKind::Conversation, "x") };
    assert!(is_idle(&page, HOME, true));
    assert!(!is_idle(&page, HOME, false));
}

#[test]
fn the_status_line_is_the_hooks_line_else_the_entries() {
    let entries = [
        Entry { key: "ports", text: "3000" },
        Entry { key: "build", text: "ok" },
        Entry { key: "pr", text: "#12" },
        Entry { key: "empty", text: "" },
        Entry { key: "lint", text: "2 warnings" },
    ];
    assert_eq!(status_line(None, &entries).as_deref(), Some("ok · 2 warnings"));
    assert_eq!(status_line(Some("deploying"), &entries).as_deref(), Some("deploying"));
    assert_eq!(status_line(Some(""), &entries), None, "an empty hooks' line hides the entries");
    assert_eq!(status_line(None, &entries[..1]), None);
    assert_eq!(entry(PORTS_KEY, &entries), Some(0));
    assert_eq!(entry(PULL_REQUEST_KEY, &entries), Some(2));
    assert_eq!(entry(PORTS_KEY, &[Entry { key: "ports", text: "" }]), None);
    let mut workspace = workspace(vec![], true);
    workspace.entries = entries.to_vec();
    assert_eq!(face(&workspace, &context()).status_entries, vec![1, 3, 4]);
}

#[test]
fn the_unread_mark_counts_then_dots_and_hides_with_the_setting() {
    let mut workspace = workspace(vec![(tab(TabKind::Pty, "a"), 1)], true);
    assert_eq!(workspace.unread(true), Unread::None);
    workspace.tabs[0].attention_at_ms = Some(5);
    assert_eq!(workspace.unread(true), Unread::Dot);
    workspace.unread_count = 3;
    assert_eq!(workspace.unread(true), Unread::Count(3));
    assert_eq!(workspace.unread(false), Unread::None);
    workspace.unread_count = 0;
    workspace.tabs[0].attention_at_ms = None;
    workspace.marked_unread = true;
    assert_eq!(workspace.unread(true), Unread::Dot);
}

#[test]
fn the_notice_is_the_newest_attention_then_the_newest_unread() {
    let unread = |id| Tab { has_unread: true, notification: id, ..tab(TabKind::Pty, "t") };
    let mut workspace = workspace(
        vec![(unread(4), 1), (unread(9), 1), (unread(9), 1), (tab(TabKind::Pty, "x"), 1)],
        true,
    );
    assert_eq!(workspace.notice(), Some(Notice::Notification(1)), "the first of the newest");
    workspace.tabs[3].attention_at_ms = Some(2);
    workspace.tabs[0].attention_at_ms = Some(2);
    assert_eq!(workspace.notice(), Some(Notice::Attention(0)));
    assert_eq!(face(&workspace, &Context { shows_unread: false, ..context() }).notice, None);
}

#[test]
fn progress_is_the_reported_one_else_the_first_terminals() {
    let report = |state, value| Some(TerminalProgress { state, value });
    let mut workspace =
        workspace(vec![(tab(TabKind::Pty, "a"), 1), (tab(TabKind::Pty, "b"), 1)], true);
    assert_eq!(workspace.progress(), None);
    workspace.tabs[1].progress = report(ProgressState::Normal, Some(40));
    assert_eq!(workspace.progress(), Some(Bar { value: Some(0.4), is_error: false }));
    workspace.tabs[0].progress = report(ProgressState::Paused, None);
    assert_eq!(
        workspace.progress(),
        None,
        "the first report decides, a paused one with no value shows none"
    );
    workspace.reported_progress = Some(None);
    assert_eq!(workspace.progress(), Some(Bar { value: None, is_error: false }));
    assert_eq!(
        terminal_progress(TerminalProgress { state: ProgressState::Error, value: None }),
        Some(Bar { value: Some(1.0), is_error: true })
    );
    assert_eq!(
        terminal_progress(TerminalProgress { state: ProgressState::Indeterminate, value: Some(5) }),
        Some(Bar { value: None, is_error: false })
    );
    assert_eq!(
        terminal_progress(TerminalProgress { state: ProgressState::Paused, value: Some(50) }),
        Some(Bar { value: Some(0.5), is_error: false })
    );
}

#[test]
fn the_row_kind_is_one_kind_or_mixed() {
    assert_eq!(workspace(vec![], true).row_kind(), RowKind::Terminal);
    let agent_terminal = Tab { agent: Some(AgentState::Working), ..tab(TabKind::Pty, "claude") };
    assert_eq!(
        workspace(vec![(agent_terminal.clone(), 1), (chat("c"), 1)], true).row_kind(),
        RowKind::Agent
    );
    assert_eq!(
        workspace(vec![(agent_terminal, 1), (tab(TabKind::Pty, "zsh"), 1)], true).row_kind(),
        RowKind::Mixed
    );
    assert_eq!(kind(None), Kind::Terminal);
    assert_eq!(kind(Some(&tab(TabKind::RemoteTerminal, "r"))), Kind::Terminal);
}

#[test]
fn last_activity_is_the_newest_agent_update_or_notification() {
    let a = Tab { agent_updated_ms: 7, notification_created_ms: 3, ..tab(TabKind::Pty, "a") };
    let b = Tab { notification_created_ms: 11, ..tab(TabKind::Pty, "b") };
    let row = face(&workspace(vec![(a, 1), (b, 1), (tab(TabKind::Pty, "c"), 1)], true), &context());
    assert_eq!(row.last_activity_ms, 11);
    assert_eq!(row.tabs.iter().map(|tab| tab.last_activity_ms).collect::<Vec<_>>(), vec![7, 11, 0]);
}

#[test]
fn listed_tabs_keep_their_kind_and_folder() {
    let page = Tab { new_tab_page: true, cwd: Some(HOME), ..tab(TabKind::Pty, "") };
    let empty = Tab { cwd: Some(""), ..tab(TabKind::Pty, "x") };
    let workspace = workspace(
        vec![(chat("c"), 1), (page, 1), (empty, 1), (shell("y", "/Users/me/p"), 1)],
        true,
    );
    let row = face(&workspace, &context());
    let kinds: Vec<_> = row.tabs.iter().map(|tab| tab.kind).collect();
    assert_eq!(
        kinds,
        vec![ListedKind::AgentChat, ListedKind::NewTab, ListedKind::Record, ListedKind::Record]
    );
    let folders: Vec<_> = row.tabs.iter().map(|tab| tab.folder.as_deref()).collect();
    assert_eq!(folders, vec![None, None, None, Some("~/p")]);
    // Without a New Tab title the page lists as a tab with its folder.
    let untitled = face(&workspace, &Context { new_tab_titled: false, ..context() });
    assert!(!untitled.tabs[1].blank);
    assert_eq!(untitled.tabs[1].folder.as_deref(), Some("~"));
}

#[test]
fn the_next_default_name_counts_listed_and_reserved_names() {
    assert_eq!(default_workspace_name(&[], &[]), "workspace-1");
    assert_eq!(default_workspace_name(&["workspace-1", "workspace-2"], &[]), "workspace-3");
    // Renamed workspaces still count: the sequence never restarts below the count.
    assert_eq!(default_workspace_name(&["shell", "api"], &[]), "workspace-3");
    assert_eq!(default_workspace_name(&["workspace-9"], &[]), "workspace-10");
    // A key-repeat burst: each reserved name counts once, a listed one is not counted twice.
    assert_eq!(default_workspace_name(&["workspace-1"], &["workspace-2"]), "workspace-3");
    assert_eq!(
        default_workspace_name(&["workspace-1", "workspace-2"], &["workspace-2"]),
        "workspace-3"
    );
    // Only ASCII digits name a number (the daemon's own parse also takes `+7`).
    assert_eq!(
        default_workspace_name(&["workspace-+7", "workspace-", "workspace-٣"], &[]),
        "workspace-4"
    );
    assert_eq!(default_workspace_name(&["workspace-007"], &[]), "workspace-8");
    assert_eq!(
        default_workspace_name(&["workspace-99999999999999999999"], &[]),
        "workspace-2",
        "out of range is no number"
    );
}

#[test]
fn trim_slash_and_whitespace_follow_swift() {
    assert_eq!(trim_slash("/"), "/");
    assert_eq!(trim_slash("/a/"), "/a");
    assert_eq!(trim_slash("/a//"), "/a/");
    assert_eq!(trim_whitespace("\u{3000} a\u{A0}\t"), "a");
    assert_eq!(trim_whitespace("\na\n"), "\na\n", "`.whitespaces` keeps newlines");
}

/// The public model never panics: pane tab counts that miss the tabs give
/// no tab, not an index out of bounds.
#[test]
fn pane_counts_past_the_tabs_give_no_tab() {
    let mut workspace = workspace(vec![(tab(TabKind::Browser, "PR"), 1)], true);
    workspace.panes = vec![Pane { focused_at: 2, tabs: 3, default_tab: 2, selected: None }];
    let row = face(&workspace, &context());
    assert_eq!(row.front, Some(2));
    assert_eq!((row.label, row.face, row.work, row.process), (Some(2), Some(2), None, None));
    assert_eq!(row.kind, Kind::Terminal);
}
