use std::path::{Path, PathBuf};

use super::*;

fn skill_dir(part: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../skills/cmux-extension-author").join(part)
}

fn stems(part: &str) -> Vec<String> {
    let mut stems: Vec<String> = std::fs::read_dir(skill_dir(part))
        .expect("skill folder")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|x| x == "md"))
        .map(|path| path.file_stem().unwrap().to_string_lossy().into_owned())
        .filter(|stem| stem != "README")
        .collect();
    stems.sort();
    stems
}

#[test]
fn every_recipe_page_is_a_surface() {
    let mut listed: Vec<String> = RECIPES.iter().map(|(name, _)| (*name).to_owned()).collect();
    listed.sort();
    assert_eq!(listed, stems("recipes"), "add the new recipe page to RECIPES in customize/docs.rs");
}

#[test]
fn every_prompt_page_is_listed() {
    let mut listed: Vec<String> = PROMPTS.iter().map(|(name, _)| (*name).to_owned()).collect();
    listed.sort();
    assert_eq!(listed, stems("prompts"), "add the new prompt page to PROMPTS in customize/docs.rs");
}

#[test]
fn every_surface_names_what_this_build_has() {
    let schema = Schema::current();
    for (what, keys) in SURFACE_KEYS {
        for key in *keys {
            assert!(schema.setting(key).is_some(), "{what}: {key} is not a setting");
        }
    }
    for (name, page) in RECIPES {
        if let Some(interface) = interface_of(page) {
            assert!(
                schema.extension_points.iter().any(|point| point.interface == interface),
                "{name}: {interface} is not an interface of this build"
            );
        }
    }
    let names = surface_names();
    let mut unique = names.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), names.len(), "{names:?}");
    assert_eq!(surfaces(&schema).len(), names.len(), "a surface with no reference");
    for surface in surfaces(&schema) {
        assert!(surface.text.contains("Prove it"), "{}: no proof line", surface.name);
        if surface.kind == "extension" {
            assert!(
                surface.text.contains("```json cmux-app.json"),
                "{}: no manifest",
                surface.name
            );
        }
    }
}

#[test]
fn every_prompt_points_at_a_surface_and_says_how_it_is_checked() {
    let names = surface_names();
    for prompt in prompts() {
        assert!(!prompt.prompt.is_empty(), "{}: no ```text prompt", prompt.name);
        assert!(
            prompt.page.contains("<!-- prompt-check: "),
            "{}: no prompt-check line",
            prompt.name
        );
        let docs: Vec<&str> = prompt
            .prompt
            .split("cmux customize docs ")
            .skip(1)
            .filter_map(|rest| rest.split(|c: char| c == '`' || c.is_whitespace()).next())
            .collect();
        assert!(
            !docs.is_empty(),
            "{}: the prompt names no `cmux customize docs SURFACE`",
            prompt.name
        );
        for surface in docs {
            assert!(names.contains(&surface), "{}: {surface} is not a surface", prompt.name);
        }
        assert!(prompt.prompt.contains("cmux ext dev --once --json"), "{}", prompt.name);
        assert!(prompt.prompt.contains("cmux ext dev --once --headless --json"), "{}", prompt.name);
    }
}

#[test]
fn docs_and_prompts_answer_before_any_store() {
    let docs = super::super::parse(&["docs".to_owned(), "section".to_owned()]).unwrap();
    let (text, json) = answer(&docs).expect("section is a surface");
    assert!(text.contains("cmux.section/1"), "{text}");
    assert_eq!(json["kind"], "extension");
    let sidebar = super::super::parse(&["docs".to_owned(), "sidebar".to_owned()]).unwrap();
    let (text, _) = answer(&sidebar).unwrap();
    assert!(text.contains("sidebar.density") && text.contains("cmux settings set"), "{text}");
    assert!(super::super::parse(&["docs".to_owned(), "nope".to_owned()]).is_err());
    let keys = super::super::parse(&["docs".to_owned(), "keybindings".to_owned()]).unwrap();
    let (text, _) = answer(&keys).unwrap();
    assert!(text.contains("`palette.open`") && text.contains("cmd+"), "{text}");
    assert!(text.contains("## `when` clauses") && text.contains("`diffViewerFocused`"), "{text}");
    let actions = super::super::parse(&["docs".to_owned(), "actions".to_owned()]).unwrap();
    let (text, _) = answer(&actions).unwrap();
    let public = cmux_action_catalog::actions().filter(|action| !action.is_debug_only);
    for action in public {
        assert!(text.contains(&format!("- `{}`: ", action.id)), "actions misses {}", action.id);
    }
    let motion = super::super::parse(&["docs".to_owned(), "motion".to_owned()]).unwrap();
    let (text, _) = answer(&motion).unwrap();
    assert!(text.contains("ui.animations.enabled") && text.contains("`quick`: 80 ms"), "{text}");
    let prompts = super::super::parse(&["prompts".to_owned()]).unwrap();
    let (_, json) = answer(&prompts).unwrap();
    assert_eq!(json["prompts"].as_array().map(Vec::len), Some(PROMPTS.len()));
}
