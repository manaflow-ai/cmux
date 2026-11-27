//! A task's cost on its turn's end (`hub/turn_cost.rs`, RFD 0167 row 16): every turn's
//! `turn_result` carries what it cost and the chat's running total, and a watching client has it
//! within a second of the harness's answer (cmuxterm-hq goals/competitive-cost-per-task.md, the
//! `competitive.cost_per_task.shown_after_turn_p95_s` metric).

use super::*;

/// Each turn's cost and the session's total reach the client on the turn's own `turn_result`, at
/// once: over 60 turns, the p95 from the agent's answer leaving it to the client holding the cost
/// is far under the goal's 1 s. Prints a `COST_PER_TASK_RECEIPT` line with the p95 and n.
#[tokio::test]
async fn every_turn_carries_its_cost_and_the_session_total_at_once() {
    let log = std::env::temp_dir().join(format!("acpmux-cost-sent-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([
        (
            "FAKE_USAGE".to_owned(),
            json!({"inputTokens": 1200, "outputTokens": 300, "costUsd": 0.0125}).to_string(),
        ),
        ("FAKE_SENT_LOG".to_owned(), log.to_string_lossy().into_owned()),
    ]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "cost-per-task").await;
    const TURNS: usize = 60;
    let mut received_us = Vec::with_capacity(TURNS);
    let mut ready_us = Vec::with_capacity(TURNS);
    for turn in 1..=TURNS {
        c.send(method::SESSION_PROMPT, prompt(&id, "hi", None)).await;
        let result = c
            .wait_for(method::MUX_EVENT, |p| {
                p["kind"] == "turn_result" && p["msg"].get("taskCostUsd").is_some()
            })
            .await;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
        received_us.push(now.as_micros() as u64);
        let msg = &result["msg"];
        assert_eq!(msg["modelCostUsd"], json!(0.0125), "{msg}");
        assert_eq!(msg["modelCostSource"], "harness", "{msg}");
        assert_eq!(msg["taskCostUsd"], json!(0.0125), "{msg}");
        let total = msg["sessionCostUsd"].as_f64().unwrap();
        assert!((total - 0.0125 * turn as f64).abs() < 1e-6, "turn {turn}: {msg}");
        ready_us.push(msg["costReadyUs"].as_u64().expect("costReadyUs"));
    }
    let sent: Vec<u64> =
        std::fs::read_to_string(&log).unwrap().lines().map(|l| l.trim().parse().unwrap()).collect();
    let _ = std::fs::remove_file(&log);
    assert_eq!(sent.len(), TURNS, "one answer per turn");
    let mut shown: Vec<u64> =
        sent.iter().zip(&received_us).map(|(s, r)| r.saturating_sub(*s)).collect();
    shown.sort_unstable();
    ready_us.sort_unstable();
    let p95 = |v: &[u64]| v[(v.len() * 95).div_ceil(100) - 1];
    let shown_p95_s = p95(&shown) as f64 / 1e6;
    println!(
        "COST_PER_TASK_RECEIPT {}",
        json!({
            "metric": "competitive.cost_per_task.shown_after_turn_p95_s",
            "value": shown_p95_s,
            "n": TURNS,
            "shownAfterTurnMaxS": *shown.last().unwrap() as f64 / 1e6,
            "costReadyP95Us": p95(&ready_us),
        })
    );
    assert!(shown_p95_s <= 1.0, "p95 {shown_p95_s} s over {TURNS} turns: {shown:?}");
}
