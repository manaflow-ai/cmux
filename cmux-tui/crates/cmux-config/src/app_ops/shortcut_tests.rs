//! Pins Swift `ShortcutBindingFormat`'s behaviour (CmuxNextSettings
//! ShortcutBinding.swift before the move), case by case.

use serde_json::{Value, json};

use super::*;

fn stroke(key: &str, mods: &str) -> Stroke {
    Stroke {
        key: key.to_owned(),
        command: mods.contains('c'),
        shift: mods.contains('s'),
        option: mods.contains('o'),
        control: mods.contains('t'),
    }
}

fn fk(code: u32) -> String {
    char::from_u32(code).unwrap().to_string()
}

#[test]
fn unbind_forms() {
    for value in [
        Value::Null,
        json!(""),
        json!(" None "),
        json!("CLEAR"),
        json!("unbound"),
        json!("disabled"),
        json!([]),
        json!({"any": []}),
        json!({"first": {"key": ""}}),
    ] {
        assert_eq!(parse(&value), Some(Binding::Unbound), "{value}");
    }
}

#[test]
fn strokes_and_modifier_spellings() {
    assert_eq!(parse(&json!("cmd+shift+p")), Some(Binding::Stroke(stroke("p", "cs"))));
    assert_eq!(parse_stroke("⌘⇧+P"), None, "glyphs are separate tokens");
    assert_eq!(parse_stroke("⌘+⇧+P"), Some(stroke("p", "cs")));
    assert_eq!(parse_stroke("Command+Option+Control+x"), Some(stroke("x", "cot")));
    assert_eq!(parse_stroke("alt+ctl+x"), Some(stroke("x", "ot")));
    assert_eq!(parse_stroke(" cmd + k"), Some(stroke("k", "c")));
    assert_eq!(parse_stroke("+p"), Some(stroke("p", "")), "an empty modifier is skipped");
    assert_eq!(parse_stroke("hyper+p"), None);
    assert_eq!(parse_stroke("cmd+"), None);
    assert_eq!(parse_stroke("cmd++"), Some(stroke("+", "c")));
    assert_eq!(parse_stroke("cmd+ "), Some(stroke(" ", "c")), "a lone space is the space key");
    assert_eq!(parse_stroke("cmd+ab"), None);
}

#[test]
fn key_names() {
    assert_eq!(key_equivalent("Left").as_deref(), Some(fk(0xF702).as_str()));
    assert_eq!(key_equivalent("→").as_deref(), Some(fk(0xF703).as_str()));
    assert_eq!(key_equivalent("arrowup").as_deref(), Some(fk(0xF700).as_str()));
    assert_eq!(key_equivalent("downarrow").as_deref(), Some(fk(0xF701).as_str()));
    assert_eq!(key_equivalent("enter").as_deref(), Some("\r"));
    assert_eq!(key_equivalent("⎋").as_deref(), Some("\u{1B}"));
    assert_eq!(key_equivalent("backspace").as_deref(), Some("\u{8}"));
    assert_eq!(key_equivalent("<space>").as_deref(), Some(" "));
    assert_eq!(key_equivalent("equals").as_deref(), Some("="));
    assert_eq!(key_equivalent("plus").as_deref(), Some("="));
    assert_eq!(key_equivalent("closebracket").as_deref(), Some("]"));
    assert_eq!(key_equivalent("PageDown").as_deref(), Some(fk(0xF72D).as_str()));
    assert_eq!(key_equivalent("f1").as_deref(), Some(fk(0xF704).as_str()));
    assert_eq!(key_equivalent("F20").as_deref(), Some(fk(0xF717).as_str()));
    assert_eq!(key_equivalent("f21"), None);
    assert_eq!(key_equivalent("f0"), None);
    assert_eq!(key_equivalent("f").as_deref(), Some("f"));
    assert_eq!(key_equivalent("P").as_deref(), Some("p"));
    assert_eq!(key_equivalent("é").as_deref(), Some("é"));
    assert_eq!(key_equivalent("e\u{301}").as_deref(), Some("e\u{301}"), "one grapheme");
    assert_eq!(key_equivalent(""), None);
    assert_eq!(key_equivalent("  "), None);
}

#[test]
fn chords_arrays_and_objects() {
    assert_eq!(
        parse(&json!(["ctrl+b", "c"])),
        Some(Binding::Chord(stroke("b", "t"), stroke("c", "")))
    );
    assert_eq!(parse(&json!(["ctrl+b"])), Some(Binding::Stroke(stroke("b", "t"))));
    assert_eq!(parse(&json!(["a", "b", "c"])), None);
    assert_eq!(parse(&json!(["ctrl+b", 3])), None);
    assert_eq!(parse(&json!(["ctrl+b", "nope+x"])), None);
    assert_eq!(
        parse(&json!({"first": {"key": "P", "command": true, "shift": true}})),
        Some(Binding::Stroke(stroke("p", "cs")))
    );
    assert_eq!(
        parse(&json!({"first": {"key": "Left", "option": 1}})),
        Some(Binding::Stroke(stroke(&fk(0xF702), ""))),
        "a non-bool flag is off"
    );
    assert_eq!(
        parse(&json!({"first": {"key": "unknownkey"}})),
        Some(Binding::Stroke(stroke("unknownkey", ""))),
        "an unnamed key keeps its lowercase text"
    );
    assert_eq!(
        parse(&json!({"first": {"key": "b", "control": true}, "second": {"key": "c"}})),
        Some(Binding::Chord(stroke("b", "t"), stroke("c", "")))
    );
    assert_eq!(
        parse(&json!({"first": {"key": "b"}, "second": null})),
        Some(Binding::Stroke(stroke("b", "")))
    );
    assert_eq!(parse(&json!({"first": {"key": "b"}, "second": "c"})), None);
    assert_eq!(parse(&json!({"first": "b"})), None);
    assert_eq!(parse(&json!({})), None);
    assert_eq!(parse(&json!(true)), None);
    assert_eq!(parse(&json!(3)), None);
}

#[test]
fn alternates() {
    assert_eq!(
        parse(&json!({"any": ["ctrl+tab", "cmd+]", ["ctrl+b", "n"], "ctrl+tab"]})),
        Some(Binding::Alternates(vec![
            Binding::Stroke(stroke("\t", "t")),
            Binding::Stroke(stroke("]", "c")),
            Binding::Chord(stroke("b", "t"), stroke("n", "")),
        ]))
    );
    assert_eq!(parse(&json!({"any": ["cmd+k"]})), Some(Binding::Stroke(stroke("k", "c"))));
    assert_eq!(parse(&json!({"any": ["cmd+k", "cmd+k"]})), Some(Binding::Stroke(stroke("k", "c"))));
    assert_eq!(parse(&json!({"any": ["cmd+k", "none"]})), None, "an unbind token is no key");
    // A one-item list is that key, so it may be an item.
    assert_eq!(
        parse(&json!({"any": ["cmd+k", {"any": ["cmd+j"]}]})),
        Some(Binding::Alternates(vec![
            Binding::Stroke(stroke("k", "c")),
            Binding::Stroke(stroke("j", "c")),
        ]))
    );
    assert_eq!(parse(&json!({"any": ["cmd+k", {"any": ["cmd+j", "cmd+i"]}]})), None);
    assert_eq!(parse(&json!({"any": ["cmd+k"], "extra": 1})), None);
    assert_eq!(parse(&json!({"any": "cmd+k"})), None);
}

#[test]
fn config_strings_round_trip() {
    assert_eq!(config_string(&stroke("p", "csot")), "cmd+shift+opt+ctrl+p");
    assert_eq!(config_string(&stroke("+", "c")), "cmd+plus");
    assert_eq!(config_string(&stroke(&fk(0xF702), "")), "left");
    assert_eq!(config_string(&stroke(&fk(0xF704 + 11), "")), "f12");
    // `plus` names the = key (as `equals` does); the + key itself writes `plus`.
    assert_eq!(config_string(&parse_stroke("cmd+plus").unwrap()), "cmd+=");
    assert_eq!(config_token("\u{7F}"), "delete");
    assert_eq!(config_token("\u{8}"), "delete");
    assert_eq!(config_token(" "), "space");
    assert_eq!(config_token(&fk(0xF72C)), "pageup");
    assert_eq!(config_token("x"), "x");
    for text in ["cmd+shift+p", "ctrl+tab", "opt+left", "cmd+f5", "ctrl+space", "cmd+]"] {
        let parsed = parse_stroke(text).unwrap();
        assert_eq!(config_string(&parsed), text);
        assert_eq!(parse_stroke(&config_string(&parsed)), Some(parsed));
    }
    let value = json!({"any": ["ctrl+tab", ["ctrl+b", "n"]]});
    assert_eq!(config_value(&parse(&value).unwrap()), value);
    assert_eq!(config_value(&Binding::Unbound), Value::Null);
}

#[test]
fn ops_answer_the_wire_shapes() {
    let reply = call("shortcut.parse", &json!({"value": ["ctrl+b", "c"]})).unwrap().unwrap();
    let binding = &reply["binding"];
    assert_eq!(binding["chord"][0]["key"], "b");
    assert_eq!(binding["chord"][0]["control"], true);
    assert_eq!(binding_from_json(binding), parse(&json!(["ctrl+b", "c"])));
    let reply = call("shortcut.parse", &json!({"value": 3})).unwrap().unwrap();
    assert_eq!(reply, json!({"binding": null}));
    let reply = call("shortcut.parse", &json!({})).unwrap().unwrap();
    assert_eq!(reply, json!({"binding": {"unbound": true}}), "a missing value is null");
    let reply =
        call("shortcut.parse_many", &json!({"values": ["cmd+k", 3, null]})).unwrap().unwrap();
    assert_eq!(reply["bindings"][1], Value::Null);
    assert_eq!(reply["bindings"][2], json!({"unbound": true}));
    let any = parse(&json!({"any": ["cmd+k", "cmd+j"]})).unwrap();
    let reply =
        call("shortcut.config_value", &json!({"binding": binding_json(&any)})).unwrap().unwrap();
    assert_eq!(reply, json!({"value": {"any": ["cmd+k", "cmd+j"]}}));
    let reply = call("shortcut.parse_stroke", &json!({"text": "cmd+k"})).unwrap().unwrap();
    assert_eq!(reply["stroke"]["command"], true);
    let reply = call("shortcut.config_string", &json!({"stroke": {"key": "k", "command": true}}))
        .unwrap()
        .unwrap();
    assert_eq!(reply, json!({"text": "cmd+k"}));
    let reply = call("shortcut.key_equivalent", &json!({"token": "nope"})).unwrap().unwrap();
    assert_eq!(reply, json!({"key": null}));
    let reply = call("shortcut.config_token", &json!({"key": "\t"})).unwrap().unwrap();
    assert_eq!(reply, json!({"token": "tab"}));
    assert!(call("shortcut.config_value", &json!({"binding": 1})).unwrap().is_err());
    assert!(call("shortcut.nope", &json!({})).is_none());
    assert_eq!(
        crate::app_ops::call("shortcut.config_token", &json!({"key": " "})),
        Ok(json!({"token": "space"}))
    );
}
