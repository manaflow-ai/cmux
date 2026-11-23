//! The cmux app manifest (`cmux-app.json`, manifest v2) validator.
//!
//! One implementation for every consumer (plans/cmux-next/app-platform.md
//! section 12, step 2): the `cmux apps validate` CLI verb, the app supervisor
//! before it runs an app, and the store registry before it records a version.
//! Structure comes from the JSON Schema (`cmux-app-host/schema/v2`); the
//! semantic rules a schema cannot express (publisher ownership, native code
//! tiers, interface names and options, a theme pack's contrast floor, scope classes, package paths, the
//! catalog fragment, CLI names, MCP tool names and `contributes.wallpapers`,
//! checked with cmux-wallpaper) live in [`rules`],
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

pub mod capabilities;
mod catalog;
mod cli;
mod deploy;
pub mod hidden;
mod interfaces;
mod issue;
mod menus;
pub mod module_store;
mod package;
mod presentation;
mod rules;
mod scopes;
mod theme_pack;
mod toolbar;
mod web_pane;
pub mod whats_new;

pub use capabilities::{
    Capabilities, OpCapability, OpClass, OpScope, scope_info, scope_reaches_out,
};
pub use catalog::{CATALOG_SCHEMA, validate_catalog};
pub use cli::{
    CLI_RESERVED, Conflict, ConflictKind, MCP_TOOL_NAME_MAX, conflicts, first_party_cli_names,
    first_party_cli_owner, is_mcp_tool, is_reserved_cli_name, mcp_tool_name,
};
pub use interfaces::{KNOWN_HOST_CAPABILITIES, KNOWN_INTERFACES, interface_files};
pub use issue::{Issue, Severity};
pub use menus::MENU_TARGETS;
pub use package::{PackageReport, validate_package, validate_package_file};
pub use scopes::{SCOPE_CLASSES, ScopeClass, ScopeInfo};
pub use theme_pack::{ContrastFinding, ThemeContrast, theme_contrast, token_key};
pub use toolbar::{OVERRIDABLE_TOOLBAR_ITEMS, SIDEBAR_TOGGLE_ITEM, TOOLBAR_VISIBLE_APP_ITEMS};
pub use web_pane::{
    APP_PAGE_SCHEME, PageFileRefusal, STRICT_PAGE_CSP, WebPage, app_page_host, effective_csp,
    resolve_request, web_pages,
};

use jsonschema::error::ValidationErrorKind;
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

/// The schema's cap on a text field (`$defs/text`: a string, or one per
/// language): `name`, `description`, titles.
pub const TEXT_MAX_CHARS: usize = 300;

/// A text field past [`TEXT_MAX_CHARS`] as its own issue, naming the field
/// and its length. The schema's answer for it is a `oneOf` miss that repeats
/// the whole text and never says why; a package refused for it is missing
/// from the App Store, so the reason must be plain.
fn text_too_long(path: &str, instance: &Value) -> Option<Issue> {
    let chars = |s: &str| s.chars().count();
    let (path, length) = match instance {
        Value::String(s) if chars(s) > TEXT_MAX_CHARS => (path.to_string(), chars(s)),
        Value::Object(texts) => texts.iter().find_map(|(language, text)| {
            let length = text.as_str().map(chars).filter(|n| *n > TEXT_MAX_CHARS)?;
            Some((format!("{path}/{language}"), length))
        })?,
        _ => return None,
    };
    Some(Issue::error(
        path,
        "text.too_long",
        format!("is {length} characters; the limit is {TEXT_MAX_CHARS}"),
    ))
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
        .map(|e| {
            let path = e.instance_path.to_string();
            // Only a `$defs/text` miss: a oneOf whose branches failed on the
            // text cap itself (an icon path's oneOf has its own, smaller cap).
            let text_miss = match &e.kind {
                ValidationErrorKind::OneOfNotValid { context } => {
                    context.iter().flatten().any(|branch| {
                        matches!(branch.kind, ValidationErrorKind::MaxLength { limit }
                            if limit == TEXT_MAX_CHARS as u64)
                    })
                }
                _ => false,
            };
            text_miss
                .then(|| text_too_long(&path, &e.instance))
                .flatten()
                .unwrap_or_else(|| Issue::error(path, "schema", e.to_string()))
        })
        .collect();
    if issues.is_empty() {
        issues.extend(rules::check(manifest));
    }
    issues.extend(hidden::manifest_issues(manifest));
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
