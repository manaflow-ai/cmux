use super::*;

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// W5-Q review (PR C): only the agent start launch shape is marked; a
/// shell, a `pane run -- claude` or a script that only names `cmux-agent`
/// elsewhere is not.
#[test]
fn w5q_only_the_agent_start_launch_is_an_agent_start() {
    assert!(is_agent_start_argv(&words(&[
        "/bin/zsh",
        "-lc",
        "sr2 claude \"$@\"",
        ARG0,
        "--resume",
        "x"
    ])));
    assert!(is_agent_start_argv(&words(&["/bin/sh", "-lc", "claude \"$@\"", ARG0])));
    assert!(!is_agent_start_argv(&words(&["/bin/zsh", "-l"])));
    assert!(!is_agent_start_argv(&words(&["claude"])));
    assert!(!is_agent_start_argv(&words(&["/bin/sh", "-c", "claude \"$@\"", ARG0])));
    assert!(!is_agent_start_argv(&words(&["/bin/sh", "-lc", ARG0, "other"])));
    assert!(!is_agent_start_argv(&[]));
}
