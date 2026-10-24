//! The sink end to end, in its own process (this test binary): marks off without
//! the variable, then one JSON line per hop with the clock, ids and thread.

#[test]
fn hops_reach_the_file_as_json_lines() {
    let dir = std::env::temp_dir().join(format!("cmux-flow-trace-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (the sink reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    assert!(cmux_flow_trace::enabled());
    cmux_flow_trace::hop("daemon.send", 42, || "00ff".to_string());
    cmux_flow_trace::hop("host.pty.write", 0, || "00ff".to_string());
    assert!(cmux_flow_trace::flush());
    let text =
        std::fs::read_to_string(dir.join(format!("flows-{}.jsonl", std::process::id()))).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(
        lines[0].starts_with("{\"hop\":\"daemon.send\",\"flow\":42,\"terminal\":\"00ff\",\"pid\":"),
        "{}",
        lines[0]
    );
    assert!(lines[1].contains("\"hop\":\"host.pty.write\",\"flow\":0,"), "{}", lines[1]);
    let t = |line: &str| -> u64 {
        line.rsplit("\"t_ns\":").next().unwrap().trim_end_matches('}').parse().unwrap()
    };
    assert!(t(lines[1]) >= t(lines[0]) && t(lines[0]) > 0);
    let _ = std::fs::remove_dir_all(&dir);
}
