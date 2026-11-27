use super::*;

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| arg.to_string()).collect()
}

#[test]
fn known_harnesses_resume_valid_sessions_only() {
    assert_eq!(
        resume_command("claude", "abc-123", None).as_deref(),
        Some("claude --resume abc-123")
    );
    assert_eq!(resume_command("codex", "s.1_2", None).as_deref(), Some("codex resume s.1_2"));
    assert_eq!(resume_command("claude", "abc;rm -rf", None), None);
    assert_eq!(resume_command("claude", &"a".repeat(129), None), None);
    assert_eq!(
        resume_command("muse", "01a14ec1-9cca-7b72-832c-5148ab7bcd41", None).as_deref(),
        Some("muse resume 01a14ec1-9cca-7b72-832c-5148ab7bcd41")
    );
    assert_eq!(resume_command("opencode", "abc", None), None);
}

#[test]
fn a_muse_resume_starts_the_cli_with_its_flags() {
    let launch = AgentLaunch {
        args: strings(&["--model", "muse-wonder-1.0"]),
        env: vec![],
        wrapper: vec![],
    };
    assert_eq!(
        resume_command("muse", "s1", Some(&launch)).as_deref(),
        Some("muse resume s1 --model muse-wonder-1.0")
    );
}

#[test]
fn a_resume_starts_the_cli_with_its_flags_and_account() {
    let launch = |args: &[&str], env: &[(&str, &str)]| AgentLaunch {
        args: strings(args),
        env: env.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect(),
        wrapper: vec![],
    };
    let claude = launch(
        &["--dangerously-skip-permissions", "--model", "claude-sonnet-5-5"],
        &[("CLAUDE_CONFIG_DIR", "/Users/a/Claude Work")],
    );
    assert_eq!(
        resume_command("claude", "abc-123", Some(&claude)).as_deref(),
        Some(
            "CLAUDE_CONFIG_DIR='/Users/a/Claude Work' claude --resume abc-123 \
                 --dangerously-skip-permissions --model claude-sonnet-5-5"
        )
    );
    let codex = launch(&["-m", "gpt-5.5"], &[("CODEX_HOME", "/Users/a/.codex-2")]);
    assert_eq!(
        resume_command("codex", "s1", Some(&codex)).as_deref(),
        Some("CODEX_HOME=/Users/a/.codex-2 codex resume s1 -m gpt-5.5")
    );
}

/// https://github.com/manaflow-ai/cmux/issues/55601: an `sr2 claude` terminal
/// resumes through `sr2`, with its flags, and runs by itself, approvals off
/// included: the person started it that way.
#[test]
fn a_wrapped_agent_resumes_through_its_launcher_and_runs() {
    let launch = AgentLaunch {
        args: strings(&["--dangerously-skip-permissions"]),
        env: vec![],
        wrapper: strings(&["sr2"]),
    };
    assert_eq!(
        resume_command("claude", "abc-123", Some(&launch)).as_deref(),
        Some("sr2 claude --resume abc-123 --dangerously-skip-permissions")
    );
    let codex = AgentLaunch { args: strings(&["--yolo"]), env: vec![], wrapper: strings(&["sr2"]) };
    assert_eq!(
        resume_command("codex", "s1", Some(&codex)).as_deref(),
        Some("sr2 codex resume s1 --yolo")
    );
    let record = StoredRelaunch {
        cwd: None,
        kind: RelaunchKind::Shell,
        shell_path: Some("/bin/zsh".into()),
        program: None,
        argv: None,
        env: vec![],
        agent: Some(("claude".into(), "abc-123".into())),
        agent_launch: Some(launch),
    };
    let prefill = agent_prefill(&record, true).expect("a known agent resumes");
    assert!(prefill.run, "it runs, with no Return to type");
    assert_eq!(
        prefill.input(&mut screen(PROMPT), true).as_deref(),
        Some("sr2 claude --resume abc-123 --dangerously-skip-permissions\r")
    );
    assert_eq!(agent_prefill(&record, false), None, "Resume Agents After Restart off");
}

/// A 60-column screen that received `bytes`.
fn screen(bytes: &[u8]) -> ghostty_vt::Terminal {
    let mut term = ghostty_vt::Terminal::new(60, 5, 1_000, Default::default()).unwrap();
    term.vt_write(bytes);
    term
}

const PROMPT: &[u8] = b"restored\r\n\x1b]133;A\x07user@host:~$ \x1b]133;B\x07";

#[test]
fn a_resume_runs_only_at_an_empty_marked_prompt_of_the_shell_itself() {
    let prefill = Prefill { kind: Prefilled::Harness, text: "claude --resume a".into(), run: true };
    // The shell's own prompt, marked by shell integration, nothing typed on it.
    assert_eq!(prefill.input(&mut screen(PROMPT), true).as_deref(), Some("claude --resume a\r"));
    // Else nothing is written; the marker line shows the command.
    // A program the shell's startup files started holds the terminal (tmux, ssh, a question).
    assert_eq!(prefill.input(&mut screen(PROMPT), false), None);
    // No mark: a startup question, or a shell without integration.
    let question: &[u8] = b"Update oh-my-zsh now? [Y/n] ";
    assert_eq!(prefill.input(&mut screen(question), true), None);
    // The person typed on the new prompt before it was written: never touch their line.
    let typed = [PROMPT, b"git sta".as_slice()].concat();
    assert_eq!(prefill.input(&mut screen(&typed), true), None);
    // The prompt went back to output (a command runs).
    let running = [PROMPT, b"make\r\n\x1b]133;C\x07building".as_slice()].concat();
    assert_eq!(prefill.input(&mut screen(&running), true), None);
}

#[test]
fn what_does_not_run_by_itself_is_typed_without_return() {
    let resume = Prefill { kind: Prefilled::Resume, text: "npm run dev".into(), run: false };
    assert_eq!(
        resume.input(&mut screen(PROMPT), true).as_deref(),
        Some("npm run dev"),
        "a person's resume command waits for Return"
    );
    let typed = [PROMPT, b"git sta".as_slice()].concat();
    assert_eq!(resume.input(&mut screen(&typed), true), None);
}

#[test]
fn a_freed_shells_last_command_is_typed_without_return() {
    let last = last_command_prefill("  cargo test -p core  ").expect("one line is typed");
    assert_eq!(last.kind, Prefilled::LastCommand);
    assert_eq!(last.input(&mut screen(PROMPT), true).as_deref(), Some("cargo test -p core"));
    assert_eq!(last.input(&mut screen(PROMPT), false), None, "not over a foreground job");
    let typed = [PROMPT, b"git sta".as_slice()].concat();
    assert_eq!(last.input(&mut screen(&typed), true), None);
    assert_eq!(last_command_prefill("cat <<EOF\nhi\nEOF"), None, "never a multi-line one");
    assert_eq!(last_command_prefill("   "), None);
}

#[test]
fn only_posix_shells_run_the_resume() {
    for shell in ["/bin/zsh", "/opt/homebrew/bin/bash", "-zsh", "sh", "/bin/dash", "ksh"] {
        assert!(posix_shell(shell), "{shell}");
    }
    for shell in ["/opt/homebrew/bin/fish", "/bin/tcsh", "/usr/local/bin/nu", "csh", "elvish", ""] {
        assert!(!posix_shell(shell), "{shell}");
    }
}

#[test]
fn argv_is_quoted_for_one_shell_line() {
    let argv = ["git", "commit", "-m", "it's done", ""].map(String::from);
    assert_eq!(shell_quoted(&argv).as_deref(), Some("git commit -m 'it'\\''s done' ''"));
    assert_eq!(shell_quoted(&["echo".into(), "a\nb".into()]), None);
    assert_eq!(shell_quoted(&[]), None);
}
