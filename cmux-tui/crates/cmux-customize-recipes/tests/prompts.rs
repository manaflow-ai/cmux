//! Every copy-paste prompt `cmux customize docs` and the recipe guide print points at a
//! working artifact: a recipe or profile the engine previews with no problem, an extension
//! package the manifest validator takes, or a theme pack whose slot variant the registry has.
//! The docs tables are held to the registries they describe.

use std::path::{Path, PathBuf};

use cmux_config::domains::Domains;
use cmux_config::schema::Schema;
use cmux_customize::docs::{self, Artifact, INTERFACE_REACH, KIT, PROMPTS, SURFACES};
use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Roots};
use cmux_customize_recipes::{GUIDE, find, problems};
use serde_json::{Map, Value, json};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// Previews the profile on a fresh setup: it must validate with no problem, then discard.
fn preview(profile: &Profile, what: &str) {
    let found = problems(profile);
    assert!(found.is_empty(), "{what}: {found:?}");
    let home = tempfile::tempdir().unwrap();
    let roots = Roots::under(home.path());
    std::fs::create_dir_all(&roots.config_dir).unwrap();
    std::fs::write(&roots.settings_file, "{}\n").unwrap();
    let customize = Customize::open(roots);
    customize.ensure_baseline(1).unwrap();
    customize
        .preview_profile(profile, "test", 2)
        .unwrap_or_else(|error| panic!("{what}: the engine refused it: {error}"));
    let status = customize.status().unwrap();
    assert!(status.problems.is_empty(), "{what}: {:?}", status.problems);
    customize.discard("test", 3).unwrap();
}

fn package(dir: &Path, what: &str) {
    let report = cmux_app_manifest::validate_package(dir);
    assert!(report.is_valid(), "{what}: {:?}", report.issues);
}

/// The ```json cmux-app.json block of an extension recipe page.
fn manifest_block(page: &str) -> &str {
    let start = page.find("```json cmux-app.json\n").expect("a ```json cmux-app.json block");
    let body = &page[start + "```json cmux-app.json\n".len()..];
    &body[..body.find("```").expect("the block's end")]
}

#[test]
fn every_prompt_artifact_installs_or_validates() {
    for prompt in PROMPTS {
        let what = prompt.id;
        match &prompt.artifact {
            Artifact::Recipe(name) => {
                let recipe = find(name).unwrap_or_else(|| panic!("{what}: no recipe {name}"));
                preview(&recipe.profile().unwrap(), what);
            }
            Artifact::Profile(path) => {
                let text = std::fs::read_to_string(repo().join(path)).unwrap();
                let profile: Profile = serde_json::from_str(&text)
                    .unwrap_or_else(|error| panic!("{what}: {path} is not a profile: {error}"));
                for (file, body) in &profile.files {
                    if file.ends_with(".js") {
                        let found = docs::motion_problems(body);
                        assert!(found.is_empty(), "{what}: {file}: {found:?}");
                    }
                }
                preview(&profile, what);
            }
            Artifact::Package(path) => package(&repo().join(path), what),
            Artifact::SkillRecipe(path) => {
                let page = std::fs::read_to_string(repo().join(path)).unwrap();
                let dir = tempfile::tempdir().unwrap();
                std::fs::write(dir.path().join("cmux-app.json"), manifest_block(&page)).unwrap();
                package(dir.path(), what);
            }
            Artifact::ThemePack(path) => {
                static DOMAINS: std::sync::OnceLock<Domains> = std::sync::OnceLock::new();
                let base = json!({});
                let context = cmux_theme_pack::Context {
                    schema: Schema::embedded(),
                    domains: DOMAINS.get_or_init(Domains::default),
                    base: &base,
                };
                let pack = cmux_theme_pack::load(&repo().join(path), &Map::new(), &context)
                    .unwrap_or_else(|error| panic!("{what}: the pack did not load: {error:?}"));
                let slots = pack.theme.get("slots").and_then(Value::as_object).cloned();
                let slots = slots.unwrap_or_else(|| panic!("{what}: the pack sets no slot"));
                let registry = docs::slot_variants();
                for (slot, variant) in &slots {
                    let known = registry.iter().find(|(id, _)| id == slot);
                    let known = known.unwrap_or_else(|| panic!("{what}: no slot {slot}"));
                    let variant = variant.as_str().unwrap_or_default();
                    assert!(
                        known.1.iter().any(|v| v == variant),
                        "{what}: {slot} has no {variant}"
                    );
                    assert!(prompt.text.contains(slot.as_str()), "{what}: the prompt names {slot}");
                }
            }
        }
    }
}

#[test]
fn the_guide_prints_every_prompt_verbatim() {
    for prompt in PROMPTS {
        assert!(GUIDE.contains(prompt.text), "the guide lacks the {} prompt", prompt.id);
        assert!(GUIDE.contains(prompt.title), "the guide lacks the {} title", prompt.id);
        assert!(SURFACES.iter().any(|(name, ..)| *name == prompt.surface), "{}", prompt.id);
    }
    assert!(GUIDE.contains("cmux customize docs") && GUIDE.contains("--card"));
}

#[test]
fn every_interface_is_placed_and_every_placed_one_exists() {
    let shipped: Vec<String> = docs::interfaces().into_iter().map(|(name, ..)| name).collect();
    for name in &shipped {
        assert!(docs::interface_reach(name).is_some(), "{name} is not in INTERFACE_REACH");
    }
    for (name, _) in INTERFACE_REACH {
        assert!(shipped.iter().any(|s| s == name), "INTERFACE_REACH names {name}, not shipped");
    }
}

#[test]
fn the_kit_table_names_real_scene_views_and_web_exports() {
    let (views, modifiers) = docs::scene_api();
    let index = std::fs::read_to_string(repo().join("webviews/src/kit/index.ts")).unwrap();
    let words: Vec<&str> =
        index.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).collect();
    for (name, scene, web, _) in KIT {
        if let Some(scene) = scene {
            assert!(views.iter().any(|(view, _)| view == scene), "{name}: no scene {scene}");
        }
        if let Some(web) = web {
            assert!(words.contains(web), "{name}: kit/index.ts exports no {web}");
        }
    }
    for modifier in ["animation", "transition", "contentTransition"] {
        assert!(modifiers.iter().any(|m| m == modifier), "the d.ts lacks .{modifier}");
    }
}

#[test]
fn docs_cover_every_surface_and_refuse_an_unknown_one() {
    let all = docs::docs(None).unwrap();
    assert_eq!(all.len(), SURFACES.len());
    for surface in &all {
        assert!(!surface.items.is_empty(), "{} has no item", surface.name);
        let one = docs::docs(Some(surface.name)).unwrap();
        assert_eq!(one.len(), 1);
    }
    assert!(docs::docs(Some("bogus")).is_err());
    let card = docs::card();
    for key in ["schema", "surfaces", "buildFrom", "kitGallery", "kit", "motion", "prompts"] {
        assert!(card.get(key).is_some(), "the card lacks {key}");
    }
    assert_eq!(card["kitGallery"], docs::KIT_GALLERY);
    let text = docs::card_text();
    assert!(text.contains("cmux customize docs"), "{text}");
}

#[test]
fn motion_problems_flags_a_value_cmux_motion_lacks() {
    assert!(docs::motion_problems(r#"Text(x).animation("smooth")"#).is_empty());
    assert!(!docs::motion_problems(r#"Text(x).transition("wobble")"#).is_empty());
}
