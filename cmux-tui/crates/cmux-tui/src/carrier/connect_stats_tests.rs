use super::*;

fn line(phase: &str, outcome: &str, parked: u64, total: u64) -> String {
    format!(
        "carrier.phases machine=vm_a phase={phase} carrier=relay:0 outcome={outcome} ticket_ms=40 relay_ms=60 parked_ms={parked} handshake_ms=30 mux_ms=5 lanes=1 ms={total}"
    )
}

#[test]
fn reads_the_line_the_dial_writes() {
    // `contract::phases_line`'s format, written out so this test does not pin its signature
    // (cmux#64815 adds the `net=` and `region=` tags at the end).
    let written = "carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=ok ticket_ms=41 relay_ms=62 parked_ms=7 handshake_ms=33 mux_ms=4 lanes=1 ms=150";
    let attempt = parse_line(written).expect("the dial's line parses");
    assert_eq!(attempt.machine, "vm_x");
    assert_eq!(attempt.phase, "connect");
    assert!(attempt.ok);
    assert_eq!(attempt.ms, [41, 62, 7, 33, 4, 150]);
    assert_eq!((attempt.net.as_str(), attempt.region.as_str()), ("-", "-"));
}

#[test]
fn other_lines_and_short_lines_are_skipped() {
    assert_eq!(parse_line("cloud.connect machine=vm_a outcome=ok"), None);
    assert_eq!(
        parse_line("carrier.routes machine=vm_a phase=connect carrier=relay:0 outcome=ok"),
        None
    );
    assert_eq!(parse_line("carrier.phases machine=vm_a phase=connect outcome=ok ms=3"), None);
}

#[test]
fn tags_are_read_when_present() {
    let a =
        parse_line(&format!("{} net=wifi region=us-west", line("connect", "ok", 2, 100))).unwrap();
    assert_eq!((a.net.as_str(), a.region.as_str()), ("wifi", "us-west"));
}

#[test]
fn nearest_rank_percentiles() {
    let values: Vec<u64> = (1..=20).collect();
    assert_eq!(percentile(&values, 50), Some(10));
    assert_eq!(percentile(&values, 95), Some(19));
    assert_eq!(percentile(&[7], 95), Some(7));
    assert_eq!(percentile(&[], 50), None);
}

#[test]
fn splits_warm_from_cold_and_counts_failures() {
    let mut attempts: Vec<Attempt> =
        (1..=10).map(|i| parse_line(&line("connect", "ok", 3, i * 100)).unwrap()).collect();
    attempts.push(parse_line(&line("connect", "relay", 0, 15_000)).unwrap());
    attempts.push(parse_line(&line("connect", "ok", 4_000, 5_000)).unwrap());
    let groups = summarize(&attempts);
    assert_eq!(groups.len(), 2);
    let cold = groups.iter().find(|g| g.start == "cold").unwrap();
    assert_eq!((cold.n, cold.failed), (1, 0));
    assert_eq!(cold.steps[5], Some((5_000, 5_000)));
    let warm = groups.iter().find(|g| g.start == "warm").unwrap();
    assert_eq!((warm.n, warm.failed), (11, 1));
    // The failed attempt's 15 s is not in the percentiles.
    assert_eq!(warm.steps[5], Some((500, 1_000)));
    let json = render_json(&groups);
    assert_eq!(json["groups"][1]["ms"]["total"]["p95"], 1_000);
    assert!(render_text(&groups).contains("500/1000"));
}

#[test]
fn all_failed_has_no_percentiles() {
    let groups = summarize(&[parse_line(&line("reconnect", "handshake", 0, 15_000)).unwrap()]);
    assert_eq!(groups[0].steps, [None; 6]);
    assert!(render_json(&groups)["groups"][0]["ms"]["total"].is_null());
}

#[test]
fn first_byte_counts_with_the_attempt_before_it() {
    let log = [
        line("connect", "relay", 0, 15_000),
        "carrier.first_byte machine=vm_b service=mux ms=999\n".to_owned(),
        line("connect", "ok", 4_000, 5_000),
        "carrier.phases machine=vm_a phase=stream carrier=relay:0 outcome=ok ticket_ms=0 relay_ms=0 parked_ms=0 handshake_ms=0 mux_ms=0 lanes=1 ms=20".to_owned(),
        // The line the dial writes, from `first_byte::line`.
        super::super::first_byte::line("vm_a", "mux", std::time::Duration::from_millis(5_300)),
        "carrier.first_byte machine=vm_a service=mux ms=7000\n".to_owned(),
        line("connect", "ok", 3, 200),
    ]
    .join("\n");
    let attempts = parse_log(&log);
    assert_eq!(attempts.len(), 4);
    // vm_b's line has no attempt; the failed one gets none; the second line on vm_a is not the first.
    assert_eq!(
        attempts.iter().map(|a| a.first_byte).collect::<Vec<_>>(),
        [None, Some(5_300), None, None]
    );
    let groups = summarize(&attempts);
    let cold = groups.iter().find(|g| g.start == "cold").unwrap();
    assert_eq!(cold.first_byte, Some((5_300, 5_300)));
    let warm = groups.iter().find(|g| g.start == "warm" && g.phase == "connect").unwrap();
    assert_eq!(warm.first_byte, None);
    assert_eq!(render_json(&groups)["groups"][0]["first_byte"]["p95"], 5_300);
    assert!(render_text(&groups).contains("5300/5300"));
}

#[test]
fn first_byte_wrapper_fires_once_on_the_first_write() {
    use tokio::io::AsyncWriteExt as _;
    let fired = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = fired.clone();
    let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
    let written = runtime.block_on(async move {
        let mut out = super::super::first_byte::FirstByte::new(
            Vec::<u8>::new(),
            std::time::Instant::now(),
            move |elapsed| seen.lock().unwrap().push(elapsed),
        );
        out.write_all(b"").await.unwrap();
        out.write_all(b"ab").await.unwrap();
        out.write_all(b"cd").await.unwrap();
        out.flush().await.unwrap();
        out.into_inner()
    });
    assert_eq!(written, b"abcd");
    assert_eq!(fired.lock().unwrap().len(), 1);
}
