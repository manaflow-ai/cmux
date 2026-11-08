//! The classic migration's rules on classic 0.64.19's split-workspace
//! session, extended by hand in classic's schema with a second window, two
//! groups (one collapsed with color and icon, one pinned and empty), a
//! colored grouped workspace, a pinned one, a Cloud VM workspace, and a
//! `stableId` saved twice (`tests/fixtures/classic-to-next/session-groups.json`).

use std::collections::BTreeSet;
use std::path::PathBuf;

use cmux_classic_import::decode;
use cmux_classic_import::ledger::{Entry, Ledger, Load, Stage, State};
use cmux_classic_import::model::{Group, Rect, Snapshot};
use cmux_classic_import::plan::{self, Decision, Mode, Plan, PlanGroup, Skip, SkipReason};
use cmux_classic_import::source::Source;
use serde_json::Value;

const BACKEND: &str = "11111111-1111-4111-8111-111111111111";
const SAVED: &str = "22222222-2222-4222-8222-222222222222";
const HOME: &str = "AAAAAAAA-0000-4000-8000-000000000001";
const SPLIT: &str = "AAAAAAAA-0000-4000-8000-000000000002";
const PINNED: &str = "AAAAAAAA-0000-4000-8000-000000000003";
const CLOUD: &str = "AAAAAAAA-0000-4000-8000-000000000004";
const SECOND: &str = "AAAAAAAA-0000-4000-8000-000000000005";

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/fixtures/classic-to-next/session-groups.json")
}

fn snapshot_with(edit: impl FnOnce(&mut Value)) -> Snapshot {
    let mut root: Value = serde_json::from_slice(&std::fs::read(fixture()).unwrap()).unwrap();
    edit(&mut root);
    decode::decode(&serde_json::to_vec(&root).unwrap(), None, "/Users/me").unwrap()
}

fn snapshot() -> Snapshot {
    snapshot_with(|_| {})
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|item| item.to_string()).collect()
}

fn source(created_at: f64) -> Source {
    Source {
        path: "/s/session-com.cmuxterm.app.json".into(),
        bundle_id: "com.cmuxterm.app".into(),
        size: 10,
        modified_at: created_at,
        created_at: Some(created_at),
    }
}

/// A ledger as a finished run leaves it: every planned workspace done.
fn finished(plan: &Plan, groups: &[(&str, &str)]) -> Ledger {
    let mut ledger = Ledger::new(State::Completed);
    ledger.source = Some(source(1.0));
    ledger.groups = groups.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
    for (index, workspace) in plan.workspaces().enumerate() {
        ledger.workspaces.insert(
            workspace.key.clone(),
            Entry::new(Stage::Done, Some(&format!("next-{index}")), None),
        );
    }
    for key in plan.cloud_vm_keys() {
        ledger.workspaces.insert(key, Entry::new(Stage::Skipped, None, Some("cloud-vm")));
    }
    ledger
}

fn keys(plan: &Plan) -> Vec<&str> {
    plan.workspaces().map(|workspace| workspace.key.as_str()).collect()
}

fn first_plan() -> Plan {
    plan::plan(&snapshot(), None, &set(&[]), &set(&[]), Mode::Automatic)
}

#[test]
fn windows_groups_colors_and_pins_are_read() {
    let snapshot = snapshot();
    assert_eq!(snapshot.windows.len(), 2);
    let first = &snapshot.windows[0];
    let first_keys: Vec<&str> =
        first.workspaces.iter().map(|workspace| workspace.key.as_str()).collect();
    assert_eq!(first_keys, [HOME, SPLIT, PINNED]);
    assert_eq!(first.selected_workspace, Some(1));
    assert_eq!(
        first.groups,
        [
            Group {
                id: BACKEND.into(),
                name: "Backend".into(),
                collapsed: true,
                pinned: false,
                color: Some("#4ECDC4".into()),
                icon: Some("server.rack".into()),
            },
            Group {
                id: SAVED.into(),
                name: "Saved".into(),
                collapsed: false,
                pinned: true,
                color: None,
                icon: None
            },
        ]
    );
    let split = &first.workspaces[1];
    assert_eq!(split.group_id.as_deref(), Some(BACKEND));
    assert_eq!(split.color.as_deref(), Some("#FF6B6B"));
    assert!(!split.pinned);
    assert!(first.workspaces[2].pinned && first.workspaces[2].group_id.as_deref() == Some(BACKEND));
    assert_eq!(
        snapshot.windows[1].frame,
        Some(Rect { x: 420.0, y: 260.0, width: 1100.0, height: 700.0 })
    );
    assert_eq!(snapshot.windows[1].workspaces[1].cloud_vm.as_deref(), Some("vm-1"));
}

/// Names stay unique across windows.
#[test]
fn names_are_unique_across_windows() {
    let names: Vec<String> =
        snapshot().workspaces().map(|workspace| workspace.name.clone()).collect();
    assert_eq!(names.iter().collect::<BTreeSet<_>>().len(), names.len(), "{names:?}");
}

/// A snapshot without `stableId` keys on `workspaceId`; one with neither on
/// a digest that is the same on every read.
#[test]
fn keys_fall_back_to_workspace_id_then_a_digest() {
    let strip = |fields: &'static [&'static str]| {
        move |root: &mut Value| {
            for workspace in root["windows"][0]["tabManager"]["workspaces"].as_array_mut().unwrap()
            {
                for field in fields {
                    workspace.as_object_mut().unwrap().remove(*field);
                }
            }
        }
    };
    let by_workspace_id = snapshot_with(strip(&["stableId"]));
    assert_eq!(
        by_workspace_id.windows[0].workspaces[0].key,
        "BBBBBBBB-0000-4000-8000-000000000001"
    );
    let derived: Vec<String> = snapshot_with(strip(&["stableId", "workspaceId"])).windows[0]
        .workspaces
        .iter()
        .map(|w| w.key.clone())
        .collect();
    assert!(derived.iter().all(|key| key.starts_with("derived:")), "{derived:?}");
    assert_eq!(derived.iter().collect::<BTreeSet<_>>().len(), 3);
    let again: Vec<String> = snapshot_with(strip(&["stableId", "workspaceId"])).windows[0]
        .workspaces
        .iter()
        .map(|w| w.key.clone())
        .collect();
    assert_eq!(again, derived);
}

/// A damaged file (JSON that is not a session object) is an error, never an empty session.
#[test]
fn a_file_that_is_not_a_session_is_an_error() {
    assert_eq!(decode::decode(b"[1,2]", None, "/h"), Err(decode::Error::NotASnapshot));
    assert!(matches!(decode::decode(b"{not json", None, "/h"), Err(decode::Error::Json(_))));
}

#[test]
fn the_first_run_brings_every_window_in_order_with_its_groups() {
    let plan = first_plan();
    let windows: Vec<Vec<&str>> = plan
        .windows
        .iter()
        .map(|window| window.workspaces.iter().map(|w| w.key.as_str()).collect())
        .collect();
    assert_eq!(windows, [vec![HOME, SPLIT, PINNED], vec![SECOND]]);
    assert_eq!(plan.windows[0].selected_key.as_deref(), Some(SPLIT));
    // Window 2 had "second window" selected (index 2), which comes over.
    assert_eq!(plan.windows[1].selected_key.as_deref(), Some(SECOND));
    assert_eq!(
        plan.windows[1].frame,
        Some(Rect { x: 420.0, y: 260.0, width: 1100.0, height: 700.0 })
    );
    let groups: Vec<&str> = plan.groups.iter().map(|group| group.classic.id.as_str()).collect();
    assert_eq!(groups, [BACKEND, SAVED]);
    assert!(plan.groups.iter().all(|group| group.existing.is_none()));
    assert_eq!(
        plan.skipped,
        [(SPLIT.to_string(), Skip::Duplicate), (CLOUD.to_string(), Skip::CloudVm)].into()
    );
    assert!(plan.cleanup.is_empty());
}

#[test]
fn a_finished_run_makes_nothing_again() {
    let snapshot = snapshot();
    let ledger = finished(&first_plan(), &[(BACKEND, "grp_1"), (SAVED, "grp_2")]);
    let again = plan::plan(
        &snapshot,
        Some(&ledger),
        &set(&["next-0", "next-1", "next-2", "next-3"]),
        &set(&["grp_1", "grp_2"]),
        Mode::Automatic,
    );
    assert!(again.is_empty(), "{again:?}");
    // Even when the person closed them all here, an automatic run brings none back.
    let closed = plan::plan(&snapshot, Some(&ledger), &set(&[]), &set(&[]), Mode::Automatic);
    assert!(closed.workspaces().next().is_none() && closed.groups.is_empty(), "{closed:?}");
}

/// Import Workspaces from Classic cmux brings back only what was closed here.
#[test]
fn a_manual_run_reopens_only_what_was_closed_here() {
    let snapshot = snapshot();
    let ledger = finished(&first_plan(), &[(BACKEND, "grp_1"), (SAVED, "grp_2")]);
    let plan = plan::plan(
        &snapshot,
        Some(&ledger),
        &set(&["next-0", "next-2", "next-3"]),
        &set(&["grp_1"]),
        Mode::Manual,
    );
    assert_eq!(keys(&plan), [SPLIT]);
    assert_eq!(
        plan.groups,
        [PlanGroup {
            classic: snapshot.windows[0].groups[0].clone(),
            existing: Some("grp_1".into())
        }]
    );
    assert_eq!(plan.skipped[HOME], Skip::AlreadyMigrated);
    assert_eq!(plan.skipped[CLOUD], Skip::CloudVm);
}

/// Classic made a workspace in the Backend group while downgraded: only it
/// comes over, into the group the first run made; changes classic made to
/// workspaces that already came over are not merged.
#[test]
fn a_re_upgrade_merges_only_new_workspaces_into_the_same_group() {
    let ledger = finished(&first_plan(), &[(BACKEND, "grp_1"), (SAVED, "grp_2")]);
    let later = snapshot_with(|root| {
        root["createdAt"] = 1_891_728_605.0.into();
        let workspaces = root["windows"][0]["tabManager"]["workspaces"].as_array_mut().unwrap();
        let mut added = workspaces[0].clone();
        added["stableId"] = "AAAAAAAA-0000-4000-8000-000000000099".into();
        added["customTitle"] = "made while downgraded".into();
        added["groupId"] = BACKEND.into();
        workspaces[1]["customTitle"] = "renamed in classic".into();
        workspaces.push(added);
    });
    assert_eq!(
        plan::decision(&Load::Ledger(ledger.clone()), Some(&source(2.0)), false),
        Decision::Merge
    );
    let plan = plan::plan(
        &later,
        Some(&ledger),
        &set(&["next-0", "next-1", "next-2", "next-3"]),
        &set(&["grp_1", "grp_2"]),
        Mode::Automatic,
    );
    assert_eq!(keys(&plan), ["AAAAAAAA-0000-4000-8000-000000000099"]);
    let existing: Vec<Option<&str>> =
        plan.groups.iter().map(|group| group.existing.as_deref()).collect();
    assert_eq!(existing, [Some("grp_1")]);
}

/// The person deleted the group here: a merged member gets a new group.
#[test]
fn a_group_deleted_here_is_made_again_for_new_members() {
    let mut ledger = Ledger::new(State::Completed);
    ledger.source = Some(source(1.0));
    ledger.groups.insert(BACKEND.into(), "grp_gone".into());
    ledger.workspaces.insert(HOME.into(), Entry::new(Stage::Done, Some("next-0"), None));
    let plan =
        plan::plan(&snapshot(), Some(&ledger), &set(&["next-0"]), &set(&[]), Mode::Automatic);
    let backend = plan.groups.iter().find(|group| group.classic.id == BACKEND).unwrap();
    assert_eq!(backend.existing, None);
}

/// The app quit while a workspace was half made: it is closed and made
/// again; one not yet started is made; finished ones are left alone.
#[test]
fn a_cut_off_run_resumes_without_duplicates() {
    let mut ledger = Ledger::new(State::InProgress);
    ledger.source = Some(source(1.0));
    ledger.workspaces.insert(HOME.into(), Entry::new(Stage::Done, Some("next-0"), None));
    ledger.workspaces.insert(SPLIT.into(), Entry::new(Stage::Created, Some("next-half"), None));
    ledger.workspaces.insert(PINNED.into(), Entry::new(Stage::Pending, None, None));
    assert_eq!(
        plan::decision(&Load::Ledger(ledger.clone()), Some(&source(1.0)), true),
        Decision::Resume
    );
    let plan = plan::plan(
        &snapshot(),
        Some(&ledger),
        &set(&["next-0", "next-half"]),
        &set(&[]),
        Mode::Automatic,
    );
    assert_eq!(plan.cleanup, ["next-half"]);
    assert_eq!(keys(&plan), [SPLIT, PINNED, SECOND]);
    assert_eq!(plan.skipped[HOME], Skip::AlreadyMigrated);
}

#[test]
fn whether_a_launch_runs() {
    let cases = [
        (Load::None, true, false, Decision::FirstRun),
        (Load::None, false, false, Decision::Skip(SkipReason::NoClassicSession)),
        (Load::None, true, true, Decision::Skip(SkipReason::ClassicRunning)),
        (Load::Newer(99), true, false, Decision::Skip(SkipReason::LedgerNotUsable)),
        (Load::Unreadable, true, false, Decision::Skip(SkipReason::LedgerNotUsable)),
        (Load::Failed("denied".into()), true, false, Decision::Skip(SkipReason::LedgerNotUsable)),
    ];
    for (load, has_source, running, expected) in cases {
        let found = source(1.0);
        assert_eq!(
            plan::decision(&load, has_source.then_some(&found), running),
            expected,
            "{load:?}"
        );
    }
}

#[test]
fn the_same_classic_save_runs_once() {
    let mut ledger = Ledger::new(State::Completed);
    ledger.source = Some(source(1.0));
    let load = Load::Ledger(ledger);
    assert_eq!(
        plan::decision(&load, Some(&source(1.0)), false),
        Decision::Skip(SkipReason::Unchanged)
    );
    // The `-previous` copy of the same save is the same save.
    let previous = Source {
        path: "/s/session-com.cmuxterm.app-previous.json".into(),
        bundle_id: "com.cmuxterm.app".into(),
        size: 99,
        modified_at: 5.0,
        created_at: Some(1.0),
    };
    assert_eq!(
        plan::decision(&load, Some(&previous), false),
        Decision::Skip(SkipReason::Unchanged)
    );
    // Classic saved again while still running: wait until it quits.
    assert_eq!(
        plan::decision(&load, Some(&source(2.0)), true),
        Decision::Skip(SkipReason::ClassicRunning)
    );
}

/// The tree already had workspaces: classic's workspaces are only recorded.
/// No automatic run makes them; the action still can.
#[test]
fn a_baseline_records_without_making() {
    let snapshot = snapshot();
    let ledger = plan::baseline(&snapshot, Ledger::default());
    assert_eq!(ledger.state, State::Completed);
    assert_eq!(ledger.workspaces[CLOUD], Entry::new(Stage::Skipped, None, Some("cloud-vm")));
    let automatic = plan::plan(&snapshot, Some(&ledger), &set(&[]), &set(&[]), Mode::Automatic);
    assert!(automatic.workspaces().next().is_none());
    let manual = plan::plan(&snapshot, Some(&ledger), &set(&[]), &set(&[]), Mode::Manual);
    assert_eq!(keys(&manual), [HOME, SPLIT, PINNED, SECOND]);
}

#[test]
fn the_preview_counts_what_comes_over_and_what_is_replaced() {
    let mut ledger = Ledger::new(State::InProgress);
    ledger.workspaces.insert(SPLIT.into(), Entry::new(Stage::Created, Some("next-half"), None));
    let plan =
        plan::plan(&snapshot(), Some(&ledger), &set(&["next-half"]), &set(&[]), Mode::Automatic);
    let preview = plan::Preview::new(&source(1.0), &plan);
    assert_eq!(preview.channel, plan::Channel::Stable);
    assert_eq!(preview.workspaces, 4);
    assert_eq!(preview.skipped_cloud_vms, 1);
    assert_eq!(preview.cleanup_workspaces, 1);
}

/// What the app receives: snake_case fields, a tagged split tree, and the
/// decision with its reason.
#[test]
fn the_wire_shape_is_snake_case() {
    let plan = first_plan();
    let value = serde_json::to_value(&plan).unwrap();
    let workspace = &value["windows"][0]["workspaces"][1];
    assert_eq!(workspace["group_id"], BACKEND);
    assert!(
        workspace["layout"].get("split").is_some() || workspace["layout"].get("pane").is_some()
    );
    assert_eq!(value["skipped"][CLOUD], "cloud_vm");
    assert_eq!(
        serde_json::to_value(Decision::Skip(SkipReason::InUseBefore)).unwrap(),
        serde_json::json!({"decision": "skip", "reason": "in_use_before"})
    );
    assert_eq!(
        serde_json::to_value(Decision::FirstRun).unwrap(),
        serde_json::json!({"decision": "first_run"})
    );
}
