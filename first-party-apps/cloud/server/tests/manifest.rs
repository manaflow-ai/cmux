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

fn json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).expect("read")).expect("JSON")
}

/// The backend catalog, the single owner of the client-facing `cloud.*`
/// ops (owner `cloud:CloudDO`).
fn backend_ops() -> serde_json::Map<String, Value> {
    let catalog = json(&app_dir().join("../../backend/catalog/cloud-operations.json"));
    catalog["operations"]
        .as_object()
        .expect("operations")
        .iter()
        .filter(|(_, op)| op["owner"] == "cloud:CloudDO")
        .map(|(name, op)| (name.clone(), op.clone()))
        .collect()
}

#[test]
fn the_server_serves_its_fragment_ops_and_the_backend_ops_it_consumes() {
    let catalog = json(&app_dir().join("catalog/cloud-catalog.json"));
    let manifest = json(&app_dir().join("cmux-app.v2.json"));
    let backend = backend_ops();
    let fragment: BTreeSet<String> = catalog["operations"]
        .as_array()
        .expect("operations")
        .iter()
        .map(|op| op["name"].as_str().expect("name").to_owned())
        .collect();
    let consumed: BTreeSet<String> = manifest["consumes"]["ops"]
        .as_array()
        .expect("consumes.ops")
        .iter()
        .map(|op| op.as_str().expect("name").to_owned())
        .collect();
    // The fragment declares no op the backend owns; it names them in consumes.ops.
    assert!(fragment.iter().all(|name| !backend.contains_key(name)), "{fragment:?}");
    for name in &consumed {
        assert!(backend.contains_key(name), "{name}: consumed but not a CloudDO op");
    }
    let served: BTreeSet<String> = cmux_cloud::ops::op_names().map(str::to_owned).collect();
    let both: BTreeSet<String> = fragment.union(&consumed).cloned().collect();
    assert_eq!(both, served);
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
    for name in &consumed {
        let op = &backend[name];
        let (mutation, user_only) = cmux_cloud::ops::op_policy(name).expect("served");
        assert_eq!(mutation, op["class"] == "mutation", "{name}: class and server guard agree");
        // Money and destructive ops need a person here, and the backend
        // keeps them off the CLI and MCP.
        let person = op["risk"] == "money" || op["risk"] == "destructive";
        // The upgrade installs software through exec: a person runs it.
        if name == "cloud.machine.upgrade" {
            assert_eq!(op["risk"], "execute", "{name}");
            assert!(user_only, "{name}: a person runs it");
        }
        // A snapshot counts against max_saved: it is a money op.
        if name == "cloud.snapshot.create" {
            assert_eq!(op["risk"], "money", "{name}");
        }
        if person {
            assert!(user_only, "{name}: a {} op needs origin user", op["risk"]);
            assert_eq!(op["mcp"]["expose"], "never", "{name}");
        }
    }
}

#[test]
fn the_client_error_table_is_the_backend_catalog() {
    let backend = backend_ops();
    let table: BTreeSet<&str> = cmux_cloud::ops::backend_ops().collect();
    let owned: BTreeSet<&str> = backend.keys().map(String::as_str).collect();
    assert_eq!(table, owned, "ops/declared.rs lists exactly the CloudDO ops");
    for (name, op) in &backend {
        let declared: Vec<&str> = op["errors"]
            .as_array()
            .expect("errors")
            .iter()
            .map(|e| e.as_str().expect("code"))
            .collect();
        assert_eq!(
            cmux_cloud::ops::declared_errors(name).map(<[&str]>::to_vec),
            Some(declared),
            "{name}"
        );
    }
}

/// `cloud.machine.link_token` mints the dial credential for `cmux link`
/// (install principals only, never MCP or a visible CLI verb). The Cloud app
/// never consumes it, and `cloud.machine.connect_info` carries no token.
#[test]
fn the_link_token_is_its_own_op_that_the_app_does_not_consume() {
    let backend = backend_ops();
    assert!(backend.contains_key("cloud.machine.link_token"), "a cloud.machine.link_token row");
    let op = &backend["cloud.machine.link_token"];
    // LINK-TOKEN-OP: every call mints a fresh token, so there is no key and
    // no replay; an exec-like grant, audited by CloudDO.
    assert_eq!(op["class"], "mutation");
    assert_eq!(op["idempotency"], "none");
    assert_eq!(op["risk"], "execute");
    assert!(op["docs"].as_str().is_some_and(|d| d.contains("audited")), "{}", op["docs"]);
    assert_eq!(op["principals"], serde_json::json!(["install"]));
    assert_eq!(op["mcp"]["expose"], "never");
    assert_eq!(op["cli"]["visible"], false);
    for code in ["cloud.machine.not_found", "cloud.machine.not_bound", "auth.forbidden"] {
        assert!(op["errors"].as_array().expect("errors").iter().any(|e| e == code), "{code}");
    }
    let manifest = json(&app_dir().join("cmux-app.v2.json"));
    let consumed = manifest["consumes"]["ops"].as_array().expect("consumes.ops");
    assert!(!consumed.iter().any(|o| o == "cloud.machine.link_token"));
    assert!(cmux_cloud::ops::canonical_name("cloud.machine.link_token").is_none(), "not served");
    let info = backend["cloud.machine.connect_info"]["output_json_schema"].to_string();
    assert!(!info.contains("link_token"), "connect_info carries no token");
}
