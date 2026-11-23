//! The doctor finds, on its own, every file or layer that changes a
//! customization in a way the person may not expect, and each fix runs only
//! when asked (Leo, 2026-11-19: "if there's errant files etc that affect
//! customizations it should be able to automatically tell the user and
//! inform them"). Each test plants the bad file and reads the report.

use std::fs;
use std::path::PathBuf;

use cmux_customize::library::CodeLayer;
use cmux_customize::library::doctor::{Finding, FindingKind, FixKind, Level, Report};
use cmux_customize::library::expire::Expiry;
use cmux_customize::{Customize, Roots};
use serde_json::json;

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
}

const NOW: u64 = 1_794_733_200_000;

fn at(now_ms: u64) -> Expiry {
    Expiry { now_ms, app_abi: Some(1), ended: Default::default() }
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

fn install(customize: &Customize, n: u8) {
    let dir = customize.layer_dir(&key(n));
    fs::create_dir_all(dir.join("pages")).unwrap();
    fs::write(dir.join("manifest.json"), "{}").unwrap();
}

fn kinds(report: &Report) -> Vec<(FindingKind, String)> {
    report.findings.iter().map(|finding| (finding.kind, finding.id.clone())).collect()
}

fn find<'a>(report: &'a Report, id: &str) -> &'a Finding {
    report
        .findings
        .iter()
        .find(|finding| finding.id == id)
        .unwrap_or_else(|| panic!("no {id} in {:#?}", kinds(report)))
}

#[test]
fn a_clean_customization_has_nothing_to_say() {
    let home = Home::new();
    home.write("cmux-next.json", "{ // mine\n  \"appearance\": { \"density\": \"compact\" } }\n");
    home.write("themes/night.json", "{ \"appearance\": { \"accent\": \"blue\" } }\n");
    home.write("agent-pane/theme.css", ":root { --agent-gap: 4px }\n");
    let report = home.customize().doctor(&at(NOW));
    assert_eq!(kinds(&report), Vec::new());
    assert_eq!(report.line, None);
}

#[test]
fn a_stale_pr_layer_and_a_broken_file_are_both_said_in_one_line() {
    let home = Home::new();
    home.write("themes/night.json", "{\n  \"appearance\": {\n    \"accent\": }\n}\n");
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(45206, 1), vec![], "cli", NOW - 3 * 3_600_000).unwrap();

    let report = customize.doctor(&at(NOW));
    let stale = find(&report, "layer-on:pr-45206");
    assert_eq!(stale.level, Level::Warning);
    assert_eq!(stale.title, "pr-45206 is still on");
    assert!(stale.detail.contains("PR #45206's web pages"), "{}", stale.detail);
    assert!(stale.detail.contains("on 3 hours"), "{}", stale.detail);
    assert_eq!(stale.fixes[0].kind, FixKind::Off);

    let broken = find(&report, "broken:themes/night.json");
    assert_eq!(broken.line, Some(3));
    assert_eq!(broken.place, "themes/night.json:3");
    assert!(broken.path.as_deref().unwrap().ends_with("config/themes/night.json"));
    assert!(broken.detail.contains("last version that loaded"), "{}", broken.detail);

    assert_eq!(
        report.line.as_deref(),
        Some(
            "2 things change your customization: pr-45206 is still on; themes/night.json does not load"
        )
    );
}

#[test]
fn turning_a_stale_layer_off_from_the_doctor_is_library_off() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(7, 1), vec![], "cli", NOW - 1000).unwrap();
    let fixed = customize.doctor_fix("layer-on:pr-7", FixKind::Off, &at(NOW), "cli").unwrap();
    assert_eq!(fixed.said, "pr-7 is off; back: cmux customize library on pr-7");
    let listing = customize.library().unwrap();
    assert!(!listing.entries[0].on);
    assert!(customize.doctor(&at(NOW)).findings.iter().all(|f| f.kind != FindingKind::LayerOn));
    // A fix the finding does not offer is refused, and nothing changes.
    let refused = customize.doctor_fix("layer-on:pr-7", FixKind::Off, &at(NOW), "cli");
    assert!(refused.is_err());
}

#[test]
fn a_layer_for_another_web_abi_pins_an_old_build() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(9, 1), vec![], "cli", NOW - 1000).unwrap();
    let report = customize.doctor(&Expiry { app_abi: Some(3), ..at(NOW) });
    let old = find(&report, "old-build:pr-9");
    assert!(old.detail.contains("web ABI 1 and this app has 3"), "{}", old.detail);
}

#[test]
fn a_hand_installed_web_dev_overlay_is_named_and_turned_off_on_request() {
    let home = Home::new();
    let overlay = home.dir.path().join("overlay");
    fs::create_dir_all(&overlay).unwrap();
    fs::write(
        overlay.join("manifest.json"),
        json!({"commit": "01192304abcdef", "abi": 1}).to_string(),
    )
    .unwrap();
    home.write(
        "web-dev.json",
        &json!({"server": "http://127.0.0.1:4200/", "overlay": overlay, "enabled": true})
            .to_string(),
    );
    let customize = home.customize();
    let report = customize.doctor(&at(NOW));
    let found = find(&report, "web-dev-overlay:web-dev.json");
    assert!(found.detail.contains("@01192304"), "{}", found.detail);
    customize.doctor_fix(&found.id, FixKind::Off, &at(NOW), "cli").unwrap();
    let web_dev: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(home.config("web-dev.json")).unwrap()).unwrap();
    assert_eq!(web_dev["enabled"], json!(false));
    assert_eq!(web_dev["server"], json!("http://127.0.0.1:4200/"), "other keys stay");
    assert!(customize.doctor(&at(NOW)).findings.is_empty());
}

#[test]
fn a_layer_folder_no_entry_uses_is_left_over_and_removal_keeps_a_copy() {
    let home = Home::new();
    let customize = home.customize();
    install(&customize, 4);
    let report = customize.doctor(&at(NOW));
    let id = format!("leftover:layers/{}", key(4));
    let leftover = find(&report, &id);
    assert_eq!(leftover.level, Level::Info);
    assert!(leftover.fixes.iter().any(|fix| fix.kind == FixKind::Remove && fix.confirm));
    let fixed = customize.doctor_fix(&id, FixKind::Remove, &at(NOW), "cli").unwrap();
    let kept = PathBuf::from(fixed.kept.unwrap());
    assert!(kept.join("manifest.json").is_file(), "moved, not deleted");
    assert!(!customize.layer_dir(&key(4)).exists());
    assert!(kept.starts_with(home.dir.path().join("state/doctor/removed")));
}

#[test]
fn an_unknown_and_a_misspelled_settings_key_are_named_with_their_line() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{\n  \"appearance\": {\n    \"density\": \"compact\",\n    \"acent\": \"blue\"\n  },\n  \"notASection\": 1\n}\n",
    );
    let report = home.customize().doctor(&at(NOW));
    let typo = find(&report, "unknown-key:appearance.acent");
    assert_eq!(typo.title, "appearance.acent is not a setting");
    assert_eq!(typo.line, Some(4));
    assert_eq!(typo.place, "cmux-next.json:4");
    find(&report, "unknown-key:notASection");
    assert!(report.findings.iter().all(|f| f.id != "unknown-key:appearance.density"));
}

#[test]
fn a_theme_that_overrides_a_setting_and_a_missing_theme_are_said() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{\n  \"appearance\": {\n    \"themeFile\": \"night\",\n    \"density\": \"compact\"\n  }\n}\n",
    );
    home.write("themes/night.json", "{ \"appearance\": { \"density\": \"comfortable\" } }\n");
    let customize = home.customize();
    let report = customize.doctor(&at(NOW));
    let shadow = find(&report, "shadowed:theme:appearance.density");
    assert_eq!(shadow.title, "Theme night overrides your appearance.density");
    assert_eq!(shadow.line, Some(4));

    home.write("cmux-next.json", "{ \"appearance\": { \"themeFile\": \"gone\" } }\n");
    let report = customize.doctor(&at(NOW));
    let missing = find(&report, "broken:themes/gone.json");
    assert_eq!(missing.title, "Theme gone is not there");
}

#[test]
fn files_in_the_wrong_folder_or_with_the_wrong_name_are_found() {
    let home = Home::new();
    home.write("theme.css", ":root {}\n");
    home.write("agentpane/theme.css", ":root {}\n");
    home.write("night.json", "{ \"colors\": { \"background\": \"#000000\" } }\n");
    home.write("themes/dusk.jsonc", "{ \"appearance\": {} }\n");
    home.write("themes/old/dawn.json", "{}\n");
    home.write("automations/backup.json", "{}\n");
    let report = home.customize().doctor(&at(NOW));
    let pane = find(&report, "wrong-folder:agentpane/theme.css");
    assert!(pane.detail.contains("agent-pane/theme.css"), "{}", pane.detail);
    find(&report, "wrong-folder:theme.css");
    find(&report, "wrong-folder:night.json");
    find(&report, "ignored:themes/dusk.jsonc");
    find(&report, "wrong-folder:themes/old/dawn.json");
    let automation = find(&report, "wrong-folder:automations/backup.json");
    assert!(automation.detail.contains("backup/automation.json"), "{}", automation.detail);
}

#[test]
fn announce_says_each_finding_once_and_again_when_it_changes() {
    let home = Home::new();
    home.write("themes/night.json", "{ \"appearance\": }\n");
    let customize = home.customize();
    let first = customize.doctor_announce(&at(NOW)).unwrap();
    assert_eq!(first.announce.as_deref(), Some("Customization: themes/night.json does not load"));
    let again = customize.doctor_announce(&at(NOW)).unwrap();
    assert_eq!(again.announce, None, "nothing new");
    assert!(again.line.is_some(), "still listed");
    home.write("themes/night.json", "{\n\n  \"appearance\": }\n");
    let changed = customize.doctor_announce(&at(NOW)).unwrap();
    assert!(changed.announce.is_some(), "a different problem is new: {:?}", changed.findings);
}

#[test]
fn a_dismissed_finding_stays_listed_but_leaves_the_notice_until_it_changes() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"mystery\": true }\n");
    let customize = home.customize();
    let report = customize.doctor_dismiss("unknown-key:mystery", &at(NOW)).unwrap();
    assert!(find(&report, "unknown-key:mystery").dismissed);
    assert_eq!(report.line, None);
    assert_eq!(customize.doctor_announce(&at(NOW)).unwrap().announce, None);
    assert!(customize.doctor_dismiss("unknown-key:nothing", &at(NOW)).is_err());
}

#[test]
fn the_doctor_changes_nothing_on_its_own() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"mystery\": true }\n");
    home.write("theme.css", ":root {}\n");
    let customize = home.customize();
    install(&customize, 1);
    customize.library_use_code(layer(1, 1), vec![], "cli", NOW - 1000).unwrap();
    let before = snapshot(home.dir.path());
    customize.doctor(&at(NOW));
    assert_eq!(snapshot(home.dir.path()), before);
}

fn snapshot(root: &std::path::Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut out = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else {
                out.push((path.clone(), fs::read(&path).unwrap()));
            }
        }
    }
    out.sort();
    out
}

/// Leo, 2026-11-19: "make sure you can recover and stuff. for all customizations".
#[test]
fn a_broken_file_is_restored_from_its_last_version_that_loaded() {
    let home = Home::new();
    home.write("themes/night.json", "{ \"appearance\": { \"accent\": \"blue\" } }\n");
    let customize = home.customize();
    customize.ensure_baseline(NOW - 10).unwrap();
    home.write("themes/night.json", "{ \"appearance\": { \"accent\": }\n");
    let report = customize.doctor(&at(NOW));
    let broken = find(&report, "broken:themes/night.json");
    assert_eq!(broken.fixes[0].kind, FixKind::Restore);
    assert!(broken.fixes[0].confirm);
    let fixed = customize.doctor_fix(&broken.id, FixKind::Restore, &at(NOW), "cli").unwrap();
    assert!(
        fixed.said.starts_with("put back themes/night.json from generation 1"),
        "{}",
        fixed.said
    );
    assert_eq!(
        fs::read_to_string(home.config("themes/night.json")).unwrap(),
        "{ \"appearance\": { \"accent\": \"blue\" } }\n"
    );
    let removed = home.dir.path().join("state/doctor/removed");
    let kept: Vec<_> = fs::read_dir(&removed).unwrap().flatten().collect();
    assert_eq!(kept.len(), 1, "the broken text is kept");
    assert!(customize.doctor(&at(NOW)).findings.is_empty());
}

#[test]
fn recover_turns_every_layer_off_and_puts_back_the_newest_setup_that_loads() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"appearance\": { \"density\": \"compact\" } }\n");
    let customize = home.customize();
    customize.ensure_baseline(NOW - 100).unwrap();
    install(&customize, 1);
    customize.library_use_code(layer(45206, 1), vec![], "cli", NOW - 50).unwrap();
    home.write("cmux-next.json", "{ \"appearance\": { \"density\": }\n");
    home.write("themes/new.json", "not json\n");

    let plan = customize.doctor(&at(NOW)).recover.expect("a plan");
    assert_eq!(plan.layers, vec!["pr-45206".to_owned()]);
    assert!(plan.generation.is_some());
    assert!(
        plan.said.starts_with("Recover turns pr-45206 off, puts back generation"),
        "{}",
        plan.said
    );

    let recovery = customize.doctor_recover(&at(NOW), "cli").unwrap();
    assert_eq!(recovery.turned_off, vec!["pr-45206".to_owned()]);
    let kept = recovery.kept_as.expect("what was live is kept");
    assert_eq!(
        fs::read_to_string(home.config("cmux-next.json")).unwrap(),
        "{ \"appearance\": { \"density\": \"compact\" } }\n"
    );
    let after = customize.doctor(&at(NOW));
    assert_eq!(after.recover, None);
    assert!(after.findings.iter().all(|f| f.level != Level::Warning), "{:#?}", kinds(&after));
    // Nothing was lost: the broken setup is one rollback away.
    customize.rollback(Some(kept), "cli", NOW + 1).unwrap();
    assert_eq!(fs::read_to_string(home.config("themes/new.json")).unwrap(), "not json\n");
}

/// Leo, 2026-11-19: "as in like random json that is affecthing things outside of typically expected settings too".
#[test]
fn json_outside_the_usual_settings_names_what_it_sets_and_random_json_is_named_unread() {
    let home = Home::new();
    home.write("cmux-tui.json", "{ \"theme\": \"dracula\", \"chrome\": { \"tabs\": false } }\n");
    home.write("harnesses/mine.toml", "command = \"my-agent\"\n");
    home.write("agent-pane/layout.json", "{ \"quickActions\": [ }\n");
    home.write("agent-pane/registry.js", "export default {}\n");
    home.write("cmux.json", "{ \"agents\": { \"harnesses\": { \"old-claude\": {} } } }\n");
    home.write("leftover-settings.json", "{ \"appearance\": { \"density\": \"compact\" } }\n");
    home.write("server.json", "{ \"token\": \"secret\" }\n");
    let report = home.customize().doctor(&at(NOW));
    let daemon = find(&report, "override:cmux-tui.json");
    assert_eq!(daemon.title, "cmux-tui.json sets chrome, theme");
    find(&report, "override:harnesses");
    let layout = find(&report, "broken:agent-pane/layout.json");
    assert_eq!(layout.level, Level::Warning);
    find(&report, "override:agent-pane/registry.js");
    let classic = find(&report, "override:cmux.json#agents.harnesses");
    assert!(classic.title.ends_with("old-claude"), "{}", classic.title);
    let random = find(&report, "ignored:leftover-settings.json");
    assert!(random.detail.contains("cmux-next.json"), "{}", random.detail);
    assert!(
        report.findings.iter().all(|f| !f.id.contains("server.json")),
        "secrets are never read"
    );
}

/// Leo, 2026-11-19, with his pane dividers gone: "i thought we turned those on by default and htat i was
/// following them by default? where's it all at?"
#[test]
fn a_setting_that_zeroes_a_divider_says_you_are_not_following_its_default() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{\n  // mine\n  \"appearance\": {\n    \"surfaces\": { \"splitDivider\": { \"opacity\": 0 } },\n    \"density\": \"compact\"\n  }\n}\n",
    );
    let customize = home.customize();
    let report = customize.doctor(&at(NOW));
    let id = "not-default:appearance.surfaces.splitDivider.opacity";
    let divider = find(&report, id);
    assert_eq!(divider.level, Level::Warning);
    assert_eq!(
        divider.title,
        "You are not following the default for appearance.surfaces.splitDivider.opacity"
    );
    assert!(
        divider.detail.starts_with("Yours: 0, default: follows Window opacity."),
        "{}",
        divider.detail
    );
    assert_eq!(divider.line, Some(4));
    assert_eq!(divider.fixes[0].kind, FixKind::FollowDefault);
    assert!(
        report.findings.iter().all(|f| f.id != "not-default:appearance.density"),
        "a plain choice is yours"
    );

    let fixed = customize.doctor_fix(id, FixKind::FollowDefault, &at(NOW), "cli").unwrap();
    assert!(
        fixed.said.starts_with("appearance.surfaces.splitDivider.opacity follows its default"),
        "{}",
        fixed.said
    );
    let text = fs::read_to_string(home.config("cmux-next.json")).unwrap();
    assert!(!text.contains("opacity"), "{text}");
    assert!(text.contains("// mine") && text.contains("\"density\": \"compact\""), "{text}");
    assert!(customize.doctor(&at(NOW)).findings.iter().all(|f| f.id != id));
}

#[test]
fn a_default_that_changed_since_you_set_yours_is_said_once_it_was_seen() {
    let home = Home::new();
    home.write("cmux-next.json", "{ \"appearance\": { \"density\": \"spacious\" } }\n");
    let customize = home.customize();
    // The first look records today's default for every key you set.
    customize.doctor_announce(&at(NOW)).unwrap();
    assert!(customize.doctor(&at(NOW)).findings.is_empty());
    // A later cmux ships another default: what the doctor saw before was "comfortable".
    let state = home.dir.path().join("state/doctor.json");
    let mut file: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
    file["seen_defaults"]["appearance.density"] = json!("comfortable");
    fs::write(&state, file.to_string()).unwrap();
    let report = customize.doctor(&at(NOW));
    let changed = find(&report, "not-default:appearance.density");
    assert_eq!(changed.level, Level::Info);
    assert!(
        changed
            .detail
            .contains("The default changed from \"comfortable\" to \"cozy\" since you set yours."),
        "{}",
        changed.detail
    );
}

/// A settings file linked into a dotfiles repo stays linked after Follow default and Restore.
#[cfg(unix)]
#[test]
fn fixes_write_through_a_linked_settings_file_and_never_open_credentials() {
    let home = Home::new();
    let dotfiles = home.dir.path().join("dotfiles");
    fs::create_dir_all(&dotfiles).unwrap();
    let real = dotfiles.join("cmux-next.json");
    fs::write(
        &real,
        "{ \"appearance\": { \"surfaces\": { \"splitDivider\": { \"opacity\": 0 } } } }\n",
    )
    .unwrap();
    fs::create_dir_all(home.config("")).unwrap();
    std::os::unix::fs::symlink(&real, home.config("cmux-next.json")).unwrap();
    let customize = home.customize();
    customize
        .doctor_fix(
            "not-default:appearance.surfaces.splitDivider.opacity",
            FixKind::FollowDefault,
            &at(NOW),
            "cli",
        )
        .unwrap();
    assert!(fs::symlink_metadata(home.config("cmux-next.json")).unwrap().file_type().is_symlink());
    assert!(!fs::read_to_string(&real).unwrap().contains("opacity"));

    // Restore: the broken text is copied aside, the link is written through.
    home.write("themes/night.json", "{ \"appearance\": { \"accent\": \"blue\" } }\n");
    customize.ensure_baseline(NOW).unwrap();
    let theme_real = dotfiles.join("night.json");
    fs::write(&theme_real, "{ \"appearance\": { \"accent\": }\n").unwrap();
    fs::remove_file(home.config("themes/night.json")).unwrap();
    std::os::unix::fs::symlink(&theme_real, home.config("themes/night.json")).unwrap();
    customize
        .doctor_fix("broken:themes/night.json", FixKind::Restore, &at(NOW + 1), "cli")
        .unwrap();
    assert!(
        fs::symlink_metadata(home.config("themes/night.json")).unwrap().file_type().is_symlink()
    );
    assert_eq!(
        fs::read_to_string(&theme_real).unwrap(),
        "{ \"appearance\": { \"accent\": \"blue\" } }\n"
    );

    // A file named like a credential is never read, so even one shaped like a theme is not named.
    home.write("github-token.json", "{ \"colors\": { \"background\": \"#000000\" } }\n");
    let report = customize.doctor(&at(NOW + 2));
    assert!(
        report.findings.iter().all(|f| !f.id.contains("github-token")),
        "{:#?}",
        kinds(&report)
    );
}
