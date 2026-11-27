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
    // The managed-preference source: a forced on beats the file's off; nothing turns it off.
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
        cmux_config: "/Users/a/.config/cmux-next/cmux-next.json".into(),
        cmux_legacy_config: "/Users/a/.config/cmux/cmux-next.json".into(),
        cmux_agent_config: "/Users/a/.config/cmux-next/cmux-next.json".into(),
        cmux_agent_legacy_config: "/Users/a/.config/cmux/cmux-next.json".into(),
        cmux_config_real: "/Users/a/.config/cmux-next/cmux-next.json".into(),
        gh_config_dir: "/Users/a/.config/gh".into(),
        xdg_gh_config_dir: "/Users/a/.config/gh".into(),
        folders: vec!["/Users/a/code/lib".into(), "/Users/a/code/app.git".into()],
        policy_files: Vec::new(),
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
        "CMUX_CONFIG=/Users/a/.config/cmux-next/cmux-next.json",
        "CMUX_LEGACY_CONFIG=/Users/a/.config/cmux/cmux-next.json",
        "CMUX_AGENT_CONFIG=/Users/a/.config/cmux-next/cmux-next.json",
        "CMUX_AGENT_LEGACY_CONFIG=/Users/a/.config/cmux/cmux-next.json",
        "CMUX_CONFIG_REAL=/Users/a/.config/cmux-next/cmux-next.json",
        "GH_CONFIG_DIR=/Users/a/.config/gh",
        "XDG_GH_CONFIG_DIR=/Users/a/.config/gh",
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
        "(literal (string-append (param \"HOME\") \"/.ssh/config\"))",
        "(literal (string-append (param \"HOME\") \"/.ssh/known_hosts\"))",
        "(subpath (param \"GH_CONFIG_DIR\"))",
        "(subpath (param \"XDG_GH_CONFIG_DIR\"))",
        "(deny file-link)",
        "(deny network-outbound)",
        "(remote ip \"*:443\")",
    ] {
        assert!(PROFILE.contains(line), "{line}");
    }
    // Credential reads are denied after the write allowlist, so no allowed folder re-opens them.
    let deny = PROFILE.find("(deny file-read* file-write*").unwrap();
    assert!(deny > PROFILE.find(";; @FOLDERS@").unwrap());
    let settings_deny =
        PROFILE.find("(literal (string-append \"\" (param \"CMUX_CONFIG\")))").unwrap();
    assert!(settings_deny > PROFILE.find(";; cmux's settings trees").unwrap());
    for param in ["CMUX_AGENT_CONFIG", "CMUX_AGENT_LEGACY_CONFIG"] {
        assert!(PROFILE.contains(&format!("(param \"{param}\")")));
    }
}

#[test]
fn the_profile_keeps_home_ssh_metadata_and_closes_escape_boundaries() {
    let (_, public_reads) = PROFILE.split_once("(allow file-read*").unwrap();
    for path in ["/.ssh", "/.ssh/config", "/.ssh/known_hosts"] {
        let account = format!(r#"(literal (string-append (param "HOME") "{path}"))"#);
        let alternate = format!(r#"(literal (string-append (param "AGENT_HOME") "{path}"))"#);
        assert!(public_reads.contains(&account), "{account}");
        assert!(!public_reads.contains(&alternate), "{alternate}");
    }
    let (grants, restrictions) = PROFILE.split_once(";; @FOLDERS@").unwrap();
    assert!(!grants.contains(r#"(subpath (param "ACPMUX_HOME"))"#));
    assert!(restrictions.contains(r#"(deny file-write* (subpath (param "ACPMUX_HOME")))"#));
    assert!(
        PROFILE.contains(r#"(remote unix-socket (path-literal "/private/var/run/mDNSResponder"))"#)
    );
    assert!(!PROFILE.contains("  (remote unix-socket))"));
    for root in ["/.rustup", "/Library/pnpm", "/.deno", "/go", "/Library/Developer"] {
        assert!(!PROFILE.contains(root), "profile widened toolchain root {root}");
    }
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
fn only_an_effective_trusted_setting_can_select_claudes_sandbox() {
    let t = tempfile::tempdir().unwrap();
    let (cwd, home) = (t.path().join("cwd"), t.path().join("home"));
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let mut env = BTreeMap::new();
    env.insert("HOME".into(), home.display().to_string());
    assert!(!claude_sandbox_on(&[], &cwd, &env).unwrap());
    let on = r#"{"sandbox":{"enabled":true}}"#;
    assert!(claude_sandbox_on(&s(&["--settings", on]), &cwd, &env).unwrap());
    assert!(claude_sandbox_on(&[format!("--settings={on}")], &cwd, &env).unwrap());
    // Claude applies the last --settings value, so an earlier true cannot disable our wrapper.
    assert!(
        !claude_sandbox_on(
            &s(&["--settings", on, "--settings", r#"{"sandbox":{"enabled":false}}"#]),
            &cwd,
            &env
        )
        .unwrap()
    );
    assert!(
        claude_sandbox_on(
            &s(&["--settings", r#"{"sandbox":{"enabled":false}}"#, "--settings", on]),
            &cwd,
            &env
        )
        .unwrap()
    );
    std::fs::write(cwd.join(".claude/settings.local.json"), on).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &env).is_err());
    std::fs::remove_file(cwd.join(".claude/settings.local.json")).unwrap();
    std::fs::write(home.join(".claude/settings.json"), on).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &env).unwrap());

    // CLAUDE_CONFIG_DIR replaces the default ~/.claude home and must be inspected too.
    let configured = t.path().join("configured-claude");
    std::fs::create_dir_all(&configured).unwrap();
    std::fs::write(configured.join("settings.json"), on).unwrap();
    env.insert("CLAUDE_CONFIG_DIR".into(), configured.display().to_string());
    std::fs::remove_file(home.join(".claude/settings.json")).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &env).unwrap());

    // An explicit source list excludes user settings while retaining project settings.
    std::fs::write(configured.join("settings.json"), on).unwrap();
    assert!(!claude_sandbox_on(&s(&["--setting-sources", "project,local"]), &cwd, &env).unwrap());
    std::fs::write(cwd.join(".claude/settings.json"), on).unwrap();
    assert!(claude_sandbox_on(&s(&["--setting-sources", "project"]), &cwd, &env).is_err());
    let off = r#"{"sandbox":{"enabled":false}}"#;
    std::fs::write(cwd.join(".claude/settings.json"), off).unwrap();
    assert!(!claude_sandbox_on(&[], &cwd, &env).unwrap());
    assert!(claude_sandbox_on(&s(&["--setting-sources=user"]), &cwd, &env).unwrap());

    std::fs::write(cwd.join("launch.json"), on).unwrap();
    let flags = s(&["--settings", on, "--settings=launch.json"]);
    assert!(claude_sandbox_on(&flags, &cwd, &env).is_err());
    assert!(
        claude_sandbox_on(&s(&["--settings", on, "--", "--settings=launch.json"]), &cwd, &env)
            .unwrap()
    );
    assert!(claude_sandbox_on(&s(&["--settings", on, "--settings"]), &cwd, &env).is_err());
}

#[test]
fn claude_settings_fail_closed_and_managed_policy_cannot_be_filtered_out() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    let config = t.path().join("config");
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), config.display().to_string())]);
    let on = r#"{"sandbox":{"enabled":true}}"#;
    std::fs::write(config.join("settings.json"), on).unwrap();
    for invalid in ["{", "[]", r#"{"sandbox":{"enabled":"true"}}"#] {
        std::fs::write(cwd.join(".claude/settings.local.json"), invalid).unwrap();
        assert!(claude_sandbox_on(&[], &cwd, &env).is_err(), "invalid source: {invalid}");
    }
    std::fs::remove_file(cwd.join(".claude/settings.local.json")).unwrap();
    // A directory at the settings path is unreadable as a file, even when CI runs as root.
    std::fs::create_dir(cwd.join(".claude/settings.local.json")).unwrap();
    assert!(claude_sandbox_on(&[], &cwd, &env).is_err());
    std::fs::remove_dir(cwd.join(".claude/settings.local.json")).unwrap();
    assert!(claude_sandbox_on(&s(&["--settings", "{}"]), &cwd, &env).unwrap());
    assert!(claude_sandbox_on(&s(&["--settings", "{"]), &cwd, &env).is_err());
    std::fs::write(config.join("remote-settings.json"), r#"{"sandbox":{"enabled":false}}"#)
        .unwrap();
    assert!(
        !claude_sandbox_on(&s(&["--setting-sources", "user", "--settings", on]), &cwd, &env)
            .unwrap()
    );
    std::fs::write(config.join("remote-settings.json"), "{").unwrap();
    assert!(
        claude_sandbox_on(&s(&["--setting-sources", "user", "--settings", on]), &cwd, &env)
            .is_err()
    );
}

#[cfg(unix)]
#[test]
fn ambiguous_settings_report_a_launch_error_before_spawning_either_sandbox() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    let config = t.path().join("config");
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), config.display().to_string())]);
    let on = r#"{"sandbox":{"enabled":true}}"#;
    std::fs::write(config.join("settings.json"), on).unwrap();
    let local = cwd.join(".claude/settings.local.json");
    std::fs::write(&local, "{").unwrap();
    let error = required_prefix("/bin/sh", &[], &cwd, &env).unwrap_err().to_string();
    assert!(error.contains(local.to_str().unwrap()) && error.contains("Correct"), "{error}");
    std::fs::remove_file(&local).unwrap();
    let flags = s(&["--settings", on, "--settings", "missing.json"]);
    let error = required_prefix("/bin/sh", &flags, &cwd, &env).unwrap_err().to_string();
    assert!(error.contains("--settings") && error.contains("readable"), "{error}");

    // A valid managed override still takes precedence over the explicit and user values.
    let managed = config.join("remote-settings.json");
    std::fs::write(&managed, r#"{"sandbox":{"enabled":false}}"#).unwrap();
    let args = s(&["--settings", on]);
    assert!(required_prefix("/bin/sh", &args, &cwd, &env).unwrap().is_some());
    std::fs::write(&managed, on).unwrap();
    assert!(required_prefix("/bin/sh", &[], &cwd, &env).unwrap().is_none());
    // Project exclusions would weaken that managed delegation. Stop with the offending source.
    std::fs::write(&local, r#"{"sandbox":{"excludedCommands":["echo"]}}"#).unwrap();
    let error = required_prefix("/bin/sh", &[], &cwd, &env).unwrap_err().to_string();
    assert!(error.contains(local.to_str().unwrap()) && error.contains("Remove"), "{error}");
}

#[test]
fn managed_plist_sandbox_values_must_agree() {
    let path = Path::new("com.anthropic.claudecode.plist");
    for (flat, expected) in [("true", Some(true)), ("false", None)] {
        let plist = format!(
            r#"<?xml version="1.0"?><plist version="1.0"><dict>
                <key>sandbox.enabled</key><{flat}/>
                <key>sandbox</key><dict><key>enabled</key><true/></dict>
            </dict></plist>"#
        );
        assert_eq!(
            ClaudeSandboxSetting::from_file(path, plist.as_bytes()).and_then(|value| value.enabled),
            expected
        );
    }
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

#[cfg(unix)]
#[test]
fn a_required_boundary_that_cannot_start_returns_a_launch_error() {
    let t = tempfile::tempdir().unwrap();
    let config = t.path().join("settings-home");
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), config.display().to_string())]);
    let args = s(&["--settings", r#"{"sandbox":{"enabled":false}}"#]);
    let missing = required_prefix("", &args, t.path(), &env).unwrap_err();
    assert!(missing.to_string().contains("Seatbelt"));
    let unsafe_folder = required_prefix("/bin/sh", &args, Path::new("/"), &env).unwrap_err();
    assert!(unsafe_folder.to_string().contains("chat folder"));
}

#[test]
fn an_added_folder_at_or_above_agent_home_is_never_a_write_root() {
    let Some(home) = dirs::home_dir() else { return };
    let t = tempfile::tempdir().unwrap();
    let agent_home = t.path().join("agent-home");
    let cwd = t.path().join("chat");
    std::fs::create_dir_all(&cwd).unwrap();
    std::fs::create_dir_all(&agent_home).unwrap();
    let env = BTreeMap::from([(String::from("HOME"), agent_home.display().to_string())]);
    let b = bound(&s(&["--add-dir", agent_home.to_str().unwrap()]), &cwd, &env).unwrap();
    assert!(!b.folders.iter().any(|d| home.starts_with(d) || agent_home.starts_with(d)));
}

#[test]
fn relative_credential_config_paths_are_resolved_from_the_chat_folder() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("chat");
    std::fs::create_dir_all(&cwd).unwrap();
    let env = BTreeMap::from([
        (String::from("GH_CONFIG_DIR"), String::from(".gh")),
        (String::from("XDG_CONFIG_HOME"), String::from(".xdg")),
    ]);
    let b = bound(&[], &cwd, &env).unwrap();
    assert_eq!(b.gh_config_dir, canonical(&cwd.join(".gh")));
    assert_eq!(b.xdg_gh_config_dir, canonical(&cwd.join(".xdg/gh")));
}

#[test]
fn profile_does_not_grant_tool_executable_write_roots() {
    assert!(!PROFILE.contains(r#"(subpath (string-append (param "AGENT_HOME") "/.local"))"#));
    assert!(!PROFILE.contains(r#"(subpath (string-append (param "AGENT_HOME") "/.cargo"))"#));
}

#[test]
fn api_port_follows_settings_precedence_and_the_effective_child_environment() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    let config = t.path().join("custom");
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let env = BTreeMap::from([
        ("CLAUDE_CONFIG_DIR".into(), config.display().to_string()),
        ("ANTHROPIC_BASE_URL".into(), "https://env.test:8001".into()),
    ]);
    let settings =
        |port| format!(r#"{{"env":{{"ANTHROPIC_BASE_URL":"https://settings.test:{port}"}}}}"#);
    assert_eq!(api_endpoint(&[], &cwd, &env).as_deref(), Some("https://env.test:8001"));
    std::fs::write(config.join("settings.json"), settings(8002)).unwrap();
    std::fs::write(cwd.join(".claude/settings.json"), settings(8003)).unwrap();
    std::fs::write(cwd.join(".claude/settings.local.json"), settings(8004)).unwrap();
    assert_eq!(api_endpoint(&[], &cwd, &env), None);
    assert_eq!(api_endpoint(&s(&["--setting-sources=project"]), &cwd, &env), None);
    assert_eq!(
        api_endpoint(&s(&["--setting-sources=user"]), &cwd, &env).as_deref(),
        Some("https://settings.test:8002")
    );
    std::fs::write(cwd.join("override.json"), settings(8005)).unwrap();
    let flags = s(&["--settings", &settings(8006), "--settings", "override.json"]);
    assert_eq!(api_endpoint(&flags, &cwd, &env), None);
    let inline_last = s(&["--settings", "override.json", "--settings", &settings(8006)]);
    assert_eq!(
        api_endpoint(&inline_last, &cwd, &env).as_deref(),
        Some("https://settings.test:8006")
    );
    std::fs::write(config.join("remote-settings.json"), settings(8007)).unwrap();
    assert_eq!(api_endpoint(&flags, &cwd, &env).as_deref(), Some("https://settings.test:8007"));
    std::fs::write(config.join("remote-settings.json"), "{").unwrap();
    assert_eq!(api_endpoint(&flags, &cwd, &env), None);
}

#[test]
fn settings_inside_project_roots_cannot_grant_exceptions_through_other_sources() {
    let t = tempfile::tempdir().unwrap();
    let project = t.path().join("repo");
    let cwd = project.join("subdir");
    let added = t.path().join("added");
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(&cwd).unwrap();
    std::fs::create_dir_all(&added).unwrap();
    let setting =
        r#"{"sandbox":{"enabled":true},"env":{"ANTHROPIC_BASE_URL":"https://example.test:8443"}}"#;
    let args = vec!["--add-dir".into(), added.display().to_string()];
    for dir in [&project, &added] {
        let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), dir.display().to_string())]);
        for name in ["settings.json", "remote-settings.json"] {
            let file = dir.join(name);
            std::fs::write(&file, setting).unwrap();
            assert!(claude_sandbox_on(&args, &cwd, &env).is_err());
            assert_eq!(api_endpoint(&args, &cwd, &env), None);
            std::fs::remove_file(file).unwrap();
        }
    }
}

#[test]
fn turning_a_settings_file_into_inline_json_preserves_its_source() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    let config = t.path().join("config");
    std::fs::create_dir_all(&cwd).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let setting =
        r#"{"sandbox":{"enabled":true},"env":{"ANTHROPIC_BASE_URL":"https://example.test:8443"}}"#;
    let choices = crate::agent_launch_choices::LaunchChoices {
        strip_attribution: true,
        ..Default::default()
    };
    for (file, trusted) in
        [(cwd.join("override.json"), false), (config.join("override.json"), true)]
    {
        std::fs::write(&file, setting).unwrap();
        let mut env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), config.display().to_string())]);
        let mut argv = s(&["claude", "--settings", file.to_str().unwrap()]);
        capture_flag_origin(&argv, &cwd, &mut env);
        crate::agent_launch_choices::apply_claude(&mut argv, &cwd, &choices);
        let args = &argv[1..];
        assert!(last_settings(args).unwrap().unwrap().starts_with('{'));
        assert_eq!(claude_sandbox_on(args, &cwd, &env).ok(), trusted.then_some(true));
        assert_eq!(api_endpoint(args, &cwd, &env).is_some(), trusted);
        assert!(policy_files(args, &cwd, &env).contains(&file));
    }
}

#[test]
fn merged_project_sandbox_options_cannot_weaken_a_trusted_delegation() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    let config = t.path().join("config");
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), config.display().to_string())]);
    let on = r#"{"sandbox":{"enabled":true}}"#;
    std::fs::write(config.join("settings.json"), on).unwrap();
    for name in ["settings.json", "settings.local.json"] {
        let path = cwd.join(".claude").join(name);
        std::fs::write(&path, r#"{"sandbox":{"excludedCommands":["echo"]}}"#).unwrap();
        assert!(claude_sandbox_on(&[], &cwd, &env).is_err());
        assert!(claude_sandbox_on(&s(&["--settings", on]), &cwd, &env).is_err());
        assert!(claude_sandbox_on(&s(&["--setting-sources=user"]), &cwd, &env).unwrap());
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn sandbox_decision_files_and_their_parents_are_protected() {
    let t = tempfile::tempdir().unwrap();
    let cwd = t.path().join("cwd");
    std::fs::create_dir_all(&cwd).unwrap();
    let env = BTreeMap::from([("CLAUDE_CONFIG_DIR".into(), "custom".into())]);
    let files = policy_files(&s(&["--settings", "own.json"]), &cwd, &env);
    for file in [
        "custom/settings.json",
        "custom/remote-settings.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
        "own.json",
    ] {
        assert!(files.contains(&cwd.join(file)), "{file}");
    }
    let bound = Bound { policy_files: files, ..sample() };
    let args = bound.sandbox_args();
    assert!(args[1].contains("(deny file-write* (subpath (param \"POLICY_FILE0\")))"));
    assert!(args[1].contains(
        "(deny file-write-unlink file-write-create (literal (param \"POLICY_PARENT0\")))"
    ));
}

#[test]
fn future_managed_dropins_are_protected_before_they_exist() {
    let t = tempfile::tempdir().unwrap();
    let env = BTreeMap::new();
    let claude = claude_files(t.path(), &env);
    let dropins = claude.managed_mcp.parent().unwrap().join("managed-settings.d");
    let files = policy_files(&[], t.path(), &env);
    assert!(files.contains(&dropins));
    let args = Bound { policy_files: files.clone(), ..sample() }.sandbox_args();
    let index = files.iter().position(|path| path == &dropins).unwrap();
    assert!(
        args[1].contains(&format!("(deny file-write* (subpath (param \"POLICY_FILE{index}\")))"))
    );
}

#[cfg(unix)]
#[test]
fn missing_credential_and_policy_paths_resolve_existing_symlink_ancestors() {
    let t = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(t.path()).unwrap();
    let cwd = root.join("chat");
    let real = root.join("real");
    std::fs::create_dir(&cwd).unwrap();
    std::fs::create_dir(&real).unwrap();
    std::os::unix::fs::symlink(&real, cwd.join("alias")).unwrap();
    let env = BTreeMap::from([
        ("HOME".into(), "alias/new/../home".into()),
        ("GH_CONFIG_DIR".into(), "alias/new/../gh".into()),
        ("XDG_CONFIG_HOME".into(), "alias/new/../xdg".into()),
        ("CLAUDE_CONFIG_DIR".into(), "alias/new/../claude".into()),
    ]);
    let bound = bound(&[], &cwd, &env).unwrap();
    assert_eq!(bound.agent_home, real.join("home"));
    assert_eq!(bound.gh_config_dir, real.join("gh"));
    assert_eq!(bound.xdg_gh_config_dir, real.join("xdg/gh"));
    assert!(bound.policy_files.contains(&real.join("claude/settings.json")));
    assert!(bound.policy_files.contains(&cwd.join("alias/new/../claude/settings.json")));
}

#[cfg(unix)]
#[test]
fn default_agent_policy_paths_protect_symlink_targets_before_creation() {
    let t = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(t.path()).unwrap();
    let cwd = root.join("chat");
    let home = root.join("home");
    let config = cwd.join("config");
    std::fs::create_dir_all(&config).unwrap();
    std::fs::create_dir(&home).unwrap();
    std::os::unix::fs::symlink(&config, home.join(".config")).unwrap();
    let env = BTreeMap::from([("HOME".into(), home.to_string_lossy().into_owned())]);
    let bound = bound(&[], &cwd, &env).unwrap();
    for dir in [cmux_config::NEXT_DIR, cmux_config::location::LEGACY_DIR] {
        let tail = Path::new(dir).join(cmux_config::location::NEXT_FILE_NAME);
        assert!(bound.policy_files.contains(&home.join(".config").join(&tail)));
        assert!(bound.policy_files.contains(&config.join(&tail)));
    }
}
