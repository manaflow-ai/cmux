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
use std::sync::LazyLock;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// The markers for what this crate has and the pinned app FFI does not yet (step A of an app FFI
/// change, docs/ci/app-ffi-release.md), one file per entry under `tests/awaiting-repin/`. Adding
/// an entry is creating its file and the re-pin deletes it, so two pull requests that mark or
/// clear different ids never touch the same path and never conflict here (they did in a shared
/// Rust list: one side clearing ids the re-pin landed while another added ids next to them).
/// Leo, 2026-11-15: "conflicts/falling behind branch idk i feel like there should be better
/// solutions to this".
///
/// - `actions/<id>`: an action the exports do not have yet; both leave its row out.
/// - `shortcut/<id>`: a default shortcut the exports do not show yet (they may show none).
/// - `shortcut-removal/<id>`: a default shortcut this crate dropped that the exports still show.
/// - `fields/<id>`: fields of an existing action this crate changed, one JSON pointer into the
///   action's catalog row per line (`/surfacePlan/palette`); the dump keeps the old value of each.
/// - `family/<family>/<id>`: a palette family member the dump does not have yet.
///
/// Text after a `#` is a note (which pull request, why). Only `fields/` reads its lines; the
/// other files may be empty. Each marker fails once the export has what it waits for, naming the
/// file to delete.
const MARKERS: &str = "cmux-tui/crates/cmux-action-catalog/tests/awaiting-repin";

/// The repo-relative path of `list`'s marker for `id`, as a failure names it.
fn marker(list: &str, id: &str) -> String {
    format!("{MARKERS}/{list}/{id}")
}

/// Each marker file in `list` (a directory under [`MARKERS`]) as its name and its lines without
/// notes or blanks, sorted by name. A missing directory is an empty list.
fn marker_files(list: &str) -> Vec<(String, Vec<String>)> {
    let dir = repo().join(MARKERS).join(list);
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => panic!("{}: {e}", dir.display()),
    };
    let mut files: Vec<_> = entries
        .map(|entry| entry.unwrap_or_else(|e| panic!("{}: {e}", dir.display())))
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| {
            let name = entry.file_name().into_string().expect("a UTF-8 marker name");
            let path = entry.path();
            assert!(path.is_file(), "{MARKERS}/{list}/{name}: a marker is a file named by its id");
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
            let lines = text
                .lines()
                .map(|line| line.split('#').next().unwrap_or("").trim())
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect();
            (name, lines)
        })
        .collect();
    files.sort();
    files
}

/// The ids `list` marks (the marker files' names).
fn marked(list: &str) -> Vec<String> {
    marker_files(list).into_iter().map(|(id, _)| id).collect()
}

fn listed(ids: &[String], id: &str) -> bool {
    ids.iter().any(|i| i == id)
}

/// Actions this crate has and the pinned app FFI does not yet: `awaiting-repin/actions/<id>`. The
/// exports are written from the pinned catalog, so they gain these rows with the re-pin, which
/// deletes the markers.
static AWAITING_REPIN: LazyLock<Vec<String>> = LazyLock::new(|| marked("actions"));

/// Each id on [`AWAITING_REPIN`] is a catalog action that `export` (one of the exports' action
/// lists) does not have yet, and every other catalog action is in `export`: a missing one names
/// the marker to create, a landed one the marker to delete.
fn check_awaiting_repin(export: &[Value], file: &str) {
    for id in AWAITING_REPIN.iter() {
        let path = marker("actions", id);
        assert!(
            cmux_action_catalog::find(id).is_some(),
            "{id} is awaiting the re-pin but not an action: delete {path}"
        );
        assert!(
            !export.iter().any(|row| row["id"] == *id),
            "{file} has {id}: the re-pin landed, so delete {path}"
        );
    }
    let missing: Vec<_> = cmux_action_catalog::actions()
        .filter(|a| !listed(&AWAITING_REPIN, a.id) && !export.iter().any(|row| row["id"] == a.id))
        .map(|a| marker("actions", a.id))
        .collect();
    assert!(
        missing.is_empty(),
        "{file} does not have these actions. A new action the pinned app FFI does not have yet \
         (step A, docs/ci/app-ffi-release.md) waits for the re-pin: create each file (empty, or a \
         `# why` note): {missing:?}"
    );
}

/// Actions whose default shortcut this crate has and the pinned app FFI does not yet:
/// `awaiting-repin/shortcut/<id>`. The exports are written from the pinned catalog, so until the
/// re-pin they show no shortcut for these rows. An export may show either no shortcut or this
/// crate's; any other value still fails. Delete the marker once both exports carry its shortcut.
static SHORTCUT_AWAITING_REPIN: LazyLock<Vec<String>> = LazyLock::new(|| marked("shortcut"));

/// Whether `id`'s exported shortcut may be `null` while the crate has one (see
/// [`SHORTCUT_AWAITING_REPIN`]).
fn shortcut_awaits_repin(id: &str, exported: &Value) -> bool {
    if !listed(&SHORTCUT_AWAITING_REPIN, id) {
        return false;
    }
    let path = marker("shortcut", id);
    let action = cmux_action_catalog::find(id).unwrap_or_else(|| {
        panic!("{id} is awaiting a shortcut re-pin but not an action: delete {path}")
    });
    assert!(
        action.default_shortcut.is_some(),
        "{id} is awaiting a shortcut re-pin but has no default shortcut: delete {path}"
    );
    exported.is_null()
}

/// Actions whose default shortcut this crate dropped and the pinned app FFI still has:
/// `awaiting-repin/shortcut-removal/<id>`. Until the re-pin the exports still show the old
/// shortcut. Leo, 2026-11-15, on Toggle Terminal and Chat: "idk if the terminal gui should even
/// get a hotkey by default".
static SHORTCUT_REMOVAL_AWAITING_REPIN: LazyLock<Vec<String>> =
    LazyLock::new(|| marked("shortcut-removal"));

/// Whether `id`'s exported shortcut may still be the pinned app's while the crate has none.
fn shortcut_removal_awaits_repin(id: &str, crate_shortcut: &Value) -> bool {
    listed(&SHORTCUT_REMOVAL_AWAITING_REPIN, id) && crate_shortcut.is_null()
}

/// Fields of an existing action that this crate has changed and the pinned app FFI does not have
/// yet, as JSON pointers into the action's catalog row, one per line of
/// `awaiting-repin/fields/<id>`. Until the re-pin the dump keeps the old value of each; every
/// other field of the row is still compared. A listed field the dump already shows as this crate
/// has it fails: the re-pin landed, so delete the marker.
static FIELDS_AWAITING_REPIN: LazyLock<Vec<(String, Vec<String>)>> = LazyLock::new(|| {
    let files = marker_files("fields");
    for (id, fields) in &files {
        assert!(
            !fields.is_empty(),
            "{} lists no field: put one JSON pointer per line, or delete it",
            marker("fields", id)
        );
    }
    files
});

/// Gives `rust`'s rows the dump's value of each field on [`FIELDS_AWAITING_REPIN`], after
/// checking that the two still differ there.
fn awaiting_field_repin(rust: &mut Value, swift: &Value) {
    for (id, fields) in FIELDS_AWAITING_REPIN.iter() {
        let path = marker("fields", id);
        let dumped = swift["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|a| a["id"] == *id)
            .unwrap_or_else(|| {
                panic!("{id} is awaiting a field re-pin but not in the dump ({path})")
            });
        let action = rust["actions"]
            .as_array_mut()
            .into_iter()
            .flatten()
            .find(|a| a["id"] == *id)
            .unwrap_or_else(|| {
                panic!("{id} is awaiting a field re-pin but not an action: delete {path}")
            });
        for field in fields {
            let old = dumped.pointer(field).cloned().unwrap_or(Value::Null);
            let new = action
                .pointer_mut(field)
                .unwrap_or_else(|| panic!("{id}{field}: no such field (line {field} of {path})"));
            assert_ne!(
                *new, old,
                "action-catalog.json has {id}{field} as the crate does: the re-pin landed, so take {field} out of {path} (delete the file when it is the last)"
            );
            *new = old;
        }
    }
}

/// Whether `id`'s exported arguments may still be the pinned app's (see
/// [`FIELDS_AWAITING_REPIN`]).
fn arguments_await_repin(id: &str) -> bool {
    field_awaits_repin(id, "/arguments")
}

/// Whether `id`'s FIELD is on [`FIELDS_AWAITING_REPIN`].
fn field_awaits_repin(id: &str, field: &str) -> bool {
    FIELDS_AWAITING_REPIN.iter().any(|(i, fields)| i == id && listed(fields, field))
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
            .retain(|action| !action["id"].as_str().is_some_and(|id| listed(&AWAITING_REPIN, id)));
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
        panic!(
            "the Rust catalog differs from the Swift dump: {difference}. A change the pinned app \
             FFI does not have yet (step A, docs/ci/app-ffi-release.md) waits for the re-pin in a \
             marker under {MARKERS}/: an action's changed field is a JSON pointer line in \
             fields/<id>, a new shortcut is shortcut/<id>, a dropped one shortcut-removal/<id>, a \
             new palette family member family/<family>/<id>"
        );
    }
}

/// Palette family members the crate has and the pinned app's dump does not yet: the app reads
/// the crate through the pinned FFI, so its dump gains them only with the next re-pin. Each
/// leaves the Rust side here until then, and fails once the dump has it. One marker per member:
/// `awaiting-repin/family/<family>/<id>`.
static FAMILY_AWAITING_REPIN: LazyLock<Vec<(String, Vec<String>)>> = LazyLock::new(|| {
    let dir = repo().join(MARKERS).join("family");
    let families = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => panic!("{}: {e}", dir.display()),
    };
    let mut families: Vec<_> = families
        .map(|entry| entry.unwrap_or_else(|e| panic!("{}: {e}", dir.display())))
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| {
            let family = entry.file_name().into_string().expect("a UTF-8 family name");
            assert!(
                entry.path().is_dir(),
                "{MARKERS}/family/{family}: a family is a directory of member markers"
            );
            let ids = marked(&format!("family/{family}"));
            (family, ids)
        })
        .collect();
    families.sort();
    families
});

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
    for (family, ids) in FAMILY_AWAITING_REPIN.iter() {
        for id in ids {
            assert!(
                !members(swift, family).iter().any(|m| m == id),
                "action-catalog.json's {family} family has {id}: the re-pin landed, so delete {}",
                marker(&format!("family/{family}"), id)
            );
        }
        let families = rust["palette"]["families"].as_array_mut().into_iter().flatten();
        for f in families.filter(|f| f["id"] == *family) {
            if let Some(list) = f["members"].as_array_mut() {
                list.retain(|m| !m.as_str().is_some_and(|m| listed(ids, m)));
            }
        }
        // A member's row derives its family and its tier (a family member is niche) from the
        // list: those two take the dump's values, every other field is still compared.
        let dump = |id: &str| {
            swift["actions"].as_array().into_iter().flatten().find(|a| a["id"] == id).cloned()
        };
        let actions = rust["actions"].as_array_mut().into_iter().flatten();
        for action in actions.filter(|a| a["id"].as_str().is_some_and(|id| listed(ids, id))) {
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
        cmux_action_catalog::actions().filter(|a| !listed(&AWAITING_REPIN, a.id)).collect();
    assert_eq!(rows.len(), rust.len(), "action count");
    for (row, action) in rows.iter().zip(&rust) {
        let id = action.id;
        assert_eq!(row["id"], id);
        assert_eq!(row["cli_name"], action.cli_name, "{id}");
        if field_awaits_repin(id, "/surfacePlan/palette") {
            assert_ne!(
                row["palette"],
                action.surface_plan.palette.wire(),
                "action-surfaces.json has {id}'s palette decision: the re-pin landed, so take /surfacePlan/palette out of {} (delete the file when it is the last)",
                marker("fields", id)
            );
        } else {
            assert_eq!(row["palette"], action.surface_plan.palette.wire(), "{id}");
        }
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
        if !shortcut_awaits_repin(id, &row["default_shortcut"])
            && !shortcut_removal_awaits_repin(id, &shortcut)
        {
            assert_eq!(
                row["default_shortcut"],
                shortcut,
                "{id}: a shortcut the pinned app FFI does not have yet waits in {}, a dropped one in {}",
                marker("shortcut", id),
                marker("shortcut-removal", id)
            );
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
                names,
                ours,
                "action-surfaces.json has {id}'s arguments: the re-pin landed, so take /arguments out of {} (delete the file when it is the last)",
                marker("fields", id)
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

/// ActionSurfaceParityTests.declarationsAreConsistent's MCP rule, checked here at step A: an MCP
/// exemption needs a CLI verb, since an action the CLI exempts already leaves MCP with the CLI's
/// reason. Without this, a row like `ownerVerb` plus `systemChange` passes this crate and turns the
/// Swift suite red only once the re-pin ships it (review F1 on #43637).
#[test]
fn mcp_exemptions_have_a_cli_verb() {
    use cmux_action_catalog::Decision;
    for action in cmux_action_catalog::actions() {
        let plan = action.surface_plan;
        let Some(mcp) = plan.mcp_exemption else { continue };
        assert!(
            !matches!(plan.cli, Some(Decision::Exempt(_))),
            "{}: an MCP exemption without a CLI verb (the CLI exemption already covers MCP)",
            action.id
        );
        assert!(
            ["credentials", "endsApp", "systemChange"].contains(&mcp),
            "{}: MCP reason {mcp}",
            action.id
        );
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

/// Leo, 2026-11-15: "idk if the terminal gui should even get a hotkey by default". Toggle
/// Terminal and Chat ships unbound (its old Opt-Cmd-` was macOS's "Move focus to the window
/// drawer"); a person binds one in Settings > Keyboard Shortcuts.
#[test]
fn toggle_terminal_and_chat_has_no_default_key() {
    let action = cmux_action_catalog::find("palette.toggleTerminalChat").expect("an action");
    assert!(action.default_shortcut.is_none() && action.default_chord.is_none());
}

/// The categories the App's launch check covers (`HandlerCoverage.categories` in
/// `CmuxNextApp/Handlers/HandlerCoverage.swift`): every catalog action there needs an App handler.
const HANDLER_COVERAGE_CATEGORIES: &[&str] = &["tab", "pane", "screen", "terminal"];

/// Every `.swift` file under `dir`, recursively.
fn swift_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            swift_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "swift") {
            out.push(path);
        }
    }
}

/// A row the app has never had (absent from the Swift dump, so step A of an app FFI change) in a
/// category `HandlerCoverage` checks reaches the app with the next FFI build: a same-tree build at
/// once, a pinned one after the re-pin. With no App handler, a Debug app traps at launch on
/// `HandlerCoverage.verify` (#43840's three terminal-to-chat rows). So its id must be named in a
/// Swift source that binds actions (`bind`, `bindEffect`, or `bindUnavailable` until the handler
/// lands) before the row merges. Rows the dump has are the App's `HandlerCoverageTests`' job.
#[test]
fn new_rows_in_handler_coverage_categories_have_an_app_binding() {
    let sources = repo().join("Packages/macOS/CmuxNext/Sources");
    let coverage =
        std::fs::read_to_string(sources.join("CmuxNextApp/Handlers/HandlerCoverage.swift"))
            .expect("HandlerCoverage.swift");
    let line = coverage
        .lines()
        .find(|l| l.contains("static let categories"))
        .expect("HandlerCoverage.categories");
    let mut swift_categories: Vec<&str> = line
        .split_once('=')
        .map_or("", |(_, set)| set)
        .split(|c: char| !(c.is_alphanumeric() || c == '.'))
        .filter_map(|word| word.strip_prefix('.'))
        .collect();
    swift_categories.sort_unstable();
    let mut ours = HANDLER_COVERAGE_CATEGORIES.to_vec();
    ours.sort_unstable();
    assert_eq!(
        swift_categories, ours,
        "HandlerCoverage.categories changed: update HANDLER_COVERAGE_CATEGORIES"
    );

    let dump = read_json(&repo().join("plans/cmux-next/action-catalog.json"));
    let dumped: std::collections::HashSet<&str> = dump["actions"]
        .as_array()
        .expect("actions")
        .iter()
        .filter_map(|a| a["id"].as_str())
        .collect();
    let mut files = Vec::new();
    swift_files(&sources, &mut files);
    let binders: Vec<String> = files
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .filter(|text| text.contains("bind"))
        .collect();
    let missing: Vec<&str> = cmux_action_catalog::actions()
        .filter(|a| HANDLER_COVERAGE_CATEGORIES.contains(&a.category) && !dumped.contains(a.id))
        .map(|a| a.id)
        .filter(|id| {
            let literal = format!("\"{id}\"");
            !binders.iter().any(|text| text.contains(&literal))
        })
        .collect();
    assert!(
        missing.is_empty(),
        "new tab/pane/screen/terminal actions with no App binding (a Debug app traps at launch in \
         HandlerCoverage.verify): {missing:?}. Bind each in Packages/macOS/CmuxNext/Sources, \
         with bindUnavailable until its handler lands"
    );
}

/// The right-click menus whose top level the app assembles from more than this crate's
/// placements: the chat menu (`ChatMenuLengthTests`) and the menus `ContextMenuEssentials` lays
/// out (workspace row, tab, pane, with their Copy ▸ and More ▸). The app's
/// `ActionSurfaceParityTests.everyMenuKeepsAShortTopLevel` counts those.
const MENUS_COUNTED_IN_THE_APP: &[&str] = &["agentChat", "workspaceRow", "tab", "pane"];

/// Lawrence (2026-10-01): long menus use submenus. Each right-click menu keeps at most 12
/// top-level rows, 13 for the terminal selection menu's fork commands, the caps of the app's
/// `ActionSurfaceParityTests.everyMenuKeepsAShortTopLevel`. The top level is what the app's
/// `ContextMenuCatalog.topLevel` makes of the placements: one row per placement with no folder
/// and no submenu parent, and one per folder (a folder of one row shows that row inline).
/// The app checks the pinned catalog, so without this a catalog row that pushes a menu past its
/// cap fails only after the re-pin, on unrelated pull requests (#43840's three terminal rows took
/// the terminal selection menu to 16). Here it fails in the pull request that adds the row.
#[test]
fn menus_keep_a_short_top_level() {
    let mut menus: std::collections::BTreeMap<&str, (usize, std::collections::BTreeSet<&str>)> =
        std::collections::BTreeMap::new();
    for action in cmux_action_catalog::actions() {
        for placement in action.surface_plan.context_menus.iter().filter(|p| p.parent.is_none()) {
            let (rows, folders) = menus.entry(placement.context).or_default();
            match placement.folder {
                Some(folder) => {
                    folders.insert(folder);
                }
                None => *rows += 1,
            }
        }
    }
    let over: Vec<String> = menus
        .iter()
        .filter(|(context, _)| !MENUS_COUNTED_IN_THE_APP.contains(context))
        .filter_map(|(context, (rows, folders))| {
            let cap = if *context == "terminalSelection" { 13 } else { 12 };
            let count = rows + folders.len();
            (count > cap).then(|| format!("{context}: {count} top-level rows, cap {cap}"))
        })
        .collect();
    assert!(
        over.is_empty(),
        "menus past their top-level cap: {over:?}. Put the new rows in one of the menu's folders \
         (`Placement::folder`), as #44028 did with the terminal-to-chat rows"
    );
}
