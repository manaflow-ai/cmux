//! The journeys, end to end on a real folder: a person alone, an agent
//! alone, the two taking turns, and a profile moving between machines.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::{ChangeKind, Customize, Error, Kind, Part, Roots, brief};

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
  "implements": { "cmux.section/1": { "export": "renderSection", "title": "PRs", "symbol": "sparkles" } }
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
    let diff = customize.diff().unwrap();
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

    home.write("themes/leaky.json", "{ \"name\": \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\" }\n");
    assert!(matches!(customize.save_profile("leaky", "", 2), Err(Error::Profile(_))));
    assert!(!home.config("profiles/leaky.json").exists());
}
