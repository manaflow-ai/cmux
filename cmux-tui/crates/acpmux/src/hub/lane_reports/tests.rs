fn report(turn: u64, prs: &[&str]) -> Report {
    Report {
        content: format!("turn {turn}"),
        prompt_id: format!("p{turn}"),
        name: "lane".into(),
        session: "s".into(),
        turn,
        state: "idle".into(),
        reply: "r".into(),
        prs: prs.iter().map(|p| (*p).to_owned()).collect(),
        shas: vec![],
        for_subagent: None,
        subagent_ended: false,
        interim: false,
        quiet_turns: 0,
    }
}

#[test]
fn a_held_reports_pull_request_goes_with_a_newer_report_the_same_as_the_last() {
    let (now, x) = (WINDOW_MS * 2, "https://github.com/o/r/pull/1");
    // Turn 2's report went; turn 3's, naming X, is held at the cap.
    let mut l = Link { last: Some(report(2, &[]).key()), ..Link::default() };
    l.sent = vec![now; MAX_REPORTS];
    l.ready = Some(report(3, &[x]));
    assert_eq!(due_report(&mut l, now), None);
    // Past the window, turn 4 repeats turn 2's report without X: X still goes.
    let later = now + WINDOW_MS;
    let mut same = report(4, &[]);
    same.content = report(2, &[]).content;
    l.ready = Some(replace_ready(same, l.ready.take()));
    let (got, _) = due_report(&mut l, later).unwrap();
    assert_eq!((got.turn, got.prs), (4, vec![x.to_owned()]));
    // The very same report is dropped.
    let mut l = Link { last: Some(report(2, &[]).key()), ..Link::default() };
    l.ready = Some(report(2, &[]));
    assert_eq!(due_report(&mut l, now), None);
    assert!(l.ready.is_none());
}

#[test]
fn a_repeated_report_naming_a_reported_pull_request_is_dropped() {
    let (now, x) = (WINDOW_MS * 2, "https://github.com/o/r/pull/1");
    let mut l = Link::default();
    // Turn 2 names X; turn 3 says something new and still names X: both go.
    for turn in [2, 3] {
        l.ready = Some(report(turn, &[x]));
        let (got, key) = due_report(&mut l, now).unwrap();
        delivered(&mut l, &got, key, now);
    }
    // Turn 4 repeats turn 3 word for word: nothing new, so nothing goes.
    let mut same = report(4, &[x]);
    same.content = report(3, &[x]).content;
    l.ready = Some(same);
    assert_eq!(due_report(&mut l, now + 1), None);
    assert_eq!(l.sent.len(), 2);
}

#[test]
fn a_newer_report_replaces_a_queued_one_and_keeps_its_pull_requests() {
    let got = replace_ready(report(2, &["pr/2"]), Some(report(1, &["pr/1", "pr/2"])));
    assert_eq!((got.turn, got.prs), (2, vec!["pr/2".to_owned(), "pr/1".to_owned()]));
    assert_eq!(replace_ready(report(1, &[]), None), report(1, &[]));
}

#[test]
fn each_turn_on_reports_only_is_known_on_its_own() {
    let mut k = TurnKinds::default();
    // Two report turns back to back: the second never hides the first.
    k.report_only.insert(("c".into(), 1));
    k.report_only.insert(("c".into(), 2));
    assert!(k.end("c", 1));
    assert!(k.end("c", 2));
    // A task steered in before the turn ends: counted before the end, whenever its own
    // answer comes, so the turn reports.
    k.report_only.insert(("c".into(), 3));
    k.steer_in("c");
    assert!(!k.end("c", 3));
    k.steer_done("c", true, 3);
    assert!(k.in_flight.is_empty());
    // (answered once turn 3, which reported for it, ended: turn 4 does not)
    k.report_only.insert(("c".into(), 4));
    assert!(k.end("c", 4));
    // A steer withdrawn (or that found no turn) is taken back: still reports only.
    k.report_only.insert(("c".into(), 5));
    k.steer_in("c");
    k.steer_done("c", false, 5);
    assert!(k.end("c", 5));
    // A turn not on reports.
    assert!(!k.end("c", 6));
    k.steer_in("c");
    k.forget("c");
    assert!(k.in_flight.is_empty() && k.carried.is_empty() && k.report_only.is_empty());
}

#[test]
fn a_steer_dropped_before_its_answer_is_not_counted_forever() {
    let turns = StdMutex::new(TurnKinds::default());
    // The steer's request is dropped (its client went away) before the agent answers, in
    // turn 1. It may already be with the agent, to be read in turn 1 or the next: both
    // report, and no later one.
    let count = SteerCount::new(&turns, "c", || 1);
    for turn in [1, 2, 3] {
        turns.lock().unwrap().report_only.insert(("c".into(), turn));
    }
    drop(count);
    let mut k = turns.lock().unwrap();
    assert!(k.in_flight.is_empty(), "a dropped steer stays on its way");
    assert!(!k.end("c", 1));
    assert!(!k.end("c", 2), "the next turn, which may have read it, did not report");
    assert!(k.end("c", 3), "every later report turn reports");
    drop(k);
    // Answered, it counts as the answer says.
    SteerCount::new(&turns, "c", || 4).done(false);
    let mut k = turns.lock().unwrap();
    k.report_only.insert(("c".into(), 4));
    assert!(k.end("c", 4));
}

#[test]
fn a_turn_whose_end_runs_after_the_next_turn_ended_keeps_its_steer() {
    let mut k = TurnKinds::default();
    // A task is steered into report turn 1; turn 1's end is held up behind the next turn,
    // which ends first.
    k.report_only.insert(("c".into(), 1));
    k.report_only.insert(("c".into(), 2));
    k.steer_in("c");
    k.steer_done("c", true, 1);
    assert!(k.end("c", 2));
    assert!(!k.end("c", 1), "turn 1's task was lost when turn 2 ended first");
}

#[test]
fn a_steer_answered_after_its_session_was_forgotten_leaves_nothing() {
    let turns = StdMutex::new(TurnKinds::default());
    let answered = SteerCount::new(&turns, "c", || 1);
    let dropped = SteerCount::new(&turns, "c", || 1);
    turns.lock().unwrap().forget("c");
    answered.done(true);
    drop(dropped);
    let k = turns.lock().unwrap();
    assert!(k.in_flight.is_empty() && k.carried.is_empty(), "a retired lane left state");
}

#[test]
fn a_steer_counted_before_a_report_turn_started_still_makes_it_report() {
    let mut k = TurnKinds::default();
    // A task's steer is counted while turn 1 is the count, then the agent takes it into turn
    // 2, a report turn that started meanwhile: turn 2 did a task, so it reports.
    k.steer_in("c");
    k.report_only.insert(("c".into(), 2));
    assert!(!k.end("c", 2), "the task's turn was taken for reports only");
    // Answered after that turn ended, with none running since: the turn it went into
    // already reported, so the next one does not.
    k.steer_done("c", true, 2);
    k.report_only.insert(("c".into(), 3));
    assert!(k.end("c", 3));
}

#[test]
fn a_late_steer_answer_does_not_make_a_later_report_turn_report() {
    let mut k = TurnKinds::default();
    k.steer_in("c");
    // Two report turns end while the steer is on its way: both report, one had it.
    for turn in [1, 2] {
        k.report_only.insert(("c".into(), turn));
        assert!(!k.end("c", turn));
    }
    // Its answer comes after, with turn 2 the last to start: no later report turn is put
    // down to it.
    k.steer_done("c", true, 2);
    k.report_only.insert(("c".into(), 3));
    assert!(k.end("c", 3), "a later report turn reported for a steer it never had");
    // Answered while turn 4 runs, it went into turn 4: that one reports.
    k.steer_in("c");
    k.steer_done("c", true, 4);
    k.report_only.insert(("c".into(), 4));
    assert!(!k.end("c", 4));
}

#[test]
fn a_steer_taken_by_the_next_report_turn_makes_that_turn_report() {
    let mut k = TurnKinds::default();
    // Sent in report turn 1, which ends before the agent reads it (that turn reports, as
    // it may have had it); report turn 2 starts and takes it, answered while it runs.
    k.steer_in("c");
    k.report_only.insert(("c".into(), 1));
    assert!(!k.end("c", 1));
    k.report_only.insert(("c".into(), 2));
    k.steer_done("c", true, 2);
    assert!(!k.end("c", 2), "the turn that did the task was taken for reports only");
    // Answered with turn 2 just started and turn 1 not yet ended: both report.
    k.steer_in("c");
    k.report_only.insert(("c".into(), 3));
    k.report_only.insert(("c".into(), 4));
    k.steer_done("c", true, 4);
    assert!(!k.end("c", 3));
    assert!(!k.end("c", 4));
    k.report_only.insert(("c".into(), 5));
    assert!(k.end("c", 5));
}

#[tokio::test]
async fn a_turn_ending_after_the_next_one_started_ends_its_own_turn() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let lane = hub.new_session(start()).await.unwrap();
    let report = json!({"kind": KIND, "from": "s1"});
    for turn in [1, 2] {
        lane.meta.lock().unwrap().turn_count = turn;
        hub.lane_turn_started(&lane, Some(&report));
    }
    // Report turn 1's end runs after report turn 2 started (its queue woke turn 2 first).
    hub.lane_turn_ended(&lane, true, 1);
    assert!(
        hub.lane_turns().report_only.contains(&(lane.id.clone(), 2)),
        "turn 1's end took turn 2's mark: turn 2 will report"
    );
    hub.lane_turn_ended(&lane, true, 2);
    assert!(hub.lane_turns().report_only.is_empty());
    hub.kill(&lane, true).await.unwrap();
}

#[tokio::test]
async fn a_report_turn_that_failed_to_start_still_reports() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    // A worker's report starts the lane's turn 1, whose agent then fails to start: the lane
    // is stuck, and its parent must hear it.
    lane.meta.lock().unwrap().turn_count = 1;
    hub.lane_turn_started(&lane, Some(&json!({"kind": KIND, "from": "s1"})));
    hub.lane_turn_ended(&lane, false, 1);
    for _ in 0..150 {
        if parent.meta().turn_count > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(parent.meta().turn_count, 1, "the failed start never reached the parent");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

#[test]
fn the_last_reply_is_read_from_the_start_of_its_turn_however_many_records_it_streamed() {
    let rec = |seq: u64, kind: &str| crate::store::EventRecord {
        seq,
        at: 0,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({}),
        host_seq: None,
    };
    // An older turn, then the last turn's start at 10 and 1,000 chunks after it.
    let log: Vec<_> = (1..=1010)
        .map(|s| rec(s, if s == 3 || s == 10 { "turn_started" } else { "chunk" }))
        .collect();
    let page = |before: u64| -> Result<EventPage> {
        let below: Vec<_> = log.iter().filter(|r| r.seq < before).cloned().collect();
        let from = below.len().saturating_sub(TAIL_RECORDS);
        Ok(EventPage { has_more: from > 0, events: below[from..].to_vec() })
    };
    let (got, whole) = last_turn_records(1010, page).unwrap();
    assert!(whole);
    assert_eq!(got.first().map(|r| r.seq), Some(10));
    assert_eq!(got.len(), 1001);
    assert!(got.windows(2).all(|w| w[0].seq + 1 == w[1].seq));
}

#[test]
fn a_turn_longer_than_the_pages_read_says_its_reply_is_cut() {
    let rec = |seq: u64, kind: &str| crate::store::EventRecord {
        seq,
        at: 0,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({}),
        host_seq: None,
    };
    // The turn's start lies further back than every page read.
    let n = (TAIL_RECORDS * MAX_TAIL_PAGES) as u64 + 100;
    let log: Vec<_> =
        (1..=n).map(|s| rec(s, if s == 1 { "turn_started" } else { "chunk" })).collect();
    let page = |before: u64| -> Result<EventPage> {
        let below: Vec<_> = log.iter().filter(|r| r.seq < before).cloned().collect();
        let from = below.len().saturating_sub(TAIL_RECORDS);
        Ok(EventPage { has_more: from > 0, events: below[from..].to_vec() })
    };
    let (got, whole) = last_turn_records(n, page).unwrap();
    assert!(!whole, "a scan that stopped short of turn_started reads as the whole turn");
    assert_eq!(got.len(), TAIL_RECORDS * MAX_TAIL_PAGES);
    assert_eq!(cut_reply("its end".into(), whole), format!("{CUT_NOTE}its end"));
    assert_eq!(cut_reply("all of it".into(), true), "all of it");
}

#[test]
fn a_turn_with_no_reply_never_reads_the_turn_befores_through_the_transcript_filter() {
    let mux = |seq: u64, kind: &str| crate::store::EventRecord {
        seq,
        at: 0,
        dir: "mux".into(),
        kind: kind.into(),
        msg: json!({}),
        host_seq: None,
    };
    let reply = |seq: u64, text: &str| crate::store::EventRecord {
        seq,
        at: 0,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a",
                "update": {"sessionUpdate": "agent_message_chunk",
                           "content": {"type": "text", "text": text}}}}),
        host_seq: None,
    };
    // Turn 1 replies; turn 2 ends with no reply of its own.
    let log = [
        mux(1, "turn_started"),
        reply(2, "turn one's reply"),
        mux(3, "turn_result"),
        mux(4, "turn_started"),
        mux(5, "turn_result"),
    ];
    // What `lane_last_reply` reads: the transcript filter, newest pages first.
    let filter = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
    let read = |last_seq: u64| {
        let page = |before: u64| -> Result<EventPage> {
            let events: Vec<_> =
                log.iter().filter(|r| r.seq < before && filter.matches(r)).cloned().collect();
            Ok(EventPage { has_more: false, events })
        };
        let (records, _) = last_turn_records(last_seq, page).unwrap();
        let events: Vec<Value> = records
            .into_iter()
            .map(|r| json!({"seq": r.seq, "dir": r.dir, "kind": r.kind, "msg": r.msg}))
            .collect();
        last_reply(&events)
    };
    assert_eq!(read(3).as_deref(), Some("turn one's reply"));
    assert_eq!(read(5), None);
}

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn queued_report(lane: &str) -> Report {
    Report {
        content: "idle\nlast words".into(),
        prompt_id: format!("{PROMPT_PREFIX}test"),
        name: "lane".into(),
        session: lane.to_owned(),
        turn: 1,
        state: "idle".into(),
        reply: "last words".into(),
        prs: vec![],
        shas: vec![],
        for_subagent: None,
        subagent_ended: false,
        interim: false,
        quiet_turns: 0,
    }
}

#[test]
fn a_transcript_that_does_not_read_says_so_instead_of_no_reply() {
    assert_eq!(reply_of(Ok(Some("done".into()))), "done");
    assert_eq!(reply_of(Ok(None)), "");
    let got = reply_of(Err(anyhow::anyhow!("page 3 failed")));
    assert!(got.contains("did not read") && got.contains("page 3 failed"), "{got}");
}

#[tokio::test]
async fn a_report_held_at_the_cap_goes_when_the_window_frees_a_place() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    // The cap is full, its oldest report leaving the window in 300 ms; the lane never ends
    // another turn.
    let oldest = now_ms() - WINDOW_MS + 300;
    hub.lane_links(|l| {
        let l = l.get_mut(&lane.id).unwrap();
        l.sent = vec![oldest; MAX_REPORTS];
        l.ready = Some(queued_report(&lane.id));
    });
    hub.lane_deliver_ready(&lane.id).await;
    assert_eq!(parent.meta().turn_count, 0, "the report went past the cap");
    for _ in 0..150 {
        if parent.meta().turn_count > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(parent.meta().turn_count, 1, "the held report never went");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

#[tokio::test]
async fn a_report_counts_toward_the_cap_from_when_the_parent_took_it() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
    // Taken a minute before the parent accepts it (its admission waited).
    let taken = now_ms() - 60_000;
    let due = hub.lane_take_due(&lane.id, taken).unwrap();
    let before = now_ms();
    hub.lane_hand_over(&lane.id, due).await;
    let sent = hub.lane_links(|l| l.get(&lane.id).map(|l| l.sent.clone())).unwrap();
    assert_eq!(sent.len(), 1);
    assert!(sent[0] >= before, "counted from when it was taken, not accepted: {sent:?}");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

#[tokio::test]
async fn a_parent_that_starts_closing_after_the_link_check_takes_no_report() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
    let now = now_ms();
    let due = hub.lane_take_due(&lane.id, now).unwrap();
    // The parent's close has begun (`kill` marks it closing, then closes it) but has not
    // retired its links yet: the link check passes, the parent must still refuse it.
    parent.closing.store(true, Ordering::SeqCst);
    hub.set_status(&parent, SessionStatus::Closed);
    hub.lane_hand_over(&lane.id, due).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(parent.meta().turn_count, 0, "the closing parent took the report");
    assert_eq!(parent.status(), SessionStatus::Closed, "the report reopened the parent");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

/// A report that comes once a shutdown began (a lane turn Quit Everything cut ends, and its
/// report reaches an idle parent the shutdown has not ended yet) starts no turn: no agent may
/// start from then on, and the parent's log takes no prompt it never ran.
#[tokio::test]
async fn an_idle_parent_takes_no_report_once_the_shutdown_began() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
    let due = hub.lane_take_due(&lane.id, now_ms()).unwrap();
    hub.begin_shutdown();
    hub.lane_hand_over(&lane.id, due).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(parent.meta().turn_count, 0, "a report went in once the shutdown began");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

#[tokio::test]
async fn a_report_queued_behind_a_busy_parent_that_then_closes_never_runs() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    let (h, p) = (hub.clone(), parent.clone());
    let blocks = vec![json!({"type": "text", "text": "until-cancel"})];
    let busy = tokio::spawn(async move {
        h.prompt_with(&p, blocks, "test", false, PromptOptions::default()).await
    });
    for _ in 0..100 {
        if parent.turn().is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(parent.turn().is_some(), "the parent's turn never started");
    // The report queues behind the parent's turn; then the parent closes.
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
    let now = now_ms();
    let due = hub.lane_take_due(&lane.id, now).unwrap();
    hub.lane_hand_over(&lane.id, due).await;
    for _ in 0..100 {
        if parent.queued() > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(parent.queued(), 1, "the report never queued behind the parent's turn");
    // A lane's report is a result (`prompt_class.rs`): it never wakes a coordinator by itself.
    let class = parent.queue().first().and_then(|q| q.run.class);
    assert_eq!(class, Some(crate::prompt_class::PromptClass::Result));
    let turns = parent.meta().turn_count;
    hub.kill(&parent, false).await.unwrap();
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), busy).await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    assert_eq!(parent.meta().turn_count, turns, "the queued report ran after the close");
    assert!(parent.child.lock().await.is_none(), "the report started the parent's agent again");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

/// Quit Everything (`_acpmux/shutdown endAgents`) ends the parent with its lanes, and no
/// agent may start once the shutdown has begun: a lane's turn it cancels reports nothing.
#[tokio::test]
async fn a_lane_turn_quit_everything_cancels_reports_nothing() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    let (h, l) = (hub.clone(), lane.clone());
    let blocks = vec![json!({"type": "text", "text": "until-cancel"})];
    let run = tokio::spawn(async move {
        h.prompt_with(&l, blocks, "test", false, PromptOptions::default()).await
    });
    for _ in 0..100 {
        if lane.turn().is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(lane.turn().is_some(), "the lane's turn never started");
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), run).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(parent.meta().turn_count, 0, "a report went in during the shutdown");
    assert!(hub.lane_links(|l| l.get(&lane.id).is_none_or(|l| l.ready.is_none())));
}

#[tokio::test]
async fn a_report_taken_for_a_lane_that_closes_before_it_goes_never_reaches_the_parent() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    let queued = Report {
        content: "idle\nlast words".into(),
        prompt_id: format!("{PROMPT_PREFIX}test"),
        name: "lane".into(),
        session: lane.id.clone(),
        turn: 1,
        state: "idle".into(),
        reply: "last words".into(),
        prs: vec![],
        shas: vec![],
        for_subagent: None,
        subagent_ended: false,
        interim: false,
        quiet_turns: 0,
    };
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued));
    // The report is taken; the lane closes (its link retired) before it is handed over.
    let now = now_ms();
    let due = hub.lane_take_due(&lane.id, now).unwrap();
    hub.kill(&lane, true).await.unwrap();
    hub.lane_hand_over(&lane.id, due).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(parent.meta().turn_count, 0, "the closed lane's report went in");
    hub.kill(&parent, true).await.unwrap();
}

#[tokio::test]
async fn a_parent_that_closed_while_its_lane_started_is_never_linked() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let child = hub.new_session(start()).await.unwrap();
    // The parent closes after `session/new` read it and before the link goes in.
    hub.kill(&parent, false).await.unwrap();
    hub.lane_link(&parent.id, &child.id, false);
    assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
    // A child that closed after `lane_link` read it and before the link went in is not
    // linked again: its close retired its links already.
    let closing = hub.new_session(start()).await.unwrap();
    let open_parent = hub.new_session(start()).await.unwrap();
    hub.kill(&closing, false).await.unwrap();
    hub.lane_link(&open_parent.id, &closing.id, false);
    assert!(!hub.lane_links(|l| l.contains_key(&closing.id)));
    hub.kill(&closing, true).await.unwrap();
    hub.kill(&open_parent, true).await.unwrap();
    // An open parent is linked.
    let open = hub.new_session(start()).await.unwrap();
    hub.lane_link(&open.id, &child.id, false);
    assert!(hub.lane_links(|l| l.get(&child.id).is_some_and(|l| l.parent == open.id)));
    // Its parent closing retires it; a child is never linked under its own descendant.
    hub.kill(&open, false).await.unwrap();
    assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
    let grandchild = hub.new_session(start()).await.unwrap();
    hub.lane_link(&child.id, &grandchild.id, false);
    hub.lane_link(&grandchild.id, &child.id, false);
    assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
    hub.kill(&grandchild, true).await.unwrap();
    for s in [&child, &open] {
        hub.kill(s, true).await.unwrap();
    }
    hub.kill(&parent, true).await.unwrap();
}

use super::*;

#[test]
fn a_turn_on_reports_only_is_known_by_its_provenance() {
    let report = json!({"kind": "lane_report", "from": "s1"});
    let task = json!({"kind": "session_message", "from": "s2"});
    assert!(reports_only(Some(&report)));
    assert!(!reports_only(Some(&task)));
    assert!(!reports_only(None));
    let digest = |kinds: &[&Value]| {
        let m: Vec<Value> = kinds.iter().map(|p| json!({"provenance": p})).collect();
        json!({"kind": "agent_digest", "messages": m})
    };
    assert!(reports_only(Some(&digest(&[&report, &report]))));
    assert!(!reports_only(Some(&digest(&[&report, &task]))));
}

#[test]
fn the_state_names_what_the_lane_waits_on() {
    assert_eq!(state(&json!({"status": "ready"})), "idle");
    assert_eq!(state(&json!({"status": "running"})), "working on its next prompt");
    assert_eq!(
        state(
            &json!({"status": "waiting", "waitingOn": "question", "waitingPrompt": "Which base?"})
        ),
        "waiting on a question: Which base?"
    );
    assert_eq!(
        state(&json!({"status": "waiting", "waitingOn": "permission"})),
        "waiting on a permission"
    );
    assert_eq!(
        state(
            &json!({"status": "ready", "queuePaused": true, "lastTurn": {"status": "failed", "errorText": "agent process closed"}})
        ),
        "blocked: agent process closed; its queue is paused"
    );
    assert_eq!(state(&json!({"status": "disconnected"})), "blocked: its agent stopped");
}

#[test]
fn a_lane_with_a_prompt_queued_is_working_not_idle() {
    let between = json!({"status": "ready", "queued": 1});
    assert_eq!(state(&between), "working on its next prompt");
    // A paused queue holds its prompts: blocked, not working.
    let paused = json!({"status": "ready", "queued": 1, "queuePaused": true});
    assert_eq!(state(&paused), "blocked: its queue is paused");
}

#[test]
fn a_reply_that_only_says_it_still_waits_is_no_news() {
    for quiet in [
        "Still waiting on fleet run 42549646257; nothing new.",
        "Nothing new yet: the compile check is still running on the pool.",
        "Still waiting on https://github.com/o/r/pull/9; 4 min in.",
    ] {
        assert!(says_only_waiting(quiet), "{quiet:?} read as news");
    }
    for news in [
        "Fleet run passed; merged.",
        "The compile check passed.",
        "The compile check failed on linux-arm.",
        "Blocked: the mirror refuses the push.",
        "Done. Opened https://github.com/manaflow-ai/cmux/pull/1",
        "Should I rebase onto feat first?",
        "Pushed 0123456789abcdef0123456789abcdef01234567, still waiting on CI.",
        "It needs your approval to post the review.",
        "Please rebase the branch before I continue.",
        "The deployment timed out; please restart it.",
        "Still waiting, but the deployment timed out; please restart it.",
        "The preview is up at http://localhost:3000.",
        "Still waiting for you to upload the credentials.",
        "Still waiting on your answer about the schema.",
        "Waiting for permission to push to the mirror.",
        "Still waiting on fleet. Stop the rollout.",
        "Still waiting on fleet, stop the rollout.",
        "Still waiting on fleet stop the rollout.",
        "Still waiting on the fleet run and then I will delete the old branch.",
        "Waiting on Sam to merge the schema change.",
        "Still waiting on the fleet run.\nThe staging deploy looks wrong to me.",
        "",
    ] {
        assert!(!says_only_waiting(news), "{news:?} read as no news");
    }
}

#[test]
fn a_still_waiting_report_is_held_and_folded_into_the_next() {
    let waiting = |turn| Report { interim: true, ..report(turn, &[]) };
    let mut l = Link { ready: Some(waiting(1)), ..Link::default() };
    assert!(due_report(&mut l, 1).is_none(), "a still-waiting report went");
    assert!(l.ready.is_some(), "a held report was dropped");
    // Two more still-waiting turns replace it, then a real one replaces them all.
    for turn in [2, 3] {
        l.ready = Some(replace_ready(waiting(turn), l.ready.take()));
        assert!(due_report(&mut l, 1).is_none());
    }
    l.ready = Some(replace_ready(report(4, &[]), l.ready.take()));
    let (due, _) = due_report(&mut l, 1).expect("the real report was held");
    assert_eq!((due.turn, due.quiet_turns), (4, 3));
    assert!(due.text().contains("3 turns before this one only said it was still waiting"));
    // A still-waiting turn never replaces news still queued.
    let kept = replace_ready(waiting(5), Some(report(4, &[])));
    assert_eq!((kept.turn, kept.interim), (4, false));
    // One naming a new pull request is news; one naming only a reported one is not (F3).
    let pr = "https://github.com/o/r/pull/9";
    let mut l =
        Link { ready: Some(Report { interim: true, ..report(6, &[pr]) }), ..Link::default() };
    assert!(due_report(&mut l, 1).is_some(), "a new pull request was held");
    l.prs = vec![pr.into()];
    assert!(due_report(&mut l, 1).is_none(), "a reported pull request made it news");
    // A still-waiting turn naming a pull request the queued news does not replaces it as
    // news, under its own turn (F2); one naming none leaves the news queued.
    let kept = replace_ready(Report { interim: true, ..report(7, &[pr]) }, Some(report(4, &[])));
    assert_eq!(
        (kept.turn, kept.interim, kept.prs.as_slice()),
        (7, false, [pr.to_owned()].as_slice())
    );
    let kept = replace_ready(Report { interim: true, ..report(8, &[]) }, Some(report(4, &[])));
    assert_eq!((kept.turn, kept.interim), (4, false));
    // ...nor one naming only a pull request an earlier report named (review at e8aeb72, F2).
    let waiting_old = Report { interim: true, ..report(9, &[pr]) };
    let kept = replace_ready_seen(waiting_old, Some(report(4, &[])), &[pr.to_owned()]);
    assert_eq!((kept.turn, kept.interim), (4, false));
    // News on its way when a still-waiting turn adds a pull request: its delivery leaves the
    // added one queued, and that goes next.
    let mut l = Link { ready: Some(report(4, &[])), ..Link::default() };
    let (going, key) = due_report(&mut l, 1).expect("the news was held");
    let waiting_pr = Report { interim: true, ..report(5, &[pr]) };
    l.ready = Some(replace_ready(waiting_pr, l.ready.take()));
    delivered(&mut l, &going, key, 1);
    let (next, _) = due_report(&mut l, 2).expect("the added pull request was dropped");
    assert_eq!(next.prs, [pr.to_owned()]);
}

/// A still-waiting report nothing replaces still reaches the parent (review of #39105, F1:
/// a dev server never ends, so no turn follows it).
#[tokio::test]
async fn a_still_waiting_report_nothing_replaces_goes_once_held_long_enough() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    let held = Report { interim: true, ..queued_report(&lane.id) };
    hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(held));
    hub.lane_deliver_ready(&lane.id).await;
    assert!(
        hub.lane_links(|l| l.get(&lane.id).is_some_and(|l| l.ready.is_some())),
        "the held report went or was lost"
    );
    // Its delivery armed the 15-minute timer; the test's runs out in 50 ms instead.
    let armed = hub.lane_links(|l| l.get_mut(&lane.id).and_then(|l| l.held.take()));
    armed.expect("a held report armed no timer").1.abort();
    hub.lane_release_waiting_at(&lane.id, 50);
    for _ in 0..250 {
        if parent.meta().turn_count > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(parent.meta().turn_count, 1, "a held report nothing replaced never went");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}

/// One turn of `lane` that replied `reply`, written to its log the way a turn is, then ended.
fn lane_turn(hub: &Arc<Hub>, lane: &Arc<Session>, turn: u64, reply: &str) {
    lane.meta.lock().unwrap().turn_count = turn;
    hub.append(lane, "mux", "turn_started", json!({}));
    let update = json!({"sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": reply}});
    let msg = json!({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": lane.id, "update": update}});
    hub.append(lane, "in", "agent_message_chunk", msg);
    hub.append(lane, "mux", "turn_result", json!({}));
    hub.lane_turn_ended(lane, true, turn);
}

/// Replays the helper run of 2026-11-09 (Leo: "for stuff like this, are you able to simply
/// not respond?"): a lane waits on a fleet run it started in the background and ends 15
/// turns in a row saying it still waits, then one saying it merged. The idle coordinator
/// above it wakes once, for the merge. Before this change it woke for every one of them.
#[cfg(unix)]
#[tokio::test]
async fn a_lane_still_waiting_on_its_own_work_wakes_its_idle_parent_once_at_the_end() {
    let hub = test_hub();
    let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(start()).await.unwrap();
    let lane = hub.new_session(start()).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, false);
    // Wait for a lane's delivery to settle: the parent took a turn for it and is idle again,
    // or nothing is on its way.
    let settle = |before: u64| {
        let (hub, parent, lane) = (hub.clone(), parent.clone(), lane.clone());
        async move {
            for _ in 0..250 {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                let woke = parent.meta().turn_count > before && parent.turn().is_none();
                let quiet = !hub.lane_inflight().contains_key(&lane.id)
                    && parent.queued() == 0
                    && parent.turn().is_none()
                    && hub.lane_links(|l| l.get(&lane.id).is_some_and(|l| l.ready.is_some()));
                if woke || quiet {
                    return;
                }
            }
        }
    };
    // The lane's fleet run runs past its turns as a daemon task that brings its end to it.
    let run = hub.bg_fake_running(&lane, true).unwrap();
    for turn in 1..=15 {
        let before = parent.meta().turn_count;
        let minutes = turn * 2;
        lane_turn(&hub, &lane, turn, &format!("Still waiting on fleet run; {minutes} min in."));
        settle(before).await;
    }
    let waiting_wakes = parent.meta().turn_count;
    // The run ends; the lane's next turn says it merged.
    drop(run);
    let before = parent.meta().turn_count;
    lane_turn(&hub, &lane, 16, "Fleet run passed and the pull request merged.");
    settle(before).await;
    let wakes = parent.meta().turn_count;
    eprintln!("parent wakeups: {wakes} for 16 lane turns ({waiting_wakes} while it waited)");
    assert_eq!(waiting_wakes, 0, "still-waiting turns woke the idle parent");
    assert_eq!(wakes, 1, "the merge never reached the parent");
    for s in [&lane, &parent] {
        hub.kill(s, true).await.unwrap();
    }
}
