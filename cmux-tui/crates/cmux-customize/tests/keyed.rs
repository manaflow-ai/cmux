//! Palette commands and sidebar sections in profiles: `actions.<id>` is one
//! key per command, so two palette packs stack and each turns off alone;
//! only the person applies a profile that brings commands (they run shell
//! commands); `sidebar.sections.hidden` / `order` are settings like any other.

use std::fs;
use std::path::PathBuf;

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Error, Roots};
use serde_json::{Value, json};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        home.write(
            "cmux-next.json",
            "{\n  // mine\n  \"actions\": { \"mine\": { \"command\": \"echo mine\" } }\n}\n",
        );
        home
    }

    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }

    fn write(&self, path: &str, text: &str) {
        let file = self.config(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }

    fn settings(&self) -> Value {
        let text = fs::read_to_string(self.config("cmux-next.json")).unwrap();
        cmux_config::jsonc::parse(&text).unwrap()
    }

    fn action_ids(&self) -> Vec<String> {
        let settings = self.settings();
        let mut ids: Vec<String> = settings["actions"]
            .as_object()
            .map(|actions| actions.keys().cloned().collect())
            .unwrap_or_default();
        ids.sort();
        ids
    }
}

fn profile(name: &str, settings: Value) -> Profile {
    serde_json::from_value(json!({"cmuxProfile": 1, "name": name, "settings": settings})).unwrap()
}

fn deploy_pack() -> Profile {
    profile(
        "deploy-pack",
        json!({
            "actions.deploy": {"title": "Deploy", "command": "make deploy"},
            "actions.git.push": {"title": "Push", "command": "git push", "icon": "arrow.up"},
            "sidebar.sections.hidden": ["recents"],
        }),
    )
}

fn review_pack() -> Profile {
    profile(
        "review-pack",
        json!({
            "actions.review": {"type": "agent", "agent": "claude", "args": "-p review"},
            "sidebar.sections.order": ["projects", "pinned"],
        }),
    )
}

#[test]
fn a_profile_brings_commands_one_key_each_and_keeps_yours() {
    let home = Home::new();
    let customize = home.customize();
    customize.preview_profile(&deploy_pack(), "cli", 10).unwrap();
    customize.apply(None, "cli", 11).unwrap();
    assert_eq!(home.action_ids(), ["deploy", "git.push", "mine"]);
    let settings = home.settings();
    assert_eq!(settings["actions"]["deploy"]["command"], "make deploy");
    assert_eq!(settings["sidebar"]["sections"]["hidden"], json!(["recents"]));
}

#[test]
fn two_palette_packs_stack_and_each_turns_off_alone() {
    let home = Home::new();
    let customize = home.customize();
    customize.preview_profile(&deploy_pack(), "cli", 10).unwrap();
    let deploy = customize.apply(None, "cli", 11).unwrap().library.expect("an entry");
    customize.preview_profile(&review_pack(), "cli", 20).unwrap();
    customize.apply(None, "cli", 21).unwrap();
    assert_eq!(home.action_ids(), ["deploy", "git.push", "mine", "review"]);

    customize.library_set_on(&deploy, false, "cli", 30).unwrap();
    assert_eq!(home.action_ids(), ["mine", "review"], "only the deploy pack's commands went");
    let settings = home.settings();
    assert!(settings["sidebar"]["sections"].get("hidden").is_none());
    assert_eq!(settings["sidebar"]["sections"]["order"], json!(["projects", "pinned"]));

    customize.library_set_on(&deploy, true, "cli", 40).unwrap();
    assert_eq!(home.action_ids(), ["deploy", "git.push", "mine", "review"]);
}

#[test]
fn an_agent_may_not_apply_or_switch_commands() {
    let home = Home::new();
    let customize = home.customize();
    match customize.preview_profile(&deploy_pack(), "mcp", 10) {
        Err(Error::Profile(why)) => {
            assert!(why.contains("actions.deploy") && why.contains("only you can apply"), "{why}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(home.action_ids(), ["mine"], "nothing was written");

    // Sidebar sections alone are an agent's to set.
    let sections = profile("sections", json!({"sidebar.sections.hidden": ["recents"]}));
    customize.preview_profile(&sections, "mcp", 20).unwrap();
    customize.discard("mcp", 21).unwrap();

    // The person applied the pack; an agent cannot turn it off or on.
    customize.preview_profile(&deploy_pack(), "cli", 30).unwrap();
    let deploy = customize.apply(None, "cli", 31).unwrap().library.expect("an entry");
    match customize.library_set_on(&deploy, false, "mcp", 40) {
        Err(Error::Protected(keys)) => {
            assert!(keys.contains(&"actions.deploy".to_owned()), "{keys:?}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(home.action_ids(), ["deploy", "git.push", "mine"]);
}

#[test]
fn a_command_or_section_list_the_app_would_refuse_is_refused_whole() {
    let home = Home::new();
    let customize = home.customize();
    for (key, value) in [
        ("actions.deploy", json!({"title": "No command"})),
        ("actions.deploy", json!("make deploy")),
        ("actions.deploy", json!({"command": "x", "target": "elsewhere"})),
        ("actions.review", json!({"agent": "claude --yolo"})),
        ("sidebar.sections.hidden", json!(["recents", "recents"])),
        ("sidebar.sections.order", json!([""])),
    ] {
        let settings = Value::Object(serde_json::Map::from_iter([(key.to_owned(), value)]));
        match customize.preview_profile(&profile("bad", settings), "cli", 1) {
            Err(Error::Profile(why)) => assert!(why.contains(key), "{key}: {why}"),
            other => panic!("{key}: {other:?}"),
        }
    }
    assert_eq!(home.action_ids(), ["mine"]);
}

#[test]
fn a_saved_profile_carries_each_command_as_its_own_key() {
    let home = Home::new();
    let customize = home.customize();
    let saved = customize.save_profile("mine", "", 1).unwrap();
    let text = fs::read_to_string(&saved.path).unwrap();
    let profile: Profile = serde_json::from_str(&text).unwrap();
    assert_eq!(profile.settings.get("actions.mine"), Some(&json!({"command": "echo mine"})));
    assert!(!profile.settings.contains_key("actions"));
}

#[test]
fn the_customize_schema_lists_actions_and_sidebar_sections() {
    let schema = cmux_customize::schema::Schema::current();
    let actions = schema.setting("actions").expect("actions");
    assert!(!actions.agent_settable);
    for key in ["sidebar.sections.hidden", "sidebar.sections.order"] {
        assert!(schema.setting(key).expect(key).agent_settable, "{key}");
    }
}
