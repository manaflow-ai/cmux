//! A look or profile hides and orders sidebar sections (hq RFD 0008 G16).
//! `sidebar.sections.hidden` / `order` were documented but were no settings
//! rows, so `check_profile` refused a profile that set them as "not one this
//! cmux has". It now takes them, writes them where the sidebar reads them
//! (`sidebar.sections` in cmux-next.json), and refuses a value the sidebar
//! planner would drop.

use std::fs;

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Error, Roots};
use serde_json::{Value, json};

const MINE: &str = "{\n  \"sidebar\": { \"density\": \"expanded\" }\n}\n";

fn profile(settings: Value) -> Profile {
    serde_json::from_value(json!({ "cmuxProfile": 1, "name": "sections", "settings": settings }))
        .unwrap()
}

fn home() -> (tempfile::TempDir, Customize) {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config");
    fs::create_dir_all(&config).unwrap();
    fs::write(config.join("cmux-next.json"), MINE).unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    (dir, customize)
}

fn settings(dir: &tempfile::TempDir) -> Value {
    let text = fs::read_to_string(dir.path().join("config").join("cmux-next.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

#[test]
fn a_profile_hides_and_orders_sidebar_sections() {
    let (dir, customize) = home();
    let begun = customize
        .preview_profile(
            &profile(json!({
                "sidebar.sections.hidden": ["recents"],
                "sidebar.sections.order": ["projects", "pinned"],
            })),
            "cli",
            1,
        )
        .expect("a profile may set sidebar.sections.hidden and order");
    assert_eq!(begun.draft.asks[0].text, "profile sections");
    let written = settings(&dir);
    // The path SidebarProjectionCustomizationResolver reads, beside the person's own keys.
    assert_eq!(
        written["sidebar"]["sections"],
        json!({ "hidden": ["recents"], "order": ["projects", "pinned"] })
    );
    assert_eq!(written["sidebar"]["density"], json!("expanded"));
}

#[test]
fn an_agent_profile_may_set_sidebar_sections() {
    let (dir, customize) = home();
    customize
        .preview_profile(&profile(json!({ "sidebar.sections.hidden": ["recents"] })), "mcp", 1)
        .expect("an agent may apply a look that hides a section");
    assert_eq!(settings(&dir)["sidebar"]["sections"]["hidden"], json!(["recents"]));
}

#[test]
fn a_profile_with_a_section_list_the_sidebar_drops_writes_nothing() {
    let too_many: Vec<String> = (0..257).map(|index| format!("section-{index}")).collect();
    for value in [
        json!("recents"),
        json!([""]),
        json!(["pinned", "pinned"]),
        json!([1]),
        json!(["s".repeat(129)]),
        json!(too_many),
        json!({ "hidden": ["recents"] }),
    ] {
        for key in ["sidebar.sections.hidden", "sidebar.sections.order"] {
            let (dir, customize) = home();
            let result =
                customize.preview_profile(&profile(json!({ key: value.clone() })), "cli", 1);
            match result {
                Err(Error::Profile(why)) => {
                    assert!(
                        why.contains(key) && why.contains("not one that setting accepts"),
                        "{why}"
                    );
                }
                other => panic!("{key} = {value}: {other:?}"),
            }
            assert_eq!(
                fs::read_to_string(dir.path().join("config").join("cmux-next.json")).unwrap(),
                MINE
            );
        }
    }
}
