use super::*;

fn words(script: &str) -> Vec<Vec<String>> {
    lex(script).unwrap().commands.into_iter().map(|c| c.words).collect()
}

#[test]
fn quotes_keep_an_argument_one_word() {
    assert_eq!(
        words(r#"grep -e 'swift build' "a | b; c""#),
        [["grep", "-e", "swift build", "a | b; c"]]
    );
    assert_eq!(words("echo $'it\\'s' a\\ b"), [["echo", "it's", "a b"]]);
}

#[test]
fn separators_and_redirections() {
    assert_eq!(
        words("a 2>&1 | b && c; d &>log & e"),
        [vec!["a", "2>&1"], vec!["b"], vec!["c"], vec!["d", "&>log"], vec!["e"]]
    );
}

#[test]
fn a_heredoc_body_is_data_and_the_script_goes_on_after_it() {
    let lexed = lex("cat <<'EOF' > f\ntail -f x\nEOF\nls\ncat <<-X\n\twatch\n\tX").unwrap();
    let w: Vec<_> = lexed.commands.iter().map(|c| c.words.clone()).collect();
    assert_eq!(w, [vec!["cat", ">", "f"], vec!["ls"], vec!["cat"]]);
    assert_eq!(lexed.heredocs, [(0, "tail -f x\n".to_owned()), (2, "watch\n".to_owned())]);
    assert!(lexed.subs.is_empty());
}

#[test]
fn an_unquoted_heredoc_body_runs_its_substitutions() {
    let lexed = lex("cat <<EOF\n$(\nswift build\n) `tail -f x` \\$(no)\nEOF").unwrap();
    assert_eq!(lexed.subs, ["\nswift build\n", "tail -f x"]);
    assert!(lex("cat <<'EOF'\n$(swift build)\nEOF").unwrap().subs.is_empty());
    assert!(lex("cat <<\\EOF\n$(swift build)\nEOF").unwrap().subs.is_empty());
}

#[test]
fn pipelines_are_joined_by_a_single_bar() {
    let lexed = lex("a | b && c || d; e & f\ng").unwrap();
    let p: Vec<_> = lexed.commands.iter().map(|c| c.pipeline).collect();
    assert_eq!(p, [0, 0, 1, 2, 3, 4, 5]);
}

#[test]
fn substitutions_are_scripts_of_their_own() {
    let lexed = lex(r#"echo "$(swift build)" `tail -f x` <(watch ls) $((1+2))"#).unwrap();
    assert_eq!(lexed.subs, ["swift build", "tail -f x", "watch ls", "(1+2)"]);
    let lexed = lex(r#"echo "${X:-$(swift build)}" ${Y:-`watch ls`} ${Z#\}}"#).unwrap();
    assert_eq!(lexed.subs, ["swift build", "watch ls"]);
}

#[test]
fn comments_run_nothing() {
    assert_eq!(words("ls # swift build\necho a#b"), [vec!["ls"], vec!["echo", "a#b"]]);
}

#[test]
fn unreadable_input_is_none() {
    for bad in ["echo 'open", "echo \"open", "x $(open", "cat <<EOF\nbody", "echo `open"] {
        assert_eq!(lex(bad), None, "{bad}");
    }
}
