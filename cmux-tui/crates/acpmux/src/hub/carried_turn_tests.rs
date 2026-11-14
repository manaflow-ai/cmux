use super::*;

#[test]
fn only_an_answer_that_carried_starts_a_turn() {
    let carried_answer = Ok(json!({
        "stopReason": "end_turn",
        "_meta": {"claude": {"subtype": "success", "carried": {"seq": 2, "promptIds": ["p-a", "p-b"]}}},
    }));
    let want = Carried { seq: 2, prompt_ids: vec!["p-a".into(), "p-b".into()] };
    assert_eq!(carried(&carried_answer), Some(want));
    // Claude's turn that ended with nothing unread, and codex-acp's answers, carry nothing.
    let plain = Ok(json!({"stopReason": "end_turn", "_meta": {"claude": {"subtype": "success"}}}));
    assert_eq!(carried(&plain), None);
    assert_eq!(carried(&Ok(json!({"stopReason": "end_turn"}))), None);
    assert_eq!(carried(&Err(RpcError::internal("agent process closed"))), None);
}

/// A Stop captures the turn, then waits for the writer: if that turn carried on meanwhile,
/// the Stop is for the turn its agent runs now, never for one that started on its own.
#[tokio::test]
async fn a_stop_that_saw_the_turn_before_a_carry_stops_the_carried_turn() {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let set = |t: Option<TurnInfo>| *s.turn.lock().unwrap_or_else(|e| e.into_inner()) = t;
    let one = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
    set(Some(one.clone()));
    let on = |t: &TurnInfo| Hub::carried_on(&s, t).map(|t| t.turn_id);
    assert_eq!(on(&one).as_deref(), Some("t-1"));
    let two = hub.carried_turn(&s, Some(&one), &Carried { seq: 1, prompt_ids: vec![] }).0;
    set(Some(two.clone()));
    let three = hub.carried_turn(&s, Some(&two), &Carried { seq: 2, prompt_ids: vec![] }).0;
    set(Some(three.clone()));
    assert_eq!(on(&one), Some(three.turn_id.clone()), "carried on twice");
    assert_eq!(on(&two), Some(three.turn_id.clone()));
    // A queued prompt's turn started on its own: not the work that Stop saw.
    set(Some(TurnInfo::prompted("test", "next", "t-queued", "p-q", Control::Local)));
    assert_eq!(on(&one), None);
    set(None);
    assert_eq!(on(&one), None);
}

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    (hub, s)
}

#[tokio::test]
async fn a_carried_turn_waits_for_its_own_end_before_turning_unread() {
    let (hub, s) = chat().await;
    s.subagents.lock().unwrap().annotate_live(
        &mut json!({"sessionId": s.id, "update": {
            "sessionUpdate": "subagent_spawned", "subagentSessionId": "background",
            "background": true
        }}),
        true,
    );
    hub.refresh_work_below(&s);
    hub.mark_unread_unless_work_below(&s);
    assert!(!s.meta().unread, "the previous turn still has background work");

    let from = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
    let carried = Carried { seq: 1, prompt_ids: vec![] };
    let (next, continues) = hub.carried_turn(&s, Some(&from), &carried);
    *s.turn.lock().unwrap() = Some(next.clone());
    hub.begin_carried(&s, &from.turn_id, &next, &carried, &continues);
    hub.end_background_subagents(&s);
    assert!(!s.meta().unread, "the carried turn is still running");

    hub.mark_unread_unless_work_below(&s);
    assert!(s.meta().unread, "the carried turn's own end earns its unread dot");
}

/// A steer still waits on a turn many carries back (one steer read per carried turn): its
/// forced Stop still reaches it (`succeeds`), past the successions kept with none waiting.
#[tokio::test]
async fn a_waiting_steer_keeps_its_turns_succession_past_many_carries() {
    let (hub, s) = chat().await;
    s.steer_now.lock().unwrap().waiting.insert("p-old".into(), None);
    let first = TurnInfo::prompted("test", "work", "t-0", "p-0", Control::Local);
    let mut turn = first.clone();
    for seq in 0..(SUCCESSORS_KEPT as u64 + 10) {
        turn = hub.carried_turn(&s, Some(&turn), &Carried { seq, prompt_ids: vec![] }).0;
    }
    assert!(Hub::succeeds(&s, "t-0", &turn.turn_id), "the succession was dropped");
    // Answered: the old successions go.
    let mut now = s.steer_now.lock().unwrap();
    now.waiting.clear();
    trim_successors(&mut now.successors);
    drop(now);
    assert!(!Hub::succeeds(&s, "t-0", &turn.turn_id));
}

/// A Stop of a turn that carried on holds for the carried turn: a connection error there is
/// not continued (`auto_resume.rs`).
#[tokio::test]
async fn a_stop_holds_across_a_carry() {
    let (hub, s) = chat().await;
    let one = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
    *s.turn.lock().unwrap() = Some(one.clone());
    hub.stop_auto_resume(&s);
    let two = hub.carried_turn(&s, Some(&one), &Carried { seq: 1, prompt_ids: vec![] }).0;
    hub.take_turn(&s, "t-1", Some(two.clone()));
    hub.schedule_auto_resume(&s, "t-1", None);
    assert!(hub.stopped_for_test(&s, &two.turn_id), "the Stop did not hold for the next turn");
}

/// A restart reads a carried turn from its record with the line it showed (`prompt_line.rs`),
/// never the envelope of the message it carried; an older record without one, its client's.
#[test]
fn a_carried_turns_record_keeps_the_line_it_showed() {
    let envelope = "[cmux agent message] from coord-deputy (acp:abc)\nMessage id: m1\n---\nMerged #1\n--- end of message m1 ---";
    let mut t = TurnInfo::prompted("cmux", envelope, "t-2", "p-2", Control::Local);
    t.show("coord-deputy: Merged #1");
    let next = NextTurn {
        carried: Carried { seq: 1, prompt_ids: vec!["p-2".into()] },
        next: t,
        continues: Continues::default(),
    };
    let back = NextTurn::from_record(&next.record(Control::Local)).unwrap();
    assert_eq!(back.next.masked_preview, "coord-deputy: Merged #1");
    let old = json!({"turnId": "t-3", "promptId": "p-3", "prompt": "[coord] Fix it", "client": "acpmux-cli#1", "seq": 2});
    assert_eq!(NextTurn::from_record(&old).unwrap().next.masked_preview, "coord: Fix it");
}

#[tokio::test]
async fn trigger_quiet_carry_preserves_verified_origin_across_restart() {
    let (hub, session) = chat().await;
    let mut from = TurnInfo::prompted("trigger", "work", "t-1", "delivery", Control::Local);
    from.trigger = true;
    let carried = Carried { seq: 1, prompt_ids: vec![] };
    let (next, continues) = hub.carried_turn(&session, Some(&from), &carried);
    assert!(next.trigger);
    assert!(continues.trigger);
    let record = NextTurn { carried, next, continues }.record(Control::Local);
    let restored = NextTurn::from_record(&record).unwrap();
    assert!(restored.next.trigger);
    assert!(restored.continues.trigger);
    let old = json!({"turnId":"old", "promptId":"p", "seq":1});
    assert!(!NextTurn::from_record(&old).unwrap().next.trigger);
}

/// A carried turn whose steers were all lane reports runs on reports only: it reports
/// nothing upward (`lane_reports.rs`), as a prompt's turn on reports does. One with any
/// other steer, or with none named, does.
#[tokio::test]
async fn a_carried_turn_on_lane_reports_only_reports_nothing_upward() {
    let (hub, s) = chat().await;
    let sent = |reports| SteerSent {
        client: "test".into(),
        text: "steer".into(),
        line: "steer".into(),
        control: Control::Local,
        needs_withdrawal: false,
        continues: Continues { reports, ..Continues::default() },
    };
    {
        let mut now = s.steer_now.lock().unwrap();
        now.sent.insert("p-r1".into(), sent(true));
        now.sent.insert("p-r2".into(), sent(true));
        now.sent.insert("p-task".into(), sent(false));
    }
    let mut from = TurnInfo::prompted("test", "work", "t-0", "p-0", Control::Local);
    let cases: [(&[&str], bool); 3] =
        [(&["p-r1", "p-r2"], true), (&["p-r1", "p-task"], false), (&[], false)];
    for (seq, (ids, want)) in cases.into_iter().enumerate() {
        let prompt_ids = ids.iter().map(|p| p.to_string()).collect();
        let carried = Carried { seq: seq as u64, prompt_ids };
        let (next, continues) = hub.carried_turn(&s, Some(&from), &carried);
        *s.turn.lock().unwrap() = Some(next.clone());
        hub.begin_carried(&s, &from.turn_id, &next, &carried, &continues);
        let turn = s.meta().turn_count;
        assert_eq!(hub.lane_turn_reports_only(&s.id, turn), want, "{ids:?}");
        from = next;
    }
}

/// A carried turn on a steer a subagent of the lane's parent sent reports to that subagent
/// (`lane_report_subagents.rs`), as a turn its prompt starts does. W5-M, 2026-11-08: a
/// subagent's `send --no-wait` steered into the lane's running turn, Claude Code carried it
/// into a turn of its own, and that turn's report went to the lead's chat.
#[tokio::test]
async fn a_carried_turn_on_a_subagents_steer_reports_to_that_subagent() {
    let (hub, lane) = chat().await;
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(req).await.unwrap();
    hub.lane_link(&parent.id, &lane.id, true);
    let sub = json!({"id": "a6555c4b0123", "type": "general-purpose"});
    let asked = json!({"kind": "session_message", "from": parent.id, "fromSubagent": sub.clone()});
    let sent = |asked| SteerSent {
        client: "test".into(),
        text: "steer".into(),
        line: "steer".into(),
        control: Control::Local,
        needs_withdrawal: false,
        continues: Continues { asked, ..Continues::default() },
    };
    {
        let mut now = lane.steer_now.lock().unwrap();
        now.sent.insert("p-sub".into(), sent(Some(asked)));
        now.sent.insert("p-person".into(), sent(None));
    }
    let mut from = TurnInfo::prompted("test", "work", "t-0", "p-0", Control::Local);
    let cases: [(&[&str], Option<&Value>); 3] =
        [(&["p-sub"], Some(&sub)), (&["p-sub", "p-person"], Some(&sub)), (&[], None)];
    for (seq, (ids, want)) in cases.into_iter().enumerate() {
        let prompt_ids = ids.iter().map(|p| p.to_string()).collect();
        let carried = Carried { seq: seq as u64, prompt_ids };
        let (next, continues) = hub.carried_turn(&lane, Some(&from), &carried);
        *lane.turn.lock().unwrap() = Some(next.clone());
        hub.begin_carried(&lane, &from.turn_id, &next, &carried, &continues);
        let turn = lane.meta().turn_count;
        assert_eq!(hub.lane_turn_subagent(&lane.id, turn).as_ref(), want, "{ids:?}");
        from = next;
    }
}

#[test]
fn a_steer_read_after_a_carry_names_it() {
    let read_after = Ok(json!({"stopReason": "steered", "_meta": {"claude": {"carried": 3}}}));
    assert_eq!(steer_carry(&read_after), Some(3));
    assert_eq!(steer_carry(&Ok(json!({"stopReason": "steered"}))), None);
    // codex-acp answers a steer with the turn's end.
    assert_eq!(steer_carry(&Ok(json!({"stopReason": "end_turn"}))), None);
}
