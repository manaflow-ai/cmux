use super::*;

fn part() -> LeavingPart {
    LeavingPart { same_daemon: true, ..LeavingPart::default() }
}

// MARK: TabCloseGuard (TabCloseGuardTests, HiddenTabCloseTests)

#[test]
fn a_close_of_kept_panes_on_its_daemon_hides() {
    assert!(hides(&[part(), part()], false));
}

#[test]
fn no_parts_or_a_close_known_to_ask_never_hides() {
    assert!(!hides(&[], false));
    assert!(!hides(&[part()], true));
}

#[test]
fn a_part_on_another_daemon_keeps_every_tab_in_place() {
    assert!(!hides(&[part(), LeavingPart { same_daemon: false, ..part() }], false));
}

#[test]
fn an_emptied_pane_hides_only_when_it_can_show_itself_leaving() {
    let emptied = LeavingPart { emptied: true, ..part() };
    assert!(!hides(&[emptied], false));
    assert!(hides(&[LeavingPart { can_show_pane_close: true, ..emptied }], false));
}

#[test]
fn an_emptied_pane_with_a_browser_tab_never_hides() {
    let emptied =
        LeavingPart { emptied: true, can_show_pane_close: true, closes_browser: true, ..part() };
    assert!(!hides(&[emptied], false));
    // A kept pane's browser tab hides: its pane stays.
    assert!(hides(&[LeavingPart { closes_browser: true, ..part() }], false));
}

#[test]
fn a_page_that_decides_its_close_never_hides() {
    assert!(!hides(&[LeavingPart { page_decides: true, ..part() }], false));
}

#[test]
fn a_key_down_press_keeps_its_repeat() {
    assert_eq!(
        press(PressEvent::KeyDown, true),
        Press { event_time: true, is_key: true, is_repeat: true }
    );
    assert_eq!(
        press(PressEvent::KeyDown, false),
        Press { event_time: true, is_key: true, is_repeat: false }
    );
}

#[test]
fn a_mouse_or_key_up_press_is_not_a_key() {
    for event in [PressEvent::Mouse, PressEvent::KeyUp] {
        assert_eq!(press(event, true), Press { event_time: true, is_key: false, is_repeat: false });
    }
}

#[test]
fn no_event_reads_the_invocations_time() {
    assert_eq!(
        press(PressEvent::None, true),
        Press { event_time: false, is_key: false, is_repeat: false }
    );
}

#[test]
fn an_unknown_event_reads_as_none() {
    let event: PressEvent = serde_json::from_str("\"scrollWheel\"").unwrap();
    assert_eq!(event, PressEvent::None);
}

fn titles(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

#[test]
fn one_tabs_agent_question_names_the_tab_and_the_agent() {
    let prompt =
        tab_close_prompt(&Warning::Agent { name: Some("claude".into()) }, &titles(&["build"]));
    assert_eq!(prompt.title, TabCloseTitle::One { title: "build".into() });
    assert_eq!(prompt.body, vec![TabCloseLine::AgentWorking { agent: Some("claude".into()) }]);
    assert_eq!(prompt.suppresses, Suppresses::AgentSession);
}

#[test]
fn an_unnamed_agent_is_the_agent() {
    let prompt = tab_close_prompt(&Warning::Agent { name: None }, &titles(&["a", "b"]));
    assert_eq!(prompt.title, TabCloseTitle::Count { count: 2 });
    assert_eq!(prompt.body, vec![TabCloseLine::AgentWorking { agent: None }]);
}

#[test]
fn programs_and_unanswered_terminals_are_two_sentences() {
    let warning =
        Warning::Programs { programs: titles(&["top", "vim"]), unanswered: titles(&["shell"]) };
    let prompt = tab_close_prompt(&warning, &titles(&["a", "b", "c"]));
    assert_eq!(prompt.title, TabCloseTitle::Count { count: 3 });
    assert_eq!(
        prompt.body,
        vec![
            TabCloseLine::StillRunning { joined: "top, vim".into() },
            TabCloseLine::NoAnswer { joined: "shell".into() }
        ]
    );
    assert_eq!(prompt.suppresses, Suppresses::Tab);
}

#[test]
fn only_programs_or_only_unanswered_is_one_sentence() {
    let running = tab_close_prompt(
        &Warning::Programs { programs: titles(&["top"]), unanswered: vec![] },
        &titles(&["x"]),
    );
    assert_eq!(running.body, vec![TabCloseLine::StillRunning { joined: "top".into() }]);
    let silent = tab_close_prompt(
        &Warning::Programs { programs: vec![], unanswered: titles(&["x"]) },
        &titles(&["x"]),
    );
    assert_eq!(silent.body, vec![TabCloseLine::NoAnswer { joined: "x".into() }]);
}

#[test]
fn the_prompt_serializes_for_the_app() {
    let prompt = tab_close_prompt(&Warning::Agent { name: None }, &titles(&["t"]));
    assert_eq!(
        serde_json::to_value(prompt).unwrap(),
        serde_json::json!({
            "title": {"kind": "one", "title": "t"},
            "body": [{"kind": "agentWorking", "agent": null}],
            "suppresses": "agentSession"
        })
    );
}

// MARK: TabLifecycle (TabLifecycleTests, NewTabKindTests)

fn chat(kind: ChatKind) -> ChatTabFacts {
    ChatTabFacts { kind, user: true, shown: true, ..ChatTabFacts::default() }
}

#[test]
fn a_persons_chat_goes_through_the_column_and_docks() {
    assert_eq!(
        chat_tab_route(chat(ChatKind::Agent)),
        ChatTabRoute { as_tab: false, column: true, docks: true }
    );
}

#[test]
fn a_chat_placed_here_does_not_dock() {
    let route = chat_tab_route(ChatTabFacts { placed_here: true, ..chat(ChatKind::Agent) });
    assert_eq!(route, ChatTabRoute { as_tab: false, column: true, docks: false });
}

#[test]
fn option_click_on_the_plus_opens_a_tab_here() {
    let route = chat_tab_route(ChatTabFacts { plus_chat_is_tab: true, ..chat(ChatKind::Agent) });
    assert_eq!(route, ChatTabRoute { as_tab: true, column: false, docks: false });
}

#[test]
fn option_click_does_not_make_a_page_a_tab() {
    let route = chat_tab_route(ChatTabFacts { plus_chat_is_tab: true, ..chat(ChatKind::Page) });
    assert_eq!(route, ChatTabRoute { as_tab: false, column: true, docks: false });
}

#[test]
fn a_kept_new_tab_page_stays_in_its_pane() {
    let route = chat_tab_route(ChatTabFacts { keeps_new_tab_page: true, ..chat(ChatKind::Page) });
    assert_eq!(route, ChatTabRoute { as_tab: false, column: false, docks: false });
    // The keep is the page's: a chat from that pane still goes through the column.
    assert!(
        chat_tab_route(ChatTabFacts { keeps_new_tab_page: true, ..chat(ChatKind::Agent) }).column
    );
}

#[test]
fn a_scripts_chat_never_routes_nor_opens_as_a_tab() {
    let route = chat_tab_route(ChatTabFacts {
        user: false,
        plus_chat_is_tab: true,
        ..chat(ChatKind::Agent)
    });
    assert_eq!(route, ChatTabRoute { as_tab: false, column: false, docks: true });
}

#[test]
fn an_unshown_pane_neither_routes_nor_docks() {
    let route = chat_tab_route(ChatTabFacts { shown: false, ..chat(ChatKind::Agent) });
    assert_eq!(route, ChatTabRoute { as_tab: false, column: false, docks: false });
}

fn answer(decision: &str, reason: Option<&str>) -> ReopenAnswer {
    ReopenAnswer { decision: Some(decision.into()), reason: reason.map(Into::into), has_tab: true }
}

#[test]
fn a_reopen_goes_or_is_already_there() {
    assert_eq!(reopen_step(&answer("reopen", None)), ReopenStep::Reopen);
    assert_eq!(reopen_step(&answer("same", None)), ReopenStep::Same);
}

#[test]
fn a_refused_reopen_says_why() {
    assert_eq!(
        reopen_step(&answer("refuse", Some("proxiedTabStaysInChromium"))),
        ReopenStep::Refuse(ReopenRefusal::ProxiedTabStaysInChromium)
    );
    assert_eq!(
        reopen_step(&answer("refuse", Some("chromiumUnavailable"))),
        ReopenStep::Refuse(ReopenRefusal::ChromiumUnavailable)
    );
    assert_eq!(
        reopen_step(&answer("refuse", Some("notABrowserTab"))),
        ReopenStep::Refuse(ReopenRefusal::NotABrowserTab)
    );
    assert_eq!(
        reopen_step(&answer("refuse", None)),
        ReopenStep::Refuse(ReopenRefusal::NotABrowserTab)
    );
}

#[test]
fn no_answer_or_no_tab_is_not_a_browser_tab() {
    assert_eq!(
        reopen_step(&ReopenAnswer { has_tab: true, ..ReopenAnswer::default() }),
        ReopenStep::Refuse(ReopenRefusal::NotABrowserTab)
    );
    assert_eq!(
        reopen_step(&ReopenAnswer { has_tab: false, ..answer("reopen", None) }),
        ReopenStep::Refuse(ReopenRefusal::NotABrowserTab)
    );
}

#[test]
fn the_reopen_step_serializes_for_the_app() {
    assert_eq!(
        serde_json::to_value(ReopenStep::Reopen).unwrap(),
        serde_json::json!({"kind": "reopen"})
    );
    assert_eq!(
        serde_json::to_value(ReopenStep::Refuse(ReopenRefusal::ChromiumUnavailable)).unwrap(),
        serde_json::json!({"kind": "refuse", "refusal": "chromiumUnavailable"})
    );
}

#[test]
fn a_link_opens_in_another_pane_or_a_column_beside() {
    assert_eq!(
        link_open(LinkTarget::Pane { other: true }),
        LinkOpen { in_target_pane: true, new_column_beside: false }
    );
    assert_eq!(
        link_open(LinkTarget::Pane { other: false }),
        LinkOpen { in_target_pane: false, new_column_beside: false }
    );
    assert_eq!(
        link_open(LinkTarget::SplitRight),
        LinkOpen { in_target_pane: false, new_column_beside: true }
    );
    assert_eq!(
        link_open(LinkTarget::NewColumn),
        LinkOpen { in_target_pane: false, new_column_beside: true }
    );
    assert_eq!(
        link_open(LinkTarget::Other),
        LinkOpen { in_target_pane: false, new_column_beside: false }
    );
}

#[test]
fn an_unknown_link_target_reads_as_other() {
    let target: LinkTarget = serde_json::from_str(r#"{"kind":"splitDown"}"#).unwrap();
    assert_eq!(target, LinkTarget::Other);
}

// MARK: TabRestart (TabRestartTests)

#[test]
fn restart_runs_only_on_a_sure_no_refusal() {
    assert_eq!(restart_step(None, true), RestartStep::Restart);
    assert_eq!(restart_step(None, false), RestartStep::RefuseTabNotDead);
}

#[test]
fn a_tab_not_a_terminal_says_so_and_any_other_refusal_is_not_dead() {
    assert_eq!(restart_step(Some("notATerminal"), true), RestartStep::RefuseNotATerminal);
    assert_eq!(restart_step(Some("notATerminal"), false), RestartStep::RefuseNotATerminal);
    assert_eq!(restart_step(Some("tabNotDead"), true), RestartStep::RefuseTabNotDead);
}

// MARK: HistoryHandlers (HistoryHandlersTests)

#[test]
fn history_opens_an_available_entry() {
    assert_eq!(history_opening(Lookup::Found, true), HistoryOpening::Open);
}

#[test]
fn an_unavailable_or_gone_entry_is_gone_and_a_loading_one_waits() {
    assert_eq!(history_opening(Lookup::Found, false), HistoryOpening::EntryGone);
    assert_eq!(history_opening(Lookup::Gone, true), HistoryOpening::EntryGone);
    assert_eq!(history_opening(Lookup::StillLoading, true), HistoryOpening::StillLoading);
    assert_eq!(history_opening(Lookup::StillLoading, false), HistoryOpening::StillLoading);
}

// MARK: CloseUndoToasts (CloseUndoToastsTests)

#[test]
fn recent_items_keep_the_newest_eight() {
    assert_eq!(recent_overflow(0), 0);
    assert_eq!(recent_overflow(8), 0);
    assert_eq!(recent_overflow(9), 1);
    assert_eq!(recent_overflow(20), 12);
}

#[test]
fn the_toast_counts_tabs_or_names_the_one() {
    assert_eq!(toast_message(3, "x"), ToastMessage::TabsClosed { count: 3 });
    assert_eq!(toast_message(1, "build"), ToastMessage::TabClosed { title: "build".into() });
    assert_eq!(toast_message(1, ""), ToastMessage::Untitled);
    assert_eq!(toast_message(0, ""), ToastMessage::Untitled);
}

#[test]
fn closes_on_one_daemon_are_one_group() {
    assert!(one_group(&[0, 0]));
    assert!(one_group(&[2, 2, 2]));
    assert!(!one_group(&[0]));
    assert!(!one_group(&[]));
    assert!(!one_group(&[0, 1]));
}

// MARK: Workspace closes (WorkspaceBulkCloseTests, WorkspaceGroupCloseTests)

fn bulk(count: usize) -> BulkRunFacts {
    BulkRunFacts {
        user: true,
        count,
        survivor: true,
        refuses_empty: true,
        ..BulkRunFacts::default()
    }
}

#[test]
fn nothing_to_close_is_refused_when_the_close_says_so() {
    assert_eq!(bulk_run(bulk(0)), BulkRun::NothingToClose);
    assert_eq!(bulk_run(BulkRunFacts { refuses_empty: false, ..bulk(0) }), BulkRun::Close);
}

#[test]
fn a_persons_close_of_rows_in_one_window_is_the_selection_close() {
    assert_eq!(bulk_run(BulkRunFacts { one_window: true, ..bulk(2) }), BulkRun::Selection);
    // Close Others in Group closes whole groups here.
    assert_eq!(
        bulk_run(BulkRunFacts { one_window: true, by_group: true, ..bulk(2) }),
        BulkRun::CloseWithUndo
    );
}

#[test]
fn a_persons_close_of_two_gets_the_undo_where_a_window_stays() {
    assert_eq!(bulk_run(bulk(2)), BulkRun::CloseWithUndo);
    assert_eq!(bulk_run(BulkRunFacts { survivor: false, ..bulk(2) }), BulkRun::Close);
}

#[test]
fn one_workspace_or_automation_gets_no_toast() {
    assert_eq!(bulk_run(BulkRunFacts { one_window: true, ..bulk(1) }), BulkRun::Close);
    assert_eq!(bulk_run(BulkRunFacts { user: false, one_window: true, ..bulk(3) }), BulkRun::Close);
}

#[test]
fn a_group_close_offers_undo_for_a_persons_close_of_listed_workspaces() {
    assert!(group_close_offers_undo(true, 1, true));
    assert!(!group_close_offers_undo(false, 1, true));
    assert!(!group_close_offers_undo(true, 0, true));
    assert!(!group_close_offers_undo(true, 1, false));
}

#[test]
fn a_selection_close_offers_undo_for_two_or_more() {
    assert!(selection_offers_undo(2, true));
    assert!(!selection_offers_undo(1, true));
    assert!(!selection_offers_undo(2, false));
}

// MARK: DestructiveConfirmation (DestructiveConfirmationTests)

#[test]
fn the_cloud_and_worktree_actions_ask_their_fixed_question() {
    assert_eq!(fixed_prompt("cloudKillMachine"), Some(FixedPrompt::KillMachine));
    assert_eq!(fixed_prompt("palette.cloud.deleteSnapshot"), Some(FixedPrompt::DeleteSnapshot));
    assert_eq!(fixed_prompt("cloudFileRemove"), Some(FixedPrompt::RemoveFile));
    assert_eq!(fixed_prompt("cloud.secret.remove"), Some(FixedPrompt::SecretRemove));
    assert_eq!(fixed_prompt("cloudFirewallDelete"), Some(FixedPrompt::DeleteFirewallRule));
    assert_eq!(fixed_prompt("git.worktree.remove"), Some(FixedPrompt::WorktreeRemove));
}

#[test]
fn other_actions_have_no_fixed_question() {
    assert_eq!(fixed_prompt("workspace.close"), None);
    assert_eq!(fixed_prompt("closeTab"), None);
    assert_eq!(fixed_prompt(""), None);
}

#[test]
fn return_confirms_all_but_the_questions_after_a_read() {
    assert!(fixed_returns_confirm(FixedPrompt::KillMachine));
    assert!(fixed_returns_confirm(FixedPrompt::DeleteSnapshot));
    assert!(fixed_returns_confirm(FixedPrompt::RemoveFile));
    assert!(fixed_returns_confirm(FixedPrompt::DeleteFirewallRule));
    assert!(!fixed_returns_confirm(FixedPrompt::SecretRemove));
    assert!(!fixed_returns_confirm(FixedPrompt::WorktreeRemove));
}

// MARK: DaemonClosedHistory (DaemonClosedHistoryTests)

#[test]
fn history_ids_round_trip() {
    assert_eq!(history_id("abc"), "daemon:abc");
    assert_eq!(daemon_id(&history_id("abc")), Some("abc"));
    assert_eq!(daemon_id("browser:abc"), None);
    assert_eq!(daemon_id("daemon:"), Some(""));
}

#[test]
fn a_window_record_names_its_window_after_the_install() {
    assert_eq!(record_window("install/window-1"), "window-1");
    assert_eq!(record_window("install/a/b"), "a/b");
    assert_eq!(record_window("window-1"), "window-1");
}

#[test]
fn since_is_milliseconds_never_negative() {
    assert_eq!(since_ms(1.5), 1500);
    assert_eq!(since_ms(-3.0), 0);
    assert_eq!(since_ms(f64::NAN), 0);
}

#[test]
fn clear_since_takes_items_closed_at_or_after() {
    assert!(clears(5, None));
    assert!(clears(5, Some(5)));
    assert!(clears(6, Some(5)));
    assert!(!clears(4, Some(5)));
}

#[test]
fn a_gone_workspace_says_no_recently_closed_workspace() {
    assert_eq!(
        reopen_failure(ItemKind::Workspace, false, Some("resource.not_found")),
        ReopenFailure::NoRecentlyClosedWorkspace
    );
    assert_eq!(
        reopen_failure(ItemKind::Workspace, true, Some("resource.not_found")),
        ReopenFailure::Error
    );
    assert_eq!(
        reopen_failure(ItemKind::Tab, false, Some("resource.not_found")),
        ReopenFailure::Error
    );
    assert_eq!(reopen_failure(ItemKind::Workspace, false, Some("io")), ReopenFailure::Error);
    assert_eq!(reopen_failure(ItemKind::Workspace, false, None), ReopenFailure::Error);
}

#[test]
fn a_delete_of_a_gone_item_is_done() {
    assert!(delete_done(Some("resource.not_found")));
    assert!(!delete_done(Some("io")));
    assert!(!delete_done(None));
}

#[test]
fn what_a_reopen_shows() {
    assert_eq!(reopen_show(ItemKind::Workspace, true, false), ReopenShow::Nothing);
    assert_eq!(reopen_show(ItemKind::Window, false, false), ReopenShow::Window);
    assert_eq!(reopen_show(ItemKind::Tab, false, true), ReopenShow::SelectTab);
    assert_eq!(reopen_show(ItemKind::Tab, false, false), ReopenShow::Show);
    assert_eq!(reopen_show(ItemKind::Screen, false, true), ReopenShow::Show);
    assert_eq!(reopen_show(ItemKind::Workspace, false, true), ReopenShow::Workspace);
}
