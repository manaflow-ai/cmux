use super::*;

#[test]
fn a_live_tree_reports_each_process_and_the_sum() {
    let mut child = std::process::Command::new("sleep").arg("30").spawn().expect("sleep");
    let own = std::process::id();
    let reply = describe(Some(Some(own)));
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(reply["running"], true);
    assert_eq!(reply["pid"], own);
    let processes = reply["processes"].as_array().expect("processes");
    assert!(processes.iter().any(|p| p["pid"] == own), "the root itself is counted");
    assert!(processes.iter().any(|p| p["pid"] == child.id() && p["ppid"] == own), "and its child");
    let sum: u64 = processes.iter().map(|p| p["memoryBytes"].as_u64().unwrap()).sum();
    assert_eq!(reply["memoryBytes"].as_u64(), Some(sum));
    assert!(sum > 0, "a live process has memory");
}

#[test]
fn no_agent_or_a_held_slot_reports_nothing_measured() {
    let idle = describe(Some(None));
    assert_eq!(idle["running"], false);
    assert_eq!(idle["processes"], json!([]));
    let held = describe(None);
    assert_eq!(held["running"], Value::Null);
    assert_eq!(held["memoryBytes"], 0);
}
