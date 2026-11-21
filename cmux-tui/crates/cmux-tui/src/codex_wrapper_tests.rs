use super::*;
use cmux_tui_core::user_settings::AgentsCmuxMcp;

fn os(args: &[&str]) -> Vec<OsString> {
    args.iter().map(OsString::from).collect()
}

/// The settings one launch in `/work` gets.
fn launch(choice: AgentsCmuxMcp, args: &[&str]) -> Vec<String> {
    launch_with(choice, args, &acpmux::codex_cmux_entry::CmuxEntry::None)
}

/// The settings one launch in `/work` gets when Codex answers `entry` for the person's own
/// `cmux` entry.
/// (A launch in doubt, `launch_entry`, is not asked and gets doubt instead of `entry`.)
fn launch_with(
    choice: AgentsCmuxMcp,
    args: &[&str],
    entry: &acpmux::codex_cmux_entry::CmuxEntry,
) -> Vec<String> {
    let entry = &launch_entry(&os(args), || entry.clone());
    let pane = |name: &str| (name == "CMUX_TUI_TERMINAL_ID").then(|| OsString::from("term_1"));
    let settings = mcp_settings(
        &McpLaunch {
            cwd: Path::new("/work"),
            executable: Path::new("/A/cmux"),
            socket: Path::new("/tmp/s.sock"),
        },
        choice,
        &pane,
        entry,
    );
    settings.iter().map(|s| s.to_string_lossy().into_owned()).collect()
}

/// The server goes in only with the person's yes, under the name `cmux`, for every new
/// session: interactive, with a prompt, exec, review.
#[test]
fn the_server_goes_in_as_cmux_only_with_the_persons_yes() {
    for choice in [AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
        assert!(launch(choice, &["exec", "hi there"]).is_empty(), "{choice:?}");
    }
    for args in [
        &[][..],
        &["fix the bug"],
        &["exec", "fix the bug"],
        &["review", "--uncommitted"],
        &["-c", "model=\"o3\"", "exec", "-C", "/w", "hi"],
    ] {
        let settings = launch(AgentsCmuxMcp::On, args);
        assert!(settings.iter().all(|s| s.starts_with("mcp_servers.cmux.")), "{settings:?}");
        assert!(settings.contains(&"mcp_servers.cmux.command=\"/A/cmux\"".to_owned()));
        assert!(settings.contains(&"mcp_servers.cmux.enabled=true".to_owned()), "{args:?}");
        assert!(settings.contains(&"mcp_servers.cmux.cwd=\"/work\"".to_owned()), "{args:?}");
    }
}

/// Without the yes, a person's own stdio `cmux` entry, as Codex answers it, gets the answer
/// with exactly its command and args beside it (the same entry); an HTTP one (no env), none,
/// and no answer get nothing. With the yes, an HTTP entry keeps cmux's server out.
#[test]
fn without_the_yes_a_persons_stdio_entry_gets_the_answer_and_stays_whole() {
    use acpmux::codex_cmux_entry::CmuxEntry;
    let stdio = CmuxEntry::Stdio { command: "/c".into(), args: vec!["a b".into()] };
    for choice in [AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
        assert_eq!(
            launch_with(choice, &["exec", "hi"], &stdio),
            [
                "mcp_servers.cmux.command=\"/c\"",
                "mcp_servers.cmux.args=[\"a b\"]",
                "mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER=\"off\""
            ],
            "{choice:?}"
        );
        for nothing in [CmuxEntry::None, CmuxEntry::Http, CmuxEntry::Unknown] {
            assert!(launch_with(choice, &["exec", "hi"], &nothing).is_empty(), "{nothing:?}");
        }
    }
    let on = |entry| launch_with(AgentsCmuxMcp::On, &["exec", "hi"], &entry);
    assert!(on(stdio).contains(&"mcp_servers.cmux.enabled=true".to_owned()));
    assert!(on(CmuxEntry::None).contains(&"mcp_servers.cmux.enabled=true".to_owned()));
    assert!(on(CmuxEntry::Http).is_empty(), "an HTTP entry keeps the name");
}

/// Skip on doubt: no answer from Codex, a project file Codex's answer does not show it
/// loads, or a launch whose loaded config can differ from the question gets no setting at
/// all (neither the server nor env keys), with the yes or without it, whatever the answer.
#[test]
fn a_launch_in_doubt_gets_no_setting_at_all() {
    use acpmux::codex_cmux_entry::CmuxEntry;
    let stdio = CmuxEntry::Stdio { command: "/c".into(), args: vec![] };
    for choice in [AgentsCmuxMcp::On, AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
        for entry in [CmuxEntry::Unknown, CmuxEntry::Doubt("a project file".into())] {
            assert!(launch_with(choice, &["exec", "hi"], &entry).is_empty(), "{entry:?}");
        }
        for args in [
            &["--trust"][..],
            &["exec", "--trust", "hi"],
            &["--worktree"],
            &["--ignore-user-config", "exec", "hi"],
            &["--remote", "ws://h"],
            &["resume", "--last"],
            &["resume", "019a"],
            &["fork", "--last"],
            &["exec", "resume", "--last", "go on"],
            &["exec", "fork", "019a"],
            &["--last"],
            &["agents"],
            &["mcp", "list"],
            &["-c", "x=1", "resume"],
        ] {
            for entry in [CmuxEntry::None, stdio.clone()] {
                let settings = launch_with(choice, args, &entry);
                assert!(settings.is_empty(), "{choice:?} {args:?} {settings:?}");
            }
        }
    }
    assert!(acpmux::codex_cmux_entry::launch_doubt(&os(&["-p", "resume", "hi"])).is_none());
    assert!(acpmux::codex_cmux_entry::launch_doubt(&os(&["exec", "--", "resume"])).is_none());
}

/// Codex 0.160.1 keeps only the deepest list of a clap global (`-c`,
/// `--enable`, `--disable`): a subcommand's own list replaces the root's.
/// The shim hoists them to the root after every session subcommand.
#[test]
fn global_settings_after_a_session_subcommand_are_hoisted() {
    fn surviving(argv: &[OsString]) -> Vec<String> {
        let argv: Vec<String> = argv.iter().map(|arg| arg.to_string_lossy().into_owned()).collect();
        let mut lists = vec![Vec::new()];
        let mut index = 0;
        while index < argv.len() {
            let arg = argv[index].as_str();
            if arg == "--" {
                break;
            }
            if matches!(arg, "-c" | "--config" | "--enable" | "--disable") {
                lists.last_mut().unwrap().push(argv[index + 1].clone());
                index += 2;
                continue;
            }
            if !arg.starts_with('-') && SUBCOMMANDS.contains(&arg) {
                lists.push(Vec::new());
            }
            index += if launch_classification::consumes_value(arg) { 2 } else { 1 };
        }
        lists.into_iter().rev().find(|list| !list.is_empty()).unwrap_or_default()
    }
    const SUBCOMMANDS: &[&str] = &["exec", "e", "review", "agents", "resume", "fork"];
    let ours = [OsString::from("-c"), OsString::from("hooks.x=1")];
    for (args, theirs) in [
        (&["review", "-c", "model=o3", "--uncommitted"][..], "model=o3"),
        (&["agents", "-c", "x=1"], "x=1"),
        (&["exec", "-c", "x=1", "hi"], "x=1"),
        (&["resume", "--last", "--config", "x=1"], "x=1"),
    ] {
        let mut argv = ours.to_vec();
        argv.extend(hoist_session_global_args(&os(args)));
        let kept = surviving(&argv);
        assert!(kept.contains(&"hooks.x=1".to_owned()), "{args:?}: {argv:?} keeps {kept:?}");
        assert!(kept.contains(&theirs.to_owned()), "{args:?}: {argv:?} keeps {kept:?}");
    }
}

/// `codex agents` (the agent command center) and `codex review` start agent sessions, so both
/// get the hooks. Only `review` (a new session) gets the server: `agents` browses and switches
/// to other sessions, in their own folders, so what it loads is in doubt (`launch_doubt`) and it
/// gets the hooks only. A command that starts no session gets neither.
#[test]
fn agents_gets_the_hooks_only_and_review_the_server_too() {
    let pane = |name: &str| (name == "CMUX_TUI_TERMINAL_ID").then(|| OsString::from("term_1"));
    for args in [&["agents"][..], &["review", "--uncommitted"], &["-m", "o3", "agents"]] {
        assert!(should_inject(&os(args), pane), "{args:?}");
    }
    for args in [&["agents"][..], &["-m", "o3", "agents"]] {
        assert!(launch(AgentsCmuxMcp::On, args).is_empty(), "{args:?}");
    }
    let review = launch(AgentsCmuxMcp::On, &["review", "--uncommitted"]);
    assert!(review.contains(&"mcp_servers.cmux.enabled=true".to_owned()), "{review:?}");
    for args in [&["a"][..], &["apply"], &["mcp", "list"], &["git-credential", "get"]] {
        assert!(!should_inject(&os(args), pane), "{args:?}");
    }
}
