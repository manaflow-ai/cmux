//! The shared model-level matrix (Packages/macOS/CmuxNext/Tests/Matrix/cases.json,
//! cx-gkyi1) on the real core: every case of the "headless" tier seeds its
//! preset, runs its `core` steps through the mux topology operations the
//! daemon serves, checks the daemon's own layout transition rules after each
//! step and then the case's expectations. The same file drives the app's
//! entry checks (ModelMatrixTests) and the real-HID runner. Every failure
//! starts with "MATRIX <case id>:".

use super::*;
use serde_json::Value;
use std::path::Path;

const SIZE: Option<(u16, u16)> = Some((80, 24));
const CONSERVING_OPS: [&str; 6] = [
    "move_tab",
    "move_tab_to_workspace",
    "move_tab_to_new_workspace",
    "move_pane_to_new_workspace",
    "move_tab_to_split",
    "zoom_pane",
];

/// The case file, or `None` in a cmux-tui tree without the app beside it
/// (a published tree): the matrix belongs to the monorepo.
fn case_file() -> Option<Value> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    if !root.join("Packages/macOS/CmuxNext").is_dir() {
        return None;
    }
    let path = root.join("Packages/macOS/CmuxNext/Tests/Matrix/cases.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("MATRIX: {}: {error}", path.display()));
    Some(serde_json::from_str(&text).expect("MATRIX: cases.json is not JSON"))
}

#[derive(Clone, Copy)]
enum Object {
    Workspace(WorkspaceId),
    Pane(PaneId),
    Tab(SurfaceId),
}

/// What the expectations read: order, selection, focus and zoom.
struct Snapshot {
    workspaces: Vec<WorkspaceId>,
    active_workspace: Option<WorkspaceId>,
    panes_of: HashMap<WorkspaceId, Vec<PaneId>>,
    tabs_of: HashMap<PaneId, Vec<SurfaceId>>,
    selected_tab: HashMap<PaneId, Option<SurfaceId>>,
    focused_pane: Option<PaneId>,
    zoomed_pane: Option<PaneId>,
}

impl Snapshot {
    fn of(mux: &Arc<Mux>) -> Self {
        mux.with_state(|state| {
            let mut panes_of = HashMap::new();
            let mut tabs_of = HashMap::new();
            let mut selected_tab = HashMap::new();
            for workspace in &state.workspaces {
                let mut panes = Vec::new();
                for screen in &workspace.screens {
                    panes.extend(screen.root.pane_ids_vec());
                }
                for pane in &panes {
                    if let Some(model) = state.panes.get(pane) {
                        tabs_of.insert(*pane, model.tabs.clone());
                        selected_tab.insert(*pane, model.active_surface());
                    }
                }
                panes_of.insert(workspace.id, panes);
            }
            let active = state.workspaces.get(state.active_workspace);
            let screen = active.and_then(|workspace| workspace.active_screen_ref());
            Snapshot {
                workspaces: state.workspaces.iter().map(|workspace| workspace.id).collect(),
                active_workspace: active.map(|workspace| workspace.id),
                panes_of,
                tabs_of,
                selected_tab,
                focused_pane: screen.map(|screen| screen.active_pane),
                zoomed_pane: screen.and_then(|screen| screen.zoomed_pane),
            }
        })
    }

    fn panes(&self) -> Vec<PaneId> {
        self.panes_of.values().flatten().copied().collect()
    }

    fn tabs(&self) -> Vec<SurfaceId> {
        self.tabs_of.values().flatten().copied().collect()
    }
}

/// A seeded preset and the objects its `$` names refer to.
struct Seed {
    mux: Arc<Mux>,
    objects: HashMap<String, Object>,
}

impl Seed {
    fn new(preset: &str) -> Self {
        let mux = test_mux();
        let mut objects = HashMap::new();
        match preset {
            "single" | "tabs3" | "split2" | "deep" => {
                let t1 = mux.new_workspace(None, SIZE).unwrap();
                let (w1, p1) =
                    mux.with_state(|state| (state.workspaces[0].id, state.pane_of(t1.id).unwrap()));
                objects.insert("$w1".into(), Object::Workspace(w1));
                objects.insert("$p1".into(), Object::Pane(p1));
                objects.insert("$t1".into(), Object::Tab(t1.id));
                match preset {
                    "tabs3" => {
                        let t2 = mux.new_tab(Some(p1), None, SIZE).unwrap();
                        let t3 = mux.new_tab(Some(p1), None, SIZE).unwrap();
                        objects.insert("$t2".into(), Object::Tab(t2.id));
                        objects.insert("$t3".into(), Object::Tab(t3.id));
                        mux.select_tab(Some(p1), Some(1), None);
                    }
                    "split2" => {
                        let t3 = mux.new_tab(Some(p1), None, SIZE).unwrap();
                        let t2 = mux.split(p1, SplitDir::Right, SIZE).unwrap();
                        let p2 = mux.with_state(|state| state.pane_of(t2.id).unwrap());
                        objects.insert("$p2".into(), Object::Pane(p2));
                        objects.insert("$t2".into(), Object::Tab(t2.id));
                        objects.insert("$t3".into(), Object::Tab(t3.id));
                        mux.select_tab(Some(p1), Some(0), None);
                        assert!(mux.focus_pane(p1));
                    }
                    "deep" => {
                        let mut last = p1;
                        for name in ["$p2", "$p3", "$p4"] {
                            let tab = mux.split(last, SplitDir::Right, SIZE).unwrap();
                            last = mux.with_state(|state| state.pane_of(tab.id).unwrap());
                            objects.insert(name.into(), Object::Pane(last));
                        }
                        assert!(mux.focus_pane(last));
                    }
                    _ => {}
                }
            }
            "ws3" | "ws20" => {
                let count = if preset == "ws3" { 3 } else { 20 };
                for index in 1..=count {
                    let tab = mux.new_workspace(None, SIZE).unwrap();
                    let (workspace, pane) = mux.with_state(|state| {
                        (state.workspaces[index - 1].id, state.pane_of(tab.id).unwrap())
                    });
                    objects.insert(format!("$w{index}"), Object::Workspace(workspace));
                    if preset == "ws3" && index == 2 {
                        objects.insert("$p1".into(), Object::Pane(pane));
                        objects.insert("$t1".into(), Object::Tab(tab.id));
                    }
                }
                mux.select_workspace(Some(if preset == "ws3" { 1 } else { 0 }), None);
            }
            other => panic!("MATRIX: preset {other} has no core seed"),
        }
        Seed { mux, objects }
    }

    fn workspace(&self, value: &Value) -> Result<WorkspaceId, String> {
        match self.object(value)? {
            Object::Workspace(id) => Ok(id),
            _ => Err(format!("{value} is no workspace")),
        }
    }

    fn pane(&self, value: &Value) -> Result<PaneId, String> {
        match self.object(value)? {
            Object::Pane(id) => Ok(id),
            _ => Err(format!("{value} is no pane")),
        }
    }

    fn tab(&self, value: &Value) -> Result<SurfaceId, String> {
        match self.object(value)? {
            Object::Tab(id) => Ok(id),
            _ => Err(format!("{value} is no tab")),
        }
    }

    fn object(&self, value: &Value) -> Result<Object, String> {
        let name = value.as_str().ok_or_else(|| format!("{value} is no object name"))?;
        self.objects.get(name).copied().ok_or_else(|| format!("{name} is not seeded"))
    }
}

/// Runs one core step. Errors name what failed.
fn apply(seed: &Seed, step: &Value) -> Result<(), String> {
    let mux = &seed.mux;
    let op = step["op"].as_str().unwrap_or("");
    let failed = |what: &str| format!("{op}: {what}");
    match op {
        "new_workspace" => {
            // Placement in the sidebar is the app's personal order, not the core's.
            for _ in 0..step["repeat"].as_u64().unwrap_or(1) {
                mux.new_workspace(None, SIZE).map_err(|error| failed(&error.to_string()))?;
            }
            Ok(())
        }
        "move_workspace" => {
            let workspace = seed.workspace(&step["workspace"])?;
            let index = step["index"].as_u64().ok_or_else(|| failed("no index"))? as usize;
            mux.move_workspace(workspace, index);
            Ok(())
        }
        "move_tab" => {
            let tab = seed.tab(&step["tab"])?;
            let pane = seed.pane(&step["pane"])?;
            // `index` is the tab's final index, as the app sends it; the core
            // takes an insertion index in the pre-move list (TabMoveIndex.wireIndex).
            let (current, len) = mux.with_state(|state| {
                let tabs =
                    state.panes.get(&pane).map(|model| model.tabs.clone()).unwrap_or_default();
                (tabs.iter().position(|candidate| *candidate == tab), tabs.len())
            });
            let index = match (step["index"].as_u64(), current) {
                (None, _) => len,
                (Some(index), Some(current)) if index as usize > current => index as usize + 1,
                (Some(index), _) => index as usize,
            };
            mux.move_tab(tab, pane, index);
            Ok(())
        }
        "move_tab_to_workspace" => {
            let tab = seed.tab(&step["tab"])?;
            let workspace = seed.workspace(&step["workspace"])?;
            mux.move_tab_to_workspace(tab, Some(workspace))
                .map(|_| ())
                .map_err(|error| failed(&error.to_string()))
        }
        "move_tab_to_new_workspace" => {
            let tab = seed.tab(&step["tab"])?;
            mux.move_tab_to_new_workspace(tab, None, None, None)
                .map(|_| ())
                .map_err(|error| failed(&error.to_string()))
        }
        "move_pane_to_new_workspace" => {
            // The app moves a pane as its tabs: the first opens the workspace, the rest join it.
            let pane = seed.pane(&step["pane"])?;
            let tabs = mux.with_state(|state| {
                state.panes.get(&pane).map(|model| model.tabs.clone()).unwrap_or_default()
            });
            let (first, rest) = tabs.split_first().ok_or_else(|| failed("the pane has no tabs"))?;
            let known = Snapshot::of(mux).workspaces;
            mux.move_tab_to_new_workspace(*first, None, None, None)
                .map_err(|error| failed(&error.to_string()))?;
            let workspace = Snapshot::of(mux)
                .workspaces
                .into_iter()
                .find(|workspace| !known.contains(workspace))
                .ok_or_else(|| failed("no new workspace"))?;
            for tab in rest {
                mux.move_tab_to_workspace(*tab, Some(workspace))
                    .map_err(|error| failed(&error.to_string()))?;
            }
            Ok(())
        }
        "move_tab_to_split" => {
            let tab = seed.tab(&step["tab"])?;
            let pane = seed.pane(&step["pane"])?;
            let edge = match step["edge"].as_str() {
                Some("left") => TabDropEdge::Left,
                Some("right") => TabDropEdge::Right,
                Some("top") => TabDropEdge::Top,
                Some("bottom") => TabDropEdge::Bottom,
                other => return Err(failed(&format!("unknown edge {other:?}"))),
            };
            mux.move_tab_to_split(tab, pane, edge, None, None)
                .map(|_| ())
                .map_err(|error| failed(&error.to_string()))
        }
        "new_tab" => {
            let pane = seed.pane(&step["pane"])?;
            mux.new_tab(Some(pane), None, SIZE)
                .map(|_| ())
                .map_err(|error| failed(&error.to_string()))
        }
        "split" => {
            let pane = seed.pane(&step["pane"])?;
            let direction = match step["direction"].as_str() {
                Some("right") => SplitDir::Right,
                Some("down") => SplitDir::Down,
                other => return Err(failed(&format!("unknown direction {other:?}"))),
            };
            mux.split(pane, direction, SIZE).map(|_| ()).map_err(|error| failed(&error.to_string()))
        }
        "close_pane" => {
            let pane = seed.pane(&step["pane"])?;
            mux.close_pane(pane).map(|_| ()).map_err(|error| failed(&error.to_string()))
        }
        "zoom_pane" => {
            let pane = seed.pane(&step["pane"])?;
            let mode = match step["mode"].as_str() {
                Some("on") => ZoomMode::On,
                Some("off") => ZoomMode::Off,
                Some("toggle") => ZoomMode::Toggle,
                other => return Err(failed(&format!("unknown zoom mode {other:?}"))),
            };
            mux.zoom_pane(Some(pane), mode).map(|_| ()).map_err(|error| failed(&error.to_string()))
        }
        other => Err(format!("unknown core op {other}")),
    }
}

/// Resolves a `$` name, or `$new`: the newest object of `kind` the case created.
fn resolve(
    seed: &Seed,
    before: &Snapshot,
    after: &Snapshot,
    value: &Value,
    kind: &str,
) -> Result<Option<Object>, String> {
    if value.is_null() {
        return Ok(None);
    }
    if value.as_str() != Some("$new") {
        return seed.object(value).map(Some);
    }
    let created = match kind {
        "workspace" => after
            .workspaces
            .iter()
            .filter(|id| !before.workspaces.contains(id))
            .max()
            .map(|id| Object::Workspace(*id)),
        "pane" => after
            .panes()
            .into_iter()
            .filter(|id| !before.panes().contains(id))
            .max()
            .map(Object::Pane),
        _ => {
            after.tabs().into_iter().filter(|id| !before.tabs().contains(id)).max().map(Object::Tab)
        }
    };
    created.map(Some).ok_or_else(|| format!("no new {kind}"))
}

fn count(snapshot: &Snapshot, of: &str, container: Option<Object>) -> Result<usize, String> {
    Ok(match (of, container) {
        ("workspaces", None) => snapshot.workspaces.len(),
        ("panes", None) => snapshot.panes().len(),
        ("panes", Some(Object::Workspace(workspace))) => {
            snapshot.panes_of.get(&workspace).map_or(0, Vec::len)
        }
        ("tabs", None) => snapshot.tabs().len(),
        ("tabs", Some(Object::Pane(pane))) => snapshot.tabs_of.get(&pane).map_or(0, Vec::len),
        ("tabs", Some(Object::Workspace(workspace))) => {
            snapshot.panes_of.get(&workspace).map_or(0, |panes| {
                panes.iter().map(|pane| snapshot.tabs_of.get(pane).map_or(0, Vec::len)).sum()
            })
        }
        _ => return Err(format!("no count of {of} in that container")),
    })
}

fn ids(snapshot: &Snapshot, of: &str) -> Result<Vec<u64>, String> {
    Ok(match of {
        "workspaces" => snapshot.workspaces.clone(),
        "panes" => snapshot.panes(),
        "tabs" => snapshot.tabs(),
        other => return Err(format!("no ids of {other}")),
    })
}

fn raw(object: Option<Object>) -> Option<u64> {
    object.map(|object| match object {
        Object::Workspace(id) | Object::Pane(id) | Object::Tab(id) => id,
    })
}

/// Checks one expectation of `before` -> `after`.
fn check(seed: &Seed, before: &Snapshot, after: &Snapshot, expect: &Value) -> Result<(), String> {
    let code = expect["code"].as_str().unwrap_or("");
    let of = expect["of"].as_str().unwrap_or("");
    let kind_of = |of: &str| match of {
        "workspace" | "workspaces" => "workspace",
        "pane" | "panes" => "pane",
        _ => "tab",
    };
    let fail = |detail: String| Err(format!("{code}: {detail}"));
    match code {
        "no-crash" | "layout-valid" => Ok(()),
        "items-kept" | "item-set-kept" => {
            let (old, new) = (ids(before, of)?, ids(after, of)?);
            let lost: Vec<_> = old.iter().filter(|id| !new.contains(id)).collect();
            let added = new.len() != old.len() || !new.iter().all(|id| old.contains(id));
            if !lost.is_empty() {
                fail(format!("{} {of} lost", lost.len()))
            } else if code == "item-set-kept" && added {
                fail(format!("{of} changed from {} to {}", old.len(), new.len()))
            } else {
                Ok(())
            }
        }
        "count-delta" => {
            let container = resolve(seed, before, after, &expect["in"], "workspace")?;
            let delta = count(after, of, container)? as i64 - count(before, of, container)? as i64;
            let by = expect["by"].as_i64().ok_or("count-delta: no by")?;
            if delta == by {
                Ok(())
            } else {
                fail(format!("{of} changed by {delta}, expected {by}"))
            }
        }
        "order-is" => {
            let wanted = expect["ids"]
                .as_array()
                .ok_or("order-is: no ids")?
                .iter()
                .map(|id| resolve(seed, before, after, id, kind_of(of)).map(raw))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            let actual: Vec<u64> = match (of, resolve(seed, before, after, &expect["in"], "pane")?)
            {
                ("workspaces", None) => after.workspaces.clone(),
                ("tabs", Some(Object::Pane(pane))) => {
                    after.tabs_of.get(&pane).cloned().unwrap_or_default()
                }
                _ => return fail(format!("no order of {of} there")),
            };
            if actual == wanted { Ok(()) } else { fail(format!("{actual:?}, expected {wanted:?}")) }
        }
        "pane-has" => {
            let pane = seed.pane(&expect["pane"])?;
            let tab = seed.tab(&expect["tab"])?;
            if after.tabs_of.get(&pane).is_some_and(|tabs| tabs.contains(&tab)) {
                Ok(())
            } else {
                fail("the pane lacks the tab".into())
            }
        }
        "selected-is" => {
            let wanted = raw(resolve(seed, before, after, arg(expect, "id")?, kind_of(of))?);
            let actual = match (of, resolve(seed, before, after, &expect["in"], "pane")?) {
                ("workspace", _) => after.active_workspace,
                ("tab", Some(Object::Pane(pane))) => {
                    after.selected_tab.get(&pane).copied().flatten()
                }
                _ => return fail(format!("no selection of {of} there")),
            };
            if actual == wanted { Ok(()) } else { fail(format!("{actual:?}, expected {wanted:?}")) }
        }
        "focus-on" => {
            let wanted = raw(resolve(seed, before, after, arg(expect, "id")?, kind_of(of))?);
            let actual = match of {
                "pane" => after.focused_pane,
                "tab" => after
                    .focused_pane
                    .and_then(|pane| after.selected_tab.get(&pane).copied().flatten()),
                other => return fail(format!("no focus of {other}")),
            };
            if actual == wanted { Ok(()) } else { fail(format!("{actual:?}, expected {wanted:?}")) }
        }
        "zoomed-is" => {
            let wanted = raw(resolve(seed, before, after, arg(expect, "id")?, "pane")?);
            let actual = after.zoomed_pane;
            if actual == wanted { Ok(()) } else { fail(format!("{actual:?}, expected {wanted:?}")) }
        }
        other => fail(format!("{other} has no headless check")),
    }
}

/// A required argument; `null` is a value, a missing key is a typo.
fn arg<'a>(expect: &'a Value, key: &str) -> Result<&'a Value, String> {
    expect.get(key).ok_or_else(|| format!("no {key}"))
}

/// Runs one case; returns its failures.
fn run_case(case: &Value) -> Vec<String> {
    let id = case["id"].as_str().unwrap_or("?");
    let seed = Seed::new(case["state"].as_str().unwrap_or(""));
    let core = case["core"].as_array().cloned().unwrap_or_default();
    let steps = case["steps"].as_array().cloned().unwrap_or_default();
    let start = Snapshot::of(&seed.mux);
    let mut failures = Vec::new();
    // A headless case without core steps would check its end against its own start.
    if core.is_empty() {
        return vec![format!("MATRIX {id}: a headless case needs core steps")];
    }
    // Step expectations pair each step with its core step; unpaired ones would never run.
    if steps.iter().any(|step| step.get("expect").is_some()) && core.len() != steps.len() {
        return vec![format!("MATRIX {id}: step expectations need one core step per step")];
    }
    for (index, step) in core.iter().enumerate() {
        let before_layout = seed.mux.with_state(layout_invariants::project);
        let before = Snapshot::of(&seed.mux);
        if let Err(error) = apply(&seed, step) {
            failures.push(format!("MATRIX {id}: core step {index}: {error}"));
            return failures;
        }
        // Moves and zoom conserve tabs; creates and closes only keep the
        // per-state invariants (no empty pane, no tab placed twice).
        let conserving = CONSERVING_OPS.contains(&step["op"].as_str().unwrap_or(""));
        let problems = seed.mux.with_state(|state| {
            if conserving {
                return layout_invariants::transition_problems(&before_layout, None, state);
            }
            let known = cmux_layout_reducer::check_state(&before_layout);
            cmux_layout_reducer::check_state(&layout_invariants::project(state))
                .difference(&known)
                .map(ToString::to_string)
                .collect()
        });
        if !problems.is_empty() {
            failures.push(format!(
                "MATRIX {id}: layout-valid after core step {index}: {}",
                problems.join("; ")
            ));
        }
        // A step's own expectations hold after its core step (one core step per step).
        if let Some(expects) = steps.get(index).and_then(|step| step["expect"].as_array()) {
            let after = Snapshot::of(&seed.mux);
            for expect in expects {
                if let Err(error) = check(&seed, &before, &after, expect) {
                    failures.push(format!("MATRIX {id}: step {index}: {error}"));
                }
            }
        }
    }
    let end = Snapshot::of(&seed.mux);
    for expect in case["expect"].as_array().into_iter().flatten() {
        if let Err(error) = check(&seed, &start, &end, expect) {
            failures.push(format!("MATRIX {id}: {error}"));
        }
    }
    failures
}

#[test]
fn matrix_cases_hold_on_the_core() {
    let Some(file) = case_file() else {
        eprintln!("MATRIX: no Packages/macOS/CmuxNext in this tree; skipped");
        return;
    };
    let cases: Vec<&Value> = file["cases"]
        .as_array()
        .expect("MATRIX: no cases")
        .iter()
        .filter(|case| {
            case["tiers"]
                .as_array()
                .is_some_and(|tiers| tiers.iter().any(|tier| tier == "headless"))
        })
        .collect();
    assert!(!cases.is_empty(), "MATRIX: no headless cases");
    let failures: Vec<String> = cases.iter().flat_map(|case| run_case(case)).collect();
    assert!(
        failures.is_empty(),
        "{} of {} headless cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}
