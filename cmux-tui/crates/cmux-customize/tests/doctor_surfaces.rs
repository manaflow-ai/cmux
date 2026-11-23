//! A broken sidebar, menu or widget customization is found by the doctor,
//! named with its file and line, and put back in one step (Leo, 2026-11-19:
//! "if there's errant files etc that affect customizations it should be able
//! to automatically tell the user and inform them", "make sure you can
//! recover and stuff. for all customizations").

use std::fs;
use std::path::PathBuf;

use cmux_customize::library::doctor::{Finding, FindingKind, FixKind, Report};
use cmux_customize::library::expire::Expiry;
use cmux_customize::{Customize, Roots};

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

// Sidebar ---------------------------------------------------------------

const GOOD_SIDEBAR: &str =
    "{\n  \"sidebar\": {\n    \"style\": \"rail\",\n    \"density\": \"comfortable\"\n  }\n}\n";

#[test]
fn a_clean_sidebar_customization_has_nothing_to_say() {
    let home = Home::new();
    home.write("cmux-next.json", GOOD_SIDEBAR);
    let report = home.customize().doctor(&at(NOW));
    assert_eq!(kinds(&report), Vec::new());
}

#[test]
fn a_sidebar_value_the_setting_refuses_is_named_with_its_line_and_restored() {
    let home = Home::new();
    home.write("cmux-next.json", GOOD_SIDEBAR);
    let customize = home.customize();
    customize.ensure_baseline(NOW - 10).unwrap();
    home.write(
        "cmux-next.json",
        "{\n  \"sidebar\": {\n    \"style\": \"neon\",\n    \"density\": \"comfortable\"\n  }\n}\n",
    );
    let report = customize.doctor(&at(NOW));
    let broken = find(&report, "broken:settings.json");
    assert_eq!(broken.line, Some(3), "{broken:#?}");
    assert!(broken.detail.to_lowercase().contains("sidebar.style"), "{}", broken.detail);
    assert!(!broken.detail.contains("neon"), "the refused value stays in the file");
    assert_eq!(broken.fixes[0].kind, FixKind::Restore);

    customize.doctor_fix(&broken.id, FixKind::Restore, &at(NOW), "cli").unwrap();
    assert_eq!(fs::read_to_string(home.config("cmux-next.json")).unwrap(), GOOD_SIDEBAR);
    assert_eq!(kinds(&customize.doctor(&at(NOW))), Vec::new());
}

#[test]
fn a_misspelled_sidebar_key_is_named_and_a_sidebar_file_that_does_not_parse_is_broken() {
    let home = Home::new();
    home.write("cmux-next.json", "{\n  \"sidebar\": {\n    \"densty\": \"compact\"\n  }\n}\n");
    let report = home.customize().doctor(&at(NOW));
    let typo = find(&report, "unknown-key:sidebar.densty");
    assert_eq!(typo.line, Some(3));

    home.write("cmux-next.json", "{\n  \"sidebar\": {\n    \"style\": \n  }\n}\n");
    let report = home.customize().doctor(&at(NOW));
    let broken = find(&report, "broken:settings.json");
    assert_eq!(broken.level, cmux_customize::library::doctor::Level::Warning);
}

// Menus -----------------------------------------------------------------

const GOOD_MENUS: &str = r#"{
  "actions": {
    "build": { "command": "make" },
    "codex": { "type": "agent", "agent": "codex", "target": "currentTerminal" }
  },
  "contextMenus": {
    "layouts": {
      "workspaceRow": {
        "items": ["renameWorkspace", "-", { "key": "group:mine", "title": "Mine", "items": ["closeWorkspace"] }],
        "hidden": ["workspace.copyPath"]
      }
    }
  },
  "workspaceGroups": {
    "byCwd": {
      "~/src/*": { "contextMenu": [{ "action": "renameWorkspace" }, { "action": "cmuxConfig.build" }] }
    }
  }
}
"#;

#[test]
fn a_clean_menu_customization_has_nothing_to_say() {
    let home = Home::new();
    home.write("cmux-next.json", GOOD_MENUS);
    let report = home.customize().doctor(&at(NOW));
    assert_eq!(kinds(&report), Vec::new());
}

#[test]
fn each_menu_entry_cmux_skips_is_named_with_its_line_and_the_menus_are_restored() {
    let home = Home::new();
    home.write("cmux-next.json", GOOD_MENUS);
    let customize = home.customize();
    customize.ensure_baseline(NOW - 10).unwrap();
    let bad = GOOD_MENUS
        .replace(r#""command": "make""#, r#""type": "workspace""#)
        .replace(r#""-", { "key""#, r#""no.such.row", { "key""#)
        .replace(r#"{ "action": "cmuxConfig.build" }"#, r#"{ "action": "nope" }"#);
    home.write("cmux-next.json", &bad);
    let report = customize.doctor(&at(NOW));

    let action = find(&report, "ignored:menu:actions.build");
    assert_eq!(action.line, Some(3), "{action:#?}");
    assert!(action.title.contains("workspace"), "{}", action.title);
    let row = find(&report, "ignored:menu:contextMenus.layouts.workspaceRow.no.such.row");
    assert_eq!(row.line, Some(9), "{row:#?}");
    let group = find(&report, "ignored:menu:workspaceGroups.byCwd.~/src/*.contextMenu.1");
    assert_eq!(group.line, Some(16), "{group:#?}");
    for finding in [action, row, group] {
        assert_eq!(finding.kind, FindingKind::Ignored);
        let fixes: Vec<_> = finding.fixes.iter().map(|fix| fix.kind).collect();
        assert_eq!(fixes, [FixKind::Open, FixKind::Restore], "{finding:#?}");
    }

    customize.doctor_fix(&row.id, FixKind::Restore, &at(NOW), "cli").unwrap();
    assert_eq!(fs::read_to_string(home.config("cmux-next.json")).unwrap(), GOOD_MENUS);
    assert_eq!(kinds(&customize.doctor(&at(NOW))), Vec::new());
}

#[test]
fn a_menu_problem_with_no_good_version_to_go_back_to_offers_only_open() {
    let home = Home::new();
    home.write(
        "cmux-next.json",
        "{\n  \"actions\": {\n    \"x\": { \"type\": \"command\" }\n  }\n}\n",
    );
    let report = home.customize().doctor(&at(NOW));
    let action = find(&report, "ignored:menu:actions.x");
    assert_eq!(action.line, Some(3));
    let fixes: Vec<_> = action.fixes.iter().map(|fix| fix.kind).collect();
    assert_eq!(fixes, [FixKind::Open]);
}

// Widgets ---------------------------------------------------------------

const GOOD_WIDGET: &str = r#"{
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "description": "My own views",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": {
    "cmux.widget/1": {
      "export": "renderWidget",
      "title": "Clock",
      "symbol": "clock",
      "options": { "sizes": ["small", "medium"], "defaultSize": "small", "places": ["newtab", "sidebar"] }
    }
  }
}
"#;

#[test]
fn a_clean_widget_has_nothing_to_say() {
    let home = Home::new();
    home.write("customize/cmux-app.json", GOOD_WIDGET);
    home.write("customize/main.js", "export function renderWidget() {}\n");
    let report = home.customize().doctor(&at(NOW));
    assert_eq!(kinds(&report), Vec::new());
}

#[test]
fn a_widget_cmux_cannot_draw_is_named_and_restored_from_its_last_version_that_loaded() {
    let home = Home::new();
    home.write("customize/cmux-app.json", GOOD_WIDGET);
    home.write("customize/main.js", "export function renderWidget() {}\n");
    let customize = home.customize();
    customize.ensure_baseline(NOW - 10).unwrap();
    home.write(
        "customize/cmux-app.json",
        &GOOD_WIDGET.replace(r#""defaultSize": "small""#, r#""defaultSize": "large""#),
    );
    let report = customize.doctor(&at(NOW));
    let broken = find(&report, "broken:customize/cmux-app.json");
    assert!(broken.detail.contains("defaultSize"), "{}", broken.detail);
    assert_eq!(broken.fixes[0].kind, FixKind::Restore, "{broken:#?}");

    customize.doctor_fix(&broken.id, FixKind::Restore, &at(NOW), "cli").unwrap();
    assert_eq!(fs::read_to_string(home.config("customize/cmux-app.json")).unwrap(), GOOD_WIDGET);
    assert_eq!(kinds(&customize.doctor(&at(NOW))), Vec::new());
}
