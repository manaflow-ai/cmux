use super::*;

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn each_bulk_close_has_its_plan_and_its_nothing_to_close() {
    assert_eq!(BULK_CLOSES.len(), 8);
    let below = bulk_close("palette.closeWorkspacesBelow").unwrap();
    assert_eq!(below.plan, BulkPlan::AroundSelection);
    assert_eq!(below.nothing_to_close, Some(NothingToClose::NoWorkspacesBelow));
    let others = bulk_close("workspaceGroup.closeOthers").unwrap();
    assert!(others.by_group && others.nothing_to_close.is_none());
    assert!(!bulk_close("workspace.closeAll").unwrap().by_group);
    assert!(bulk_close("closeWorkspace").is_none());
}

#[test]
fn the_survivor_is_the_active_window_first_then_any_that_keeps_one() {
    let windows = vec![ids(&["a", "b"]), ids(&["c"]), ids(&[])];
    assert_eq!(survivor(Some(1), &windows, &ids(&["a"])), Some(1));
    assert_eq!(survivor(Some(1), &windows, &ids(&["c"])), Some(0));
    assert_eq!(survivor(None, &windows, &ids(&["a", "b", "c"])), None);
    assert_eq!(survivor(Some(9), &windows, &ids(&["c"])), Some(0));
}

#[test]
fn rows_of_one_window_close_together_and_rows_of_two_do_not() {
    assert_eq!(rows_window(&[Some("w".into()), None, Some("w".into())]), Some(Some("w".into())));
    assert_eq!(rows_window(&[None]), Some(None));
    assert_eq!(rows_window(&[Some("w".into()), Some("v".into())]), None);
}

#[test]
fn a_running_program_asks_with_dont_ask_again() {
    let facts =
        CloseFacts { count: 2, programs: ids(&["vim", "top", "vim"]), ..CloseFacts::default() };
    let prompt = close_prompt(&facts).unwrap();
    assert_eq!(prompt.title, CloseTitle::Count { count: 2 });
    assert_eq!(prompt.body, CloseBody::Running { programs: ids(&["top", "vim"]) });
    assert!(prompt.suppresses_warning);
}

#[test]
fn several_closes_with_no_window_left_ask_without_dont_ask_again() {
    let facts =
        CloseFacts { count: 3, ask_without_undo: true, incognito: true, ..CloseFacts::default() };
    let prompt = close_prompt(&facts).unwrap();
    assert_eq!(prompt.body, CloseBody::NoUndo { incognito: true });
    assert!(!prompt.suppresses_warning);
    assert_eq!(
        close_prompt(&CloseFacts { count: 1, ask_without_undo: true, ..CloseFacts::default() }),
        None
    );
    assert_eq!(close_prompt(&CloseFacts { count: 2, ..CloseFacts::default() }), None);
    let one = CloseFacts { count: 1, programs: ids(&["vim"]), ..CloseFacts::default() };
    assert_eq!(close_prompt(&one).unwrap().title, CloseTitle::One);
    let titled = CloseFacts { titled: true, ..one };
    assert_eq!(close_prompt(&titled).unwrap().title, CloseTitle::Given);
}

#[test]
fn each_destructive_action_routes_to_its_question() {
    assert_eq!(confirmation("closeWorkspace", false), Confirmation::InHandler);
    assert_eq!(confirmation("palette.closeOtherWorkspaces", false), Confirmation::BulkClose);
    assert_eq!(confirmation("workspace.stashAndClose", true), Confirmation::Stash);
    assert_eq!(confirmation("space.delete", false), Confirmation::SpaceDelete);
    assert_eq!(confirmation("tabGroup.close", false), Confirmation::TabGroupClose);
    assert_eq!(confirmation("workspace.rename", false), Confirmation::None);
}

#[test]
fn a_space_delete_asks_only_for_a_running_program() {
    let base = SpaceDeleteFacts { warn: true, resolved: true, ..SpaceDeleteFacts::default() };
    assert_eq!(space_delete(&base), SpaceDelete::ReadPrograms);
    let read = SpaceDeleteFacts { programs: Some(ids(&["vim"])), ..base };
    assert_eq!(space_delete(&read), SpaceDelete::Prompt { programs: ids(&["vim"]) });
    assert_eq!(
        space_delete(&SpaceDeleteFacts { programs: Some(vec![]), ..base }),
        SpaceDelete::None
    );
    assert_eq!(space_delete(&SpaceDeleteFacts { moves: true, ..read.clone() }), SpaceDelete::None);
    assert_eq!(
        space_delete(&SpaceDeleteFacts { default_space: true, ..read.clone() }),
        SpaceDelete::None
    );
    assert_eq!(space_delete(&SpaceDeleteFacts { warn: false, ..read }), SpaceDelete::None);
}

#[test]
fn clearing_defaults_asks_while_the_space_has_them_and_asks_the_daemon_first() {
    let base =
        ClearDefaultsFacts { resolved: true, connected: true, ..ClearDefaultsFacts::default() };
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { shown: true, ..base }),
        ClearDefaults::Ask
    );
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { in_flight: true, ..base }),
        ClearDefaults::Ask
    );
    assert_eq!(space_clear_defaults(base), ClearDefaults::ReadDaemon);
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { connected: false, ..base }),
        ClearDefaults::Run
    );
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { held: HeldDefaults::Held, ..base }),
        ClearDefaults::Ask
    );
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { held: HeldDefaults::Unanswered, ..base }),
        ClearDefaults::Ask
    );
    assert_eq!(
        space_clear_defaults(ClearDefaultsFacts { held: HeldDefaults::Empty, ..base }),
        ClearDefaults::Run
    );
}

fn arg(text: &str) -> DefaultsArgument {
    DefaultsArgument { text: Some(text.to_owned()) }
}

#[test]
fn defaults_keep_the_field_a_run_does_not_name() {
    let patch = defaults_patch(Some(&arg(" /Users/me/src ")), None).unwrap();
    assert_eq!(patch.cwd, Some(CwdChange::Set { path: "/Users/me/src".into() }));
    assert_eq!(patch.env, None);
    let patch = defaults_patch(None, Some(&arg(r#"{"A":"1"}"#))).unwrap();
    assert_eq!(patch.cwd, None);
    assert_eq!(patch.env.unwrap().get("A").map(String::as_str), Some("1"));
}

#[test]
fn empty_defaults_clear_and_bad_ones_are_refused() {
    let patch = defaults_patch(Some(&arg("")), Some(&arg(" "))).unwrap();
    assert_eq!(patch.cwd, Some(CwdChange::Clear));
    assert_eq!(patch.env, Some(BTreeMap::new()));
    assert_eq!(defaults_patch(Some(&arg("true")), None), Err(DefaultsRefusal::CwdMustBeAbsolute));
    assert_eq!(defaults_patch(Some(&arg("src")), None), Err(DefaultsRefusal::CwdMustBeAbsolute));
    let not_text = DefaultsArgument { text: None };
    assert_eq!(defaults_patch(None, Some(&not_text)), Err(DefaultsRefusal::DefaultsMustBeText));
    assert_eq!(
        defaults_patch(None, Some(&arg(r#"{"A":1}"#))),
        Err(DefaultsRefusal::EnvMustBeObject)
    );
    assert_eq!(defaults_patch(None, Some(&arg("[]"))), Err(DefaultsRefusal::EnvMustBeObject));
}

fn set(value: &str) -> FieldUpdate {
    FieldUpdate::Set { value: value.to_owned() }
}

#[test]
fn notes_write_the_description_trimmed_and_empty_clears_it() {
    let update = notes(&NotesVerb::Describe { text: Some("  notes\n".into()) }).unwrap();
    assert_eq!((update.description, update.task_status), (set("notes"), FieldUpdate::Unchanged));
    assert_eq!(update.capabilities, vec!["workspace-description-v1"]);
    assert_eq!(
        notes(&NotesVerb::Describe { text: Some(" ".into()) }).unwrap().description,
        FieldUpdate::Clear
    );
    assert_eq!(notes(&NotesVerb::ClearDescription).unwrap().description, FieldUpdate::Clear);
}

#[test]
fn the_status_cycles_through_the_lanes_from_to_do() {
    let cycle = |current: Option<&str>| {
        notes(&NotesVerb::CycleStatus { current: current.map(str::to_owned) }).unwrap().task_status
    };
    assert_eq!(cycle(None), set("todo"));
    assert_eq!(cycle(Some("working")), set("needs-attention"));
    assert_eq!(cycle(Some("done")), set("todo"));
    let done = notes(&NotesVerb::MarkDone).unwrap();
    assert_eq!((done.task_status, done.capabilities), (set("done"), vec!["workspace-status-v1"]));
}

#[test]
fn set_status_takes_auto_or_a_lane() {
    let status = |text: &str| notes(&NotesVerb::SetStatus { status: Some(text.to_owned()) });
    assert_eq!(status("auto").unwrap().task_status, FieldUpdate::Clear);
    assert_eq!(status("needs-attention").unwrap().task_status, set("needs-attention"));
    assert_eq!(
        status("inProgress"),
        Err(vec!["auto", "todo", "working", "needs-attention", "review", "done"])
    );
}

fn tab(id: &str, cwd: Option<&str>, terminal: bool) -> DirectoryTab {
    DirectoryTab { id: id.into(), cwd: cwd.map(str::to_owned), terminal }
}

#[test]
fn the_directory_is_the_shown_selected_tab_else_the_first_that_has_one() {
    let tabs = vec![
        tab("web", Some("/web"), false),
        tab("a", None, true),
        tab("b", Some("/b"), true),
        tab("c", Some("/c"), true),
    ];
    assert_eq!(directory(&tabs, Some("c"), true), Some("/c".into()));
    assert_eq!(directory(&tabs, Some("a"), true), Some("/b".into()));
    assert_eq!(directory(&tabs, None, true), Some("/b".into()));
    assert_eq!(directory(&tabs, None, false), Some("/web".into()));
    assert_eq!(directory(&tabs, Some("web"), true), Some("/b".into()));
}

fn row(id: &str, pending: bool) -> FocusWorkspace {
    FocusWorkspace { id: id.into(), pending }
}

#[test]
fn going_to_a_group_opens_it_and_shows_its_first_ready_workspace() {
    let group = FocusGroup {
        collapsed: true,
        workspaces: vec![row("new", true), row("first", false)],
        ..FocusGroup::default()
    };
    assert_eq!(
        group_focus(&group),
        FocusPlan { expands: true, workspace: Some("first".into()), reopens: false }
    );
    let saved = FocusGroup { pinned: true, collapsed: true, ..FocusGroup::default() };
    assert_eq!(group_focus(&saved), FocusPlan { expands: false, workspace: None, reopens: true });
    let listed = FocusGroup { pinned: true, items: 1, ..FocusGroup::default() };
    assert!(!group_focus(&listed).reopens);
}

#[test]
fn a_group_chain_goes_out_through_parents_and_stops_at_a_loop() {
    let mut parents = BTreeMap::new();
    parents.insert("inner".to_owned(), Some("outer".to_owned()));
    parents.insert("outer".to_owned(), None);
    assert_eq!(group_chain(Some("inner"), &parents), ids(&["inner", "outer"]));
    assert!(group_chain(Some("missing"), &parents).is_empty());
    assert!(group_chain(None, &parents).is_empty());
    let mut looped = BTreeMap::new();
    looped.insert("a".to_owned(), Some("b".to_owned()));
    looped.insert("b".to_owned(), Some("a".to_owned()));
    assert_eq!(group_chain(Some("a"), &looped).len(), GROUP_DEPTH);
}

#[test]
fn screen_closes_leave_pinned_screens_except_to_the_right() {
    let pinned = [true, false, false, true, false];
    assert_eq!(screen_close(ScreenClose::Others, 2, &pinned), vec![1, 4]);
    assert_eq!(screen_close(ScreenClose::ToRight, 2, &pinned), vec![3, 4]);
    assert_eq!(screen_close(ScreenClose::ToLeft, 2, &pinned), vec![1]);
    assert!(screen_close(ScreenClose::ToLeft, 0, &pinned).is_empty());
}

#[test]
fn a_screen_moves_until_the_edge() {
    assert_eq!(screen_move(1, -1, 3), Some(0));
    assert_eq!(screen_move(0, -1, 3), None);
    assert_eq!(screen_move(2, 1, 3), None);
}

fn screen(group: Option<&str>, pinned: bool) -> GroupedScreen {
    GroupedScreen { group: group.map(str::to_owned), pinned }
}

#[test]
fn a_screen_group_moves_past_its_neighbor_and_never_into_the_pinned_run() {
    let screens = vec![
        screen(None, true),
        screen(Some("x"), false),
        screen(Some("g"), false),
        screen(Some("g"), false),
        screen(None, false),
    ];
    assert_eq!(screen_group_move("g", true, &screens), Some(3));
    assert_eq!(screen_group_move("g", false, &screens), Some(1));
    assert_eq!(screen_group_move("x", false, &screens), None);
    assert_eq!(screen_group_move("x", true, &screens), Some(3));
    let grouped =
        vec![screen(Some("a"), false), screen(Some("a"), false), screen(Some("g"), false)];
    assert_eq!(screen_group_move("g", false, &grouped), Some(0));
    assert_eq!(screen_group_move("g", true, &grouped), None);
    assert_eq!(screen_group_move("none", true, &grouped), None);
}
