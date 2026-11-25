//! The Linux exporter (`examples/export-action-surfaces`, run by `scripts/cmux-next/export-action-surfaces-linux.sh`)
//! writes the three action exports byte for byte as the Mac's Swift tests do.
//!
//! The committed exports come from one catalog: the one the app's pinned FFI held when the Mac last wrote them.
//! `action-catalog.json` is that catalog as the app decoded it, so taking back what the dump adds (each
//! binding's parsed `when`, each enum case's nil `subtitle` and `symbol`) gives the catalog JSON the exporter
//! reads; exporting it again must give all three committed files, byte for byte.

#[path = "../examples/export-action-surfaces/apple_json.rs"]
mod apple_json;
#[path = "../examples/export-action-surfaces/dump.rs"]
mod dump;
#[path = "../examples/export-action-surfaces/surfaces.rs"]
mod surfaces;
#[path = "../examples/export-action-surfaces/swift_tables.rs"]
mod swift_tables;

use std::path::{Path, PathBuf};

use serde_json::Value;

fn repo() -> PathBuf {
    // affected-reads: plans/cmux-next/action-catalog.json plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md Packages/macOS/CmuxNext/Sources/CmuxNextActions
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read(path: &str) -> String {
    std::fs::read_to_string(repo().join(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

/// The catalog JSON behind the committed dump: the dump less what the Swift types add on decoding.
fn catalog_behind_the_dump(dump: &str) -> Value {
    let mut root: Value = serde_json::from_str(dump).expect("action-catalog.json parses");
    for action in root["actions"].as_array_mut().expect("actions") {
        for argument in
            action.get_mut("arguments").and_then(Value::as_array_mut).into_iter().flatten()
        {
            for pointer in ["/kind/enumeration", "/suggestions/pinned"] {
                for case in argument
                    .pointer_mut(pointer)
                    .and_then(Value::as_array_mut)
                    .into_iter()
                    .flatten()
                {
                    let case = case.as_object_mut().expect("an enum case");
                    assert_eq!(
                        case.remove("subtitle"),
                        Some(Value::Null),
                        "a catalog enum case has no subtitle"
                    );
                    assert_eq!(
                        case.remove("symbol"),
                        Some(Value::Null),
                        "a catalog enum case has no symbol"
                    );
                }
            }
        }
    }
    for list in
        root["key_binding_defaults"].as_object_mut().expect("key_binding_defaults").values_mut()
    {
        for row in list.as_array_mut().into_iter().flatten() {
            if let Some(binding) = row.as_object_mut() {
                binding.remove("when");
            }
        }
    }
    root
}

fn first_difference(file: &str, committed: &str, exported: &str) -> Option<String> {
    if committed == exported {
        return None;
    }
    let (old, new): (Vec<&str>, Vec<&str>) =
        (committed.lines().collect(), exported.lines().collect());
    let line = old.iter().zip(&new).position(|(a, b)| a != b).unwrap_or(old.len().min(new.len()));
    Some(format!(
        "{file} line {}: committed {:?}, exported {:?}",
        line + 1,
        old.get(line).unwrap_or(&"<end>"),
        new.get(line).unwrap_or(&"<end>")
    ))
}

#[test]
fn exporter_writes_the_committed_exports() {
    let dump_text = read("plans/cmux-next/action-catalog.json");
    let catalog = catalog_behind_the_dump(&dump_text);

    let dir = repo().join("Packages/macOS/CmuxNext/Sources/CmuxNextActions");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("the string catalogs")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "xcstrings"))
        .collect();
    files.sort();
    let catalogs: Vec<(String, Value)> = files
        .iter()
        .map(|path| {
            let table = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_owned();
            (table, serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap())
        })
        .collect();
    let titles = surfaces::Titles::new(&catalogs).expect("the string catalogs read");

    let (json, block) = surfaces::export(&catalog, &titles);
    let markdown = read("plans/cmux-next/actions.md");
    let exported_markdown =
        surfaces::replace_block(&markdown, &block).expect("actions.md has its generated block");
    let exported_dump = dump::export(&catalog).expect("the dump exports");

    let differences: Vec<String> = [
        first_difference(
            "action-surfaces.json",
            &read("plans/cmux-next/action-surfaces.json"),
            &json,
        ),
        first_difference("actions.md", &markdown, &exported_markdown),
        first_difference("action-catalog.json", &dump_text, &exported_dump),
    ]
    .into_iter()
    .flatten()
    .collect();
    assert!(
        differences.is_empty(),
        "the Linux exporter no longer writes what the Swift exports wrote; port the Swift change to \
         examples/export-action-surfaces:\n{}",
        differences.join("\n")
    );
}

#[test]
fn when_clauses_parse_as_the_swift_parser_does() {
    use serde_json::json;
    assert_eq!(
        dump::parse("surfaceKind != page && !codeEditorFocused"),
        Some(
            json!({"and": [{"notEquals": ["surfaceKind", {"string": "page"}]}, {"not": {"has": "codeEditorFocused"}}]})
        )
    );
    assert_eq!(
        dump::parse("a == 2 || (b)"),
        Some(json!({"or": [{"equals": ["a", {"number": 2}]}, {"has": "b"}]}))
    );
    assert_eq!(
        dump::parse("a not in b"),
        Some(json!({"not": {"isIn": {"0": "a", "listKey": "b"}}}))
    );
    assert_eq!(dump::parse("a =~ /x/i"), Some(json!({"matches": {"0": "a", "pattern": "(?i)x"}})));
    assert_eq!(dump::parse("a &&"), None);
}
