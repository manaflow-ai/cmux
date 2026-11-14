use super::*;

fn store(tag: &str) -> Store {
    let dir = std::env::temp_dir().join(format!("cmux-watch-unit-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    Store::open(&dir).unwrap()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[test]
fn an_exited_watch_gives_back_its_signal_slot() {
    let store = store("slot");
    let spec = crate::AutomationSpec {
        name: "once".into(),
        trigger: Trigger::Watch { command: "echo hi".into(), debounce_seconds: 1 },
        body: crate::Body::Command { command: "true".into(), folder: None },
        catch_up: crate::CatchUp::default(),
        timeout_seconds: 30,
        enabled: true,
        gate: crate::Gate::default(),
    };
    let a = store.create(spec, 0).unwrap();
    let mut w = Watches::new(store);
    w.reconcile(std::slice::from_ref(&a), now_ms());
    let pid = w.status()[0].pid.unwrap() as libc::pid_t;
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while signals::holds(pid) && std::time::Instant::now() < deadline {
        w.wait(Duration::from_millis(100), &now_ms);
    }
    assert!(!signals::holds(pid), "the exited command's slot is free");
}

#[test]
fn one_pass_takes_a_bounded_number_of_lines() {
    let mut w = Watches::new(store("drain"));
    w.watchers.insert(
        "a".into(),
        Watcher {
            spec: Spec { command: String::new(), folder: None, debounce_ms: 1_000 },
            generation: 1,
            child: None,
            started_ms: 0,
            restart_at_ms: None,
            backoff_ms: FIRST_BACKOFF_MS,
            last_error: None,
        },
    );
    for _ in 0..(MAX_DRAIN + 10) {
        w.tx.send(Msg::Line { id: "a".into(), generation: 1, line: "x".into(), at_ms: 0 }).unwrap();
    }
    w.wait(Duration::ZERO, &|| 0);
    assert_eq!(w.pending["a"].lines, MAX_DRAIN as u64);
}

#[test]
fn a_stream_is_held_at_most_30_seconds_whatever_the_debounce() {
    let mut w = Watches::new(store("hold"));
    w.watchers.insert(
        "a".into(),
        Watcher {
            spec: Spec { command: String::new(), folder: None, debounce_ms: 3_600_000 },
            generation: 1,
            child: None,
            started_ms: 0,
            restart_at_ms: None,
            backoff_ms: FIRST_BACKOFF_MS,
            last_error: None,
        },
    );
    w.add_line("a", "x", 0);
    assert_eq!(w.next_deadline_ms(), Some(MAX_HOLD_MS));
}
