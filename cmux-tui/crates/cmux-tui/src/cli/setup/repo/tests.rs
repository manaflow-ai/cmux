//! The grammar, the consent card, and install, update and remove with a
//! stand-in repo and App Store. The file model's own journeys are the
//! `cmux-customize` crate's `tests/setup.rs`.

use std::cell::RefCell;
use std::fs;
use std::path::Path;

use cmux_customize::setup::Reference;
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

use super::super::super::OutputMode;
use super::{Apps, Checkout, Failure, Request, card_text, inert, install, parse, remove, update};

fn words(text: &[&str]) -> Vec<String> {
    text.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn the_grammar_takes_each_verb_and_refuses_the_rest() {
    assert_eq!(
        parse(&words(&["install", "github.com/a/b", "--yes"])),
        Ok(Request::Install { reference: "github.com/a/b".to_owned(), yes: true })
    );
    assert_eq!(parse(&words(&["update"])), Ok(Request::Update { which: None, yes: false }));
    assert_eq!(
        parse(&words(&["remove", "a/b"])),
        Ok(Request::Remove { which: Some("a/b".to_owned()) })
    );
    assert_eq!(parse(&words(&["installed"])), Ok(Request::Installed));
    let Ok(Request::Export { dir, header }) = parse(&words(&[
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
    for bad in [
        &["install"][..],
        &["install", "a", "b"],
        &["export", "out"],
        &["export", "--id", "a/b"],
        &["installed", "x"],
        &["remove", "--yes"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

/// A repo on disk and an App Store that records what it was asked.
struct World {
    repo: std::path::PathBuf,
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
