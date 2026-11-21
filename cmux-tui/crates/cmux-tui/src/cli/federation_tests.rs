use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn a_kind_or_the_name_escape_is_not_a_session() {
    assert_eq!(qualified("build-box:ws_1a2b"), Some(("build-box", "ws_1a2b")));
    assert_eq!(qualified("workspace:ws_1a2b"), None);
    assert_eq!(qualified("name:ws_1a2b"), None);
}

#[test]
fn a_qualified_selector_routes_to_its_session_and_loses_the_qualifier() {
    let mut global = GlobalArgs::default();
    let mut command = args(&["workspace", "build-box:ws_1a2b", "update", "--title", "x:ws_9"]);
    apply_qualifiers(&mut global, &mut command).unwrap();
    assert_eq!(global.session.as_deref(), Some("build-box"));
    // The payload of --title is text, never a selector.
    assert_eq!(command, args(&["workspace", "ws_1a2b", "update", "--title", "x:ws_9"]));
}

#[test]
fn id_options_and_lists_take_qualifiers_from_one_session_only() {
    let mut global = GlobalArgs::default();
    let mut command =
        args(&["tab", "group", "create", "--tabs", "box:tab_1,box:tab_2", "--pane=box:pane_3"]);
    apply_qualifiers(&mut global, &mut command).unwrap();
    assert_eq!(command[4], "tab_1,tab_2");
    assert_eq!(command[5], "--pane=pane_3");
    assert_eq!(global.session.as_deref(), Some("box"));

    let mut command = args(&["tab", "group", "create", "--tabs", "a:tab_1,b:tab_2"]);
    assert!(apply_qualifiers(&mut GlobalArgs::default(), &mut command).is_err());
    let mut named = GlobalArgs { session: Some("a".into()), ..GlobalArgs::default() };
    assert!(apply_qualifiers(&mut named, &mut args(&["workspace", "b:ws_1", "show"])).is_err());
    let mut socket =
        GlobalArgs { socket: Some(PathBuf::from("/tmp/s.sock")), ..GlobalArgs::default() };
    assert!(apply_qualifiers(&mut socket, &mut args(&["workspace", "b:ws_1", "show"])).is_err());
}

#[test]
fn unqualified_urls_and_words_after_the_separator_are_untouched() {
    let mut global = GlobalArgs::default();
    let mut command = args(&["tab", "create", "browser", "--url", "https:ws_1", "--", "box:ws_2"]);
    let before = command.clone();
    apply_qualifiers(&mut global, &mut command).unwrap();
    assert_eq!(command, before);
    assert_eq!(global.session, None);
    assert_eq!(qualified("box:ws_"), None);
    assert_eq!(qualified("box:room_1"), None);
    assert_eq!(qualified("a/b:ws_1"), None);
    assert_eq!(qualified("box:term_9f"), Some(("box", "term_9f")));
}

#[test]
fn local_sessions_are_the_socket_files_by_name_plus_the_app_session() {
    let directory = tempfile::tempdir().unwrap();
    for name in ["main.sock", "build.sock", "notes.txt"] {
        std::fs::write(directory.path().join(name), b"").unwrap();
    }
    let app = ("cmux-app".to_owned(), PathBuf::from("/elsewhere/cmux-app.sock"));
    let sessions = local_sessions(
        &[directory.path().to_path_buf(), directory.path().join("missing")],
        Some(app.clone()),
    );
    let names: Vec<&str> = sessions.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(names, vec!["build", "cmux-app", "main"]);
    assert_eq!(sessions[1], app);
}

#[test]
fn joined_lists_tag_every_record_with_its_session() {
    let joined = join(vec![
        ("main".into(), json!([{"id": "ws_1"}, {"id": "ws_2"}])),
        ("build".into(), json!([{"id": "ws_3"}])),
        ("odd".into(), json!({"count": 0})),
    ]);
    assert_eq!(
        joined,
        json!([
            {"id": "ws_1", "session": "main"},
            {"id": "ws_2", "session": "main"},
            {"id": "ws_3", "session": "build"},
            {"session": "odd", "result": {"count": 0}},
        ])
    );
}
