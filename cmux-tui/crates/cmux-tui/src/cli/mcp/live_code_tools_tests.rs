use super::*;

fn words_of(name: &str, value: Value) -> Option<Result<Vec<String>, String>> {
    words(name, &value.as_object().cloned().unwrap_or_default())
}

fn ok(list: &[&str]) -> Option<Result<Vec<String>, String>> {
    Some(Ok(list.iter().map(|word| (*word).to_owned()).collect()))
}

#[test]
fn each_tool_is_the_clis_live_code_verb() {
    assert_eq!(words_of(STATUS, json!({})), ok(&["live-code", "status"]));
    assert_eq!(
        words_of(APPLY, json!({"patch": "/tmp/p.dylib", "timeout_seconds": 600})),
        ok(&["live-code", "apply", "/tmp/p.dylib", "--timeout", "600"])
    );
    assert_eq!(
        words_of(UNDO, json!({"all": true, "dir": "/tmp/live"})),
        ok(&["live-code", "undo", "--all", "--dir", "/tmp/live"])
    );
    assert_eq!(words_of(LOG, json!({"lines": 5})), ok(&["live-code", "log", "-n", "5"]));
}

#[test]
fn bad_arguments_are_refused_and_other_tools_are_not_ours() {
    assert!(matches!(words_of(APPLY, json!({})), Some(Err(_))));
    assert!(matches!(words_of(UNDO, json!({"patch": "x"})), Some(Err(_))));
    // A wrong type or range is refused, not read as absent.
    for bad in [
        json!({"all": "true"}),
        json!({"timeout_seconds": 9999}),
        json!({"timeout_seconds": "5"}),
        json!({"dir": 3}),
        json!({"dir": ""}),
    ] {
        assert!(matches!(words_of(UNDO, bad.clone()), Some(Err(_))), "{bad}");
    }
    assert!(matches!(words_of(LOG, json!({"lines": 0})), Some(Err(_))));
    assert!(matches!(words_of(APPLY, json!({"patch": 1})), Some(Err(_))));
    assert_eq!(words_of("chat_send", json!({})), None);
    let names: Vec<String> = descriptors()
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect();
    assert_eq!(names, [STATUS, APPLY, UNDO, LOG]);
}
