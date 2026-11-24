//! Pull request entries: a PR's web layer goes live as web-dev.json's
//! overlay, the higher one that is on wins, and turning the last one off
//! writes back exactly what web-dev.json had, leaving its other keys alone.

use std::fs;
use std::path::PathBuf;

use cmux_customize::library::{CodeKind, CodeLayer};
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
        kind: Default::default(),
        source: String::new(),
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
fn off_puts_back_the_same_bytes() {
    let home = Home::new();
    let customize = home.customize();
    // web-overlay.sh's layout: unsorted keys, two spaces, no final newline,
    // and a comment the app reads as JSONC.
    let before = "{\n  \"slot\": \"a\",\n  // mine\n  \"devtools\": true,\n  \"overlay\": \"/old\",\n  \"enabled\": false\n}";
    fs::create_dir_all(home.dir.path().join("config")).unwrap();
    fs::write(home.web_dev_path(), before).unwrap();
    install(&customize, 1);
    install(&customize, 2);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    customize.library_set_on("pr-20", false, "cli", 3).unwrap();
    customize.library_set_on("pr-10", false, "cli", 4).unwrap();
    assert_eq!(fs::read_to_string(home.web_dev_path()).unwrap(), before);
}

#[test]
fn off_keeps_a_key_changed_while_a_layer_was_on() {
    let home = Home::new();
    let customize = home.customize();
    fs::create_dir_all(home.dir.path().join("config")).unwrap();
    fs::write(home.web_dev_path(), "{\"slot\": \"a\", \"enabled\": false}").unwrap();
    install(&customize, 1);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    let mut live = home.web_dev().unwrap();
    live["slot"] = json!("b");
    home.write_web_dev(live);
    customize.library_set_on("pr-10", false, "cli", 2).unwrap();
    // Not the old bytes: those would undo the edit.
    assert_eq!(home.web_dev().unwrap(), json!({"slot": "b", "enabled": false}));
}

#[test]
fn keys_that_were_absent_are_removed_again() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(1, 1), vec![], "cli", 1).unwrap();
    assert!(home.web_dev().unwrap().get("overlay").is_some());
    customize.library_remove("pr-1", "cli", 2).unwrap();
    // There was no web-dev.json: there is none again.
    assert!(!home.web_dev_path().exists(), "{:?}", home.web_dev());
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

fn kinded(kind: CodeKind, source: &str, n: u8) -> CodeLayer {
    CodeLayer { kind, source: source.to_owned(), pr: 0, title: String::new(), ..layer(0, n) }
}

#[test]
fn every_kind_gets_its_entry_name_and_label() {
    let cases = [
        (layer(43496, 1), "pr-43496", "#43496"),
        (
            kinded(CodeKind::Branch, "lane/Cat-Icon", 1),
            "branch-lane-cat-icon",
            "branch lane/Cat-Icon",
        ),
        (kinded(CodeKind::Sha, &"dbb1e3e6".repeat(5), 1), "sha-dbb1e3e", "commit dbb1e3e"),
        (
            kinded(CodeKind::Dir, "/Users/me/src/My cmux", 1),
            "dir-my-cmux",
            "folder /Users/me/src/My cmux",
        ),
        (
            kinded(CodeKind::Fork, "someone/cmux@feat/x", 1),
            "fork-someone-feat-x",
            "fork someone/cmux@feat/x",
        ),
    ];
    for (code, name, label) in cases {
        assert_eq!(code.name(), name);
        assert!(code.label().starts_with(label), "{}", code.label());
        assert!(cmux_customize::profile::valid_name(&code.name()), "{}", code.name());
    }
}

#[test]
fn a_pr_a_branch_and_a_folder_stack_and_off_all_puts_back_exactly() {
    let home = Home::new();
    let customize = home.customize();
    let before = json!({"overlay": "/ota", "enabled": true, "server": "s"});
    home.write_web_dev(before.clone());
    install(&customize, 1);
    install(&customize, 2);
    let folder = install(&customize, 3);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(kinded(CodeKind::Branch, "feat-x", 2), vec![], "cli", 2).unwrap();
    let changed = customize
        .library_use_code(kinded(CodeKind::Dir, "/src/cmux", 3), vec![], "cli", 3)
        .unwrap();
    let names: Vec<&str> = changed.library.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["dir-cmux", "branch-feat-x", "pr-10"]);
    assert_eq!(
        home.web_dev().unwrap()["overlay"],
        json!(folder),
        "the folder is on top and serves"
    );
    let on = customize.layers().on;
    assert_eq!(on.len(), 3);
    assert!(
        on.iter()
            .any(|l| l.kind == "dir" && l.web && l.source.as_deref() == Some("folder /src/cmux"))
    );
    assert!(on.iter().any(|l| l.kind == "branch" && !l.web));
    // The same branch again replaces its entry (it does not add one) and goes on top.
    let again = customize
        .library_use_code(kinded(CodeKind::Branch, "feat-x", 2), vec![], "cli", 4)
        .unwrap();
    let names: Vec<&str> = again.library.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["branch-feat-x", "dir-cmux", "pr-10"]);
    let on = customize.layers().on;
    assert!(
        on.iter()
            .any(|l| l.kind == "branch" && l.web && l.source.as_deref() == Some("branch feat-x"))
    );
    customize.library_off_all("cli", 5).unwrap();
    assert_eq!(home.web_dev().unwrap(), before);
}

#[test]
fn an_older_entry_reads_as_a_pull_request() {
    let old = json!({"repo": "manaflow-ai/cmux", "pr": 7, "head": "a".repeat(40)});
    let code: CodeLayer = serde_json::from_value(old).unwrap();
    assert_eq!(code.kind, CodeKind::Pr);
    assert_eq!(code.name(), "pr-7");
    // And a PR is written as before: no kind, no source.
    let back = serde_json::to_value(&code).unwrap();
    assert!(back.get("kind").is_none() && back.get("source").is_none());
}

#[test]
fn a_refresh_updates_an_entry_in_place_and_keeps_it_off() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    install(&customize, 2);
    install(&customize, 3);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(kinded(CodeKind::Branch, "feat-x", 2), vec![], "cli", 2).unwrap();
    customize.library_settle_code("pr-10", "", Some(false), "cli", 3).unwrap();
    // pr-10 is second and off; a newer head for it stays second and off.
    let newer = CodeLayer { head: "c".repeat(40), ..layer(10, 3) };
    let changed = customize.library_update_code(newer, "cli", 4).unwrap();
    let names: Vec<&str> = changed.library.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["branch-feat-x", "pr-10"]);
    let pr = changed.library.entries.iter().find(|e| e.name == "pr-10").unwrap();
    assert!(!pr.on);
    assert_eq!(pr.code.as_ref().unwrap().head, "c".repeat(40));
    // An entry nobody has is an error, not a new entry.
    assert!(customize.library_update_code(layer(99, 1), "cli", 5).is_err());
}
