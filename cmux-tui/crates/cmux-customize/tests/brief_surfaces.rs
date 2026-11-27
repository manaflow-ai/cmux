//! The surfaces a person names in the chat ("denser sidebar", "particles behind it", "the studio
//! composer"): the brief names each one's key, every key is one this build's settings schema has
//! and lets an agent set, and a preview of them all is undone by one discard.

use std::fs;

use cmux_config::schema::Schema as Settings;
use cmux_customize::{Customize, Roots, SURFACE_KEYS, brief};

#[test]
fn every_surface_key_is_a_setting_an_agent_may_set() {
    let settings = Settings::embedded();
    for (surface, keys) in SURFACE_KEYS {
        for key in *keys {
            let row = settings.row(key).unwrap_or_else(|| panic!("{surface}: no setting {key}"));
            assert!(row.agent_settable, "{surface}: {key} is refused to agents");
        }
    }
}

#[test]
fn the_brief_names_every_surface_key_and_how_to_find_a_toggle() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let text = brief("make the sidebar denser", customize.roots(), &customize.status().unwrap());
    for (_, keys) in SURFACE_KEYS {
        for key in *keys {
            assert!(text.contains(&format!("`{key}`")), "the brief misses {key}:\n{text}");
        }
    }
    assert!(text.contains("live:particles"), "{text}");
    assert!(text.contains("cmux settings list | grep -i"), "{text}");
    assert!(text.contains("cmux customize use NAME"), "{text}");
}

#[test]
fn five_surfaces_preview_together_and_one_discard_undoes_them() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("config").join("cmux-next.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let before = "{\n  \"appearance\": { \"density\": \"cozy\" }\n}\n";
    fs::write(&file, before).unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    customize
        .begin("denser sidebar, particles, studio composer, card chrome, hide a section", "mcp", 1)
        .unwrap();

    fs::write(
        &file,
        r#"{
  "appearance": { "density": "compact", "chromeStyle": "card", "background": "live:particles" },
  "sidebar": { "density": "compact", "sections": { "hidden": ["recents"] } },
  "agentPane": { "composerLook": "studio" }
}
"#,
    )
    .unwrap();
    let status = customize.status().unwrap();
    assert!(status.problems.is_empty(), "{:?}", status.problems);
    assert!(status.dirty(), "the preview is a draft");

    customize.discard("cli", 2).unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), before);
    assert!(!customize.status().unwrap().dirty());
}
