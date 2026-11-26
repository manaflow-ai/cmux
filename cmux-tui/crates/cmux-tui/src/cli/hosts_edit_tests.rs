use super::*;

fn parsed(verb: &str, args: &str) -> Result<HostEdit, String> {
    let words: Vec<&str> = args.split_whitespace().collect();
    parse(verb, &words).expect("an edit verb")
}

#[test]
fn edit_verbs_parse() {
    assert_eq!(
        parsed("add", "studio studio.local ssh://leo@10.0.0.2:2222 --icon desktopcomputer"),
        Ok(HostEdit::Add {
            label: "studio".into(),
            endpoints: vec!["studio.local".into(), "ssh://leo@10.0.0.2:2222".into()],
            icon: Some("desktopcomputer".into()),
        })
    );
    assert_eq!(
        parsed("rename", "studio mini"),
        Ok(HostEdit::Rename { from: "studio".into(), to: "mini".into() })
    );
    assert_eq!(
        parsed("set-endpoints", "studio a b"),
        Ok(HostEdit::SetEndpoints {
            label: "studio".into(),
            endpoints: vec!["a".into(), "b".into()]
        })
    );
    assert_eq!(parsed("rm", "studio"), Ok(HostEdit::Remove { label: "studio".into() }));
    assert!(parsed("add", "studio").is_err());
    assert!(parsed("add", "studio a --bogus").is_err());
    assert!(parsed("rename", "studio").is_err());
    assert!(parsed("set-endpoints", "studio").is_err());
    assert!(parsed("remove", "a b").is_err());
    assert!(parse("frobnicate", &[]).is_none());
}
