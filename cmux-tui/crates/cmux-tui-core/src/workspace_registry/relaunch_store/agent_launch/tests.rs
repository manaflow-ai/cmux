use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect()
}

#[test]
fn claude_keeps_flags_and_account_and_drops_session_and_prompt() {
    let launch = agent_launch_from_job(
        "claude",
        &strings(&[
            "/opt/homebrew/bin/claude",
            "--dangerously-skip-permissions",
            "--model",
            "opus",
            "--resume",
            "old-id",
            "--continue",
            "fix the bug",
        ]),
        &env(&[("CLAUDE_CONFIG_DIR", "/Users/a/.claude-work"), ("CODEX_HOME", "/x")]),
    )
    .unwrap();
    assert_eq!(launch.args, strings(&["--dangerously-skip-permissions", "--model", "opus"]));
    assert_eq!(launch.env, env(&[("CLAUDE_CONFIG_DIR", "/Users/a/.claude-work")]));
}

#[test]
fn the_shims_arguments_win_over_the_injected_argv() {
    let args = r#"["--model","sonnet","--settings","/Users/a/s.json"]"#;
    let launch = agent_launch_from_job(
        "claude",
        &strings(&["claude", "--settings", "/cache/hooks-123.json", "--model", "sonnet"]),
        &env(&[(SHIM_ARGS_ENV, args)]),
    )
    .unwrap();
    assert_eq!(launch.args, strings(&["--model", "sonnet", "--settings", "/Users/a/s.json"]));
    assert!(launch.env.is_empty());
}

#[test]
fn node_installs_and_wrappers_find_the_program_word() {
    let npm =
        strings(&["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose"]);
    assert_eq!(agent_launch_from_job("claude", &npm, &[]).unwrap().args, strings(&["--verbose"]));
    let wrapped = strings(&["python3", "/tmp/fake.py", "codex", "-m", "gpt-5.5"]);
    assert_eq!(
        agent_launch_from_job("codex", &wrapped, &[]).unwrap().args,
        strings(&["-m", "gpt-5.5"])
    );
    assert!(agent_launch_from_job("claude", &strings(&["zsh", "-l"]), &[]).is_none());
    assert!(agent_launch_from_job("opencode", &strings(&["opencode"]), &[]).is_none());
}

#[test]
fn codex_resume_and_non_interactive_runs() {
    let resumed = strings(&[
        "codex",
        "resume",
        "abc",
        "--dangerously-bypass-approvals-and-sandbox",
        "-m",
        "gpt",
    ]);
    assert_eq!(
        agent_launch_from_job("codex", &resumed, &[]).unwrap().args,
        strings(&["--dangerously-bypass-approvals-and-sandbox", "-m", "gpt"])
    );
    assert!(agent_launch_from_job("codex", &strings(&["codex", "exec", "do it"]), &[]).is_none());
    assert!(agent_launch_from_job("claude", &strings(&["claude", "-p", "hi"]), &[]).is_none());
}

/// A non-interactive run of the harness (`claude -p`, `codex exec`) has
/// no session to resume; an interactive one, another program, or a
/// process that could not be read says nothing.
#[test]
fn a_non_interactive_run_is_told_apart_from_an_unknown_process() {
    let non_interactive =
        |harness: &str, argv: &[&str]| job_is_non_interactive(harness, &strings(argv), &[]);
    assert!(non_interactive("claude", &["claude", "-p", "hi"]));
    assert!(non_interactive("claude", &["/bin/sh", "/tmp/x/claude", "--print", "hi"]));
    assert!(non_interactive("codex", &["codex", "exec", "do it"]));
    assert!(non_interactive("claude", &["claude", "mcp", "list"]));
    assert!(non_interactive("claude", &["claude", "--model", "opus", "-p", "hi"]));
    assert!(non_interactive("codex", &["codex", "-m", "gpt-5.5", "exec", "do it"]));
    assert!(non_interactive("codex", &["codex", "--version"]));
    assert!(!non_interactive("claude", &["claude", "--model", "opus"]));
    assert!(!non_interactive("claude", &["claude", "fix the bug"]));
    // An interactive Codex session started with its first prompt.
    assert!(!non_interactive("codex", &["codex", "fix the bug"]));
    assert!(!non_interactive("codex", &["codex", "-m", "gpt-5.5", "fix the bug"]));
    assert!(!non_interactive("codex", &["codex", "resume", "abc"]));
    assert!(!non_interactive("claude", &["zsh", "-l"]));
    assert!(!non_interactive("opencode", &["opencode", "run", "x"]));
    // The shim's arguments are the CLI's own.
    let shim = env(&[(SHIM_ARGS_ENV, r#"["-p","hi"]"#)]);
    assert!(job_is_non_interactive("claude", &strings(&["claude", "-p", "hi"]), &shim));
}

#[test]
fn a_credential_drops_the_flags_and_a_relative_account_is_not_kept() {
    let launch = agent_launch_from_job(
        "claude",
        &strings(&["claude", "--model", "opus", "--api-key", "sk-ant-123"]),
        &env(&[("CLAUDE_CONFIG_DIR", "relative/dir")]),
    )
    .unwrap();
    assert_eq!(launch.args, strings(&["--model", "opus"]));
    assert!(launch.env.is_empty());
}

#[test]
fn an_unknown_flag_goes_with_its_value_and_lists_keep_every_value() {
    let launch = agent_launch_from_job(
        "claude",
        &strings(&[
            "claude",
            "--output-format",
            "stream-json",
            "--add-dir",
            "a",
            "b",
            "--verbose",
            "--max-turns",
            "3",
            "--model",
            "opus",
            "--some-switch",
        ]),
        &[],
    )
    .unwrap();
    assert_eq!(
        launch.args,
        strings(&["--add-dir", "a", "b", "--verbose", "--model", "opus", "--some-switch"])
    );
}

#[test]
fn inline_configuration_and_secrets_anywhere_are_dropped() {
    let claude = agent_launch_from_job(
        "claude",
        &strings(&[
            "claude",
            "--settings",
            r#"{"env":{"ANTHROPIC_BASE_URL":"x"}}"#,
            "--mcp-config",
            "/p/mcp.json",
            "--append-system-prompt",
            "use ghp_abc for it",
            "--model",
            "opus",
        ]),
        &[],
    )
    .unwrap();
    assert_eq!(claude.args, strings(&["--mcp-config", "/p/mcp.json", "--model", "opus"]));
    let codex = agent_launch_from_job(
        "codex",
        &strings(&[
            "codex",
            "-c",
            "mcp_servers.x.env={API=\"1\"}",
            "--config=a=b",
            r#"-csandbox_mode="danger-full-access""#,
            "-m",
            "gpt",
        ]),
        &[],
    )
    .unwrap();
    assert_eq!(codex.args, strings(&["-m", "gpt"]));
}

#[test]
fn codex_runs_only_without_a_subcommand_or_as_resume() {
    assert!(agent_launch_from_job("codex", &strings(&["codex", "cloud"]), &[]).is_none());
    // An interactive session started with its first prompt keeps its flags and account.
    let prompted = agent_launch_from_job(
        "codex",
        &strings(&["codex", "-m", "gpt", "fix the bug"]),
        &env(&[("CODEX_HOME", "/accounts/work")]),
    )
    .unwrap();
    assert_eq!(prompted.args, strings(&["-m", "gpt"]));
    assert_eq!(prompted.env, env(&[("CODEX_HOME", "/accounts/work")]));
    assert!(agent_launch_from_job("claude", &strings(&["claude", "mcp", "list"]), &[]).is_none());
    let plain = agent_launch_from_job("codex", &strings(&["codex", "-m", "gpt"]), &[]).unwrap();
    assert_eq!(plain.args, strings(&["-m", "gpt"]));
}

/// Muse Code's `muse` launcher `exec`s its versioned binary: that is the
/// process the terminal runs. Its flags are kept; what picks a session, a
/// worktree or an image, and inline configuration are not.
#[test]
fn muse_keeps_its_flags_from_the_binary_its_launcher_runs() {
    let binary = "/Users/a/.local/bin/muse-bin-1.4.14-R7309.1";
    let yolo = agent_launch_from_job("muse", &strings(&[binary, "--yolo"]), &[]).unwrap();
    assert_eq!(yolo, AgentLaunch { args: strings(&["--yolo"]), env: Vec::new() });
    let resumed = agent_launch_from_job(
        "muse",
        &strings(&[
            "muse",
            "--model",
            "muse-wonder-1.0",
            "resume",
            "01a14ec1-9cca-7b72-832c-5148ab7bcd41",
            "-w",
            "create",
            "--image",
            "/tmp/a.png",
            "-c",
            "provider.token=${T}",
            "--agents",
            "{\"a\":1}",
            "--approval-mode",
            "never",
        ]),
        &[],
    )
    .unwrap();
    assert_eq!(resumed.args, strings(&["--model", "muse-wonder-1.0", "--approval-mode", "never"]));
    let last = agent_launch_from_job("muse", &strings(&["muse", "resume", "--last"]), &[]);
    assert_eq!(last.unwrap().args, Vec::<String>::new());
    // A prompt starts a session; it is not kept.
    let prompted =
        agent_launch_from_job("muse", &strings(&["muse", "--effort", "max", "fix it"]), &[]);
    assert_eq!(prompted.unwrap().args, strings(&["--effort", "max"]));
    for run in [&["muse", "exec", "hi"][..], &["muse", "--version"], &["muse", "usage"]] {
        assert!(agent_launch_from_job("muse", &strings(run), &[]).is_none(), "{run:?}");
        assert!(job_is_non_interactive("muse", &strings(run), &[]), "{run:?}");
    }
    assert!(!job_is_non_interactive("muse", &strings(&[binary, "--yolo"]), &[]));
    // Another program is not Muse.
    assert!(agent_launch_from_job("muse", &strings(&["zsh", "-l"]), &[]).is_none());
    assert!(
        agent_launch_from_job("muse", &strings(&["museum"]), &[]).is_none(),
        "only muse and its launcher's binary"
    );
}

#[test]
fn the_shims_arguments_need_the_harness_process() {
    let args = r#"["--model","opus"]"#;
    let other = strings(&["node", "/usr/lib/node_modules/some-tool/index.js"]);
    assert!(agent_launch_from_job("claude", &other, &env(&[(SHIM_ARGS_ENV, args)])).is_none());
}
