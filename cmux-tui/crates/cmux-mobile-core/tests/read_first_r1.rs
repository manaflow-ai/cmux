//! R1 time to readable for the read-first track (goals/mobile-speed-ios-bench.md in cmuxterm-hq;
//! Leo, 2026-11-22: "like im sure theres a hell of s lot more value in being able to read nigh
//! instantly as much as possible"): from the tap to the rows the first frame draws, read from the
//! phone's own store with the link cut. The headless network-conditions benches have no phone
//! store, so their first content is R2 (time to fresh); this is R1's emitting leg.
//!
//! What it times, per run: open the store on its directory, get the Agent Chats entry, decode it
//! to rows. That is the Rust half of `PhoneReadFirst.read` -> `AgentChatsMemory` on a cold launch;
//! Swift's decode and SwiftUI's draw are not in it. The value is the app's own stored form
//! (`StoredPage` in AgentChatsMemory.swift: the first `storedChatLimit` = 60 chats of the Mac's
//! list), so the Mac's history size (1x = 60 chats, 10x = 600, 100x = 6,000) must not move it.
//!
//! - cold: a fresh `ReadStore` on a directory holding 64 entries (the app's bound) that were
//!   written after the one read, the first read since.
//! - warm: the same store again, the entry read before (a switch back to the list).
//!
//! `NETCOND_MODE=duress` reads while two threads rewrite the other 63 entries (the app writing
//! pages as Macs answer) and the other cores spin, with the longest prompts the list keeps.
//!
//! Prints `NETCOND {"surface":"chat","profile":"no-link@1","phase":"cold","scale":"1x",
//! "metric":"r1_ms","value":0.21,"run":0,"seed":0}` per run, as mobile_link_conditions.rs does.
//! `#[ignore]`: `cargo test --release -p cmux-mobile-core --test read_first_r1 -- --ignored
//! --nocapture` (scripts/measure/ios-network-conditions.sh runs it with the chat surface).

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Instant;

use cmux_mobile_core::read_store::{ReadKey, ReadStore, ReadStoreLimits};
use serde_json::{Value, json};

/// The app's bounds (PhoneReadFirst.swift) and the first page it keeps (AgentChatsMemory.swift).
const LIMITS: ReadStoreLimits = ReadStoreLimits { max_entries: 64, max_value_bytes: 256 * 1024 };
const STORED_CHAT_LIMIT: usize = 60;

fn env_or(name: &str, default: &str) -> String {
    std::env::var(name).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.to_owned())
}

/// The Mac's list at `chats` chats, cut to the stored first page, in StoredPage's JSON form.
fn stored_page(chats: usize, prompt_bytes: usize) -> Vec<u8> {
    let rows: Vec<Value> = (0..chats.min(STORED_CHAT_LIMIT))
        .map(|i| {
            let harness = ["claude", "codex", "opencode"][i % 3];
            let status = if i % 4 == 0 { "running" } else { "idle" };
            json!({
                "id": format!("chat-{i:06}-6f1c2b0e-9a4d-4c55-8d0e-{i:012}"),
                "title": format!("Fix the reconnect toast pushing the transcript up #{i}"),
                "harness": harness,
                "cwd": format!("/Users/someone/Projects/cmux/lane-{i}"),
                "status": status,
                "updatedAt": 1_795_000_000.0 + i as f64,
                "archived": false,
                "lastPrompt": "p".repeat(prompt_bytes),
            })
        })
        .collect();
    let next = (chats > STORED_CHAT_LIMIT).then(|| format!("cursor-{STORED_CHAT_LIMIT}"));
    serde_json::to_vec(&json!({"chats": rows, "nextCursor": next})).expect("encode")
}

/// Open, get, decode: the rows the first frame draws, and how long that took (ms).
fn readable(directory: &PathBuf, key: &ReadKey, store: Option<&ReadStore>) -> (f64, usize) {
    let start = Instant::now();
    let opened;
    let store = match store {
        Some(store) => store,
        None => {
            opened = ReadStore::open(directory, LIMITS).expect("open");
            &opened
        }
    };
    let rows = store
        .get(key)
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|page| page["chats"].as_array().map(Vec::len))
        .unwrap_or(0);
    (start.elapsed().as_secs_f64() * 1000.0, rows)
}

fn scale_factor(scale: &str) -> usize {
    scale.trim_end_matches('x').parse().unwrap_or(1)
}

#[test]
#[ignore = "bench: scripts/measure/ios-network-conditions.sh runs it"]
fn r1_time_to_readable_from_the_phone_store() {
    let duress = env_or("NETCOND_MODE", "links") == "duress";
    let runs: usize = env_or("NETCOND_RUNS", "20").parse().unwrap_or(20);
    let seed_base: u64 = env_or("NETCOND_SEED_BASE", "0").parse().unwrap_or(0);
    let scales = env_or("NETCOND_SCALES", "1x,10x,100x");
    // The longest prompts the list keeps under duress; a short one otherwise.
    let prompt_bytes = if duress { 3_000 } else { 200 };
    let profile = "no-link@1";
    let base = std::env::temp_dir().join(format!("cmux-r1-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);

    let stop = Arc::new(AtomicBool::new(false));
    let mut load = Vec::new();
    if duress {
        let cores = thread::available_parallelism().map_or(2, |n| n.get());
        for _ in 0..cores.saturating_sub(3) {
            let stop = stop.clone();
            load.push(thread::spawn(move || {
                let mut x = 1u64;
                while !stop.load(Ordering::Relaxed) {
                    x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                    std::hint::black_box(x);
                }
            }));
        }
    }

    for scale in scales.split(',') {
        let chats = STORED_CHAT_LIMIT * scale_factor(scale);
        let page = stored_page(chats, prompt_bytes);
        assert!(page.len() <= LIMITS.max_value_bytes, "stored page {} bytes", page.len());
        let directory = base.join(scale);
        let writers_stop = Arc::new(AtomicBool::new(false));
        let mut writers = Vec::new();
        if duress {
            for w in 0..2 {
                let (directory, stop, page) =
                    (directory.clone(), writers_stop.clone(), page.clone());
                writers.push(thread::spawn(move || {
                    let store = ReadStore::open(&directory, LIMITS).expect("open");
                    let mut i = 0usize;
                    while !stop.load(Ordering::Relaxed) {
                        let key = ReadKey::new(
                            "account",
                            format!("mac-{}", 1 + (i * 2 + w) % 63),
                            "agent_chats",
                        );
                        let _ = store.put(&key, &page);
                        i += 1;
                    }
                }));
            }
        }
        for run in 0..runs {
            let seed = seed_base + run as u64;
            let key = ReadKey::new("account", "mac-0", "agent_chats");
            {
                // The entry the tap reads, then the other 63 written after it.
                let store = ReadStore::open(&directory, LIMITS).expect("open");
                store.put(&key, &page).expect("put");
                for other in 1..LIMITS.max_entries {
                    store
                        .put(&ReadKey::new("account", format!("mac-{other}"), "agent_chats"), &page)
                        .expect("put");
                }
            }
            let (cold, rows) = readable(&directory, &key, None);
            let store = ReadStore::open(&directory, LIMITS).expect("open");
            let _ = readable(&directory, &key, Some(&store));
            let (warm, warm_rows) = readable(&directory, &key, Some(&store));
            for (phase, ms, rows) in [("cold", cold, rows), ("warm", warm, warm_rows)] {
                let value = (rows > 0).then_some(ms);
                if value.is_none() {
                    println!(
                        "NETCOND-ERROR chat {phase} {scale} run {run}: no rows from the store"
                    );
                }
                println!(
                    "NETCOND {}",
                    json!({"surface": "chat", "profile": profile, "phase": phase, "scale": scale,
                           "metric": "r1_ms", "value": value, "run": run, "seed": seed})
                );
            }
            println!(
                "NETCOND {}",
                json!({"surface": "chat", "profile": profile, "phase": "cold", "scale": scale,
                       "metric": "bytes_down", "value": 0, "run": run, "seed": seed})
            );
        }
        writers_stop.store(true, Ordering::Relaxed);
        for writer in writers {
            let _ = writer.join();
        }
        eprintln!("netcond: r1 chat {scale}: {runs} runs, stored page {} bytes", page.len());
    }
    stop.store(true, Ordering::Relaxed);
    for thread in load {
        let _ = thread.join();
    }
    let _ = fs::remove_dir_all(&base);
}
