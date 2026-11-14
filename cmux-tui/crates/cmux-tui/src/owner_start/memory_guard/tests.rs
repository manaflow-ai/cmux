use super::*;

#[test]
fn each_doubling_alerts_once() {
    let gib = 1u64 << 30;
    let mut guard = MemoryGuard::new(4 * gib);
    assert_eq!(guard.observe(3 * gib), None);
    assert_eq!(guard.observe(4 * gib), Some(4 * gib));
    assert_eq!(guard.observe(5 * gib), None);
    assert_eq!(guard.observe(7 * gib), None);
    assert_eq!(guard.observe(8 * gib), Some(8 * gib));
    // A jump past several doublings is one alert, and the next waits above it.
    assert_eq!(guard.observe(190 * gib), Some(16 * gib));
    assert_eq!(guard.observe(200 * gib), None);
    assert_eq!(guard.observe(256 * gib), Some(256 * gib));
}

#[test]
fn the_memory_log_sits_beside_the_panic_log() {
    let path = memory_log_path(Path::new("/state/owner-panics-main.jsonl"));
    assert_eq!(path, Path::new("/state/owner-memory-main.jsonl"));
}

#[test]
fn a_record_is_a_memory_event_line() {
    let line = record(5 << 30, 4 << 30, Duration::from_secs(600), 1);
    assert_eq!(line["kind"], "memory");
    assert_eq!(line["threshold_bytes"], 4u64 << 30);
    assert!(line["message"].as_str().unwrap().contains("passed 4.0 GiB"));
    assert_eq!(line["test"], false);
}
