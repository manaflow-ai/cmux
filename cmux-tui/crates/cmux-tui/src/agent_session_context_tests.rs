use super::*;

#[test]
fn the_verb_and_its_hook_command_agree() {
    let args = |words: &[&str]| words.iter().map(OsString::from).collect::<Vec<_>>();
    assert!(invocation(&args(&["agent", "session-context"])));
    assert!(!invocation(&args(&["agent", "session-context", "x"])));
    assert!(!invocation(&args(&["agent", "list"])));
    let command = hook_command(Path::new("/opt/cmux tui/cmux-tui")).unwrap();
    assert_eq!(command, "'/opt/cmux tui/cmux-tui' agent session-context");
}
