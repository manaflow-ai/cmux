//! The journeys, end to end on a real folder: a person alone, an agent
//! alone, the two taking turns, and a profile moving between machines.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::{ChangeKind, Customize, Error, Kind, Part, Reader, Roots, brief};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        Home { dir: tempfile::tempdir().unwrap() }
    }

    fn roots(&self) -> Roots {
        Roots::under(self.dir.path())
    }

    fn customize(&self) -> Customize {
        Customize::open(self.roots())
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
}

const COZY: &str = "{\n  // my settings\n  \"appearance\": { \"density\": \"cozy\" }\n}\n";
const COMPACT: &str = "{\n  // my settings\n  \"appearance\": { \"density\": \"compact\" }\n}\n";
const MANIFEST: &str = r#"{
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": { "cmux.section/1": { "export": "renderSection", "title": "PRs", "symbol": "sparkles" } },
  "description": "My own views"
}
"#;

fn paths(changes: &[cmux_customize::Change]) -> Vec<(&str, ChangeKind, bool)> {
    changes.iter().map(|change| (change.path.as_str(), change.kind, change.by_hand)).collect()
}

#[test]
fn a_person_alone_edits_applies_and_rolls_back_and_forward() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    assert_eq!(customize.ensure_baseline(1).unwrap(), Some(1));
    assert_eq!(customize.ensure_baseline(2).unwrap(), None);
    assert!(!customize.status().unwrap().dirty());

    home.write("cmux-next.json", COMPACT);
    let status = customize.status().unwrap();
    assert_eq!(paths(&status.changes), [("settings.json", ChangeKind::Modified, true)]);
    assert_eq!(status.changes[0].part, Part::Settings);
    let diff = customize.diff(Reader::Person).unwrap();
    assert!(
        diff[0].diff.as_deref().unwrap().contains("-  \"appearance\": { \"density\": \"cozy\" }")
    );

    let applied = customize.apply(None, "cli", 10).unwrap();
    assert!(applied.recorded);
    assert_eq!((applied.generation.n, applied.generation.kind), (2, Kind::Applied));
    assert_eq!(applied.generation.label, "changes made by hand");
    assert_eq!(applied.generation.parts, [Part::Settings]);
    // Applying again records nothing.
    assert!(!customize.apply(None, "cli", 11).unwrap().recorded);

    let back = customize.rollback(None, "cli", 20).unwrap();
    assert_eq!((back.generation.n, back.kept_as), (1, None));
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(customize.generations().unwrap().current, Some(1));
    // Forward again is the same verb with a number.
    customize.rollback(Some(2), "cli", 30).unwrap();
    assert_eq!(home.read("cmux-next.json").unwrap(), COMPACT);
    assert!(matches!(customize.rollback(Some(9), "cli", 31), Err(Error::NoSuchGeneration(9))));
}

#[test]
fn an_agent_alone_asks_previews_and_applies_under_what_was_asked() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    let begun =
        customize.begin("make the sidebar compact and add a PR widget", "mcp", 100).unwrap();
    assert_eq!((begun.baseline, begun.by_hand, begun.refined), (Some(1), None, false));

    let text = brief(
        "make the sidebar compact and add a PR widget",
        customize.roots(),
        &customize.status().unwrap(),
    );
    assert!(text.contains("> make the sidebar compact and add a PR widget"));
    assert!(text.contains("customize status --json"));
    assert!(text.contains(&home.config("cmux-next.json").display().to_string()));

    home.write("cmux-next.json", COMPACT);
    home.write("customize/main.js", "export function renderSection() {}\n");
    home.write("customize/cmux-app.json", MANIFEST);
    let status = customize.status().unwrap();
    assert_eq!(
        paths(&status.changes),
        [
            ("customize/cmux-app.json", ChangeKind::Added, false),
            ("customize/main.js", ChangeKind::Added, false),
            ("settings.json", ChangeKind::Modified, false),
        ]
    );
    assert_eq!(status.problems, []);
    assert!(status.ask_to_first_change_ms.is_some());

    let applied = customize.apply(None, "mcp", 200).unwrap();
    assert_eq!(applied.generation.label, "make the sidebar compact and add a PR widget");
    assert_eq!(applied.generation.parts, [Part::Settings, Part::Views]);
    assert_eq!(customize.status().unwrap().draft, None);
}

#[test]
fn a_person_and_an_agent_take_turns_and_neither_loses_an_edit() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();

    // The person changes something by hand, then asks an agent for more.
    home.write("agent-pane/theme.css", ":root { --agent-gap: 2px }\n");
    let begun = customize.begin("night theme", "cli", 100).unwrap();
    assert_eq!(begun.by_hand, Some(2), "the hand edit is its own generation before the draft");

    // The agent's turn.
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    customize.end_turn().unwrap();
    assert_eq!(
        paths(&customize.status().unwrap().changes),
        [("themes/night.json", ChangeKind::Added, false)]
    );

    // The person tweaks the agent's file, then asks again: the brief names it.
    home.write("themes/night.json", "{ \"name\": \"night\", \"mine\": true }\n");
    let begun = customize.begin("darker", "cli", 200).unwrap();
    assert!(begun.refined);
    let status = customize.status().unwrap();
    assert_eq!(paths(&status.changes), [("themes/night.json", ChangeKind::Added, true)]);
    let text = brief("darker", customize.roots(), &status);
    assert!(text.contains("edited these by hand"));
    assert!(text.contains("- themes/night.json"));
    assert!(text.contains("- night theme"), "the earlier ask is in the brief: {text}");

    // Discard returns to the hand-edited setup, not past it, and keeps the draft.
    let discarded = customize.discard("cli", 300).unwrap();
    assert_eq!((discarded.generation.n, discarded.kept_as), (2, Some(3)));
    assert_eq!(home.read("themes/night.json"), None);
    assert_eq!(home.read("agent-pane/theme.css").unwrap(), ":root { --agent-gap: 2px }\n");
    let history = customize.generations().unwrap();
    assert_eq!(history.current, Some(2));
    assert_eq!(history.generations[0].kind, Kind::Discarded);
    assert_eq!(history.generations[0].label, "night theme; darker");

    // "Discard" was not "lost": the discarded draft comes back by number.
    customize.rollback(Some(3), "cli", 400).unwrap();
    assert_eq!(
        home.read("themes/night.json").unwrap(),
        "{ \"name\": \"night\", \"mine\": true }\n"
    );
}

#[test]
fn a_tree_that_does_not_validate_is_never_recorded_and_the_preview_stays() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    customize.begin("break it", "mcp", 1).unwrap();
    home.write("cmux-next.json", "{\n  \"appearance\": { \"density\": \"enormous\" }\n}\n");
    home.write("themes/bad.json", "{ \"name\": }\n");
    let Err(Error::Invalid(problems)) = customize.apply(None, "mcp", 2) else { panic!("applied") };
    let lines: Vec<String> = problems.iter().map(|problem| problem.line()).collect();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(lines[0].starts_with("settings.json:2:19: "), "{lines:?}");
    assert!(lines[1].starts_with("themes/bad.json:1:"), "{lines:?}");
    assert_eq!(customize.generations().unwrap().generations.len(), 1);
    assert!(customize.status().unwrap().draft.is_some());
    assert!(home.read("themes/bad.json").is_some());
}

#[test]
fn rolling_back_with_unapplied_changes_keeps_them() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write("cmux-next.json", COMPACT);
    customize.apply(Some("compact"), "cli", 2).unwrap();
    home.write("customize/notes/a.js", "// draft\n");
    let back = customize.rollback(None, "user", 3).unwrap();
    assert_eq!((back.generation.n, back.kept_as), (1, Some(3)));
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(home.read("customize/notes/a.js"), None);
    assert!(
        !home.config("customize/notes").exists(),
        "the folder a removed file leaves empty goes too"
    );
    let history = customize.generations().unwrap();
    assert_eq!(history.generations[0].kind, Kind::Autosaved);
    assert_eq!(history.generations[0].parent, Some(2));
}

#[test]
fn files_outside_the_parts_are_never_read_or_touched() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("cloud-secrets.json", "{ \"token\": \"x\" }\n");
    home.write("automations/auto_1/automation.json", "{ \"name\": \"standup\" }\n");
    home.write("automations/auto_1/runs.jsonl", "{}\n");
    home.write("customize/.cmux-ext-dev.json", "{}\n");
    home.write("customize/node_modules/x/index.js", "x\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write("automations/auto_1/automation.json", "{ \"name\": \"standup at nine\" }\n");
    let applied = customize.apply(None, "cli", 2).unwrap();
    assert_eq!(
        paths(&applied.changes),
        [("automations/auto_1/automation.json", ChangeKind::Modified, true)]
    );
    home.write("cloud-secrets.json", "{ \"token\": \"y\" }\n");
    home.write("automations/auto_1/runs.jsonl", "{}\n{}\n");
    customize.rollback(None, "cli", 3).unwrap();
    assert_eq!(
        home.read("automations/auto_1/automation.json").unwrap(),
        "{ \"name\": \"standup\" }\n"
    );
    assert_eq!(home.read("cloud-secrets.json").unwrap(), "{ \"token\": \"y\" }\n");
    assert_eq!(home.read("automations/auto_1/runs.jsonl").unwrap(), "{}\n{}\n");
    assert!(home.config("customize/node_modules/x/index.js").exists());
    // No copy of the secrets file is anywhere in the store.
    assert!(!store_contains(&home.dir.path().join("state"), "\"token\""));
}

fn store_contains(dir: &Path, needle: &str) -> bool {
    fs::read_dir(dir).unwrap().flatten().any(|entry| {
        let path = entry.path();
        if path.is_dir() {
            store_contains(&path, needle)
        } else {
            fs::read_to_string(&path).is_ok_and(|text| text.contains(needle))
        }
    })
}

#[cfg(unix)]
#[test]
fn a_linked_settings_file_stays_a_link_and_the_store_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new();
    let dotfiles = home.dir.path().join("dotfiles");
    fs::create_dir_all(&dotfiles).unwrap();
    fs::write(dotfiles.join("cmux.json"), COZY).unwrap();
    fs::create_dir_all(home.config("")).unwrap();
    std::os::unix::fs::symlink(dotfiles.join("cmux.json"), home.config("cmux-next.json")).unwrap();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    fs::write(dotfiles.join("cmux.json"), COMPACT).unwrap();
    customize.discard("cli", 2).unwrap();
    assert!(fs::symlink_metadata(home.config("cmux-next.json")).unwrap().file_type().is_symlink());
    assert_eq!(fs::read_to_string(dotfiles.join("cmux.json")).unwrap(), COZY);
    let state = home.dir.path().join("state");
    assert_eq!(fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(fs::metadata(state.join("index.json")).unwrap().permissions().mode() & 0o777, 0o600);
}

#[test]
fn a_profile_carries_a_setup_to_another_machine_as_a_preview() {
    let mine = Home::new();
    mine.write(
        "cmux-next.json",
        "{\n  \"appearance\": { \"density\": \"compact\", \"themeFile\": \"night\" },\n  \"updates\": { \"channel\": \"nightly\" }\n}\n",
    );
    mine.write("themes/night.json", "{ \"name\": \"night\" }\n");
    mine.write("automations/auto_1/automation.json", "{ \"name\": \"standup\" }\n");
    let customize = mine.customize();
    let saved = customize.save_profile("compact-night", "small and dark", 5).unwrap();
    assert_eq!(
        (saved.settings, saved.files.as_slice()),
        (2, ["themes/night.json".to_owned()].as_slice())
    );
    assert_eq!(saved.left_out.len(), 2, "{:?}", saved.left_out);
    let text = fs::read_to_string(&saved.path).unwrap();
    assert!(!text.contains("nightly") && !text.contains(&mine.dir.path().display().to_string()));
    assert_eq!(customize.profiles().unwrap()[0].name, "compact-night");

    let theirs = Home::new();
    theirs.write(
        "cmux-next.json",
        "{\n  // theirs\n  \"sidebar\": { \"density\": \"expanded\" }\n}\n",
    );
    let other = theirs.customize();
    let profile = other.load_profile(saved.path.to_str().unwrap()).unwrap();
    let begun = other.preview_profile(&profile, "cli", 10).unwrap();
    assert_eq!(begun.baseline, Some(1));
    assert_eq!(begun.draft.asks[0].text, "profile compact-night");
    let settings = theirs.read("cmux-next.json").unwrap();
    assert!(
        settings.contains("// theirs") && settings.contains("\"expanded\""),
        "their own keys stay: {settings}"
    );
    assert!(settings.contains("\"compact\"") && settings.contains("\"night\""));
    assert_eq!(theirs.read("themes/night.json").unwrap(), "{ \"name\": \"night\" }\n");
    // It is a draft: discard puts their setup back.
    other.discard("cli", 11).unwrap();
    assert_eq!(theirs.read("themes/night.json"), None);
    assert!(!theirs.read("cmux-next.json").unwrap().contains("compact"));
}

#[test]
fn a_hostile_or_broken_profile_writes_nothing() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    let profile = |settings: &str, files: &str| {
        serde_json::from_str::<cmux_customize::profile::Profile>(&format!(
            "{{\"cmuxProfile\":1,\"name\":\"x\",\"settings\":{settings},\"files\":{files}}}"
        ))
        .unwrap()
    };
    for (settings, files) in [
        ("{\"updates.channel\":\"nightly\"}", "{}"),
        ("{\"appearance.density\":\"enormous\"}", "{}"),
        ("{\"no.such.key\":1}", "{}"),
        ("{}", "{\"../../.zshrc\":\"x\"}"),
        ("{}", "{\"cloud-secrets.json\":\"{}\"}"),
        ("{}", "{\"settings.json\":\"{}\"}"),
        ("{}", "{\"automations/a/automation.json\":\"{}\"}"),
        ("{}", "{\"themes/bad.json\":\"{ nope\"}"),
        ("{}", "{\"customize/main.js\":\"let a = '\u{202E}';\"}"),
    ] {
        let result = customize.preview_profile(&profile(settings, files), "cli", 1);
        assert!(
            matches!(result, Err(Error::Profile(_) | Error::Invalid(_))),
            "{settings} {files}: {result:?}"
        );
    }
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(customize.generations().unwrap().generations.len(), 0);
    assert!(!home.config("themes").exists() && !home.config("customize").exists());
}

const SECRET_SETTINGS: &str = "{\n  \"browser\": { \"newTabPage\": \"https://alice:credential@example.com\" },\n  \"appearance\": { \"density\": \"compact\" },\n  \"updates\": { \"channel\": \"nightly\" }\n}\n";

fn diff_text(diffs: &[cmux_customize::FileDiff]) -> String {
    diffs.iter().filter_map(|file| file.diff.clone()).collect::<Vec<_>>().join("\n")
}

/// F1: the first generation's diff is the whole settings file, and a live
/// diff is whatever was just saved. Neither shows a credential to anyone,
/// and an agent does not read a setting the settings tools keep from it.
#[test]
fn no_diff_shows_a_credential_at_any_generation_or_live() {
    let home = Home::new();
    home.write("cmux-next.json", SECRET_SETTINGS);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    for reader in [Reader::Agent, Reader::Person] {
        let first = diff_text(&customize.generation_diff(1, reader).unwrap());
        assert!(!first.contains("credential"), "{reader:?}: {first}");
        assert!(first.contains("+  \"browser\": { \"newTabPage\": \"[redacted]\" },"), "{first}");
        assert!(first.contains("\"density\": \"compact\""), "{first}");
        assert_eq!(first.contains("nightly"), reader == Reader::Person, "{reader:?}: {first}");
    }

    let token = format!("ghp_{}", "a1B2".repeat(9));
    home.write(
        "cmux-next.json",
        &SECRET_SETTINGS.replace("alice:credential", "bob:hunter2").replace("compact", "cozy"),
    );
    home.write("themes/night.json", "{ \"name\": \"night\", \"apiKey\": \"k-937\" }\n");
    home.write("customize/main.js", &format!("const gh = '{token}';\nlet a = 1;\n"));
    for reader in [Reader::Agent, Reader::Person] {
        let live = diff_text(&customize.diff(reader).unwrap());
        for secret in ["credential", "hunter2", "k-937", token.as_str()] {
            assert!(!live.contains(secret), "{reader:?} reads {secret}: {live}");
        }
        assert!(live.contains("+  \"appearance\": { \"density\": \"cozy\" },"), "{live}");
        assert!(live.contains("+let a = 1;"), "{live}");
    }
    // The files themselves are as they were saved: only the reading is masked.
    assert!(home.read("cmux-next.json").unwrap().contains("bob:hunter2"));
}

/// F2: a profile is for sharing, so a credential stays on this machine and
/// the answer names what stayed.
#[test]
fn a_saved_profile_leaves_credentials_out_and_says_which() {
    let home = Home::new();
    home.write("cmux-next.json", SECRET_SETTINGS);
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    home.write("themes/leaky.json", "{ \"name\": \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\" }\n");
    home.write("themes/keyed.json", "{\n  \"name\": \"keyed\",\n  \"token\": \"t-937\"\n}\n");
    let saved = home.customize().save_profile("mine", "", 2).unwrap();
    let text = fs::read_to_string(&saved.path).unwrap();
    for secret in ["credential", "alice", "ghp_", "t-937", "nightly"] {
        assert!(!text.contains(secret), "the profile carries {secret}: {text}");
    }
    assert_eq!(
        (saved.settings, saved.files.as_slice()),
        (1, ["themes/night.json".to_owned()].as_slice())
    );
    let said = saved.left_out.join("\n");
    assert!(
        said.contains("the setting browser.newTabPage: its value carries a credential"),
        "{said}"
    );
    assert!(
        said.contains("themes/leaky.json: line 1 looks like a secret (a GitHub token)"),
        "{said}"
    );
    assert!(said.contains("themes/keyed.json: line 3 looks like a secret"), "{said}");
    assert!(said.contains("1 setting that only you can change"), "{said}");
    assert!(!said.contains("credential@") && !said.contains("t-937"), "{said}");
}

/// F3: a profile writes only where a generation can hold what was there.
#[test]
fn a_profile_cannot_write_a_file_the_history_does_not_keep() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("customize/.env", "MINE=1\n");
    let customize = home.customize();
    for path in
        ["customize/.env", "customize/.git/config", "themes/.hidden.json", "customize/a/.b/c.js"]
    {
        let profile = serde_json::from_str::<cmux_customize::profile::Profile>(&format!(
            "{{\"cmuxProfile\":1,\"name\":\"x\",\"settings\":{{}},\"files\":{{\"{path}\":\"THEIRS=1\\n\"}}}}"
        ))
        .unwrap();
        let result = customize.preview_profile(&profile, "cli", 1);
        assert!(matches!(result, Err(Error::Profile(_))), "{path}: {result:?}");
    }
    assert_eq!(home.read("customize/.env").unwrap(), "MINE=1\n");
    assert_eq!(customize.generations().unwrap().generations.len(), 0);
}

/// F4: a file that grew past what a generation holds is not in any
/// snapshot, so discard and rollback refuse to write over it.
#[test]
fn a_file_too_large_to_snapshot_is_never_overwritten() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("customize/data.js", "let small = 1;\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    customize.apply(Some("night"), "cli", 2).unwrap();

    let big = "x".repeat(2 * 1024 * 1024 + 1);
    home.write("customize/data.js", &big);
    home.write("cmux-next.json", COMPACT);
    for result in [customize.discard("cli", 3), customize.rollback(Some(1), "cli", 4)] {
        match result {
            Err(Error::Untracked(files)) => {
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].path, "customize/data.js");
            }
            other => panic!("the large file was written over: {other:?}"),
        }
    }
    // Nothing moved: the large file, the unapplied edit, and the history.
    assert_eq!(home.read("customize/data.js").unwrap().len(), big.len());
    assert_eq!(home.read("cmux-next.json").unwrap(), COMPACT);
    assert_eq!(customize.generations().unwrap().generations.len(), 2);
    let error = Error::Untracked(vec![]).code();
    assert_eq!(error, "customize.untracked");

    // Small again, both work.
    home.write("customize/data.js", "let small = 2;\n");
    customize.rollback(Some(1), "cli", 5).unwrap();
    assert_eq!(home.read("customize/data.js").unwrap(), "let small = 1;\n");
    assert_eq!(home.read("themes/night.json"), None);
}

fn profile_of(settings: &str, files: &str) -> cmux_customize::profile::Profile {
    serde_json::from_str(&format!(
        "{{\"cmuxProfile\":1,\"name\":\"x\",\"settings\":{settings},\"files\":{files}}}"
    ))
    .unwrap()
}

/// A profile import writes only where the draft's base generation holds
/// what was there: never over a file too large to snapshot.
#[test]
fn a_profile_never_writes_over_a_file_no_generation_holds() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let big = "x".repeat(2 * 1024 * 1024 + 1);
    home.write("customize/data.js", &big);
    let customize = home.customize();
    let profile = profile_of(
        "{\"appearance.density\":\"compact\"}",
        "{\"customize/data.js\":\"let small = 1;\\n\",\"themes/night.json\":\"{}\\n\"}",
    );
    match customize.preview_profile(&profile, "cli", 1) {
        Err(Error::Untracked(files)) => {
            assert_eq!(files.len(), 1, "{files:?}");
            assert_eq!(files[0].path, "customize/data.js");
        }
        other => panic!("the large file was written over: {other:?}"),
    }
    // Nothing at all changed: not the file, not the settings, no draft.
    assert_eq!(home.read("customize/data.js").unwrap().len(), big.len());
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(home.read("themes/night.json"), None);
    assert!(customize.status().unwrap().draft.is_none());
}

/// A folder swapped for a link into somewhere the scan never reads (a
/// dotfiles repo) is not written through: not by discard, rollback or a
/// profile.
#[cfg(unix)]
#[test]
fn nothing_is_written_through_a_linked_folder() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("customize/widgets/main.js", "let recorded = 1;\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();

    let dotfiles = home.dir.path().join("dotfiles/widgets");
    fs::create_dir_all(&dotfiles).unwrap();
    fs::write(dotfiles.join("main.js"), "let edited = 2;\n").unwrap();
    fs::remove_dir_all(home.config("customize/widgets")).unwrap();
    std::os::unix::fs::symlink(&dotfiles, home.config("customize/widgets")).unwrap();

    for result in [customize.discard("cli", 2), customize.rollback(Some(1), "cli", 3)] {
        match result {
            Err(Error::Untracked(files)) => {
                assert_eq!(files[0].path, "customize/widgets/main.js", "{files:?}");
            }
            other => panic!("the linked folder was written through: {other:?}"),
        }
    }
    let profile = profile_of("{}", "{\"customize/widgets/extra.js\":\"let theirs = 3;\\n\"}");
    let imported = customize.preview_profile(&profile, "cli", 4);
    assert!(matches!(imported, Err(Error::Untracked(_))), "{imported:?}");
    assert_eq!(fs::read_to_string(dotfiles.join("main.js")).unwrap(), "let edited = 2;\n");
    assert!(!dotfiles.join("extra.js").exists());
}

/// A credential's name and value on two lines (a formatter's choice) are
/// still one credential: masked in a diff, left out of a profile.
#[test]
fn a_credential_split_over_two_lines_is_still_hidden() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write(
        "customize/config.json",
        "{\n  \"apiKey\":\n    \"private-value\",\n  \"name\": \"mine\"\n}\n",
    );
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    for reader in [Reader::Agent, Reader::Person] {
        let live = diff_text(&customize.diff(reader).unwrap());
        assert!(!live.contains("private-value"), "{reader:?}: {live}");
        assert!(live.contains("+    \"[redacted]\","), "{live}");
    }
    customize.apply(None, "cli", 2).unwrap();
    let shown = diff_text(&customize.generation_diff(2, Reader::Agent).unwrap());
    assert!(!shown.contains("private-value"), "{shown}");

    let saved = customize.save_profile("mine", "", 3).unwrap();
    assert!(!fs::read_to_string(&saved.path).unwrap().contains("private-value"));
    assert_eq!(saved.files, ["themes/night.json".to_owned()]);
    let said = saved.left_out.join("\n");
    assert!(said.contains("customize/config.json: line 3 looks like a secret"), "{said}");
}

/// Two imports at once each keep their settings: the whole read, merge,
/// snapshot and write of one happens before the other's.
#[test]
fn two_profile_imports_at_once_lose_neither() {
    for round in 0..12 {
        let home = Home::new();
        home.write("cmux-next.json", "{\n  // mine\n}\n");
        let start = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            for settings in
                ["{\"appearance.density\":\"compact\"}", "{\"appearance.themeFile\":\"night\"}"]
            {
                let (home, start) = (&home, &start);
                scope.spawn(move || {
                    let customize = home.customize();
                    start.wait();
                    customize.preview_profile(&profile_of(settings, "{}"), "cli", 1).unwrap();
                });
            }
        });
        let settings = home.read("cmux-next.json").unwrap();
        assert!(
            settings.contains("\"compact\"") && settings.contains("\"night\""),
            "round {round}: an import was lost: {settings}"
        );
        // Both are asks of one draft, over one baseline. What the first
        // wrote is kept by number before the second writes over it.
        let status = home.customize().status().unwrap();
        assert_eq!(status.draft.unwrap().asks.len(), 2);
        let history = home.customize().generations().unwrap();
        assert_eq!(history.current, Some(1));
        let kinds: Vec<Kind> = history.generations.iter().map(|g| g.kind).collect();
        assert_eq!(kinds, [Kind::Autosaved, Kind::Baseline]);
    }
}

/// A change of only the executable bit is a change: discard puts the mode
/// back and leaves nothing dirty.
#[cfg(unix)]
#[test]
fn discard_puts_back_an_executable_bit() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("customize/run.sh", "#!/bin/sh\n");
    let script = home.config("customize/run.sh");
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o111;
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    assert_eq!(mode(&script), 0);

    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(customize.status().unwrap().dirty());
    customize.discard("cli", 2).unwrap();
    assert_eq!(mode(&script), 0, "the mode was left changed");
    assert!(!customize.status().unwrap().dirty());
}

/// F5: the shortcuts file is an array, and a person who has one can apply.
#[test]
fn a_setup_with_a_shortcuts_file_applies() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write(
        "keybindings.json",
        "// mine\n[\n  { \"key\": \"cmd+k\", \"command\": \"palette.open\" },\n]\n",
    );
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write("cmux-next.json", COMPACT);
    let status = customize.status().unwrap();
    assert_eq!(status.problems, Vec::new(), "{:?}", status.problems);
    assert_eq!(customize.apply(None, "cli", 2).unwrap().generation.n, 2);
    home.write("keybindings.json", "{ \"cmd+k\": \"palette.open\" }\n");
    assert!(matches!(customize.apply(None, "cli", 3), Err(Error::Invalid(_))));
}

/// What the verbs cost as a setup grows: printed (run with `--nocapture`),
/// and held loosely, because a shared runner is noisy, to "four times the
/// files is nowhere near sixteen times the cost": no verb grows faster than
/// the files it must read.
#[test]
fn the_verbs_cost_no_more_than_the_files_they_read() {
    use std::time::Instant;
    let timed = |files: usize| {
        let home = Home::new();
        home.write("cmux-next.json", COZY);
        for n in 0..files {
            home.write(
                &format!("themes/t{n}.json"),
                &format!("{{ \"name\": \"t{n}\", \"pad\": \"{}\" }}\n", "x".repeat(4000)),
            );
        }
        let customize = home.customize();
        customize.ensure_baseline(1).unwrap();
        home.write("cmux-next.json", COMPACT);
        home.write("themes/t0.json", "{ \"name\": \"changed\" }\n");
        let best = |run: &dyn Fn()| {
            (0..5)
                .map(|_| {
                    let start = Instant::now();
                    run();
                    start.elapsed()
                })
                .min()
                .unwrap()
        };
        let status = best(&|| drop(customize.status().unwrap()));
        let start = Instant::now();
        customize.apply(Some("bench"), "test", 2).unwrap();
        let apply = start.elapsed();
        let start = Instant::now();
        customize.rollback(None, "test", 3).unwrap();
        let rollback = start.elapsed();
        eprintln!(
            "customize timings, {files} files: status {status:?}, apply {apply:?}, rollback {rollback:?}"
        );
        status
    };
    let (small, large) = (timed(100), timed(400));
    assert!(
        large < small * 8 + std::time::Duration::from_millis(50),
        "status: {small:?} for 100 files, {large:?} for 400"
    );
}

const CU_ON: &str = "{\n  \"appearance\": { \"density\": \"cozy\" },\n  \"computerUse\": { \"enabled\": true }\n}\n";
const CU_OFF: &str = "{\n  \"appearance\": { \"density\": \"compact\" },\n  \"computerUse\": { \"enabled\": false }\n}\n";

/// An agent's rollback or discard never turns back on what the person
/// turned off: it is held to the settings an agent may set, like
/// `settings_set`. The person's own restore goes through.
#[test]
fn an_agent_cannot_restore_a_setting_only_the_person_can_change() {
    let home = Home::new();
    home.write("cmux-next.json", CU_ON);
    home.write("themes/night.json", "{ \"name\": \"night\" }\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    // The person turns Computer Use off by hand and applies it.
    home.write("cmux-next.json", CU_OFF);
    customize.apply(None, "cli", 2).unwrap();

    match customize.rollback(Some(1), "mcp", 3) {
        Err(Error::Protected(keys)) => assert_eq!(keys, ["computerUse.enabled"]),
        other => panic!("the agent turned Computer Use back on: {other:?}"),
    }
    assert_eq!(home.read("cmux-next.json").unwrap(), CU_OFF);
    assert_eq!(customize.generations().unwrap().current, Some(2));
    let said = Error::Protected(vec!["computerUse.enabled".to_owned()]).to_string();
    assert!(said.contains("computerUse.enabled") && !said.contains("true"), "{said}");

    // The same through a draft: the person turns it on again without
    // applying, then off is what a discard would restore. Going the other
    // way (generation 2 has it off, live has it on) is refused as well: the
    // gate is the key, not the direction.
    customize.begin("try a theme", "mcp", 4).unwrap();
    home.write("cmux-next.json", CU_ON);
    assert!(matches!(customize.discard("mcp", 5), Err(Error::Protected(_))));
    assert_eq!(home.read("cmux-next.json").unwrap(), CU_ON);
    // The person's own discard is theirs to make.
    customize.discard("cli", 6).unwrap();
    assert_eq!(home.read("cmux-next.json").unwrap(), CU_OFF);

    // What an agent may set, it may put back: a restore that leaves the
    // protected settings as they are goes through.
    home.write("themes/night.json", "{ \"name\": \"midnight\" }\n");
    home.write("cmux-next.json", &CU_OFF.replace("compact", "cozy"));
    customize.apply(None, "cli", 7).unwrap();
    let back = customize.rollback(Some(2), "mcp", 8).unwrap();
    assert_eq!(back.generation.n, 2);
    assert_eq!(home.read("cmux-next.json").unwrap(), CU_OFF);
    assert_eq!(home.read("themes/night.json").unwrap(), "{ \"name\": \"night\" }\n");
}

/// A script's credentials are hidden however the script quotes them:
/// in every diff, and in what a saved profile carries.
#[test]
fn a_credential_in_a_script_is_hidden_from_diffs_and_profiles() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    home.write("customize/main.js", "const config = {apiKey: 'private-value'};\n");
    home.write("customize/other.js", "const config = {\n  'token':\n    `private-value`,\n};\n");
    home.write("customize/plain.js", "const title = 'kept';\n");
    home.write("customize/long.js", "const token = `\nprivate-value\n`;\nconst name = 'shown';\n");
    for reader in [Reader::Agent, Reader::Person] {
        let live = diff_text(&customize.diff(reader).unwrap());
        assert!(!live.contains("private-value"), "{reader:?}: {live}");
        assert!(live.contains("+const config = {apiKey: '[redacted]'};"), "{live}");
        assert!(live.contains("+const title = 'kept';"), "{live}");
    }
    customize.apply(None, "cli", 2).unwrap();
    let shown = diff_text(&customize.generation_diff(2, Reader::Agent).unwrap());
    assert!(!shown.contains("private-value"), "{shown}");

    let saved = customize.save_profile("mine", "", 3).unwrap();
    assert!(!fs::read_to_string(&saved.path).unwrap().contains("private-value"));
    assert_eq!(saved.files, ["customize/plain.js".to_owned()]);
    let said = saved.left_out.join("\n");
    assert!(said.contains("customize/main.js: line 1 looks like a secret"), "{said}");
    assert!(said.contains("customize/other.js: line 3 looks like a secret"), "{said}");
    assert!(said.contains("customize/long.js: line 2 looks like a secret"), "{said}");
}

/// A profile that is refused says which setting, or where the file stops
/// being a profile: never the value, which an agent reads in the answer.
#[test]
fn a_refused_profile_never_quotes_what_it_carries() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    let customize = home.customize();
    let profile = profile_of("{\"appearance.density\":{\"token\":\"private-value\"}}", "{}");
    match customize.preview_profile(&profile, "mcp", 1) {
        Err(Error::Profile(said)) => {
            assert!(said.contains("appearance.density") && !said.contains("private"), "{said}");
        }
        other => panic!("the value was taken: {other:?}"),
    }
    let file = home.config("leaky-profile.json");
    fs::write(&file, "{\n  \"cmuxProfile\": \"private-value\",\n  \"name\": \"x\"\n}\n").unwrap();
    match customize.load_profile(&file.to_string_lossy()) {
        Err(Error::Profile(said)) => {
            assert!(
                said.contains("not a cmux profile (line 2") && !said.contains("private"),
                "{said}"
            );
        }
        other => panic!("read as a profile: {:?}", other.map(|profile| profile.name)),
    }
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
}

/// A profile imported into an open preview writes over files no generation
/// holds yet: they are kept by number first, so rollback brings them back.
#[test]
fn a_profile_imported_into_an_open_preview_keeps_what_it_writes_over() {
    let home = Home::new();
    home.write("cmux-next.json", COZY);
    home.write("customize/main.js", "let v = 1;\n");
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.begin("a bigger sidebar", "cli", 2).unwrap();
    home.write("customize/main.js", "let v = 2; // the preview\n");

    let profile = profile_of(
        "{\"appearance.density\":\"compact\"}",
        "{\"customize/main.js\":\"let v = 3;\\n\"}",
    );
    customize.preview_profile(&profile, "cli", 3).unwrap();
    assert_eq!(home.read("customize/main.js").unwrap(), "let v = 3;\n");
    let history = customize.generations().unwrap();
    // The preview is generation 2, kept and not current.
    assert_eq!(history.current, Some(1));
    let kept = history.generations.first().unwrap();
    assert_eq!((kept.n, kept.kind), (2, Kind::Autosaved));
    assert_eq!(kept.label, "the preview before the profile x");

    // Importing again keeps the first import's result (generation 3), once:
    // a third import of the same bytes has nothing new to keep.
    customize.preview_profile(&profile, "cli", 4).unwrap();
    customize.preview_profile(&profile, "cli", 5).unwrap();
    assert_eq!(customize.generations().unwrap().generations.len(), 3);

    customize.rollback(Some(2), "cli", 5).unwrap();
    assert_eq!(home.read("customize/main.js").unwrap(), "let v = 2; // the preview\n");
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
}
