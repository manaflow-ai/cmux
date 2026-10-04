//! The cmux app manifest (`cmux-app.json`, manifest v2) validator.
//!
//! One implementation for every consumer (plans/cmux-next/app-platform.md
//! section 12, step 2): the `cmux apps validate` CLI verb, the app supervisor
//! before it runs an app, and the store registry before it records a version.
//! Structure comes from the JSON Schema (`cmux-app-host/schema/v2`); the
//! semantic rules a schema cannot express (publisher ownership, native code
//! tiers, interface names and options, scope classes, package paths, the
//! catalog fragment) live in [`rules`], [`catalog`] and [`package`].

mod catalog;
mod interfaces;
mod issue;
mod package;
mod presentation;
mod rules;
mod scopes;

pub use catalog::{CATALOG_SCHEMA, validate_catalog};
pub use interfaces::{KNOWN_HOST_CAPABILITIES, KNOWN_INTERFACES};
pub use issue::{Issue, Severity};
pub use package::{PackageReport, validate_package, validate_package_file};
pub use scopes::{SCOPE_CLASSES, ScopeClass, ScopeInfo, scope_info};

use serde_json::Value;
use std::sync::OnceLock;

/// The manifest v2 JSON Schema, embedded so every consumer validates identically.
pub const SCHEMA: &str = include_str!("../../cmux-app-host/schema/v2/cmux-app.schema.json");

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
