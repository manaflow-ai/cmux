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

/// A task's spend burn-rate warnings during its turn (`hub/spend_burn.rs`): usage updates whose
/// cost crosses half, nine tenths and all of the default $10 budget fire a fast burn (that pace
/// spends the budget within the turn), then `budget_50`, `budget_90` and `over_budget`, in that
/// order, each before the turn's `turn_result`, once each, every turn. Over 60 turns the checks'
/// p95 and the cost's shown-after-turn p95 stay small: prints a `SPEND_BURN_RECEIPT` line.
#[tokio::test]
async fn usage_crossing_the_budget_warns_fast_then_50_90_100_in_order() {
    let log = std::env::temp_dir().join(format!("acpmux-burn-sent-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([
        (
            "FAKE_USAGE".to_owned(),
            json!({"inputTokens": 1200, "outputTokens": 300, "costUsd": 10.4}).to_string(),
        ),
        ("FAKE_USAGE_UPDATES".to_owned(), json!([2.6, 5.2, 9.3, 10.4]).to_string()),
        ("FAKE_SENT_LOG".to_owned(), log.to_string_lossy().into_owned()),
    ]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "spend-burn").await;
    const TURNS: usize = 60;
    let mut received_us = Vec::with_capacity(TURNS);
    let mut check_max_ns = Vec::with_capacity(TURNS);
    let mut check_mean_ns = Vec::with_capacity(TURNS);
    let mut fired = 0;
    for turn in 1..=TURNS {
        c.send(method::SESSION_PROMPT, prompt(&id, "hi", None)).await;
        let mut levels = Vec::new();
        let result = loop {
            let p = c
                .wait_for(method::MUX_EVENT, |p| {
                    p["kind"] == "spend_warning"
                        || (p["kind"] == "turn_result" && p["msg"].get("taskCostUsd").is_some())
                })
                .await;
            if p["kind"] == "turn_result" {
                break p;
            }
            let w = &p["msg"];
            assert_eq!(w["budgetUsd"], json!(10.0), "{w}");
            assert!(w["counters"]["warningsFired"].as_u64().unwrap() > fired, "{w}");
            fired = w["counters"]["warningsFired"].as_u64().unwrap();
            levels.push(w["level"].as_str().unwrap().to_owned());
        };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
        received_us.push(now.as_micros() as u64);
        assert_eq!(
            levels,
            ["fast_burn", "budget_50", "budget_90", "over_budget"],
            "turn {turn}: the warnings in order"
        );
        let msg = &result["msg"];
        assert_eq!(msg["spendBurn.checks"], json!(4), "{msg}");
        assert_eq!(msg["spendBurn.warnings"], json!(4), "{msg}");
        assert_eq!(msg["spendBurn.overBudget"], json!(true), "{msg}");
        assert!((msg["spendBurn.spentUsd"].as_f64().unwrap() - 10.4).abs() < 1e-6, "{msg}");
        let ns = |k: &str| (msg[k].as_f64().unwrap() * 1000.0) as u64;
        check_max_ns.push(ns("spendBurn.checkMaxUs"));
        check_mean_ns.push(ns("spendBurn.checkUs") / 4);
    }
    let sent: Vec<u64> =
        std::fs::read_to_string(&log).unwrap().lines().map(|l| l.trim().parse().unwrap()).collect();
    let _ = std::fs::remove_file(&log);
    assert_eq!(sent.len(), TURNS, "one answer per turn");
    let mut shown: Vec<u64> =
        sent.iter().zip(&received_us).map(|(s, r)| r.saturating_sub(*s)).collect();
    shown.sort_unstable();
    check_max_ns.sort_unstable();
    check_mean_ns.sort_unstable();
    let p95 = |v: &[u64]| v[(v.len() * 95).div_ceil(100) - 1];
    let shown_p95_s = p95(&shown) as f64 / 1e6;
    let check_p95_s = p95(&check_max_ns) as f64 / 1e9;
    println!(
        "SPEND_BURN_RECEIPT {}",
        json!({
            "metric": "competitive.cost_per_task.spend_warning_check_p95_s",
            "value": check_p95_s,
            "n": TURNS,
            "checkMeanP95S": p95(&check_mean_ns) as f64 / 1e9,
            "shownAfterTurnP95S": shown_p95_s,
            "warningsFired": fired,
        })
    );
    assert!(check_p95_s <= 0.002, "check p95 {check_p95_s} s: {check_max_ns:?}");
    assert!(shown_p95_s <= 1.0, "p95 {shown_p95_s} s over {TURNS} turns: {shown:?}");
}
