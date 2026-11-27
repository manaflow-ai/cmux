use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_list_and_switches() {
    assert_eq!(parse(&[]), Ok(Request::Help));
    assert_eq!(
        parse(&words("skills list")),
        Ok(Request::List { agent: None, cwd: None, files_only: false })
    );
    assert_eq!(
        parse(&words("skills list --agent codex --cwd /w --files-only")),
        Ok(Request::List { agent: Some("codex".into()), cwd: Some("/w".into()), files_only: true })
    );
    assert_eq!(
        parse(&words("skills off /h/.claude/skills/x/SKILL.md")),
        Ok(Request::Set {
            enabled: false,
            file: "/h/.claude/skills/x/SKILL.md".into(),
            agent: None,
            cwd: None
        })
    );
    assert!(parse(&words("skills on")).is_err());
    assert!(parse(&words("skills list --agent gemini")).is_err());
    assert!(parse(&words("skills list extra")).is_err());
    assert!(parse(&words("mcp list")).is_err());
    assert!(parse(&words("skills")).is_err());
}
