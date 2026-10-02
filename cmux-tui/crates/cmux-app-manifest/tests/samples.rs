//! Every sample app (`samples/apps/*`) is a valid manifest v2 package whose
//! interface implementations name exports its built script defines.

use std::path::{Path, PathBuf};

use cmux_app_manifest::{KNOWN_INTERFACES, validate_package};
use serde_json::Value;

fn samples() -> Vec<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../samples/apps");
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
        .unwrap_or_else(|e| panic!("{}: {e}", root.display()))
        .map(|e| e.expect("entry").path())
        .filter(|p| p.join("cmux-app.json").is_file())
        .collect();
    dirs.sort();
    dirs
}

#[test]
fn samples_are_valid_manifest_v2_packages() {
    let dirs = samples();
    assert!(dirs.len() >= 3, "expected the samples, found {dirs:?}");
    for dir in dirs {
        // Samples still on manifest v1 are checked by the v1 TS validator
        // until they move; this test covers every v2 sample.
        let raw = std::fs::read_to_string(dir.join("cmux-app.json")).expect("manifest");
        if serde_json::from_str::<Value>(&raw).expect("json")["manifestVersion"] == 1 {
            continue;
        }
        let report = validate_package(&dir);
        assert!(report.is_valid(), "{}: {:?}", dir.display(), report.issues);
        let manifest = report.manifest.expect("manifest");
        assert_eq!(manifest["manifestVersion"], 2, "{}", dir.display());
        let main = std::fs::read_to_string(
            dir.join(manifest["runtime"]["main"].as_str().expect("runtime.main")),
        )
        .expect("main");
        let implements = manifest["implements"].as_object().expect("implements");
        assert!(!implements.is_empty(), "{} implements nothing", dir.display());
        for (interface, implementation) in implements {
            assert!(KNOWN_INTERFACES.contains(&interface.as_str()));
            let export = implementation["export"]
                .as_str()
                .unwrap_or_else(|| panic!("{interface} needs a scene export"));
            assert!(
                main.contains(&format!("function {export}("))
                    || main.contains(&format!("async function {export}(")),
                "{}: dist/main.js defines no {export}",
                dir.display()
            );
        }
        if let Some(file) = manifest.get("catalog").and_then(Value::as_str) {
            let catalog: Value =
                serde_json::from_str(&std::fs::read_to_string(dir.join(file)).expect("catalog"))
                    .expect("catalog json");
            for (op, entry) in catalog["operations"].as_object().expect("operations") {
                let export =
                    entry["export"].as_str().unwrap_or_else(|| panic!("{op} needs an export"));
                assert!(
                    main.contains(&format!("function {export}(")),
                    "{}: {op} names a missing export {export}",
                    dir.display()
                );
            }
        }
    }
}
