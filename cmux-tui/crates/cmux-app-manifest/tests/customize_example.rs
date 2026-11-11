//! The customize app example agents copy (skills/cmux-customization/references/local-app-views.md)
//! is a valid package as written: its manifest passes the validator the daemon runs (manifest
//! v2), and every implementation's export is defined and handed to cmux in `__cmuxAppExports`.
//! The copy-paste folders in skills/cmux-customization/templates are held to the same line.

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

    /// The names in the one `globalThis.__cmuxAppExports = { ... }` object.
    ///
    /// Read as names, not as text: a substring search finds `render` in `renderPane`, so a
    /// manifest naming an export the script never hands over would pass.
    fn exported_names(script: &str) -> Vec<&str> {
        let open = "globalThis.__cmuxAppExports = {";
        let start = script.find(open).expect("exports") + open.len();
        let len = script[start..].find('}').expect("the exports object is closed");
        script[start..start + len]
            .split(',')
            .map(|entry| entry.split(':').next().unwrap_or("").trim())
            .filter(|name| !name.is_empty())
            .collect()
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

        let exported = exported_names(script);
        for interface in ["cmux.section/1", "cmux.session.info.section/1"] {
            let export = manifest["implements"][interface]["export"]
                .as_str()
                .unwrap_or_else(|| panic!("{interface} has no export"));
            assert!(script.contains(&format!("function {export}(")), "{export} is not defined");
            assert!(exported.contains(&export), "{export} is not exported, {exported:?} is");
        }
        assert!(!script.contains("\nexport "), "main.js is a classic script");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    /// The "Matching the app" template (a focus timer built only from the kit) is a valid package too.
    #[test]
    fn the_documented_focus_timer_template_is_a_valid_package() {
        let doc_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../skills/cmux-customization/references/local-app-views.md");
        let doc = std::fs::read_to_string(&doc_path).expect("doc");
        let manifest = block(&doc, "#### Focus timer manifest", "json");
        let script = block(&doc, "#### Focus timer script", "js");

        let dir = std::env::temp_dir()
            .join(format!("cmux-customize-template-{}", std::process::id()))
            .join("customize");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cmux-app.json"), manifest).unwrap();
        std::fs::write(dir.join("main.js"), script).unwrap();

        let report = validate_package(&dir);
        assert!(report.is_valid(), "{:?}", report.issues);
        let manifest = report.manifest.expect("manifest");
        assert_eq!(manifest["id"], "local/customize");
        let export = manifest["implements"]["cmux.section/1"]["export"].as_str().expect("export");
        assert!(script.contains(&format!("function {export}(")), "{export} is not defined");
        assert_eq!(exported_names(script), [export], "the template exports just its one view");
        for piece in ["Panel(", "Toggle(", "Slider(", "Row(", "Button(", "Menu(", "cmux.toast("] {
            assert!(script.contains(piece), "the template uses {piece}");
        }
        assert!(!script.contains('#'), "no literal colors");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    /// Every folder in skills/cmux-customization/templates is a customize app as written: a
    /// valid package, each implementation's export defined and in the one `__cmuxAppExports`,
    /// a classic script, and only tone names for color.
    #[test]
    fn every_template_folder_is_a_valid_customize_app() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../skills/cmux-customization/templates");
        let mut names: Vec<String> = std::fs::read_dir(&root)
            .expect("templates")
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(
            names,
            [
                "clock-weather",
                "command-button",
                "design-links",
                "my-prs",
                "pane",
                "sidebar-section",
                "starter",
                "threads"
            ]
        );
        for name in names {
            let dir = root.join(&name);
            let report = validate_package(&dir);
            assert!(report.is_valid(), "{name}: {:?}", report.issues);
            let manifest = report.manifest.expect("manifest");
            assert_eq!(manifest["manifestVersion"], 2, "{name}");
            assert_eq!(manifest["id"], "local/customize", "{name}");
            let script = std::fs::read_to_string(dir.join("main.js")).expect("main.js");
            assert_eq!(
                script.matches("__cmuxAppExports =").count(),
                1,
                "{name}: one exports object"
            );
            let exported = exported_names(&script);
            let implements = manifest["implements"].as_object().expect("implements");
            assert!(implements.contains_key("cmux.section/1"), "{name} has a sidebar section");
            for (interface, entry) in implements {
                let export =
                    entry["export"].as_str().unwrap_or_else(|| panic!("{name}: {interface}"));
                assert!(
                    script.contains(&format!("function {export}(")),
                    "{name}: {export} is not defined"
                );
                assert!(
                    exported.contains(&export),
                    "{name}: {export} is not exported, {exported:?} is"
                );
            }
            let named: Vec<&str> =
                implements.values().filter_map(|entry| entry["export"].as_str()).collect();
            for export in &exported {
                assert!(
                    named.contains(export),
                    "{name}: {export} is exported but implements nothing"
                );
            }
            assert!(
                !script.contains("\nexport ") && !script.contains("\nimport "),
                "{name}: classic script"
            );
            assert!(!script.contains('#'), "{name}: no literal colors");
        }
    }
}
