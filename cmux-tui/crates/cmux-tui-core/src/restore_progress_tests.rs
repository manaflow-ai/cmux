use super::{RestorePhase, RestoreProgress};

#[test]
fn a_new_count_advances_the_restore_and_a_repeated_one_does_not() {
    let progress = RestoreProgress::new();
    progress.enter(RestorePhase::AgentRoster);
    progress.advance(1, Some(10));
    let first = progress.to_json();
    assert_eq!(first["phase"], "agent_roster");
    assert_eq!(first["done"], 1);
    assert_eq!(first["total"], 10);
    std::thread::sleep(std::time::Duration::from_millis(20));
    progress.advance(1, Some(10));
    let stalled = progress.to_json();
    assert_eq!(stalled["last_advance_ms"], first["last_advance_ms"], "{stalled}");
    assert!(stalled["elapsed_ms"].as_u64() >= Some(20), "{stalled}");
    progress.advance(2, Some(10));
    let advanced = progress.to_json();
    assert!(advanced["last_advance_ms"].as_u64() > first["last_advance_ms"].as_u64(), "{advanced}");
    progress.enter(RestorePhase::HostAdoption);
    let next = progress.to_json();
    assert_eq!(next["phase"], "host_adoption");
    assert!(next["done"].is_null() && next["total"].is_null(), "{next}");
}
