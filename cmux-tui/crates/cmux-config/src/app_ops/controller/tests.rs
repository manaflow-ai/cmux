//! Ports `SettingsDiagnosticNoticesTests` and pins the Swift
//! `SettingsController` edit, load and theme file note semantics case by case.

use serde_json::{Value, json};

use crate::app_ops::{OpError, call};

fn ask(op: &str, request: Value) -> Value {
    call(op, &request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

const BACKGROUND_MESSAGE: &str = "expected none, daily, desktop, bundled art, folder:<absolute path>, or an absolute system wallpaper or image path";

fn background() -> Value {
    json!({"kind": "invalidValue", "path": "appearance.background", "message": BACKGROUND_MESSAGE})
}

fn accent() -> Value {
    json!({"kind": "invalidValue", "path": "appearance.accent", "message": "expected one of blue, red"})
}

fn unreadable(message: &str) -> Value {
    json!({"kind": "unreadableFile", "path": "", "message": message})
}

fn file(background: Value, accent: Option<Value>) -> Value {
    let mut appearance = json!({ "background": background });
    if let Some(accent) = accent {
        appearance["accent"] = accent;
    }
    json!({ "appearance": appearance })
}

/// The app's `SettingsDiagnosticNotices` state, kept in the app between ops.
#[derive(Default)]
struct Notices {
    remembered: Value,
    shown: Option<Value>,
}

impl Notices {
    fn request(&self) -> Value {
        let mut request = json!({ "remembered": if self.remembered.is_null() { json!([]) } else { self.remembered.clone() } });
        if let Some(shown) = &self.shown {
            request["shown"] = shown.clone();
        }
        request
    }

    fn adopt(&mut self, answer: &Value) {
        self.remembered = answer["remembered"].clone();
        self.shown = answer.get("shown").cloned();
    }

    fn update(&mut self, diagnostics: Vec<Value>, file: Value, managed: &[&str]) -> Value {
        let mut request = self.request();
        request["diagnostics"] = json!(diagnostics);
        request["file"] = file;
        request["managed"] = json!(managed);
        let answer = ask("notices.update", request);
        self.adopt(&answer);
        answer
    }

    fn announced(&mut self, notices: &Value) {
        let mut request = self.request();
        request["notices"] = notices.clone();
        let answer = ask("notices.announced", request);
        self.adopt(&answer);
    }

    /// One load whose pending notices a toast then showed.
    fn load(&mut self, diagnostics: Vec<Value>, file: Value) -> Value {
        self.load_managed(diagnostics, file, &[])
    }

    fn load_managed(&mut self, diagnostics: Vec<Value>, file: Value, managed: &[&str]) -> Value {
        let update = self.update(diagnostics, file, managed);
        self.announced(&update["announce"]);
        update
    }
}

fn members(update: &Value, key: &str) -> Vec<Value> {
    update["announce"]
        .as_array()
        .unwrap()
        .iter()
        .map(|notice| notice.get(key).cloned().unwrap_or(Value::Null))
        .collect()
}

#[test]
fn a_refused_value_is_announced_with_its_key_value_and_reason() {
    let mut notices = Notices::default();
    let update = notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    assert_eq!(members(&update, "path"), vec![json!("appearance.background")]);
    assert_eq!(members(&update, "value"), vec![json!("\"folder:~/Pictures\"")]);
    assert_eq!(members(&update, "message"), vec![json!(BACKGROUND_MESSAGE)]);
    assert_eq!(update["cleared"], json!(false));
}

#[test]
fn the_same_refusal_is_not_announced_again_on_reload() {
    let mut notices = Notices::default();
    notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    let again = notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    assert_eq!(again["announce"], json!([]));
    assert_eq!(again["cleared"], json!(false));
}

#[test]
fn a_refusal_announced_at_an_earlier_launch_stays_quiet() {
    let mut first = Notices::default();
    first.load(vec![background()], file(json!("folder:~/Pictures"), None));
    let mut relaunched = Notices { remembered: first.remembered.clone(), shown: None };
    let update = relaunched.load(vec![background()], file(json!("folder:~/Pictures"), None));
    assert_eq!(update["announce"], json!([]));
}

#[test]
fn the_remembered_fingerprint_holds_no_raw_value() {
    let mut notices = Notices::default();
    notices.load(vec![background()], file(json!("folder:/Users/someone/Secret Photos"), None));
    let remembered = notices.remembered.as_array().unwrap();
    assert_eq!(remembered.len(), 1);
    assert!(!remembered[0].as_str().unwrap().contains("Secret Photos"));
}

#[test]
fn a_refusal_no_toast_showed_stays_pending() {
    let mut notices = Notices::default();
    // No window: the app does not call `notices.announced`.
    for _ in 0..2 {
        let update =
            notices.update(vec![background()], file(json!("folder:~/Pictures"), None), &[]);
        assert_eq!(update["announce"].as_array().unwrap().len(), 1);
    }
}

#[test]
fn another_bad_value_at_the_same_key_is_announced() {
    let mut notices = Notices::default();
    notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    let changed = notices.load(vec![background()], file(json!(42), None));
    assert_eq!(members(&changed, "value"), vec![json!("42")]);
}

#[test]
fn a_fix_clears_the_notice_and_a_new_break_announces_again() {
    let mut notices = Notices::default();
    notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    let fixed = notices.load(vec![], file(json!("daily"), None));
    assert_eq!(fixed["announce"], json!([]));
    assert_eq!(fixed["cleared"], json!(true));
    let quiet = notices.load(vec![], file(json!("daily"), None));
    assert_eq!(quiet["cleared"], json!(false));
    let broken = notices.load(vec![background()], file(json!("folder:~/Pictures"), None));
    assert_eq!(broken["announce"].as_array().unwrap().len(), 1);
}

#[test]
fn fixing_the_shown_refusal_clears_it_while_another_stays() {
    let mut notices = Notices::default();
    let first = notices
        .load(vec![background(), accent()], file(json!("folder:~/Pictures"), Some(json!("teal"))));
    assert_eq!(first["announce"][0]["path"], json!("appearance.background"));
    let partial = notices.load(vec![accent()], file(json!("daily"), Some(json!("teal"))));
    assert_eq!(partial["cleared"], json!(true));
    assert_eq!(partial["announce"], json!([]));
}

#[test]
fn managed_keys_and_shortcut_conflicts_are_not_announced() {
    let mut notices = Notices::default();
    let update = notices.load(
        vec![
            json!({"kind": "managedOverride", "path": "updates.channel", "message": "managed by MDM"}),
            json!({"kind": "managedConflict", "path": "updates.channel", "message": "MDM wins"}),
            json!({"kind": "shortcutConflict", "path": "shortcuts.bindings.newTab", "message": "also used by newWindow"}),
        ],
        json!({}),
    );
    assert_eq!(update["announce"], json!([]));
}

#[test]
fn bad_values_a_managed_layer_sets_are_not_announced() {
    let mut notices = Notices::default();
    let update = notices.load_managed(
        vec![
            json!({"kind": "invalidValue", "path": "updates.channel", "message": "expected one of stable, nightly"}),
            json!({"kind": "invalidValue", "path": "DisabledFeatures", "message": "DisabledFeatures must be an array of feature names"}),
            background(),
        ],
        file(json!("folder:~/Pictures"), None),
        &["updates.channel", "DisabledFeatures"],
    );
    assert_eq!(members(&update, "path"), vec![json!("appearance.background")]);
}

#[test]
fn a_managed_parent_or_child_hides_the_notice() {
    let mut notices = Notices::default();
    let inside = json!({"kind": "invalidValue", "path": "updates.channel.beta", "message": "bad"});
    let holding = json!({"kind": "invalidValue", "path": "terminal", "message": "bad"});
    let beside = json!({"kind": "invalidValue", "path": "updates.channelX", "message": "bad"});
    let update = notices.update(
        vec![inside, holding, beside],
        json!({}),
        &["updates.channel", "terminal.font"],
    );
    assert_eq!(members(&update, "path"), vec![json!("updates.channelX")]);
}

#[test]
fn an_unreadable_file_is_announced_without_a_value() {
    let mut notices = Notices::default();
    let update = notices.load(vec![unreadable("unexpected character at line 3")], json!({}));
    assert_eq!(members(&update, "path"), vec![json!("")]);
    assert_eq!(members(&update, "value"), vec![Value::Null]);
}

#[test]
fn an_unreadable_file_is_announced_once_wherever_the_error_moves() {
    let mut notices = Notices::default();
    notices.load(vec![unreadable("unexpected character at line 3")], json!({}));
    let moved = notices.load(vec![unreadable("unexpected character at line 4")], json!({}));
    assert_eq!(moved["announce"], json!([]));
}

#[test]
fn a_theme_files_refusal_carries_its_own_value_and_file() {
    let mut notices = Notices::default();
    let diagnostic = json!({"kind": "invalidValue", "path": "appearance.accent", "message": "expected one of blue, red",
                            "file": "themes/tokyo.json", "value": "\"teal\""});
    let update = notices.update(
        vec![diagnostic.clone(), diagnostic],
        file(json!("daily"), Some(json!("blue"))),
        &[],
    );
    assert_eq!(
        update["announce"].as_array().unwrap().len(),
        1,
        "a repeat in one load is one notice"
    );
    assert_eq!(update["announce"][0]["value"], json!("\"teal\""));
    assert_eq!(update["announce"][0]["file"], json!("themes/tokyo.json"));
}

#[test]
fn only_dropped_value_kinds_announce() {
    for kind in [
        "unreadableFile",
        "invalidValue",
        "unknownAction",
        "unknownMetric",
        "unsupportedChord",
        "removedSetting",
    ] {
        assert_eq!(
            ask("notices.announces", json!({ "kind": kind })),
            json!({"announces": true}),
            "{kind}"
        );
    }
    for kind in [
        "shortcutConflict",
        "managedOverride",
        "managedConflict",
        "correctedValue",
        "setByThemeFile",
        "overThemeFile",
        "plainBackgrounds",
    ] {
        assert_eq!(
            ask("notices.announces", json!({ "kind": kind })),
            json!({"announces": false}),
            "{kind}"
        );
    }
}

#[test]
fn the_fingerprint_is_swifts() {
    // Swift: [file, path, hex(SHA256(value).prefix(12)), message].compacted.joined("\0").
    let print = ask("notices.fingerprint", json!({"path": "a.b", "value": "1", "message": "m"}));
    assert_eq!(print, json!({"fingerprint": "a.b\u{0}6b86b273ff34fce19d6b804e\u{0}m"}));
    let none =
        ask("notices.fingerprint", json!({"path": "a.b", "message": "m", "file": "themes/x.json"}));
    assert_eq!(none, json!({"fingerprint": "themes/x.json\u{0}a.b\u{0}\u{0}m"}));
    let unreadable = ask(
        "notices.fingerprint",
        json!({"kind": "unreadableFile", "path": "", "message": "line 3"}),
    );
    assert_eq!(unreadable, json!({"fingerprint": "unreadableFile"}));
}

// MARK: Load

#[test]
fn a_load_reads_an_object_and_keeps_last_good_otherwise() {
    let last_good = json!({"a": 1});
    assert_eq!(
        ask("controller.load_root", json!({"source": "// c\n{\"b\": 2,}", "last_good": last_good})),
        json!({"root": {"b": 2}})
    );
    assert_eq!(
        ask("controller.load_root", json!({"source": "", "last_good": last_good})),
        json!({"root": {}})
    );
    assert_eq!(
        ask("controller.load_root", json!({"source": "[1]", "last_good": last_good})),
        json!({"root": {"a": 1}, "problem": "root is not an object"})
    );
    let broken =
        ask("controller.load_root", json!({"source": "{\"b\": }", "last_good": last_good}));
    assert_eq!(broken["root"], last_good);
    let problem = ask("jsonc.parse", json!({"source": "{\"b\": }"}))["problem"].clone();
    assert_eq!(broken["problem"], problem);
    assert_eq!(
        ask("controller.load_root", json!({"error": "permission denied", "last_good": last_good})),
        json!({"root": {"a": 1}, "problem": "permission denied"})
    );
    assert_eq!(ask("controller.load_root", json!({"last_good": last_good})), json!({"root": {}}));
}

// MARK: Edits

#[test]
fn replacing_sets_removes_and_makes_the_objects_along_the_way() {
    assert_eq!(
        ask("controller.replace", json!({"root": {"a": {"b": 1}}, "path": ["a", "c"], "value": 2})),
        json!({"root": {"a": {"b": 1, "c": 2}}})
    );
    assert_eq!(
        ask("controller.replace", json!({"root": {"a": {"b": 1}}, "path": ["a", "b"]})),
        json!({"root": {"a": {}}})
    );
    // A removal still makes the objects on its path, as Swift's `replacing` does.
    assert_eq!(
        ask("controller.replace", json!({"root": {}, "path": ["x", "y"]})),
        json!({"root": {"x": {}}})
    );
    // A non-object in the way is replaced.
    assert_eq!(
        ask("controller.replace", json!({"root": {"a": 3}, "path": ["a", "b"], "value": true})),
        json!({"root": {"a": {"b": true}}})
    );
    assert_eq!(
        ask("controller.replace", json!({"root": {"a": 1}, "path": [], "value": 5})),
        json!({"root": 5})
    );
    assert_eq!(
        ask("controller.replace", json!({"root": {"a": 1}, "path": []})),
        json!({"root": null})
    );
}

#[test]
fn remove_pruned_resets_then_drops_each_emptied_parent() {
    assert_eq!(
        ask("controller.remove_pruned", json!({"path": ["a", "b", "c"]})),
        json!({"edits": [
            {"op": "reset", "path": ["a", "b", "c"]},
            {"op": "reset_unchanged", "path": ["a", "b"], "value": {}},
            {"op": "reset_unchanged", "path": ["a"], "value": {}},
        ]})
    );
    assert_eq!(
        ask("controller.remove_pruned", json!({"path": ["a"]})),
        json!({"edits": [{"op": "reset", "path": ["a"]}]})
    );
    assert_eq!(
        ask("controller.remove_pruned", json!({"path": []})),
        json!({"edits": [{"op": "reset", "path": []}]})
    );
}

#[test]
fn apply_edits_follows_each_edit_kind() {
    let root = json!({"a": {"b": 1, "c": {}}, "n": 2});
    let apply = |edits: Value| {
        ask("controller.apply_edits", json!({"root": root, "edits": edits}))["root"].clone()
    };
    assert_eq!(
        apply(json!([{"op": "set_exact", "path": ["a", "b"], "value": 5}])),
        json!({"a": {"b": 5, "c": {}}, "n": 2})
    );
    assert_eq!(apply(json!([{"op": "set", "path": ["z"], "value": true}]))["z"], json!(true));
    // set_unset writes only where nothing is.
    assert_eq!(apply(json!([{"op": "set_unset", "path": ["a", "b"], "value": 5}])), root);
    assert_eq!(
        apply(json!([{"op": "set_unset", "path": ["a", "d"], "value": 5}]))["a"]["d"],
        json!(5)
    );
    // reset removes a present key and leaves the document alone otherwise (no objects made).
    assert_eq!(
        apply(json!([{"op": "reset", "path": ["a", "b"]}])),
        json!({"a": {"c": {}}, "n": 2})
    );
    assert_eq!(apply(json!([{"op": "reset", "path": ["q", "r"]}])), root);
    // reset_unchanged removes only an equal value; numbers compare as doubles.
    assert_eq!(
        apply(json!([{"op": "reset_unchanged", "path": ["n"], "value": 2.0}])),
        json!({"a": {"b": 1, "c": {}}})
    );
    assert_eq!(apply(json!([{"op": "reset_unchanged", "path": ["n"], "value": 3}])), root);
    assert_eq!(
        apply(json!([{"op": "reset_unchanged", "path": ["a", "c"], "value": {}}])),
        json!({"a": {"b": 1}, "n": 2})
    );
    // An emptied parent stays in place.
    assert_eq!(
        apply(json!([{"op": "reset", "path": ["a", "b"]}, {"op": "reset", "path": ["a", "c"]}])),
        json!({"a": {}, "n": 2})
    );
    let unknown = call(
        "controller.apply_edits",
        &json!({"root": root, "edits": [{"op": "move", "path": ["a"]}]}),
    );
    assert!(matches!(unknown, Err(OpError::Invalid(_))));
}

#[test]
fn removing_pruned_through_apply_edits_drops_the_emptied_objects() {
    let root = json!({"a": {"b": {"c": 1}}, "keep": {"d": {"c": 1}, "e": 2}});
    for (path, after) in [
        (json!(["a", "b", "c"]), json!({"keep": {"d": {"c": 1}, "e": 2}})),
        (json!(["keep", "d", "c"]), json!({"a": {"b": {"c": 1}}, "keep": {"e": 2}})),
    ] {
        let edits = ask("controller.remove_pruned", json!({ "path": path }))["edits"].clone();
        assert_eq!(
            ask("controller.apply_edits", json!({"root": root, "edits": edits}))["root"],
            after
        );
    }
}

// MARK: Theme file notes

#[test]
fn a_name_that_is_no_theme_file_name_is_refused() {
    let notes = ask(
        "controller.theme_file_notes",
        json!({"root": {"appearance": {"themeFile": "a/b"}}, "file_keys": []}),
    );
    assert_eq!(
        notes,
        json!({"diagnostics": [{
            "kind": "invalidValue",
            "path": "appearance.themeFile",
            "message": "expected a theme file name, such as \"tokyo\" for themes/tokyo.json",
        }]})
    );
    assert_eq!(
        ask("controller.theme_file_notes", json!({"root": {}, "file_keys": []})),
        json!({"diagnostics": []})
    );
}

#[test]
fn each_key_the_file_sets_says_where_its_value_comes_from() {
    let root =
        json!({"appearance": {"themeFile": "tokyo", "themeFileExceptions": ["appearance.accent"]}});
    let notes = ask(
        "controller.theme_file_notes",
        json!({
            "root": root,
            "file_keys": ["appearance.accent", "terminal.fontSize", "updates.channel.x", "appearance.density"],
            "density": true,
            "managed": ["updates.channel"],
        }),
    );
    let set = "set by the theme file; a change here applies over it";
    let over = "your value applies over the theme file's; Reset returns to the file's";
    assert_eq!(
        notes,
        json!({"diagnostics": [
            {"kind": "overThemeFile", "path": "appearance.accent", "message": over, "file": "themes/tokyo.json"},
            {"kind": "setByThemeFile", "path": "terminal.fontSize", "message": set, "file": "themes/tokyo.json"},
            {"kind": "setByThemeFile", "path": "appearance.density", "message": set, "file": "themes/tokyo.json"},
            // The file's own density is over the custom density row too.
            {"kind": "setByThemeFile", "path": "appearance.customDensity", "message": set, "file": "themes/tokyo.json"},
        ]})
    );
    let no_density = ask(
        "controller.theme_file_notes",
        json!({"root": root, "file_keys": ["terminal.fontSize"]}),
    );
    assert_eq!(no_density["diagnostics"].as_array().unwrap().len(), 1);
}

// MARK: Window background

#[test]
fn see_through_asks_follow_opacity_and_material() {
    let ask_see = |path: Value, value: Value| {
        ask("controller.see_through", json!({"path": path, "value": value}))["see_through"].clone()
    };
    assert_eq!(ask_see(json!(["appearance", "backgroundOpacity"]), json!(0.5)), json!(true));
    assert_eq!(ask_see(json!(["appearance", "backgroundOpacity"]), json!(1)), json!(false));
    assert_eq!(ask_see(json!(["appearance", "backgroundOpacity"]), json!("x")), json!(false));
    assert_eq!(ask_see(json!(["appearance", "backgroundBlur"]), json!("regular")), json!(true));
    assert_eq!(ask_see(json!(["appearance", "backgroundBlur"]), json!("none")), json!(false));
    assert_eq!(ask_see(json!(["appearance", "backgroundBlur"]), json!(3)), json!(false));
    assert_eq!(ask_see(json!(["appearance", "accent"]), json!(0.1)), json!(false));
}
