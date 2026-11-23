//! Setups end to end on a real folder: a setup repo read, planned,
//! installed as one layer, removed back to what was there, and a person's
//! own customization exported as a setup repo that installs elsewhere.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::setup::{self, ExportHeader, Receipt, Reference, SETUP_FILE, SetupSource};
use cmux_customize::{Customize, Error, Roots};
use serde_json::{Value, json};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        Home { dir: tempfile::tempdir().unwrap() }
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

    fn read(&self, path: &str) -> Option<String> {
        fs::read_to_string(self.config(path)).ok()
    }

    fn settings(&self) -> Value {
        cmux_config::jsonc::parse(&self.read("cmux-next.json").unwrap_or_default()).unwrap()
    }
}

const MINE: &str = "{\n  // my settings\n  \"appearance\": { \"density\": \"compact\" },\n  \"actions\": { \"mine\": { \"type\": \"command\", \"command\": \"ls\" } }\n}\n";

#[test]
fn inactive_archive_profile_applies_seven_days() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    let customize = home.customize();
    let file = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../examples/looks/claude-code/inactive-archive/cmux-setup.json");
    let profile = customize.load_profile(file.to_str().unwrap()).unwrap();
    customize.preview_profile(&profile, "cli", 1).unwrap();
    assert!(customize.apply(None, "cli", 2).unwrap().recorded);
    let settings = home.settings();
    assert_eq!(settings["agents"]["chats"]["archiveInactive"], "7d");
    assert_eq!(settings["appearance"]["density"], "compact");
}

/// The sample setup (ext-in-git-notes/sample-setup): a theme, one action,
/// one extension.
fn sample_repo(root: &Path) -> PathBuf {
    let repo = root.join("repo");
    fs::create_dir_all(repo.join("themes")).unwrap();
    fs::create_dir_all(repo.join("screenshots")).unwrap();
    fs::write(
        repo.join(SETUP_FILE),
        r#"{
  // A comment: the file is JSONC, as cmux-next.json is.
  "cmuxSetup": 1,
  "id": "manaflow-ai/cmux-setup-sample",
  "name": "Sample Setup",
  "description": "A dusk theme, a hello action and the sample extension.",
  "version": "1.0.0",
  "extensions": ["github.com/manaflow-ai/cmux-extension-sample"],
  "cmuxProfile": 1,
  "settings": { "appearance.themeFile": "sample-dusk" },
  "actions": {
    "sample-hello": { "type": "command", "command": "echo hello", "title": "Say Hello" }
  }
}
"#,
    )
    .unwrap();
    fs::write(
        repo.join("themes/sample-dusk.json"),
        "{ \"name\": \"Sample Dusk\", \"colors\": { \"background\": \"#1a1b2e\" } }\n",
    )
    .unwrap();
    fs::write(
        repo.join("keybindings.json"),
        "[{ \"key\": \"cmd+shift+h\", \"command\": \"cmuxConfig.sample-hello\" }]\n",
    )
    .unwrap();
    // Listing material is never applied.
    fs::write(repo.join("README.md"), "# Sample\n").unwrap();
    fs::write(repo.join("screenshots/main.png"), [0u8, 159, 146, 150]).unwrap();
    fs::write(repo.join("themes/notes.txt"), "not a theme\n").unwrap();
    repo
}

fn receipt(setup: &setup::Setup, installed: &setup::Installed) -> Receipt {
    let reference = Reference::parse("github.com/manaflow-ai/cmux-setup-sample").unwrap();
    Receipt::new(setup, installed, SetupSource::Repo { reference }, &"a".repeat(40), Vec::new(), 10)
}

#[test]
fn a_setup_repo_reads_as_a_profile_with_its_files_at_their_paths() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    assert_eq!(read.manifest.id, "manaflow-ai/cmux-setup-sample");
    assert_eq!(read.profile.version, 1);
    assert_eq!(
        read.profile.files.keys().collect::<Vec<_>>(),
        ["keybindings.json", "themes/sample-dusk.json"]
    );
    assert_eq!(read.profile.settings["appearance.themeFile"], json!("sample-dusk"));
    assert_eq!(read.sha256.len(), 64);
    // The same content hashes the same; a changed file does not.
    assert_eq!(setup::read_dir(&repo).unwrap().sha256, read.sha256);
    fs::write(repo.join("themes/sample-dusk.json"), "{}\n").unwrap();
    assert_ne!(setup::read_dir(&repo).unwrap().sha256, read.sha256);
}

#[test]
fn a_folder_without_the_root_file_or_with_a_link_is_refused() {
    let home = Home::new();
    let Err(Error::Setup(why)) = setup::read_dir(home.dir.path()) else { panic!() };
    assert!(why.contains("cmux-setup.json"), "{why}");

    let repo = sample_repo(home.dir.path());
    std::os::unix::fs::symlink("/etc/hosts", repo.join("themes/evil.json")).unwrap();
    let Err(Error::Setup(why)) = setup::read_dir(&repo) else { panic!() };
    assert!(why.contains("is a link"), "{why}");
}

#[test]
fn the_plan_names_everything_it_changes_and_checks_the_owner() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"appearance\": { \"themeFile\": \"mine\" } }\n");
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    let customize = home.customize();
    let plan = customize.plan_setup(&read, "manaflow-ai", "0.0.0").unwrap();
    assert_eq!(plan.theme.as_deref(), Some("sample-dusk"));
    assert_eq!(plan.settings[0].replaces, Some(json!("mine")));
    assert_eq!(plan.files.len(), 2);
    assert_eq!(plan.keybindings, 1);
    assert_eq!(plan.actions[0].name, "sample-hello");
    assert_eq!(plan.actions[0].runs, "echo hello");
    assert_eq!(plan.extensions, ["github.com/manaflow-ai/cmux-extension-sample"]);
    // Planning writes nothing.
    assert!(!home.config("themes/sample-dusk.json").exists());

    // A repo whose owner is not the id's is refused.
    let Err(Error::Setup(why)) = customize.plan_setup(&read, "someone", "0.0.0") else { panic!() };
    assert!(why.contains("reserved") || why.contains("owner"), "{why}");
}

#[test]
fn a_setup_that_sets_a_setting_only_the_person_may_set_is_refused_whole() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.profile.settings.insert("updates.channel".to_owned(), json!("nightly"));
    assert!(home.customize().plan_setup(&read, "manaflow-ai", "0.0.0").is_err());
    assert!(home.customize().install_setup(&read, "setup", "cli", 10).is_err());
    assert!(!home.config("themes/sample-dusk.json").exists());
}

/// Leo (2026-11-18): "how will things go when this sort of stuff shifts and
/// changes over time, like with the incoming updates". A setup written for
/// another cmux: a renamed key installs under its new name, a removed key and
/// a key this cmux does not have are left out and listed, and the rest
/// installs (schemas/settings/retired-keys.json).
#[test]
fn a_setup_written_for_another_cmux_installs_what_this_one_has() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.profile.settings.insert("sidebar.showCounts".to_owned(), json!(false));
    read.profile.settings.insert("tabs.terminalFirst".to_owned(), json!(true));
    read.profile.settings.insert("sidebar.fromANewerCmux".to_owned(), json!(3));
    let customize = home.customize();
    let plan = customize.plan_setup(&read, "manaflow-ai", "0.0.0").unwrap();
    let keys: Vec<&str> = plan.settings.iter().map(|s| s.key.as_str()).collect();
    assert_eq!(keys, ["appearance.themeFile", "sidebar.workspaceRow.tabCount"]);
    assert_eq!(plan.renamed.len(), 1);
    assert_eq!(plan.renamed[0].from, "sidebar.showCounts");
    let skipped: Vec<&str> = plan.skipped.iter().map(|s| s.key.as_str()).collect();
    assert_eq!(skipped, ["tabs.terminalFirst", "sidebar.fromANewerCmux"]);
    assert!(plan.skipped[1].reason.contains("no setting by that name"), "{:?}", plan.skipped);
    let card = serde_json::to_value(&plan).unwrap();
    assert_eq!(card["skipped"][0]["key"], "tabs.terminalFirst");

    customize.install_setup(&read, "setup", "cli", 10).unwrap();
    let settings = home.settings();
    assert_eq!(settings["sidebar"]["workspaceRow"]["tabCount"], json!(false));
    assert_eq!(settings["sidebar"].get("showCounts"), None);
    assert_eq!(settings["sidebar"].get("fromANewerCmux"), None);
    assert_eq!(settings.get("tabs"), None);
    assert_eq!(settings["appearance"]["themeFile"], json!("sample-dusk"));
}

/// Lenient about names, never about values: a known key with a value it does
/// not accept still refuses the whole setup, and nothing is written.
#[test]
fn a_bad_value_for_a_known_or_renamed_key_still_refuses_the_whole_setup() {
    for (key, value) in
        [("appearance.density", json!("enormous")), ("sidebar.showCounts", json!("lots"))]
    {
        let home = Home::new();
        home.write("cmux-next.json", MINE);
        let repo = sample_repo(home.dir.path());
        let mut read = setup::read_dir(&repo).unwrap();
        read.profile.settings.insert("sidebar.fromANewerCmux".to_owned(), json!(3));
        read.profile.settings.insert(key.to_owned(), value);
        let customize = home.customize();
        let Err(Error::Profile(why)) = customize.plan_setup(&read, "manaflow-ai", "0.0.0") else {
            panic!("{key}")
        };
        assert!(why.contains("not one that setting accepts"), "{key}: {why}");
        assert!(customize.install_setup(&read, "setup", "cli", 10).is_err());
        assert_eq!(home.read("cmux-next.json").unwrap(), MINE, "{key}");
        assert!(!home.config("themes/sample-dusk.json").exists(), "{key}");
    }
}

#[test]
fn install_applies_one_layer_and_remove_puts_back_what_was_there() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    home.write("keybindings.json", "[{ \"key\": \"cmd+k\", \"command\": \"mine\" }]\n");
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    let customize = home.customize();

    let installed =
        customize.install_setup(&read, "setup manaflow-ai/cmux-setup-sample", "cli", 10).unwrap();
    let applied = installed.applied.clone().expect("it changed something");
    assert!(applied.library.is_some(), "kept as one library entry");
    assert!(customize.status().unwrap().draft.is_none(), "applied, not left as a preview");
    let settings = home.settings();
    assert_eq!(settings["appearance"]["themeFile"], json!("sample-dusk"));
    assert_eq!(settings["appearance"]["density"], json!("compact"), "your own keys stay");
    assert_eq!(settings["actions"]["sample-hello"]["command"], json!("echo hello"));
    assert_eq!(settings["actions"]["mine"]["command"], json!("ls"));
    assert!(home.read("themes/sample-dusk.json").unwrap().contains("Sample Dusk"));
    let keys = home.read("keybindings.json").unwrap();
    assert!(keys.contains("cmd+k") && keys.contains("cmd+shift+h"), "{keys}");
    assert!(home.read("cmux-next.json").unwrap().contains("// my settings"));

    customize.record_setup(receipt(&read, &installed)).unwrap();
    let found = customize.setup("github.com/manaflow-ai/cmux-setup-sample@main").unwrap().unwrap();
    assert_eq!(found.id, "manaflow-ai/cmux-setup-sample");
    assert!(customize.setup("manaflow-ai/cmux-setup-sample").unwrap().is_some());

    let removed = customize.remove_setup(&found, "cli", 20).unwrap();
    assert_eq!(removed.actions, ["sample-hello"]);
    let settings = home.settings();
    assert_eq!(settings["appearance"].get("themeFile"), None);
    assert_eq!(settings["actions"].get("sample-hello"), None);
    assert_eq!(settings["actions"]["mine"]["command"], json!("ls"));
    assert!(!home.config("themes/sample-dusk.json").exists());
    let keys = home.read("keybindings.json").unwrap();
    assert!(keys.contains("cmd+k") && !keys.contains("cmd+shift+h"), "{keys}");
    assert!(customize.setups().unwrap().is_empty());
}

#[test]
fn remove_puts_back_the_action_it_replaced_and_keeps_one_you_changed_since() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{ \"actions\": { \"sample-hello\": { \"command\": \"echo mine\" } } }\n",
    );
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.manifest
        .actions
        .insert("other".to_owned(), json!({ "type": "command", "command": "date" }));
    let customize = home.customize();
    let installed = customize.install_setup(&read, "setup", "cli", 10).unwrap();
    assert_eq!(installed.prior_actions["sample-hello"], Some(json!({ "command": "echo mine" })));
    assert_eq!(installed.prior_actions["other"], None);
    customize.record_setup(receipt(&read, &installed)).unwrap();

    // The person edits one of the setup's actions by hand.
    let text = home.read("cmux-next.json").unwrap().replace("\"date\"", "\"date -u\"");
    home.write("cmux-next.json", &text);
    customize.apply(None, "cli", 15).unwrap();

    let found = customize.setups().unwrap().remove(0);
    let removed = customize.remove_setup(&found, "cli", 20).unwrap();
    assert_eq!(removed.actions, ["sample-hello"]);
    assert_eq!(removed.kept_actions, ["other"]);
    let settings = home.settings();
    assert_eq!(settings["actions"]["sample-hello"]["command"], json!("echo mine"));
    assert_eq!(settings["actions"]["other"]["command"], json!("date -u"));
}

#[test]
fn the_plan_never_shows_a_credential_it_replaces() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{ \"browser\": { \"newTabPage\": \"https://me:hunter2@example.com/start\" } }\n",
    );
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.profile.settings.insert("browser.newTabPage".to_owned(), json!("https://cmux.com"));
    let plan = home.customize().plan_setup(&read, "manaflow-ai", "0.0.0").unwrap();
    let row = plan.settings.iter().find(|row| row.key == "browser.newTabPage").unwrap();
    assert_eq!(row.replaces, Some(json!(setup::HIDDEN)));
    assert!(!serde_json::to_string(&plan).unwrap().contains("hunter2"));
}

#[test]
fn an_update_that_fails_puts_the_installed_setup_back() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    let customize = home.customize();
    let installed = customize.install_setup(&read, "setup", "cli", 10).unwrap();
    customize.record_setup(receipt(&read, &installed)).unwrap();

    // The new commit adds a theme where this computer has a folder, so the
    // install step of the update cannot write it (after the old one came off).
    let old = customize.setups().unwrap().remove(0);
    let mut next = read;
    next.profile.files.insert("themes/later.json".to_owned(), "{ \"name\": \"Later\" }\n".into());
    fs::create_dir_all(home.config("themes/later.json/inside")).unwrap();
    let error = customize.replace_setup(&old, &next, "setup v2", "cli", 20);
    assert!(error.is_err(), "{error:?}");

    let kept = customize.setups().unwrap();
    assert_eq!(kept.len(), 1, "the old receipt is still there to remove or retry");
    assert_eq!(kept[0].sha256, old.sha256);
    assert!(customize.status().unwrap().draft.is_none(), "no preview left open");
    assert_eq!(home.settings()["appearance"]["themeFile"], json!("sample-dusk"));
    assert!(home.read("themes/sample-dusk.json").unwrap().contains("Sample Dusk"));
    let library = old.library.expect("the setup is a library entry");
    assert!(customize.library().unwrap().entries.iter().any(|entry| entry.name == library));
    // And it still removes cleanly.
    customize.remove_setup(&kept[0], "cli", 30).unwrap();
    assert!(!home.config("themes/sample-dusk.json").exists());
}

#[test]
fn a_failed_install_leaves_nothing_live() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    home.write("keybindings.json", "[{ \"key\": \"cmd+k\", \"command\": \"mine\" }]\n");
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    // A theme the setup cannot write (a folder is in its place), sorted after
    // the files it writes first.
    read.profile.files.insert("themes/zz.json".to_owned(), "{ \"name\": \"Z\" }\n".into());
    fs::create_dir_all(home.config("themes/zz.json/inside")).unwrap();
    let customize = home.customize();
    let error = customize.install_setup(&read, "setup", "cli", 10);
    assert!(error.is_err(), "{error:?}");
    assert!(customize.status().unwrap().draft.is_none());
    assert!(!home.config("themes/sample-dusk.json").exists());
    let keys = home.read("keybindings.json").unwrap();
    assert!(!keys.contains("cmd+shift+h"), "{keys}");
    let settings = home.settings();
    assert_eq!(settings["appearance"].get("themeFile"), None);
    assert_eq!(settings["actions"].get("sample-hello"), None);
    assert_eq!(settings["actions"]["mine"]["command"], json!("ls"));
}

#[test]
fn export_writes_a_setup_repo_that_installs_on_another_machine() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{ \"appearance\": { \"themeFile\": \"night\" }, \"actions\": { \"hi\": { \"command\": \"echo hi\" } } }\n",
    );
    home.write(
        "themes/night.json",
        "{ \"name\": \"night\", \"colors\": { \"background\": \"#000000\" } }\n",
    );
    let customize = home.customize();
    let out = home.dir.path().join("my-setup");
    let header = ExportHeader {
        id: "leo/night".to_owned(),
        name: "Night".to_owned(),
        description: "My night look.".to_owned(),
        repo: "leo/cmux-night".to_owned(),
        extensions: vec!["github.com/manaflow-ai/cmux-extension-sample".to_owned()],
    };
    let exported = customize.export_setup(&out, &header, 10).unwrap();
    assert_eq!(exported.files, ["themes/night.json"]);
    assert_eq!(exported.actions, ["hi"]);
    assert_eq!(exported.page_url, "https://cmux.com/setups/leo/cmux-night");
    let readme = fs::read_to_string(out.join("README.md")).unwrap();
    assert!(readme.contains(
        "[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/setups/leo/cmux-night)"
    ));
    assert!(readme.contains("cmux setup install github.com/leo/cmux-night"));

    // A folder of something else is never written into.
    let other = home.dir.path().join("other");
    fs::create_dir_all(&other).unwrap();
    fs::write(other.join("notes.md"), "x").unwrap();
    assert!(customize.export_setup(&other, &header, 11).is_err());

    // Another machine installs it.
    let there = Home::new();
    let read = setup::read_dir(&out).unwrap();
    let plan = there.customize().plan_setup(&read, "leo", "0.0.0").unwrap();
    assert_eq!(plan.theme.as_deref(), Some("night"));
    there.customize().install_setup(&read, "setup leo/night", "cli", 20).unwrap();
    assert_eq!(there.settings()["appearance"]["themeFile"], json!("night"));
    assert_eq!(there.settings()["actions"]["hi"]["command"], json!("echo hi"));
    assert!(there.read("themes/night.json").is_some());
}

#[test]
fn a_setup_that_carries_a_credential_is_refused_whole() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let customize = home.customize();
    let token = format!("ghp_{}", "a1B2".repeat(9));

    let mut in_setting = setup::read_dir(&repo).unwrap();
    in_setting
        .profile
        .settings
        .insert("browser.newTabPage".to_owned(), json!("https://me:hunter2@example.com/"));
    let mut in_file = setup::read_dir(&repo).unwrap();
    in_file
        .profile
        .files
        .insert("themes/leaky.json".to_owned(), format!("{{ \"name\": \"{token}\" }}\n"));
    let mut in_action = setup::read_dir(&repo).unwrap();
    in_action
        .manifest
        .actions
        .insert("leak".to_owned(), json!({ "command": format!("curl -H {token}") }));
    let mut in_action_name = setup::read_dir(&repo).unwrap();
    in_action_name.manifest.actions.insert(token, json!({ "command": "date" }));
    for bad in [in_setting, in_file, in_action, in_action_name] {
        for result in [
            customize.plan_setup(&bad, "manaflow-ai", "0.0.0").map(|_| ()),
            customize.install_setup(&bad, "setup", "cli", 10).map(|_| ()),
        ] {
            let why = match result {
                Err(error) => error.to_string(),
                Ok(()) => panic!("a setup with a credential went through"),
            };
            assert!(!why.contains("hunter2") && !why.contains("a1B2"), "{why}");
        }
    }
    assert!(!home.config("themes/sample-dusk.json").exists());
}

#[test]
fn exporting_again_leaves_out_what_this_export_leaves_out() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"appearance\": { \"themeFile\": \"night\" } }\n");
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    home.write("themes/old.json", "{ \"name\": \"old\" }\n");
    let customize = home.customize();
    customize.apply(None, "cli", 5).unwrap();
    let out = home.dir.path().join("my-setup");
    let header = ExportHeader {
        id: "leo/night".to_owned(),
        name: "Night".to_owned(),
        description: "My night look.".to_owned(),
        repo: String::new(),
        extensions: Vec::new(),
    };
    customize.export_setup(&out, &header, 10).unwrap();
    assert!(out.join("themes/old.json").is_file());

    // The old theme now holds a token, so the next export leaves it out:
    // the copy the first export wrote must not stay behind in the repo.
    let token = format!("ghp_{}", "a1B2".repeat(9));
    home.write("themes/old.json", &format!("{{ \"name\": \"{token}\" }}\n"));
    customize.apply(None, "cli", 15).unwrap();
    // Nothing is deleted from your repo, and nothing left out ships: the
    // export stops and names the file.
    let Err(Error::Setup(why)) = customize.export_setup(&out, &header, 20) else { panic!() };
    assert!(why.contains("themes/old.json"), "{why}");
    assert!(!why.contains("a1B2"), "{why}");
    assert!(out.join("themes/old.json").is_file(), "your file stays");
    // Moved out of the repo, the export goes through.
    fs::remove_file(out.join("themes/old.json")).unwrap();
    let exported = customize.export_setup(&out, &header, 25).unwrap();
    assert_eq!(exported.files, ["themes/night.json"]);
    let read = setup::read_dir(&out).unwrap();
    assert!(!read.profile.files.contains_key("themes/old.json"));
}

#[test]
fn remove_never_deletes_a_setup_file_you_grew_past_what_cmux_keeps() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    let customize = home.customize();
    let installed = customize.install_setup(&read, "setup", "cli", 10).unwrap();
    customize.record_setup(receipt(&read, &installed)).unwrap();

    // You rework the setup's theme into a file larger than cmux keeps a
    // copy of (2 MiB), so no generation could bring it back.
    let big = format!("{{ \"name\": \"mine\", \"pad\": \"{}\" }}\n", "x".repeat(3 * 1024 * 1024));
    home.write("themes/sample-dusk.json", &big);

    let found = customize.setups().unwrap().remove(0);
    assert!(customize.remove_setup(&found, "cli", 20).is_err());
    assert_eq!(home.read("themes/sample-dusk.json").unwrap().len(), big.len(), "your file stays");
}

#[test]
fn removing_a_setup_never_deletes_a_library_entry_you_already_had() {
    let home = Home::new();
    let repo = sample_repo(home.dir.path());
    let read = setup::read_dir(&repo).unwrap();
    let customize = home.customize();

    // You already have this look as a library entry, turned off.
    let first = customize.install_setup(&read, "setup", "cli", 10).unwrap();
    assert!(first.library_created);
    let yours = first.applied.as_ref().and_then(|applied| applied.library.clone()).unwrap();
    customize.library_set_on(&yours, false, "cli", 15).unwrap();
    assert!(!home.config("themes/sample-dusk.json").exists());

    // Installing the setup now matches your entry rather than making one.
    let installed = customize.install_setup(&read, "setup", "cli", 20).unwrap();
    let named = installed.applied.as_ref().and_then(|applied| applied.library.clone());
    if named.as_deref() == Some(yours.as_str()) {
        assert!(!installed.library_created);
    }
    customize.record_setup(receipt(&read, &installed)).unwrap();
    let found = customize.setups().unwrap().remove(0);
    customize.remove_setup(&found, "cli", 30).unwrap();
    assert!(
        customize.library().unwrap().entries.iter().any(|entry| entry.name == yours),
        "your entry is still in the library"
    );
}

/// A look: its own theme (selected), a stylesheet, and views
/// (`customize/`, as a repo holds them: the app `local/customize`).
fn look(root: &Path, id: &str, color: &str) -> PathBuf {
    let name = id.split('/').next_back().unwrap();
    let repo = root.join(name);
    for dir in ["themes", "customize", "agent-pane"] {
        fs::create_dir_all(repo.join(dir)).unwrap();
    }
    fs::write(
        repo.join(SETUP_FILE),
        format!(
            r#"{{"cmuxSetup": 1, "id": "{id}", "name": "{name}", "cmuxProfile": 1,
               "settings": {{"appearance.themeFile": "{name}"}}}}"#
        ),
    )
    .unwrap();
    fs::write(
        repo.join(format!("themes/{name}.json")),
        format!("{{ \"name\": \"{name}\", \"colors\": {{ \"background\": \"{color}\" }} }}\n"),
    )
    .unwrap();
    fs::write(repo.join(format!("themes/{name}-only.json")), "{ \"name\": \"only\" }\n").unwrap();
    fs::write(repo.join("customize/main.js"), format!("// {name}\nvar __cmuxAppExports = {{}};\n"))
        .unwrap();
    fs::write(
        repo.join("customize/cmux-app.json"),
        r#"{"manifestVersion": 2, "id": "local/customize", "name": "Views", "version": "1.0.0",
            "description": "A view", "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
            "files": ["main.js"]}"#,
    )
    .unwrap();
    repo
}

/// Every file under `dir`, by path, with its bytes.
fn snapshot(dir: &Path) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
    let mut found = std::collections::BTreeMap::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        let Ok(entries) = fs::read_dir(&next) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                found.insert(
                    path.strip_prefix(dir).unwrap().to_path_buf(),
                    fs::read(&path).unwrap(),
                );
            }
        }
    }
    found
}

/// Leo: "Shouldn't repos not need to entirely fork cmux? Like just have a bit
/// of whatever customizations there are. Like dotfiles". Two looks stack as
/// layers of their own over the person's own edits; removing one takes off
/// only its layer, and the other look and the edits stay byte for byte.
#[test]
fn two_looks_and_your_edits_stack_and_removing_one_leaves_the_rest_byte_for_byte() {
    let home = Home::new();
    let customize = home.customize();
    // Your own: settings with a comment, your own views app and a theme.
    home.write("cmux-next.json", MINE);
    home.write("customize/main.js", "// my sidebar\n");
    home.write(
        "customize/cmux-app.json",
        r#"{"manifestVersion": 2, "id": "local/customize", "name": "Mine", "version": "1.0.0",
            "description": "My views", "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
            "files": ["main.js"]}"#,
    );
    home.write("themes/mine.json", "{ \"name\": \"mine\" }\n");
    customize.apply(None, "cli", 1).unwrap();

    let install = |id: &str, color: &str, at: u64| {
        let read = setup::read_dir(&look(home.dir.path(), id, color)).unwrap();
        customize.plan_setup(&read, "leo", "0.0.0").unwrap();
        let installed = customize.install_setup(&read, &format!("setup {id}"), "cli", at).unwrap();
        let reference = Reference::parse(&format!("github.com/{id}")).unwrap();
        let receipt = Receipt::new(
            &read,
            &installed,
            SetupSource::Repo { reference },
            &"a".repeat(40),
            Vec::new(),
            at,
        );
        customize.record_setup(receipt.clone()).unwrap();
        receipt
    };
    let dusk = install("leo/dusk", "#1a1b2e", 10);
    let dawn = install("leo/dawn", "#fdf6e3", 20);
    assert_eq!(dusk.layer.as_deref(), Some("setup-leo-dusk"));

    // Your own edits after both: a setting, by hand, applied.
    let edited = home.read("cmux-next.json").unwrap().replace("\"compact\"", "\"comfortable\"");
    home.write("cmux-next.json", &edited);
    customize.apply(Some("my density"), "cli", 30).unwrap();

    // Neither install wrote your views; each look has a layer of its own.
    let setups = home.config("setups");
    assert_eq!(home.read("customize/main.js").unwrap(), "// my sidebar\n");
    let index: Value =
        serde_json::from_str(&fs::read_to_string(setups.join("layers.json")).unwrap()).unwrap();
    let apps: Vec<&str> = index["layers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["app"].as_str().unwrap())
        .collect();
    assert_eq!(apps, ["local/setup-leo-dawn", "local/setup-leo-dusk"], "newest on top");
    assert_eq!(
        fs::read_to_string(setups.join("setup-leo-dusk/main.js")).unwrap(),
        "// dusk\nvar __cmuxAppExports = {};\n"
    );
    let manifest: Value = serde_json::from_str(
        &fs::read_to_string(setups.join("setup-leo-dusk/cmux-app.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["id"], json!("local/setup-leo-dusk"));

    let settings_before = home.read("cmux-next.json").unwrap();
    let mine_before = snapshot(&home.config("customize"));
    let dawn_layer_before = snapshot(&setups.join("setup-leo-dawn"));
    let dawn_themes_before =
        [home.read("themes/dawn.json").unwrap(), home.read("themes/dawn-only.json").unwrap()];
    let mine_theme_before = home.read("themes/mine.json").unwrap();
    assert!(settings_before.contains("\"comfortable\""), "{settings_before}");

    // Take the lower look off.
    let found = customize.setup("leo/dusk").unwrap().unwrap();
    let removed = customize.remove_setup(&found, "cli", 40).unwrap();
    assert_eq!(removed.layer.as_deref(), Some("setup-leo-dusk"));

    // Its layer is gone, and only its layer.
    assert!(!setups.join("setup-leo-dusk").exists());
    assert!(home.read("themes/dusk-only.json").is_none());
    let index: Value =
        serde_json::from_str(&fs::read_to_string(setups.join("layers.json")).unwrap()).unwrap();
    assert_eq!(index["layers"][0]["app"], json!("local/setup-leo-dawn"));
    assert_eq!(index["layers"].as_array().unwrap().len(), 1);
    // The other look, and your edits, byte for byte.
    assert_eq!(home.read("cmux-next.json").unwrap(), settings_before);
    assert_eq!(snapshot(&home.config("customize")), mine_before);
    assert_eq!(snapshot(&setups.join("setup-leo-dawn")), dawn_layer_before);
    assert_eq!(
        [home.read("themes/dawn.json").unwrap(), home.read("themes/dawn-only.json").unwrap()],
        dawn_themes_before
    );
    assert_eq!(home.read("themes/mine.json").unwrap(), mine_theme_before);
    assert_eq!(
        customize.setups().unwrap().iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
        [dawn.id.as_str()]
    );
}

#[test]
fn a_setup_turns_off_and_on_in_its_place_and_order_sets_which_look_wins() {
    let home = Home::new();
    let customize = home.customize();
    home.write("cmux-next.json", MINE);
    let install = |id: &str, color: &str, at: u64| {
        let read = setup::read_dir(&look(home.dir.path(), id, color)).unwrap();
        let installed = customize.install_setup(&read, id, "cli", at).unwrap();
        let reference = Reference::parse(&format!("github.com/{id}")).unwrap();
        let receipt =
            Receipt::new(&read, &installed, SetupSource::Repo { reference }, "c", Vec::new(), at);
        customize.record_setup(receipt).unwrap();
    };
    install("leo/dusk", "#111111", 10);
    install("leo/dawn", "#eeeeee", 20);
    let theme = |home: &Home| home.settings()["appearance"]["themeFile"].clone();
    assert_eq!(theme(&home), json!("dawn"), "the top look wins a key both set");

    customize.set_setup_on("leo/dawn", false, "cli", 30).unwrap();
    assert_eq!(theme(&home), json!("dusk"));
    let index = setup::layers::read_index(&home.config("setups")).unwrap();
    assert_eq!(index.layers.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(), ["leo/dusk"]);
    assert!(home.config("setups/setup-leo-dawn/main.js").exists(), "off keeps it installed");
    customize.set_setup_on("leo/dawn", true, "cli", 40).unwrap();
    assert_eq!(theme(&home), json!("dawn"));

    customize.order_setups(&["leo/dusk".to_owned()], "cli", 50).unwrap();
    assert_eq!(theme(&home), json!("dusk"), "the order decides");
    let ids: Vec<String> = customize.setups().unwrap().into_iter().map(|r| r.id).collect();
    assert_eq!(ids, ["leo/dusk", "leo/dawn"]);
}

#[test]
fn the_first_receipts_file_still_reads() {
    let home = Home::new();
    let state = home.dir.path().join("state");
    fs::create_dir_all(&state).unwrap();
    fs::write(
        state.join("setups.json"),
        r#"{"setups": [
          {"id": "leo/night", "name": "Night", "repository": "github.com/leo/night",
           "reference": {"host": "github.com", "owner": "leo", "repo": "night", "path": ""},
           "commit": "abc", "sha256": "def", "installed_ms": 1},
          {"id": "leo/try", "name": "Try", "repository": "/tmp/try",
           "reference": {"host": "local", "owner": "leo", "repo": "try", "path": ""},
           "local": "/tmp/try", "commit": "local-1", "sha256": "1", "installed_ms": 2}
        ]}"#,
    )
    .unwrap();
    let setups = home.customize().setups().unwrap();
    assert_eq!(setups.len(), 2);
    assert!(
        matches!(&setups[0].source, SetupSource::Repo { reference } if reference.key() == "github.com/leo/night")
    );
    assert_eq!(setups[1].source, SetupSource::Folder { path: PathBuf::from("/tmp/try") });
    assert!(setups.iter().all(|receipt| receipt.on && receipt.layer.is_none()));
    assert!(home.customize().setup("github.com/leo/night").unwrap().is_some());
}

/// A setup that sets one action, `shared`, to run `command`.
fn action_setup(root: &Path, id: &str, command: &str) -> setup::Setup {
    let name = id.replace('/', "-");
    let repo = root.join(format!("actions-{name}-{}", command.len()));
    fs::create_dir_all(&repo).unwrap();
    fs::write(
        repo.join(SETUP_FILE),
        format!(
            r#"{{"cmuxSetup": 1, "id": "{id}", "name": "{name}", "cmuxProfile": 1,
               "actions": {{"shared": {{"type": "command", "command": "{command}"}}}}}}"#
        ),
    )
    .unwrap();
    setup::read_dir(&repo).unwrap()
}

fn install_action(home: &Home, customize: &Customize, id: &str, command: &str, at: u64) {
    let read = action_setup(home.dir.path(), id, command);
    let installed = customize.install_setup(&read, id, "cli", at).unwrap();
    let reference = Reference::parse(&format!("github.com/{id}")).unwrap();
    let receipt =
        Receipt::new(&read, &installed, SetupSource::Repo { reference }, "c", Vec::new(), at);
    customize.record_setup(receipt).unwrap();
}

fn remove_by_id(customize: &Customize, id: &str, at: u64) -> setup::Removed {
    let receipt = customize.setup(id).unwrap().unwrap();
    customize.remove_setup(&receipt, "cli", at).unwrap()
}

/// What the `shared` action runs now (`Null`: there is none).
fn shared(home: &Home) -> Value {
    home.settings()["actions"]["shared"]["command"].clone()
}

const MINE_SHARED: &str =
    "{ \"actions\": { \"shared\": { \"type\": \"command\", \"command\": \"echo mine\" } } }\n";

fn prior_of(customize: &Customize, id: &str) -> Option<Value> {
    customize.setup(id).unwrap().unwrap().prior_actions["shared"].clone()
}

#[test]
fn removing_one_of_two_setups_that_set_the_same_action_keeps_it_for_the_other() {
    for first_off in ["leo/a", "leo/b"] {
        let home = Home::new();
        home.write("cmux-next.json", MINE_SHARED);
        let customize = home.customize();
        install_action(&home, &customize, "leo/a", "echo same", 10);
        install_action(&home, &customize, "leo/b", "echo same", 20);
        let mine = Some(json!({ "type": "command", "command": "echo mine" }));
        assert_eq!(prior_of(&customize, "leo/b"), mine, "both name what was there before them");

        let removed = remove_by_id(&customize, first_off, 30);
        assert_eq!(shared(&home), json!("echo same"), "{first_off} off: the other still sets it");
        assert!(removed.actions.is_empty(), "{removed:?}");
        assert_eq!(removed.shared_actions, ["shared"]);
        let other = if first_off == "leo/a" { "leo/b" } else { "leo/a" };
        let receipt = customize.setup(other).unwrap().unwrap();
        assert_eq!(receipt.actions["shared"]["command"], json!("echo same"));
        assert_eq!(receipt.prior_actions["shared"], mine, "its receipt still puts yours back");

        let removed = remove_by_id(&customize, other, 40);
        assert_eq!(removed.actions, ["shared"]);
        assert_eq!(shared(&home), json!("echo mine"), "the last one off puts yours back");
    }
}

#[test]
fn two_setups_with_different_values_hand_the_action_down_by_order() {
    for (first_off, left) in [("leo/b", "echo a"), ("leo/a", "echo b")] {
        let home = Home::new();
        home.write("cmux-next.json", MINE_SHARED);
        let customize = home.customize();
        install_action(&home, &customize, "leo/a", "echo a", 10);
        install_action(&home, &customize, "leo/b", "echo b", 20);
        assert_eq!(shared(&home), json!("echo b"), "the top one wins");

        let removed = remove_by_id(&customize, first_off, 30);
        assert_eq!(shared(&home), json!(left), "{first_off} off");
        assert_eq!(removed.shared_actions, ["shared"]);
        let other = if first_off == "leo/a" { "leo/b" } else { "leo/a" };
        remove_by_id(&customize, other, 40);
        assert_eq!(shared(&home), json!("echo mine"));
        assert!(customize.setups().unwrap().is_empty());
    }
}

#[test]
fn an_action_no_one_had_comes_out_only_with_the_last_setup_that_sets_it() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    let customize = home.customize();
    install_action(&home, &customize, "leo/a", "echo same", 10);
    install_action(&home, &customize, "leo/b", "echo same", 20);
    install_action(&home, &customize, "leo/c", "echo c", 30);
    remove_by_id(&customize, "leo/c", 40);
    assert_eq!(shared(&home), json!("echo same"));
    remove_by_id(&customize, "leo/a", 50);
    assert_eq!(shared(&home), json!("echo same"));
    assert_eq!(prior_of(&customize, "leo/b"), None);
    remove_by_id(&customize, "leo/b", 60);
    assert_eq!(shared(&home), Value::Null);
    assert_eq!(home.settings()["actions"]["mine"]["command"], json!("ls"));
}

#[test]
fn an_action_you_changed_before_a_new_setup_comes_back_when_that_setup_goes() {
    let home = Home::new();
    home.write("cmux-next.json", MINE_SHARED);
    let customize = home.customize();
    install_action(&home, &customize, "leo/a", "echo a", 10);
    let text = home.read("cmux-next.json").unwrap().replace("\"echo a\"", "\"echo hand\"");
    home.write("cmux-next.json", &text);
    customize.apply(None, "cli", 15).unwrap();
    install_action(&home, &customize, "leo/b", "echo b", 20);
    assert!(
        !customize.setup("leo/a").unwrap().unwrap().actions.contains_key("shared"),
        "your change made it yours: leo/a no longer puts anything back"
    );

    let removed = remove_by_id(&customize, "leo/b", 30);
    assert_eq!(removed.actions, ["shared"]);
    assert_eq!(shared(&home), json!("echo hand"));
    let removed = remove_by_id(&customize, "leo/a", 40);
    assert!(removed.actions.is_empty() && removed.shared_actions.is_empty(), "{removed:?}");
    assert_eq!(shared(&home), json!("echo hand"));
}

#[test]
fn receipts_that_chain_their_priors_still_put_the_first_value_back() {
    // The receipt file as the previous rule wrote it: each setup's prior is
    // what was there when it installed (leo/b's is leo/a's value).
    let home = Home::new();
    home.write("cmux-next.json", MINE_SHARED);
    let customize = home.customize();
    install_action(&home, &customize, "leo/a", "echo a", 10);
    install_action(&home, &customize, "leo/b", "echo b", 20);
    let path = home.dir.path().join("state/setups.json");
    let mut file: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let rows = file["setups"].as_array_mut().unwrap();
    let b = rows.iter_mut().find(|row| row["id"] == json!("leo/b")).unwrap();
    b["prior_actions"]["shared"] = json!({ "type": "command", "command": "echo a" });
    fs::write(&path, serde_json::to_string(&file).unwrap()).unwrap();

    remove_by_id(&customize, "leo/a", 30);
    assert_eq!(shared(&home), json!("echo b"));
    assert_eq!(
        prior_of(&customize, "leo/b"),
        Some(json!({ "type": "command", "command": "echo mine" }))
    );
    remove_by_id(&customize, "leo/b", 40);
    assert_eq!(shared(&home), json!("echo mine"));
}

#[test]
fn an_update_whose_id_changed_leaves_one_receipt_in_the_old_place() {
    let home = Home::new();
    home.write("cmux-next.json", MINE_SHARED);
    let customize = home.customize();
    install_action(&home, &customize, "leo/below", "echo below", 5);
    install_action(&home, &customize, "leo/old", "echo old", 10);
    install_action(&home, &customize, "leo/top", "echo top", 15);
    let old = customize.setup("leo/old").unwrap().unwrap();

    let taken = action_setup(home.dir.path(), "leo/top", "echo taken");
    let refused = customize.replace_setup(&old, &taken, "update", "cli", 20);
    assert!(matches!(refused, Err(Error::Setup(_))), "{refused:?}");

    let renamed = action_setup(home.dir.path(), "leo/renamed", "echo renamed");
    let installed = customize.replace_setup(&old, &renamed, "update", "cli", 30).unwrap();
    let reference = Reference::parse("github.com/leo/renamed").unwrap();
    let receipt =
        Receipt::new(&renamed, &installed, SetupSource::Repo { reference }, "d", Vec::new(), 30);
    customize.record_setup(receipt).unwrap();
    let ids: Vec<String> = customize.setups().unwrap().into_iter().map(|r| r.id).collect();
    assert_eq!(ids, ["leo/top", "leo/renamed", "leo/below"]);
}

/// A choice a row renamed (`aliases`, `updates.notify`: `card` is now
/// `badge`): a setup that sets the old value installs the new one.
#[test]
fn a_setup_with_an_old_choice_value_installs_the_new_one() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.profile.settings.insert("updates.notify".to_owned(), json!("card"));
    let customize = home.customize();
    let plan = customize.plan_setup(&read, "manaflow-ai", "0.0.0").unwrap();
    let notify = plan.settings.iter().find(|s| s.key == "updates.notify").unwrap();
    assert_eq!(notify.value, json!("badge"));
    assert_eq!(plan.renamed.len(), 1);
    assert_eq!(plan.renamed[0].old_value, Some(json!("card")));
    assert!(plan.skipped.is_empty(), "{:?}", plan.skipped);
    customize.install_setup(&read, "setup", "cli", 10).unwrap();
    assert_eq!(home.settings()["updates"]["notify"], json!("badge"));
}

/// A setup (a look add-on) that picks the corner treatment installs it into
/// cmux-next.json and removing it puts the default back (Leo, 2026-11-18: the
/// gooey look "we have as a toggle maybe, and we can like do more stuff with
/// that").
#[test]
fn a_setup_that_picks_the_corner_treatment_keeps_it() {
    let home = Home::new();
    home.write("cmux-next.json", MINE);
    let repo = sample_repo(home.dir.path());
    let mut read = setup::read_dir(&repo).unwrap();
    read.profile.settings.insert("appearance.cornerFlush".to_owned(), json!("flush-goo"));
    let customize = home.customize();
    customize.plan_setup(&read, "manaflow-ai", "0.0.0").expect("a look setting plans");
    let installed = customize.install_setup(&read, "setup corner", "cli", 10).unwrap();
    let settings = home.settings();
    assert_eq!(settings["appearance"]["cornerFlush"], json!("flush-goo"));
    assert_eq!(settings["appearance"]["density"], json!("compact"), "your own keys stay");

    customize.record_setup(receipt(&read, &installed)).unwrap();
    let found = customize.setup("manaflow-ai/cmux-setup-sample").unwrap().unwrap();
    customize.remove_setup(&found, "cli", 20).unwrap();
    assert_eq!(home.settings()["appearance"].get("cornerFlush"), None);
}
