use super::*;

const DAY: u64 = 86_400_000;

fn budget(tag: &str, per_day: u32) -> Budget {
    let dir = std::env::temp_dir().join(format!("supervise-budget-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    Budget::new(dir.join("stops.json"), per_day)
}

#[test]
fn faults_above_the_budget_hold_with_their_causes_and_a_new_day_starts_over() {
    let b = budget("hold", 2);
    let t = 20_000 * DAY + 5;
    assert!(!b.record_at(StopCause::Died("sigkill".into()), t).unwrap().exceeded());
    assert!(!b.record_at(StopCause::SelfStop("74".into()), t + 1).unwrap().exceeded());
    let over = b.record_at(StopCause::NoProgress("60s".into()), t + 2).unwrap();
    match over {
        BudgetState::Exceeded { faults, budget, causes } => {
            assert_eq!((faults, budget), (3, 2));
            assert_eq!(causes.len(), 3);
        }
        other => panic!("not exceeded: {other:?}"),
    }
    // Persisted: another reader sees the same day.
    let again = Budget::new(b.path().to_owned(), 2);
    assert!(again.state_of(&again.today_at(t + 3)).exceeded());
    // The next day starts with nothing.
    assert_eq!(again.today_at(t + DAY).faults, 0);
    let _ = std::fs::remove_dir_all(b.path().parent().unwrap());
}

#[test]
fn updates_and_intentional_stops_never_spend_the_budget() {
    let b = budget("free", 0);
    let t = 20_001 * DAY;
    for i in 0..5 {
        let s = b.record_at(StopCause::Update(format!("v{i}")), t + i).unwrap();
        assert!(!s.exceeded());
        assert!(!b.record_at(StopCause::Intentional("quit".into()), t + i).unwrap().exceeded());
    }
    let ledger = b.today_at(t + 9);
    assert_eq!((ledger.stops, ledger.faults), (10, 0));
    let _ = std::fs::remove_dir_all(b.path().parent().unwrap());
}
