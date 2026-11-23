//! Every shipped recipe is a profile the engine takes: each key is one the
//! settings schema has, each shortcut names a real action, and the engine
//! previews it as a draft that discard takes back.

use std::collections::BTreeMap;

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Roots};
use cmux_customize_recipes::{GUIDE, GUIDE_DIR, Group, RECIPES, find, guide, problems, write_all};

#[test]
fn every_shipped_recipe_names_only_keys_the_schema_has() {
    let mut found = Vec::new();
    for recipe in RECIPES {
        for problem in recipe.problems() {
            found.push(format!("{}: {problem}", recipe.name));
        }
    }
    assert!(found.is_empty(), "recipes with problems:\n{}", found.join("\n"));
}

#[test]
fn a_recipe_that_names_a_key_the_schema_lacks_is_refused() {
    let profile = Profile {
        version: 1,
        name: "typo".to_owned(),
        description: "A guessed key".to_owned(),
        created_ms: 0,
        settings: BTreeMap::from([
            ("sidebar.notARealKey".to_owned(), serde_json::json!(true)),
            ("sidebar.style".to_owned(), serde_json::json!("not-a-style")),
        ]),
        files: BTreeMap::new(),
    };
    let found = problems(&profile);
    assert!(
        found
            .iter()
            .any(|line| line.contains("sidebar.notARealKey") && line.contains("does not have")),
        "{found:?}"
    );
    assert!(found.iter().any(|line| line.contains("sidebar.style")), "{found:?}");
}

#[test]
fn every_recipe_has_a_unique_name_and_every_group_a_recipe() {
    // No fixed count: each look that ships adds its recipe without editing a number here.
    assert!(RECIPES.len() >= 10, "{} recipes", RECIPES.len());
    let mut names: Vec<_> = RECIPES.iter().map(|recipe| recipe.name).collect();
    names.sort();
    names.dedup();
    assert_eq!(names.len(), RECIPES.len(), "two recipes share a name");
    for group in Group::ALL {
        assert!(RECIPES.iter().any(|recipe| recipe.group == *group), "no recipe in {group:?}");
    }
    for name in ["compact-sidebar", "different-font", "pr-widget", "tiling-look", "pane-keys"] {
        assert!(find(name).is_some(), "the {name} recipe Leo's ask names");
    }
}

/// CMUX-642, Leo: "make customization for codex, [another agent app], claude code app
/// (everything)", "sidebar, gui, everything". Each look-alike is one profile
/// that turns on the theme file it carries, restyles the chat with its own
/// stylesheet and sets the sidebar and chat settings.
#[test]
fn each_app_look_alike_carries_its_theme_its_chat_stylesheet_and_its_settings() {
    for name in ["codex-app", "codex-app-dark", "claude-code-app"] {
        let recipe = find(name).unwrap_or_else(|| panic!("no {name} recipe"));
        assert_eq!(recipe.group, Group::Apps, "{name}");
        let profile = recipe.profile().unwrap();
        assert_eq!(
            profile.settings.get("appearance.themeFile"),
            Some(&serde_json::json!(name)),
            "{name} turns on a theme file of its own name"
        );
        let theme = profile
            .files
            .get(&format!("themes/{name}.json"))
            .unwrap_or_else(|| panic!("{name} carries no theme file"));
        assert!(cmux_config::jsonc::parse(theme).is_ok(), "{name}: its theme file is not JSONC");
        let chat = profile
            .files
            .get("agent-pane/theme.css")
            .unwrap_or_else(|| panic!("{name} carries no chat stylesheet"));
        assert!(chat.contains("--cv-bubble"), "{name}: the stylesheet leaves the prompt alone");
        for key in ["sidebar.groupBy", "agentPane.display.width", "tabs.hideLoneChatTab"] {
            assert!(profile.settings.contains_key(key), "{name} does not set {key}");
        }
        assert_eq!(recipe.parts(), ["settings", "keybindings", "themes", "styles"], "{name}");
    }
}

/// Leo, 2026-11-19: "for the Claude Code or Codex or [another agent app], like
/// the features, the functionality, the appearance for those, like we can
/// just do them". Each app recipe works like its app, not only looks like it:
/// its new-chat key starts a chat with that app's agent, and its other keys
/// open the app's panels and menus.
#[test]
fn each_app_recipe_binds_its_apps_new_chat_key_to_its_agent() {
    for (name, key, harness) in [
        ("codex-app", "cmd+shift+o", "codex"),
        ("codex-app-dark", "cmd+shift+o", "codex"),
        ("claude-code-app", "cmd+n", "claude"),
    ] {
        let profile = find(name).unwrap().profile().unwrap();
        let text =
            profile.files.get("keybindings.json").unwrap_or_else(|| panic!("{name} binds no keys"));
        let parsed = cmux_config::keybindings::parse(text);
        let entry = parsed
            .entries
            .iter()
            .find(|entry| entry.keys == [key])
            .unwrap_or_else(|| panic!("{name} does not bind {key}"));
        assert_eq!(entry.command, "palette.newAgentChat", "{name}: {key}");
        assert_eq!(entry.args, Some(serde_json::json!({ "harness": harness })), "{name}: {key}");
    }
}

/// Leo, 2026-11-22: "should we tuck it in a bit more like claude code? hm. well, we'd better at
/// least do this for our claude code customization repo". The Claude Code look starts the
/// transcript's rows on the composer's + column, derived from the composer's lead token.
#[test]
fn the_claude_code_look_tucks_the_transcript_to_the_composers_plus() {
    let profile = find("claude-code-app").expect("no claude-code-app recipe").profile().unwrap();
    let chat = profile.files.get("agent-pane/theme.css").expect("no chat stylesheet");
    assert!(chat.contains(":root .acpmux-row"), "the rows keep the composer's edge");
    assert!(
        chat.contains("var(--grid-composer-lead-center)"),
        "the tuck is not derived from the composer's + column"
    );
}

#[test]
fn every_shortcut_a_recipe_binds_is_an_action_cmux_has() {
    for recipe in RECIPES {
        let profile = recipe.profile().unwrap();
        let Some(text) = profile.files.get("keybindings.json") else { continue };
        let parsed = cmux_config::keybindings::parse(text);
        assert!(parsed.diagnostics.is_empty(), "{}: {:?}", recipe.name, parsed.diagnostics);
        assert!(!parsed.entries.is_empty(), "{}: binds nothing", recipe.name);
        for entry in parsed.entries {
            let action = cmux_action_catalog::find(&entry.command)
                .unwrap_or_else(|| panic!("{}: {} is not an action", recipe.name, entry.command));
            let Some(args) = &entry.args else { continue };
            let args = args.as_object().unwrap_or_else(|| {
                panic!("{}: {}'s args are not an object", recipe.name, entry.command)
            });
            for name in args.keys() {
                assert!(
                    action.arguments.iter().any(|argument| argument.name == name),
                    "{}: {} takes no argument {name}",
                    recipe.name,
                    entry.command
                );
            }
        }
    }
}

/// The engine itself takes each recipe: previewed whole on a fresh setup,
/// it validates, and discard puts the setup back.
#[test]
fn the_engine_previews_every_recipe_and_discard_takes_it_back() {
    for recipe in RECIPES {
        let home = tempfile::tempdir().unwrap();
        let roots = Roots::under(home.path());
        std::fs::create_dir_all(&roots.config_dir).unwrap();
        std::fs::write(&roots.settings_file, "{}\n").unwrap();
        let customize = Customize::open(roots.clone());
        customize.ensure_baseline(1).unwrap();
        let profile = recipe.profile().unwrap();
        customize
            .preview_profile(&profile, "test", 2)
            .unwrap_or_else(|error| panic!("{}: the engine refused it: {error}", recipe.name));
        let status = customize.status().unwrap();
        assert!(status.problems.is_empty(), "{}: {:?}", recipe.name, status.problems);
        assert!(status.dirty(), "{}: previewing it changed nothing", recipe.name);
        customize.discard("test", 3).unwrap();
        assert!(!customize.status().unwrap().dirty(), "{}: discard left a change", recipe.name);
    }
}

#[test]
fn the_guide_offers_try_it_for_every_recipe() {
    for recipe in RECIPES {
        let command = format!("cmux customize use {GUIDE_DIR}/{}.json", recipe.name);
        assert!(GUIDE.contains(&command), "the guide has no Try it for {}: {command}", recipe.name);
        assert!(GUIDE.contains(recipe.title), "the guide does not name {}", recipe.title);
        assert!(GUIDE.contains(recipe.ask), "the guide does not give the ask for {}", recipe.name);
    }
}

#[test]
fn written_recipes_are_the_profiles_and_the_guide_points_at_them() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_all(dir.path()).unwrap();
    assert_eq!(written.files.len(), RECIPES.len());
    for recipe in RECIPES {
        let text = std::fs::read_to_string(&written.files[recipe.name]).unwrap();
        let read: Profile = serde_json::from_str(&text).unwrap();
        assert_eq!(read, recipe.profile().unwrap());
    }
    let page = std::fs::read_to_string(&written.guide).unwrap();
    assert_eq!(page, guide(dir.path()));
    assert!(!page.contains(GUIDE_DIR));
    // A second run writes nothing new.
    let before = std::fs::metadata(&written.guide).unwrap().modified().unwrap();
    write_all(dir.path()).unwrap();
    assert_eq!(std::fs::metadata(&written.guide).unwrap().modified().unwrap(), before);
}

#[test]
fn a_folder_with_shell_characters_stays_one_argument_in_every_run_command() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("my recipes; touch pwn #'x");
    let page = guide(&dir);
    for recipe in RECIPES {
        let path = dir.join(format!("{}.json", recipe.name)).display().to_string();
        let line = page
            .lines()
            .find(|line| line.starts_with("cmux customize use ") && line.contains(recipe.name))
            .unwrap_or_else(|| panic!("no Run command for {}", recipe.name));
        let argument = line.strip_prefix("cmux customize use ").unwrap();
        // The shell reads the argument back as exactly the path, as one word.
        let out = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("printf '%s\\n' {argument}"))
            .output()
            .unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), format!("{path}\n"), "{line}");
    }
}

/// c-07be086806, Leo: "we know you can change colours. im saying the big stuff". The layout and
/// behaviour looks are recipes too, and none of them sets a color or a theme. The leader keys all
/// start with Command-J, cmux's own leader, so none takes a key a terminal or a chat types.
#[test]
fn the_layout_and_behaviour_looks_change_layout_and_keys_not_colors() {
    for name in ["review-desk", "bottom-deck", "workspace-tabs", "leader"] {
        let recipe = find(name).unwrap_or_else(|| panic!("no {name} recipe"));
        let profile = recipe.profile().unwrap();
        for key in profile.settings.keys() {
            assert!(
                !key.starts_with("appearance.") && !key.contains("color") && !key.contains("Color"),
                "{name} sets {key}, a look key"
            );
        }
    }
    let leader = find("leader").unwrap().profile().unwrap();
    let parsed = cmux_config::keybindings::parse(&leader.files["keybindings.json"]);
    assert!(parsed.entries.len() >= 20, "{} leader keys", parsed.entries.len());
    for entry in &parsed.entries {
        assert_eq!(entry.keys[0], "cmd+j", "{} does not start with the leader", entry.command);
        assert!(entry.keys.len() >= 2, "{} is the bare leader", entry.command);
    }
    assert_eq!(find("review-desk").unwrap().parts(), ["settings", "keybindings"]);
}
