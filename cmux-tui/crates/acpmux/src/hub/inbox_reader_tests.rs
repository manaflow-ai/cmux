//! The inbox reader (`inbox_reader.rs`): what it reads, its answer, the cache, and that no notice
//! ever waits for it.

use super::super::*;
use super::*;
use std::sync::atomic::AtomicUsize;

fn item(prompt_id: &str, thread: &str, class: PromptClass, at: u64, text: &str) -> Item {
    let mut item = Item::carried(prompt_id, "lane-a", text);
    item.thread = thread.to_owned();
    item.class = class;
    item.at = at;
    item.noticed = false;
    item
}

/// When a result that came then steers into a running turn at once: its coalescing window
/// ([`STEER_COALESCE_MS`], cmux#49385) has passed.
fn due_result_at() -> u64 {
    now_ms().saturating_sub(STEER_COALESCE_MS + 1)
}

/// A long status: past the whole-notice bound together with a second one, many lines.
fn long(tag: &str) -> String {
    format!("{tag} status\n{}", "detail line about the build and its tests\n".repeat(120))
}

fn hub_with_chat(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(id).unwrap();
    (hub, session)
}

fn carried(session: &Session) -> Option<Vec<String>> {
    session.inbox().in_flight.as_ref().map(|(_, ids)| {
        let mut ids = ids.clone();
        ids.sort();
        ids
    })
}

/// The chat runs another agent's turn that takes steers: a message that is no FYI steers in at
/// once (`inbox_tests.rs` `running`).
fn running(session: &Session) {
    let turn = TurnInfo::prompted("test", "go", "t-run", "p-run", Control::Local);
    *session.turn.lock().unwrap() = Some(turn);
    session.steering.store(true, Ordering::SeqCst);
}

/// A notice went: it is in flight, or it went and the chat (no agent here) refused it.
fn went(session: &Session) -> bool {
    let inbox = session.inbox();
    inbox.in_flight.is_some() || inbox.refused_at != 0
}

#[test]
fn it_reads_only_long_messages_that_are_no_blocker_and_no_fire() {
    assert!(!wanted(PromptClass::Fyi, false, "one short line"));
    assert!(wanted(PromptClass::Fyi, false, "first\nsecond"));
    assert!(wanted(PromptClass::Result, false, &"x".repeat(PREVIEW_CHARS + 1)));
    assert!(!wanted(PromptClass::Block, false, "first\nsecond"), "a block keeps its words");
    assert!(!wanted(PromptClass::Question, false, "first\nsecond"), "a question keeps its words");
    assert!(!wanted(PromptClass::Fyi, true, "first\nsecond"), "a FIRE keeps its words");
}

#[test]
fn the_answer_is_a_score_and_one_line() {
    let s = parse_read("2|lane-a merged #123; base is green").unwrap();
    assert_eq!(s, Summary { score: 2, line: "lane-a merged #123; base is green".into() });
    assert_eq!(parse_read("Sure:\n3 | needs a review of #9\n").unwrap().score, 3);
    assert!(parse_read("no form here").is_none());
    assert!(parse_read("7|out of range").is_none());
    assert!(parse_read("1|   ").is_none());
    let cut = parse_read(&format!("1|{}", "w ".repeat(400))).unwrap();
    assert!(cut.line.chars().count() <= SUMMARY_CHARS + 1 && cut.line.ends_with('…'));
}

#[test]
fn the_prompt_carries_the_goal_and_the_message_not_a_relay_label() {
    let p = read_prompt(Some("land RFD 0041 slice 4"), "lane-a", "merged #5\nall green");
    assert!(p.contains("Its goal: land RFD 0041 slice 4"));
    assert!(p.contains("merged #5\nall green"));
    assert!(read_prompt(None, "lane-a", "x").contains("(none set)"));
}

#[test]
fn a_summary_takes_the_preview_of_a_thread_with_no_blocker_and_ranks_by_the_goal() {
    let now = now_ms();
    let (a, b) = (long("alpha"), long("beta"));
    let old = item("p-old", "t-old", PromptClass::Fyi, now - 10, &a);
    let new = item("p-new", "t-new", PromptClass::Fyi, now, &b);
    let block = item("p-block", "t-block", PromptClass::Block, now - 20, "stuck\nneed a key");
    let mut summaries = Summaries::new();
    summaries.insert("p-old".into(), Summary { score: 3, line: "alpha needs your review".into() });
    summaries.insert("p-new".into(), Summary { score: 0, line: "beta noise".into() });
    // One the render must not use: a blocker keeps its words.
    summaries.insert("p-block".into(), Summary { score: 3, line: "hidden".into() });
    let (text, parts) = render_read(&[&old, &new, &block], &summaries);
    let lines: Vec<&str> = text.lines().skip(1).collect();
    assert!(lines[0].starts_with("- [blocker]") && lines[0].contains(": stuck"), "{text}");
    assert!(lines[1].contains("(summary) alpha needs your review"), "goal rank first: {text}");
    assert!(lines[2].contains("(summary) beta noise"), "{text}");
    assert!(!text.contains("hidden"));
    assert_eq!(parts[1]["summary"], "alpha needs your review");
    assert_eq!(parts[1]["preview"], "alpha status", "the raw preview stays in the parts");
    // With none, the notice is today's.
    assert_eq!(
        render_read(&[&old, &new, &block], &Summaries::new()),
        render(&[&old, &new, &block])
    );
}

#[test]
fn a_whole_notice_has_no_summaries() {
    let short = item("p-short", "t", PromptClass::Fyi, 1, "one\ntwo");
    let mut summaries = Summaries::new();
    summaries.insert("p-short".into(), Summary { score: 3, line: "s".into() });
    assert_eq!(render_read(&[&short], &summaries), render(&[&short]));
    let (s, jobs) = lookup("reader-unset-chat", &[&short]);
    assert!(s.is_empty() && jobs.is_empty());
}

/// The notice goes at once with the plain previews while the reads run; once they end, a later
/// notice of the same messages (one held back, refused and retried) shows their summaries, and
/// reads no model again.
#[tokio::test]
async fn a_notice_never_waits_and_a_later_one_shows_the_cached_summary() {
    let (hub, session) = hub_with_chat("reader-fast");
    running(&session);
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    set_test_summarizer(
        &session.id,
        Arc::new(move |prompt: String| {
            counted.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(100));
            let tag = if prompt.contains("alpha") { "alpha" } else { "beta" };
            Ok(format!("2|{tag} summarized"))
        }),
    );
    let now = due_result_at();
    session.inbox().items.push(item("f-a", "ta", PromptClass::Fyi, now, &long("alpha")));
    session.inbox().items.push(item("f-b", "tb", PromptClass::Result, now, &long("beta")));
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["f-a".into(), "f-b".into()]), "it went at once");
    let new: Vec<Item> = vec![
        item("f-a", "ta", PromptClass::Fyi, now, &long("alpha")),
        item("f-b", "tb", PromptClass::Result, now, &long("beta")),
    ];
    let refs: Vec<&Item> = new.iter().collect();
    let started = Instant::now();
    loop {
        let (s, jobs) = lookup(&session.id, &refs);
        assert!(jobs.is_empty(), "the notice started both reads");
        if s.len() == 2 {
            assert_eq!(s["f-a"].line, "alpha summarized");
            let (text, _) = render_read(&refs, &s);
            assert!(text.contains("(summary) alpha summarized"), "{text}");
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(3), "reads ended");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(calls.load(Ordering::SeqCst), 2, "the later notice read no model");
}

/// A read that takes 5 s holds no notice up: it goes at once, a steer or a wake alike.
#[tokio::test]
async fn a_slow_reader_holds_no_notice() {
    let (hub, session) = hub_with_chat("reader-slow");
    running(&session);
    set_test_summarizer(
        &session.id,
        Arc::new(|_| {
            std::thread::sleep(Duration::from_secs(5));
            Ok("1|late".into())
        }),
    );
    let now = due_result_at();
    session.inbox().items.push(item("s-a", "ta", PromptClass::Result, now, &long("alpha")));
    hub.inbox_reader_prefetch(
        &session,
        "s-a",
        "lane-a",
        PromptClass::Result,
        false,
        &long("alpha"),
    );
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["s-a".into()]), "it went at once");
}

/// A notice that carries a block, a question or a FIRE never waits for the reader.
#[tokio::test]
async fn a_blocker_never_waits_for_the_reader() {
    for (n, class) in
        [PromptClass::Block, PromptClass::Question, PromptClass::Fyi].into_iter().enumerate()
    {
        let (hub, session) = hub_with_chat(&format!("reader-urgent-{n}"));
        running(&session);
        set_test_summarizer(
            &session.id,
            Arc::new(|_| {
                std::thread::sleep(Duration::from_secs(5));
                Ok("1|late".into())
            }),
        );
        let now = now_ms();
        session.inbox().items.push(item("u-a", "ta", PromptClass::Fyi, now, &long("alpha")));
        let mut urgent = item("u-b", "tb", class, now, &long("beta"));
        urgent.fire = class == PromptClass::Fyi;
        session.inbox().items.push(urgent);
        hub.inbox_review(&session);
        assert_eq!(
            carried(&session),
            Some(vec!["u-a".into(), "u-b".into()]),
            "{class:?} went at once"
        );
    }
}

/// What a notice's render and its lookup cost with and without the reader's summaries: p50 and
/// p95 over 2,000 renders of 12 threads. Manual: `cargo test -p acpmux --release --lib
/// inbox_reader_render_cost -- --ignored --nocapture`.
#[test]
#[ignore]
fn inbox_reader_render_cost() {
    let now = now_ms();
    let items: Vec<Item> = (0..12)
        .map(|i| item(&format!("b-{i}"), &format!("t-{i}"), PromptClass::Fyi, now + i, &long("x")))
        .collect();
    let refs: Vec<&Item> = items.iter().collect();
    let mut summaries = Summaries::new();
    for i in 0..12 {
        summaries
            .insert(format!("b-{i}"), Summary { score: (i % 4) as u8, line: "a summary".into() });
    }
    {
        let mut c = cache();
        for i in 0..12 {
            let s = Summary { score: 1, line: "a summary".into() };
            c.insert(("bench".into(), format!("b-{i}")), Entry::Done(Some(s)));
        }
    }
    set_test_summarizer("bench", Arc::new(|_| Err("unused".into())));
    let time = |f: &dyn Fn()| {
        let mut d: Vec<Duration> = (0..2000)
            .map(|_| {
                let t = Instant::now();
                f();
                t.elapsed()
            })
            .collect();
        d.sort();
        (d[1000].as_secs_f64() * 1e6, d[1900].as_secs_f64() * 1e6)
    };
    let plain = time(&|| {
        std::hint::black_box(render(&refs));
    });
    let read = time(&|| {
        let (s, _) = lookup("bench", &refs);
        std::hint::black_box(render_read(&refs, &s));
    });
    println!(
        "{}",
        json!({"threads": 12, "plain_us": {"p50": plain.0, "p95": plain.1},
               "reader_cached_us": {"p50": read.0, "p95": read.1}})
    );
}

/// The live read through `complete_own` (the `claude` CLI on its small model, its own login):
/// wall time of each read of one real-shaped status message, p50 and p90 over 8. Manual, needs a
/// signed-in `claude` on PATH: `cargo test -p acpmux --lib inbox_reader_live_haiku -- --ignored
/// --nocapture`. Prints timings, the parsed score and an error's code only (never its detail,
/// which carries the CLI's last stderr line).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn inbox_reader_live_haiku() {
    use super::super::super::complete::ModelFallback;
    let profile = crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::ClaudeStdio,
        argv: vec!["claude".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = crate::config::Config::default();
    cfg.harnesses.insert("claude".into(), profile);
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(true);
    hub.finish_startup().await;
    let text = "lane cap status 15:40Z\ngcp-agent-lane-2: 7/8 lanes busy, load 11.2\n\
                gcp-agent-lane-6: 8/8 busy, queue 3 (oldest 6 min)\nhuge-blue: deploys tail clean\n\
                No action unless gcp-agent-lane-6's queue passes 10 min.";
    let mut took = Vec::new();
    for _ in 0..8 {
        let prompt = read_prompt(Some("coordinate the fleet's lanes"), "lane-cap-watch", text);
        let t = Instant::now();
        let answer = hub
            .complete_own(
                Some("claude"),
                prompt,
                MAX_TOKENS,
                READ_TIMEOUT,
                ModelFallback::SmallOnly,
            )
            .await
            .map_err(|e| e.reason().to_owned());
        took.push(t.elapsed());
        let score = answer.as_deref().ok().and_then(parse_read).map(|s| s.score);
        let why = answer.as_ref().err().map(|e| e.chars().take(120).collect::<String>());
        println!(
            "read {:.2} s, ok {}, score {score:?}, error {why:?}",
            took.last().unwrap().as_secs_f64(),
            answer.is_ok()
        );
    }
    took.sort();
    println!(
        "{}",
        json!({"reads": took.len(), "p50_s": took[4].as_secs_f64(), "p90_s": took[7].as_secs_f64()})
    );
}

/// What the coordinator waits for, with and without the reader: the time from a message's
/// coming (as `inbox_accept` takes it: in the thread, the read started, the inbox reviewed) to
/// its notice going, for a reader that answers in `model` (the measured Haiku CLI first token
/// and exit, PR body) and for none. Paths: a steer into a running turn, a wake of an idle chat
/// (its 2 s debounce), and a burst of 50 messages from 50 threads 10 ms apart into each (load:
/// the reader's 2 slots queue). Manual: `cargo test -p acpmux --lib inbox_reader_latency --
/// --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn inbox_reader_latency() {
    let models: [Option<u64>; 5] = [None, Some(100), Some(2240), Some(2870), Some(5090)];
    let mut n = 0;
    for (path, burst) in [("steer", 1), ("wake", 1), ("steer", 50), ("wake", 50)] {
        for model in models {
            let mut took = Vec::new();
            for _ in 0..3 {
                n += 1;
                let (hub, session) = hub_with_chat(&format!("lat-{n}"));
                if path == "steer" {
                    running(&session);
                }
                if let Some(ms) = model {
                    set_test_summarizer(
                        &session.id,
                        Arc::new(move |_| {
                            std::thread::sleep(Duration::from_millis(ms));
                            Ok("2|a summary".into())
                        }),
                    );
                }
                let started = Instant::now();
                for i in 0..burst {
                    let id = format!("m-{i}");
                    // A steer's results come due (`STEER_COALESCE_MS`): this measures the
                    // reader, not the inbox's coalescing window, which is the same either way.
                    let at = if path == "steer" { due_result_at() } else { now_ms() };
                    let mut it = item(&id, &format!("t-{i}"), PromptClass::Result, at, &long("x"));
                    it.from = format!("lane-{i}");
                    it.report = true;
                    let text = it.text.clone();
                    session.inbox().items.push(it);
                    hub.inbox_reader_prefetch(
                        &session,
                        &id,
                        &format!("lane-{i}"),
                        PromptClass::Result,
                        false,
                        &text,
                    );
                    hub.inbox_review(&session);
                    if i + 1 < burst {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                }
                while !went(&session) {
                    assert!(started.elapsed() < Duration::from_secs(10), "no notice");
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                took.push(started.elapsed().as_millis());
            }
            took.sort();
            println!(
                "{}",
                json!({"path": path, "burst": burst,
                       "model_ms": model.map_or(json!("off"), |m| json!(m)),
                       "runs_ms": took, "median_ms": took[1]})
            );
        }
    }
}
