//! The sidebar draws what is in view: a frame's work does not grow with the number of sessions
//! (Leo, 2026-11-18: "we draw the visible area, right? Like, that's what we're supposed to do").

use super::*;
use crate::hub::peer_snapshot::thread_allocations;
use crate::tui::interaction_tests::app;
use serde_json::json;

/// `n` sessions, newest first, over 50 projects (one in seven on a peer), so every project is
/// cut at its first rows at both sizes below and the drawn list has the same lines.
fn sessions(n: usize) -> Vec<Value> {
    (0..n)
        .map(|i| {
            let mut s = json!({
                "sessionId": format!("s{i}"),
                "name": format!("session {i}"),
                "cwd": format!("/work/project-{}", i % 50),
                "status": if i % 11 == 0 { "running" } else { "idle" },
                "updatedAt": (n - i) as u64,
            });
            if i % 7 == 0 {
                s["peer"] = json!("box");
            }
            s
        })
        .collect()
}

struct Frames {
    terminal: ratatui::Terminal<ratatui::backend::TestBackend>,
    area: Rect,
}

impl Frames {
    fn new() -> Self {
        let terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(40, 40)).unwrap();
        Frames { terminal, area: Rect { x: 0, y: 0, width: 40, height: 40 } }
    }
    /// One sidebar frame: its allocations on this thread.
    fn draw(&mut self, app: &mut App) -> usize {
        let area = self.area;
        app.buttons.clear();
        let ((), made) = thread_allocations(|| {
            self.terminal.draw(|f| draw_sidebar(f, area, app)).unwrap();
        });
        made
    }
}

/// Allocations of one frame after each event, at `n` sessions.
async fn frame_allocations(n: usize) -> [usize; 5] {
    let (mut app, _) = app().await;
    app.sessions = sessions(n).into();
    app.selected = app.drafts.len();
    let mut frames = Frames::new();
    frames.draw(&mut app);
    // A frame with nothing changed (the 80 ms tick of a running session).
    let idle = frames.draw(&mut app);
    // The pointer moves to another row.
    app.hover = Some((5, 6));
    let hover = frames.draw(&mut app);
    // The selection steps one row down.
    app.selected += 1;
    let step = frames.draw(&mut app);
    // One session's status changes in place.
    app.sessions[3]["status"] = json!("waiting");
    let change = frames.draw(&mut app);
    // The sidebar is one column wider.
    frames.area.width = 39;
    let resize = frames.draw(&mut app);
    [idle, hover, step, change, resize]
}

#[tokio::test]
async fn a_sidebar_frame_does_not_grow_with_the_sessions() {
    let small = frame_allocations(1_000).await;
    let large = frame_allocations(10_000).await;
    let names = ["idle", "hover", "step", "one change", "resize"];
    for ((name, s), l) in names.iter().zip(small).zip(large) {
        assert!(
            l <= s + s / 10 + 4,
            "a {name} frame made {l} allocations at 10,000 sessions and {s} at 1,000"
        );
    }
}

/// The drawn order the sidebar had before it kept its layout between frames, written out plainly:
/// drafts first, then projects in order of their newest session, a project past seven rows cut at
/// six unless it is opened or holds the selection.
fn plain_order(app: &App) -> Vec<usize> {
    let ndrafts = app.drafts.len();
    let mut order: Vec<String> = Vec::new();
    let mut members: std::collections::HashMap<String, Vec<usize>> = Default::default();
    for i in (0..app.row_count()).filter(|i| app.row_visible(*i)) {
        let g = if i < ndrafts {
            String::new()
        } else {
            let s = &app.sessions[i - ndrafts];
            let project = project_label(s.get("cwd").and_then(Value::as_str).unwrap_or(""));
            match s.get("peer").and_then(Value::as_str) {
                Some(p) => format!("{p} · {project}"),
                None => project,
            }
        };
        if !members.contains_key(&g) {
            order.push(g.clone());
        }
        members.entry(g).or_default().push(i);
    }
    let mut drawn = Vec::new();
    for g in order {
        let idxs = members.remove(&g).unwrap();
        let open = g.is_empty()
            || app.expanded_groups.contains(&g)
            || idxs.len() <= GROUP_ROWS + 1
            || idxs.iter().skip(GROUP_ROWS).any(|&i| i == app.selected);
        drawn.extend(idxs.into_iter().take(if open { usize::MAX } else { GROUP_ROWS }));
    }
    drawn
}

/// The sidebar groups what it draws as before: projects in order of their newest session, six
/// rows and "Show more", the selection's project open, opened projects, the host filter, drafts.
#[tokio::test]
async fn the_grouped_list_is_drawn_as_before() {
    let (mut app, _) = app().await;
    app.sessions = sessions(1_000).into();
    app.selected = app.drafts.len() + 3;
    let mut frames = Frames::new();
    frames.draw(&mut app);
    assert_eq!(app.sidebar_order, plain_order(&app));
    assert_eq!(app.sidebar_order[0], 0, "the draft leads");
    assert!(
        app.buttons.iter().any(|(_, b)| matches!(b, ButtonAction::ShowGroup(_))),
        "a long project shows Show more"
    );
    // Selecting a row behind "Show more" opens its project.
    let behind = (0..app.row_count()).find(|i| !app.sidebar_order.contains(i)).unwrap();
    app.selected = behind;
    frames.draw(&mut app);
    assert!(app.sidebar_order.contains(&behind), "the selection's project opens");
    assert_eq!(app.sidebar_order, plain_order(&app));
    assert!(app.sidebar_rows.iter().any(|(_, i)| *i == behind), "the selection is in view");
    // "Show more" opens a project that stays open after the selection leaves it.
    let group = app
        .buttons
        .iter()
        .find_map(|(_, b)| match b {
            ButtonAction::ShowGroup(g) => Some(g.clone()),
            _ => None,
        })
        .unwrap();
    app.expanded_groups.insert(group);
    app.selected = app.drafts.len();
    frames.draw(&mut app);
    assert_eq!(app.sidebar_order, plain_order(&app));
    // A session moves to the top of the list.
    let row = app.sessions.remove(250);
    app.sessions.insert(0, row);
    frames.draw(&mut app);
    assert_eq!(app.sidebar_order, plain_order(&app));
    // A host filter hides the other host's rows.
    app.host_filter = Some("box".into());
    frames.draw(&mut app);
    assert_eq!(app.sidebar_order, plain_order(&app));
    assert!(app.sidebar_order.iter().all(|&i| app.row_visible(i)));
    app.host_filter = None;
    // A second draft.
    app.open_draft();
    frames.draw(&mut app);
    assert_eq!(app.sidebar_order, plain_order(&app));
}

/// ms per sidebar frame and allocations at 100 and 10,000 sessions, for the PR's numbers:
/// `cargo test -p acpmux --features tui --release sidebar_frame_numbers -- --ignored --nocapture`.
#[tokio::test]
#[ignore]
async fn sidebar_frame_numbers() {
    for n in [100, 10_000] {
        let (mut app, _) = app().await;
        app.sessions = sessions(n).into();
        app.selected = app.drafts.len();
        let mut frames = Frames::new();
        frames.draw(&mut app);
        let rounds = 200;
        let mut idle = Vec::with_capacity(rounds);
        let mut change = Vec::with_capacity(rounds);
        let (mut idle_allocs, mut change_allocs) = (0, 0);
        for r in 0..rounds {
            let at = std::time::Instant::now();
            idle_allocs = frames.draw(&mut app);
            idle.push(at.elapsed());
            app.sessions[3]["status"] = json!(if r % 2 == 0 { "waiting" } else { "idle" });
            let at = std::time::Instant::now();
            change_allocs = frames.draw(&mut app);
            change.push(at.elapsed());
        }
        let p = |v: &mut Vec<std::time::Duration>, q: f64| {
            v.sort();
            v[((v.len() as f64 - 1.0) * q) as usize].as_secs_f64() * 1e3
        };
        println!(
            "sessions={n} idle_frame_ms p50={:.3} p95={:.3} allocs={idle_allocs} | change_frame_ms p50={:.3} p95={:.3} allocs={change_allocs}",
            p(&mut idle, 0.5),
            p(&mut idle, 0.95),
            p(&mut change, 0.5),
            p(&mut change, 0.95),
        );
    }
}

/// A frame reads no session it read before; a one-row change, set in place or moved to the top
/// (`events.rs`' `MUX_SESSION_CHANGED`), reads that row alone, at any number of sessions.
#[tokio::test]
async fn a_frame_reads_only_the_rows_that_changed() {
    for n in [1_000, 10_000] {
        let (mut app, _) = app().await;
        app.sessions = sessions(n).into();
        app.selected = app.drafts.len();
        let mut frames = Frames::new();
        frames.draw(&mut app);
        assert_eq!(app.sidebar_layout.rows_read, n, "the first frame reads every row once");
        let read = |app: &mut App, frames: &mut Frames| {
            let before = app.sidebar_layout.rows_read;
            frames.draw(app);
            app.sidebar_layout.rows_read - before
        };
        assert_eq!(read(&mut app, &mut frames), 0, "an idle frame read rows");
        app.hover = Some((5, 6));
        app.selected += 1;
        assert_eq!(read(&mut app, &mut frames), 0, "a hover and a step read rows");
        app.sessions[3]["status"] = json!("waiting");
        assert_eq!(read(&mut app, &mut frames), 1, "a status change read other rows");
        let row = app.sessions.remove(n / 2);
        app.sessions.insert(0, row);
        assert_eq!(read(&mut app, &mut frames), 1, "a row moved to the top read other rows");
        assert_eq!(app.sidebar_order, plain_order(&app));
        // A sort is not followed row by row: it reads the list again, and the order holds.
        app.sessions.sort_by_key(|s| std::cmp::Reverse(s["updatedAt"].as_u64()));
        assert_eq!(read(&mut app, &mut frames), n);
        assert_eq!(app.sidebar_order, plain_order(&app));
    }
}
