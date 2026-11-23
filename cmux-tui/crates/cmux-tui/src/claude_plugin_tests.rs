use super::*;

fn plugin(folder: &Path, name: &str) {
    fs::create_dir_all(folder.join(".claude-plugin")).unwrap();
    fs::write(folder.join(MANIFEST), json!({"name": name}).to_string()).unwrap();
}

#[test]
fn any_launcher_pane_plugin_dirs_keep_other_plugins_and_replace_cmux_ones() {
    let root = tempfile::tempdir().unwrap();
    let mine = root.path().join("mine");
    let other_build = root.path().join("other-build");
    let person = root.path().join("person");
    plugin(&other_build, PLUGIN_NAME);
    plugin(&person, "my-plugin");
    let inherited = std::env::join_paths([&other_build, &person, &mine]).unwrap();
    let value = pane_plugin_dirs(Some(&inherited), &mine).unwrap();
    assert_eq!(std::env::split_paths(&value).collect::<Vec<_>>(), [person.clone(), mine.clone()]);
    assert_eq!(pane_plugin_dirs(None, &mine).unwrap().as_os_str(), mine.as_os_str());

    install(&mine, Path::new("/opt/cmux tui/cmux-tui"), Path::new("/opt/cmux tui/hook")).unwrap();
    let both = std::env::join_paths([&person, &mine]).unwrap();
    assert_eq!(without_cmux_plugins(&both).unwrap().as_os_str(), person.as_os_str());
    assert_eq!(without_cmux_plugins(mine.as_os_str()), None);
}

#[test]
fn any_launcher_pane_plugin_dirs_drop_the_folder_of_a_deleted_build() {
    let root = tempfile::tempdir().unwrap();
    let mine = root.path().join("data/cmux-tui/builds/0123abcd/claude-plugin");
    // Another build's plugin folder, deleted with its build: no manifest.
    let deleted = root.path().join("data/cmux-tui/builds/4567ef01/claude-plugin");
    // The person's folder of the same name, elsewhere, stays.
    let person = root.path().join("tools/claude-plugin");
    let inherited = std::env::join_paths([&deleted, &person]).unwrap();
    let value = pane_plugin_dirs(Some(&inherited), &mine).unwrap();
    assert_eq!(std::env::split_paths(&value).collect::<Vec<_>>(), [person.clone(), mine]);
    assert_eq!(without_cmux_plugins(&inherited).unwrap().as_os_str(), person.as_os_str());
}

#[test]
fn any_launcher_plugin_has_the_hooks_and_the_session_context() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("plugin");
    let executable = Path::new("/opt/cmux-tui");
    install(&dir, executable, Path::new("/opt/cmux-tui-hook")).unwrap();
    let first = fs::read(dir.join(HOOKS)).unwrap();
    install(&dir, executable, Path::new("/opt/cmux-tui-hook")).unwrap();
    assert_eq!(fs::read(dir.join(HOOKS)).unwrap(), first);
    assert!(is_cmux_tui_plugin(&dir));
    let hooks: Value = serde_json::from_slice(&first).unwrap();
    let commands = |event: &str| {
        hooks["hooks"][event]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|group| group["hooks"].as_array().into_iter().flatten())
            .filter_map(|hook| hook["command"].as_str().map(str::to_owned))
            .collect::<Vec<_>>()
    };
    let start = commands("SessionStart");
    assert_eq!(start.len(), 2, "{start:?}");
    assert!(start.iter().any(|command| command.contains("agent session-context")));
    assert!(start.iter().any(|command| command.contains("/opt/cmux-tui-hook")));
    for event in ["Stop", "UserPromptSubmit", "PreToolUse", "Notification"] {
        let found = commands(event);
        assert_eq!(found.len(), 1, "{event}: {found:?}");
        assert!(found[0].contains(agent_hook_install::CLAUDE_PLUGIN_ORIGIN_ENV), "{event}");
    }
}

#[test]
fn any_launcher_sideload_policy_is_found_in_json_and_property_lists() {
    let root = tempfile::tempdir().unwrap();
    let write = |name: &str, data: &[u8]| {
        let path = root.path().join(name);
        fs::write(&path, data).unwrap();
        path
    };
    let off = write("off.json", br#"{"disableSideloadFlags": false, "env": {}}"#);
    let none = write("none.json", br#"{"permissions": {"deny": []}}"#);
    let nested = write("nested.json", br#"{"settings": {"disableSideloadFlags": true}}"#);
    let plist = write("p.plist", b"bplist00\x01disableSideloadFlags\x09");
    let missing = root.path().join("missing.json");
    assert!(!sideloading_disabled(&[off.clone(), none.clone(), missing]));
    assert!(sideloading_disabled(&[off, nested]));
    assert!(sideloading_disabled(&[none, plist]));
    let files = policy_files(Some(root.path()), None);
    assert!(files.contains(&root.path().join(".claude/remote-settings.json")), "{files:?}");
}
