//! The cmux app manifest (`cmux-app.json`, manifest v2) validator.
//!
//! One implementation for every consumer (plans/cmux-next/app-platform.md
//! section 12, step 2): the `cmux apps validate` CLI verb, the app supervisor
//! before it runs an app, and the store registry before it records a version.
//! Structure comes from the JSON Schema (`cmux-app-host/schema/v2`); the
//! semantic rules a schema cannot express (publisher ownership, native code
//! tiers, interface names and options, scope classes, package paths, the
//! catalog fragment, CLI names and MCP tool names) live in [`rules`],
//! [`catalog`], [`cli`] and [`package`].

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

mod catalog;
mod cli;
mod interfaces;
mod issue;
mod package;
mod presentation;
mod rules;
mod scopes;
mod toolbar;

pub use catalog::{CATALOG_SCHEMA, validate_catalog};
pub use cli::{
    CLI_RESERVED, Conflict, ConflictKind, MCP_TOOL_NAME_MAX, conflicts, first_party_cli_names,
    first_party_cli_owner, is_mcp_tool, is_reserved_cli_name, mcp_tool_name,
};
pub use interfaces::{KNOWN_HOST_CAPABILITIES, KNOWN_INTERFACES};
pub use issue::{Issue, Severity};
pub use package::{PackageReport, validate_package, validate_package_file};
pub use scopes::{SCOPE_CLASSES, ScopeClass, ScopeInfo, scope_info};
pub use toolbar::{OVERRIDABLE_TOOLBAR_ITEMS, SIDEBAR_TOGGLE_ITEM, TOOLBAR_VISIBLE_APP_ITEMS};

use serde_json::Value;
use std::sync::OnceLock;

/// The manifest v2 JSON Schema, embedded so every consumer validates identically.
pub const SCHEMA: &str = include_str!("../../cmux-app-host/schema/v2/cmux-app.schema.json");

/// Compiles an embedded JSON Schema. The embedded schemas have unit tests
/// that they compile, so an `Err` means a broken build; callers then refuse
/// (fail closed) instead of ending the process.
pub(crate) fn compile_schema(name: &str, raw: &str) -> Result<jsonschema::Validator, String> {
    let schema: Value =
        serde_json::from_str(raw).map_err(|e| format!("{name} is not JSON: {e}"))?;
    compile_schema_value(name, &schema)
}

pub(crate) fn compile_schema_value(
    name: &str,
    schema: &Value,
) -> Result<jsonschema::Validator, String> {
    jsonschema::draft202012::new(schema).map_err(|e| format!("{name} does not compile: {e}"))
}

pub(crate) fn schema_validator() -> Result<&'static jsonschema::Validator, &'static str> {
    static VALIDATOR: OnceLock<Result<jsonschema::Validator, String>> = OnceLock::new();
    VALIDATOR
        .get_or_init(|| compile_schema("the embedded manifest schema", SCHEMA))
        .as_ref()
        .map_err(String::as_str)
}

/// Validates a parsed manifest: schema first; semantic rules only when the
/// structure is valid (they assume it).
pub fn validate_manifest(manifest: &Value) -> Vec<Issue> {
    let validator = match schema_validator() {
        Ok(validator) => validator,
        Err(error) => return vec![Issue::error("", "schema", error)],
    };
    let mut issues: Vec<Issue> = validator
        .iter_errors(manifest)
        .map(|e| Issue::error(e.instance_path.to_string(), "schema", e.to_string()))
        .collect();
    if issues.is_empty() {
        issues.extend(rules::check(manifest));
    }
    issues
}

/// The one pane-protocol namespace of an app id (app-platform.md 18):
/// `<publisher>.<name>` with '-' replaced by '_' (`octo/ssh-terminal` ->
/// `octo.ssh_terminal`). Third-party op and scope families must use it.
pub fn app_namespace(id: &str) -> String {
    id.replace('-', "_").replacen('/', ".", 1)
}

/// True when no issue is an error.
pub fn is_valid(issues: &[Issue]) -> bool {
    issues.iter().all(|i| i.severity != Severity::Error)
}

#[cfg(test)]
mod embedded_tests {
    use serde_json::json;

    /// Every embedded table and schema loads; the fail-closed paths below
    /// are reached only by a broken build.
    #[test]
    fn every_embedded_asset_loads() {
        assert!(crate::schema_validator().is_ok());
        assert!(crate::catalog::validator().is_ok());
        assert!(crate::cli::reserved().is_ok());
        assert!(crate::scopes::rules().is_ok());
        for (name, validator) in crate::interfaces::option_validators() {
            assert!(validator.is_ok(), "{name}: {:?}", validator.as_ref().err());
        }
    }

    #[test]
    fn a_broken_scope_table_is_an_error_not_a_panic() {
        let unknown = json!({"rules": [{"class": "mythic", "pattern": "x"}]}).to_string();
        assert_eq!(
            crate::scopes::parse_rules(&unknown).err().as_deref(),
            Some("unknown scope class Some(\"mythic\")")
        );
        let bad_regex = json!({"rules": [{"class": "standard", "pattern": "("}]}).to_string();
        assert!(crate::scopes::parse_rules(&bad_regex).is_err());
        assert!(crate::scopes::parse_rules("{}").is_err());
    }

    #[test]
    fn a_broken_reserved_table_is_an_error_not_a_panic() {
        assert!(crate::cli::parse_reserved("{}").is_err());
        assert!(crate::cli::parse_reserved(r#"{"names": [1]}"#).is_err());
        let bad_owner = r#"{"names": ["cloud"], "firstParty": {"cloud": 1}}"#;
        assert!(crate::cli::parse_reserved(bad_owner).is_err());
    }

    #[test]
    fn a_schema_that_does_not_compile_is_an_error_not_a_panic() {
        assert!(crate::compile_schema("test", "not json").is_err());
        assert!(crate::compile_schema("test", r#"{"type": 7}"#).is_err());
    }
}
