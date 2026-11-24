use super::*;
use std::sync::{Arc, Mutex};

#[test]
fn only_a_plain_sleep_of_at_least_30_seconds_is_parked() {
    assert_eq!(sleep_seconds("sleep 600"), Some(600.0));
    assert_eq!(sleep_seconds("  sleep   30 "), Some(30.0));
    assert_eq!(sleep_seconds("sleep 5m"), Some(300.0));
    assert_eq!(sleep_seconds("sleep 1m 30s"), Some(90.0));
    assert_eq!(sleep_seconds("sleep 0.5h"), Some(1800.0));
    assert_eq!(sleep_seconds("sleep 1d"), Some(86_400.0));
    for not in [
        "sleep 29",
        "sleep 10 19",
        "sleep",
        "sleep 600 && gh pr view 1",
        "sleep 600; echo done",
        "sleep 600 | cat",
        "sleep $N",
        "sleep '600'",
        "sleep 600 # wait",
        "sleep 600 > /dev/null",
        "sleep inf",
        "sleep 1e3",
        "sleep -5",
        "sleep 6.0.0",
        "sleep .",
        "sleep 600x",
        "timeout 5 sleep 600",
        "/bin/sleep 600",
        "sleepy 600",
        "sleep 600\necho x",
    ] {
        assert_eq!(sleep_seconds(not), None, "{not:?}");
    }
}

fn bash(command: &str, background: bool) -> Value {
    json!({"tool_name": "Bash", "tool_use_id": "toolu_1", "cwd": "/w",
        "tool_input": {"command": command, "description": "Wait", "timeout": 700_000,
            "run_in_background": background}})
}

#[test]
fn the_hook_rewrites_a_foreground_sleep_into_the_waiter() {
    let words = ["/opt/acpmux".to_owned()];
    let out = rewrite(&bash("sleep 600", false), &words).expect("rewritten");
    let hook = &out["hookSpecificOutput"];
    assert_eq!(hook["hookEventName"], "PreToolUse");
    assert!(hook.get("permissionDecision").is_none(), "asked or allowed as before");
    assert_eq!(
        hook["updatedInput"],
        json!({"command": "'/opt/acpmux' '__parked-sleep' '--call' 'toolu_1' '--seconds' '600'",
            "description": "Wait", "timeout": 700_000, "run_in_background": false})
    );
    assert!(rewrite(&bash("sleep 600", true), &words).is_none(), "a background sleep");
    assert!(rewrite(&bash("sleep 10", false), &words).is_none(), "too short to pause");
    assert!(rewrite(&bash("cargo test", false), &words).is_none());
    let mut no_id = bash("sleep 600", false);
    no_id.as_object_mut().unwrap().remove("tool_use_id");
    assert!(rewrite(&no_id, &words).is_none(), "no call id: nothing to park");
    let mut other = bash("sleep 600", false);
    other["tool_name"] = json!("Read");
    assert!(rewrite(&other, &words).is_none());
}

#[test]
fn the_policy_is_read_from_the_applied_machine_toml() {
    let root = tempfile::tempdir().unwrap();
    assert!(!aggressive(root.path()), "no file: off");
    let applied = root
        .path()
        .join(cmux_cloud_start_core::machine_config::idle::applied_path().trim_start_matches('/'));
    std::fs::create_dir_all(applied.parent().unwrap()).unwrap();
    std::fs::write(&applied, "version = 1\nrole = \"lane\"\n").unwrap();
    assert!(!aggressive(root.path()), "a lane without the policy: off");
    std::fs::write(&applied, "version = 1\n[idle]\npolicy = \"aggressive\"\n").unwrap();
    assert!(aggressive(root.path()));
    std::fs::write(&applied, "version = 1\n[idle]\npolicy = \"fast\"\n").unwrap();
    assert!(!aggressive(root.path()));
    std::fs::write(&applied, "not toml [").unwrap();
    assert!(!aggressive(root.path()));
}

/// The platform side as a fake: it records every park and unpark, pauses the machine while
/// something is parked (the guest's wall clock jumps, its monotonic clock does not), and wakes
/// it at the timer.
#[derive(Default)]
struct FakePlatform {
    log: Mutex<Vec<String>>,
}

impl PlatformWaits for FakePlatform {
    fn park(&self, wait: ParkedWait) {
        let Wake::Timer { at_ms } = wait.wake;
        self.log.lock().unwrap().push(format!("park {} {} {at_ms}", wait.session, wait.call));
    }
    fn unpark(&self, session: &str, call: &str) {
        self.log.lock().unwrap().push(format!("unpark {session} {call}"));
    }
}

/// The waiter's sleep across a pause: the guest runs 2 s, the platform pauses it at the park
/// and resumes it at the timer (600 s of wall clock in which the guest's naps make no progress),
/// and the wait ends at its end on the wall clock, not 600 s of guest time after the resume. A
/// monotonic `sleep 600` paused after 2 s would have run until 1 198 s.
#[test]
fn a_parked_sleep_pauses_wakes_on_time_and_ends_on_the_wall_clock() {
    let platform = Arc::new(FakePlatform::default());
    let start = 1_000_000;
    let end = start + 600_000;
    platform.park(ParkedWait {
        session: "s".into(),
        call: "toolu_1".into(),
        wake: Wake::Timer { at_ms: end },
    });
    let wall = Arc::new(Mutex::new(start));
    let naps = Arc::new(Mutex::new(Vec::new()));
    {
        let (wall_r, wall_n, naps) = (wall.clone(), wall.clone(), naps.clone());
        let mut first = true;
        sleep_until(end, &mut move || *wall_r.lock().unwrap(), &mut move |to, left| {
            naps.lock().unwrap().push((to, left));
            let mut now = wall_n.lock().unwrap();
            if first {
                // 2 s awake, then paused: the platform's timer resumes the guest at `end`.
                first = false;
                *now += 2_000;
                *now = end;
            }
        });
    }
    platform.unpark("s", "toolu_1");
    assert_eq!(*wall.lock().unwrap(), end, "it returned at the timer, not later");
    assert_eq!(naps.lock().unwrap().as_slice(), [(end, 600_000)], "one nap, aimed at the end");
    assert_eq!(
        platform.log.lock().unwrap().as_slice(),
        ["park s toolu_1 1600000", "unpark s toolu_1"]
    );

    // A wake before the timer (a message): it naps again towards the same end.
    let wall = Arc::new(Mutex::new(start));
    let mut aims = Vec::new();
    {
        let (r, n) = (wall.clone(), wall.clone());
        sleep_until(end, &mut move || *r.lock().unwrap(), &mut |to, _| {
            aims.push(to);
            let mut now = n.lock().unwrap();
            *now = if *now == start { start + 100_000 } else { end + 50 };
        });
    }
    assert_eq!(aims, [end, end]);
}

#[test]
fn the_registry_reports_each_park_and_forgets_ended_sessions() {
    let parked = Parked::default();
    let mut changes = parked.subscribe();
    parked.park(ParkedWait {
        session: "a".into(),
        call: "c1".into(),
        wake: Wake::Timer { at_ms: 5 },
    });
    assert!(changes.has_changed().unwrap());
    changes.borrow_and_update();
    assert_eq!(parked.snapshot()["a"]["c1"], Wake::Timer { at_ms: 5 });
    parked.unpark("a", "nope");
    assert!(!changes.has_changed().unwrap(), "an unknown call changes nothing");
    parked.park(ParkedWait {
        session: "b".into(),
        call: "c2".into(),
        wake: Wake::Timer { at_ms: 7 },
    });
    parked.retain_sessions(&["a"].into_iter().collect());
    assert!(!parked.snapshot().contains_key("b"), "b's turn ended");
    parked.unpark("a", "c1");
    assert!(parked.snapshot().is_empty());
}

/// The waiter gives exactly what `sleep` gives: no output, exit 0 (a short one: the threshold is
/// the hook's, not the waiter's), and no daemon to tell changes nothing.
#[cfg(unix)]
#[test]
fn the_waiter_prints_nothing_and_exits_zero_like_sleep() {
    let start = std::time::Instant::now();
    let args: Vec<String> = ["--call", "toolu_1", "--seconds", "1"].map(str::to_owned).to_vec();
    main(&args).unwrap();
    assert!(start.elapsed() >= std::time::Duration::from_millis(1_000));
    assert!(main(&["--seconds".to_owned(), "x".to_owned()]).is_err());
}

/// A shared fake, so the test still reads its log after `Parked` owns the forwarder.
struct Shared(Arc<FakePlatform>);

impl PlatformWaits for Shared {
    fn park(&self, wait: ParkedWait) {
        self.0.park(wait);
    }
    fn unpark(&self, session: &str, call: &str) {
        self.0.unpark(session, call);
    }
}

#[test]
fn a_parked_wait_also_goes_to_the_platform_with_a_timer_ahead_of_its_end() {
    let wait = ParkedWait {
        session: "s1".into(),
        call: "toolu_1".into(),
        wake: Wake::Timer { at_ms: 601_000 },
    };
    // The platform's timer fires the resume lead before the end, under a delivery id that is the
    // same each time the same call is parked.
    assert_eq!(
        timer_request(&wait),
        json!({"delivery": "parked-wait:s1:toolu_1", "fireAt": 599_000})
    );
    assert_eq!(timer_request(&wait), timer_request(&wait.clone()));
    let early = ParkedWait { wake: Wake::Timer { at_ms: 500 }, ..wait.clone() };
    assert_eq!(timer_request(&early)["fireAt"], 0);

    let fake = Arc::new(FakePlatform::default());
    let parked = Parked::default();
    parked.forward_to(Box::new(Shared(fake.clone())));
    parked.park(wait);
    assert_eq!(parked.snapshot()["s1"]["toolu_1"], Wake::Timer { at_ms: 601_000 });
    parked.unpark("s1", "toolu_1");
    assert!(parked.snapshot().is_empty());
    assert_eq!(*fake.log.lock().unwrap(), ["park s1 toolu_1 601000", "unpark s1 toolu_1"]);
}

#[tokio::test]
async fn the_trigger_timer_posts_the_wake_to_the_platform() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    const ID: &str = "3f1c2a9e-8b7d-4c6e-9a5b-1d2e3f4a5b6c";
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = tokio::sync::oneshot::channel::<String>();
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        loop {
            let mut chunk = [0; 4096];
            let count = socket.read(&mut chunk).await.unwrap();
            assert!(count > 0);
            request.extend_from_slice(&chunk[..count]);
            let text = String::from_utf8_lossy(&request).to_string();
            if let Some((head, body)) = text.split_once("\r\n\r\n") {
                let length: usize = head
                    .to_ascii_lowercase()
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length: ").map(|v| v.parse().unwrap()))
                    .unwrap_or(0);
                if body.len() >= length {
                    break;
                }
            }
        }
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
        socket.write_all(reply.as_bytes()).await.unwrap();
        let _ = tx.send(String::from_utf8(request).unwrap());
    });
    let client = crate::cli::trigger::TriggerClient::new(
        origin,
        zeroize::Zeroizing::new("cmx_owner".into()),
    )
    .unwrap();
    let timers = TriggerTimers {
        trigger: ID.into(),
        client: Arc::new(client),
        rt: tokio::runtime::Handle::current(),
    };
    timers.park(ParkedWait {
        session: "s1".into(),
        call: "toolu_1".into(),
        wake: Wake::Timer { at_ms: 601_000 },
    });
    let seen = tokio::time::timeout(std::time::Duration::from_secs(10), rx).await.unwrap().unwrap();
    assert!(seen.starts_with(&format!("POST /v1/triggers/{ID}/timers HTTP/1.1")), "{seen}");
    assert!(seen.to_ascii_lowercase().contains("authorization: bearer cmx_owner"));
    let (_, body) = seen.split_once("\r\n\r\n").unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(body).unwrap(),
        json!({"delivery": "parked-wait:s1:toolu_1", "fireAt": 599_000})
    );
}
