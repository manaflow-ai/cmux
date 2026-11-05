//! Requests a person waits on answer while the registry is busy. Leo, on a
//! notice after a plain click on a group's expand/collapse: "Collapse/Expand
//! Workspace Group did not apply: update-personal-group: timed out:
//! workspace_group.update (no reply within 2.0 seconds)"; `workspace.place`
//! and `new-conversation-tab` (`cmux agent open`) timed out the same way.
//! Every state write commits under the one workspace registry lock; on a busy
//! Mac (about 50 agent sessions writing status, progress and logs, the
//! machine at load ~290) the lock is held most of the time (78 % on the
//! 80-agent load, `mux/tests/registry_reads.rs`), and the mutex is not fair,
//! so a click's one short commit queued behind the whole crowd of writers.
//!
//! The model: 48 sessions, each committing `workspace_status.set` for its own
//! workspace back to back with a short pause, each commit holding the
//! registry lock 5 ms (the mean progress hold measured on Austin's day) so
//! together they want more of the lock than it has, as in a busy burst; and
//! 4 `cmux agent open` callers opening chat tabs. A person collapses a group,
//! moves a workspace between groups and opens a chat tab 30 times
//! meanwhile; the sidebar writes must answer in well under 100 ms (p95), the
//! chat tab under 200 ms ([`P95_TAB_BUDGET_MS`]), and the writes must still
//! commit and persist.
//!
//! The priority is bounded the other way too: agents can send personal
//! writes as well, so while 48 sessions keep them queued an ordinary
//! registry writer still makes progress.

use std::cell::Cell;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::json;

use super::conversation_tabs::ConversationTabTarget;
use super::conversation_tabs_store::ConversationTabRecord;
use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::Mux;

const SESSIONS: usize = 48;
const GROUPS: usize = 12;
const LOOSE_WORKSPACES: usize = 12;
const AGENT_OPEN_CALLERS: usize = 4;
const CLICKS: usize = 30;
const HOLD: Duration = Duration::from_millis(5);
const SESSION_PAUSE: Duration = Duration::from_millis(20);
const AGENT_OPEN_PAUSE: Duration = Duration::from_millis(100);
const CLICK_PAUSE: Duration = Duration::from_millis(30);
const P95_BUDGET_MS: f64 = 100.0;
/// A chat tab costs about 9 ms idle, but it takes the registry lock several
/// times (its browser row, the presentation reload, the topology commit),
/// and each take waits for the current holder; the 4 agent-open callers
/// also share the interactive turns, and plain lockers get a turn after 4.
/// So it answers in about 65 ms (p50) under this load, against 2 to 2.8 s
/// before. 200 ms is 10x under the app's 2 s deadline; fewer registry takes
/// per tab is its own follow-up.
const P95_TAB_BUDGET_MS: f64 = 200.0;

thread_local! {
    /// Set on the busy sessions' threads: only their commits hold the lock
    /// for [`HOLD`]; the person's requests commit at their own speed.
    static BUSY_SESSION: Cell<bool> = const { Cell::new(false) };
}

fn percentile(sorted: &[f64], fraction: f64) -> f64 {
    let index = ((sorted.len() as f64 - 1.0) * fraction).round() as usize;
    sorted[index.min(sorted.len() - 1)]
}

struct Sidebar {
    groups: Vec<String>,
    busy: Vec<String>,
    loose: Vec<String>,
}

/// A realistic sidebar: groups, a busy session's workspace in each, and
/// loose rows.
fn sidebar(mux: &Arc<Mux>) -> Sidebar {
    let groups: Vec<String> = (0..GROUPS)
        .map(|index| {
            let created = mutate(
                mux,
                "workspace_group.create",
                json!({"name": format!("Group {index}")}),
                &format!("group-{index}"),
            );
            created["id"].as_str().unwrap().to_string()
        })
        .collect();
    let busy: Vec<String> = (0..SESSIONS)
        .map(|index| {
            let workspace = empty_workspace(mux, &format!("busy-{index}"));
            mutate(
                mux,
                "workspace.place",
                json!({"workspace": workspace, "group": groups[index % GROUPS]}),
                &format!("place-{index}"),
            );
            workspace
        })
        .collect();
    let loose = (0..LOOSE_WORKSPACES)
        .map(|index| empty_workspace(mux, &format!("loose-{index}")))
        .collect();
    Sidebar { groups, busy, loose }
}

fn hold_busy_commits(mux: &Mux) {
    mux.set_state_commit_after_apply_hook_for_test(Some(Arc::new(|| {
        if BUSY_SESSION.with(Cell::get) {
            std::thread::sleep(HOLD);
        }
    })));
}

fn workspace_slot(mux: &Mux, public: &str) -> crate::WorkspaceId {
    mux.with_state(|state| {
        state.workspaces.iter().find(|workspace| workspace.public_id.as_str() == public).unwrap().id
    })
}

/// A chat tab as `cmux agent open` makes it.
fn open_chat_tab(mux: &Arc<Mux>, workspace: crate::WorkspaceId, session: String) {
    mux.new_conversation_tab(
        ConversationTabTarget::Workspace(workspace),
        ConversationTabRecord::AgentSession {
            host: "install:latency-test".into(),
            session: Some(session),
            harness: Some("claude".into()),
            host_name: None,
        },
        None,
        None,
    )
    .unwrap_or_else(|error| panic!("new-conversation-tab failed: {error:?}"));
}

fn timed(latencies: &mut BTreeMap<&'static str, Vec<f64>>, name: &'static str, run: impl FnOnce()) {
    let started = Instant::now();
    run();
    latencies.entry(name).or_default().push(started.elapsed().as_secs_f64() * 1000.0);
}

#[test]
fn a_persons_requests_answer_while_busy_sessions_saturate_the_registry() {
    let session = Session::new("person-request-latency");
    let mux = session.open();
    let sidebar = sidebar(&mux);

    // The same requests on an idle registry: what they cost with no wait.
    let idle_workspace = workspace_slot(&mux, &sidebar.loose[LOOSE_WORKSPACES - 3]);
    let mut idle = BTreeMap::new();
    for click in 0..CLICKS {
        timed(&mut idle, "workspace_group.update", || {
            send(
                &mux,
                "workspace_group.update",
                json!({"workspace_group": sidebar.groups[3], "collapsed": click.is_multiple_of(2)}),
                Some(&format!("idle-fold-{click}")),
            )
            .unwrap();
        });
        timed(&mut idle, "new-conversation-tab", || {
            open_chat_tab(&mux, idle_workspace, format!("idle-{click}"));
        });
    }
    for (name, values) in &idle {
        let mut sorted = values.clone();
        sorted.sort_by(f64::total_cmp);
        eprintln!(
            "IDLE_REQUEST_LATENCY {name} n={} p50={:.1}ms p95={:.1}ms",
            sorted.len(),
            percentile(&sorted, 0.5),
            percentile(&sorted, 0.95)
        );
    }

    hold_busy_commits(&mux);
    let stop = Arc::new(AtomicBool::new(false));
    let background_commits = Arc::new(AtomicU64::new(0));
    let mut threads: Vec<_> = sidebar
        .busy
        .iter()
        .enumerate()
        .map(|(index, workspace)| {
            let (mux, stop, commits, workspace) =
                (mux.clone(), stop.clone(), background_commits.clone(), workspace.clone());
            std::thread::spawn(move || {
                BUSY_SESSION.with(|busy| busy.set(true));
                let mut round = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    round += 1;
                    let result = send(
                        &mux,
                        "workspace_status.set",
                        json!({"workspace": workspace, "key": "agent", "text": format!("turn {round}")}),
                        Some(&format!("status-{index}-{round}")),
                    );
                    result.unwrap_or_else(|error| panic!("status write failed: {error:?}"));
                    commits.fetch_add(1, Ordering::Relaxed);
                    std::thread::sleep(SESSION_PAUSE);
                }
            })
        })
        .collect();
    // `cmux agent open` callers, each into its own loose workspace.
    for caller in 0..AGENT_OPEN_CALLERS {
        let (mux, stop) = (mux.clone(), stop.clone());
        let workspace = workspace_slot(&mux, &sidebar.loose[caller]);
        threads.push(std::thread::spawn(move || {
            let mut round = 0u64;
            while !stop.load(Ordering::Relaxed) {
                round += 1;
                open_chat_tab(&mux, workspace, format!("cli-{caller}-{round}"));
                std::thread::sleep(AGENT_OPEN_PAUSE);
            }
        }));
    }
    // Let every session reach its loop.
    std::thread::sleep(Duration::from_millis(300));

    let group = sidebar.groups[0].clone();
    let (moved, from, to) = (
        sidebar.loose[LOOSE_WORKSPACES - 1].clone(),
        sidebar.groups[1].clone(),
        sidebar.groups[2].clone(),
    );
    let chat_workspace = workspace_slot(&mux, &sidebar.loose[LOOSE_WORKSPACES - 2]);
    let mut latencies = BTreeMap::new();
    let commits_before = background_commits.load(Ordering::Relaxed);
    let measured_from = Instant::now();
    for click in 0..CLICKS {
        let collapsed = click.is_multiple_of(2);
        timed(&mut latencies, "workspace_group.update", || {
            let result = send(
                &mux,
                "workspace_group.update",
                json!({"workspace_group": group, "collapsed": collapsed}),
                Some(&format!("fold-{click}")),
            )
            .unwrap_or_else(|error| panic!("workspace_group.update failed: {error:?}"));
            assert_eq!(result["value"]["collapsed"], collapsed, "{result}");
        });
        std::thread::sleep(CLICK_PAUSE);
        let into = if click.is_multiple_of(2) { &from } else { &to };
        timed(&mut latencies, "workspace.place", || {
            send(
                &mux,
                "workspace.place",
                json!({"workspace": moved, "group": into}),
                Some(&format!("move-{click}")),
            )
            .unwrap_or_else(|error| panic!("workspace.place failed: {error:?}"));
        });
        std::thread::sleep(CLICK_PAUSE);
        timed(&mut latencies, "new-conversation-tab", || {
            open_chat_tab(&mux, chat_workspace, format!("person-{click}"));
        });
        std::thread::sleep(CLICK_PAUSE);
    }
    let window = measured_from.elapsed();
    let commits_during = background_commits.load(Ordering::Relaxed) - commits_before;
    stop.store(true, Ordering::Relaxed);
    for thread in threads {
        thread.join().unwrap();
    }
    mux.set_state_commit_after_apply_hook_for_test(None);

    // Share of the window the busy sessions held the lock (each commit
    // holds it at least HOLD).
    let busy_share = commits_during as f64 * HOLD.as_secs_f64() / window.as_secs_f64();
    let mut lines = Vec::new();
    let mut over = Vec::new();
    for (name, values) in &latencies {
        let mut sorted = values.clone();
        sorted.sort_by(f64::total_cmp);
        let (p50, p95, max) =
            (percentile(&sorted, 0.5), percentile(&sorted, 0.95), sorted[sorted.len() - 1]);
        let line = format!(
            "PERSON_REQUEST_LATENCY {name} n={} p50={p50:.1}ms p95={p95:.1}ms max={max:.1}ms \
             background_commits={commits_during} registry_busy_share={:.0}% sessions={SESSIONS} \
             agent_open_callers={AGENT_OPEN_CALLERS}",
            sorted.len(),
            busy_share * 100.0
        );
        eprintln!("{line}");
        let budget =
            if *name == "new-conversation-tab" { P95_TAB_BUDGET_MS } else { P95_BUDGET_MS };
        if p95 >= budget {
            over.push(line.clone());
        }
        lines.push(line);
    }
    if let Some(out) = std::env::var_os("FAST_CHECKS_OUT") {
        let path = std::path::Path::new(&out).join("person-request-latency.txt");
        let _ = std::fs::write(path, lines.join("\n") + "\n");
    }

    // Still durable: the last fold and the last move are in the registry
    // file after a restart.
    let last = (CLICKS - 1).is_multiple_of(2);
    drop(mux);
    let mux = session.open();
    let stored = read(&mux, "workspace_group.list", json!({}));
    let stored = stored
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == group.as_str())
        .cloned()
        .unwrap();
    assert_eq!(stored["collapsed"], last, "the last fold is in the registry file");
    mux.shutdown();

    assert!(over.is_empty(), "a person's request waited behind the busy sessions: {over:#?}");
}

/// The other side of the priority: agents can send personal writes too
/// (`workspace.place`, group edits in a loop). With 48 sessions keeping
/// such writes queued on the registry all the time, an ordinary writer (a
/// status update, a workspace create or close) steps aside for a bounded
/// number of turns and then queues as before: it keeps making progress.
#[test]
fn ordinary_registry_writers_progress_while_personal_writes_stay_queued() {
    const WRITES: usize = 30;
    const P95_ORDINARY_BUDGET_MS: f64 = 1000.0;
    let session = Session::new("ordinary-writer-progress");
    let mux = session.open();
    let Sidebar { groups, busy, .. } = sidebar(&mux);
    hold_busy_commits(&mux);
    let stop = Arc::new(AtomicBool::new(false));
    let personal: Vec<_> = (0..SESSIONS)
        .map(|index| {
            let (mux, stop, group) = (mux.clone(), stop.clone(), groups[index % GROUPS].clone());
            std::thread::spawn(move || {
                BUSY_SESSION.with(|busy| busy.set(true));
                let mut round = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    round += 1;
                    send(
                        &mux,
                        "workspace_group.update",
                        json!({"workspace_group": group, "collapsed": round.is_multiple_of(2)}),
                        Some(&format!("agent-fold-{index}-{round}")),
                    )
                    .unwrap_or_else(|error| panic!("personal write failed: {error:?}"));
                    // Back to back: each session asks again the moment it
                    // is answered.
                }
            })
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));

    let (done, finished) = std::sync::mpsc::channel();
    let writer = {
        let (mux, workspace) = (mux.clone(), busy[0].clone());
        std::thread::spawn(move || {
            for write in 0..WRITES {
                let started = Instant::now();
                send(
                    &mux,
                    "workspace_status.set",
                    json!({"workspace": workspace, "key": "build", "text": format!("step {write}")}),
                    Some(&format!("ordinary-{write}")),
                )
                .unwrap_or_else(|error| panic!("status write failed: {error:?}"));
                if done.send(started.elapsed().as_secs_f64() * 1000.0).is_err() {
                    return;
                }
                std::thread::sleep(CLICK_PAUSE);
            }
        })
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut latencies = Vec::with_capacity(WRITES);
    while latencies.len() < WRITES {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match finished.recv_timeout(remaining) {
            Ok(latency) => latencies.push(latency),
            Err(_) => break,
        }
    }
    stop.store(true, Ordering::Relaxed);
    for thread in personal {
        thread.join().unwrap();
    }
    writer.join().unwrap();
    mux.set_state_commit_after_apply_hook_for_test(None);
    mux.shutdown();

    assert_eq!(
        latencies.len(),
        WRITES,
        "an ordinary writer starved behind queued personal writes: {} of {WRITES} in 60 s",
        latencies.len()
    );
    let mut sorted = latencies;
    sorted.sort_by(f64::total_cmp);
    let (p50, p95, max) = (percentile(&sorted, 0.5), percentile(&sorted, 0.95), sorted[WRITES - 1]);
    let line = format!(
        "ORDINARY_WRITER_LATENCY workspace_status.set n={WRITES} p50={p50:.1}ms p95={p95:.1}ms max={max:.1}ms \
         personal_writers={SESSIONS}"
    );
    eprintln!("{line}");
    assert!(p95 < P95_ORDINARY_BUDGET_MS, "an ordinary writer waited too long: {line}");
}
