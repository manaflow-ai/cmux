//! Whole-read costs at a dogfood-sized hub (7,828 chats, 7,295 closed), measured by hand: a read
//! builds the rows it sends, a closed one from its cached bytes (`closed_rows.rs`).
#![cfg(target_os = "linux")]
use super::*;
use crate::config::Config;
use std::time::Duration;

/// A dogfood-sized hub: 7,295 closed records must stay out of the live list index.
fn scale_hub() -> Arc<Hub> {
    let store = crate::store::MemoryStore::default();
    for n in 0..7_828 {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("scale-{n:04}"),
            "name": format!("scale-{n:04}"), "harness": "claude", "family": "claude",
            "agentSessionId": format!("chat-{n:04}"), "cwd": "/nonexistent",
            "status": if n < 7_295 { "closed" } else { "idle" },
            "createdAt": 1, "updatedAt": n + 1,
            "preview": "A short synthetic reply", "configOptions": [{"payload": "x".repeat(32_768)}]
        }))
        .unwrap();
        crate::store::Store::save(&store, &meta).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

fn process_cpu() -> Duration {
    let mut value = std::mem::MaybeUninit::<libc::timespec>::uninit();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, value.as_mut_ptr()) },
        0
    );
    let value = unsafe { value.assume_init() };
    Duration::new(u64::try_from(value.tv_sec).unwrap(), u32::try_from(value.tv_nsec).unwrap())
}

fn uncached_rows(hub: &Hub, with_tools: bool) -> Built {
    let rows: Vec<Value> = hub
        .sessions()
        .iter()
        .map(|session| {
            if with_tools {
                hub.session_summary(session)
            } else {
                hub.session_list_summary(session)
            }
        })
        .collect();
    serialize_in_order(&rows)
}

/// Every row of the list, as one read with no page cap builds it.
fn whole(hub: &Hub, with_tools: bool, own_only: bool) -> String {
    hub.session_list_text(&json!({}), with_tools, own_only, usize::MAX).unwrap()
}

fn measure_rows(rounds: usize, mut run: impl FnMut()) -> (f64, f64) {
    let start = std::time::Instant::now();
    let cpu = process_cpu();
    for _ in 0..rounds {
        run();
    }
    (
        start.elapsed().as_secs_f64() * 1000.0 / rounds as f64,
        (process_cpu() - cpu).as_secs_f64() * 1000.0 / rounds as f64,
    )
}

/// Same 7,828-record fixture as the live-index measurement, timing the full idle projections
/// before and after the closed-summary bytes are warmed. The output supplies the PR's table.
#[tokio::test]
#[ignore = "manual closed-summary-cache measurement"]
async fn measure_7828_full_idle_closed_summary_cache() {
    let rounds = 3;

    let baseline = scale_hub();
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(uncached_rows(&baseline, false));
    });
    eprintln!(
        "7828 watch/list baseline uncached full build: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle"
    );
    let cached = scale_hub();
    std::hint::black_box(whole(&cached, false, false));
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(whole(&cached, false, false));
    });
    eprintln!("7828 watch/list cached full build: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle");

    let baseline = scale_hub();
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(uncached_rows(&baseline, true));
    });
    eprintln!(
        "7828 sessions?usage baseline uncached full build: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle"
    );
    let cached = scale_hub();
    std::hint::black_box(whole(&cached, true, true));
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(whole(&cached, true, true));
    });
    eprintln!(
        "7828 sessions?usage cached full build: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle"
    );

    let baseline = scale_hub();
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(
            baseline
                .sessions()
                .iter()
                .map(|session| baseline.session_summary(session))
                .collect::<Vec<_>>(),
        );
    });
    eprintln!(
        "7828 peer sync baseline uncached summaries: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle"
    );
    let cached = scale_hub();
    std::hint::black_box(cached.all_session_summaries());
    let (wall, cpu) = measure_rows(rounds, || {
        std::hint::black_box(cached.all_session_summaries());
    });
    eprintln!("7828 peer sync cached summaries: {wall:.3} wall ms/cycle, {cpu:.3} CPU ms/cycle");
}

/// Same 7,828-record fixture used for the live-index before/after measurement. Each pair uses
/// the same operation with the pre-index full walk and the indexed live projection.
#[tokio::test]
#[ignore = "manual live-index measurement"]
async fn measure_7828_exclude_closed_index() {
    let rounds = 5;
    let measure = |mut run: Box<dyn FnMut()>| {
        let start = std::time::Instant::now();
        let cpu = process_cpu();
        for _ in 0..rounds {
            run();
        }
        (
            start.elapsed().as_secs_f64() * 1000.0 / f64::from(rounds),
            (process_cpu() - cpu).as_secs_f64() * 1000.0 / f64::from(rounds),
        )
    };

    let baseline = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(whole(&baseline, false, false));
    }));
    eprintln!("7828 list baseline whole read: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");
    let indexed = scale_hub();
    let live = json!({"excludeStatus": ["closed"]});
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(indexed.session_list_text(&live, false, false, usize::MAX).unwrap());
    }));
    eprintln!("7828 list indexed live read: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");

    let baseline = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(baseline.all_session_summaries());
    }));
    eprintln!(
        "7828 locate/wait baseline all_session_summaries: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list"
    );
    let indexed = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(indexed.live_session_summaries());
    }));
    eprintln!(
        "7828 locate/wait indexed live_session_summaries: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list"
    );
}
