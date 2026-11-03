//! The customize app example agents copy (skills/cmux-customization/references/local-app-views.md)
//! is a valid package as written: its manifest passes the validator, and every
//! section's render function is defined and handed to cmux in `__cmuxAppExports`.

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

        let report = validate_package(&dir);
        assert!(report.is_valid(), "{:?}", report.issues);
        let manifest = report.manifest.expect("manifest");
        assert_eq!(manifest["id"], "local/customize");
        assert_eq!(manifest["contributes"]["sidebarSections"][0]["defaultRegion"], "bottom");

        let exports = &script[script.find("globalThis.__cmuxAppExports = {").expect("exports")..];
        for kind in ["sidebarSections", "sessionInfoSections"] {
            let sections = manifest["contributes"][kind].as_array().expect(kind);
            assert!(!sections.is_empty(), "{kind}");
            for section in sections {
                let render = section["render"].as_str().expect("render");
                assert!(script.contains(&format!("function {render}(")), "{render} is not defined");
                assert!(exports.contains(render), "{render} is not exported");
            }
        }
        assert!(!script.contains("\nexport "), "main.js is a classic script");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }
}
