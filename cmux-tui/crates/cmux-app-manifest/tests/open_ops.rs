//! `openOps` on terminal backend and connector implementations: the catalog
//! ops whose user runs get an open token (Cloud C10).

use cmux_app_manifest::{Severity, validate_catalog, validate_manifest};
use serde_json::{Value, json};

/// A third-party terminal backend `octo/ssh` with `options`.
fn manifest(interface: &str, options: Value) -> Value {
    json!({ "manifestVersion": 2, "id": "octo/ssh", "name": "SSH", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "repository": "https://github.com/octo/ssh",
        "server": { "kind": "js", "instances": "user", "hosts": ["local"] },
        "implements": { interface: { "server": true, "options": options } },
        "optionalScopes": { "terminal:backend": "Run your SSH terminals." } })
}

fn errors(m: &Value) -> Vec<(String, &'static str)> {
    validate_manifest(m)
        .into_iter()
        .filter(|i| i.severity == Severity::Error)
        .map(|i| (i.path, i.code))
        .collect()
}

fn catalog(ops: &[&str]) -> Value {
    let operations: Vec<Value> = ops
        .iter()
        .map(|name| json!({ "name": name, "owner": "app:octo/ssh", "class": "mutation", "risk": "mutate-own",
            "idempotency": "required", "input": { "type": "object" }, "docs": "d", "since": "octo.ssh/1" }))
        .collect();
    json!({ "family": "octo.ssh", "operations": operations })
}

#[test]
fn both_terminal_interfaces_accept_open_ops() {
    for interface in ["cmux.terminal.backend/1", "cmux.terminal.connector/1"] {
        let m = manifest(interface, json!({ "kinds": ["ssh"], "openOps": ["octo.ssh.open"] }));
        assert_eq!(errors(&m), vec![], "{interface}");
    }
}

#[test]
fn open_ops_are_one_to_sixteen_unique_op_names() {
    let bad = [
        json!([]),
        json!(["octo.ssh.open", "octo.ssh.open"]),
        json!(["Not An Op"]),
        json!((0..17).map(|i| format!("octo.ssh.op{i}")).collect::<Vec<_>>()),
    ];
    for open_ops in bad {
        let m =
            manifest("cmux.terminal.backend/1", json!({ "kinds": ["ssh"], "openOps": open_ops }));
        assert!(
            errors(&m).iter().any(|(_, code)| *code == "interface.options"),
            "{open_ops}: {:?}",
            errors(&m)
        );
    }
}

#[test]
fn every_open_op_must_be_in_the_apps_catalog() {
    let m = manifest(
        "cmux.terminal.connector/1",
        json!({ "kinds": ["ssh"], "openOps": ["octo.ssh.open", "octo.ssh.missing"] }),
    );
    // A manifest-only check has no catalog to compare with.
    assert_eq!(errors(&m), vec![]);
    let got: Vec<(String, &str)> =
        validate_catalog(&m, &catalog(&["octo.ssh.open", "octo.ssh.list"]))
            .into_iter()
            .map(|i| (i.path, i.code))
            .collect();
    assert_eq!(
        got,
        vec![(
            "/implements/cmux.terminal.connector~11/options/openOps/1".to_string(),
            "catalog.openOpUnknown"
        )]
    );
    assert!(validate_catalog(&m, &catalog(&["octo.ssh.open", "octo.ssh.missing"])).is_empty());
}
