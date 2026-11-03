//! The customize app example agents copy (skills/cmux-customization/references/local-app-views.md)
//! is a valid package as written: its manifest passes the validator the daemon runs (manifest
//! v2), and every implementation's export is defined and handed to cmux in `__cmuxAppExports`.

use std::path::Path;

use cmux_app_manifest::validate_package;

/// Module named `apps` so `--filter apps::` selects it with the other app platform tests.
mod apps {
    use super::*;

    /// The first fenced block of `lang` after `heading`.
    fn block<'a>(doc: &'a str, heading: &str, lang: &str) -> &'a str {
        let after = &doc[doc.find(heading).unwrap_or_else(|| panic!("no {heading}"))..];
        let open = format!("```{lang}\n");
        let start = after.find(&open).unwrap_or_else(|| panic!("no {lang} block after {heading}"))
            + open.len();
        let len = after[start..].find("```").expect("closed block");
        &after[start..start + len]
    }

    #[test]
    fn the_documented_customize_app_is_a_valid_package() {
        let doc_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../skills/cmux-customization/references/local-app-views.md");
        let doc = std::fs::read_to_string(&doc_path).expect("doc");
        let manifest = block(&doc, "## The manifest", "json");
        let script = block(&doc, "## The script", "js");

        let dir = std::env::temp_dir()
            .join(format!("cmux-customize-example-{}", std::process::id()))
            .join("customize");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cmux-app.json"), manifest).unwrap();
        std::fs::write(dir.join("main.js"), script).unwrap();

        // The customize folder's manifest is read as `cmux-app.json` (catalog::manifest_file).
        let report = validate_package(&dir);
        assert!(report.is_valid(), "{:?}", report.issues);
        let manifest = report.manifest.expect("manifest");
        assert_eq!(manifest["manifestVersion"], 2);
        assert_eq!(manifest["id"], "local/customize");
        assert_eq!(
            manifest.pointer("/implements/cmux.section~11/options/defaultRegion"),
            Some(&serde_json::json!("bottom"))
        );

        let exports = &script[script.find("globalThis.__cmuxAppExports = {").expect("exports")..];
        for interface in ["cmux.section/1", "cmux.session.info.section/1"] {
            let export = manifest["implements"][interface]["export"]
                .as_str()
                .unwrap_or_else(|| panic!("{interface} has no export"));
            assert!(script.contains(&format!("function {export}(")), "{export} is not defined");
            assert!(exports.contains(export), "{export} is not exported");
        }
        assert!(!script.contains("\nexport "), "main.js is a classic script");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }
}
