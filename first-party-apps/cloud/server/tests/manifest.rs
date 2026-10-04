//! The manifest and the catalog fragment pass the one validator
//! (`cmux-app-manifest`), and the server serves exactly the catalog's ops.

use cmux_app_manifest::{Severity, validate_package_file};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::Path;

fn app_dir() -> &'static Path {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/.."))
}

#[test]
fn manifest_and_catalog_fragment_validate() {
    let report = validate_package_file(app_dir(), "cmux-app.v2.json");
    let errors: Vec<_> = report.issues.iter().filter(|i| i.severity == Severity::Error).collect();
    assert!(errors.is_empty(), "{errors:?}");
    let manifest = report.manifest.expect("manifest parsed");
    assert_eq!(manifest["id"], "cmux/cloud");
    assert!(manifest["server"]["scopes"].is_object(), "server.scopes is scope -> reason");
    // Every host-only op the server sends is a declared server scope.
    let op = cmux_cloud::api::host::LINK_GET;
    let reason = &manifest["server"]["scopes"][format!("op:{op}")];
    assert!(reason.as_str().is_some_and(|r| !r.is_empty()), "op:{op} is declared");
}

#[test]
fn the_server_serves_every_catalog_op_and_no_other() {
    let raw =
        std::fs::read_to_string(app_dir().join("catalog/cloud-catalog.json")).expect("catalog");
    let catalog: Value = serde_json::from_str(&raw).expect("catalog JSON");
    let declared: BTreeSet<String> = catalog["operations"]
        .as_array()
        .expect("operations")
        .iter()
        .map(|op| op["name"].as_str().expect("name").to_owned())
        .collect();
    let served: BTreeSet<String> = cmux_cloud::ops::op_names().map(str::to_owned).collect();
    assert_eq!(declared, served);
    for op in catalog["operations"].as_array().expect("operations") {
        let name = op["name"].as_str().expect("name");
        assert_eq!(cmux_cloud::ops::canonical_name(&format!("cmux.{name}")), Some(name));
        if op["risk"] == "destructive" {
            assert_eq!(op["mcp"]["expose"], "never", "{name}: destructive ops are never on MCP");
        }
        assert_eq!(op["idempotency"] == "required", op["class"] == "mutation", "{name}");
        let (mutation, user_only) = cmux_cloud::ops::op_policy(name).expect("served");
        assert_eq!(mutation, op["class"] == "mutation", "{name}: class and server guard agree");
        assert_eq!(user_only, op["gesture"] == "required", "{name}: gesture and origin rule agree");
        if user_only {
            assert_eq!(
                op["cli"]["visible"], false,
                "{name}: a user-only op is not a visible CLI verb"
            );
        }
    }
}
