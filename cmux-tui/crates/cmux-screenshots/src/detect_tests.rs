use super::*;
use crate::rule::{IMAGES_AND_VIDEOS, MediaKind};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// A folder made for one test, removed when it ends.
struct TempFolder(PathBuf);

impl TempFolder {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("cmux-screenshots-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        Self(std::fs::canonicalize(&dir).expect("real temp folder"))
    }

    fn folder(&self, relative: &str) -> String {
        let dir = self.0.join(relative);
        std::fs::create_dir_all(&dir).expect("folder");
        dir.to_string_lossy().into_owned()
    }

    fn path(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

impl Drop for TempFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A fake Mac: preferences and files in memory, folders on disk under a temporary home.
struct Fixture {
    home: TempFolder,
    temp: TempFolder,
    preferences: HashMap<String, HashMap<String, String>>,
    files: HashMap<String, String>,
}

impl Fixture {
    fn new() -> Self {
        let fixture = Self {
            home: TempFolder::new(),
            temp: TempFolder::new(),
            preferences: HashMap::new(),
            files: HashMap::new(),
        };
        fixture.home.folder("Desktop");
        fixture.temp.folder("TemporaryItems");
        fixture
    }

    fn pref(mut self, domain: &str, key: &str, value: &str) -> Self {
        self.preferences.entry(domain.into()).or_default().insert(key.into(), value.into());
        self
    }

    fn file(mut self, relative: &str, text: &str) -> Self {
        self.files.insert(join(&self.home.path(), relative), text.into());
        self
    }

    fn detect(&self, find_tools: bool, extra: &[&str]) -> Vec<Source> {
        let extra: Vec<String> = extra.iter().map(|s| (*s).to_owned()).collect();
        Detector::new(self).detect(find_tools, &extra)
    }
}

impl Environment for Fixture {
    fn home(&self) -> String {
        self.home.path()
    }
    fn temporary_directory(&self) -> String {
        self.temp.path()
    }
    fn preference(&self, key: &str, domain: &str) -> Option<String> {
        self.preferences.get(domain)?.get(key).cloned()
    }
    fn string_preferences(&self, domain: &str) -> Vec<(String, String)> {
        self.preferences.get(domain).map(|m| m.clone().into_iter().collect()).unwrap_or_default()
    }
    fn text(&self, path: &str) -> Option<String> {
        self.files.get(path).cloned()
    }
    fn is_directory(&self, path: &str) -> bool {
        std::fs::metadata(path).is_ok_and(|m| m.is_dir())
    }
    fn real_path(&self, path: &str) -> Option<String> {
        std::fs::canonicalize(path).ok().map(|p| p.to_string_lossy().into_owned())
    }
}

fn ids(sources: &[Source]) -> Vec<&str> {
    sources.iter().map(|s| s.id.as_str()).collect()
}

#[test]
fn with_nothing_set_it_lists_the_desktop_and_the_preview_folder() {
    let env = Fixture::new();
    let sources = env.detect(true, &[]);
    assert_eq!(ids(&sources), ["system", "system.preview"]);
    assert_eq!(sources[0].folder, join(&env.home.path(), "Desktop"));
    assert_eq!(sources[1].folder, join(&env.temp.path(), "TemporaryItems"));
    assert_eq!(sources[1].rule.folder_prefix.as_deref(), Some("NSIRD_screencaptureui_"));
    assert_eq!(sources[1].rule.depth, 1);
    assert!(sources[0].accepts_drops());
    assert!(!sources[1].accepts_drops());
}

#[test]
fn reads_the_screencapture_location_with_a_tilde() {
    let env = Fixture::new().pref(SYSTEM_DOMAIN, "location", "~/screenshots");
    let shots = env.home.folder("screenshots");
    assert_eq!(env.detect(false, &[])[0].folder, shots);
}

#[test]
fn a_missing_location_falls_back_to_the_desktop() {
    let env = Fixture::new().pref(SYSTEM_DOMAIN, "location", "/nowhere/cmux-screenshots-missing");
    assert!(Detector::new(&env).system_folder().ends_with("/Desktop"));
}

/// CleanShot X exports into the macOS folder (shown once) and keeps a history.
#[test]
fn clean_shot_into_the_macos_folder_shows_once_and_its_history_shows_too() {
    let env = Fixture::new();
    let shots = env.home.folder("screenshots");
    env.home.folder("Library/Application Support/CleanShot/media");
    let env = env.pref(SYSTEM_DOMAIN, "location", "~/screenshots").pref(
        "pl.maketheweb.cleanshotx",
        "exportPath",
        &shots,
    );
    let sources = env.detect(true, &[]);
    assert_eq!(ids(&sources), ["system", "system.preview", "tool.cleanShotX.history"]);
    let history = sources.last().expect("history");
    assert_eq!(history.origin.tool().map(Tool::display_name), Some("CleanShot X"));
    assert_eq!(history.rule.folder_prefix.as_deref(), Some("media_"));
    assert_eq!(history.origin, Origin::ToolHistory(Tool::CleanShotX));
    assert!(!history.accepts_drops());
}

#[test]
fn reads_kap_and_flameshot_settings_files() {
    let env = Fixture::new();
    let kap = env.home.folder("Kaps");
    let flame = env.home.folder("Flames");
    let env = env
        .file(
            "Library/Application Support/Kap/config.json",
            &format!(r#"{{"kapturesDir": "{kap}"}}"#),
        )
        .file(".config/flameshot/flameshot.ini", "[General]\nsavePath=~/Flames\n");
    let sources = env.detect(true, &[]);
    let by_id: HashMap<&str, &Source> = sources.iter().map(|s| (s.id.as_str(), s)).collect();
    assert_eq!(by_id["tool.kap"].folder, kap);
    assert_eq!(by_id["tool.kap"].rule.kinds, IMAGES_AND_VIDEOS);
    assert_eq!(by_id["tool.flameshot"].folder, flame);
}

/// A tool whose key the detector does not know: any string preference naming an existing folder.
#[test]
fn finds_an_unknown_key_that_names_a_folder() {
    let env = Fixture::new();
    let saves = env.home.folder("ShottrSaves");
    let env = env
        .pref("cc.ffitch.shottr", "NSWindowFrame", "1 2 3 4")
        .pref("cc.ffitch.shottr", "theme", "dark")
        .pref("cc.ffitch.shottr", "defaultSaveFolder", &saves);
    let sources = env.detect(true, &[]);
    assert_eq!(
        sources.iter().find(|s| s.id == "tool.shottr").map(|s| s.folder.as_str()),
        Some(saves.as_str())
    );
    assert!(looks_like_folder_key("exportPath"));
    assert!(looks_like_folder_key("SaveLocation"));
    assert!(!looks_like_folder_key("NSOSPLastRootDirectory"));
    assert!(!looks_like_folder_key("recentFolders"));
    assert!(!looks_like_folder_key("theme"));
}

#[test]
fn tools_off_lists_only_macos_and_the_persons_folders() {
    let env = Fixture::new();
    env.home.folder("Library/Application Support/CleanShot/media");
    let mine = env.home.folder("Pictures/Mine");
    let sources = env.detect(false, &["~/Pictures/Mine", "relative/ignored"]);
    let origins: Vec<_> = sources.iter().map(|s| s.origin).collect();
    assert_eq!(origins, [Origin::System, Origin::SystemPreview, Origin::Custom]);
    let last = sources.last().expect("custom");
    assert_eq!(last.id, format!("custom.{mine}"));
    assert!(last.folder.ends_with("/Mine"));
    assert!(last.accepts_drops());
}

#[test]
fn a_folder_that_does_not_exist_is_not_listed() {
    let env = Fixture::new();
    assert_eq!(
        ids(&env.detect(true, &["/nowhere/cmux-screenshots-missing"])),
        ["system", "system.preview"]
    );
}

#[test]
fn fixed_folders_carry_their_rules() {
    let env = Fixture::new();
    env.home.folder("Movies");
    env.home.folder("Library/Application Support/so.cap.desktop/recordings");
    let sources = env.detect(true, &[]);
    assert_eq!(ids(&sources), ["system", "system.preview", "tool.cap.history", "tool.quickTime"]);
    assert_eq!(sources[2].rule.kinds, MediaKind::Video.bit());
    assert_eq!(sources[2].rule.depth, 3);
    assert_eq!(sources[3].rule.name_prefixes.len(), 9);
    assert!(sources[3].accepts_drops());
}

#[test]
fn expand_takes_absolute_tilde_and_file_urls() {
    let env = Fixture::new();
    let d = Detector::new(&env);
    let home = env.home.path();
    assert_eq!(d.expand(" ~ ").as_deref(), Some(home.as_str()));
    assert_eq!(d.expand("~/a/b"), Some(join(&home, "a/b")));
    assert_eq!(d.expand("/a/./b/../c/").as_deref(), Some("/a/c"));
    assert_eq!(d.expand("file:///a%20b/c/").as_deref(), Some("/a b/c"));
    assert_eq!(d.expand("file://localhost/x").as_deref(), Some("/x"));
    assert_eq!(d.expand("relative"), None);
    assert_eq!(d.expand("~other"), None);
}

#[test]
fn sources_json_names_the_origin_and_rule() {
    let env = Fixture::new();
    let json: serde_json::Value =
        serde_json::from_str(&sources_json(&env.detect(true, &[]))).expect("json");
    assert_eq!(json[1]["origin"], "systemPreview");
    assert_eq!(json[1]["acceptsDrops"], false);
    assert_eq!(json[1]["rule"]["depth"], 1);
    assert_eq!(json[0]["tool"], serde_json::Value::Null);
}
