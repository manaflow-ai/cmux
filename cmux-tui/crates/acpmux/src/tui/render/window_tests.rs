//! Transcript layout work per frame is bounded by what is on screen, not by the transcript's
//! length: a width change wraps the turns in view (plus one viewport of overscan each side), a
//! one-item change wraps that item's turn, and a scroll step wraps only turns that come into
//! view. `TranscriptCache::items_wrapped` counts the items laid out.

use super::*;
use ratatui::Terminal;
use ratatui::backend::TestBackend;

const ID: &str = "test-session";
/// Items per turn in these transcripts: a question, a tool call, a thought and the reply.
const TURN: usize = 4;
const HEIGHT: u16 = 40;

fn transcript(items: usize) -> Transcript {
    let mut t = Transcript::default();
    for k in 0..items / TURN {
        t.items.push(Item::User {
            text: format!("Question {k}: why does the parser drop the last token of a long line?"),
            steer: false,
            queued: false,
        });
        t.items.push(Item::Tool {
            id: format!("tool-{k}"),
            title: format!("Read src/parser_{k}.rs"),
            kind: "read".into(),
            status: "completed".into(),
            detail: "fn parse() {}\n".repeat(3),
        });
        t.items
            .push(Item::Thought { text: "**Looking at the tokenizer**\nIt stops early.".into() });
        t.items.push(Item::Assistant {
            text: format!(
                "Reply {k}. The tokenizer stops one byte early when the line ends without a \
                 newline, so the last token never reaches the parser. Read `src/parser_{k}.rs` \
                 at https://example.com/parser/{k} for the fix.\n\n- first point\n- second point"
            ),
        });
    }
    t.status = "ready".into();
    t
}

async fn app_with(items: usize) -> App {
    let (mut app, _) = crate::tui::interaction_tests::app().await;
    app.sessions = vec![serde_json::json!({"sessionId": ID})];
    app.selected = app.drafts.len();
    app.transcripts.insert(ID.into(), transcript(items));
    app
}

fn terminal(width: u16) -> Terminal<TestBackend> {
    Terminal::new(TestBackend::new(width, HEIGHT)).unwrap()
}

/// Items wrapped by one frame.
fn frame(app: &mut App, term: &mut Terminal<TestBackend>) -> usize {
    let before = app.transcript_cache.items_wrapped;
    term.draw(|f| draw(f, app)).unwrap();
    app.transcript_cache.items_wrapped - before
}

/// Items wrapped by one frame drawn `width` columns wide.
fn resized(app: &mut App, term: &mut Terminal<TestBackend>, width: u16) -> usize {
    let old = app.transcript_inner().width;
    term.backend_mut().resize(width, HEIGHT);
    let n = frame(app, term);
    assert_ne!(app.transcript_inner().width, old, "the step changes the transcript's width");
    n
}

/// Every row holds at most one item's worth of these turns (a turn is at least four rows), so
/// the rows in view plus one viewport of overscan each side bound the items wrapped. The live
/// turn at the end is laid out with every change, as before.
fn bound(app: &App) -> usize {
    3 * app.transcript_inner().height as usize + TURN
}

/// Max items wrapped per width-change step, pinned to the bottom and scrolled to the middle.
async fn width_steps(items: usize) -> (usize, usize) {
    let mut app = app_with(items).await;
    let mut term = terminal(140);
    frame(&mut app, &mut term);
    let mut pinned = 0;
    for w in [136, 132, 128, 124] {
        pinned = pinned.max(resized(&mut app, &mut term, w));
    }
    let vp = app.viewport.get_mut(ID).unwrap();
    let middle = vp.total / 2;
    vp.scroll_by(-(middle as isize));
    frame(&mut app, &mut term);
    let mut middle_max = 0;
    for w in [128, 132, 136, 140] {
        middle_max = middle_max.max(resized(&mut app, &mut term, w));
    }
    let b = bound(&app);
    assert!(
        pinned <= b,
        "N={items}: a width step at the bottom wrapped {pinned} items (bound {b})"
    );
    assert!(
        middle_max <= b,
        "N={items}: a width step mid-transcript wrapped {middle_max} items (bound {b})"
    );
    (pinned, middle_max)
}

fn flat(a: usize, b: usize) -> bool {
    a.abs_diff(b) * 10 <= a.max(b)
}

#[tokio::test]
async fn a_width_change_wraps_only_the_turns_in_view() {
    let (p1, m1) = width_steps(1_000).await;
    let (p10, m10) = width_steps(10_000).await;
    eprintln!("items wrapped per width step: N=1000 {p1}/{m1}, N=10000 {p10}/{m10}");
    assert!(flat(p1, p10), "bottom: {p1} at N=1,000 vs {p10} at N=10,000");
    assert!(flat(m1, m10), "middle: {m1} at N=1,000 vs {m10} at N=10,000");
}

#[tokio::test]
async fn a_one_item_change_wraps_only_its_turn() {
    for items in [1_000, 10_000] {
        let mut app = app_with(items).await;
        let mut term = terminal(140);
        frame(&mut app, &mut term);
        let update = |k: usize| {
            serde_json::json!({"sessionId": ID, "update": {
                "sessionUpdate": "tool_call_update", "toolCallId": format!("tool-{k}"),
                "status": "failed",
            }})
        };
        // The turn above the last one is on screen.
        let shown = items / TURN - 2;
        app.transcripts.get_mut(ID).unwrap().apply_update(&update(shown));
        let n = frame(&mut app, &mut term);
        assert!(n <= TURN, "N={items}: a change on screen wrapped {n} items, its turn has {TURN}");
        // The first turn is far above the screen: nothing is wrapped until it is scrolled to.
        app.transcripts.get_mut(ID).unwrap().apply_update(&update(0));
        let n = frame(&mut app, &mut term);
        assert_eq!(n, 0, "N={items}: a change off screen wrapped {n} items");
    }
}

#[tokio::test]
async fn a_scroll_step_wraps_only_turns_coming_into_view() {
    for items in [1_000, 10_000] {
        let mut app = app_with(items).await;
        let mut term = terminal(140);
        frame(&mut app, &mut term);
        resized(&mut app, &mut term, 130);
        let rows = 3 * app.transcript_inner().height as usize;
        let mut total = 0;
        for _ in 0..rows {
            app.viewport.get_mut(ID).unwrap().scroll_by(-1);
            let n = frame(&mut app, &mut term);
            assert!(n <= TURN, "N={items}: a one-row scroll wrapped {n} items");
            total += n;
        }
        assert!(total <= rows, "N={items}: {rows} one-row scrolls wrapped {total} items");
    }
}

/// Cost of one width-change frame (ms and allocations), at 100 and 10,000 items. Run with
/// `cargo test -p acpmux --features tui --release -- --ignored width_change_frame_cost --nocapture`.
#[cfg(target_os = "linux")]
#[tokio::test]
#[ignore = "bench: prints numbers"]
async fn width_change_frame_cost() {
    for items in [100, 10_000] {
        let mut app = app_with(items).await;
        let mut term = terminal(140);
        frame(&mut app, &mut term);
        const FRAMES: usize = 40;
        let (mut wrapped, mut allocs) = (0, 0);
        let start = std::time::Instant::now();
        for k in 0..FRAMES {
            let w = if k % 2 == 0 { 130 } else { 140 };
            term.backend_mut().resize(w, HEIGHT);
            let (n, a) =
                crate::hub::peer_snapshot::thread_allocations(|| frame(&mut app, &mut term));
            wrapped += n;
            allocs += a;
        }
        let ms = start.elapsed().as_secs_f64() * 1000.0 / FRAMES as f64;
        eprintln!(
            "width-change frame, N={items}: {ms:.3} ms, {} allocations, {} items wrapped",
            allocs / FRAMES,
            wrapped / FRAMES
        );
    }
}
