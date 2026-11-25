//! What one live row of `_acpmux/sessions` costs, step by step (goal acpmux-under-duress: the
//! bench's bigchat leg reads `ls` p99 685 ms with ~470 live rows at load 72 on 8 cores; a 500 ms
//! CLI p99 there leaves ~65 us of daemon CPU a row). Each step is timed over every row of a hub
//! of `ROWS` idle chats, thin (a bench fixture's meta) and wide (a real chat's: 290 touched files,
//! its context parts, models, config options, usage). Run on the fleet:
//! `cargo test -p acpmux --release --lib row_cost -- --ignored --nocapture`.
use super::*;
use std::time::Instant;

const ROWS: usize = 470;
const ROUNDS: usize = 5;

fn keep<T>(value: T) {
    std::hint::black_box(value);
}

fn wide_fields(i: usize) -> Value {
    let long = |n: usize| "x".repeat(n);
    let touched: Vec<Value> = (0..290)
        .map(|f| json!({"path": format!("/work/repo-{i}/src/dir-{f}/file-{f}.rs"), "at": 1_795_150_609_446_u64 + f as u64}))
        .collect();
    let context: Vec<Value> = (0..7)
        .map(|c| {
            json!({"id": format!("part-{c}"), "source": "cmux-default", "label": long(38),
            "tokens": 91, "included": true, "editable": true, "measurement": "estimated",
            "sourceBytes": 800, "channel": "developer-instructions", "text": long(800)})
        })
        .collect();
    let options: Vec<Value> = (0..12)
        .map(|o| {
            json!({"_meta": {"inputModalities": ["text", "image"]}, "description": long(47),
            "name": format!("Model-{o}"), "value": format!("model-{o}")})
        })
        .collect();
    let config: Vec<Value> = (0..6)
        .map(|c| {
            json!({"category": "model", "currentValue": "model-1", "id": format!("opt-{c}"),
            "name": "Model", "options": options, "type": "select"})
        })
        .collect();
    let models: Vec<Value> = (0..12)
        .map(|o| json!({"description": long(47), "modelId": format!("model-{o}"), "name": format!("Model-{o}")}))
        .collect();
    let prs: Vec<String> = (0..5)
        .map(|p| format!("https://github.com/manaflow-ai/cmux/pull/{}", 50_000 + p))
        .collect();
    let pr_times: serde_json::Map<String, Value> =
        prs.iter().map(|p| (p.clone(), json!(1_795_155_533_185_u64))).collect();
    json!({
        "touchedFiles": touched,
        "cmuxContext": context,
        "configOptions": config,
        "models": {"availableModels": models, "currentModelId": "model-1"},
        "modes": {"availableModes": (0..5).map(|m| json!({"description": long(40), "id": format!("mode-{m}"), "name": "Ask"})).collect::<Vec<_>>(), "currentModeId": "mode-1"},
        "usage": {"_meta": {"codexAppServer": {"tokenUsage": {"last": {"inputTokens": 106_428, "outputTokens": 4, "totalTokens": 106_432}, "modelContextWindow": 258_400}}}, "sessionUpdate": "usage_update", "size": 258_400, "used": 106_432},
        "usageLimits": {"credits": {"balance": "216.3"}, "plan": "pro", "windows": [{"id": "weekly", "resetsAt": 1_795_420_770_u64, "usedPercent": 100.0, "windowMins": 10_080}]},
        "agentCapabilities": {"loadSession": true, "mcpCapabilities": {"http": true, "sse": false}, "promptCapabilities": {"audio": true, "embeddedContext": true, "image": true}},
        "spawnArgv": [long(1000), long(1000), long(1000), long(1000)],
        "pullRequests": prs,
        "pullRequestTimes": pr_times,
        "title": long(80),
        "lastPrompt": long(200),
        "preview": long(400),
    })
}

fn hub_of(wide: bool) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..ROWS {
        let mut meta = json!({"schema": "acpmux.session.v1", "id": format!("s-{i:05}"),
            "name": format!("chat-{i}"), "harness": "claude", "cwd": "/work",
            "status": "idle", "createdAt": 1, "updatedAt": 1_000 + i});
        if wide && let (Some(meta), Value::Object(extra)) = (meta.as_object_mut(), wide_fields(i)) {
            meta.extend(extra);
        }
        let meta: crate::store::SessionMeta =
            serde_json::from_value(meta).expect("the wide meta parses as a SessionMeta");
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

/// Microseconds a row for `step` over every row, the best of [`ROUNDS`].
fn per_row(sessions: &[Arc<Session>], mut step: impl FnMut(&Session)) -> f64 {
    (0..ROUNDS)
        .map(|_| {
            let start = Instant::now();
            for s in sessions {
                step(s);
            }
            start.elapsed().as_secs_f64() * 1e6 / sessions.len() as f64
        })
        .fold(f64::INFINITY, f64::min)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "a measurement: run with --release --ignored --nocapture"]
async fn row_cost() {
    for wide in [false, true] {
        let hub = hub_of(wide);
        let sessions = hub.sessions();
        assert_eq!(sessions.len(), ROWS);
        let label = if wide { "wide" } else { "thin" };
        let meta_bytes = serde_json::to_string(&sessions[0].meta()).unwrap().len();
        let mut steps: Vec<(&str, f64)> = Vec::new();
        steps.push(("meta_clone", per_row(&sessions, |s| keep(s.meta()))));
        steps.push(("read_meta_id", per_row(&sessions, |s| keep(s.read_meta(|m| m.id.len())))));
        steps.push(("summary_value", per_row(&sessions, |s| keep(hub.session_list_summary(s)))));
        steps.push(("own_row_text", per_row(&sessions, |s| keep(hub.own_row_text(s, false)))));
        let rows: Vec<Value> = sessions.iter().map(|s| hub.session_list_summary(s)).collect();
        let mut at = 0;
        steps.push((
            "value_to_string",
            per_row(&sessions, |_| {
                keep(serde_json::to_string(&rows[at % rows.len()]).unwrap());
                at += 1;
            }),
        ));
        let metas: Vec<crate::store::SessionMeta> = sessions.iter().map(|s| s.meta()).collect();
        let mut at = 0;
        let mut next = || {
            at += 1;
            &metas[(at - 1) % metas.len()]
        };
        steps.push(("waiting_on", per_row(&sessions, |s| keep(hub.waiting_on(s)))));
        steps.push(("lineage_of", per_row(&sessions, |_| keep(hub.lineage_of(next())))));
        steps.push(("retry_row", per_row(&sessions, |s| keep(hub.retry_row(s, None)))));
        steps.push(("usage_stats_of", per_row(&sessions, |s| keep(hub.usage_stats_of(s, next())))));
        steps.push(("git_branch_now", per_row(&sessions, |_| keep(hub.git_branch_now(next())))));
        steps.push(("work_below_read", per_row(&sessions, |s| keep(hub.holds_work_below_read(s)))));
        steps.push((
            "subsessions_waiting",
            per_row(&sessions, |s| keep(hub.subsessions_waiting(s))),
        ));
        steps.push(("work_below_since", per_row(&sessions, |s| keep(hub.work_below_since(s)))));
        steps.push(("shown", per_row(&sessions, |s| keep(hub.shown(s)))));
        steps.push((
            "credential_only_here",
            per_row(&sessions, |s| keep(hub.credential_only_here(s, next()))),
        ));
        steps.push((
            "session_enforcement",
            per_row(&sessions, |_| keep(hub.session_enforcement(next()))),
        ));
        steps.push((
            "running_processes",
            per_row(&sessions, |s| keep(hub.running_processes_read(s))),
        ));
        steps.push(("waits_for_slot", per_row(&sessions, |_| keep(hub.waits_for_slot(next())))));
        steps.push(("person_hold", per_row(&sessions, |s| keep(hub.person_hold(s)))));
        steps.push(("spawned_by", per_row(&sessions, |_| keep(hub.spawned_by(next())))));
        steps.push(("live_tags", per_row(&sessions, |_| keep(super::session::live_tags(next())))));
        steps.push(("forks_any_turn", per_row(&sessions, |_| keep(hub.forks_any_turn(next())))));
        // The whole list as `ls` reads it, at the reply page's byte budget.
        let mut whole_ms = f64::INFINITY;
        for _ in 0..ROUNDS {
            let one = Instant::now();
            let text = hub.session_list_text(&json!({}), false, false, 1 << 20).unwrap();
            std::hint::black_box(text.len());
            whole_ms = whole_ms.min(one.elapsed().as_secs_f64() * 1000.0);
        }
        let line: Vec<String> = steps.iter().map(|(k, us)| format!("{k}={us:.1}")).collect();
        println!(
            "PERF row_cost {label} rows={ROWS} meta_bytes={meta_bytes} whole_list_ms={whole_ms:.2} us_per_row: {}",
            line.join(" ")
        );
    }
}
