use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_list() {
    assert_eq!(parse(&[]), Ok(Request::List { cwd: None }));
    assert_eq!(parse(&words("--help")), Ok(Request::Help));
    assert_eq!(parse(&words("--cwd /w")), Ok(Request::List { cwd: Some("/w".into()) }));
    assert_eq!(parse(&words("list")), Ok(Request::List { cwd: None }));
    assert_eq!(parse(&words("ls --cwd /w")), Ok(Request::List { cwd: Some("/w".into()) }));
    assert!(parse(&words("list extra")).is_err());
    assert!(parse(&words("add x")).is_err());
    assert!(parse(&words("list --cwd")).is_err());
}

#[test]
fn table_marks_the_hidden_one() {
    let root = tempfile::tempdir().unwrap();
    let homes = Homes::under(root.path());
    let dir = homes.claude.join("agents");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a.md"), "---\nname: rev\ndescription: Reviews.\ntools: Read\n---\n")
        .unwrap();
    let text = table(&subagents::list(&homes, None));
    assert!(text.contains("user     on   rev"), "{text}");
    assert!(text.contains("Claude Code: 1 subagents on, 1 listed."), "{text}");
}
