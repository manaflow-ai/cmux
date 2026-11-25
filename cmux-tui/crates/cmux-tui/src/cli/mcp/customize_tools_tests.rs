use super::*;

fn w(name: &str, args: Value) -> Result<Vec<String>, String> {
    let tool = TOOLS.iter().find(|tool| tool.name == name).unwrap();
    words(tool, args.as_object().unwrap())
}

#[test]
fn customize_tool_arguments_become_the_cli_words() {
    assert_eq!(
        w("customize_ask", json!({"wish": "--compact sidebar, please"})).unwrap(),
        ["brief", "--", "--compact sidebar, please"]
    );
    assert_eq!(w("customize_check", json!({})).unwrap(), ["check"]);
    assert_eq!(w("customize_recipes", json!({})).unwrap(), ["recipes"]);
    assert_eq!(w("customize_schema", json!({})).unwrap(), ["schema"]);
    assert_eq!(w("customize_schema", json!({"part": "views"})).unwrap(), ["schema", "views"]);
    assert_eq!(w("customize_apply", json!({"note": "compact"})).unwrap(), ["apply", "compact"]);
    assert_eq!(w("customize_apply", json!({})).unwrap(), ["apply"]);
    assert_eq!(w("customize_rollback", json!({})).unwrap(), ["rollback"]);
    assert_eq!(w("customize_rollback", json!({"generation": 3})).unwrap(), ["rollback", "3"]);
    assert_eq!(w("customize_show", json!({"generation": 2})).unwrap(), ["show", "2"]);
    assert_eq!(
        w("customize_save", json!({"name": "compact-night", "note": "small and dark"})).unwrap(),
        ["save", "compact-night", "small and dark"]
    );
    assert_eq!(
        w("customize_use", json!({"profile": "compact-night"})).unwrap(),
        ["use", "compact-night"]
    );
    for (name, bad) in [
        ("customize_ask", json!({})),
        ("customize_ask", json!({"wish": " "})),
        ("customize_show", json!({})),
        ("customize_show", json!({"generation": "2"})),
        ("customize_rollback", json!({"generation": 0})),
        ("customize_save", json!({"name": "--help"})),
        ("customize_use", json!({"profile": "-x"})),
        ("customize_status", json!({"extra": 1})),
        ("customize_schema", json!({"part": "--rust"})),
        ("customize_discard", json!({"note": "x"})),
    ] {
        assert!(w(name, bad.clone()).is_err(), "{name} {bad}");
    }
    let names: Vec<String> = descriptors()
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect();
    assert_eq!(
        w("customize_try", json!({"profile": "night", "minutes": 2})).unwrap(),
        ["try", "night", "--minutes", "2"]
    );
    assert_eq!(w("customize_try", json!({})).unwrap(), ["try"]);
    assert_eq!(w("customize_keep", json!({})).unwrap(), ["keep"]);
    assert_eq!(w("customize_revert", json!({})).unwrap(), ["revert"]);
    assert!(w("customize_try", json!({"minutes": 0})).is_err());
    assert!(w("customize_try", json!({"minutes": "5"})).is_err());
    assert!(w("customize_keep", json!({"minutes": 5})).is_err());
    assert_eq!(w("customize_doctor", json!({})).unwrap(), ["doctor"]);
    assert!(w("customize_doctor", json!({"id": "broken:settings.json"})).is_err());
    assert_eq!(names.len(), 18);
    assert!(names.iter().all(|name| name.starts_with("customize_")));
}
