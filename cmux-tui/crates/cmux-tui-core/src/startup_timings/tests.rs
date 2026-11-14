use super::*;

#[test]
fn the_laps_after_ready_go_on_the_line_of_their_start_and_change_no_other_field() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-startup-after-ready-{}-{}",
        std::process::id(),
        unix_now_ms()
    ));
    fs::create_dir_all(&dir).unwrap();
    let mut timings = StartupTimings::start();
    timings.lap("socket.bind");
    let (other, mine) = (timings.to_line(7, 100), timings.to_line(8, 200));
    append_startup_timings(&dir, &other).unwrap();
    append_startup_timings(&dir, &mine).unwrap();
    let laps = serde_json::json!([{"step":"session.restate.part","ms":1.5,"values":12}]);
    assert!(add_after_ready(&dir, 8, 200, &laps).unwrap());
    assert!(!add_after_ready(&dir, 9, 200, &laps).unwrap(), "no line of that start");
    let text = fs::read_to_string(dir.join(STARTUP_TIMINGS_FILE)).unwrap();
    let _ = fs::remove_dir_all(&dir);
    let lines = text
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0], other, "the line of another start does not change");
    assert_eq!(lines[1]["after_ready"], laps);
    assert_eq!(lines[1]["total_ms"], mine["total_ms"]);
    assert_eq!(lines[1]["steps"], mine["steps"]);
}

#[test]
fn absorbed_laps_keep_their_order_and_name_the_untimed_rest() {
    let mut outer = StartupTimings::start();
    outer.lap("socket.bind");
    let mut inner = StartupTimings::start();
    inner.lap("registry.open");
    std::thread::sleep(Duration::from_millis(5));
    outer.absorb(inner, "open.other");
    outer.lap("server.attach");
    let names: Vec<_> = outer.steps().into_iter().map(|(step, _)| step).collect();
    assert_eq!(names, ["socket.bind", "registry.open", "open.other", "server.attach"]);
    let sum: Duration = outer.steps().iter().map(|(_, took)| *took).sum();
    assert!(sum <= outer.total());
    assert!(outer.steps()[2].1 >= Duration::from_millis(5));
}

#[test]
fn the_process_marks_are_the_first_laps() {
    process_mark("process.start");
    std::thread::sleep(Duration::from_millis(5));
    process_mark("process.args");
    let mut timings = StartupTimings::from_process_start("process.server_setup");
    timings.lap("socket.bind");
    let names: Vec<_> = timings.steps().iter().map(|(step, _)| *step).collect();
    assert_eq!(names, ["process.args", "process.server_setup", "socket.bind"]);
    assert!(timings.steps()[0].1 >= Duration::from_millis(5));
    assert!(timings.total() >= Duration::from_millis(5));
    let again = StartupTimings::from_process_start("process.server_setup");
    assert!(again.steps().is_empty(), "the marks are taken once");
}

#[test]
fn the_file_keeps_only_the_latest_starts() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-startup-timings-{}-{}",
        std::process::id(),
        unix_now_ms()
    ));
    fs::create_dir_all(&dir).unwrap();
    for pid in 0..(KEPT_STARTS as u32 + 3) {
        append_startup_timings(&dir, &StartupTimings::start().to_line(pid, 1)).unwrap();
    }
    let text = fs::read_to_string(dir.join(STARTUP_TIMINGS_FILE)).unwrap();
    let _ = fs::remove_dir_all(&dir);
    let pids: Vec<u64> = text
        .lines()
        .map(|line| {
            serde_json::from_str::<serde_json::Value>(line).unwrap()["pid"].as_u64().unwrap()
        })
        .collect();
    assert_eq!(pids.len(), KEPT_STARTS);
    assert_eq!(pids.first(), Some(&3));
    assert_eq!(pids.last(), Some(&(KEPT_STARTS as u64 + 2)));
}
