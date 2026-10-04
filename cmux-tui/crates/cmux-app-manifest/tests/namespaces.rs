//! Third-party scope and op families live in the app's own namespace
//! (`<publisher>.<name>`, '-' -> '_'; app-platform.md 18): two apps cannot
//! collide on `hello:read`, and no third party defines `git:*`.

use cmux_app_manifest::{ScopeClass, app_namespace, scope_info, validate_catalog, validate_manifest};
use serde_json::{Value, json};

fn third_party() -> Value {
    json!({ "manifestVersion": 2, "id": "octo/ssh-terminal", "name": "SSH", "version": "1.0.0", "description": "d",
        "repository": "https://github.com/octo/ssh-terminal", "engines": { "cmux": "^2.0" }, "icon": "icon.png" })
}

fn op(name: &str, owner: &str) -> Value {
    json!({ "name": name, "owner": owner, "class": "read", "risk": "read", "idempotency": "forbidden",
        "input": { "type": "object" }, "docs": "d", "since": "1" })
}

#[test]
fn the_namespace_of_an_app_id() {
    assert_eq!(app_namespace("octo/ssh-terminal"), "octo.ssh_terminal");
    assert_eq!(app_namespace("cmux/remote-desktop"), "cmux.remote_desktop");
}

#[test]
fn third_party_catalogs_use_their_own_namespace() {
    let m = third_party();
    let owner = "app:octo/ssh-terminal";
    let own = json!({ "family": "octo.ssh_terminal", "operations": [op("octo.ssh_terminal.hosts.list", owner)] });
    assert!(validate_catalog(&m, &own).is_empty(), "{:?}", validate_catalog(&m, &own));
    for family in ["git", "hello", "other.app"] {
        let bad = json!({ "family": family, "operations": [op(&format!("{family}.list"), owner)] });
        assert!(validate_catalog(&m, &bad).iter().any(|i| i.code == "catalog.namespace"), "{family}");
    }
}

#[test]
fn namespaced_scopes_parse_and_classify() {
    assert_eq!(scope_info("octo.ssh_terminal:read").map(|i| i.class), Some(ScopeClass::Standard));
    assert_eq!(scope_info("octo.ssh_terminal:write").map(|i| i.class), Some(ScopeClass::Sensitive));
    let mut m = third_party();
    m["scopes"] = json!({ "octo.ssh_terminal:read": "List your saved hosts.", "git:read": "Read diffs." });
    assert!(validate_manifest(&m).iter().all(|i| i.code != "schema"), "{:?}", validate_manifest(&m));
}
