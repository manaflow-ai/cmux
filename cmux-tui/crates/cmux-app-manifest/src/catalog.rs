//! The app's catalog fragment (`catalog` in the manifest): the structure from
//! `cmux-app-host/schema/v2/cmux-app-catalog.schema.json`, then the rules
//! that tie it to the manifest.

use crate::issue::Issue;
use serde_json::Value;
use std::collections::HashSet;
use std::sync::OnceLock;

/// The catalog fragment JSON Schema, embedded like the manifest schema.
pub const CATALOG_SCHEMA: &str =
    include_str!("../../cmux-app-host/schema/v2/cmux-app-catalog.schema.json");

fn validator() -> &'static jsonschema::Validator {
    static V: OnceLock<jsonschema::Validator> = OnceLock::new();
    V.get_or_init(|| {
        let schema: Value = serde_json::from_str(CATALOG_SCHEMA).expect("catalog schema is JSON");
        jsonschema::draft202012::new(&schema).expect("catalog schema compiles")
    })
}

/// Validates a parsed catalog fragment against `manifest`. Issue paths are
/// pointers into the fragment, prefixed with `/catalog`.
pub fn validate_catalog(manifest: &Value, catalog: &Value) -> Vec<Issue> {
    let mut out: Vec<Issue> = validator()
        .iter_errors(catalog)
        .map(|e| {
            Issue::error(format!("/catalog{}", e.instance_path), "catalog.schema", e.to_string())
        })
        .collect();
    if !out.is_empty() {
        return out;
    }
    let owner = format!("app:{}", manifest["id"].as_str().unwrap_or_default());
    let family = catalog["family"].as_str().unwrap_or_default();
    let id = manifest["id"].as_str().unwrap_or_default();
    let publisher = id.split('/').next().unwrap_or_default();
    if !crate::rules::is_first_party(publisher) && family != crate::app_namespace(id) {
        out.push(Issue::error(
            "/catalog/family",
            "catalog.namespace",
            format!(
                "a third-party catalog uses its app namespace {}; bare families are first-party",
                crate::app_namespace(id)
            ),
        ));
    }
    let has_main = manifest.pointer("/runtime/main").is_some();
    crate::toolbar::check_ops(manifest, catalog, &mut out);
    check_open_ops(manifest, catalog, &mut out);
    if catalog.get("owner").and_then(Value::as_str).is_some_and(|o| o != owner) {
        out.push(Issue::error("/catalog/owner", "catalog.owner", format!("owner must be {owner}")));
    }
    let mut names = HashSet::new();
    let mut keys = HashSet::new();
    let mut seen = crate::cli::Seen::default();
    for (i, op) in catalog["operations"].as_array().into_iter().flatten().enumerate() {
        let at = format!("/catalog/operations/{i}");
        let name = op["name"].as_str().unwrap_or_default();
        if op["owner"].as_str() != Some(owner.as_str()) {
            out.push(Issue::error(
                format!("{at}/owner"),
                "catalog.owner",
                format!("owner must be {owner}"),
            ));
        }
        if !name.starts_with(&format!("{family}.")) {
            out.push(Issue::error(
                format!("{at}/name"),
                "catalog.family",
                format!("{name} is not in family {family}"),
            ));
        }
        if !names.insert(name) {
            out.push(Issue::error(
                format!("{at}/name"),
                "catalog.duplicate",
                format!("{name} is declared twice"),
            ));
        }
        if op.get("export").is_some() && !has_main {
            out.push(Issue::error(
                format!("{at}/export"),
                "runtime.main.required",
                "an export implementation needs runtime.main",
            ));
        }
        let mut presets = HashSet::new();
        for (j, preset) in op
            .pointer("/palette/presets")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
        {
            if !presets.insert(preset["id"].as_str().unwrap_or_default()) {
                out.push(Issue::error(
                    format!("{at}/palette/presets/{j}/id"),
                    "catalog.duplicate",
                    "preset ids are unique within an op",
                ));
            }
        }
        for (j, binding) in op["keyboard"].as_array().into_iter().flatten().enumerate() {
            let key = (
                binding["key"].as_str().unwrap_or_default(),
                binding["when"].as_str().unwrap_or_default(),
            );
            if !keys.insert(key) {
                out.push(Issue::warning(
                    format!("{at}/keyboard/{j}"),
                    "catalog.shortcutConflict",
                    format!("{} is bound twice in this app for the same condition", key.0),
                ));
            }
        }
        out.extend(crate::cli::check_op(&at, op, &mut seen));
    }
    out
}

/// The interfaces whose implementations list `openOps`.
const OPEN_OP_INTERFACES: &[&str] = &["cmux.terminal.backend/1", "cmux.terminal.connector/1"];

/// Every `openOps` entry of a terminal backend or connector implementation
/// is an op in the app's catalog fragment (`catalog.openOpUnknown`).
fn check_open_ops(manifest: &Value, catalog: &Value, out: &mut Vec<Issue>) {
    let names: HashSet<&str> = catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["name"].as_str())
        .collect();
    for interface in OPEN_OP_INTERFACES {
        let open_ops = manifest
            .get("implements")
            .and_then(|i| i.get(*interface))
            .and_then(|i| i.pointer("/options/openOps"))
            .and_then(Value::as_array);
        for (i, op) in open_ops.into_iter().flatten().enumerate() {
            let op = op.as_str().unwrap_or_default();
            if !names.contains(op) {
                out.push(Issue::error(
                    format!("/implements/{}/options/openOps/{i}", crate::issue::escape(interface)),
                    "catalog.openOpUnknown",
                    format!("{op} is not in the app's catalog"),
                ));
            }
        }
    }
}
