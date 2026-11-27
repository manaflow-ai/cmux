use super::*;

fn book() -> Vec<(String, String)> {
    vec![
        ("a".repeat(44), "gcp-agent-lane-10".to_owned()),
        ("b".repeat(44), "twice".to_owned()),
        ("b".repeat(44), "twice-again".to_owned()),
        ("c".repeat(44), "../etc".to_owned()),
    ]
}

#[test]
fn a_listed_machine_reaches_its_own_socket_beside_the_brokers() {
    let got = admit(Some("/srv/broker/broker.sock"), &book(), &"a".repeat(44)).unwrap();
    assert_eq!(got, PathBuf::from("/srv/broker/client-gcp-agent-lane-10.sock"));
}

#[test]
fn no_configured_broker_is_off() {
    let refused = admit(None, &book(), &"a".repeat(44)).unwrap_err();
    assert_eq!(refused.reason, "service.off");
}

#[test]
fn an_unlisted_twice_listed_or_odd_name_is_refused() {
    for from in ["z".repeat(44), "b".repeat(44), "c".repeat(44)] {
        let refused = admit(Some("/srv/broker.sock"), &book(), &from).unwrap_err();
        assert_eq!(refused.reason, "service.unknown_machine", "{from}");
    }
}

#[test]
fn a_relative_broker_socket_is_misconfigured() {
    let refused = admit(Some("broker.sock"), &book(), &"a".repeat(44)).unwrap_err();
    assert_eq!(refused.reason, "service.misconfigured");
}

// ---- the per-caller budget ----

fn small() -> Limits {
    Limits {
        cheap_slots: 4,
        bulk_slots: 2,
        caller_cheap_inflight: 4,
        caller_bulk_inflight: 2,
        caller_cheap_per_min: 100,
        caller_bulk_per_min: 100,
    }
}

#[test]
fn pings_and_reads_are_cheap_and_everything_else_is_bulk() {
    let cheap = [
        r#"{"op":"ping","check_push":false}"#,
        r#"{"op":"call","tool":"get","repo":"a/b","lane":"x","args":{}}"#,
        r#"{"op":"call","tool":"ci_status","lane":"x"}"#,
        r#"{"op":"call","tool":"ci_wait","lane":"x"}"#,
    ];
    for line in cheap {
        assert_eq!(classify(line.as_bytes()).cost, Cost::Cheap, "{line}");
    }
    let bulk = [
        r#"{"op":"call","tool":"push","lane":"x"}"#,
        r#"{"op":"call","tool":"ci","lane":"x"}"#,
        r#"{"op":"call","tool":"land","lane":"x"}"#,
        r#"{"op":"call","tool":"never_heard_of_it","lane":"x"}"#,
        r#"{"op":"fetch"}"#,
        r#"{"op":"call"}"#,
        "not json",
        "",
    ];
    for line in bulk {
        assert_eq!(classify(line.as_bytes()).cost, Cost::Bulk, "{line}");
    }
}

#[test]
fn the_caller_key_is_the_lane_field_and_empty_when_absent() {
    assert_eq!(classify(br#"{"op":"ping","lane":"lane-7"}"#).lane, "lane-7");
    assert_eq!(classify(br#"{"op":"ping"}"#).lane, "");
    assert_eq!(classify(br#"{"op":"ping","lane":5}"#).lane, "");
}

#[test]
fn one_lane_cannot_take_more_than_its_share_of_a_machines_bulk_slots() {
    let budget = Budget::new(small());
    let now = Instant::now();
    let a1 = budget.admit("m", "a", Cost::Bulk, now).unwrap();
    let _a2 = budget.admit("m", "a", Cost::Bulk, now).unwrap();
    let refused = budget.admit("m", "a", Cost::Bulk, now).unwrap_err();
    assert_eq!(refused.why, Refused::CallerInflight);
    // Lane b still gets a slot of the machine's two... until they are all held.
    let _b = budget.admit("m", "b", Cost::Bulk, now);
    assert_eq!(budget.admit("m", "c", Cost::Bulk, now).unwrap_err().why, Refused::MachineSlots);
    // Another machine has slots of its own.
    assert!(budget.admit("other", "a", Cost::Bulk, now).is_ok());
    drop(a1);
    assert!(budget.admit("m", "a", Cost::Bulk, now).is_ok());
}

#[test]
fn a_caller_over_its_minute_waits_for_its_oldest_call_to_age_out() {
    let budget = Budget::new(Limits { caller_bulk_per_min: 2, ..small() });
    let t0 = Instant::now();
    drop(budget.admit("m", "a", Cost::Bulk, t0).unwrap());
    drop(budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(10)).unwrap());
    let busy = budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(20)).unwrap_err();
    assert_eq!(busy.why, Refused::CallerRate);
    assert_eq!(busy.retry_after_s, 40);
    // Another lane is not spent, and the first call ages out of the window at 60 s.
    assert!(budget.admit("m", "b", Cost::Bulk, t0 + Duration::from_secs(20)).is_ok());
    assert!(budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(61)).is_ok());
}

#[test]
fn cheap_calls_have_slots_bulk_calls_cannot_take() {
    let budget = Budget::new(small());
    let now = Instant::now();
    let _held: Vec<_> =
        (0..2).map(|i| budget.admit("m", &format!("l{i}"), Cost::Bulk, now).unwrap()).collect();
    assert!(budget.admit("m", "l2", Cost::Bulk, now).is_err());
    for _ in 0..4 {
        std::mem::forget(budget.admit("m", "l2", Cost::Cheap, now).unwrap());
    }
}

#[test]
fn the_refusal_is_the_busy_line_lane_gh_asks_again_on() {
    let line = Busy { why: Refused::MachineSlots, retry_after_s: 2 }.line(Cost::Bulk);
    assert!(line.ends_with('\n'));
    let v: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
    assert_eq!(v["ok"], false);
    let error = v["error"].as_str().unwrap();
    assert!(error.starts_with("busy:") && error.contains("nothing was started"), "{error}");
    assert!(error.contains("retry after 2s"));
    assert_eq!(v["retry_after"], 2);
}

#[cfg(unix)]
mod stream {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::UnixListener;
    use tokio::sync::{Semaphore, watch};

    /// A broker stand-in with `workers` threads' worth of capacity, as the real one has: a
    /// connection takes a worker before it reads its line, a `push` holds it until
    /// `release`, and every request is answered `{"ok":true,"echo":<line>}`.
    fn fake_broker(
        dir: &Path,
        workers: usize,
    ) -> (PathBuf, watch::Sender<bool>, tokio::task::JoinHandle<()>) {
        let socket = dir.join("client-m.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (release, released) = watch::channel(false);
        let pool = Arc::new(Semaphore::new(workers));
        let task = tokio::spawn(async move {
            loop {
                let Ok((conn, _)) = listener.accept().await else { return };
                let pool = pool.clone();
                let mut released = released.clone();
                tokio::spawn(async move {
                    let _worker = pool.acquire_owned().await.unwrap();
                    let (read, mut write) = conn.into_split();
                    let mut line = String::new();
                    if BufReader::new(read).read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    if line.contains(r#""tool":"push""#) {
                        let _ = released.wait_for(|r| *r).await;
                    }
                    let echo = serde_json::json!({"ok": true, "echo": line.trim_end()});
                    let _ = write.write_all(format!("{echo}\n").as_bytes()).await;
                });
            }
        });
        (socket, release, task)
    }

    /// One request through the budget: the answer line and how long it took.
    async fn ask(socket: &Path, budget: &Arc<Budget>, line: &str) -> (serde_json::Value, Duration) {
        let began = Instant::now();
        let (mut client, server) = tokio::io::duplex(PIPE_BYTES);
        tokio::spawn(serve(server, socket.to_path_buf(), "m".into(), budget.clone()));
        client.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        let mut answer = String::new();
        BufReader::new(client).read_line(&mut answer).await.unwrap();
        (serde_json::from_str(&answer).unwrap(), began.elapsed())
    }

    fn push(lane: &str) -> String {
        format!(r#"{{"op":"call","tool":"push","repo":"a/b","lane":"{lane}","args":{{}}}}"#)
    }

    const PING: &str = r#"{"op":"ping","check_push":false}"#;

    #[tokio::test(flavor = "multi_thread")]
    async fn the_first_line_reaches_the_broker_whole_and_its_answer_comes_back() {
        let dir = tempfile::tempdir().unwrap();
        let (socket, _release, _broker) = fake_broker(dir.path(), 4);
        let budget = Budget::new(small());
        let (answer, _) = ask(&socket, &budget, PING).await;
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["echo"], PING);
    }

    /// Durability 4.6: hold every bulk slot, and a cheap ping still answers; a further bulk
    /// call is answered busy at once instead of waiting behind the held ones.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_ping_answers_while_every_bulk_slot_is_held() {
        let dir = tempfile::tempdir().unwrap();
        let (socket, release, _broker) = fake_broker(dir.path(), 3);
        let budget = Budget::new(Limits { bulk_slots: 2, ..small() });
        let held: Vec<_> = (0..2)
            .map(|i| {
                let (socket, budget) = (socket.clone(), budget.clone());
                tokio::spawn(async move { ask(&socket, &budget, &push(&format!("l{i}"))).await })
            })
            .collect();
        // Both bulk slots are taken once the broker's workers are.
        tokio::time::timeout(Duration::from_secs(5), async {
            while budget.table.lock().unwrap().machines.get("m").map_or(0, |m| m.bulk) < 2 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();

        let (ping, took) = ask(&socket, &budget, PING).await;
        assert_eq!(ping["ok"], true);
        assert!(took < Duration::from_secs(1), "ping took {took:?}");
        let (third, refused_in) = ask(&socket, &budget, &push("l2")).await;
        assert_eq!(third["ok"], false);
        assert!(third["error"].as_str().unwrap().starts_with("busy:"));
        assert!(refused_in < Duration::from_secs(1), "refusal took {refused_in:?}");

        release.send(true).unwrap();
        for held in held {
            assert_eq!(held.await.unwrap().0["ok"], true);
        }
        // The slots came back.
        assert_eq!(ask(&socket, &budget, &push("l2")).await.0["ok"], true);
    }

    /// The number for the PR: a broker with 3 workers and bulk calls that hold them for
    /// 500 ms. Before (no cap on bulk streams) the ping waits behind them; after, bulk is
    /// held to 2 of the 3 workers, so the ping has one. Run with `--nocapture` to see it.
    #[tokio::test(flavor = "multi_thread")]
    async fn ping_latency_with_the_bulk_slots_held_before_and_after() {
        async fn trial(limits: Limits) -> Duration {
            let dir = tempfile::tempdir().unwrap();
            let (socket, release, _broker) = fake_broker(dir.path(), 3);
            let budget = Budget::new(limits);
            for i in 0..8 {
                let (socket, budget) = (socket.clone(), budget.clone());
                tokio::spawn(async move { ask(&socket, &budget, &push(&format!("l{i}"))).await });
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
            let freed = tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let _ = release.send(true);
            });
            let (ping, took) = ask(&socket, &budget, PING).await;
            assert_eq!(ping["ok"], true);
            freed.abort();
            took
        }
        let unbudgeted = Limits {
            bulk_slots: usize::MAX,
            caller_bulk_inflight: usize::MAX,
            caller_bulk_per_min: usize::MAX,
            ..small()
        };
        let before = trial(unbudgeted).await;
        let after = trial(Limits { bulk_slots: 2, caller_bulk_inflight: 2, ..small() }).await;
        println!("ping with all bulk held: before {before:?}, after {after:?}");
        assert!(before >= Duration::from_millis(300), "before {before:?}");
        assert!(after < Duration::from_millis(250), "after {after:?}");
    }
}
