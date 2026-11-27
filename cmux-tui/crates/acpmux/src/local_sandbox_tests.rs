use super::*;
use crate::user_settings::Settings;
use serde_json::json;

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|w| w.to_string()).collect()
}

#[test]
fn the_setting_is_on_by_default_fails_closed_and_policy_only_tightens() {
    assert!(file_wants(&Settings::Missing));
    assert!(file_wants(&Settings::Unreadable("bad json".into())));
    assert!(file_wants(&Settings::Parsed(json!({}))));
    assert!(file_wants(&Settings::Parsed(json!({"sessions": {"sandbox": "false"}}))));
    assert!(!file_wants(&Settings::Parsed(json!({"sessions": {"sandbox": false}}))));
    assert!(!file_wants(&Settings::Parsed(json!({"sessions.sandbox": false}))));
    // MDM or the team policy: a forced on beats the file's off; nothing turns it off.
    assert!(enabled_by(true, false));
    assert!(enabled_by(false, true));
    assert!(!enabled_by(false, false));
}

fn sample() -> Bound {
    Bound {
        cwd: "/Users/a/code/app".into(),
        home: "/Users/a".into(),
        agent_home: "/Users/a".into(),
        acpmux_home: "/Users/a/.acpmux".into(),
        session_tmp: "/private/tmp/acpmux-501".into(),
        folders: vec!["/Users/a/code/lib".into(), "/Users/a/code/app.git".into()],
        api_port: None,
    }
}

#[test]
fn the_profile_gets_every_folder_and_its_params() {
    let args = sample().sandbox_args();
    assert_eq!(args[0], "-p");
    let profile = &args[1];
    assert!(profile.contains("(subpath (param \"DIR0\"))\n  (subpath (param \"DIR1\"))\n"));
    assert!(!profile.contains(";; @FOLDERS@\n"));
    assert!(!profile.contains("(remote ip \"*:8443\")"));
    let params: Vec<&str> = args[2..].iter().map(String::as_str).collect();
    for want in [
        "CWD=/Users/a/code/app",
        "HOME=/Users/a",
        "AGENT_HOME=/Users/a",
        "ACPMUX_HOME=/Users/a/.acpmux",
        "SESSION_TMP=/private/tmp/acpmux-501",
        "DIR0=/Users/a/code/lib",
        "DIR1=/Users/a/code/app.git",
    ] {
        assert!(params.contains(&want), "{want} in {params:?}");
    }
    let with_port = Bound { api_port: Some(8443), ..sample() }.sandbox_args();
    assert!(with_port[1].ends_with("(allow network-outbound (remote ip \"*:8443\"))\n"));
}

#[test]
fn the_profile_denies_credentials_writes_and_other_ports() {
    // The red-team's three paths, as the checked-in profile states them.
    for line in [
        "(deny file-write* (subpath \"/\"))",
        "(subpath (string-append (param \"HOME\") \"/.ssh\"))",
        "(subpath (string-append (param \"HOME\") \"/.aws\"))",
        "(subpath (string-append (param \"HOME\") \"/.config/gh\"))",
        "(subpath (string-append (param \"AGENT_HOME\") \"/.config/gh\"))",
        "(deny file-link)",
        "(deny network-outbound)",
        "(remote ip \"*:443\")",
    ] {
        assert!(PROFILE.contains(line), "{line}");
    }
    // Credential reads are denied after the write allowlist, so no allowed folder re-opens them.
    let deny = PROFILE.find("(deny file-read* file-write*").unwrap();
    assert!(deny > PROFILE.find(";; @FOLDERS@").unwrap());
}

#[test]
fn paths_are_regex_escaped() {
    assert_eq!(regex_escape(Path::new("/Users/a.b/x+y (1)")), "/Users/a\\.b/x\\+y \\(1\\)");
}

#[test]
fn added_dirs_are_read_from_the_command_line() {
    let args =
        s(&["--add-dir", "/a", "b", "--model", "x", "--add-dir=/c", "--", "--add-dir", "/no"]);
    assert_eq!(added_dirs(&args), vec![PathBuf::from("/a"), "b".into(), "/c".into()]);
}

#[test]
fn added_dirs_stop_at_flags_and_handle_missing_values() {
    assert!(added_dirs(&[]).is_empty());
    assert!(added_dirs(&s(&["--add-dir"])).is_empty());
    assert!(added_dirs(&s(&["--add-dir", "--", "/not-a-folder-argument"])).is_empty());
    assert_eq!(
        added_dirs(&s(&["--add-dir", "--add-dir", "/a", "/b", "--add-dir"])),
        vec![PathBuf::from("/a"), PathBuf::from("/b")]
    );
}

#[test]
fn a_worktree_gets_its_git_folders() {
    let t = tempfile::tempdir().unwrap();
    let main = t.path().join("main");
    let common = main.join(".git");
    let own = common.join("worktrees/wt");
    std::fs::create_dir_all(&own).unwrap();
    std::fs::write(own.join("commondir"), "../..\n").unwrap();
    let wt = t.path().join("wt");
    std::fs::create_dir_all(wt.join("sub")).unwrap();
    std::fs::write(wt.join(".git"), format!("gitdir: {}\n", own.display())).unwrap();
    let dirs: Vec<PathBuf> = git_dirs(&wt.join("sub")).iter().map(|d| canonical(d)).collect();
    assert_eq!(dirs, vec![canonical(&own), canonical(&common)]);
    // A subfolder of a repository: its `.git`.
    assert_eq!(git_dirs(&main.join("x")), vec![common.clone()]);
    assert!(git_dirs(Path::new("/nonexistent-folder-for-a-test")).is_empty());
}

#[test]
fn untrusted_worktree_metadata_cannot_add_an_arbitrary_write_root() {
    let t = tempfile::tempdir().unwrap();
    let folder = t.path().join("checkout");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join(".git"), "gitdir: /\n").unwrap();
    assert!(git_dirs(&folder).is_empty());

    let common = t.path().join("repo/.git");
    std::fs::create_dir_all(&common).unwrap();
    let own = common.join("worktrees/wt");
    std::fs::create_dir_all(&own).unwrap();
    std::fs::write(own.join("commondir"), "/\n").unwrap();
    std::fs::write(folder.join(".git"), format!("gitdir: {}\n", own.display())).unwrap();
    assert_eq!(git_dirs(&folder), vec![canonical(&own)]);
}

#[test]
fn claude_codes_own_sandbox_is_seen_from_any_settings_source() {
    let t = tempfile::tempdir().unwrap();
    let (cwd, home) = (t.path().join("cwd"), t.path().join("home"));
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    assert!(!claude_sandbox_on(&[], &cwd, &home, None));
    let on = r#"{"sandbox":{"enabled":true}}"#;
    assert!(claude_sandbox_on(&s(&["--settings", on]), &cwd, &home, None));
    assert!(claude_sandbox_on(&[format!("--settings={on}")], &cwd, &home, None));
    // Claude applies the last --settings value, so an earlier true cannot suppress our wrapper.
    assert!(!claude_sandbox_on(
        &s(&["--settings", on, "--settings", r#"{"sandbox":{"enabled":false}}"#]),
        &cwd,
        &home,
        None
    ));
    // The final false wins, even when the first value enabled Claude's sandbox.
    assert!(!claude_sandbox_on(
        &s(&["--settings", r#"{"sandbox":{"enabled":false}}"#]),
        &cwd,
        &home,
        None
    ));
    std::fs::write(cwd.join(".claude/settings.local.json"), on).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &home, None));
    std::fs::remove_file(cwd.join(".claude/settings.local.json")).unwrap();
    std::fs::write(home.join(".claude/settings.json"), on).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &home, None));
    let configured = t.path().join("configured-claude");
    std::fs::create_dir_all(&configured).unwrap();
    std::fs::write(configured.join("settings.json"), on).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &home, Some(&configured)));
    // An explicit source list excludes user and enterprise settings. A user setting
    // must not make acpmux skip its outer sandbox when Claude will not read it.
    assert!(!claude_sandbox_on(&s(&["--setting-sources", "project,local"]), &cwd, &home, None));
    std::fs::write(cwd.join(".claude/settings.json"), on).unwrap();
    assert!(claude_sandbox_on(&s(&["--setting-sources", "project"]), &cwd, &home, None));
}

#[test]
fn only_an_api_port_the_profile_lacks_is_added() {
    assert_eq!(extra_api_port("https://api.example.com:8443/v1"), Some(8443));
    assert_eq!(extra_api_port("http://user:pw@10.0.0.2:4000"), Some(4000));
    assert_eq!(extra_api_port("https://api.example.com/v1"), None);
    assert_eq!(extra_api_port("https://api.example.com:443"), None);
    assert_eq!(extra_api_port("http://127.0.0.1:8080"), None);
    assert_eq!(extra_api_port("http://localhost:8080"), None);
    assert_eq!(extra_api_port("http://[::1]:8080"), None);
    assert_eq!(extra_api_port("http://[2001:db8::1]:9000"), Some(9000));
    assert_eq!(extra_api_port("not a url"), None);
}

#[test]
fn a_folder_at_or_above_home_is_never_a_write_root() {
    let Some(home) = dirs::home_dir() else { return };
    let env = BTreeMap::new();
    assert_eq!(bound(&[], &home, &env), None);
    assert_eq!(bound(&[], Path::new("/"), &env), None);
    let t = tempfile::tempdir().unwrap();
    let b = bound(&s(&["--add-dir", "/"]), t.path(), &env).unwrap();
    assert!(!b.folders.iter().any(|d| home.starts_with(d)), "{:?}", b.folders);
}

#[test]
fn profile_does_not_grant_tool_executable_write_roots() {
    assert!(!PROFILE.contains(r#"(subpath (string-append (param "AGENT_HOME") "/.local"))"#));
    assert!(!PROFILE.contains(r#"(subpath (string-append (param "AGENT_HOME") "/.cargo"))"#));
}
