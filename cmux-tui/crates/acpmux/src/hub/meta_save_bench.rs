//! What a metadata save costs its caller (`meta_save.rs`): p50 and p95 of one `Hub::save_meta` of
//! a changed unread mark on the long chat of a small home and of a god one (`god_fixture`:
//! `ACPMUX_GOD_SCALE=0.1` for a quick run), alone and while another thread saves the same chat
//! over and over. A save writes the chat's metadata, never its log, so the god home's p95 stays
//! within 1.2 x the small one's plus a floor for noise. It uses only `save_meta`, which the hub
//! had before the save waited for its write: copy it beside `meta_save.rs` there, with the
//! `mod bench` lines at the end of that file, for the before numbers.
//! Manual: `cargo test -p acpmux --release --lib meta_save_cost -- --ignored --nocapture
//! --test-threads=1`. One `META-SAVE-COST` line per home and mode.

use super::*;
use crate::god_fixture::{Shape, write_home};
use std::time::{Duration, Instant};

/// Timed saves per home and mode.
const SAMPLES: usize = 400;
/// What god p95 may exceed 1.2 x small p95 by: a sync's scheduling noise, not cost.
const FLOOR_US: f64 = 250.0;

/// A hub on `shape`'s home, written in `dir`, with its long chat loaded.
fn hub_on(dir: &std::path::Path, shape: &Shape) -> (Arc<Hub>, Arc<Session>) {
    let (home, claude, work) = (dir.join("home"), dir.join("claude"), dir.join("work"));
    let made = write_home(&home, &claude, &work, shape).unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, &home).unwrap();
    let hub = Hub::new(cfg, store);
    let meta = hub.store.load(&made.god).unwrap().expect("the long chat");
    hub.install_stored_session(meta, false, false, true);
    let session = hub.resolve_here(&made.god).unwrap();
    (hub, session)
}

/// The time of each of [`SAMPLES`] saves, each of a changed unread mark.
fn cost(hub: &Hub, session: &Session) -> Vec<Duration> {
    let mut took = Vec::with_capacity(SAMPLES);
    for i in 0..SAMPLES {
        session.meta.lock().unwrap().unread = i % 2 == 0;
        let started = Instant::now();
        hub.save_meta(session);
        took.push(started.elapsed());
    }
    took
}

fn percentile(sorted: &[Duration], p: usize) -> f64 {
    let at = (sorted.len() * p / 100).min(sorted.len().saturating_sub(1));
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

#[test]
#[ignore = "manual per-save cost measurement"]
fn meta_save_cost() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _enter = runtime.enter();
    let mut p95 = std::collections::BTreeMap::<(&str, &str), f64>::new();
    for shape in [Shape::small(), Shape::god_from_env()] {
        let dir = tempfile::tempdir().unwrap();
        let (hub, session) = hub_on(dir.path(), &shape);
        for mode in ["alone", "contended"] {
            let stop = AtomicBool::new(false);
            // Another change of the chat, saved over and over while the timed saves run; the
            // scope joins it.
            let mut took = std::thread::scope(|s| {
                if mode == "contended" {
                    s.spawn(|| {
                        let mut n = 0u64;
                        while !stop.load(Ordering::SeqCst) {
                            n += 1;
                            session.meta.lock().unwrap().turn_count = n;
                            hub.save_meta(&session);
                        }
                    });
                }
                let took = cost(&hub, &session);
                stop.store(true, Ordering::SeqCst);
                took
            });
            took.sort();
            let (p50_us, p95_us) = (percentile(&took, 50), percentile(&took, 95));
            println!(
                "META-SAVE-COST home={} mode={mode} n={} p50_us={p50_us:.1} p95_us={p95_us:.1}",
                shape.name,
                took.len()
            );
            p95.insert((shape.name, mode), p95_us);
        }
    }
    // Constant cost: the god home's p95 within a fifth of the small one's, plus the floor.
    for mode in ["alone", "contended"] {
        let (small, god) = (p95[&("small", mode)], p95[&("god", mode)]);
        assert!(god <= small * 1.2 + FLOOR_US, "{mode}: p95 small {small:.1} us, god {god:.1} us");
    }
}

/// Process CPU time (user + system), in microseconds.
fn cpu_us() -> f64 {
    // SAFETY: getrusage fills the struct it is given.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let us = |t: libc::timeval| t.tv_sec as f64 * 1e6 + t.tv_usec as f64;
    us(usage.ru_utime) + us(usage.ru_stime)
}

/// What a save costs the host in CPU (`meta_save.rs`): the process's CPU time per
/// `Hub::save_meta` of a changed `updatedAt`, as each turn's saves change it, on the long chat of
/// a small home and of a god one (whose agent reports 220 slash commands and its tool rows).
/// Manual: `cargo test -p acpmux --release --lib meta_save_cpu -- --ignored --nocapture
/// --test-threads=1`. One `META-SAVE-CPU` line per home.
#[test]
#[ignore = "manual per-save CPU measurement"]
fn meta_save_cpu() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _enter = runtime.enter();
    let saves: usize =
        std::env::var("META_SAVE_CPU_N").ok().and_then(|n| n.parse().ok()).unwrap_or(4000);
    for shape in [Shape::small(), Shape::god_from_env()] {
        let dir = tempfile::tempdir().unwrap();
        let (hub, session) = hub_on(dir.path(), &shape);
        let started = cpu_us();
        for i in 0..saves {
            session.meta.lock().unwrap().updated_at = 1_000 + i as u64;
            hub.save_meta(&session);
        }
        let per = (cpu_us() - started) / saves as f64;
        println!("META-SAVE-CPU home={} n={saves} cpu_us_per_save={per:.1}", shape.name);
    }
}
