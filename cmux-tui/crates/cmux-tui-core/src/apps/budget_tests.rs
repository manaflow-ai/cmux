use super::*;
use serde_json::json;

fn update(id: &str, text: &str) -> Vec<Value> {
    vec![json!({ "op": "update", "id": id, "props": { "text": text } })]
}

/// Sends `per_second` batches a second from `start` for `seconds`,
/// firing flush timers when due. Returns (instant, ops) of each forward
/// and the instant the mount went Slowed and was paused, if it did.
struct Run {
    sent: Vec<(Instant, Vec<Value>)>,
    slowed_at: Option<Instant>,
    paused_at: Option<Instant>,
}

fn drive(budget: &mut MountBudget, start: Instant, per_second: u32, seconds: u32) -> Run {
    let mut run = Run { sent: Vec::new(), slowed_at: None, paused_at: None };
    let mut flush_at: Option<Instant> = None;
    let step = Duration::from_secs(1) / per_second;
    for i in 0..per_second * seconds {
        let now = start + step * i;
        if let Some(at) = flush_at.filter(|at| *at <= now) {
            flush_at = None;
            let out = budget.flush(at);
            if let Some(ops) = out.deliver {
                run.sent.push((at, ops));
            }
            flush_at = flush_at.or(out.flush_at);
        }
        let out = budget.offer(now, update("clock", &i.to_string()));
        if out.changed == Some(Step::Slowed) {
            run.slowed_at.get_or_insert(now);
        }
        if out.pause {
            run.paused_at = Some(now);
            return run;
        }
        if let Some(ops) = out.deliver {
            run.sent.push((now, ops));
        }
        flush_at = flush_at.or(out.flush_at);
    }
    run
}

#[test]
fn a_chatty_mount_is_slowed_within_5_s_then_gets_1_batch_a_second_then_pauses() {
    let start = Instant::now();
    let mut budget = MountBudget::default();
    let run = drive(&mut budget, start, 60, 70);
    let slowed = run.slowed_at.expect("60 batches a second reaches Slowed");
    // Over the rate from its first batch: Slowed 5 s later (one batch of slack).
    let took = slowed.duration_since(start);
    assert!(took >= SLOW_AFTER && took <= SLOW_AFTER + FRAME * 2, "Slowed at {took:?}");
    // Before Slowed: one per frame (60 Hz input is exactly frame rate).
    let before = run.sent.iter().filter(|(at, _)| *at < slowed).count();
    assert!(before >= 290, "forwarded {before} batches before Slowed");
    // Slowed: at most one forward in any second.
    let after: Vec<Instant> =
        run.sent.iter().filter(|(at, _)| *at > slowed).map(|(at, _)| *at).collect();
    assert!(!after.is_empty(), "a Slowed mount still updates");
    for pair in after.windows(2) {
        assert!(pair[1] - pair[0] >= SLOWED_INTERVAL, "{:?} apart", pair[1] - pair[0]);
    }
    // Each coalesced forward is one op: the rewritten row's last value.
    let (_, last) = run.sent.last().expect("forwards");
    assert_eq!(last.len(), 1);
    // Slowed for 60 s pauses the app.
    let paused = run.paused_at.expect("Slowed for 60 s pauses");
    assert_eq!(paused.duration_since(slowed).as_secs(), PAUSE_AFTER_SLOWED.as_secs());
    assert_eq!(budget.step(), Step::Slowed);
}

#[test]
fn a_slowed_mount_back_under_the_rate_for_5_s_is_normal_again() {
    let start = Instant::now();
    let mut budget = MountBudget::default();
    let run = drive(&mut budget, start, 60, 6);
    assert!(run.slowed_at.is_some());
    let calm = start + Duration::from_secs(6);
    let mut changed = None;
    for i in 0..7 {
        let out = budget.offer(calm + Duration::from_secs(i), update("clock", "x"));
        changed = changed.or(out.changed);
    }
    assert_eq!(changed, Some(Step::Normal));
    assert_eq!(budget.step(), Step::Normal);
}

#[test]
fn one_changed_row_under_budget_sends_one_update_op_at_once() {
    let start = Instant::now();
    let mut budget = MountBudget::default();
    for i in 0..20u32 {
        // 5 a second: well under the rate, each a frame or more apart.
        let now = start + Duration::from_millis(200) * i;
        let out = budget.offer(now, update("row-7", &i.to_string()));
        assert_eq!(out.deliver, Some(update("row-7", &i.to_string())));
        assert_eq!((out.flush_at, out.changed, out.pause), (None, None, false));
    }
    assert_eq!((budget.batches_in, budget.batches_out), (20, 20));
}

#[test]
fn two_batches_in_one_frame_forward_once_in_order() {
    let start = Instant::now();
    let mut budget = MountBudget::default();
    assert!(budget.offer(start, update("a", "1")).deliver.is_some());
    let create = json!({ "op": "create", "id": "b", "type": "Text", "props": {} });
    let held = budget.offer(start + Duration::from_millis(2), vec![create.clone()]);
    assert_eq!(held.deliver, None);
    let at = held.flush_at.expect("a flush is armed");
    assert_eq!(at, start + FRAME);
    let again = budget.offer(start + Duration::from_millis(4), update("b", "2"));
    assert_eq!((again.deliver, again.flush_at), (None, None), "one timer for the frame");
    let flushed = budget.flush(at).deliver.expect("the frame forwards");
    assert_eq!(flushed, vec![create, update("b", "2")[0].clone()]);
}

#[test]
fn merged_updates_keep_later_props_and_deletes() {
    let mut pending = Vec::new();
    append(&mut pending, vec![json!({ "op": "update", "id": "n", "props": { "a": 1, "b": 1 } })]);
    append(
        &mut pending,
        vec![json!({ "op": "update", "id": "n", "props": { "b": null, "c": 3 } })],
    );
    append(&mut pending, vec![json!({ "op": "remove", "id": "n" })]);
    append(&mut pending, vec![json!({ "op": "update", "id": "n", "props": { "a": 9 } })]);
    assert_eq!(
        pending,
        vec![
            json!({ "op": "update", "id": "n", "props": { "a": 1, "b": null, "c": 3 } }),
            json!({ "op": "remove", "id": "n" }),
            json!({ "op": "update", "id": "n", "props": { "a": 9 } }),
        ]
    );
}

#[test]
fn three_entry_timeouts_in_60_s_pause_and_older_ones_do_not_count() {
    let start = Instant::now();
    let mut ladder = AppLadder::default();
    assert!(!ladder.entry_timeout(start));
    assert!(!ladder.entry_timeout(start + Duration::from_secs(30)));
    // The first fell out of the window: two in the last 60 s.
    assert!(!ladder.entry_timeout(start + Duration::from_secs(61)));
    assert!(ladder.entry_timeout(start + Duration::from_secs(62)));
    assert_eq!(ladder.paused, Some(PauseCause::Timeouts));
    // Paused once; more timeouts do not pause again.
    assert!(!ladder.entry_timeout(start + Duration::from_secs(63)));
}

#[test]
fn a_memory_kill_after_a_restart_pauses_and_a_healthy_run_forgets_it() {
    let mut ladder = AppLadder::default();
    assert!(!ladder.memory_kill());
    ladder.healthy();
    assert!(!ladder.memory_kill());
    assert!(ladder.memory_kill());
    assert_eq!(ladder.paused, Some(PauseCause::Memory));
}
