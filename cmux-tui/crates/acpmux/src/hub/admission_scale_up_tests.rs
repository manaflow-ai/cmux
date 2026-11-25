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
fn admission_scale_up_reads_a_providers_answer() {
    assert_eq!(parse_answer(true, "log\n{\"host\": \"lane-9\"}\n"), Answer::Host("lane-9".into()));
    assert_eq!(
        parse_answer(false, "{\"error\": \"no slot\", \"terminal\": true}"),
        Answer::Failed { why: "no slot".into(), terminal: true }
    );
    assert!(matches!(parse_answer(true, "not json"), Answer::Failed { terminal: false, .. }));
    assert!(matches!(parse_answer(false, "{\"host\": \"x\"}"), Answer::Failed { .. }));
}
