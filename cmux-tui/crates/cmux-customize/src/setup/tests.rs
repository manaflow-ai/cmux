use super::*;

#[test]
fn a_reference_takes_every_form_and_refuses_the_rest() {
    let plain = Reference::parse("github.com/manaflow-ai/cmux-setup-sample").unwrap();
    assert_eq!(plain.key(), "github.com/manaflow-ai/cmux-setup-sample");
    assert_eq!(plain.git_ref, None);
    assert_eq!(plain.page_url(), "https://cmux.com/setups/manaflow-ai/cmux-setup-sample");
    let pinned = Reference::parse("https://github.com/a/b.git@v1.0.0").unwrap();
    assert_eq!((pinned.repo.as_str(), pinned.git_ref.as_deref()), ("b", Some("v1.0.0")));
    let tree = Reference::parse("https://github.com/a/b/tree/main/setups/night").unwrap();
    assert_eq!((tree.path.as_str(), tree.git_ref.as_deref()), ("setups/night", Some("main")));
    assert_eq!(tree.to_string(), "github.com/a/b/setups/night@main");
    let other = Reference::parse("codeberg.org/a/b").unwrap();
    assert_eq!(other.page_url(), "https://cmux.com/setups/codeberg.org/a/b");
    for bad in [
        "a/b",
        "github.com/a",
        "github.com/a/../x",
        "github.com/a/b@-x",
        "github.com/a/b@x..y",
        "local/a/b",
    ] {
        assert!(Reference::parse(bad).is_err(), "{bad}");
    }
}

#[test]
fn an_id_starts_with_its_owner() {
    assert!(check_id("leo/night", "Leo").is_ok());
    assert!(check_id("someone/night", "leo").is_err());
    assert!(check_id("Leo/night", "leo").is_err());
    assert!(check_id("cmux/night", "cmux").is_err());
    assert!(check_id("manaflow-ai/sample", "manaflow-ai").is_ok());
}

#[test]
fn engines_name_the_oldest_cmux() {
    assert!(engine_ok(Some(">=0.70.0"), "0.71.2").is_ok());
    assert!(engine_ok(Some("^0.70"), "0.70.0").is_ok());
    let Err(Error::Setup(why)) = engine_ok(Some(">=0.80.0"), "0.71.2") else { panic!() };
    assert!(why.contains("requires cmux 0.80.0 or later"), "{why}");
    // An unstamped build and an unreadable requirement pass.
    assert!(engine_ok(Some(">=9.0.0"), "0.0.0").is_ok());
    assert!(engine_ok(Some("latest"), "0.71.0").is_ok());
    assert!(engine_ok(None, "0.71.0").is_ok());
}

#[test]
fn actions_are_commands_or_agents_without_secrets() {
    let ok = BTreeMap::from([
        ("hello".to_owned(), serde_json::json!({"type": "command", "command": "echo hi"})),
        ("codex".to_owned(), serde_json::json!({"agent": "codex"})),
    ]);
    assert!(check_actions(&ok).is_ok());
    for bad in [
        serde_json::json!("echo"),
        serde_json::json!({"type": "command"}),
        serde_json::json!({"type": "shell", "command": "x"}),
        serde_json::json!({"command": "curl -H 'Authorization: Bearer ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"}),
    ] {
        assert!(check_actions(&BTreeMap::from([("x".to_owned(), bad.clone())])).is_err(), "{bad}");
    }
    assert!(
        check_actions(&BTreeMap::from([("a b".to_owned(), serde_json::json!({"command": "x"}))]))
            .is_err()
    );
}
