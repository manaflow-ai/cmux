//! Pull request entries: a PR's web layer goes live as web-dev.json's
//! overlay, the higher one that is on wins, and turning the last one off
//! writes back exactly what web-dev.json had, leaving its other keys alone.

use std::fs;
use std::path::PathBuf;

use cmux_customize::library::CodeLayer;
use cmux_customize::{Customize, Roots};
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

    fn web_dev_path(&self) -> PathBuf {
        self.dir.path().join("config/web-dev.json")
    }

    fn web_dev(&self) -> Option<Value> {
        fs::read_to_string(self.web_dev_path()).ok().map(|t| serde_json::from_str(&t).unwrap())
    }

    fn write_web_dev(&self, value: Value) {
        fs::create_dir_all(self.dir.path().join("config")).unwrap();
        fs::write(self.web_dev_path(), serde_json::to_string(&value).unwrap()).unwrap();
    }
}

fn key(n: u8) -> String {
    format!("{n:064x}")
}

fn layer(pr: u64, n: u8) -> CodeLayer {
    CodeLayer {
        repo: "manaflow-ai/cmux".to_owned(),
        pr,
        title: format!("pr {pr}"),
        head: format!("{n:040x}"),
        base: format!("{:040x}", 99_u8),
        web: key(n),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    }
}

/// Installs layer `n` the way the CLI does: the folder, manifest last.
fn install(customize: &Customize, n: u8) -> String {
    let dir = customize.layer_dir(&key(n));
    fs::create_dir_all(dir.join("pages")).unwrap();
    fs::write(dir.join("manifest.json"), "{}").unwrap();
    dir.to_string_lossy().into_owned()
}

#[test]
fn a_pr_goes_live_and_off_puts_back_exactly_what_was_there() {
    let home = Home::new();
    let customize = home.customize();
    let before = json!({"server": "http://127.0.0.1:4200/", "token": "t", "overlay": "/old", "enabled": false});
    home.write_web_dev(before.clone());
    let dir = install(&customize, 1);

    let changed =
        customize.library_use_code(layer(43496, 1), vec!["try it".into()], "cli", 1).unwrap();
    assert!(changed.changed.contains(&"code:web".to_owned()));
    let live = home.web_dev().unwrap();
    assert_eq!(live["overlay"], json!(dir));
    assert_eq!(live["enabled"], json!(true));
    assert_eq!(live["server"], before["server"], "other keys stay");
    let listed = &changed.library.entries[0];
    assert_eq!(listed.name, "pr-43496");
    assert_eq!(listed.source, "pr");
    assert!(listed.on);
    assert_eq!(listed.code.as_ref().unwrap().pr, 43496);

    customize.library_set_on("pr-43496", false, "cli", 2).unwrap();
    assert_eq!(home.web_dev().unwrap(), before);
}

#[test]
fn keys_that_were_absent_are_removed_again() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(1, 1), vec![], "cli", 1).unwrap();
    assert!(home.web_dev().unwrap().get("overlay").is_some());
    customize.library_remove("pr-1", "cli", 2).unwrap();
    // There was no web-dev.json: it is left with neither key.
    let after = home.web_dev().unwrap_or(json!({}));
    assert_eq!(after, json!({}));
    assert!(customize.library().unwrap().entries.is_empty());
}

#[test]
fn the_higher_pr_wins_and_off_restores_the_one_below() {
    let home = Home::new();
    let customize = home.customize();
    let low = install(&customize, 1);
    let high = install(&customize, 2);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    let changed = customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    assert_eq!(home.web_dev().unwrap()["overlay"], json!(high));
    let conflict = &changed.library.conflicts[0];
    assert_eq!((conflict.kind, conflict.key.as_str()), ("code", "code:web"));
    assert_eq!(conflict.winner, "pr-20");
    assert_eq!(changed.library.entries[1].overridden, vec!["code:web".to_owned()]);

    customize.library_set_on("pr-20", false, "cli", 3).unwrap();
    assert_eq!(home.web_dev().unwrap()["overlay"], json!(low));
    customize.library_set_on("pr-20", true, "cli", 4).unwrap();
    assert_eq!(home.web_dev().unwrap()["overlay"], json!(high));
    customize.library_set_on("pr-20", false, "cli", 5).unwrap();
    customize.library_set_on("pr-10", false, "cli", 6).unwrap();
    assert_eq!(home.web_dev().unwrap_or(json!({})), json!({}));
}

#[test]
fn a_newer_head_replaces_the_entry_in_place_of_adding_one() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    let newer = install(&customize, 3);
    customize.library_use_code(layer(7, 1), vec!["first".into()], "cli", 1).unwrap();
    let mut next = layer(7, 3);
    next.title = "pr 7 again".into();
    let changed = customize.library_use_code(next, vec!["second".into()], "cli", 2).unwrap();
    assert_eq!(changed.library.entries.len(), 1);
    assert_eq!(changed.library.entries[0].words, vec!["second".to_owned(), "first".to_owned()]);
    assert_eq!(home.web_dev().unwrap()["overlay"], json!(newer));
}

#[test]
fn a_pr_with_no_web_part_is_kept_off_and_says_it_needs_a_build() {
    let home = Home::new();
    let customize = home.customize();
    let mut native = layer(43496, 1);
    native.web.clear();
    native.needs_build = vec!["the app icon is in the signed bundle".into()];
    let changed = customize.library_use_code(native, vec![], "cli", 1).unwrap();
    assert!(!changed.library.entries[0].on);
    assert!(home.web_dev().is_none(), "nothing written");
    let refused = customize.library_set_on("pr-43496", true, "cli", 2).unwrap_err().to_string();
    assert!(refused.contains("needs a build: the app icon"), "{refused}");
}

#[test]
fn a_layer_not_installed_is_refused_and_nothing_changes() {
    let home = Home::new();
    let customize = home.customize();
    let refused =
        customize.library_use_code(layer(5, 9), vec![], "cli", 1).unwrap_err().to_string();
    assert!(refused.contains("use pr:5"), "{refused}");
    assert!(customize.library().unwrap().entries.is_empty());
    assert!(home.web_dev().is_none());
}

#[test]
fn settle_notes_and_turns_off() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(8, 1), vec![], "cli", 1).unwrap();
    let changed =
        customize.library_settle_code("pr-8", "in your build", Some(false), "cli", 2).unwrap();
    let entry = &changed.library.entries[0];
    assert!(!entry.on);
    assert_eq!(entry.code.as_ref().unwrap().note, "in your build");
    assert_eq!(home.web_dev().unwrap_or(json!({})), json!({}));
}

#[test]
fn listing_json_of_other_entries_has_no_code_field() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(8, 1), vec![], "cli", 1).unwrap();
    let text = serde_json::to_string(&customize.library().unwrap()).unwrap();
    assert!(text.contains("\"code\":{"));
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["entries"][0]["code"]["web"], json!(key(1)));
}
