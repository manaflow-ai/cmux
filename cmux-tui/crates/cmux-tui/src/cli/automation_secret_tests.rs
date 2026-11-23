use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_string).collect()
}

#[test]
fn parses_set_list_and_remove_and_keeps_the_value_off_argv() {
    assert_eq!(
        parse(&words("set scout MODELS_CATALOG_TOKEN")).ok(),
        Some(Verb::Set {
            automation: "scout".into(),
            name: "MODELS_CATALOG_TOKEN".into(),
            file: None
        })
    );
    assert_eq!(
        parse(&words("set scout GH_TOKEN --secret-file /tmp/t")).ok(),
        Some(Verb::Set {
            automation: "scout".into(),
            name: "GH_TOKEN".into(),
            file: Some("/tmp/t".into())
        })
    );
    assert_eq!(parse(&words("list scout")).ok(), Some(Verb::List { automation: "scout".into() }));
    assert_eq!(
        parse(&words("rm scout GH_TOKEN")).ok(),
        Some(Verb::Remove { automation: "scout".into(), name: "GH_TOKEN".into() })
    );
    // A value as an argument is refused, and the message does not echo it.
    let Err(Failure::Usage(m)) = parse(&words("set scout GH_TOKEN ghp_abcdef123456")) else {
        panic!("a value in argv must be refused")
    };
    assert!(!m.contains("ghp_abcdef123456"), "{m}");
    assert!(matches!(parse(&words("set scout GH_TOKEN --value x")), Err(Failure::Usage(_))));
}

#[test]
fn names_are_environment_variable_names() {
    for ok in ["A", "GH_TOKEN", "CMUX_PRO_KEY", "X1"] {
        assert!(valid_name(ok), "{ok}");
    }
    for bad in ["", "gh_token", "1A", "_A", "A-B", "A B", &"A".repeat(65)] {
        assert!(!valid_name(bad), "{bad}");
    }
    assert!(matches!(parse(&words("set scout gh_token")), Err(Failure::Usage(_))));
}

#[test]
fn a_secret_file_is_read_without_its_trailing_line_break_and_a_nul_is_refused() {
    let dir = std::env::temp_dir().join(format!("cmux-secret-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("v");
    std::fs::write(&path, "line one\nline two\n").unwrap();
    assert_eq!(
        read_value("N", Some(&path)).ok().as_deref().map(|v| v.as_str()),
        Some("line one\nline two")
    );
    std::fs::write(&path, "a\0b").unwrap();
    assert!(read_value("N", Some(&path)).is_err());
    std::fs::write(&path, "").unwrap();
    assert!(read_value("N", Some(&path)).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}
