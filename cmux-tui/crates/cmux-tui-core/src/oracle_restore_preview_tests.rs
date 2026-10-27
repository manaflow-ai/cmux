//! `oracle-restore-preview` and invariant I9 at the daemon (p15-oracle task
//! 205): the journal checkpoint reduced through the journal head equals the
//! live `session.snapshot` on the section map's compared sections, after a
//! fixed script and after every step of seeded op walks; the preview reads
//! the journal without the registry lock; every snapshot section is mapped.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use super::{OracleRestorePreview, RESTORE_SECTIONS, RestoreSection, oracle_restore_preview};
use crate::mux::ProviderWorkspaceState;
use crate::workspace_registry::WorkspaceRegistry;
use crate::{Mux, SplitDir, SurfaceOptions, ZoomMode};

/// Walks of [`i9_holds_after_every_step_of_seeded_walks`]; the oracle's VM
/// run sets `CMUX_TUI_TEST_I9_WALKS=10000`.
const DEFAULT_WALKS: usize = 32;
const WALK_STEPS: usize = 24;

/// A persistent session with test terminals, in its own state root.
struct Session {
    mux: Option<Arc<Mux>>,
    root: std::path::PathBuf,
}

impl Session {
    fn open(name: &str) -> Self {
        let mut bytes = [0u8; 8];
        getrandom::fill(&mut bytes).expect("random");
        let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let root = std::env::temp_dir().join(format!("cmux-oracle-i9-{suffix}"));
        let registry = WorkspaceRegistry::open(&root, name).expect("registry");
        let mux = Mux::from_workspace_registry(
            name.to_owned(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .expect("persistent mux");
        Self { mux: Some(mux), root }
    }

    fn mux(&self) -> &Arc<Mux> {
        self.mux.as_ref().expect("open")
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        drop(self.mux.take());
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// The live snapshot, its journal head and the preview of the latest
/// checkpoint through that head: one cut, as the oracle driver reads it
/// (`oracle-state`, then `oracle-restore-preview through`).
fn cut(mux: &Mux) -> (Value, u64, OracleRestorePreview) {
    let (live, head) =
        crate::resource_api::public_session_snapshot_with_journal_head(mux).expect("snapshot");
    (live, head, oracle_restore_preview(mux, "latest", Some(head)).expect("preview"))
}

/// The I9 difference of a preview that dropped `extra.state` changes.
const STATE_CHANGES_NOT_REDUCED: &str = "extra: state changes not reduced";

/// I9's differences, as invariants.py reports them: a compared section the
/// preview lacks, a value that differs, or an id on one side only. Arrays
/// of objects with an `id` compare by id: the reducer orders a collection
/// by `index` then id, the live snapshot by topology, and each item's
/// `index` and parent ids already hold its place. A preview that dropped
/// state changes reports [`STATE_CHANGES_NOT_REDUCED`] instead of comparing
/// `extra`, which it knows is the checkpoint's.
fn i9_differences(live: &Value, head: u64, reply: &OracleRestorePreview) -> Vec<String> {
    let Some(preview) = &reply.preview else { return vec!["no preview".into()] };
    let mut out = Vec::new();
    if preview.head_sequence != head {
        out.push(format!("preview at {}, live at {head}", preview.head_sequence));
    }
    if preview.unsupported_count > 0 {
        out.push(format!("unsupported required records: {:?}", preview.unsupported));
    }
    if preview.state_changes_not_reduced > 0 {
        out.push(STATE_CHANGES_NOT_REDUCED.into());
    }
    for (name, section) in &reply.sections {
        if *section != RestoreSection::Compared
            || (*name == "extra" && preview.state_changes_not_reduced > 0)
        {
            continue;
        }
        let Some(restored) = preview.session.get(name) else {
            out.push(format!("{name}: missing from the preview"));
            continue;
        };
        match (by_id(&live[*name]), by_id(restored)) {
            (Some(live), Some(restored)) if live != restored => {
                for id in
                    live.keys().chain(restored.keys()).collect::<std::collections::BTreeSet<_>>()
                {
                    if live.get(id) != restored.get(id) {
                        out.push(format!(
                            "{name}/{id}{}",
                            first_difference(live.get(id).copied(), restored.get(id).copied())
                        ));
                    }
                }
            }
            (Some(_), Some(_)) => {}
            _ if live[*name] != *restored => {
                out.push(format!("{name}: live {}, restored {restored}", live[*name]));
            }
            _ => {}
        }
    }
    out
}

/// Where `live` and `restored` first differ: `/pointer: live L, restored R`.
fn first_difference(live: Option<&Value>, restored: Option<&Value>) -> String {
    match (live, restored) {
        (Some(Value::Object(a)), Some(Value::Object(b))) => {
            let keys: std::collections::BTreeSet<_> = a.keys().chain(b.keys()).collect();
            keys.into_iter()
                .find(|key| a.get(*key) != b.get(*key))
                .map(|key| format!("/{key}{}", first_difference(a.get(key), b.get(key))))
                .unwrap_or_default()
        }
        (live, restored) => format!(
            ": live {}, restored {}",
            live.map_or("absent".into(), Value::to_string),
            restored.map_or("absent".into(), Value::to_string)
        ),
    }
}

fn by_id(value: &Value) -> Option<BTreeMap<&str, &Value>> {
    value.as_array()?.iter().map(|item| Some((item["id"].as_str()?, item))).collect()
}

#[test]
fn the_section_map_covers_every_session_snapshot_key() {
    let session = Session::open("i9-sections");
    let (live, _, _) = cut(session.mux());
    let keys: Vec<&str> = live.as_object().expect("object").keys().map(String::as_str).collect();
    let mut mapped: Vec<&str> = RESTORE_SECTIONS.iter().map(|(name, _)| *name).collect();
    mapped.sort_unstable();
    let mut keys_sorted = keys.clone();
    keys_sorted.sort_unstable();
    assert_eq!(mapped, keys_sorted, "every session.snapshot key is in RESTORE_SECTIONS");
    for (name, section) in RESTORE_SECTIONS {
        if let RestoreSection::Excluded { reason } = section {
            assert!(reason.len() > 20, "{name}: an excluded section needs its reason");
        }
    }
}

#[test]
fn a_session_without_a_checkpoint_has_no_preview_and_memory_has_no_reader() {
    let session = Session::open("i9-no-checkpoint");
    let reply = oracle_restore_preview(session.mux(), "latest", None).unwrap();
    assert!(reply.preview.is_none());
    assert_eq!(reply.sections.len(), RESTORE_SECTIONS.len());

    let memory = Mux::new_for_test("i9-memory", SurfaceOptions::default());
    let error = oracle_restore_preview(&memory, "latest", None).unwrap_err();
    assert!(error.to_string().contains("persistent session"), "{error}");
}

#[test]
fn the_preview_after_a_fixed_script_equals_the_live_session() {
    let session = Session::open("i9-script");
    let mux = session.mux();
    let first = mux.new_workspace(Some("one".into()), Some((80, 24))).unwrap();
    mux.create_journal_checkpoint("oracle_test", "i9-script").unwrap();
    let (live, head, reply) = cut(mux);
    let preview = reply.preview.as_ref().expect("a checkpoint exists");
    assert_eq!(preview.state_changes_not_reduced, 0);
    assert!(preview.session.contains_key("extra"), "extra is compared");
    assert_eq!(i9_differences(&live, head, &reply), Vec::<String>::new());
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.split(pane, SplitDir::Right, None).unwrap();
    let second = mux.new_workspace(Some("two".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    mux.new_tab(Some(pane), None, None).unwrap();
    assert!(mux.rename_surface(right.id, "renamed".into()));
    mux.zoom_pane(Some(pane), ZoomMode::On).unwrap();
    let (live, head, reply) = cut(mux);
    let preview = reply.preview.as_ref().expect("a checkpoint exists");
    assert!(preview.head_sequence > preview.checkpoint_sequence, "records after the checkpoint");
    // The one difference is the tracked finding EXTRA_STATE_FINDING.
    assert_eq!(i9_differences(&live, head, &reply), vec![STATE_CHANGES_NOT_REDUCED.to_string()]);
    assert_eq!(preview.session["workspaces"].as_array().map(Vec::len), Some(2));
}

/// I9 finding: the restore reducer counts `state_upsert`/`state_delete`
/// changes but does not reduce them into `extra.state`, so a restore loses
/// them (`fully_reducible` is false; spec/session-journal.md). Most
/// topology ops carry such changes (sidebar items, placements, screen
/// groups). This test fails once the reducer reduces them: then remove
/// [`STATE_CHANGES_NOT_REDUCED`] from the walks' tracked findings.
const EXTRA_STATE_FINDING: &str = "state changes are counted, not reduced into extra.state";

#[test]
fn i9_extra_state_finding_still_diverges() {
    let session = Session::open("i9-extra-state");
    let mux = session.mux();
    mux.new_workspace(Some("one".into()), Some((80, 24))).unwrap();
    mux.create_journal_checkpoint("oracle_test", "i9-extra-state").unwrap();
    mux.new_workspace(Some("two".into()), Some((80, 24))).unwrap();
    let (live, head, reply) = cut(mux);
    let preview = reply.preview.as_ref().expect("a checkpoint exists");
    assert!(preview.state_changes_not_reduced > 0, "{EXTRA_STATE_FINDING}: fixed, so remove it");
    let preview_extra = &preview.session["extra"];
    assert_ne!(live["extra"], *preview_extra, "the restore keeps the checkpoint's extra.state");
    assert_eq!(i9_differences(&live, head, &reply), vec![STATE_CHANGES_NOT_REDUCED.to_string()]);
}

/// "No writer lock": the preview completes while this thread holds the
/// registry and its writer connection, which every journal write needs.
#[test]
fn the_preview_reads_the_journal_without_the_registry_lock() {
    let session = Session::open("i9-no-lock");
    let mux = session.mux().clone();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.create_journal_checkpoint("oracle_test", "i9-no-lock").unwrap();
    let registry = mux.workspace_registry.lock().unwrap();
    let writer = mux.registry_connection.get();
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = mux.clone();
    let thread = std::thread::spawn(move || {
        let reply =
            oracle_restore_preview(&reader, "latest", None).map(|reply| reply.preview.is_some());
        sender.send(reply.map_err(|error| error.to_string())).unwrap();
    });
    let reply = receiver.recv_timeout(Duration::from_secs(20));
    drop(writer);
    drop(registry);
    thread.join().unwrap();
    assert_eq!(reply, Ok(Ok(true)), "the preview waited on the registry lock");
}

/// A deterministic walk step source (no RNG dependency: a SplitMix64).
struct Steps(u64);

impl Steps {
    fn below(&mut self, bound: usize) -> usize {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        usize::try_from((z ^ (z >> 31)) % bound.max(1) as u64).unwrap_or(0)
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> Option<T> {
        (!items.is_empty()).then(|| items[self.below(items.len())])
    }
}

/// The walk ops: every topology op family the test terminal runtime runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    WorkspaceCreate,
    WorkspaceClose,
    WorkspaceRename,
    WorkspaceSelect,
    WorkspaceMove,
    ScreenCreate,
    ScreenClose,
    ScreenRename,
    PaneSplit,
    PaneClose,
    PaneFocus,
    PaneZoom,
    PaneSwap,
    PaneRename,
    TabCreate,
    TabClose,
    TabMove,
    TabRename,
    Checkpoint,
}

const ALL_OPS: [Op; 19] = [
    Op::WorkspaceCreate,
    Op::WorkspaceClose,
    Op::WorkspaceRename,
    Op::WorkspaceSelect,
    Op::WorkspaceMove,
    Op::ScreenCreate,
    Op::ScreenClose,
    Op::ScreenRename,
    Op::PaneSplit,
    Op::PaneClose,
    Op::PaneFocus,
    Op::PaneZoom,
    Op::PaneSwap,
    Op::PaneRename,
    Op::TabCreate,
    Op::TabClose,
    Op::TabMove,
    Op::TabRename,
    Op::Checkpoint,
];

/// Run one `op` on targets `steps` picks from the current state. Refusals
/// are fine: a refused op must change nothing, which I9 checks as well.
fn run(mux: &Arc<Mux>, steps: &mut Steps, op: Op, index: usize) {
    let (workspaces, panes, surfaces, screens) = mux.with_state(|state| {
        let mut panes: Vec<_> = state.panes.keys().copied().collect();
        panes.sort_unstable();
        let mut surfaces: Vec<_> = state.surfaces.keys().copied().collect();
        surfaces.sort_unstable();
        let workspaces: Vec<_> = state.workspaces.iter().map(|ws| ws.id).collect();
        let screens: Vec<_> =
            state.workspaces.iter().flat_map(|ws| ws.screens.iter().map(|s| s.id)).collect();
        (workspaces, panes, surfaces, screens)
    });
    let size = Some((80, 24));
    let name = format!("n{index}");
    match op {
        Op::WorkspaceCreate => drop(mux.new_workspace(Some(name), size)),
        Op::WorkspaceClose => {
            if workspaces.len() > 1
                && let Some(workspace) = steps.pick(&workspaces)
            {
                mux.close_workspace(workspace);
            }
        }
        Op::WorkspaceRename => {
            if let Some(workspace) = steps.pick(&workspaces) {
                mux.rename_workspace(workspace, name);
            }
        }
        Op::WorkspaceSelect => mux.select_workspace(Some(steps.below(workspaces.len())), None),
        Op::WorkspaceMove => {
            if let Some(workspace) = steps.pick(&workspaces) {
                mux.move_workspace(workspace, steps.below(workspaces.len()));
            }
        }
        Op::ScreenCreate => drop(mux.new_screen(steps.pick(&workspaces), size)),
        Op::ScreenClose => {
            if let Some(screen) = steps.pick(&screens) {
                drop(mux.close_screen(screen));
            }
        }
        Op::ScreenRename => {
            if let Some(screen) = steps.pick(&screens) {
                mux.rename_screen(screen, name);
            }
        }
        Op::PaneSplit => {
            if let Some(pane) = steps.pick(&panes) {
                let dir = if steps.below(2) == 0 { SplitDir::Right } else { SplitDir::Down };
                drop(mux.split(pane, dir, size));
            }
        }
        Op::PaneClose => {
            if let Some(pane) = steps.pick(&panes) {
                drop(mux.close_pane(pane));
            }
        }
        Op::PaneFocus => {
            if let Some(pane) = steps.pick(&panes) {
                mux.focus_pane(pane);
            }
        }
        Op::PaneZoom => drop(mux.zoom_pane(steps.pick(&panes), ZoomMode::Toggle)),
        Op::PaneSwap => {
            if let (Some(pane), Some(target)) = (steps.pick(&panes), steps.pick(&panes)) {
                mux.swap_panes(pane, target);
            }
        }
        Op::PaneRename => {
            if let Some(pane) = steps.pick(&panes) {
                mux.rename_pane(pane, name);
            }
        }
        Op::TabCreate => drop(mux.new_tab(steps.pick(&panes), None, size)),
        Op::TabClose => {
            if let Some(surface) = steps.pick(&surfaces) {
                drop(mux.close_surface(surface));
            }
        }
        Op::TabMove => {
            if let Some(surface) = steps.pick(&surfaces)
                && let Some(pane) = mux.with_state(|state| state.pane_of(surface))
            {
                mux.move_tab(surface, pane, steps.below(4));
            }
        }
        Op::TabRename => {
            if let Some(surface) = steps.pick(&surfaces) {
                mux.rename_surface(surface, name);
            }
        }
        Op::Checkpoint => drop(mux.create_journal_checkpoint("oracle_test", &name)),
    }
}

/// One seeded walk of `WALK_STEPS` ops from `ops`, I9 checked after each,
/// except for the tracked finding [`EXTRA_STATE_FINDING`]: `extra` is
/// compared at every cut with no state change since the checkpoint. The
/// count of those cuts.
fn walk(seed: u64, ops: &[Op]) -> Result<usize, String> {
    let session = Session::open(&format!("i9-walk-{seed}"));
    let mux = session.mux();
    let mut steps = Steps(seed);
    mux.new_workspace(Some("start".into()), Some((80, 24))).map_err(|e| e.to_string())?;
    mux.create_journal_checkpoint("oracle_test", "walk-start").map_err(|e| e.to_string())?;
    let mut done = Vec::with_capacity(WALK_STEPS);
    let mut extra_compared = 0;
    for index in 0..WALK_STEPS {
        let op = steps.pick(ops).expect("ops");
        run(mux, &mut steps, op, index);
        done.push(op);
        let (live, head, reply) = cut(mux);
        let mut differences = i9_differences(&live, head, &reply);
        let before = differences.len();
        differences.retain(|difference| difference != STATE_CHANGES_NOT_REDUCED);
        extra_compared += usize::from(before == differences.len());
        if !differences.is_empty() {
            return Err(format!("seed {seed}, after {done:?}: {differences:#?}"));
        }
    }
    Ok(extra_compared)
}

/// A `usize` test knob, or `default` when it is unset or not a number.
fn knob(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

/// Run `CMUX_TUI_TEST_I9_WALKS` (default [`DEFAULT_WALKS`]) walks over
/// `ops` on up to 32 threads, seeds from `CMUX_TUI_TEST_I9_FIRST_SEED`
/// (default 0, so a long run can be split into seed ranges); panics with
/// the first failures. Returns the cuts that compared `extra`.
fn assert_walks_hold(ops: &[Op]) -> usize {
    let walks = knob("CMUX_TUI_TEST_I9_WALKS", DEFAULT_WALKS);
    let first = knob("CMUX_TUI_TEST_I9_FIRST_SEED", 0);
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(32);
    let results: Vec<Result<usize, String>> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|worker| {
                scope.spawn(move || {
                    (first + worker..first + walks)
                        .step_by(threads)
                        .map(|seed| walk(seed as u64, ops))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        workers.into_iter().flat_map(|worker| worker.join().unwrap()).collect()
    });
    let failures: Vec<&String> =
        results.iter().filter_map(|result| result.as_ref().err()).collect();
    assert!(failures.is_empty(), "{} of {walks} walks broke I9:\n{}", failures.len(), {
        failures.iter().take(3).map(|failure| failure.as_str()).collect::<Vec<_>>().join("\n")
    });
    results.iter().filter_map(|result| result.as_ref().ok()).sum()
}

/// Ops whose journal records I9 finds do not restore the live session, with
/// what differs. Each is a daemon defect to fix, not a rule:
/// [`i9_findings_still_diverge`] fails once one is fixed, so its entry
/// leaves this list and the walks cover the op.
const I9_FINDINGS: [(Op, &str); 3] = [
    (
        Op::WorkspaceClose,
        "the close's record deletes the workspace's terminals that stay live and \
         detached, and does not move focus to the next workspace's screen and pane",
    ),
    (Op::PaneZoom, "an unzoom upserts the screen but not the pane: `zoomed` stays true"),
    (
        Op::TabMove,
        "a move within a pane does not upsert the screen (layout tab_ids keep the old \
         order) and gives a tab it shifted the wrong index",
    ),
];

/// The base ops every finding walk adds its op to.
const BASE_OPS: [Op; 3] = [Op::WorkspaceCreate, Op::PaneSplit, Op::TabCreate];

fn finding(op: Op) -> bool {
    I9_FINDINGS.iter().any(|(finding, _)| *finding == op)
}

/// `I9_ONLY=PaneZoom,TabCreate` walks only those ops (probing one op).
#[test]
fn i9_holds_after_every_step_of_seeded_walks() {
    let only = std::env::var("I9_ONLY").ok();
    let ops: Vec<Op> = ALL_OPS
        .into_iter()
        .filter(|op| match &only {
            Some(only) => only.split(',').any(|name| format!("{op:?}") == name),
            None => !finding(*op),
        })
        .collect();
    let extra_compared = assert_walks_hold(&ops);
    if only.is_none() {
        assert!(extra_compared > 0, "no cut compared extra: the walks no longer cover it");
    }
}

#[test]
fn i9_findings_still_diverge() {
    for (op, what) in I9_FINDINGS {
        let ops = [BASE_OPS.as_slice(), &[op]].concat();
        let broke = (0..64).any(|seed| walk(seed, &ops).is_err());
        assert!(broke, "{op:?} no longer breaks I9 ({what}): remove it from I9_FINDINGS");
    }
}
