//! Seeded property test for invariant 3 of
//! plans/cmux-next/OWNERSHIP-PRINCIPLES.md: a terminal host's death never
//! closes a workspace or removes a tab; the tab becomes dead.
//!
//! Random mixes of host deaths, process ends (close and keep policies),
//! explicit closes and owner restarts run against a persistent mux. A
//! reference model predicts the tab set after every step. Workspaces,
//! screens, panes and tabs may change only through a process end or an
//! explicit close; every other step leaves the topology identical.
//!
//! The generator is a fixed xorshift so a failure names its seed and
//! replays exactly (cmux-tui-core has no proptest dependency, and the
//! lockfile is not regenerated for one test).

use std::collections::{BTreeMap, BTreeSet};

use super::*;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// Cases run by [`host_death_never_removes_topology`].
const CASES: u64 = 48;
/// Steps per case.
const STEPS: usize = 12;

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1)
    }

    fn step(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.step() % bound as u64) as usize
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Life {
    Running,
    /// The host died with no exit status; the tabs stay, dead.
    HostLost,
    /// The process ended; `runtime` says whether the screen surface lives.
    Ended {
        runtime: bool,
    },
    Closed,
}

struct ModelTerminal {
    id: String,
    incarnation: String,
    keep: bool,
    life: Life,
    tabs: BTreeSet<String>,
}

impl ModelTerminal {
    fn shows_tabs(&self) -> bool {
        match self.life {
            Life::Running | Life::HostLost => true,
            Life::Ended { runtime } => self.keep && runtime,
            Life::Closed => false,
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Step {
    HostDeath(usize),
    ProcessEnd(usize),
    Close(usize),
    Restart,
}

/// Workspace -> screen -> pane -> tab public ids.
type Topology = BTreeMap<String, BTreeMap<String, BTreeMap<String, Vec<String>>>>;

fn topology(mux: &Mux) -> Topology {
    mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| {
                let screens = workspace
                    .screens
                    .iter()
                    .map(|screen| {
                        let panes = screen
                            .root
                            .pane_ids_vec()
                            .into_iter()
                            .map(|pane| {
                                let tabs = state.panes[&pane]
                                    .tabs
                                    .iter()
                                    .map(|tab| state.resource_indexes.tab_ids[tab].to_string())
                                    .collect::<Vec<_>>();
                                (state.resource_indexes.pane_ids[&pane].to_string(), tabs)
                            })
                            .collect();
                        (screen.public_id.to_string(), panes)
                    })
                    .collect();
                (workspace.public_id.to_string(), screens)
            })
            .collect()
    })
}

fn tabs_of(topology: &Topology) -> BTreeSet<String> {
    topology
        .values()
        .flat_map(|screens| screens.values())
        .flat_map(|panes| panes.values())
        .flat_map(|tabs| tabs.iter().cloned())
        .collect()
}

fn runtime_surface(mux: &Mux, terminal: &ModelTerminal) -> Option<SurfaceId> {
    mux.resolve_terminal(&terminal.id).unwrap().and_then(|resolved| resolved.surface)
}

/// Removal steps may only delete structure whose every tab was removed.
fn assert_removal_only(before: &Topology, after: &Topology, removed: &BTreeSet<String>, at: &str) {
    for (workspace, screens) in before {
        let all_tabs = |screens: &BTreeMap<String, BTreeMap<String, Vec<String>>>| {
            screens.values().flat_map(|panes| panes.values()).flatten().cloned().collect::<Vec<_>>()
        };
        let Some(after_screens) = after.get(workspace) else {
            assert!(
                all_tabs(screens).iter().all(|tab| removed.contains(tab)),
                "{at}: workspace {workspace} closed with surviving tabs"
            );
            continue;
        };
        for (screen, panes) in screens {
            let Some(after_panes) = after_screens.get(screen) else {
                assert!(
                    panes.values().flatten().all(|tab| removed.contains(tab)),
                    "{at}: screen {screen} removed with surviving tabs"
                );
                continue;
            };
            for (pane, tabs) in panes {
                if !after_panes.contains_key(pane) {
                    assert!(
                        tabs.iter().all(|tab| removed.contains(tab)),
                        "{at}: pane {pane} removed with surviving tabs"
                    );
                }
            }
        }
    }
    assert!(
        after.keys().all(|workspace| before.contains_key(workspace)),
        "{at}: a removal step created a workspace"
    );
}

fn terminal_hex(prefix: &str, index: usize) -> String {
    format!("{prefix}000000000040008000{index:012x}")
}

fn run_case(seed: u64) -> usize {
    let mut rng = Rng::new(seed);
    let root = std::env::temp_dir()
        .join(format!("cmux-host-death-{seed}-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "host-death";
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(&root, session)),
        ..SurfaceOptions::default()
    };
    let mut mux = Mux::open_persistent(session, options.clone(), &root).unwrap();

    let mut terminals = Vec::new();
    for _ in 0..1 + rng.below(3) {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        for _ in 0..1 + rng.below(2) {
            let index = terminals.len();
            let id = terminal_hex("00", index);
            let incarnation = terminal_hex("10", index);
            let keep = rng.below(2) == 0;
            let on_exit = if keep { TerminalOnExit::Keep } else { TerminalOnExit::Close };
            let before = tabs_of(&topology(&mux));
            mux.seed_running_terminal_with_on_exit_for_test(
                &id,
                &incarnation,
                &workspace.key,
                on_exit,
            )
            .unwrap();
            let tabs = tabs_of(&topology(&mux)).difference(&before).cloned().collect();
            terminals.push(ModelTerminal { id, incarnation, keep, life: Life::Running, tabs });
        }
    }

    let mut executed = 0;
    for step_index in 0..STEPS {
        let step = match rng.below(10) {
            0..=3 => Step::HostDeath(rng.below(terminals.len())),
            4..=6 => Step::ProcessEnd(rng.below(terminals.len())),
            7..=8 => Step::Close(rng.below(terminals.len())),
            _ => Step::Restart,
        };
        let at = format!("seed {seed} step {step_index} {step:?}");
        let before = topology(&mux);
        let revision = mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
        match step {
            Step::HostDeath(index) | Step::ProcessEnd(index) => {
                let terminal = &mut terminals[index];
                let Some(surface) = runtime_surface(&mux, terminal) else { continue };
                if let Step::ProcessEnd(_) = step {
                    let code = i32::try_from(rng.below(3)).unwrap();
                    mux.surface(surface).unwrap().record_process_end_for_test(TerminalExit::now(
                        TerminalExitOutcome::Exit { code },
                    ));
                }
                mux.surface_exited(surface);
                if terminal.life == Life::Running {
                    terminal.life = match step {
                        Step::HostDeath(_) => Life::HostLost,
                        _ => Life::Ended { runtime: true },
                    };
                }
            }
            Step::Close(index) => {
                let terminal = &mut terminals[index];
                if terminal.life == Life::Closed {
                    continue;
                }
                mux.close_terminal(&terminal.id, &terminal.incarnation).unwrap();
                terminal.life = Life::Closed;
            }
            Step::Restart => {
                mux.shutdown();
                drop(mux);
                mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
                for terminal in &mut terminals {
                    terminal.life = match terminal.life {
                        // No host record survives: a host loss.
                        Life::Running => Life::HostLost,
                        // The in-memory screen is gone.
                        Life::Ended { .. } => Life::Ended { runtime: false },
                        other => other,
                    };
                }
            }
        }
        executed += 1;
        if let Step::HostDeath(_) = step {
            // Closed history and every client delta derive from tombstoned
            // rows; a host death must tombstone none.
            let deletes = mux
                .resource_events_after(revision)
                .unwrap()
                .batches
                .iter()
                .flat_map(|batch| batch.changes.as_array().unwrap().clone())
                .filter(|change| {
                    change["kind"] == "delete"
                        && ["workspace", "screen", "pane", "tab"]
                            .contains(&change["resource"].as_str().unwrap_or_default())
                })
                .collect::<Vec<_>>();
            assert!(deletes.is_empty(), "{at}: a host death tombstoned {deletes:?}");
        }

        let after = topology(&mux);
        let expected = terminals
            .iter()
            .filter(|terminal| terminal.shows_tabs())
            .flat_map(|terminal| terminal.tabs.iter().cloned())
            .collect::<BTreeSet<_>>();
        let actual = tabs_of(&after);
        assert_eq!(actual, expected, "{at}: tab set diverged from the model");
        let removed = tabs_of(&before).difference(&actual).cloned().collect::<BTreeSet<_>>();
        if removed.is_empty() {
            assert_eq!(after, before, "{at}: topology changed without a process end or close");
        } else {
            assert!(
                !matches!(step, Step::HostDeath(_)),
                "{at}: a host death removed tabs {removed:?}"
            );
            assert_removal_only(&before, &after, &removed, &at);
        }
        for terminal in terminals.iter().filter(|terminal| terminal.life == Life::HostLost) {
            let resolved = mux.resolve_terminal(&terminal.id).unwrap().unwrap();
            assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited, "{at}");
        }
    }
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
    executed
}

#[cfg(unix)]
#[test]
fn host_death_never_removes_topology() {
    let executed = (1..=CASES).map(run_case).sum::<usize>();
    // Skipped steps (no runtime, already closed) do not count.
    assert!(executed >= CASES as usize * STEPS / 2, "only {executed} steps executed");
    eprintln!("host_death_never_removes_topology: {CASES} cases, {executed} executed steps");
}
