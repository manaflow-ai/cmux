//! The grammar, the consent card, and install, update and remove with a
//! stand-in repo and App Store. The file model's own journeys are the
//! `cmux-customize` crate's `tests/setup.rs`.

use std::cell::RefCell;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::setup::looks::Scheme;
use cmux_customize::setup::{Reference, SetupSource};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

use super::super::super::OutputMode;
use super::{
    Apps, Checkout, Failure, Request, card_text, fetch_from, gallery, inert, install_as,
    install_link, order, parse, preview, reload, remove, set_on, stepped, swap, undo_redo, update,
    variant,
};

/// Installs `text` under its own id, as `cmux setup install TEXT` does.
fn install(
    customize: &Customize,
    apps: &dyn Apps,
    output: OutputMode,
    text: &str,
    yes: bool,
) -> Result<Value, Failure> {
    install_as(customize, apps, output, text, yes, None)
}

fn words(text: &[&str]) -> Vec<String> {
    text.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn the_grammar_takes_each_verb_and_refuses_the_rest() {
    assert_eq!(
        parse(&words(&["install", "github.com/a/b", "--yes"])),
        Ok(Request::Install {
            reference: "github.com/a/b".to_owned(),
            yes: true,
            as_id: None,
            watch: false
        })
    );
    assert_eq!(
        parse(&words(&["install", "./look", "--watch"])),
        Ok(Request::Install {
            reference: "./look".to_owned(),
            yes: false,
            as_id: None,
            watch: true
        })
    );
    assert_eq!(
        parse(&words(&["dev", "./look", "--yes"])),
        Ok(Request::Install {
            reference: "./look".to_owned(),
            yes: true,
            as_id: None,
            watch: true
        })
    );
    assert_eq!(
        parse(&words(&["dev", "./look", "--as", "leo/try"])),
        Ok(Request::Install {
            reference: "./look".to_owned(),
            yes: false,
            as_id: Some("leo/try".to_owned()),
            watch: true
        })
    );
    assert!(parse(&words(&["update", "--watch"])).is_err());
    assert_eq!(parse(&words(&["undo"])), Ok(Request::Undo));
    assert_eq!(parse(&words(&["redo"])), Ok(Request::Redo));
    assert_eq!(
        parse(&words(&["swap", "a/b", "./c", "--yes"])),
        Ok(Request::Swap { from: "a/b".to_owned(), to: "./c".to_owned(), yes: true })
    );
    assert_eq!(parse(&words(&["variant"])), Ok(Request::Variant { words: vec![] }));
    assert_eq!(
        parse(&words(&["variant", "a/b", "dawn"])),
        Ok(Request::Variant { words: words(&["a/b", "dawn"]) })
    );
    assert_eq!(parse(&words(&["update"])), Ok(Request::Update { which: None, yes: false }));
    assert_eq!(
        parse(&words(&["remove", "a/b"])),
        Ok(Request::Remove { which: Some("a/b".to_owned()) })
    );
    assert_eq!(parse(&words(&["installed"])), Ok(Request::Installed));
    let Ok(Request::Export { dir, header, profile: None }) = parse(&words(&[
        "export",
        "out",
        "--id",
        "leo/night",
        "--repo",
        "leo/cmux-night",
        "--extension",
        "github.com/a/b",
    ])) else {
        panic!()
    };
    assert_eq!(dir, Path::new("out"));
    assert_eq!((header.id.as_str(), header.name.as_str()), ("leo/night", "night"));
    assert_eq!(header.extensions, ["github.com/a/b"]);
    let Ok(Request::Export { profile, .. }) =
        parse(&words(&["export", "out", "--id", "leo/night", "--profile", "kept-night"]))
    else {
        panic!()
    };
    assert_eq!(profile.as_deref(), Some("kept-night"));
    for bad in [
        &["install"][..],
        &["install", "a", "b"],
        &["export", "out"],
        &["export", "--id", "a/b"],
        &["export", "out", "--id", "a/b", "--profile"],
        &["installed", "x"],
        &["remove", "--yes"],
        &["undo", "x"],
        &["swap", "a/b"],
        &["variant", "a", "b", "c"],
        &["remove", "a/b", "--watch"],
        &["dev"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

/// A repo on disk and an App Store that records what it was asked.
struct World {
    repo: PathBuf,
    commit: RefCell<String>,
    installed: RefCell<Vec<String>>,
    removed: RefCell<Vec<String>>,
}

impl Apps for World {
    fn fetch(&self, _reference: &Reference) -> Result<Checkout, Failure> {
        let dir = tempfile::tempdir().unwrap().keep();
        copy(&self.repo, &dir);
        Ok(Checkout { dir, commit: self.commit.borrow().clone() })
    }

    fn info(&self, reference: &str) -> Option<Value> {
        Some(json!({
            "app": "manaflow-ai/cmux-extension-sample",
            "install": {"installed": self.installed.borrow().iter().any(|r| r == reference)},
            "scopes": ["sidebar.section", {"scope": "network"}],
        }))
    }

    fn install(&self, reference: &str) -> Result<Value, String> {
        self.installed.borrow_mut().push(reference.to_owned());
        Ok(json!({"app": "manaflow-ai/cmux-extension-sample"}))
    }

    fn remove(&self, app: &str) -> Result<(), String> {
        self.removed.borrow_mut().push(app.to_owned());
        Ok(())
    }
}

fn copy(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

const SETUP: &str = r#"{
  "cmuxSetup": 1,
  "id": "manaflow-ai/cmux-setup-sample",
  "name": "Sample Setup",
  "version": "1.0.0",
  "extensions": ["github.com/manaflow-ai/cmux-extension-sample"],
  "cmuxProfile": 1,
  "settings": { "appearance.themeFile": "sample-dusk" },
  "actions": { "sample-hello": { "type": "command", "command": "echo hello", "title": "Say Hello" } }
}
"#;

fn world(root: &Path) -> World {
    let repo = root.join("repo");
    fs::create_dir_all(repo.join("themes")).unwrap();
    fs::write(repo.join("cmux-setup.json"), SETUP).unwrap();
    fs::write(repo.join("themes/sample-dusk.json"), "{ \"name\": \"Sample Dusk\" }\n").unwrap();
    World {
        repo,
        commit: RefCell::new("1".repeat(40)),
        installed: RefCell::default(),
        removed: RefCell::default(),
    }
}

#[test]
fn without_a_yes_nothing_changes_and_the_card_comes_back() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    let Err(failure) = install(
        &customize,
        &world,
        OutputMode::Json,
        "github.com/manaflow-ai/cmux-setup-sample",
        false,
    ) else {
        panic!("it asked nobody")
    };
    assert_eq!(failure.code, "setup.needs_consent");
    let card = &failure.details;
    assert_eq!(card["setup"]["theme"], json!("sample-dusk"));
    assert_eq!(card["extensions"][0]["scopes"], json!(["sidebar.section", "network"]));
    assert_eq!(card["reviewed"], json!(false));
    let text = card_text(card);
    for line in [
        "Sample Setup (manaflow-ai/cmux-setup-sample) from github.com/manaflow-ai/cmux-setup-sample at 111111111111",
        "Not reviewed by cmux",
        "  theme: sample-dusk",
        "  setting appearance.themeFile = \"sample-dusk\"",
        "  file themes/sample-dusk.json (theme)",
        "  action sample-hello: runs command `echo hello`",
        "  extension github.com/manaflow-ai/cmux-extension-sample (installs; scopes: sidebar.section, network)",
        "Undo: cmux setup remove github.com/manaflow-ai/cmux-setup-sample",
    ] {
        assert!(text.contains(line), "{line}\n---\n{text}");
    }
    assert!(customize.setups().unwrap().is_empty());
    assert!(world.installed.borrow().is_empty());
    assert!(!root.path().join("home/config/themes/sample-dusk.json").exists());
}

#[test]
fn install_update_and_remove_round_trip() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let reference = "https://github.com/manaflow-ai/cmux-setup-sample";

    let answer = install(&customize, &world, OutputMode::Json, reference, true).unwrap();
    assert_eq!(answer["installed"]["commit"], json!("1".repeat(40)));
    assert_eq!(answer["installed"]["extensions"][0]["installed_by_setup"], json!(true));
    assert_eq!(*world.installed.borrow(), ["github.com/manaflow-ai/cmux-extension-sample"]);
    assert!(home.join("config/themes/sample-dusk.json").exists());

    // The same commit again changes nothing.
    let again = update(&customize, &world, OutputMode::Json, None, true).unwrap();
    assert_eq!(again["updated"], json!(false));

    // A new commit with a new action and no extension.
    fs::write(
        world.repo.join("cmux-setup.json"),
        SETUP
            .replace("\"extensions\": [\"github.com/manaflow-ai/cmux-extension-sample\"],", "")
            .replace("echo hello", "echo hello again"),
    )
    .unwrap();
    *world.commit.borrow_mut() = "2".repeat(40);
    let updated = update(&customize, &world, OutputMode::Json, Some(reference), true).unwrap();
    assert_eq!(updated["updated"], json!(true));
    assert_eq!(updated["from"], json!("1".repeat(40)));
    assert_eq!(*world.removed.borrow(), ["manaflow-ai/cmux-extension-sample"]);
    let settings = fs::read_to_string(home.join("config/cmux-next.json")).unwrap();
    assert!(settings.contains("echo hello again"), "{settings}");
    assert_eq!(customize.setups().unwrap().len(), 1);

    let removed = remove(&customize, &world, Some("manaflow-ai/cmux-setup-sample")).unwrap();
    assert_eq!(removed["removed"]["actions"], json!(["sample-hello"]));
    let settings = fs::read_to_string(home.join("config/cmux-next.json")).unwrap_or_default();
    assert!(!settings.contains("sample-hello") && !settings.contains("sample-dusk"), "{settings}");
    assert!(!home.join("config/themes/sample-dusk.json").exists());
    assert!(customize.setups().unwrap().is_empty());
}

#[test]
fn a_reinstall_of_the_same_commit_with_other_content_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    install(&customize, &world, OutputMode::Json, "github.com/manaflow-ai/cmux-setup-sample", true)
        .unwrap();
    fs::write(world.repo.join("themes/sample-dusk.json"), "{ \"name\": \"Changed\" }\n").unwrap();
    let Err(failure) = install(
        &customize,
        &world,
        OutputMode::Json,
        "github.com/manaflow-ai/cmux-setup-sample",
        true,
    ) else {
        panic!()
    };
    assert_eq!(failure.code, "setup.changed_at_commit");
}

#[test]
fn a_repo_whose_owner_is_not_the_ids_is_refused_before_anything() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    let Err(failure) =
        install(&customize, &world, OutputMode::Json, "github.com/someone/fork", true)
    else {
        panic!()
    };
    assert_eq!(failure.code, "customize.setup");
    assert!(world.installed.borrow().is_empty());
}

#[test]
fn the_card_shows_repo_text_inert() {
    let card = json!({
        "setup": {
            "name": "Nice\u{1b}]0;owned\u{7}\u{1b}[2J",
            "id": "a/b",
            "description": "fine\nYou may install this safely",
            "settings": [{ "key": "appearance.themeFile", "value": "x" }],
            "files": [],
            "actions": [{ "name": "hi\u{9b}31m", "kind": "command", "runs": "echo\rhi" }],
        },
        "source": { "reference": "github.com/a/b", "commit": "0123456789abcdef" },
        "reviewed": false,
        "extensions": [],
    });
    let text = card_text(&card);
    for control in ['\u{1b}', '\u{7}', '\u{9b}', '\r'] {
        assert!(!text.contains(control), "{text:?}");
    }
    assert!(!text.contains("\nYou may install"), "a repo string cannot start a card line: {text}");
    assert!(text.contains("hi\u{fffd}31m"), "{text}");
    assert_eq!(inert(&json!({"k\n": ["\u{1b}x"]})), json!({"k\u{fffd}": ["\u{fffd}x"]}));
}

#[test]
fn check_takes_a_folder_and_its_flags() {
    assert_eq!(
        parse(&words(&["check", "out", "--strict", "--owner", "leo"])),
        Ok(Request::Check { dir: "out".into(), owner: Some("leo".to_owned()), strict: true })
    );
    assert_eq!(
        parse(&words(&["check", "."])),
        Ok(Request::Check { dir: ".".into(), owner: None, strict: false })
    );
    for bad in [
        &["check"][..],
        &["check", "a", "b"],
        &["check", "a", "--owner"],
        &["check", "a", "--fix"],
        &["check", "a", "--yes"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn check_reports_every_problem_and_exits_by_severity() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let report = |dir: &Path| {
        cmux_customize::setup::check_dir(
            dir,
            &cmux_customize::setup::CheckOptions {
                owner: None,
                running: "0.0.0",
                history: &cmux_customize::setup::NoHistory,
            },
        )
    };
    // The sample installs, so it checks clean.
    let clean = report(&world.repo);
    assert_eq!(clean.findings, Vec::new());
    assert_eq!(super::check_exit(&clean, true), 0);
    assert!(super::check_text(&clean, &world.repo, false).ends_with("would take it."));
    // Two mistakes: both are named, and install would refuse.
    fs::write(
        world.repo.join("cmux-setup.json"),
        SETUP.replace("appearance.themeFile", "appearance.themeFiel"),
    )
    .unwrap();
    fs::write(world.repo.join("themes/sample-dusk.json"), "{ \"name\": ").unwrap();
    let broken = report(&world.repo);
    assert_eq!(broken.errors(), 2, "{:?}", broken.findings);
    assert_eq!(super::check_exit(&broken, false), 1);
    let text = super::check_text(&broken, &world.repo, false);
    assert!(text.contains("error[setting.unknown]"), "{text}");
    assert!(text.contains("fix: did you mean appearance.themeFile?"), "{text}");
    assert!(text.contains("error[file.invalid] themes/sample-dusk.json"), "{text}");
    assert!(text.contains("2 errors, 0 warnings"), "{text}");
}

#[test]
fn install_takes_a_folder_and_as_only_with_one() {
    assert_eq!(
        parse(&words(&["install", "./look", "--as", "leo/try", "--yes"])),
        Ok(Request::Install {
            reference: "./look".to_owned(),
            yes: true,
            as_id: Some("leo/try".to_owned()),
            watch: false
        })
    );
    assert!(parse(&words(&["install", "./look", "--as"])).is_err());
    assert!(parse(&words(&["install", "--as", "leo/try"])).is_err());
}

#[test]
fn a_folder_installs_like_a_repo_and_is_kept_as_its_source() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let folder = world.repo.to_str().unwrap().to_owned();

    let answer = install(&customize, &world, OutputMode::Json, &folder, true).unwrap();
    let installed = &answer["installed"];
    assert_eq!(installed["id"], json!("manaflow-ai/cmux-setup-sample"));
    assert_eq!(installed["source"]["kind"], json!("folder"));
    assert_eq!(installed["source"]["path"], json!(world.repo.canonicalize().unwrap()));
    assert!(installed.get("reference").is_none() && installed.get("local").is_none());
    assert!(installed["commit"].as_str().unwrap().starts_with("local-"), "{installed}");
    assert_eq!(answer["page"], Value::Null);
    assert_eq!(answer["undo"], json!("cmux setup remove manaflow-ai/cmux-setup-sample"));
    assert!(card_text(&answer["card"]).contains("straight from this folder"));
    assert!(home.join("config/themes/sample-dusk.json").exists());

    // Unchanged, an update changes nothing; changed, it moves to what the folder holds.
    let again = update(&customize, &world, OutputMode::Json, None, true).unwrap();
    assert_eq!(again["updated"], json!(false));
    fs::write(world.repo.join("cmux-setup.json"), SETUP.replace("echo hello", "echo hi again"))
        .unwrap();
    let updated = update(&customize, &world, OutputMode::Json, None, true).unwrap();
    assert_eq!(updated["updated"], json!(true));
    let settings = fs::read_to_string(home.join("config/cmux-next.json")).unwrap();
    assert!(settings.contains("echo hi again"), "{settings}");
    assert_eq!(customize.setups().unwrap().len(), 1);

    remove(&customize, &world, Some("manaflow-ai/cmux-setup-sample")).unwrap();
    assert!(!home.join("config/themes/sample-dusk.json").exists());
    assert!(customize.setups().unwrap().is_empty());
}

#[test]
fn as_names_a_local_try_and_a_repo_refuses_it() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    // A look whose id is reserved installs from a folder only under an id of one's own.
    fs::write(
        world.repo.join("cmux-setup.json"),
        SETUP.replace("manaflow-ai/cmux-setup-sample", "cmux/studio"),
    )
    .unwrap();
    let folder = world.repo.to_str().unwrap().to_owned();
    assert!(install(&customize, &world, OutputMode::Json, &folder, true).is_err());
    let answer =
        install_as(&customize, &world, OutputMode::Json, &folder, true, Some("leo/studio-try"))
            .unwrap();
    assert_eq!(answer["installed"]["id"], json!("leo/studio-try"));
    assert!(answer["installed"]["library"].is_string(), "{answer}");
    let Err(failure) = install_as(
        &customize,
        &world,
        OutputMode::Json,
        "github.com/leo/night",
        true,
        Some("leo/night"),
    ) else {
        panic!()
    };
    assert_eq!(failure.code, "usage.invalid");
    // A path with no setup in it is named, and nothing is installed.
    let empty = root.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    let Err(failure) = install(&customize, &world, OutputMode::Json, empty.to_str().unwrap(), true)
    else {
        panic!()
    };
    assert_eq!(failure.code, "setup.not_a_setup");
    assert_eq!(customize.setups().unwrap().len(), 1);
}

/// A setup folder with views: `customize/cmux-app.json` as `local/customize`
/// (as a repo holds it) and one script.
fn views_setup(root: &Path, id: &str, theme: &str) -> PathBuf {
    let dir = root.join(id.replace('/', "-"));
    fs::create_dir_all(dir.join("customize")).unwrap();
    fs::create_dir_all(dir.join("themes")).unwrap();
    fs::write(
        dir.join(format!("themes/{theme}.json")),
        "{ \"name\": \"T\", \"colors\": { \"background\": \"#101010\" } }\n",
    )
    .unwrap();
    fs::write(
        dir.join("cmux-setup.json"),
        format!(
            r#"{{"cmuxSetup": 1, "id": "{id}", "name": "{id}", "cmuxProfile": 1,
               "settings": {{"appearance.themeFile": "{theme}"}}}}"#
        ),
    )
    .unwrap();
    fs::write(dir.join("customize/main.js"), format!("// {id}\nvar __cmuxAppExports = {{}};\n"))
        .unwrap();
    fs::write(
        dir.join("customize/cmux-app.json"),
        r#"{"manifestVersion": 2, "id": "local/customize", "name": "Views", "version": "1.0.0",
            "description": "A view", "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
            "files": ["main.js"]}"#,
    )
    .unwrap();
    dir
}

#[test]
fn two_folders_stack_as_layers_that_turn_off_reorder_and_remove_alone() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let mine = home.join("config/customize/main.js");
    fs::create_dir_all(mine.parent().unwrap()).unwrap();
    fs::write(&mine, "// mine\n").unwrap();
    let dusk = views_setup(root.path(), "leo/dusk", "dusk");
    let dawn = views_setup(root.path(), "leo/dawn", "dawn");
    for dir in [&dusk, &dawn] {
        install(&customize, &world, OutputMode::Json, dir.to_str().unwrap(), true).unwrap();
    }
    let setups = home.join("config/setups");
    let index = |setups: &Path| -> Vec<String> {
        let index: Value =
            serde_json::from_str(&fs::read_to_string(setups.join("layers.json")).unwrap()).unwrap();
        index["layers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["app"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(index(&setups), ["local/setup-leo-dawn", "local/setup-leo-dusk"], "newest on top");
    let manifest: Value = serde_json::from_str(
        &fs::read_to_string(setups.join("setup-leo-dusk/cmux-app.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["id"], json!("local/setup-leo-dusk"));
    assert_eq!(fs::read_to_string(&mine).unwrap(), "// mine\n", "your own views are not written");

    let off = parse(&words(&["off", "leo/dawn"])).unwrap();
    assert_eq!(off, Request::On { which: Some("leo/dawn".to_owned()), on: false });
    set_on(&customize, &world, Some("leo/dawn"), false).unwrap();
    assert_eq!(index(&setups), ["local/setup-leo-dusk"]);
    assert!(setups.join("setup-leo-dawn/main.js").exists(), "off keeps it installed");
    set_on(&customize, &world, Some("leo/dawn"), true).unwrap();
    order(&customize, &world, &["leo/dusk".to_owned()]).unwrap();
    assert_eq!(index(&setups), ["local/setup-leo-dusk", "local/setup-leo-dawn"]);

    remove(&customize, &world, Some(dusk.to_str().unwrap())).unwrap();
    assert_eq!(index(&setups), ["local/setup-leo-dawn"]);
    assert!(!setups.join("setup-leo-dusk").exists());
    assert!(setups.join("setup-leo-dawn/main.js").exists());
    assert_eq!(fs::read_to_string(&mine).unwrap(), "// mine\n");

    // One id, one install: the same id from another folder needs --as.
    let twin = root.path().join("twin");
    copy(&dawn, &twin);
    let Err(failure) = install(&customize, &world, OutputMode::Json, twin.to_str().unwrap(), true)
    else {
        panic!()
    };
    assert_eq!(failure.code, "setup.id_taken");
}

#[test]
fn the_grammar_takes_gallery_and_preview() {
    assert_eq!(parse(&words(&["gallery"])), Ok(Request::Gallery));
    assert_eq!(
        parse(&words(&["preview", "manaflow-ai/paper-look"])),
        Ok(Request::Preview { which: "manaflow-ai/paper-look".to_owned(), scheme: Scheme::Dark })
    );
    assert_eq!(
        parse(&words(&["preview", "--scheme", "light", "github.com/a/b"])),
        Ok(Request::Preview { which: "github.com/a/b".to_owned(), scheme: Scheme::Light })
    );
    for bad in [
        &["gallery", "x"][..],
        &["gallery", "--yes"],
        &["preview"],
        &["preview", "a/b", "c/d"],
        &["preview", "a/b", "--scheme"],
        &["preview", "a/b", "--scheme", "dim"],
        &["preview", "a/b", "--size", "2"],
        &["preview", "a/b", "--yes"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn an_empty_machine_gets_every_look_and_no_stack() {
    let root = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(root.path()));
    let answer = gallery(&customize).unwrap();
    let looks = answer["looks"].as_array().unwrap();
    assert_eq!(looks.len(), cmux_customize::setup::looks::catalog().unwrap().looks.len());
    assert_eq!(
        looks[0],
        json!({
            "id": "manaflow-ai/codex-profile",
            "name": "Pebble",
            "tagline": "Clean, quiet, sidebar of threads.",
            "repo": "github.com/manaflow-ai/cmux/examples/looks/codex/profile@feat-cmux-next",
            "tags": ["chat", "sidebar", "new-tab"],
            "traits": ["Light", "Round corners"],
            "installed": null,
        })
    );
    assert_eq!(answer["stack"], json!([]));
}

#[test]
fn the_gallery_shows_installed_looks_in_the_stack_with_other_setups() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    let paper = views_setup(root.path(), "manaflow-ai/paper-look", "paper");
    let dusk = views_setup(root.path(), "leo/dusk", "dusk");
    for dir in [&paper, &dusk] {
        install(&customize, &world, OutputMode::Json, dir.to_str().unwrap(), true).unwrap();
    }
    set_on(&customize, &world, Some("manaflow-ai/paper-look"), false).unwrap();
    let answer = gallery(&customize).unwrap();
    let stack = answer["stack"].as_array().unwrap();
    let rows: Vec<(&str, u64, bool, bool)> = stack
        .iter()
        .map(|row| {
            (
                row["id"].as_str().unwrap(),
                row["position"].as_u64().unwrap(),
                row["on"].as_bool().unwrap(),
                row["catalog"].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(rows, [("leo/dusk", 1, true, false), ("manaflow-ai/paper-look", 2, false, true)]);
    let paper_row = answer["looks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|look| look["id"] == "manaflow-ai/paper-look")
        .unwrap();
    assert_eq!(paper_row["installed"], stack[1]);
    assert_eq!(answer["looks"][0]["installed"], json!(null));
}

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage";

#[test]
fn a_preview_is_fetched_once_kept_a_day_and_falls_back_file_by_file() {
    let root = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(root.path()));
    let asked = RefCell::new(Vec::<String>::new());
    let mut get = |url: &str| -> Result<Option<Vec<u8>>, String> {
        asked.borrow_mut().push(url.to_owned());
        Ok(url.ends_with("screenshots/chat.png").then(|| PNG.to_vec()))
    };
    let now = 1_000_000;
    let first = preview(&customize, "manaflow-ai/paper-look", Scheme::Dark, &mut get, now).unwrap();
    assert_eq!(first["path"], "screenshots/chat.png");
    assert_eq!(first["cached"], json!(false));
    assert_eq!(first["scheme"], "dark");
    assert_eq!(first["id"], "manaflow-ai/paper-look");
    assert_eq!(first["dataUrl"], "data:image/png;base64,iVBORw0KGgppbWFnZQ==");
    assert_eq!(
        *asked.borrow(),
        [
            "https://raw.githubusercontent.com/manaflow-ai/cmux-paper-look/HEAD/preview/golden-dark.png",
            "https://raw.githubusercontent.com/manaflow-ai/cmux-paper-look/HEAD/preview/golden-light.png",
            "https://raw.githubusercontent.com/manaflow-ai/cmux-paper-look/HEAD/screenshots/chat.png",
        ]
    );
    assert!(root.path().join("state/looks/previews/manaflow-ai-paper-look/dark.png").is_file());
    // By its repo too, from the cache, without a request.
    asked.borrow_mut().clear();
    let again = preview(
        &customize,
        "https://github.com/manaflow-ai/cmux-paper-look",
        Scheme::Dark,
        &mut get,
        now + 1000,
    )
    .unwrap();
    assert_eq!(
        (again["cached"].clone(), again["path"].clone()),
        (json!(true), first["path"].clone())
    );
    assert!(asked.borrow().is_empty());
    // A day on, it is fetched again.
    preview(&customize, "manaflow-ai/paper-look", Scheme::Dark, &mut get, now + 86_400_000)
        .unwrap();
    assert_eq!(asked.borrow().len(), 3);
}

#[test]
fn a_repo_with_no_preview_is_refused_and_that_is_kept_too() {
    let root = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(root.path()));
    let asked = RefCell::new(0);
    let mut get = |_: &str| -> Result<Option<Vec<u8>>, String> {
        *asked.borrow_mut() += 1;
        // A page that is not a PNG counts as no file.
        Ok(Some(b"<html>".to_vec()))
    };
    for _ in 0..2 {
        let Err(failure) =
            preview(&customize, "manaflow-ai/paper-look", Scheme::Light, &mut get, 5)
        else {
            panic!()
        };
        assert_eq!(failure.code, "setup.preview_missing");
        assert_eq!(failure.details["tried"][0], "preview/golden-light.png");
    }
    assert_eq!(*asked.borrow(), 3, "the second ask is answered from the cache");
    let mut broken = |_: &str| -> Result<Option<Vec<u8>>, String> { Err("offline".to_owned()) };
    let Err(failure) = preview(&customize, "manaflow-ai/paper-look", Scheme::Dark, &mut broken, 5)
    else {
        panic!()
    };
    assert_eq!(failure.code, "setup.preview_fetch");
    let Err(failure) = preview(&customize, "nobody/nothing", Scheme::Dark, &mut broken, 5) else {
        panic!()
    };
    assert_eq!(failure.code, "customize.setup");
}

#[test]
fn an_installed_folders_preview_is_read_in_place() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    let paper = views_setup(root.path(), "manaflow-ai/paper-look", "paper");
    install(&customize, &world, OutputMode::Json, paper.to_str().unwrap(), true).unwrap();
    let mut never = |url: &str| -> Result<Option<Vec<u8>>, String> { panic!("fetched {url}") };
    let Err(failure) = preview(&customize, "manaflow-ai/paper-look", Scheme::Dark, &mut never, 5)
    else {
        panic!()
    };
    assert_eq!(failure.code, "setup.preview_missing");
    fs::create_dir_all(paper.join("preview")).unwrap();
    fs::write(paper.join("preview/golden-light.png"), PNG).unwrap();
    let answer =
        preview(&customize, "manaflow-ai/paper-look", Scheme::Dark, &mut never, 5).unwrap();
    assert_eq!(
        (answer["path"].clone(), answer["cached"].clone()),
        (json!("preview/golden-light.png"), json!(false))
    );
}

/// `git` in `dir` for the test's own repo; its output.
fn sh_git(dir: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[test]
fn a_setup_in_a_folder_of_a_big_repo_fetches_only_that_folder() {
    // A look in a monorepo (`github.com/manaflow-ai/cmux/examples/looks/studio`):
    // the whole commit of cmux is 614 MB, the look's folder a few KB.
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().join("repo");
    fs::create_dir_all(repo.join("looks/studio/themes")).unwrap();
    fs::write(repo.join("looks/studio/cmux-setup.json"), SETUP).unwrap();
    fs::write(repo.join("looks/studio/themes/sample-dusk.json"), "{}\n").unwrap();
    fs::create_dir_all(repo.join("app")).unwrap();
    fs::write(repo.join("app/big.bin"), vec![7u8; 1 << 20]).unwrap();
    sh_git(&repo, &["init", "-q", "-b", "main"]);
    sh_git(&repo, &["config", "uploadpack.allowFilter", "true"]);
    sh_git(&repo, &["add", "."]);
    sh_git(&repo, &["commit", "-q", "-m", "x"]);
    let big = sh_git(&repo, &["rev-parse", "HEAD:app/big.bin"]);
    let url = format!("file://{}", repo.display());

    let reference = Reference::parse("github.com/a/b/looks/studio@main").unwrap();
    let checkout = fetch_from(&reference, &url, &["-c", "protocol.file.allow=always"]).unwrap();

    assert_eq!(checkout.commit, sh_git(&repo, &["rev-parse", "HEAD"]));
    assert!(checkout.dir.join("looks/studio/cmux-setup.json").is_file());
    assert!(checkout.dir.join("looks/studio/themes/sample-dusk.json").is_file());
    assert!(!checkout.dir.join("app/big.bin").exists(), "a file outside the setup was checked out");
    // `--missing=print` lists an object it lacks as `?ID` and fetches nothing.
    let objects = sh_git(&checkout.dir, &["rev-list", "--objects", "--missing=print", "HEAD"]);
    assert!(objects.lines().any(|line| line == format!("?{big}")), "{big} was fetched:\n{objects}");

    // A setup at the repo's root still gets the whole commit.
    let whole = fetch_from(
        &Reference::parse("github.com/a/b@main").unwrap(),
        &url,
        &["-c", "protocol.file.allow=always"],
    )
    .unwrap();
    assert!(whole.dir.join("app/big.bin").is_file());
}

/// A world whose looks are folders on this computer: a fetch is a bug.
struct Local;

impl Apps for Local {
    fn fetch(&self, reference: &Reference) -> Result<Checkout, Failure> {
        panic!("a folder on this computer was fetched: {reference}")
    }
    fn info(&self, _reference: &str) -> Option<Value> {
        None
    }
    fn install(&self, reference: &str) -> Result<Value, String> {
        Err(format!("no App Store here: {reference}"))
    }
    fn remove(&self, _app: &str) -> Result<(), String> {
        Ok(())
    }
}

/// A look in a folder: id `leo/NAME`, picking theme `NAME-dusk`, shipping
/// `NAME-dusk` and `NAME-dawn`.
fn look(root: &Path, name: &str) -> PathBuf {
    let dir = root.join(name);
    fs::create_dir_all(dir.join("themes")).unwrap();
    fs::write(
        dir.join("cmux-setup.json"),
        format!(
            r#"{{ "cmuxSetup": 1, "id": "leo/{name}", "name": "{name}", "version": "1.0.0",
  "cmuxProfile": 1, "settings": {{ "appearance.themeFile": "{name}-dusk" }} }}"#
        ),
    )
    .unwrap();
    fs::write(dir.join(format!("themes/{name}-dusk.json")), "{ \"name\": \"dusk 1\" }\n").unwrap();
    fs::write(dir.join(format!("themes/{name}-dawn.json")), "{ \"name\": \"dawn\" }\n").unwrap();
    // Views: its own layer under the setups folder.
    fs::create_dir_all(dir.join("customize")).unwrap();
    fs::write(dir.join("customize/main.js"), "// views 1\nvar __cmuxAppExports = {};\n").unwrap();
    fs::write(
        dir.join("customize/cmux-app.json"),
        r#"{"manifestVersion": 2, "id": "local/customize", "name": "Views", "version": "1.0.0",
            "description": "A view", "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
            "files": ["main.js"]}"#,
    )
    .unwrap();
    dir
}

/// The views file of look `name`'s layer.
fn view(home: &Path, name: &str) -> PathBuf {
    home.join(format!("config/setups/setup-leo-{name}/main.js"))
}

fn text(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

#[test]
fn a_look_in_a_folder_installs_in_place_and_every_save_reloads_as_one_undo_step() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let dir = look(root.path(), "night");
    let path = dir.display().to_string();
    let theme = home.join("config/themes/night-dusk.json");

    let answer = stepped(&customize, "install", "install night", || {
        install(&customize, &Local, OutputMode::Json, &path, true)
    })
    .unwrap();
    assert_eq!(answer["installed"]["source"]["path"], json!(dir.canonicalize().unwrap()));
    assert!(text(&theme).contains("dusk 1"));
    assert!(text(&view(&home, "night")).contains("views 1"));
    assert!(dir.join("cmux-setup.json").exists(), "the folder is read in place, never removed");

    // Three saves while watching: each reloads, all one step.
    let source = SetupSource::Folder { path: dir.canonicalize().unwrap() };
    let mut session = None::<String>;
    for n in 2..=4 {
        fs::write(dir.join("themes/night-dusk.json"), format!("{{ \"name\": \"dusk {n}\" }}\n"))
            .unwrap();
        fs::write(
            dir.join("customize/main.js"),
            format!("// views {n}\nvar __cmuxAppExports = {{}};\n"),
        )
        .unwrap();
        let (value, step) =
            reload(&customize, &Local, OutputMode::Json, &source, None, session.as_deref())
                .unwrap();
        assert_eq!(value["updated"], json!(true), "save {n}");
        assert!(text(&theme).contains(&format!("dusk {n}")), "save {n}");
        assert!(text(&view(&home, "night")).contains(&format!("views {n}")), "save {n}");
        session = Some(step);
    }
    // A save that changes nothing is no reload.
    let (same, _) =
        reload(&customize, &Local, OutputMode::Json, &source, None, session.as_deref()).unwrap();
    assert_eq!(same["updated"], json!(false));
    let history = customize.setup_history();
    assert_eq!(
        history.steps.iter().map(|step| step.verb.as_str()).collect::<Vec<_>>(),
        ["install", "reload"]
    );

    // A save that does not read keeps the last good look.
    fs::write(dir.join("cmux-setup.json"), "{ not json").unwrap();
    assert!(
        reload(&customize, &Local, OutputMode::Json, &source, None, session.as_deref()).is_err()
    );
    assert!(text(&theme).contains("dusk 4"));

    // Undo: the live edits, whole; then the install.
    undo_redo(&customize, &Local, false).unwrap();
    assert!(text(&theme).contains("dusk 1"), "{}", text(&theme));
    assert!(text(&view(&home, "night")).contains("views 1"), "the layer goes back with it");
    undo_redo(&customize, &Local, false).unwrap();
    assert!(!theme.exists());
    assert!(!view(&home, "night").exists(), "no layer is left for a setup that is gone");
    assert!(customize.setups().unwrap().is_empty());
    assert!(undo_redo(&customize, &Local, false).is_err(), "nothing left to undo");
    // Redo: back on, then the edits.
    undo_redo(&customize, &Local, true).unwrap();
    assert!(text(&theme).contains("dusk 1"));
    assert!(text(&view(&home, "night")).contains("views 1"));
    assert_eq!(customize.setups().unwrap().len(), 1);
    undo_redo(&customize, &Local, true).unwrap();
    assert!(text(&theme).contains("dusk 4"));
    assert!(text(&view(&home, "night")).contains("views 4"));
}

#[test]
fn swap_is_one_step_and_a_swap_that_fails_puts_the_old_look_back() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let night = look(root.path(), "night").display().to_string();
    let day = look(root.path(), "day").display().to_string();
    let settings = home.join("config/cmux-next.json");

    stepped(&customize, "install", "install night", || {
        install(&customize, &Local, OutputMode::Json, &night, true)
    })
    .unwrap();
    let swapped = stepped(&customize, "swap", "swap night for day", || {
        swap(&customize, &Local, OutputMode::Json, "leo/night", &day, true)
    })
    .unwrap();
    assert_eq!(swapped["swapped"]["from"], json!("leo/night"));
    let ids: Vec<_> = customize.setups().unwrap().into_iter().map(|setup| setup.id).collect();
    assert_eq!(ids, ["leo/day"]);
    assert!(text(&settings).contains("day-dusk") && !text(&settings).contains("night-dusk"));

    assert!(view(&home, "day").exists() && !view(&home, "night").exists());

    // One undo puts night back whole, its layer too.
    undo_redo(&customize, &Local, false).unwrap();
    let ids: Vec<_> = customize.setups().unwrap().into_iter().map(|setup| setup.id).collect();
    assert_eq!(ids, ["leo/night"]);
    assert!(view(&home, "night").exists() && !view(&home, "day").exists());
    assert!(text(&settings).contains("night-dusk"), "{}", text(&settings));
    assert!(home.join("config/themes/night-dusk.json").exists());

    // A swap to a folder that is not a look leaves night on.
    let nothing = root.path().join("nothing");
    fs::create_dir_all(&nothing).unwrap();
    let nothing = nothing.display().to_string();
    assert!(swap(&customize, &Local, OutputMode::Json, "leo/night", &nothing, true).is_err());
    let ids: Vec<_> = customize.setups().unwrap().into_iter().map(|setup| setup.id).collect();
    assert_eq!(ids, ["leo/night"]);
    assert!(text(&settings).contains("night-dusk"));
    assert!(home.join("config/themes/night-dusk.json").exists());
    assert!(view(&home, "night").exists());

    // Under another look, the new one takes night's place in the order.
    let dusk = look(root.path(), "dusk").display().to_string();
    install(&customize, &Local, OutputMode::Json, &dusk, true).unwrap();
    swap(&customize, &Local, OutputMode::Json, "leo/night", &day, true).unwrap();
    let ids: Vec<_> = customize.setups().unwrap().into_iter().map(|setup| setup.id).collect();
    assert_eq!(ids, ["leo/dusk", "leo/day"]);
}

#[test]
fn a_variant_is_picked_in_the_looks_layer_and_goes_with_it() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let customize = Customize::open(Roots::under(&home));
    let night = look(root.path(), "night").display().to_string();
    let settings = home.join("config/cmux-next.json");
    stepped(&customize, "install", "install night", || {
        install(&customize, &Local, OutputMode::Json, &night, true)
    })
    .unwrap();

    let listed = variant(&customize, &[]).unwrap();
    assert_eq!(listed["variants"]["variants"], json!(["night-dawn", "night-dusk"]));
    assert_eq!(listed["variants"]["picked"], json!("night-dusk"));
    assert!(variant(&customize, &["leo/night".to_owned(), "noon".to_owned()]).is_err());

    let words = ["leo/night".to_owned(), "night-dawn".to_owned()];
    let picked =
        stepped(&customize, "variant", "variant night-dawn", || variant(&customize, &words))
            .unwrap();
    assert_eq!(picked["variants"]["picked"], json!("night-dawn"));
    assert!(text(&settings).contains("night-dawn"), "{}", text(&settings));

    undo_redo(&customize, &Local, false).unwrap();
    assert!(text(&settings).contains("night-dusk") && !text(&settings).contains("night-dawn"));
    undo_redo(&customize, &Local, true).unwrap();
    assert!(text(&settings).contains("night-dawn"));

    // Removing the look takes the variant off with it: no theme file left named.
    remove(&customize, &Local, Some("leo/night")).unwrap();
    assert!(!text(&settings).contains("night-"), "{}", text(&settings));
}

#[test]
fn install_link_takes_one_link_and_never_a_yes() {
    let link = "cmux://setups/install?repo=github.com%2Fa%2Fb";
    assert_eq!(
        parse(&words(&["install-link", link])),
        Ok(Request::InstallLink { link: link.to_owned() })
    );
    assert!(parse(&words(&["install-link", link, "--yes"])).is_err());
    assert!(parse(&words(&["install-link"])).is_err());
    assert!(parse(&words(&["install-link", link, link])).is_err());
}

#[test]
fn a_setup_pages_open_in_cmux_link_asks_with_the_card_and_its_pinned_reference() {
    let root = tempfile::tempdir().unwrap();
    let world = world(root.path());
    let customize = Customize::open(Roots::under(&root.path().join("home")));
    let commit = "1".repeat(40);
    let link = format!(
        "cmux://setups/install?repo=github.com%2Fmanaflow-ai%2Fcmux-setup-sample&commit={commit}"
    );
    let Err(failure) = install_link(&customize, &world, OutputMode::Json, &link) else {
        panic!("a link installed without asking")
    };
    assert_eq!(failure.code, "setup.needs_consent");
    assert_eq!(
        failure.details["reference"],
        json!(format!("github.com/manaflow-ai/cmux-setup-sample@{commit}"))
    );
    let text = failure.details["text"].as_str().unwrap();
    assert!(text.contains("Sample Setup (manaflow-ai/cmux-setup-sample)"), "{text}");
    assert!(customize.setups().unwrap().is_empty());
    assert!(world.installed.borrow().is_empty());
    // An extension's link, another kind, or one with a flag is not a setup link.
    for bad in [
        "cmux://apps/install?repo=github.com/a/b",
        "cmux://setups/install?repo=github.com/a/b&yes=1",
        "cmux://setups/install?repo=github.com/a/b&commit=main",
        "https://setups/install?repo=github.com/a/b",
    ] {
        let Err(failure) = install_link(&customize, &world, OutputMode::Json, bad) else {
            panic!("{bad} was taken")
        };
        assert_eq!(failure.code, "setup.link", "{bad}");
    }
}
