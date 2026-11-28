use super::*;

#[test]
fn agent_text_fields_and_names() {
    let f = fields("fanin s=42 k=7 t=1795086515201911");
    assert_eq!((f["s"], f["k"], f["t"]), (42, 7, 1_795_086_515_201_911));
    assert_eq!(name(10, 1), (0, "s00001".to_owned()));
    assert_eq!(name(10, 11), (0, "s00011".to_owned()));
    assert_eq!(name(10, 2000), (9, "s02000".to_owned()));
}

#[test]
fn client_counts_churn_fanout_and_dups() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let h = handler(seen.clone());
    let upd = |text: &str| {
        json!({"method": "session/update", "params": {"sessionId": "x",
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
    };
    h(10, "session/update", &upd("fanin s=3 k=1 t=5"));
    h(11, "session/update", &upd("fanin s=3 k=1 t=5"));
    h(12, "session/update", &upd("fanin-rx s=3 r=2 t=9"));
    h(13, "_acpmux/lagged", &json!({"params": {"dropped": 4}}));
    let s = seen.lock().unwrap();
    assert_eq!(s.churn[&(3, 1)], (10, 2));
    assert_eq!(s.fanout[&(3, 2)], (9, 12, 1));
    assert_eq!(s.lagged, 4);
}

#[test]
fn summary_ratios_against_the_first_ramp() {
    let cfg = Cfg {
        hosts: 2,
        rate: 1.0,
        out: PathBuf::new(),
        bin: PathBuf::new(),
        window_s: 1,
        settle_s: 0,
        latency_ms: 0,
        burst_s: 0,
        fanout_rounds: 0,
        agent_hosts: false,
        attach_workers: 1,
    };
    let t = |n: u64, p95: f64, cpu: f64| {
        json!({"n": n, "attach_ms": {"p95": p95}, "attach_one_ms": {"p95": p95},
        "fanin_ms": {"p95": p95}, "fanout_ms": {"p95": p95},
        "controller": {"cpu_pct_per_session": cpu, "rss_kb_per_session": cpu}})
    };
    let s = summarize(&cfg, &[t(50, 2.0, 0.1), t(2000, 2.2, 0.1)]);
    assert_eq!(s["ratios"][1]["attach_p95"], json!(1.1));
    assert_eq!(s["goal_met_at_2000"], true);
    let s = summarize(&cfg, &[t(50, 2.0, 0.1), t(2000, 5.0, 0.1)]);
    assert_eq!(s["goal_met_at_2000"], false);
}
