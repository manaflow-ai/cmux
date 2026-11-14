use super::*;
use crate::tree::SETTINGS;

fn check(path: &str, text: &str) -> Vec<String> {
    let files = BTreeMap::from([(path.to_owned(), text.as_bytes().to_vec())]);
    problems(&files).iter().map(Problem::line).collect()
}

#[test]
fn a_json_mistake_names_its_line_and_column() {
    let lines = check("themes/night.json", "{\n  \"name\": \"night\",\n  \"look\": }\n}\n");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("themes/night.json:3:"), "{lines:?}");
}

#[test]
fn a_shortcuts_file_is_an_array_and_only_an_unreadable_one_is_a_problem() {
    let valid = "// mine\n[\n  { \"key\": \"cmd+k\", \"command\": \"palette.open\" },\n]\n";
    assert_eq!(check("keybindings.json", valid), Vec::<String>::new());
    assert_eq!(check("keybindings.json", ""), Vec::<String>::new());
    assert_eq!(check("keybindings.json", "// nothing yet\n"), Vec::<String>::new());
    // One entry the app skips does not stop an apply of something else.
    assert_eq!(check("keybindings.json", "[ { \"key\": \"cmd+k\" } ]"), Vec::<String>::new());
    let object = check("keybindings.json", "{ \"cmd+k\": \"palette.open\" }");
    assert_eq!(object.len(), 1, "{object:?}");
    assert!(object[0].contains("must be a JSON array of bindings"), "{object:?}");
    let broken = check("keybindings.json", "[\n  { \"key\": }\n]\n");
    assert_eq!(broken.len(), 1, "{broken:?}");
    assert!(broken[0].starts_with("keybindings.json:2:"), "{broken:?}");
}

#[test]
fn a_settings_value_the_schema_refuses_names_its_key_line() {
    let lines = check(SETTINGS, "{\n  // mine\n  \"appearance\": {\n    \"density\": 42\n  }\n}\n");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("settings.json:4:5: "), "{lines:?}");
}

#[test]
fn a_problem_never_quotes_the_value_it_refuses() {
    let lines = check(
        SETTINGS,
        "{\n  \"appearance\": { \"density\": { \"apiKey\": \"private-value\" } },\n  \"updates\": { \"channel\": \"my-private-ring\" }\n}\n",
    );
    assert_eq!(lines.len(), 2, "{lines:?}");
    let said = lines.join("\n");
    assert!(!said.contains("private"), "{said}");
    assert!(said.contains("appearance.density has a value this setting does not accept"), "{said}");
    assert!(said.contains("settings.json:3:"), "{said}");
}

#[test]
fn valid_files_have_no_problems() {
    assert_eq!(check(SETTINGS, ""), Vec::<String>::new());
    assert_eq!(
        check(SETTINGS, "{ /* c */ \"appearance\": { \"density\": \"compact\" }, }"),
        Vec::<String>::new()
    );
    assert_eq!(check("agent-pane/theme.css", ":root { --agent-gap: 4px }"), Vec::<String>::new());
}

#[test]
fn a_hidden_direction_mark_is_refused_with_its_position() {
    let lines = check("customize/main.js", "let a = 1;\nlet b = \"\u{202E}x\";\n");
    assert_eq!(lines.len(), 1);
    assert!(lines[0].starts_with("customize/main.js:2:10: "), "{lines:?}");
    assert!(lines[0].contains("U+202E"));
}

#[test]
fn the_views_manifest_must_name_a_script_that_is_there() {
    let manifest = r#"{
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": { "cmux.section/1": { "export": "renderSection", "title": "Mine", "symbol": "sparkles" } },
  "description": "My own views"
}"#;
    let lines = check("customize/cmux-app.json", manifest);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("customize/cmux-app.json:7:16: runtime.main"), "{lines:?}");
    let files = BTreeMap::from([
        ("customize/cmux-app.json".to_owned(), manifest.as_bytes().to_vec()),
        ("customize/main.js".to_owned(), b"export function renderSection() {}".to_vec()),
    ]);
    assert_eq!(problems(&files), Vec::new());
}
