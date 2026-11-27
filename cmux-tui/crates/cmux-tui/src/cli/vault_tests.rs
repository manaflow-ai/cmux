use super::*;

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_every_verb() {
    assert_eq!(parse(&words("status")).unwrap().0, Verb::Status);
    assert_eq!(parse(&words("approve 1234 5678")).unwrap().0, Verb::Approve("1234 5678".into()));
    assert!(parse(&words("approve 123")).is_err());
    assert_eq!(
        parse(&words("set OPENAI_API_KEY --repo Manaflow-AI/cmux")).unwrap().0,
        Verb::Set { name: "OPENAI_API_KEY".into(), scope: Scope::Repo("manaflow-ai/cmux".into()) }
    );
    assert!(parse(&words("set PATH")).is_err());
    assert!(parse(&words("set A --repo a/b --machine vm_abcdefghij0123456789")).is_err());
    assert_eq!(
        parse(&words("import .env --only A,B")).unwrap().0,
        Verb::Import {
            file: ".env".into(),
            only: Some(vec!["A".into(), "B".into()]),
            all: false,
            scope: Scope::All
        }
    );
    let (verb, opts) = parse(&words("ls --team team_abc")).unwrap();
    assert_eq!((verb, opts.team.as_deref()), (Verb::Ls, Some("team_abc")));
    assert!(parse(&words("ls --team nope")).is_err());
    assert_eq!(parse(&[]).unwrap().0, Verb::Help);
}
