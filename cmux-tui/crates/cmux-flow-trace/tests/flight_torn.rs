//! The flight recorder under concurrent hops, in its own process so no other test's hops share its ring.

/// Eight threads hop while another dumps over and over: every dumped event is whole (its name is one of the
/// names hopped and its terminal the id that name was hopped with), never a mix of two records.
#[test]
fn concurrent_hops_never_give_a_dump_a_torn_record() {
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let threads: Vec<_> = (0..8)
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut flow = 0;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    cmux_flow_trace::hop("flight.torn.a", flow, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
                    cmux_flow_trace::hop_id("flight.torn.b", flow, &[0xbb; 16]);
                    flow += 1;
                }
            })
        })
        .collect();
    let mut out = [cmux_flow_trace::RecentEvent::EMPTY; cmux_flow_trace::RECENT_EVENTS];
    let mut seen = 0;
    let until = std::time::Instant::now() + std::time::Duration::from_millis(300);
    while std::time::Instant::now() < until {
        let count = cmux_flow_trace::dump_recent(&mut out, None);
        for event in &out[..count] {
            match event.name {
                "flight.torn.a" => assert_eq!(event.terminal(), "a".repeat(32)),
                "flight.torn.b" => assert_eq!(event.terminal(), "b".repeat(32)),
                _ => continue,
            }
            seen += 1;
        }
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for thread in threads {
        thread.join().unwrap();
    }
    assert!(seen > 0, "the dumps saw the hops");
}
