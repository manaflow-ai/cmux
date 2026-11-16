//! Getting out of a layer that broke cmux: `off --code` (what the app runs
//! when a layer's pages fail), `off --all` / `reset`, both with no app and
//! with a library or web-dev.json that does not read; and the one line a
//! bug report carries about which layers are on.

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

    fn web_dev(&self) -> Value {
        self.read("web-dev.json").map_or(json!({}), |text| serde_json::from_str(&text).unwrap())
    }

    fn library_path(&self) -> PathBuf {
        self.dir.path().join("state/library.json")
    }
}

const PLAIN: &str = "{\n  // mine\n  \"sidebar\": { \"density\": \"expanded\" }\n}\n";

fn settings(density: &str) -> String {
    format!(
        "{{\n  // mine\n  \"sidebar\": {{ \"density\": \"expanded\" }},\n  \"appearance\": {{ \"density\": \"{density}\" }}\n}}\n"
    )
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
        base: String::new(),
        web: key(n),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    }
}

fn install(customize: &Customize, n: u8) -> String {
    let dir = customize.layer_dir(&key(n));
    fs::create_dir_all(dir.join("pages")).unwrap();
    fs::write(dir.join("manifest.json"), "{}").unwrap();
    dir.to_string_lossy().into_owned()
}

const BEFORE: &str =
    r#"{"server": "http://127.0.0.1:4200/", "token": "t", "overlay": "/mine", "enabled": false}"#;

#[test]
fn off_code_turns_every_pr_off_notes_the_reason_and_puts_web_dev_back() {
    let home = Home::new();
    home.write("web-dev.json", BEFORE);
    let customize = home.customize();
    install(&customize, 1);
    install(&customize, 2);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    // An entry that was already off keeps its own note.
    customize.library_settle_code("pr-10", "merged: in your build", Some(false), "cli", 4).unwrap();

    let out = customize.library_off_code(Some("pages did not load\n(timeout)"), "app", 5).unwrap();
    assert!(out.complete, "{:?}", out.notes);
    assert_eq!(out.turned_off, vec!["pr-20".to_owned()]);
    assert_eq!(home.web_dev(), serde_json::from_str::<Value>(BEFORE).unwrap());
    assert_eq!(out.overlay.as_deref(), Some("/mine"));
    let listing = customize.library().unwrap();
    let note = |name: &str| {
        let entry = listing.entries.iter().find(|entry| entry.name == name).unwrap();
        assert!(!entry.on, "{name} is off");
        entry.code.as_ref().unwrap().note.clone()
    };
    assert_eq!(note("pr-20"), "pages did not load (timeout)");
    assert_eq!(note("pr-10"), "merged: in your build");
    // web-dev.json is back on the person's own overlay, which is no entry.
    assert_eq!(
        customize.layers().line,
        "customize: 0 on; web-dev overlay unknown (off, no manifest)"
    );
}

#[test]
fn off_all_puts_back_settings_and_web_dev_from_before_any_layer() {
    let home = Home::new();
    home.write("cmux-next.json", PLAIN);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.begin("compact", "cli", 1).unwrap();
    home.write("cmux-next.json", &settings("compact"));
    let name = customize.apply(None, "cli", 2).unwrap().library.unwrap();
    install(&customize, 1);
    customize.library_use_code(layer(43496, 1), vec![], "cli", 3).unwrap();
    let layers = customize.layers();
    assert_eq!(
        layers.line,
        format!("customize: 2 on: pr-43496 @{} (web), {name}", &layer(0, 1).head[..7])
    );
    assert_eq!(layers.on[1].kind, "settings");

    let out = customize.library_off_all("cli", 4).unwrap();
    assert!(out.complete, "{:?}", out.notes);
    assert_eq!(out.turned_off, vec!["pr-43496".to_owned(), name]);
    let file: Value = cmux_config::jsonc::parse(&home.read("cmux-next.json").unwrap()).unwrap();
    assert!(file["appearance"].get("density").is_none(), "density is unset again: {file}");
    assert_eq!(file["sidebar"]["density"], "expanded", "your own keys stay");
    assert_eq!(home.web_dev(), json!({}), "keys that were absent are gone again");
    assert!(customize.library().unwrap().entries.iter().all(|entry| !entry.on));
}

#[test]
fn a_library_that_does_not_read_still_gets_off_the_layer() {
    let home = Home::new();
    home.write("web-dev.json", BEFORE);
    let customize = home.customize();
    let dir = install(&customize, 1);
    customize.library_use_code(layer(1, 1), vec![], "cli", 1).unwrap();
    assert_eq!(home.web_dev()["overlay"], json!(dir));
    fs::write(home.library_path(), "{ not json").unwrap();
    let layers = customize.layers();
    assert!(layers.problem.is_some() && layers.stray_overlay, "{layers:?}");
    assert!(layers.line.contains("library unreadable"), "{}", layers.line);

    // The base is lost with the file: only the layer overlay goes, the
    // other keys stay.
    let out = customize.library_off_code(Some("pages failed"), "app", 2).unwrap();
    assert!(!out.complete);
    let after = home.web_dev();
    assert!(after.get("overlay").is_none(), "{after}");
    assert_eq!(after["server"], "http://127.0.0.1:4200/");
    assert_eq!(after["token"], "t");
    assert_eq!(after["enabled"], true);

    // reset keeps the file beside and starts the library empty.
    let out = customize.library_off_all("cli", 3).unwrap();
    assert!(!out.complete);
    assert!(
        out.notes.iter().any(|note| note.contains("library.json.unreadable-3")),
        "{:?}",
        out.notes
    );
    assert!(home.dir.path().join("state/library.json.unreadable-3").is_file());
    assert!(customize.library().unwrap().entries.is_empty());
}

#[test]
fn a_library_of_the_wrong_shape_still_gives_back_its_web_base() {
    let home = Home::new();
    home.write("web-dev.json", BEFORE);
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(7, 1), vec![], "cli", 1).unwrap();
    // JSON, but not a library this cmux reads.
    let mut library: Value =
        serde_json::from_str(&fs::read_to_string(home.library_path()).unwrap()).unwrap();
    library["version"] = json!("two");
    fs::write(home.library_path(), library.to_string()).unwrap();

    let out = customize.library_off_code(Some("pages failed"), "app", 2).unwrap();
    assert_eq!(out.turned_off, vec!["pr-7".to_owned()]);
    assert_eq!(home.web_dev(), serde_json::from_str::<Value>(BEFORE).unwrap());
    let library: Value =
        serde_json::from_str(&fs::read_to_string(home.library_path()).unwrap()).unwrap();
    assert_eq!(library["entries"][0]["on"], false);
    assert_eq!(library["entries"][0]["code"]["note"], "pages failed");
    assert!(library["base"].get("web").is_none());
}

#[test]
fn an_overlay_left_on_a_layer_no_entry_serves_is_cleared() {
    let home = Home::new();
    let customize = home.customize();
    let dir = install(&customize, 1);
    customize.library_use_code(layer(1, 1), vec![], "cli", 1).unwrap();
    customize.library_set_on("pr-1", false, "cli", 2).unwrap();
    // A write cut short: the library says off, web-dev.json still serves it.
    home.write("web-dev.json", &json!({"overlay": dir, "enabled": true, "token": "t"}).to_string());
    assert!(customize.layers().stray_overlay);
    assert!(customize.layers().line.contains("serves a layer no entry has on"));

    let out = customize.library_off_code(None, "app", 3).unwrap();
    assert!(out.turned_off.is_empty());
    assert!(out.notes.iter().any(|note| note.contains("still served layer")), "{:?}", out.notes);
    assert_eq!(home.web_dev(), json!({"enabled": true, "token": "t"}));
    assert!(!customize.layers().stray_overlay);
}

#[test]
fn a_web_dev_json_that_does_not_read_is_kept_beside_not_lost() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    home.write("web-dev.json", "{ \"server\": oops");
    customize.library_use_code(layer(1, 1), vec![], "cli", 1).unwrap();
    assert_eq!(home.read("web-dev.json.unreadable").unwrap(), "{ \"server\": oops");
    // JSONC (a comment) keeps its keys.
    home.write("web-dev.json", "{\n  // mine\n  \"token\": \"t\"\n}\n");
    customize.library_off_all("cli", 2).unwrap();
    assert_eq!(home.web_dev(), json!({"token": "t"}));
}

#[test]
fn a_lower_pr_under_a_higher_one_is_named_overridden() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    install(&customize, 2);
    customize.library_use_code(layer(10, 1), vec![], "cli", 1).unwrap();
    customize.library_use_code(layer(20, 2), vec![], "cli", 2).unwrap();
    let layers = customize.layers();
    assert_eq!(
        layers.line,
        format!(
            "customize: 2 on: pr-20 @{} (web), pr-10 @{} (overridden)",
            &layer(0, 2).head[..7],
            &layer(0, 1).head[..7]
        )
    );
    assert!(layers.on[0].web && !layers.on[1].web);
    assert_eq!(layers.on[1].pr, Some(10));
}

/// A hand-installed overlay (`web-overlay.sh install`) is no library entry,
/// so the library reads as empty; the line still names it, its commit, its
/// age and that the app refuses it for another web ABI.
#[test]
fn a_hand_installed_overlay_is_named_with_its_age_and_refusal() {
    let home = Home::new();
    let customize = home.customize();
    let overlay = home.dir.path().join("overlay");
    fs::create_dir_all(&overlay).unwrap();
    fs::write(
        overlay.join("manifest.json"),
        json!({"stamp": "20261112T081500Z-4242", "commit": "01192304abcdef", "surfaces": ["pages"], "abi": 4})
            .to_string(),
    )
    .unwrap();
    home.write("web-dev.json", &json!({"overlay": overlay, "enabled": true}).to_string());
    // 2026-11-15T09:00Z: three days later.
    let now = 1_794_733_200_000;
    let layers = customize.layers_at(Some(7), now);
    assert!(layers.on.is_empty());
    assert_eq!(
        layers.line,
        "customize: 0 on; web-dev overlay 01192304 (3 days, refused: abi 4, app 7)"
    );
    let web_dev = layers.web_dev.as_ref().unwrap();
    assert!(!web_dev.library && web_dev.refused && web_dev.installed);
    assert_eq!((web_dev.abi, web_dev.app_abi), (Some(4), Some(7)));
    assert!(!layers.stray_overlay, "a hand-installed overlay is not the library's to clear");

    // The same ABI is not refused; turned off says so.
    assert_eq!(
        customize.layers_at(Some(4), now).line,
        "customize: 0 on; web-dev overlay 01192304 (3 days)"
    );
    home.write("web-dev.json", &json!({"overlay": overlay, "enabled": false}).to_string());
    assert_eq!(
        customize.layers_at(None, now).line,
        "customize: 0 on; web-dev overlay 01192304 (off, 3 days)"
    );
}

/// A library layer the app refuses says so after its entry.
#[test]
fn a_refused_library_layer_says_so() {
    let home = Home::new();
    let customize = home.customize();
    let dir = install(&customize, 1);
    fs::write(PathBuf::from(&dir).join("manifest.json"), json!({"abi": 3}).to_string()).unwrap();
    customize.library_use_code(layer(5, 1), vec![], "cli", 1).unwrap();
    let line = customize.layers_at(Some(7), 2).line;
    assert_eq!(
        line,
        format!(
            "customize: 1 on: pr-5 @{} (web); web layer refused: abi 3, app 7",
            &layer(0, 1).head[..7]
        )
    );
}
