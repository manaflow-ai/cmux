use super::*;

fn w(tool: &str, args: Value) -> Result<Vec<String>, String> {
    words(tool, args.as_object().unwrap())
}

#[test]
fn kit_tool_arguments_become_the_cli_words() {
    assert_eq!(w(TOKENS, json!({"action": "list"})).unwrap(), ["tokens", "list"]);
    assert_eq!(
        w(TOKENS, json!({"action": "list", "group": "ink"})).unwrap(),
        ["tokens", "list", "ink"]
    );
    assert_eq!(
        w(TOKENS, json!({"action": "show", "name": "--instrument-seed-grid"})).unwrap(),
        ["tokens", "show", "--instrument-seed-grid"]
    );
    assert_eq!(
        w(TOKENS, json!({"action": "test", "value": 14, "family": "spacing"})).unwrap(),
        ["tokens", "test", "14", "--as", "spacing"]
    );
    assert_eq!(
        w(TOKENS, json!({"action": "test", "value": "180ms"})).unwrap(),
        ["tokens", "test", "180ms"]
    );
    assert_eq!(
        w(COMPONENTS, json!({"action": "list", "filter": "kit"})).unwrap(),
        ["components", "list", "kit"]
    );
    assert_eq!(
        w(COMPONENTS, json!({"action": "test", "name": "Pill", "props": {"label": "x"}})).unwrap(),
        ["components", "test", "Pill", r#"{"label":"x"}"#]
    );
    for (tool, bad) in [
        (TOKENS, json!({})),
        (TOKENS, json!({"action": "frob"})),
        (TOKENS, json!({"action": "show"})),
        (TOKENS, json!({"action": "test"})),
        (TOKENS, json!({"action": "list", "name": "x"})),
        (COMPONENTS, json!({"action": "test", "name": "Pill", "props": [1]})),
        (COMPONENTS, json!({"action": "show", "props": {}})),
    ] {
        assert!(w(tool, bad.clone()).is_err(), "{tool} {bad}");
    }
    let names: Vec<Value> = descriptors().into_iter().map(|d| d["name"].clone()).collect();
    assert_eq!(names, [json!(TOKENS), json!(COMPONENTS)]);
}

#[test]
fn kit_tool_words_parse_as_the_cli_verbs() {
    for (tool, args) in [
        (TOKENS, json!({"action": "test", "value": 14, "family": "spacing"})),
        (TOKENS, json!({"action": "show", "name": "--instrument-seed-grid"})),
        (COMPONENTS, json!({"action": "test", "name": "Pill", "props": {"label": "x"}})),
    ] {
        let words = w(tool, args).unwrap();
        assert!(crate::cli::customize::parse(&words).is_ok(), "{words:?}");
    }
}
