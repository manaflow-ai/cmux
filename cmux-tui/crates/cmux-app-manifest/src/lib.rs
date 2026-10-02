//! The cmux app manifest (`cmux-app.json`, manifest v2) validator.
//!
//! One implementation for every consumer (plans/cmux-next/app-platform.md
//! section 12, step 2): the `cmux apps validate` CLI verb, the app supervisor
//! before it runs an app, and the store registry before it records a version.
//! Structure comes from the JSON Schema (`cmux-app-host/schema/v2`); the
//! semantic rules a schema cannot express (publisher ownership, native code
//! tiers, interface names, package paths) live in [`rules`].

mod issue;
mod package;
mod rules;

pub use issue::{Issue, Severity};
pub use package::{PackageReport, validate_package};

use serde_json::Value;
use std::sync::OnceLock;

/// The manifest v2 JSON Schema, embedded so every consumer validates identically.
pub const SCHEMA: &str = include_str!("../../cmux-app-host/schema/v2/cmux-app.schema.json");

/// Interface names this cmux version knows (`cmux-app-host/interfaces/<name>/<major>.json`).
pub const KNOWN_INTERFACES: &[&str] = &[
    "cmux.contact.provider/1",
    "cmux.credential.provider/1",
    "cmux.diff.renderer/1",
    "cmux.diff.source/1",
    "cmux.editor/1",
    "cmux.feed.source/1",
    "cmux.fs.provider/1",
    "cmux.opener/1",
    "cmux.palette.scope/1",
    "cmux.pane/1",
    "cmux.search.provider/1",
    "cmux.section/1",
    "cmux.status/1",
    "cmux.viewer/1",
];

fn schema_validator() -> &'static jsonschema::Validator {
    static VALIDATOR: OnceLock<jsonschema::Validator> = OnceLock::new();
    VALIDATOR.get_or_init(|| {
        let schema: Value = serde_json::from_str(SCHEMA).expect("embedded manifest schema is JSON");
        jsonschema::draft202012::new(&schema).expect("embedded manifest schema compiles")
    })
}

/// Validates a parsed manifest: schema first; semantic rules only when the
/// structure is valid (they assume it).
pub fn validate_manifest(manifest: &Value) -> Vec<Issue> {
    let mut issues: Vec<Issue> = schema_validator()
        .iter_errors(manifest)
        .map(|e| Issue::error(e.instance_path.to_string(), "schema", e.to_string()))
        .collect();
    if issues.is_empty() {
        issues.extend(rules::check(manifest));
    }
    issues
}

/// True when no issue is an error.
pub fn is_valid(issues: &[Issue]) -> bool {
    issues.iter().all(|i| i.severity != Severity::Error)
}
