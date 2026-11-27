use super::*;

fn procargs(exec: &str, argv: &[&str], env: &[&str]) -> Vec<u8> {
    let mut bytes = (argv.len() as i32).to_ne_bytes().to_vec();
    bytes.extend_from_slice(exec.as_bytes());
    bytes.extend_from_slice(&[0, 0, 0]);
    for part in argv.iter().chain(env) {
        bytes.extend_from_slice(part.as_bytes());
        bytes.push(0);
    }
    bytes.extend_from_slice(&[0, 0]);
    bytes.extend_from_slice(b"ptr_munge=1\0");
    bytes
}

#[test]
fn procargs2_gives_argv_and_only_the_requested_keys() {
    let bytes = procargs(
        "/usr/local/bin/claude",
        &["claude", "--model", "opus", "--dangerously-skip-permissions"],
        &[
            "HOME=/Users/a",
            "ANTHROPIC_API_KEY=sk-secret",
            "CLAUDE_CONFIG_DIR=/Users/a/.claude-work",
        ],
    );
    let launch = parse_procargs2(&bytes, &["CLAUDE_CONFIG_DIR", "CODEX_HOME"]).unwrap();
    assert_eq!(launch.argv, ["claude", "--model", "opus", "--dangerously-skip-permissions"]);
    assert_eq!(
        launch.env,
        [("CLAUDE_CONFIG_DIR".to_string(), "/Users/a/.claude-work".to_string())]
    );
}

#[test]
fn a_retitled_process_still_gives_its_environment() {
    // `process.title = "claude"`: the argument area is the title, then NULs
    // to its old end, before the untouched environment.
    let mut bytes = 3i32.to_ne_bytes().to_vec();
    bytes.extend_from_slice(b"/usr/local/bin/node\0\0\0");
    bytes.extend_from_slice(b"claude\0");
    bytes.extend_from_slice(&[0; 40]);
    bytes.extend_from_slice(
        b"HOME=/Users/a\0CLAUDE_CONFIG_DIR=/Users/a/.claude-2\0\0\0ptr_munge=1\0",
    );
    let launch = parse_procargs2(&bytes, &["CLAUDE_CONFIG_DIR"]).unwrap();
    assert_eq!(launch.argv.first().map(String::as_str), Some("claude"));
    assert_eq!(launch.env, [("CLAUDE_CONFIG_DIR".to_string(), "/Users/a/.claude-2".to_string())]);
}

#[test]
fn a_truncated_buffer_is_refused() {
    let bytes = procargs("/bin/codex", &["codex", "-m", "gpt"], &[]);
    assert!(parse_procargs2(&bytes[..12], &[]).is_none());
    assert!(parse_procargs2(&[1, 0], &[]).is_none());
}

#[test]
fn linux_strings_split_on_nul() {
    assert_eq!(
        nul_strings(b"codex\0resume\0abc\0").collect::<Vec<_>>(),
        ["codex", "resume", "abc"]
    );
    let env = pick_env(nul_strings(b"CODEX_HOME=/h\0CODEX_HOME=/later\0X=1\0"), &["CODEX_HOME"]);
    assert_eq!(env, [("CODEX_HOME".to_string(), "/h".to_string())]);
}

#[cfg(unix)]
#[test]
fn a_live_process_reads_its_own_launch() {
    // This test process: its argv[0] and a key it does have.
    let launch = process_launch(std::process::id(), &["PATH"]).expect("own launch");
    assert!(!launch.argv.is_empty());
    assert_eq!(launch.env.first().map(|(key, _)| key.as_str()), Some("PATH"));
}
