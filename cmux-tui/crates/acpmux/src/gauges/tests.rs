use super::*;

#[test]
fn a_phase_reports_its_length_and_a_mark_only_its_first_time() {
    let gauges: &'static Gauges = Box::leak(Box::new(Gauges::new()));
    {
        let _phase = gauges.phase("store load");
        std::thread::sleep(Duration::from_millis(5));
    }
    gauges.mark("socket ready");
    gauges.mark("socket ready");
    let status = gauges.status();
    let phases = status["startup"].as_array().unwrap();
    assert_eq!(phases.len(), 2, "{status}");
    assert_eq!(phases[0]["name"], "store load");
    assert!(phases[0]["ms"].as_u64().unwrap() >= 5, "{status}");
    assert_eq!(phases[1]["name"], "socket ready");
    assert_eq!(phases[1]["ms"], 0);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    assert!(status["memory"]["rssBytes"].as_u64().unwrap() > 0, "{status}");
}
