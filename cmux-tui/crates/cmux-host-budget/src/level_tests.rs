//! The app's level tests (CmuxNextHostPressureTests `HostPressureTrackerTests`,
//! ported with the Swift tracker): the warning and the banner come from the
//! shared host budget (12 performance cores here, a load limit of 12) and do
//! not flicker.

use super::*;
use crate::tests::gray;
use crate::{Budget, Formula, parse_budget, short_host_name, with_pressure};

const NORMAL: u32 = 1;
const WARN: u32 = 2;
const CRITICAL: u32 = 4;

fn verdict(load: f64, pressure: u32, ram: f64, swap: f64) -> crate::Verdict {
    gray(load, pressure, ram, swap, &Budget::default())
}

fn at(load: f64, pressure: u32) -> Reading {
    Reading::from(&verdict(load, pressure, 0.5, 0.0))
}

fn calm() -> Reading {
    at(2.0, NORMAL)
}

#[test]
fn a_busy_but_fine_mac_shows_nothing() {
    let mut tracker = Tracker::default();
    assert_eq!(tracker.feed(&at(8.9, NORMAL)), None);
    assert_eq!(tracker.level(), Level::Normal);
}

#[test]
fn the_warning_starts_below_the_budget() {
    let mut tracker = Tracker::default();
    assert_eq!(tracker.feed(&at(9.0, NORMAL)), Some(Level::Warning));
    assert!(verdict(9.0, NORMAL, 0.5, 0.0).ok);
}

#[test]
fn each_part_of_the_budget() {
    let rows = [
        (12.0, NORMAL, 0.5, 0.0, Level::Warning),
        (2.0, WARN, 0.5, 0.0, Level::Warning),
        (2.0, NORMAL, 0.5, 65.0, Level::Warning),
        (2.0, NORMAL, 0.5, 64.0, Level::Normal),
        (2.0, NORMAL, 0.04, 0.0, Level::Warning),
        (2.0, NORMAL, 0.10, 0.0, Level::Normal),
        (13.0, NORMAL, 0.04, 0.0, Level::Critical),
        (2.0, CRITICAL, 0.5, 0.0, Level::Critical),
        (146.0, WARN, 0.5, 0.0, Level::Critical),
        (2.0, WARN, 0.5, 200.0, Level::Critical),
        (146.0, NORMAL, 0.5, 0.0, Level::Warning),
    ];
    for (load, pressure, ram, swap, level) in rows {
        let reading = Reading::from(&verdict(load, pressure, ram, swap));
        assert_eq!(level_for(&reading, Level::Normal), level, "{load} {pressure} {ram} {swap}");
    }
}

/// acpmux's phrases, in its order, for each part of the budget.
#[test]
fn the_reasons_are_acpmuxs() {
    assert_eq!(
        verdict(13.0, WARN, 0.04, 70.0).over,
        [
            "load1 13.0 >= 12 (12 P-cores)",
            "memory pressure warn",
            "available RAM 4% < 10%",
            "swap +70 MB/min"
        ]
    );
}

/// A formula that allows warn pressure counts only critical, sampled or from an event.
#[test]
fn an_allowed_warn_is_within_budget() {
    let budget = Budget {
        formula: Formula { pressure: "warn".into(), ..Formula::default() },
        ..Budget::default()
    };
    assert!(gray(2.0, WARN, 0.5, 0.0, &budget).ok);
    let busy = serde_json::to_value(gray(13.0, NORMAL, 0.5, 0.0, &budget)).unwrap();
    let warned = with_pressure(&busy, "warn").unwrap();
    assert_eq!(warned["over"].as_array().unwrap().len(), 1);
    let read = |v: serde_json::Value| serde_json::from_value::<Reading>(v).unwrap();
    assert_eq!(level_for(&read(warned), Level::Normal), Level::Warning);
    let critical = with_pressure(&busy, "critical").unwrap();
    assert_eq!(level_for(&read(critical), Level::Normal), Level::Critical);
}

#[test]
fn a_raised_level_falls_only_after_calm_samples() {
    let mut tracker = Tracker::new(2);
    assert_eq!(tracker.feed(&at(2.0, CRITICAL)), Some(Level::Critical));
    assert_eq!(tracker.feed(&calm()), None);
    assert_eq!(tracker.level(), Level::Critical);
    assert_eq!(tracker.feed(&calm()), Some(Level::Normal));
}

#[test]
fn a_pressed_sample_resets_the_calm_streak() {
    let mut tracker = Tracker::new(2);
    tracker.feed(&at(2.0, WARN));
    assert_eq!(tracker.feed(&calm()), None);
    assert_eq!(tracker.feed(&at(2.0, WARN)), None);
    assert_eq!(tracker.feed(&calm()), None);
    assert_eq!(tracker.feed(&calm()), Some(Level::Normal));
}

#[test]
fn a_load_warning_holds_through_the_deadband() {
    let mut tracker = Tracker::new(1);
    assert_eq!(tracker.feed(&at(9.0, NORMAL)), Some(Level::Warning));
    assert_eq!(tracker.feed(&at(8.0, NORMAL)), None);
    assert_eq!(tracker.level(), Level::Warning);
    assert_eq!(tracker.feed(&at(7.7, NORMAL)), Some(Level::Normal));
}

#[test]
fn critical_steps_down_through_warning() {
    let mut tracker = Tracker::new(1);
    tracker.feed(&at(20.0, WARN));
    assert_eq!(tracker.level(), Level::Critical);
    assert_eq!(tracker.feed(&at(20.0, NORMAL)), Some(Level::Warning));
    assert_eq!(tracker.feed(&calm()), Some(Level::Normal));
}

#[test]
fn calm_samples_is_at_least_one() {
    assert_eq!(Tracker::new(0).calm_samples(), 1);
    assert_eq!(Tracker::default().calm_samples(), 2);
}

#[test]
fn the_dispatch_sources_pressure_replaces_the_sampled_one() {
    let sampled = serde_json::to_value(verdict(13.0, NORMAL, 0.5, 70.0)).unwrap();
    assert_eq!(sampled["formula"]["pressure"], "normal");
    assert_eq!(
        sampled["over"],
        serde_json::json!(["load1 13.0 >= 12 (12 P-cores)", "swap +70 MB/min"])
    );
    let newer = with_pressure(&sampled, "warn").unwrap();
    assert_eq!(
        newer["over"],
        serde_json::json!([
            "load1 13.0 >= 12 (12 P-cores)",
            "swap +70 MB/min",
            "memory pressure warn"
        ])
    );
    assert_eq!(newer["pressure"], "warn");
    let critical = with_pressure(&newer, "critical").unwrap();
    assert_eq!(critical["over"].as_array().unwrap().last().unwrap(), "memory pressure critical");
    assert_eq!(with_pressure(&newer, "normal").unwrap()["over"], sampled["over"]);
    assert_eq!(newer["ok"], false);
    let fine = serde_json::to_value(verdict(2.0, NORMAL, 0.5, 0.0)).unwrap();
    let back = with_pressure(&with_pressure(&fine, "warn").unwrap(), "normal").unwrap();
    assert_eq!(back["ok"], true);
    assert_eq!(back["warning"], serde_json::Value::Null);
}

/// The same pressure keeps the verdict as it is; a word that is not a level,
/// or JSON that is not a verdict, gives nothing.
#[test]
fn a_pressure_change_needs_a_verdict_and_a_level() {
    let sampled = serde_json::to_value(verdict(13.0, NORMAL, 0.5, 70.0)).unwrap();
    assert_eq!(with_pressure(&sampled, "normal").unwrap(), sampled);
    assert_eq!(with_pressure(&sampled, "severe"), None);
    assert_eq!(with_pressure(&serde_json::json!({"ok": null}), "warn"), None);
    assert_eq!(with_pressure(&serde_json::json!([1]), "warn"), None);
}

/// The warning line follows the new reasons.
#[test]
fn the_warning_line_follows_the_new_pressure() {
    let sampled = serde_json::to_value(verdict(2.0, NORMAL, 0.5, 0.0)).unwrap();
    let warned = with_pressure(&sampled, "warn").unwrap();
    assert_eq!(
        warned["warning"],
        "host-budget: gray over its CPU/RAM budget: memory pressure warn"
    );
}

/// acpmux keys `hosts` by the lowercased short name, and 0 turns the RAM reason off.
#[test]
fn a_mixed_case_host_gets_its_override() {
    let file = br#"{"formula": {"min_available_ram_fraction": 0.2},
        "hosts": {"cosmic-gray": {"load1_per_core": 2, "min_available_ram_fraction": 0}}}"#;
    let host = short_host_name(" Cosmic-Gray.local");
    assert_eq!(host, "cosmic-gray");
    let budget = parse_budget(Some(file), &host);
    assert_eq!(budget.formula.min_available_ram_fraction, 0.0);
    let v = gray(25.0, NORMAL, 0.04, 0.0, &budget);
    assert_eq!(v.load_limit, 24.0);
    assert_eq!(v.over, ["load1 25.0 >= 24 (12 P-cores)"]);
    assert_eq!(level_for(&Reading::from(&v), Level::Normal), Level::Warning);
    assert_eq!(short_host_name(""), "localhost");
}

#[test]
fn a_logical_core_budget_says_cores() {
    let budget = Budget {
        formula: Formula { cores: "logical".into(), ..Formula::default() },
        ..Budget::default()
    };
    let sample = crate::Sample { load1: Some(15.0), logical_cpus: 15, ..crate::Sample::default() };
    let v = crate::evaluate("x", &sample, None, &budget);
    assert_eq!(v.over, ["load1 15.0 >= 15 (15 cores)"]);
}

#[test]
fn the_override_keeps_acpmuxs_rules() {
    let file = br#"{"formula": {"pressure": "warn", "min_available_ram_fraction": 0.2, "cores": "logical"},
        "hosts": {"bad": {"pressure": "critical", "min_available_ram_fraction": 2, "cores": "all"}}}"#;
    let formula = parse_budget(Some(file), "gray").formula;
    assert_eq!(formula.pressure, "warn");
    assert_eq!(formula.min_available_ram_fraction, 0.2);
    assert_eq!(formula.cores, "logical");
    assert_eq!(parse_budget(Some(file), "bad").formula, formula);
}

#[test]
fn levels_have_the_c_abi_numbers() {
    for level in [Level::Normal, Level::Warning, Level::Critical] {
        assert_eq!(Level::from_code(level.code()), Some(level));
    }
    assert_eq!((Level::Normal.code(), Level::Warning.code(), Level::Critical.code()), (0, 1, 2));
    assert_eq!(Level::from_code(3), None);
    assert_eq!(Level::from_code(-1), None);
}
