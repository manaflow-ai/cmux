use super::*;

fn w(args: Value) -> Result<Vec<String>, String> {
    words(args.as_object().unwrap())
}

#[test]
fn library_tool_arguments_become_the_cli_words() {
    assert_eq!(w(json!({"action": "list"})).unwrap(), ["library", "list"]);
    assert_eq!(w(json!({"action": "on", "entry": "roomy"})).unwrap(), ["library", "on", "roomy"]);
    assert_eq!(
        w(json!({"action": "order", "entry": "roomy", "position": 2})).unwrap(),
        ["library", "order", "roomy", "2"]
    );
    assert_eq!(
        w(json!({"action": "order", "entry": "roomy", "position": "top"})).unwrap(),
        ["library", "order", "roomy", "top"]
    );
    assert_eq!(
        w(json!({"action": "export", "link": true, "on": true})).unwrap(),
        ["library", "export", "--link", "--on"]
    );
    assert_eq!(
        w(json!({"action": "import", "source": "cmux-collection:abc", "on": true})).unwrap(),
        ["library", "import", "cmux-collection:abc", "--on"]
    );
    for bad in [
        json!({}),
        json!({"action": "frob"}),
        json!({"action": "on"}),
        json!({"action": "on", "entry": "-x"}),
        json!({"action": "list", "entry": "x"}),
        json!({"action": "order", "entry": "x", "position": 0}),
        json!({"action": "import"}),
        json!({"action": "export", "link": "yes"}),
    ] {
        assert!(w(bad.clone()).is_err(), "{bad}");
    }
    assert_eq!(descriptor()["name"], NAME);
}
