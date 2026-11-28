//! The manifest passes the one validator (`cmux-app-manifest`, by path) as
//! an unverified third-party app: no errors, and no scope that such an app
//! cannot hold.

use cmux_app_manifest::{Severity, validate_package_file};
use std::path::Path;

fn app_dir() -> &'static Path {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/.."))
}

#[test]
fn manifest_validates_as_a_third_party_app() {
    let report = validate_package_file(app_dir(), "cmux-app.v2.json");
    let errors: Vec<_> = report.issues.iter().filter(|i| i.severity == Severity::Error).collect();
    assert!(errors.is_empty(), "{errors:?}");
    let warnings: Vec<_> = report.issues.iter().filter(|i| i.code == "scope.restricted").collect();
    assert!(warnings.is_empty(), "an unverified app holds no restricted scope: {warnings:?}");
    let manifest = report.manifest.expect("manifest parsed");
    assert_eq!(manifest["id"], ssh_terminal::APP_ID);
    assert_eq!(manifest["handles"]["connection"]["kinds"], serde_json::json!(["ssh"]));
    assert!(
        manifest["handles"].get("credential").is_none(),
        "the host owns the SSH transport and the key: the app asks for no credential handle"
    );
    assert!(manifest.get("server").is_none(), "no first-party native server tier");
    assert!(
        manifest.get("implements").is_none(),
        "implements waits for app platform approval; the target shape is in the README"
    );
}
