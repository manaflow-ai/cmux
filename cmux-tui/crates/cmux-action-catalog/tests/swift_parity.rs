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

/// Actions this crate has and the pinned app FFI does not yet (step A of an app FFI change,
/// docs/ci/app-ffi-release.md). The exports are written from the pinned catalog, so they gain
/// these rows with the re-pin, which takes them off this list (#38644, #41954).
const AWAITING_REPIN: &[&str] = &["agentBoard.show", "macScreen.stopViewing"];

/// Each id on [`AWAITING_REPIN`] is a catalog action that `export` (one of the exports' action
/// lists) does not have yet: once the export has it, it comes off the list.
fn check_awaiting_repin(export: &[Value], file: &str) {
    for id in AWAITING_REPIN {
        assert!(
            cmux_action_catalog::find(id).is_some(),
            "{id} is awaiting the re-pin but not an action"
        );
        assert!(
            !export.iter().any(|row| row["id"] == *id),
            "{file} has {id}: the re-pin landed, so take it off AWAITING_REPIN"
        );
    }
}

/// Actions whose default shortcut this crate has and the pinned app FFI does not yet (step A of
/// an app FFI change, docs/ci/app-ffi-release.md). The exports are written from the pinned
/// catalog, so until the re-pin they show no shortcut for these rows. An export may show
/// either no shortcut or this crate's; any other value still fails. Take an id off once both
/// exports carry its shortcut.
const SHORTCUT_AWAITING_REPIN: &[&str] = &["palette.toggleTerminalChat"];

/// Whether `id`'s exported shortcut may be `null` while the crate has one (see
/// [`SHORTCUT_AWAITING_REPIN`]).
fn shortcut_awaits_repin(id: &str, exported: &Value) -> bool {
    if !SHORTCUT_AWAITING_REPIN.contains(&id) {
        return false;
    }
    let action = cmux_action_catalog::find(id)
        .unwrap_or_else(|| panic!("{id} is awaiting a shortcut re-pin but not an action"));
    assert!(
        action.default_shortcut.is_some(),
        "{id} is awaiting a shortcut re-pin but has no default shortcut"
    );
    exported.is_null()
}

/// Fields of an existing action that this crate has changed and the pinned app FFI does not have
/// yet (step A of an app FFI change, docs/ci/app-ffi-release.md), as JSON pointers into the
/// action's catalog row. Until the re-pin the dump keeps the old value of each; every other
/// field of the row is still compared. A listed field the dump already shows as this crate has
/// it fails: the re-pin landed, so take it off.
const FIELDS_AWAITING_REPIN: &[(&str, &[&str])] =
    &[("macScreen.open", &["/arguments", "/surfacePlan/contextMenus"])];

/// Gives `rust`'s rows the dump's value of each field on [`FIELDS_AWAITING_REPIN`], after
/// checking that the two still differ there.
fn awaiting_field_repin(rust: &mut Value, swift: &Value) {
    for (id, fields) in FIELDS_AWAITING_REPIN {
        let dumped = swift["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|a| a["id"] == *id)
            .unwrap_or_else(|| panic!("{id} is awaiting a field re-pin but not in the dump"));
        let action = rust["actions"]
            .as_array_mut()
            .into_iter()
            .flatten()
            .find(|a| a["id"] == *id)
            .unwrap_or_else(|| panic!("{id} is awaiting a field re-pin but not an action"));
        for field in *fields {
            let old = dumped.pointer(field).cloned().unwrap_or(Value::Null);
            let new =
                action.pointer_mut(field).unwrap_or_else(|| panic!("{id}{field}: no such field"));
            assert_ne!(
                *new, old,
                "action-catalog.json has {id}{field} as the crate does: the re-pin landed, so take it off FIELDS_AWAITING_REPIN"
            );
            *new = old;
        }
    }
}

/// Whether `id`'s exported arguments may still be the pinned app's (see
/// [`FIELDS_AWAITING_REPIN`]).
fn arguments_await_repin(id: &str) -> bool {
    FIELDS_AWAITING_REPIN.iter().any(|(i, fields)| *i == id && fields.contains(&"/arguments"))
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
    // carries one still differs. A case without them is not a Swift dump's (a hand-written
    // row): it fails here, not in the app's ActionCatalogDumpTests after the re-pin.
    let mut missing = Vec::new();
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
                        match case.get(field) {
                            Some(Value::Null) => {
                                case.remove(field);
                            }
                            Some(_) => {}
                            None => missing
                                .push(format!("{key} case {:?} has no {field}", case.get("value"))),
                        }
                    }
                }
            }
        }
    }
    assert!(
        missing.is_empty(),
        "enum cases the Swift dump writes with null subtitle and symbol: {missing:?}"
    );
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
    check_awaiting_repin(
        swift["actions"].as_array().map_or(&[], Vec::as_slice),
        "action-catalog.json",
    );
    if let Some(actions) = object.get_mut("actions").and_then(Value::as_array_mut) {
        actions
            .retain(|action| !action["id"].as_str().is_some_and(|id| AWAITING_REPIN.contains(&id)));
    }
    awaiting_family_repin(&mut rust, &swift);
    awaiting_field_repin(&mut rust, &swift);
    for action in rust["actions"].as_array_mut().into_iter().flatten() {
        let Some(id) = action["id"].as_str().map(str::to_owned) else { continue };
        let dumped = swift["actions"].as_array().into_iter().flatten().find(|a| a["id"] == *id);
        if dumped.is_some_and(|d| shortcut_awaits_repin(&id, &d["defaultShortcut"])) {
            action["defaultShortcut"] = Value::Null;
        }
    }
    if let Some(difference) = first_difference("$", &rust, &swift) {
        panic!("the Rust catalog differs from the Swift dump: {difference}");
    }
}

/// Palette family members the crate has and the pinned app's dump does not yet: the app reads
/// the crate through the pinned FFI, so its dump gains them only with the next re-pin. Each
/// leaves the Rust side here until then, and fails once the dump has it.
const FAMILY_AWAITING_REPIN: &[(&str, &[&str])] = &[];

fn awaiting_family_repin(rust: &mut Value, swift: &Value) {
    let members = |catalog: &Value, family: &str| {
        catalog["palette"]["families"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|f| f["id"] == family)
            .and_then(|f| f["members"].as_array())
            .cloned()
            .unwrap_or_default()
    };
    for (family, ids) in FAMILY_AWAITING_REPIN {
        for id in *ids {
            assert!(
                !members(swift, family).iter().any(|m| m == id),
                "action-catalog.json's {family} family has {id}: the re-pin landed, so take it off FAMILY_AWAITING_REPIN"
            );
        }
        let families = rust["palette"]["families"].as_array_mut().into_iter().flatten();
        for f in families.filter(|f| f["id"] == *family) {
            if let Some(list) = f["members"].as_array_mut() {
                list.retain(|m| !m.as_str().is_some_and(|m| ids.contains(&m)));
            }
        }
        // A member's row derives its family and its tier (a family member is niche) from the
        // list: those two take the dump's values, every other field is still compared.
        let dump = |id: &str| {
            swift["actions"].as_array().into_iter().flatten().find(|a| a["id"] == id).cloned()
        };
        let actions = rust["actions"].as_array_mut().into_iter().flatten();
        for action in actions.filter(|a| a["id"].as_str().is_some_and(|id| ids.contains(&id))) {
            let Some(dumped) = action["id"].as_str().and_then(dump) else { continue };
            for field in ["palette_family", "palette_tier"] {
                action["computed"][field] = dumped["computed"][field].clone();
            }
        }
    }
}

#[test]
fn action_list_export_matches() {
    let export = read_json(&repo().join("plans/cmux-next/action-surfaces.json"));
    let rows = export["actions"].as_array().expect("actions");
    check_awaiting_repin(rows, "action-surfaces.json");
    let rust: Vec<_> =
        cmux_action_catalog::actions().filter(|a| !AWAITING_REPIN.contains(&a.id)).collect();
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
        if !shortcut_awaits_repin(id, &row["default_shortcut"]) {
            assert_eq!(row["default_shortcut"], shortcut, "{id}");
        }
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
        if arguments_await_repin(id) {
            let names: Vec<_> = args.iter().map(|a| a["name"].clone()).collect();
            let ours: Vec<_> = action.arguments.iter().map(|a| Value::from(a.name)).collect();
            assert_ne!(
                names, ours,
                "action-surfaces.json has {id}'s arguments: the re-pin landed, so take it off FIELDS_AWAITING_REPIN"
            );
        } else {
            assert_eq!(args.len(), action.arguments.len(), "{id}");
            for (wire, argument) in args.iter().zip(action.arguments) {
                assert_eq!(wire["name"], argument.name, "{id}");
                assert_eq!(wire["required"], argument.required, "{id}.{}", argument.name);
            }
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
