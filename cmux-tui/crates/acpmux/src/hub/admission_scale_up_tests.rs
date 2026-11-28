use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn provider(name: &str) -> Provider {
    Provider { name: name.into(), argv: vec![name.into()], terminal: false }
}

fn one_plan() -> Plan {
    Plan { providers: vec![provider("a")], budget: Duration::from_secs(5) }
}

/// A runner that counts its calls and answers each once `release` is notified.
fn held_runner(calls: Arc<AtomicUsize>, release: Arc<tokio::sync::Notify>) -> Runner {
    Arc::new(move |_p, _bound| {
        let (calls, release) = (calls.clone(), release.clone());
        Box::pin(async move {
            calls.fetch_add(1, Ordering::SeqCst);
            release.notified().await;
            Answer::Host("new-machine".into())
        })
    })
}

async fn settle(scale: &ScaleUp) {
    for _ in 0..200 {
        if !scale.state.lock().unwrap().running {
            return;
        }
        tokio::task::yield_now().await;
    }
    panic!("the run never ended");
}

#[tokio::test]
async fn admission_scale_up_runs_once_for_concurrent_over_cap_creates() {
    let (calls, release) = (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
    let scale = Arc::new(ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN));
    let owner = Arc::new(cmux_scope::Scope::new("test"));
    let now = Instant::now();
    let creates: Vec<_> = (0..16)
        .map(|_| {
            let (scale, owner) = (scale.clone(), owner.clone());
            tokio::spawn(async move { scale.trigger(&owner, one_plan(), now) })
        })
        .collect();
    let mut seen = Vec::new();
    for c in creates {
        seen.push(c.await.unwrap());
    }
    assert_eq!(seen.iter().filter(|t| **t == Trigger::Started).count(), 1, "{seen:?}");
    assert!(
        seen.iter().all(|t| t.scaling()),
        "every one of them says a machine is coming: {seen:?}"
    );
    release.notify_one();
    settle(&scale).await;
    assert_eq!(calls.load(Ordering::SeqCst), 1, "one provider run for 16 creates");
    assert!(owner.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test]
async fn admission_scale_up_waits_out_its_cooldown() {
    let (calls, release) = (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
    let scale = ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN);
    let owner = cmux_scope::Scope::new("test");
    let start = Instant::now();
    assert_eq!(scale.trigger(&owner, one_plan(), start), Trigger::Started);
    release.notify_one();
    settle(&scale).await;
    let soon = start + COOLDOWN - Duration::from_secs(1);
    assert_eq!(scale.trigger(&owner, one_plan(), soon), Trigger::Cooling);
    assert!(!Trigger::Cooling.scaling());
    assert_eq!(scale.trigger(&owner, one_plan(), start + COOLDOWN), Trigger::Started);
    release.notify_one();
    settle(&scale).await;
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert!(owner.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test]
async fn admission_scale_up_stops_at_the_first_host_or_a_terminal_failure() {
    let asked = Arc::new(StdMutex::new(Vec::<String>::new()));
    let answers = |script: Vec<(&'static str, Answer)>| -> Runner {
        let asked = asked.clone();
        Arc::new(move |p: Provider, _| {
            asked.lock().unwrap().push(p.name.clone());
            let a = script.iter().find(|(n, _)| *n == p.name).map(|(_, a)| a.clone());
            Box::pin(
                async move { a.unwrap_or(Answer::Failed { why: "?".into(), terminal: false }) },
            )
        })
    };
    let plan = Plan {
        providers: vec![provider("a"), provider("b"), provider("c")],
        budget: Duration::from_secs(5),
    };
    let failed = Answer::Failed { why: "full".into(), terminal: false };
    let runner = answers(vec![("a", failed.clone()), ("b", Answer::Host("h".into()))]);
    let ran = run_plan(&runner, plan.clone()).await;
    assert_eq!(ran.host.as_deref(), Some("h"));
    assert_eq!((ran.provider.as_deref(), ran.error.as_deref()), (Some("b"), None));
    assert_eq!(*asked.lock().unwrap(), ["a", "b"]);
    asked.lock().unwrap().clear();
    let runner = answers(vec![("a", Answer::Failed { why: "making".into(), terminal: true })]);
    let ran = run_plan(&runner, plan).await;
    assert_eq!(ran, Ran { host: None, error: Some("making".into()), provider: Some("a".into()) });
    assert_eq!(*asked.lock().unwrap(), ["a"], "a terminal answer ends the chain");
}

#[tokio::test]
async fn admission_scale_up_records_its_outcome_for_status() {
    let (calls, release) = (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
    let scale = ScaleUp::new(held_runner(calls, release.clone()), COOLDOWN);
    let owner = cmux_scope::Scope::new("test");
    let start = Instant::now();
    let idle = scale.status(start);
    assert_eq!(idle["v"], 1);
    assert_eq!(idle["state"], "idle");
    assert!(idle["lastStartedMs"].is_null() && idle["lastHost"].is_null(), "{idle}");
    assert_eq!(scale.trigger(&owner, one_plan(), start), Trigger::Started);
    let adding = scale.status(start);
    assert_eq!(adding["state"], "adding");
    assert!(adding["lastStartedMs"].is_u64() && adding["lastEndedMs"].is_null(), "{adding}");
    release.notify_one();
    settle(&scale).await;
    let done = scale.status(start + Duration::from_secs(1));
    assert_eq!(done["state"], "cooling");
    assert_eq!(
        (done["lastHost"].as_str(), done["lastProvider"].as_str()),
        (Some("new-machine"), Some("a"))
    );
    assert!(done["lastError"].is_null() && done["lastEndedMs"].is_u64(), "{done}");
    assert!(done["lastEndedMs"].as_u64() >= done["lastStartedMs"].as_u64());
    assert_eq!(scale.status(start + COOLDOWN)["state"], "idle");
    assert!(owner.close(Duration::from_secs(1)).await.joined());
    // A failed run keeps why, and no host.
    let failing: Runner = Arc::new(|_p, _b| {
        Box::pin(async { Answer::Failed { why: "no slot".into(), terminal: false } })
    });
    let scale = ScaleUp::new(failing, COOLDOWN);
    let owner = cmux_scope::Scope::new("test");
    assert_eq!(scale.trigger(&owner, one_plan(), start), Trigger::Started);
    settle(&scale).await;
    let failed = scale.status(start);
    assert!(failed["lastHost"].is_null(), "{failed}");
    assert_eq!(failed["lastError"], "no slot");
    assert!(owner.close(Duration::from_secs(1)).await.joined());
}

#[test]
fn admission_scale_up_needs_providers_and_a_checkout() {
    let dir = std::env::temp_dir().join(format!("acpmux-scale-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(dir.join("tools")).unwrap();
    std::fs::create_dir_all(dir.join("machines")).unwrap();
    std::fs::write(dir.join("tools/lane_overflow.py"), "").unwrap();
    let source = dir.join("machines/fleet-registry.json");
    assert_eq!(workspace_of(&source).as_deref(), Some(dir.as_path()));
    let none = json!({"machines": {"m": {"lanes": {"max_lanes": 8}}}});
    assert_eq!(plan(&none, &source, "m", Some(&dir)), None, "no lane_overflow: nothing runs");
    let empty = json!({"lane_overflow": {"providers": []}});
    assert_eq!(plan(&empty, &source, "m", Some(&dir)), None, "no providers: nothing runs");
    let registry = json!({"lane_overflow": {"timeout_seconds": 900, "providers": [
        {"name": "lanes", "argv": ["tools/lane_overflow.py", "freestyle-lanes"]},
        {"name": "gone", "argv": ["tools/missing.py"]},
        {"name": "bad"},
    ]}});
    assert_eq!(plan(&registry, &source, "m", None), None, "no checkout: nothing runs");
    let got = plan(&registry, &source, "m", Some(&dir)).unwrap();
    assert_eq!(got.budget, Duration::from_secs(900));
    assert_eq!(got.providers.len(), 1, "{got:?}");
    let argv = &got.providers.first().unwrap().argv;
    let program = dir.join("tools/lane_overflow.py").to_string_lossy().into_owned();
    let source_arg = source.to_string_lossy().into_owned();
    let want: Vec<&str> = vec![
        &program,
        "freestyle-lanes",
        "--origin",
        "m",
        "--busy",
        "m",
        "--budget",
        "900",
        "--registry",
        &source_arg,
    ];
    assert_eq!(argv.iter().map(String::as_str).collect::<Vec<_>>(), want);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn admission_scale_up_is_skipped_while_a_peer_has_room() {
    let roomy = json!({"pick": "big-red", "why": "big-red: 31 GB RAM free"});
    assert_eq!(room_elsewhere(&roomy).as_deref(), Some("placed on big-red: 31 GB RAM free"));
    let full = json!({"pick": "big-red", "why": "least loaded", "overloaded": true});
    assert_eq!(room_elsewhere(&full), None, "a pick with no room is nowhere: scale up");
    assert_eq!(room_elsewhere(&json!({"error": "no candidates"})), None, "no peer: scale up");
}

#[test]
fn one_lane_per_host_needs_an_empty_peer() {
    let reg = json!({"lane_place": {"one_lane_per_host": true}});
    let verdict = |live: Value| json!({"pick": "p", "why": "p: room", "hosts": [{"name": "p", "live": live}]});
    let mut empty = verdict(json!(0));
    solo_pick(&mut empty, Some(&reg));
    assert!(room_elsewhere(&empty).is_some(), "an empty peer takes the lane");
    for live in [json!(1), Value::Null] {
        let mut busy = verdict(live);
        solo_pick(&mut busy, Some(&reg));
        assert_eq!(room_elsewhere(&busy), None, "a busy or unknown peer is no room");
    }
    let mut off = verdict(json!(3));
    solo_pick(&mut off, Some(&json!({})));
    assert!(room_elsewhere(&off).is_some(), "without the flag nothing changes");
}

#[test]
fn admission_scale_up_reads_a_providers_answer() {
    assert_eq!(parse_answer(true, "log\n{\"host\": \"lane-9\"}\n"), Answer::Host("lane-9".into()));
    assert_eq!(
        parse_answer(false, "{\"error\": \"no slot\", \"terminal\": true}"),
        Answer::Failed { why: "no slot".into(), terminal: true }
    );
    assert!(matches!(parse_answer(true, "not json"), Answer::Failed { terminal: false, .. }));
    assert!(matches!(parse_answer(false, "{\"host\": \"x\"}"), Answer::Failed { .. }));
}

/// This host at `live` of a cap of 3, as `admission::check` reads it.
fn at(registry: &Value, live: usize) -> crate::hub::admission::Verdict {
    crate::hub::admission::check(&crate::hub::admission::Inputs {
        flag: None,
        registry: Some(registry),
        unreadable: false,
        source: Path::new("/r/fleet-registry.json"),
        machine: Some("m"),
        live,
    })
}

fn spare_registry(warm_spare: Option<bool>) -> Value {
    let mut r = serde_json::json!({"machines": {"m": {"lanes": {"max_lanes": 3}}}});
    if let Some(on) = warm_spare {
        r["lane_overflow"] = serde_json::json!({"warm_spare": on});
    }
    r
}

#[test]
fn admission_scale_up_warm_spare_is_off_unless_turned_on() {
    let none = |_: &str| None;
    assert!(!warm_spare_on(None, none), "off by default");
    assert!(!warm_spare_on(Some(&spare_registry(None)), none));
    assert!(!warm_spare_on(Some(&spare_registry(Some(false))), none));
    assert!(warm_spare_on(Some(&spare_registry(Some(true))), none));
    let env = |v: &'static str| move |k: &str| (k == WARM_SPARE_ENV).then(|| v.to_owned());
    assert!(warm_spare_on(None, env("1")));
    assert!(!warm_spare_on(Some(&spare_registry(Some(true))), env("0")), "env wins");
    assert!(warm_spare_on(Some(&spare_registry(Some(true))), env("maybe")));
    // Off, no create asks for a spare and no Auto start moves for one, at any count.
    let r = spare_registry(None);
    for live in 0..6 {
        let v = at(&r, live);
        assert!(!wants_warm_spare(false, v.last_slot.is_some(), false), "live {live}");
    }
    assert!(!uses_spare(false, true, true));
}

#[test]
fn admission_scale_up_warm_spare_only_at_the_last_free_slot() {
    let r = spare_registry(Some(true));
    let asks: Vec<bool> = (0..6)
        .map(|live| wants_warm_spare(true, at(&r, live).last_slot.is_some(), false))
        .collect();
    // Two free slots, one, then the create that takes the last; past the cap the
    // existing over-cap scale-up asks instead.
    assert_eq!(asks, [false, false, true, false, false, false]);
    assert!(at(&r, 3).over.is_some() && at(&r, 3).last_slot.is_none());
    assert!(!wants_warm_spare(true, true, true), "a connected host has room: no spare");
    let uncapped = serde_json::json!({"machines": {"m": {}}});
    assert!(at(&uncapped, 0).last_slot.is_none(), "no cap, no last slot");
}

#[tokio::test]
async fn admission_scale_up_warm_spare_asks_once_for_a_burst_at_zero_headroom() {
    let (calls, release) = (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
    let scale = Arc::new(ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN));
    let owner = Arc::new(cmux_scope::Scope::new("test"));
    let r = Arc::new(spare_registry(Some(true)));
    let now = Instant::now();
    // 16 concurrent creates that each see the last free slot, plus earlier ones.
    let creates: Vec<_> = (0..16)
        .map(|i| {
            let (scale, owner, r) = (scale.clone(), owner.clone(), r.clone());
            tokio::spawn(async move {
                let live = if i < 4 { i % 2 } else { 2 };
                let v = at(&r, live);
                wants_warm_spare(warm_spare_on(Some(&r), |_| None), v.last_slot.is_some(), false)
                    .then(|| scale.trigger(&owner, one_plan(), now))
            })
        })
        .collect();
    let mut seen = Vec::new();
    for c in creates {
        seen.extend(c.await.unwrap());
    }
    assert_eq!(seen.len(), 12, "only the last-slot creates ask: {seen:?}");
    assert_eq!(seen.iter().filter(|t| **t == Trigger::Started).count(), 1, "{seen:?}");
    release.notify_one();
    settle(&scale).await;
    // Repeated last-slot creates after the run ended, within the cooldown, ask nothing.
    // Four probes spread inside COOLDOWN, the last a fifth of it short of its end.
    for s in 1..5u32 {
        let later = now + COOLDOWN * s / 5;
        assert_eq!(scale.trigger(&owner, one_plan(), later), Trigger::Cooling, "at {s}/5");
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1, "one machine for the whole burst");
    assert!(owner.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test]
async fn admission_scale_up_warm_spare_adds_none_when_quota_says_no() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    let denied: Runner = Arc::new(move |_p, _bound| {
        counted.fetch_add(1, Ordering::SeqCst);
        Box::pin(async {
            Answer::Failed { why: "no slot: saved VM cap reached".into(), terminal: true }
        })
    });
    let scale = ScaleUp::new(denied, COOLDOWN);
    let owner = cmux_scope::Scope::new("test");
    let now = Instant::now();
    let (trigger, result) = scale.trigger_wait(&owner, one_plan(), now);
    assert_eq!(trigger, Trigger::Started);
    let mut result = result.expect("a started run has a result");
    let _ = result.wait_for(|r| r.is_some()).await;
    assert_eq!(*result.borrow(), Some(None), "no host");
    settle(&scale).await;
    let done = scale.status(now);
    assert!(done["lastHost"].is_null(), "{done}");
    assert_eq!(done["lastError"].as_str(), Some("no slot: saved VM cap reached"));
    // With no spare, no connected host has room, so Auto starts never move for one,
    // and the next last-slot creates within the cooldown ask nothing more.
    assert!(!uses_spare(true, true, false));
    assert_eq!(scale.trigger(&owner, one_plan(), now + Duration::from_secs(60)), Trigger::Cooling);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(owner.close(Duration::from_secs(1)).await.joined());
}

#[test]
fn admission_scale_up_warm_spare_takes_the_next_auto_start() {
    // The spare joined: the placement engine's verdict over the peers has room on it.
    let peers = serde_json::json!({"pick": "spare", "why": "spare: 4 cores free", "hosts": []});
    let room = room_elsewhere(&peers).is_some();
    assert!(room);
    assert!(uses_spare(true, true, room), "the next Auto start is placed on the spare");
    assert!(!uses_spare(true, false, room), "an explicit choice stays where it asked");
    assert!(!wants_warm_spare(true, true, room), "never a second spare while one has room");
    let placed = crate::hub::admission_redirect::pick(
        &peers,
        crate::hub::admission_redirect::Reason::OverCap,
        3,
        Some(3),
    )
    .expect("placed on the spare");
    assert_eq!(placed.host, "spare");
}
