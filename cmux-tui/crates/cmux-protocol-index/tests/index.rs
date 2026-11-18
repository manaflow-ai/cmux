//! Holds docs/protocols/index.json to this checkout, and docs/protocols/README.md to the index.

use std::path::PathBuf;

use cmux_protocol_index::{Disk, INDEX_PATH, README_PATH, check, parse, render};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn index() -> cmux_protocol_index::Index {
    let text =
        std::fs::read_to_string(repo().join(INDEX_PATH)).expect("read docs/protocols/index.json");
    parse(&text).expect("docs/protocols/index.json")
}

#[test]
fn the_index_matches_the_tree() {
    let root = repo();
    let problems = check(&index(), &Disk(&root));
    assert!(problems.is_empty(), "docs/protocols/index.json:\n{}", problems.join("\n"));
}

#[test]
fn the_readme_is_rendered_from_the_index() {
    let path = repo().join(README_PATH);
    let want = render(&index());
    if std::env::var_os("UPDATE_PROTOCOL_INDEX").is_some() {
        std::fs::write(&path, &want).expect("write docs/protocols/README.md");
        return;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        have == want,
        "docs/protocols/README.md is stale: run `UPDATE_PROTOCOL_INDEX=1 cargo test -p cmux-protocol-index` from cmux-tui/"
    );
}
