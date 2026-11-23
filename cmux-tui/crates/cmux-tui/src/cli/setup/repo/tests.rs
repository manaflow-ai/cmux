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
use super::{
    Apps, Checkout, Failure, Request, card_text, fetch_from, inert, install, parse, reload, remove,
    stepped, swap, undo_redo, update, variant,
};

fn words(text: &[&str]) -> Vec<String> {
    text.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn the_grammar_takes_each_verb_and_refuses_the_rest() {
    assert_eq!(
        parse(&words(&["install", "github.com/a/b", "--yes"])),
        Ok(Request::Install { reference: "github.com/a/b".to_owned(), yes: true, watch: false })
    );
    assert_eq!(
        parse(&words(&["install", "./look", "--watch"])),
        Ok(Request::Install { reference: "./look".to_owned(), yes: false, watch: true })
    );
    assert_eq!(
        parse(&words(&["dev", "./look", "--yes"])),
        Ok(Request::Install { reference: "./look".to_owned(), yes: true, watch: true })
    );
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
    repo: std::path::PathBuf,
    commit: RefCell<String>,
    installed: RefCell<Vec<String>>,
    removed: RefCell<Vec<String>>,
}

impl Apps for World {
    fn fetch(&self, _reference: &Reference) -> Result<Checkout, Failure> {
        let dir = tempfile::tempdir().unwrap().keep();
        copy(&self.repo, &dir);
        Ok(Checkout { dir, commit: self.commit.borrow().clone(), keep: false })
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
fn look(root: &Path, name: &str) -> std::path::PathBuf {
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
    dir
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
    assert_eq!(answer["installed"]["reference"]["dir"], json!(path));
    assert!(text(&theme).contains("dusk 1"));
    assert!(dir.join("cmux-setup.json").exists(), "the folder is read in place, never removed");

    // Three saves while watching: each reloads, all one step.
    let mut session = None::<String>;
    for n in 2..=4 {
        fs::write(dir.join("themes/night-dusk.json"), format!("{{ \"name\": \"dusk {n}\" }}\n"))
            .unwrap();
        let reference = Reference::parse_any(&path).unwrap();
        let (value, step) =
            reload(&customize, &Local, OutputMode::Json, &reference, session.as_deref()).unwrap();
        assert_eq!(value["updated"], json!(true), "save {n}");
        assert!(text(&theme).contains(&format!("dusk {n}")), "save {n}");
        session = Some(step);
    }
    // A save that changes nothing is no reload.
    let reference = Reference::parse_any(&path).unwrap();
    let (same, _) =
        reload(&customize, &Local, OutputMode::Json, &reference, session.as_deref()).unwrap();
    assert_eq!(same["updated"], json!(false));
    let history = customize.setup_history();
    assert_eq!(
        history.steps.iter().map(|step| step.verb.as_str()).collect::<Vec<_>>(),
        ["install", "reload"]
    );

    // A save that does not read keeps the last good look.
    fs::write(dir.join("cmux-setup.json"), "{ not json").unwrap();
    assert!(reload(&customize, &Local, OutputMode::Json, &reference, session.as_deref()).is_err());
    assert!(text(&theme).contains("dusk 4"));

    // Undo: the live edits, whole; then the install.
    undo_redo(&customize, false).unwrap();
    assert!(text(&theme).contains("dusk 1"), "{}", text(&theme));
    undo_redo(&customize, false).unwrap();
    assert!(!theme.exists());
    assert!(customize.setups().unwrap().is_empty());
    assert!(undo_redo(&customize, false).is_err(), "nothing left to undo");
    // Redo: back on, then the edits.
    undo_redo(&customize, true).unwrap();
    assert!(text(&theme).contains("dusk 1"));
    assert_eq!(customize.setups().unwrap().len(), 1);
    undo_redo(&customize, true).unwrap();
    assert!(text(&theme).contains("dusk 4"));
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

    // One undo puts night back whole.
    undo_redo(&customize, false).unwrap();
    let ids: Vec<_> = customize.setups().unwrap().into_iter().map(|setup| setup.id).collect();
    assert_eq!(ids, ["leo/night"]);
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

    undo_redo(&customize, false).unwrap();
    assert!(text(&settings).contains("night-dusk") && !text(&settings).contains("night-dawn"));
    undo_redo(&customize, true).unwrap();
    assert!(text(&settings).contains("night-dawn"));

    // Removing the look takes the variant off with it: no theme file left named.
    remove(&customize, &Local, Some("leo/night")).unwrap();
    assert!(!text(&settings).contains("night-"), "{}", text(&settings));
}
