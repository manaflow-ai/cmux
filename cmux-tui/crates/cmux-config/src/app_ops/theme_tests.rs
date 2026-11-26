use super::*;

fn ask(op: &str, request: Value) -> Value {
    call(op, &request).expect("a theme op").expect("answers")
}

#[test]
fn other_areas_ops_are_not_ours() {
    assert!(call("jsonc.parse", &json!({})).is_none());
}

#[test]
fn names_are_plain_file_names() {
    assert_eq!(ask("theme.valid_name", json!({"name": "tokyo night"})), json!({"valid": true}));
    for bad in ["", ".hidden", "a/b", "a:b", "tokyo.json", " padded", "tab\tname"] {
        assert_eq!(
            ask("theme.valid_name", json!({"name": bad})),
            json!({"valid": false}),
            "{bad:?}"
        );
    }
    let root = json!({"appearance": {"themeFile": "tokyo"}});
    assert_eq!(ask("theme.name", json!({"root": root})), json!({"name": "tokyo"}));
    assert_eq!(
        ask("theme.name", json!({"root": {"appearance": {"themeFile": "../x"}}})),
        json!({})
    );
}

#[test]
fn only_look_settings_are_looks() {
    assert_eq!(ask("theme.is_look", json!({"key": "appearance.accent"})), json!({"look": true}));
    assert_eq!(ask("theme.is_look", json!({"key": SETTING_KEY})), json!({"look": false}));
    assert_eq!(ask("theme.is_look", json!({"key": "terminal.term"})), json!({"look": false}));
    assert_eq!(ask("theme.is_look", json!({"key": "nope"})), json!({"look": false}));
}

#[test]
fn exceptions_keep_only_looks_that_take_one() {
    let root = json!({"appearance": {"themeFileExceptions": [
        "appearance.accent", "appearance", "appearance.themeEdits", "terminal.term", "appearance.accent", 3
    ]}});
    assert_eq!(
        ask("theme.exceptions", json!({"root": root})),
        json!({"keys": ["appearance.accent"]})
    );
    assert_eq!(ask("theme.exceptions", json!({"root": {}})), json!({"keys": []}));
}

#[test]
fn a_write_edits_the_exceptions_list() {
    let root = json!({"appearance": {"themeFileExceptions": ["appearance.borders"]}});
    let edit = |writes: Value, file_keys: Value| {
        ask("theme.exception_edit", json!({"writes": writes, "file_keys": file_keys, "root": root}))
    };
    // A set the file also sets adds its key; one it does not set adds none.
    assert_eq!(
        edit(json!([{"key": "appearance.accent", "sets": true}]), json!(["appearance.accent"])),
        json!({"change": true, "value": ["appearance.accent", "appearance.borders"]})
    );
    assert_eq!(
        edit(json!([{"key": "appearance.accent", "sets": true}]), json!([])),
        json!({"change": false})
    );
    // A reset removes it; the last one removes the list.
    assert_eq!(
        edit(json!([{"key": "appearance.borders", "sets": false}]), json!(["appearance.borders"])),
        json!({"change": true, "value": null})
    );
    // Choosing a theme file clears the list.
    assert_eq!(
        edit(json!([{"key": "appearance.themeFile", "sets": true}]), json!([])),
        json!({"change": true, "value": null})
    );
    // No active theme file: only resets count.
    let no_file = ask(
        "theme.exception_edit",
        json!({
            "writes": [{"key": "appearance.borders", "sets": false}, {"key": "appearance.accent", "sets": true}],
            "root": root,
        }),
    );
    assert_eq!(no_file, json!({"change": true, "value": null}));
    // The theme edits never take an exception.
    assert_eq!(
        edit(
            json!([{"key": "appearance.themeEdits", "sets": true}]),
            json!(["appearance.themeEdits"])
        ),
        json!({"change": false})
    );
}

#[test]
fn a_theme_file_is_read_as_a_look() {
    let reply = ask(
        "theme.read",
        json!({
            "name": "tokyo",
            "text": r#"{ "name": "Tokyo", "appearance": { "accent": "blue", "x": 1 }, "density": {"basedOn": "compact"}, "fonts": [] }"#,
        }),
    );
    assert_eq!(reply["loaded"], json!(true));
    assert_eq!(reply["values"], json!([{"path": ["appearance", "accent"], "value": "blue"}]));
    assert_eq!(reply["diagnostics"][0]["path"], json!("appearance.x"));
    assert_eq!(reply["diagnostics"][0]["kind"], json!("invalidValue"));
    assert_eq!(reply["diagnostics"][0]["file"], json!("themes/tokyo.json"));
    assert_eq!(reply["title"], json!("Tokyo"));
    assert_eq!(reply["density"], json!({"basedOn": "compact"}));
    assert_eq!(reply["fonts"], json!([]));
}

#[test]
fn a_missing_file_is_reported_at_the_setting() {
    let reply = ask("theme.read", json!({"name": "gone"}));
    assert_eq!(reply["loaded"], json!(false));
    assert_eq!(reply["unparsable"], json!(false));
    let first = &reply["diagnostics"][0];
    assert_eq!(first["path"], json!("appearance.themeFile"));
    assert_eq!(first["message"], json!("there is no file themes/gone.json"));
    assert!(first.get("file").is_none());
}

#[test]
fn an_unreadable_file_says_why_as_the_app_words_it() {
    let broken = ask("theme.read", json!({"name": "t", "text": "{\n  \"a\": 1,\n  x\n}"}));
    assert_eq!(broken["unparsable"], json!(true));
    assert_eq!(broken["diagnostics"][0]["kind"], json!("unreadableFile"));
    assert_eq!(
        broken["diagnostics"][0]["message"],
        json!("the text is not valid JSON at line 3, column 3")
    );
    let list = ask("theme.read", json!({"name": "t", "text": "[1]"}));
    assert_eq!(list["diagnostics"][0]["message"], json!("root is not an object"));
    let denied = ask("theme.read", json!({"name": "t", "error": "permission denied"}));
    assert_eq!(denied["diagnostics"][0]["message"], json!("permission denied"));
    assert_eq!(denied["unparsable"], json!(true));
}

#[test]
fn low_contrast_text_is_corrected() {
    let reply = ask(
        "theme.read",
        json!({
            "name": "t",
            "text": r##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#333333" } }"##,
        }),
    );
    assert_eq!(reply["corrected"], json!(["foreground"]));
    assert_eq!(reply["diagnostics"][0]["kind"], json!("correctedValue"));
}
