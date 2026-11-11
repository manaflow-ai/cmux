//! The Rust catalog is the Swift catalog it replaces, field for field.
//!
//! - `plans/cmux-next/action-catalog.json` is every field of every Swift descriptor as the app
//!   resolved it (`ActionCatalogDumpTests`, run on a fleet Mac), plus the key binding defaults,
//!   palette tables, categories and menu folders. The English catalog JSON must equal it.
//! - `plans/cmux-next/action-surfaces.json` is what `action.list`, the CLI and the docs read:
//!   each action's CLI name, surfaces, menu, title and its key, shortcut, chord, palette
//!   suggestion rank and arguments must match.
//! - Every translation must equal the app's string catalogs (`CmuxNextActions/*.xcstrings`),
//!   in every language.
//!
//! The app reads this crate since step B, so the export is written from it; the string
//! catalogs still hold the same translations until the Swift string tables are trimmed.

use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read_json(path: &Path) -> Value {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The first difference between two values, as a path and both sides.
fn first_difference(path: &str, a: &Value, b: &Value) -> Option<String> {
    match (a, b) {
        (Value::Object(x), Value::Object(y)) => {
            for key in x.keys().chain(y.keys()) {
                let (l, r) =
                    (x.get(key).unwrap_or(&Value::Null), y.get(key).unwrap_or(&Value::Null));
                if x.contains_key(key) != y.contains_key(key) {
                    return Some(format!(
                        "{path}.{key}: present on one side only (rust {l}, swift {r})"
                    ));
                }
                if let Some(d) = first_difference(&format!("{path}.{key}"), l, r) {
                    return Some(d);
                }
            }
            None
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return Some(format!("{path}: {} items in rust, {} in swift", x.len(), y.len()));
            }
            x.iter().zip(y).enumerate().find_map(|(i, (l, r))| {
                let label = l
                    .get("id")
                    .and_then(Value::as_str)
                    .map_or_else(|| i.to_string(), str::to_owned);
                first_difference(&format!("{path}[{label}]"), l, r)
            })
        }
        _ => (a != b).then(|| format!("{path}: rust {a}, swift {b}")),
    }
}

#[test]
fn english_catalog_equals_the_swift_dump() {
    let mut swift = read_json(&repo().join("plans/cmux-next/action-catalog.json"));
    // The Swift dump reflects each binding's parsed `when` clause too; the catalog keeps its text.
    if let Some(defaults) = swift.get_mut("key_binding_defaults").and_then(Value::as_object_mut) {
        for list in defaults.values_mut() {
            for entry in list.as_array_mut().into_iter().flatten() {
                if let Some(entry) = entry.as_object_mut() {
                    entry.remove("when");
                }
            }
        }
    }
    // Swift's `ActionEnumCase` also has `subtitle` and `symbol`: run-time list data (a team
    // row's kind and plan, from the cloud team rows) that the app's decoder never reads from
    // the catalog. The dump reflects them as null; only a null is dropped, so a case that
    // carries one still differs.
    let arguments = swift
        .get_mut("actions")
        .and_then(Value::as_array_mut)
        .into_iter()
        .flatten()
        .filter_map(|action| action.get_mut("arguments").and_then(Value::as_array_mut))
        .flatten()
        .filter_map(Value::as_object_mut);
    for argument in arguments {
        for (key, value) in argument.iter_mut() {
            let cases = match key.as_str() {
                "kind" => value.get_mut("enumeration"),
                "suggestions" => value.get_mut("pinned"),
                _ => None,
            };
            for case in cases.and_then(Value::as_array_mut).into_iter().flatten() {
                if let Some(case) = case.as_object_mut() {
                    for field in ["subtitle", "symbol"] {
                        if case.get(field).is_some_and(Value::is_null) {
                            case.remove(field);
                        }
                    }
                }
            }
        }
    }
    // A set in Swift: compare it in one order.
    let sort = |v: &mut Value| {
        if let Some(keys) = v["key_binding_defaults"]["text_input_keys"].as_array_mut() {
            keys.sort_by_key(|k| {
                (k["key"].as_str().unwrap_or("").to_owned(), k["modifiers"].to_string())
            });
        }
    };
    sort(&mut swift);
    let mut rust = cmux_action_catalog::json::catalog_value(0);
    sort(&mut rust);
    let object = rust.as_object_mut().expect("an object");
    object.remove("locale");
    // The dump is a Debug build's, which has every Debug-only entry; the list of them is new.
    object.remove("debug_build_only");
    if let Some(difference) = first_difference("$", &rust, &swift) {
        panic!("the Rust catalog differs from the Swift dump: {difference}");
    }
}

#[test]
fn action_list_export_matches() {
    let export = read_json(&repo().join("plans/cmux-next/action-surfaces.json"));
    let rows = export["actions"].as_array().expect("actions");
    let rust: Vec<_> = cmux_action_catalog::actions().collect();
    assert_eq!(rows.len(), rust.len(), "action count");
    for (row, action) in rows.iter().zip(&rust) {
        let id = action.id;
        assert_eq!(row["id"], id);
        assert_eq!(row["cli_name"], action.cli_name, "{id}");
        assert_eq!(row["palette"], action.surface_plan.palette.wire(), "{id}");
        assert_eq!(row["cli"], action.surface_plan.cli.map_or("undeclared", |d| d.wire()), "{id}");
        assert_eq!(
            row["context_menu"],
            action.surface_plan.context_menu().map_or("undeclared", |d| d.wire()),
            "{id}"
        );
        assert_eq!(
            row["mcp"],
            action.surface_plan.mcp().map_or("undeclared", |d| d.wire()),
            "{id}"
        );
        assert_eq!(row["main_menu"], serde_json::json!(action.main_menu), "{id}");
        assert_eq!(row["title"], action.title.en, "{id}");
        // `title_key` is not compared: the export guesses it from the English
        // (`ActionTitleCatalog`), and two keys can share one (Recently Closed is
        // `action.history.closed`, not `action.recentlyClosed`). The catalog keeps the key the
        // app looks the title up by, read from a build that marked every lookup.
        let mut shortcut = action
            .default_shortcut
            .as_ref()
            .map_or(Value::Null, cmux_action_catalog::json::shortcut);
        if action.shortcut_family == Some("digits") && !shortcut.is_null() {
            shortcut["family"] = serde_json::json!("digits");
        }
        assert_eq!(row["default_shortcut"], shortcut, "{id}");
        let chord = action.default_chord.map_or(Value::Null, |c| {
            serde_json::json!([
                cmux_action_catalog::json::shortcut(&c.first),
                cmux_action_catalog::json::shortcut(&c.second)
            ])
        });
        assert_eq!(row["default_chord"], chord, "{id}");
        assert_eq!(
            row["palette_suggested"],
            serde_json::json!(action.palette_suggestion_rank()),
            "{id}"
        );
        let args = row["args"].as_array().expect("args");
        assert_eq!(args.len(), action.arguments.len(), "{id}");
        for (wire, argument) in args.iter().zip(action.arguments) {
            assert_eq!(wire["name"], argument.name, "{id}");
            assert_eq!(wire["required"], argument.required, "{id}.{}", argument.name);
        }
        let section = &row["palette_section"];
        let category = cmux_action_catalog::category(action.category).expect("a category");
        assert_eq!(section["title_key"], category.title.key, "{id}");
        assert_eq!(section["order"], category.palette_section_order(), "{id}");
    }
}

/// Every translation the catalog carries is the app's, in every language.
#[test]
fn translations_equal_the_string_catalogs() {
    let dir = repo().join("Packages/macOS/CmuxNext/Sources/CmuxNextActions");
    let mut tables = std::collections::HashMap::new();
    let mut checked = 0;
    for (table, key, values) in cmux_action_catalog::strings::entries() {
        let catalog = tables
            .entry(table)
            .or_insert_with(|| read_json(&dir.join(format!("{table}.xcstrings"))));
        let entry = &catalog["strings"][key];
        assert!(!entry.is_null(), "{table}/{key} is not in {table}.xcstrings");
        for (index, locale) in cmux_action_catalog::LOCALES.iter().enumerate() {
            let swift =
                entry["localizations"][*locale]["stringUnit"]["value"].as_str().unwrap_or("");
            assert_eq!(values[index], swift, "{table}/{key} in {locale}");
            checked += 1;
        }
    }
    assert!(checked > 1000, "only {checked} translations checked");
}

#[test]
fn ids_and_cli_names_are_unique() {
    let mut ids = std::collections::HashSet::new();
    let mut cli = std::collections::HashSet::new();
    for action in cmux_action_catalog::actions() {
        assert!(ids.insert(action.id), "{} twice", action.id);
        assert!(cli.insert(action.cli_name), "CLI name {} twice", action.cli_name);
    }
}

#[test]
fn japanese_titles_are_translated() {
    let ja = cmux_action_catalog::strings::locale_index("ja-JP");
    assert_eq!(cmux_action_catalog::LOCALES[ja], "ja");
    let action = cmux_action_catalog::find("newSurface").expect("newSurface");
    assert_ne!(cmux_action_catalog::strings::resolve(&action.title, ja), action.title.en);
    assert_eq!(cmux_action_catalog::find("app.quit").map(|a| a.id), Some("quit"));
}

#[test]
fn debug_build_only_entries_exist() {
    for id in cmux_action_catalog::tables::DEBUG_BUILD_ONLY_ACTIONS {
        let action =
            cmux_action_catalog::find(id).unwrap_or_else(|| panic!("{id} is not an action"));
        assert!(action.is_debug_only, "{id} is Debug-build only but not debug-only");
    }
    for (id, name, value) in cmux_action_catalog::tables::DEBUG_BUILD_ONLY_CASES {
        let action =
            cmux_action_catalog::find(id).unwrap_or_else(|| panic!("{id} is not an action"));
        let argument = action.arguments.iter().find(|a| a.name == *name).expect("the argument");
        let cmux_action_catalog::model::ArgKind::Enumeration(cases) = argument.kind else {
            panic!("{id}.{name} is not an enumeration");
        };
        assert!(cases.iter().any(|c| c.value == *value), "{id}.{name} has no {value}");
    }
}
