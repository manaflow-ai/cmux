//! Every recipe page of the extension-author skill (skills/cmux-extension-author/recipes) is a
//! folder an author can copy as written: its files pass the validator `cmux ext dev` runs (the
//! manifest, its interfaces' options and its catalog), every export the manifest or catalog names
//! is exported by `src/main.ts`, and the page ends with the `cmux ext dev --once --json` line
//! that proves it. The skill's table lists every page. The load and the first render, with bun,
//! are `cmux-tui`'s `ext::recipes_tests`.

use std::path::{Path, PathBuf};

use cmux_app_manifest::{KNOWN_INTERFACES, Severity, validate_package};

/// Module named `apps` so `--filter apps::` selects it with the other app platform tests.
mod apps {
    use super::*;

    fn skill_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../skills/cmux-extension-author")
    }

    /// The recipe pages, by file name, sorted.
    fn recipes() -> Vec<(String, String)> {
        let mut pages: Vec<(String, String)> = std::fs::read_dir(skill_dir().join("recipes"))
            .expect("recipes folder")
            .filter_map(|entry| {
                let path = entry.ok()?.path();
                (path.extension()? == "md").then(|| {
                    let name = path.file_name().unwrap().to_string_lossy().into_owned();
                    (name, std::fs::read_to_string(&path).unwrap())
                })
            })
            .collect();
        pages.sort();
        pages
    }

    /// The page's files: each fenced block whose info string names a path (```json cmux-app.json).
    fn files(page: &str) -> Vec<(String, String)> {
        let mut out = Vec::new();
        let mut lines = page.lines();
        while let Some(line) = lines.next() {
            let Some(info) = line.strip_prefix("```") else { continue };
            let mut words = info.split_whitespace();
            let (Some(_lang), path) = (words.next(), words.next()) else { continue };
            let body: Vec<&str> = lines.by_ref().take_while(|l| !l.starts_with("```")).collect();
            if let Some(path) = path {
                out.push((path.to_string(), body.join("\n") + "\n"));
            }
        }
        out
    }

    /// The names `src/main.ts` exports (`export const NAME` or `export function NAME`).
    fn exports(script: &str) -> Vec<&str> {
        script
            .lines()
            .filter_map(|l| {
                l.strip_prefix("export const ").or_else(|| l.strip_prefix("export function "))
            })
            .filter_map(|rest| rest.split(|c: char| !c.is_alphanumeric() && c != '_').next())
            .collect()
    }

    /// The problems with one page, empty when it holds.
    fn check(name: &str, page: &str, root: &Path) -> Vec<String> {
        let mut problems = Vec::new();
        let files = files(page);
        let dir = root.join(name.trim_end_matches(".md"));
        for (path, text) in &files {
            let target = dir.join(path);
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::write(target, text).unwrap();
        }
        let source = files.iter().find(|(p, _)| p == "src/main.ts").map(|(_, t)| t.as_str());
        // As `ext dev` does before a build: a main script the build writes need not exist yet.
        let report = validate_package(&dir);
        for issue in report.issues.iter().filter(|i| i.severity == Severity::Error) {
            let built_later =
                source.is_some() && issue.path == "/runtime/main" && issue.code == "path.missing";
            if !built_later {
                problems.push(format!("{}: {} ({})", issue.path, issue.message, issue.code));
            }
        }
        let Some(manifest) = report.manifest else {
            problems.push("cmux-app.json did not parse".into());
            return problems;
        };
        let mut wanted: Vec<String> = Vec::new();
        for (interface, entry) in manifest["implements"].as_object().into_iter().flatten() {
            if !KNOWN_INTERFACES.contains(&interface.as_str()) {
                problems.push(format!("{interface} is not an interface cmux knows"));
            }
            if !page.contains(&format!("`{interface}`")) {
                problems.push(format!("the page does not name {interface}"));
            }
            wanted.extend(entry["export"].as_str().map(str::to_string));
        }
        if let Some(catalog) = files.iter().find(|(p, _)| p == "catalog.json") {
            let catalog: serde_json::Value = serde_json::from_str(&catalog.1).unwrap();
            for op in catalog["operations"].as_array().into_iter().flatten() {
                wanted.extend(op["export"].as_str().map(str::to_string));
            }
        }
        match source {
            Some(script) => {
                let have = exports(script);
                for export in &wanted {
                    if !have.contains(&export.as_str()) {
                        problems.push(format!("src/main.ts does not export {export} ({have:?})"));
                    }
                }
                if !script.contains("from \"cmux-extension-sdk\"") {
                    problems.push("src/main.ts does not import cmux-extension-sdk".into());
                }
            }
            None if !wanted.is_empty() => {
                problems.push(format!("exports {wanted:?} but no src/main.ts"));
            }
            None => {}
        }
        if manifest.get("runtime").is_some() && source.is_none() {
            problems.push("a runtime with no src/main.ts to build it".into());
        }
        if !page.contains("```sh\ncmux ext dev --once --json\n") {
            problems.push("the page does not end with the cmux ext dev --once --json proof".into());
        }
        if !page.contains("<!-- recipe-check: ") {
            problems.push("no <!-- recipe-check: --> line (what the render must show)".into());
        }
        problems
    }

    #[test]
    fn every_extension_recipe_validates_as_written() {
        let root = std::env::temp_dir().join(format!("cmux-ext-recipes-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let pages = recipes();
        assert!(pages.len() >= 9, "recipes: {:?}", pages.iter().map(|p| &p.0).collect::<Vec<_>>());
        let mut problems = Vec::new();
        for (name, page) in &pages {
            problems.extend(check(name, page, &root).into_iter().map(|p| format!("{name}: {p}")));
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(problems.is_empty(), "\n{}", problems.join("\n"));
    }

    /// The skill's table links every recipe page, and links no page that is not there.
    #[test]
    fn the_skill_lists_every_recipe() {
        let skill = std::fs::read_to_string(skill_dir().join("SKILL.md")).unwrap();
        let pages = recipes();
        for (name, _) in &pages {
            assert!(skill.contains(&format!("(recipes/{name})")), "SKILL.md does not link {name}");
        }
        for link in skill.split("(recipes/").skip(1) {
            let name = link.split(')').next().unwrap();
            assert!(pages.iter().any(|(n, _)| n == name), "SKILL.md links missing recipes/{name}");
        }
    }

    /// A page that breaks a rule is caught: a manifest naming an export the script lacks.
    #[test]
    fn a_recipe_whose_script_lacks_its_export_is_caught() {
        let (_, page) = recipes().into_iter().find(|(n, _)| n == "section.md").unwrap();
        let broken = page.replace("export const renderSection", "const renderSection");
        let root =
            std::env::temp_dir().join(format!("cmux-ext-recipes-bad-{}", std::process::id()));
        let problems = check("section.md", &broken, &root);
        let _ = std::fs::remove_dir_all(&root);
        assert!(problems.iter().any(|p| p.contains("renderSection")), "{problems:?}");
    }
}
