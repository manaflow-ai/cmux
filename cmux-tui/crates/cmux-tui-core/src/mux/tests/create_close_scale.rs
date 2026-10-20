//! Create and close cost per object kind at 10, 100, 500 and 1000
//! workspaces (plans/cmux-next/CREATE-CLOSE-DESIGN.md).
//!
//! Each kind is created and closed in the middle workspace, so a cost that
//! grows with the session shows as a ratio between the 10 and 1000 rows.
//! The cross-check is off, as in a release daemon. The table is written to
//! `.build/artifacts/create-close-bench.txt` (a fleet step returns it with
//! `--artifact`) and to stderr.

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use super::*;
use crate::mux::resource_content::without_crosscheck;

const SIZES: [usize; 4] = [10, 100, 500, 1000];
const REPS: usize = 5;

fn stat(mux: &Mux, field: &str) -> u64 {
    serde_json::to_value(mux.resource_projection_stats()).unwrap()[field].as_u64().unwrap_or(0)
}

fn full_projections(mux: &Mux) -> u64 {
    stat(mux, "full_projections")
}

fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}

/// One kind's median create and close time, and full projections per op.
#[derive(Clone, Copy, Debug)]
pub(super) struct KindCost {
    pub(super) create: Duration,
    pub(super) close: Duration,
    pub(super) create_full: u64,
    pub(super) close_full: u64,
}

fn measure(
    mux: &Arc<Mux>,
    mut create: impl FnMut() -> u64,
    mut close: impl FnMut(u64),
) -> KindCost {
    let (mut creates, mut closes) = (Vec::new(), Vec::new());
    let (mut create_full, mut close_full) = (0, 0);
    for _ in 0..REPS {
        let before = full_projections(mux);
        let started = Instant::now();
        let id = create();
        creates.push(started.elapsed());
        let middle = full_projections(mux);
        let started = Instant::now();
        close(id);
        closes.push(started.elapsed());
        create_full += middle - before;
        close_full += full_projections(mux) - middle;
    }
    KindCost {
        create: median(creates),
        close: median(closes),
        create_full: create_full / REPS as u64,
        close_full: close_full / REPS as u64,
    }
}

fn middle_pane(mux: &Mux) -> (WorkspaceId, PaneId) {
    mux.with_state(|state| {
        let workspace = &state.workspaces[state.workspaces.len() / 2];
        let screen = &workspace.screens[workspace.active_screen];
        (workspace.id, screen.active_pane)
    })
}

/// Every kind's cost with `mux` holding its current workspaces.
pub(super) fn kind_costs(mux: &Arc<Mux>) -> Vec<(&'static str, KindCost)> {
    let (workspace, pane) = middle_pane(mux);
    let size = Some((80, 24));
    let mut costs = Vec::new();
    costs.push((
        "workspace",
        measure(
            mux,
            || {
                let surface = mux.new_workspace(None, size).unwrap();
                mux.with_state(|state| {
                    let pane = state.pane_of(surface.id).unwrap();
                    let (index, _) = state.screen_of(pane).unwrap();
                    state.workspaces[index].id
                })
            },
            |id| assert!(mux.close_workspace(id)),
        ),
    ));
    costs.push((
        "terminal-tab",
        measure(
            mux,
            || mux.new_tab(Some(pane), None, size).unwrap().id,
            |id| assert!(mux.close_surface(id).unwrap()),
        ),
    ));
    costs.push((
        "browser-tab",
        measure(
            mux,
            || mux.new_browser_tab("about:blank#scale".into(), Some(pane), size).unwrap().id,
            |id| assert!(mux.close_surface(id).unwrap()),
        ),
    ));
    costs.push((
        "split",
        measure(
            mux,
            || {
                let surface = mux.split(pane, SplitDir::Right, size).unwrap();
                mux.with_state(|state| state.pane_of(surface.id).unwrap())
            },
            |id| assert!(mux.close_pane(id).unwrap()),
        ),
    ));
    costs.push((
        "screen",
        measure(
            mux,
            || {
                let surface = mux.new_screen(Some(workspace), size).unwrap();
                mux.with_state(|state| {
                    let pane = state.pane_of(surface.id).unwrap();
                    let (w, s) = state.screen_of(pane).unwrap();
                    state.workspaces[w].screens[s].id
                })
            },
            |id| assert!(mux.close_screen(id).unwrap()),
        ),
    ));
    costs
}

/// Grow `mux` to `target` workspaces, each with one terminal tab.
pub(super) fn grow_to(mux: &Arc<Mux>, target: usize) {
    let have = mux.with_state(|state| state.workspaces.len());
    for index in have..target {
        mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
    }
}

fn report_path() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/artifacts/create-close-bench.txt")
}

#[test]
fn create_close_cost_per_kind_at_scale() {
    without_crosscheck(|| {
        let mux = Mux::new_for_test("create-close-scale", SurfaceOptions::default());
        let mut table = String::from("n kind create_us close_us create_full close_full\n");
        let mut rows = Vec::new();
        for size in SIZES {
            grow_to(&mux, size);
            for (kind, cost) in kind_costs(&mux) {
                writeln!(
                    table,
                    "CREATE-CLOSE n={size} kind={kind} create_us={} close_us={} create_full={} close_full={}",
                    cost.create.as_micros(),
                    cost.close.as_micros(),
                    cost.create_full,
                    cost.close_full,
                )
                .unwrap();
                rows.push((size, kind, cost));
            }
        }
        eprintln!("{table}");
        let path = report_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, &table);
        mux.shutdown();
    });
}
