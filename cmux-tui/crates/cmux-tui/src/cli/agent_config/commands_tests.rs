use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_add_list_remove() {
    assert_eq!(parse(&[]), Ok(Request::Help));
    assert_eq!(parse(&words("list")), Ok(Request::List { agent: None }));
    assert_eq!(parse(&words("ls --agent cmux")), Ok(Request::List { agent: Some(Target::Cmux) }));
    let mut add = words("add review --agent codex --description d --replace --prompt");
    add.push("Review --this diff".into());
    assert_eq!(
        parse(&add),
        Ok(Request::Add {
            agent: Target::Codex,
            name: "review".into(),
            prompt: Prompt::Text("Review --this diff".into()),
            description: "d".into(),
            replace: true,
        })
    );
    assert_eq!(
        parse(&words("add x --prompt-file -")),
        Ok(Request::Add {
            agent: Target::Claude,
            name: "x".into(),
            prompt: Prompt::Stdin,
            description: String::new(),
            replace: false,
        })
    );
    assert_eq!(
        parse(&words("rm x --agent cmux")),
        Ok(Request::Remove { agent: Target::Cmux, name: "x".into() })
    );
    assert!(parse(&words("add x")).is_err(), "no prompt");
    assert!(parse(&words("add --prompt p")).is_err(), "no name");
    assert!(parse(&words("add x --prompt p --agent gemini")).is_err());
    assert!(parse(&words("list extra")).is_err());
    assert!(parse(&words("list --replace")).is_err());
    assert!(parse(&words("edit x")).is_err());
}

#[test]
fn usage_lists_every_verb() {
    for verb in ["commands add", "commands list", "commands remove"] {
        assert!(USAGE.contains(&format!("cmux agent-config {verb}")), "{verb}");
    }
}
