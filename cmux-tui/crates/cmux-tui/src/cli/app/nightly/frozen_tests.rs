use std::path::{Path, PathBuf};

use super::super::Target;
use super::*;

fn plist(path: &Path, build: &str, schemas: Option<&[(&str, i64)]>) {
    let mut info = plist::Dictionary::new();
    info.insert("CFBundleIdentifier".into(), "com.cmuxterm.app.nightly".into());
    info.insert("CFBundleVersion".into(), build.into());
    info.insert("CFBundleShortVersionString".into(), format!("0.{build}").into());
    info.insert("CFBundleExecutable".into(), "cmux".into());
    if let Some(schemas) = schemas {
        let mut stores = plist::Dictionary::new();
        for (store, version) in schemas {
            stores.insert((*store).into(), plist::Value::Integer((*version).into()));
        }
        info.insert("CmuxStoreSchemas".into(), stores.into());
    }
    std::fs::create_dir_all(path.join("Contents")).unwrap();
    plist::Value::Dictionary(info).to_file_xml(path.join("Contents/Info.plist")).unwrap();
}

/// A kept build `build` under `root`, kept at `kept_at`.
fn keep(
    root: &Path,
    build: &str,
    kept_at: Option<&str>,
    schemas: Option<&[(&str, i64)]>,
) -> PathBuf {
    let app = root.join(build).join("cmux NIGHTLY.app");
    plist(&app, build, schemas);
    if let Some(at) = kept_at {
        std::fs::write(
            root.join(build).join("kept.json"),
            json!({ "build": build, "keptAt": at }).to_string(),
        )
        .unwrap();
    }
    app
}

struct Fake {
    team: Option<&'static str>,
    kept_team: Option<&'static str>,
    readable: Option<Schemas>,
    stored: Option<Schemas>,
}

impl Checks for Fake {
    fn team(&self, _: &Path) -> Option<String> {
        self.kept_team.map(str::to_owned)
    }
    fn running_team(&self, _: &Path) -> Option<String> {
        self.team.map(str::to_owned)
    }
    fn readable(&self, _: &Path) -> Option<Schemas> {
        self.readable.clone()
    }
    fn stored(&self) -> Option<Schemas> {
        self.stored.clone()
    }
}

fn schemas_of(pairs: &[(&str, i64)]) -> Schemas {
    pairs.iter().map(|(store, version)| ((*store).to_owned(), *version)).collect()
}

fn fine() -> Fake {
    Fake {
        team: Some("TEAM1"),
        kept_team: Some("TEAM1"),
        readable: None,
        stored: Some(schemas_of(&[("chats", 3)])),
    }
}

fn running(dir: &Path, build: &str) -> Running {
    let bundle = dir.join("Applications/cmux NIGHTLY.app");
    plist(&bundle, build, Some(&[("chats", 3)]));
    Running::read(&bundle).unwrap()
}

#[test]
fn lists_kept_builds_newest_first_and_skips_staged_bundles() {
    let dir = tempfile::tempdir().unwrap();
    keep(dir.path(), "90", Some("2026-11-27T01:00:00Z"), Some(&[("chats", 2)]));
    keep(dir.path(), "100", None, None);
    // A swap a crash interrupted: not offered.
    plist(&dir.path().join("110/.cmux-rollback-110-1-cmux NIGHTLY.app"), "110", None);
    let kept = list_kept(dir.path());
    assert_eq!(kept.iter().map(|k| k.build.as_str()).collect::<Vec<_>>(), ["100", "90"]);
    assert_eq!(kept[1].schemas, Some(schemas_of(&[("chats", 2)])));
    assert_eq!(kept[1].kept_at.as_deref(), Some("2026-11-27T01:00:00Z"));
    assert_eq!(kept[1].short_version, "0.90");
    assert_eq!(kept[0].kept_at, None);
}

#[test]
fn previous_is_the_build_kept_last_below_the_running_one() {
    let dir = tempfile::tempdir().unwrap();
    keep(dir.path(), "80", Some("2026-11-27T05:00:00Z"), None);
    keep(dir.path(), "90", Some("2026-11-26T05:00:00Z"), None);
    keep(dir.path(), "95", None, None);
    keep(dir.path(), "120", Some("2026-11-28T05:00:00Z"), None);
    let kept = list_kept(dir.path());
    assert_eq!(previous(&kept, "100").map(|k| k.build.as_str()), Some("80"));
    assert_eq!(previous(&kept, "80"), None);
    // With no keep dates the newest number wins.
    let dir = tempfile::tempdir().unwrap();
    keep(dir.path(), "8", None, None);
    keep(dir.path(), "9", None, None);
    assert_eq!(previous(&list_kept(dir.path()), "10").map(|k| k.build.as_str()), Some("9"));
}

#[test]
fn decide_goes_back_when_the_team_and_every_store_check_out() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("versions");
    keep(&store, "90", Some("2026-11-27T01:00:00Z"), Some(&[("chats", 3), ("drafts", 1)]));
    let kept = list_kept(&store);
    let running = running(dir.path(), "100");
    assert_eq!(decide(&kept, &Target::Previous, &running, &fine()).unwrap().build, "90");
    assert_eq!(decide(&kept, &Target::Build("90".into()), &running, &fine()).unwrap().build, "90");
}

#[test]
fn decide_refuses_with_the_apps_reasons() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("versions");
    let running = running(dir.path(), "100");
    assert_eq!(decide(&[], &Target::Previous, &running, &fine()), Err(Refusal::NothingKept));
    keep(&store, "90", None, Some(&[("chats", 2)]));
    keep(&store, "110", None, Some(&[("chats", 3)]));
    let kept = list_kept(&store);
    let label = || "0.90".to_owned();
    assert_eq!(
        decide(&kept, &Target::Build("100".into()), &running, &fine()),
        Err(Refusal::Installed { build: "100".into() })
    );
    assert_eq!(
        decide(&kept, &Target::Build("70".into()), &running, &fine()),
        Err(Refusal::NotKept { build: "70".into() })
    );
    let other_team = Fake { kept_team: Some("TEAM2"), ..fine() };
    assert_eq!(
        decide(&kept, &Target::Previous, &running, &other_team),
        Err(Refusal::Signature { kept: label() })
    );
    let unsigned = Fake { team: None, kept_team: None, ..fine() };
    assert_eq!(
        decide(&kept, &Target::Previous, &running, &unsigned),
        Err(Refusal::Signature { kept: label() })
    );
    assert_eq!(
        decide(&kept, &Target::Previous, &running, &fine()),
        Err(Refusal::StoreTooNew { kept: label(), store: "chats".into() })
    );
    let new_store = Fake { stored: Some(schemas_of(&[("chats", 1), ("notes", 1)])), ..fine() };
    assert_eq!(
        decide(&kept, &Target::Previous, &running, &new_store),
        Err(Refusal::UnknownStore { kept: label(), store: "notes".into() })
    );
    let unknown = Fake { stored: None, ..fine() };
    assert_eq!(decide(&kept, &Target::Previous, &running, &unknown), Err(Refusal::StoresUnknown));
    // A newer kept build only: nothing older.
    let dir = tempfile::tempdir().unwrap();
    keep(dir.path(), "110", None, None);
    assert_eq!(
        decide(&list_kept(dir.path()), &Target::Previous, &running, &fine()),
        Err(Refusal::NothingOlder { running: "100".into() })
    );
}

#[test]
fn decide_asks_the_kept_cli_when_its_plist_names_no_stores() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("versions");
    keep(&store, "90", None, None);
    let kept = list_kept(&store);
    let running = running(dir.path(), "100");
    assert_eq!(
        decide(&kept, &Target::Previous, &running, &fine()),
        Err(Refusal::Predates { kept: "0.90".into() })
    );
    let answers = Fake { readable: Some(schemas_of(&[("chats", 3)])), ..fine() };
    assert_eq!(decide(&kept, &Target::Previous, &running, &answers).unwrap().build, "90");
}

#[test]
fn swap_puts_the_kept_build_in_place_and_keeps_the_one_that_ran() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("versions");
    keep(&store, "90", Some("2026-11-27T01:00:00Z"), Some(&[("chats", 3)]));
    // An older copy of the running build in the store gives way.
    keep(&store, "100", None, None);
    std::fs::write(store.join("100/cmux NIGHTLY.app/stale"), "").unwrap();
    let running = running(dir.path(), "100");
    let target = list_kept(&store).into_iter().find(|k| k.build == "90").unwrap();
    swap(&running.bundle, "100", &target, &store, "2026-11-28T06:00:00Z").unwrap();
    assert_eq!(Running::read(&running.bundle).unwrap().build, "90");
    assert!(!store.join("90").exists());
    let kept = list_kept(&store);
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].build, "100");
    assert_eq!(kept[0].kept_at.as_deref(), Some("2026-11-28T06:00:00Z"));
    assert!(!store.join("100/cmux NIGHTLY.app/stale").exists());
    // Nothing staged is left beside the app.
    let beside: Vec<_> = std::fs::read_dir(running.bundle.parent().unwrap())
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(beside, ["cmux NIGHTLY.app"]);
}

#[test]
fn swap_puts_the_kept_build_back_when_the_app_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("versions");
    keep(&store, "90", None, None);
    let target = list_kept(&store).remove(0);
    let gone = dir.path().join("Applications/cmux NIGHTLY.app");
    std::fs::create_dir_all(gone.parent().unwrap()).unwrap();
    assert!(swap(&gone, "100", &target, &store, "2026-11-28T06:00:00Z").is_err());
    assert!(target.bundle.join("Contents/Info.plist").exists());
}

#[test]
fn reads_codesign_teams_store_answers_and_app_pids() {
    let shown =
        "Executable=/Applications/cmux.app/Contents/MacOS/cmux\nTeamIdentifier=7WLXT3NR37\n";
    assert_eq!(team_identifier(shown).as_deref(), Some("7WLXT3NR37"));
    assert_eq!(team_identifier("TeamIdentifier=not set\n"), None);
    assert_eq!(
        schemas("{\"chats\":3,\"drafts\":1}\n"),
        Some(schemas_of(&[("chats", 3), ("drafts", 1)]))
    );
    assert_eq!(schemas("{\"not_ready\":true}"), None);
    assert_eq!(schemas("nope"), None);
}

#[test]
fn a_staged_sparkle_update_stops_the_swap() {
    let dir = tempfile::tempdir().unwrap();
    let running = running(dir.path(), "100");
    let home = dir.path().join("home");
    assert!(!sparkle_waits(&running, &home));
    let installation = home
        .join("Library/Caches")
        .join(&running.bundle_id)
        .join("org.sparkle-project.Sparkle/Installation");
    std::fs::create_dir_all(&installation).unwrap();
    assert!(!sparkle_waits(&running, &home), "an empty folder stages nothing");
    std::fs::create_dir_all(installation.join("abc123")).unwrap();
    assert!(sparkle_waits(&running, &home));
}

#[test]
fn writes_the_keep_date_the_app_writes() {
    assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso8601(1_795_759_419), "2026-11-27T06:03:39Z");
    assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
}

#[test]
fn every_refusal_has_a_message_in_each_language() {
    let refusals = [
        Refusal::NoApp,
        Refusal::NothingKept,
        Refusal::NotKept { build: "1".into() },
        Refusal::Signature { kept: "1".into() },
        Refusal::Predates { kept: "1".into() },
        Refusal::StoreTooNew { kept: "1".into(), store: "s".into() },
        Refusal::UnknownStore { kept: "1".into(), store: "s".into() },
        Refusal::StoresUnknown,
        Refusal::SparkleWaits,
        Refusal::Swap { error: "e".into() },
    ];
    for locale in ["en", "ja"] {
        let messages = &crate::localization::catalog_for_locale(locale).app_control.nightly;
        for refusal in &refusals {
            let text = refusal.message(messages);
            assert!(!text.is_empty() && !text.contains('{'), "{locale} {refusal:?}: {text}");
        }
    }
}
