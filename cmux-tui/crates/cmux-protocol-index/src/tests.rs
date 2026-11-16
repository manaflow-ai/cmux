use std::collections::BTreeMap;

use super::{Tree, check, parse, render};

struct Fake(BTreeMap<&'static str, &'static str>);

impl Tree for Fake {
    fn exists(&self, path: &str) -> bool {
        self.0.contains_key(path)
    }

    fn read(&self, path: &str) -> Option<String> {
        self.0.get(path).map(|text| (*text).to_owned())
    }
}

fn tree() -> Fake {
    Fake(BTreeMap::from([
        ("crates/wire", ""),
        ("crates/wire/spec.md", "# wire"),
        ("crates/wire/src/lib.rs", "pub const VERSION: u8 = 2;"),
        ("crates/wire/vectors.json", "[]"),
        ("crates/wire/tests/vectors.rs", "include_str!(\"../vectors.json\")"),
        ("app/WireTests.swift", "let file = \"crates/wire/vectors.json\""),
    ]))
}

const SHARED: &str = r#"{"about": "a", "protocols": [{
    "name": "wire", "owner": "crates/wire", "spec": "crates/wire/spec.md",
    "version": {"value": "2", "source": "crates/wire/src/lib.rs", "contains": "VERSION: u8 = 2"},
    "vectors": ["crates/wire/vectors.json"],
    "sides": [
        {"lang": "rust", "test": "crates/wire/tests/vectors.rs", "reads": "vectors.json", "run": "cargo test"},
        {"lang": "swift", "test": "app/WireTests.swift", "reads": "vectors.json", "run": "swift test"}
    ]}]}"#;

#[test]
fn an_index_that_matches_the_tree_has_no_problems() {
    assert_eq!(check(&parse(SHARED).expect("index"), &tree()), Vec::<String>::new());
}

#[test]
fn a_version_bump_the_index_missed_is_reported() {
    let mut tree = tree();
    tree.0.insert("crates/wire/src/lib.rs", "pub const VERSION: u8 = 3;");
    let problems = check(&parse(SHARED).expect("index"), &tree);
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert!(problems[0].contains("no longer contains `VERSION: u8 = 2`"), "{problems:?}");
}

#[test]
fn a_test_that_stopped_reading_the_vectors_is_reported() {
    let mut tree = tree();
    tree.0.insert("app/WireTests.swift", "let json = #\"{\"t\": \"hello\"}\"#");
    let problems = check(&parse(SHARED).expect("index"), &tree);
    assert!(
        problems.iter().any(|p| p.contains("app/WireTests.swift does not contain `vectors.json`")),
        "{problems:?}"
    );
}

#[test]
fn a_missing_path_is_reported() {
    let mut tree = tree();
    tree.0.remove("crates/wire/vectors.json");
    let problems = check(&parse(SHARED).expect("index"), &tree);
    assert!(
        problems.iter().any(|p| p.contains("vectors crates/wire/vectors.json does not exist")),
        "{problems:?}"
    );
}

#[test]
fn one_language_needs_a_gap_and_two_languages_must_not_keep_one() {
    let one_side = SHARED.replace(
        r#",
        {"lang": "swift", "test": "app/WireTests.swift", "reads": "vectors.json", "run": "swift test"}"#,
        "",
    );
    let problems = check(&parse(&one_side).expect("index"), &tree());
    assert!(problems.iter().any(|p| p.contains("fewer than two languages")), "{problems:?}");

    let with_gap = SHARED.replace(r#""vectors": ["#, r#""gap": "none", "vectors": ["#);
    let problems = check(&parse(&with_gap).expect("index"), &tree());
    assert!(problems.iter().any(|p| p.contains("drop the gap")), "{problems:?}");
}

#[test]
fn the_readme_lists_a_shared_protocol_with_both_sides() {
    let readme = render(&parse(SHARED).expect("index"));
    assert!(readme.contains("| wire | [`crates/wire`](../../crates/wire) |"), "{readme}");
    assert!(readme.contains("rust: `cargo test`<br>swift: `swift test`"), "{readme}");
}
