//! Every cmux-platform route the generated client offers is called through it.
//! The client is generated from `openapi.json` (build.rs), so its paths and
//! fields cannot drift from the platform's; a hand-written `"/v1/..."` literal
//! for one of the same routes elsewhere in cmux-tui can, and nothing would
//! notice until a Cloud call failed. This test finds those literals.
//!
//! The ones written before the client existed are listed in
//! `hand-written-routes.txt` (file and literal), to move onto the client one by
//! one. A new one fails here: call the route through `cmux_cloud_client`
//! instead. A listed one that is gone fails too, so the list only shrinks.
//! Routes the vendored spec does not describe (`/v1/artifacts`, the
//! `cmux.wire/1` ops) are not this test's: add them to `tags.txt` first.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The spec's path templates, split into segments.
fn routes() -> Vec<Vec<String>> {
    let text = std::fs::read_to_string(crate_dir().join("openapi.json")).expect("openapi.json");
    let spec: serde_json::Value = serde_json::from_str(&text).expect("openapi.json is JSON");
    spec["paths"].as_object().expect("paths").keys().map(|path| segments(path)).collect()
}

fn segments(path: &str) -> Vec<String> {
    path.split('?').next().unwrap_or_default().split('/').map(str::to_owned).collect()
}

fn is_placeholder(segment: &str) -> bool {
    segment.starts_with('{') && segment.ends_with('}')
}

/// Whether a literal (a `format!` string: `{}` and `{name}` are its
/// placeholders) names a route of the spec.
fn names_route(literal: &str, routes: &[Vec<String>]) -> bool {
    let literal = segments(literal);
    routes.iter().any(|route| {
        route.len() == literal.len()
            && route.iter().zip(&literal).all(|(want, have)| {
                want == have || is_placeholder(want) || (is_placeholder(have) && !want.is_empty())
            })
    })
}

/// `"/v1/..."` literals in a Rust source, outside comments.
fn literals(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in text.lines() {
        let code = line.trim_start();
        if code.starts_with("//") {
            continue;
        }
        let mut rest = line;
        while let Some(start) = rest.find("\"/v1/") {
            let tail = &rest[start + 1..];
            let end = tail.find('"').unwrap_or(tail.len());
            found.push(tail[..end].to_owned());
            rest = &tail[end..];
        }
    }
    found
}

fn source_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default().to_owned();
        if path.is_dir() {
            if !matches!(
                name.as_str(),
                "tests" | "target" | "vendor" | "benches" | "examples" | "cmux-cloud-client"
            ) {
                source_files(&path, out);
            }
        } else if name.ends_with(".rs") && !name.contains("test") {
            out.push(path);
        }
    }
}

/// `crate/path.rs literal` for every hand-written literal of a spec route.
fn hand_written() -> BTreeSet<String> {
    let routes = routes();
    let crates = crate_dir().join("..");
    let mut files = Vec::new();
    source_files(&crates, &mut files);
    let mut found = BTreeSet::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        let relative = file.strip_prefix(&crates).unwrap_or(&file).display().to_string();
        for literal in literals(&text) {
            if names_route(&literal, &routes) {
                found.insert(format!("{relative} {literal}"));
            }
        }
    }
    found
}

fn listed() -> BTreeSet<String> {
    let text = std::fs::read_to_string(crate_dir().join("hand-written-routes.txt"))
        .expect("hand-written-routes.txt");
    text.lines()
        .map(|line| line.split('#').next().unwrap_or_default().trim())
        .filter(|line| !line.is_empty())
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect()
}

#[test]
fn no_new_hand_written_call_to_a_route_the_client_generates() {
    let found = hand_written();
    let listed = listed();
    let new = found.difference(&listed).cloned().collect::<Vec<_>>();
    let gone = listed.difference(&found).cloned().collect::<Vec<_>>();
    assert!(
        new.is_empty(),
        "these name a cmux-platform route by hand that cmux_cloud_client generates from openapi.json; \
         call it through the client instead:\n{}",
        new.join("\n")
    );
    assert!(
        gone.is_empty(),
        "these are no longer hand-written; remove them from cmux-cloud-client/hand-written-routes.txt:\n{}",
        gone.join("\n")
    );
}

#[test]
fn a_literal_names_a_route_by_its_template() {
    let routes = vec![segments("/v1/machines/{id}/pause"), segments("/v1/auth/token")];
    assert!(names_route("/v1/machines/{}/pause", &routes));
    assert!(names_route("/v1/machines/{machine_id}/pause", &routes));
    assert!(names_route("/v1/auth/token?x=1", &routes));
    assert!(!names_route("/v1/machines/{}/paws", &routes));
    assert!(!names_route("/v1/artifacts", &routes));
    assert_eq!(literals("let a = \"/v1/auth/token\";\n    // \"/v1/y\""), ["/v1/auth/token"]);
}
