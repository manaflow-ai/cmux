//! The library: every apply saves itself as an entry, entries stack and
//! toggle, two entries on the same key say which wins, and collections
//! travel as one file that is checked whole before anything is written.

use std::fs;
use std::path::PathBuf;

use cmux_customize::library::{Collection, Position};
use cmux_customize::{Customize, Error, Roots};

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

    fn library_file(&self) -> Option<String> {
        fs::read_to_string(self.dir.path().join("state/library.json")).ok()
    }

    fn density(&self) -> Option<String> {
        let text = self.read("cmux-next.json")?;
        let value: serde_json::Value = cmux_config::jsonc::parse(&text).ok()?;
        value["appearance"]["density"].as_str().map(str::to_owned)
    }
}

const PLAIN: &str = "{\n  // mine\n  \"sidebar\": { \"density\": \"expanded\" }\n}\n";

fn settings(density: &str) -> String {
    format!(
        "{{\n  // mine\n  \"sidebar\": {{ \"density\": \"expanded\" }},\n  \"appearance\": {{ \"density\": \"{density}\" }}\n}}\n"
    )
}

/// Asks for `wish`, writes `text` to the settings file, applies.
fn ask_and_apply(customize: &Customize, home: &Home, wish: &str, text: &str, at: u64) -> String {
    customize.begin(wish, "cli", at).unwrap();
    home.write("cmux-next.json", text);
    customize.apply(None, "cli", at + 1).unwrap().library.expect("saved to the library")
}

#[test]
fn an_empty_library_lists_nothing_and_names_no_entry() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let listing = customize.library().unwrap();
    assert!(listing.entries.is_empty() && listing.conflicts.is_empty());
    for result in [
        customize.library_set_on("nope", true, "cli", 1),
        customize.library_order("nope", Position::Top, "cli", 1),
        customize.library_remove("nope", "cli", 1),
    ] {
        match result {
            Err(Error::Library(why)) => assert!(why.contains("library is empty"), "{why}"),
            other => panic!("{other:?}"),
        }
    }
    let collection = customize.library_export("mine", "", false).unwrap();
    assert!(collection.entries.is_empty());
    assert_eq!(home.read("cmux-next.json").unwrap(), PLAIN);
}

#[test]
fn every_apply_fills_the_library_with_what_it_changed_and_the_words() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    home.write("themes/night.json", "{ \"name\": \"night\", \"background\": \"#1E1E2E\" }\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();

    let name = ask_and_apply(&customize, &home, "make it compact", &settings("compact"), 10);
    assert_eq!(name, "make-it-compact");
    let listing = customize.library().unwrap();
    let entry = &listing.entries[0];
    assert!(entry.on);
    assert_eq!(entry.source, "ask");
    assert_eq!(entry.words, ["make it compact"]);
    // Only what the apply changed: not the sidebar key that was already there.
    assert_eq!(entry.settings, ["appearance.density"]);
    assert_eq!(entry.thumbnail.keys, ["appearance.density"]);

    // Hand edits applied with no ask are saved too, under their label.
    home.write("themes/night.json", "{ \"name\": \"night\", \"background\": \"#000000\" }\n");
    let applied = customize.apply(None, "cli", 20).unwrap();
    let listing = customize.library().unwrap();
    assert_eq!(applied.library.as_deref(), Some(listing.entries[0].name.as_str()));
    assert_eq!(listing.entries[0].source, "by hand");
    assert_eq!(listing.entries[0].files, ["themes/night.json"]);
    assert_eq!(listing.entries[0].thumbnail.swatches, ["#000000"]);
    assert_eq!(listing.entries.len(), 2);

    // A profile someone used (a recipe is one) comes in with its name.
    let profile: cmux_customize::profile::Profile = serde_json::from_str(
        "{\"cmuxProfile\":1,\"name\":\"roomy\",\"settings\":{\"appearance.density\":\"comfortable\"}}",
    )
    .unwrap();
    customize.preview_profile(&profile, "cli", 30).unwrap();
    let applied = customize.apply(None, "cli", 31).unwrap();
    assert_eq!(applied.library.as_deref(), Some("roomy"));
    assert_eq!(customize.library().unwrap().entries[0].source, "profile");

    // An apply that changes nothing records nothing and saves nothing.
    assert_eq!(customize.apply(None, "cli", 40).unwrap().library, None);
    assert_eq!(customize.library().unwrap().entries.len(), 3);
}

#[test]
fn turning_an_entry_off_puts_back_what_is_under_it_and_on_brings_it_back() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let name = ask_and_apply(&customize, &home, "make it compact", &settings("compact"), 10);
    assert_eq!(home.density().as_deref(), Some("compact"));

    let off = customize.library_set_on(&name, false, "cli", 20).unwrap();
    assert_eq!(home.density(), None, "the key was not there before the library set it");
    assert_eq!(off.changed, ["appearance.density"]);
    let generation = off.generation.expect("a toggle is an applied generation");
    assert_eq!(generation.label, format!("library: off {name}"));
    // Comments and other keys stay.
    assert!(home.read("cmux-next.json").unwrap().contains("// mine"));
    assert!(home.read("cmux-next.json").unwrap().contains("expanded"));

    customize.library_set_on(&name, true, "cli", 30).unwrap();
    assert_eq!(home.density().as_deref(), Some("compact"));
    // A toggle rolls back like any apply.
    customize.rollback(None, "cli", 40).unwrap();
    assert_eq!(home.density(), None);
}

#[test]
fn two_entries_on_the_same_key_the_higher_one_wins_and_the_list_says_so() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let compact = ask_and_apply(&customize, &home, "compact please", &settings("compact"), 10);
    let roomy = ask_and_apply(&customize, &home, "roomy please", &settings("comfortable"), 20);
    assert_eq!(home.density().as_deref(), Some("comfortable"));

    let listing = customize.library().unwrap();
    assert_eq!(
        listing.entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        [roomy.as_str(), compact.as_str()]
    );
    assert_eq!(listing.conflicts.len(), 1);
    let conflict = &listing.conflicts[0];
    assert_eq!((conflict.kind, conflict.key.as_str()), ("setting", "appearance.density"));
    assert_eq!(conflict.winner, roomy);
    assert_eq!(conflict.losers, std::slice::from_ref(&compact));
    assert_eq!(listing.entries[1].overridden, ["appearance.density"]);
    assert!(listing.entries[0].overridden.is_empty());

    // Order decides: the lower one moved to the top wins.
    customize.library_order(&compact, Position::Top, "cli", 30).unwrap();
    assert_eq!(home.density().as_deref(), Some("compact"));
    assert_eq!(customize.library().unwrap().conflicts[0].winner, compact);

    // Off: the one under it shows through, and there is no conflict.
    customize.library_set_on(&compact, false, "cli", 40).unwrap();
    assert_eq!(home.density().as_deref(), Some("comfortable"));
    assert!(customize.library().unwrap().conflicts.is_empty());

    // Removing the last one on the key puts back the person's own value.
    customize.library_remove(&roomy, "cli", 50).unwrap();
    assert_eq!(home.density(), None);
    assert_eq!(customize.library().unwrap().entries.len(), 1);
}

#[test]
fn a_toggle_while_a_preview_is_open_is_refused_and_writes_nothing() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let name = ask_and_apply(&customize, &home, "make it compact", &settings("compact"), 10);
    customize.begin("now something else", "cli", 20).unwrap();
    home.write("cmux-next.json", &settings("comfortable"));
    let library_before = home.library_file();
    let generations = customize.generations().unwrap().generations.len();
    match customize.library_set_on(&name, false, "cli", 30) {
        Err(Error::Library(why)) => assert!(why.contains("preview is open"), "{why}"),
        other => panic!("{other:?}"),
    }
    assert_eq!(home.library_file(), library_before);
    assert_eq!(home.density().as_deref(), Some("comfortable"), "the preview stays");
    assert_eq!(customize.generations().unwrap().generations.len(), generations);
    // Once the preview is applied the toggle works, on the new stack.
    customize.apply(None, "cli", 40).unwrap();
    customize.library_set_on(&name, false, "cli", 50).unwrap();
    assert_eq!(home.density().as_deref(), Some("comfortable"), "the higher entry still sets it");
}

#[test]
fn a_hand_edit_no_toggle_touches_stays_and_one_under_the_stack_becomes_the_base() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let compact = ask_and_apply(&customize, &home, "make it compact", &settings("compact"), 10);
    customize.library_set_on(&compact, false, "cli", 20).unwrap();
    // By hand, outside any ask: the key the library manages, with no entry on it.
    home.write("cmux-next.json", &settings("comfortable"));
    let on = customize.library_set_on(&compact, true, "cli", 30).unwrap();
    assert!(on.by_hand.is_some(), "the hand edit was kept by number first");
    assert_eq!(home.density().as_deref(), Some("compact"));
    customize.library_set_on(&compact, false, "cli", 40).unwrap();
    assert_eq!(home.density().as_deref(), Some("comfortable"), "the hand value is the base now");
}

#[test]
fn fifty_entries_stack_and_toggle_by_order() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    let mut names = Vec::new();
    for i in 0..50u64 {
        let density = if i % 2 == 0 { "compact" } else { "comfortable" };
        // Each ask also writes its own theme file, so no two are the same.
        customize.begin(&format!("step {i}"), "cli", i * 10).unwrap();
        home.write(&format!("themes/t{i}.json"), &format!("{{ \"name\": \"t{i}\" }}\n"));
        home.write("cmux-next.json", &settings(density));
        names.push(customize.apply(None, "cli", i * 10 + 1).unwrap().library.unwrap());
    }
    let listing = customize.library().unwrap();
    assert_eq!(listing.entries.len(), 50);
    assert_eq!(listing.entries[0].name, names[49]);
    let density = listing.conflicts.iter().find(|c| c.key == "appearance.density").unwrap();
    assert_eq!(density.winner, names[49]);
    // Entries whose density equals the one under them carry no density change.
    assert!(!density.losers.is_empty());
    assert_eq!(home.density().as_deref(), Some("comfortable"));
    customize.library_set_on(&names[49], false, "cli", 10_000).unwrap();
    assert_eq!(home.density().as_deref(), Some("compact"));
    assert!(home.config("themes/t0.json").exists());
    customize.library_set_on(&names[0], false, "cli", 10_001).unwrap();
    assert!(!home.config("themes/t0.json").exists(), "its file goes with it");
}

#[test]
fn a_collection_exports_and_imports_off_unless_asked_and_conflicts_show() {
    let mine = Home::new();
    mine.write("cmux-next.json", PLAIN);
    let customize = mine.customize();
    ask_and_apply(&customize, &mine, "make it compact", &settings("compact"), 10);
    let collection = customize.library_export("my set", "small things", false).unwrap();
    let text = serde_json::to_string(&collection).unwrap();
    assert!(text.contains("\"cmuxCollection\":1") && text.contains("\"cmuxProfile\":1"));
    assert!(!text.contains("added_ms") && !text.contains("generation"), "local fields stay home");

    let theirs = Home::new();
    theirs.write("cmux-next.json", &settings("comfortable"));
    let other = theirs.customize();
    let parsed = Customize::parse_collection(&text).unwrap();
    let imported = other.library_import(&parsed, false, "cli", 5).unwrap();
    assert_eq!(imported.added, ["make-it-compact"]);
    assert!(imported.change.generation.is_none(), "off: nothing live changes");
    assert_eq!(theirs.density().as_deref(), Some("comfortable"));
    assert!(!other.library().unwrap().entries[0].on);
    // The same again is already there.
    let again = other.library_import(&parsed, false, "cli", 6).unwrap();
    assert_eq!(
        (again.added.len(), again.already.as_slice()),
        (0, ["make-it-compact".to_owned()].as_slice())
    );
    other.library_set_on("make-it-compact", true, "cli", 7).unwrap();
    assert_eq!(theirs.density().as_deref(), Some("compact"));
    other.library_set_on("make-it-compact", false, "cli", 8).unwrap();
    assert_eq!(theirs.density().as_deref(), Some("comfortable"), "their own value comes back");

    // With --on, the entries the file marks on are on, and live.
    let third = Home::new();
    third.write("cmux-next.json", PLAIN);
    let imported = third.customize().library_import(&parsed, true, "cli", 9).unwrap();
    assert!(imported.change.generation.is_some());
    assert_eq!(third.density().as_deref(), Some("compact"));

    // A lone profile file imports as a collection of one.
    let one = Customize::parse_collection(
        "{\"cmuxProfile\":1,\"name\":\"roomy\",\"settings\":{\"appearance.density\":\"comfortable\"}}",
    )
    .unwrap();
    assert_eq!(one.entries[0].profile.name, "roomy");
}

#[test]
fn a_malformed_or_hostile_collection_writes_nothing() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    ask_and_apply(&customize, &home, "make it compact", &settings("compact"), 10);
    let library_before = home.library_file();
    let settings_before = home.read("cmux-next.json");
    let good = "{\"on\":true,\"profile\":{\"cmuxProfile\":1,\"name\":\"good\",\"settings\":{\"sidebar.density\":\"compact\"}}}";
    let cases = [
        "not json".to_owned(),
        "{\"cmuxCollection\":2,\"entries\":[]}".to_owned(),
        "{\"name\":\"no version\"}".to_owned(),
        "{\"cmuxCollection\":1,\"entries\":[{\"on\":true}]}".to_owned(),
        // One good entry and one bad: nothing at all.
        format!(
            "{{\"cmuxCollection\":1,\"entries\":[{good},{{\"profile\":{{\"cmuxProfile\":1,\"name\":\"bad\",\"settings\":{{\"no.such.key\":1}}}}}}]}}"
        ),
        format!(
            "{{\"cmuxCollection\":1,\"entries\":[{good},{{\"profile\":{{\"cmuxProfile\":1,\"name\":\"esc\",\"files\":{{\"../../etc/x\":\"y\"}}}}}}]}}"
        ),
        format!(
            "{{\"cmuxCollection\":1,\"entries\":[{good},{{\"profile\":{{\"cmuxProfile\":1,\"name\":\"Bad Name\"}}}}]}}"
        ),
        format!(
            "{{\"cmuxCollection\":1,\"entries\":[{good},{{\"profile\":{{\"cmuxProfile\":1,\"name\":\"auto\",\"files\":{{\"automations/a/automation.json\":\"{{}}\"}}}}}}]}}"
        ),
        format!(
            "{{\"cmuxCollection\":1,\"entries\":[{good},{{\"profile\":{{\"cmuxProfile\":1,\"name\":\"leak\",\"files\":{{\"themes/x.json\":\"{{\\\"token\\\": \\\"ghp_abcdefghijklmnopqrstuvwxyz0123456789\\\"}}\"}}}}}}]}}"
        ),
    ];
    for text in &cases {
        let result = Customize::parse_collection(text).and_then(|collection: Collection| {
            customize.library_import(&collection, true, "cli", 20)
        });
        assert!(result.is_err(), "{text} was taken");
        assert_eq!(home.library_file(), library_before, "{text}");
        assert_eq!(home.read("cmux-next.json"), settings_before, "{text}");
        assert!(!home.config("themes/x.json").exists());
    }
}
