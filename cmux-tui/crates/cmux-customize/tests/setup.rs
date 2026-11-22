//! Setups end to end on a real folder: a setup repo read, planned,
//! installed as one layer, removed back to what was there, and a person's
//! own customization exported as a setup repo that installs elsewhere.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::setup::{self, ExportHeader, Receipt, Reference, SETUP_FILE};
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
    Receipt {
        id: setup.manifest.id.clone(),
        name: setup.manifest.name.clone(),
        repository: reference.repository(),
        reference,
        commit: "a".repeat(40),
        sha256: setup.sha256.clone(),
        version: setup.manifest.version.clone(),
        generation: installed.applied.as_ref().map(|applied| applied.generation.n),
        before: installed.before,
        library: installed.applied.as_ref().and_then(|applied| applied.library.clone()),
        library_created: installed.library_created,
        actions: setup.actions().clone(),
        prior_actions: installed.prior_actions.clone(),
        extensions: Vec::new(),
        installed_ms: 10,
    }
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
    read.profile.settings.insert("not.a.setting".to_owned(), json!(1));
    assert!(home.customize().plan_setup(&read, "manaflow-ai", "0.0.0").is_err());
    assert!(home.customize().install_setup(&read, "setup", "cli", 10).is_err());
    assert!(!home.config("themes/sample-dusk.json").exists());
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
