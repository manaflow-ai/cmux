use super::*;

fn open(place: FilePlace, path: &str) -> MarkdownOpen {
    MarkdownOpen::Open { place, path: path.to_owned() }
}

#[test]
fn a_named_markdown_file_opens_where_its_pane_is() {
    assert_eq!(open_markdown(Some("/a.md"), false, true, false), open(FilePlace::Remote, "/a.md"));
    assert_eq!(open_markdown(Some("a.md"), true, true, false), open(FilePlace::BesideChat, "a.md"));
    assert_eq!(open_markdown(Some("a.md"), true, false, false), open(FilePlace::Pane, "a.md"));
}

#[test]
fn another_machines_file_needs_an_absolute_path() {
    for path in ["a.md", "/a\0.md"] {
        assert_eq!(
            open_markdown(Some(path), false, false, true),
            MarkdownOpen::Refused(Refusal::PathNotAbsolute { path: path.to_owned() })
        );
    }
}

#[test]
fn no_path_asks_the_picker_only_for_a_run_that_may_change_the_view() {
    assert_eq!(open_markdown(Some(""), true, false, true), MarkdownOpen::Picker);
    assert_eq!(
        open_markdown(None, true, false, false),
        MarkdownOpen::Refused(Refusal::PickerNeedsFocus)
    );
}

#[test]
fn a_diff_opens_the_named_folder_then_the_panes() {
    let ask = DiffAsk {
        path: Some("/repo".to_owned()),
        pane_folder: Some("/pane".to_owned()),
        allows_view_change: true,
        ..DiffAsk::default()
    };
    assert_eq!(
        open_diff(ask.clone()),
        DiffOpen::Folder { folder: "/repo".to_owned(), focus: true }
    );
    assert_eq!(
        open_diff(DiffAsk { path: Some(String::new()), beside_caller: true, ..ask.clone() }),
        DiffOpen::Folder { folder: "/pane".to_owned(), focus: false }
    );
    assert_eq!(
        open_diff(DiffAsk { patch: true, ..ask }),
        DiffOpen::ChatPatch { folder: Some("/repo".to_owned()), focus: true }
    );
}

#[test]
fn a_diff_with_no_folder_asks_the_picker() {
    assert_eq!(
        open_diff(DiffAsk { allows_view_change: true, ..DiffAsk::default() }),
        DiffOpen::Picker
    );
    assert_eq!(open_diff(DiffAsk::default()), DiffOpen::Refused(Refusal::PickerNeedsFocus));
    assert_eq!(
        open_diff(DiffAsk { patch: true, ..DiffAsk::default() }),
        DiffOpen::ChatPatch { folder: None, focus: false }
    );
}

#[test]
fn a_failed_diff_says_why_on_another_machine_else_asks() {
    assert_eq!(diff_failed(false, true), DiffFailed::Reason);
    assert_eq!(diff_failed(true, true), DiffFailed::Picker);
    assert_eq!(diff_failed(true, false), DiffFailed::PickerNeedsFocus);
}

#[test]
fn the_shared_find_actions_are_left_to_their_handlers() {
    let actions = [
        EditorAction { action: "find".to_owned(), runs_editor_command: false },
        EditorAction { action: "editor.save".to_owned(), runs_editor_command: false },
        EditorAction { action: "editor.run".to_owned(), runs_editor_command: true },
    ];
    assert_eq!(
        editor_bindings(&actions),
        vec![
            EditorBinding { action: "editor.save".to_owned(), needs_text: false },
            EditorBinding { action: "editor.run".to_owned(), needs_text: true },
        ]
    );
}

#[test]
fn vscode_serves_a_terminals_folder_or_asks_the_person() {
    let facts = VSCodeFacts {
        local: true,
        installed: true,
        by_person: false,
        terminal: true,
        cwd: Some(" /work ".to_owned()),
    };
    assert_eq!(vscode_open(facts.clone()), VSCodeOpen::Serve { folder: "/work".to_owned() });
    assert_eq!(
        vscode_open(VSCodeFacts { by_person: true, ..facts.clone() }),
        VSCodeOpen::Panel { folder: Some("/work".to_owned()) }
    );
    assert_eq!(vscode_open(VSCodeFacts { terminal: false, ..facts.clone() }), VSCodeOpen::NoFolder);
    assert_eq!(
        vscode_open(VSCodeFacts { cwd: Some("~/w".to_owned()), ..facts }),
        VSCodeOpen::NoFolder
    );
    assert_eq!(
        vscode_open(VSCodeFacts { by_person: true, cwd: None, ..facts }),
        VSCodeOpen::Panel { folder: None }
    );
    assert_eq!(vscode_open(VSCodeFacts { local: false, ..facts.clone() }), VSCodeOpen::ThisMacOnly);
    assert_eq!(vscode_open(VSCodeFacts { installed: false, ..facts }), VSCodeOpen::NotInstalled);
}

#[test]
fn open_with_names_an_app_or_asks_the_person() {
    assert_eq!(open_with(Some("Xcode"), false, false), OpenWith::App { app: "Xcode".to_owned() });
    assert_eq!(open_with(Some(""), false, true), OpenWith::NoSuchApp);
    assert_eq!(open_with(None, true, false), OpenWith::NoSelection);
    assert_eq!(open_with(None, true, true), OpenWith::Choose);
}
