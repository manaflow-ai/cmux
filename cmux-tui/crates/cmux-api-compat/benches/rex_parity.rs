//! Rex parity bench: 10,000-revision chains of pathological changes applied
//! to a ~20 KB message. Rex reports ~35 us per upgrade for this case.
//!
//! `cargo bench -p cmux-api-compat --bench rex_parity` prints one line per
//! scenario. No criterion (not in the lockfile): a fixed warmup, then the
//! median and p99 of timed runs.

use std::hint::black_box;
use std::time::{Duration, Instant};

use cmux_api_compat::{Change, Compat, Conversion, Direction, MessageChange, Schema};
use serde_json::{Value, json};

const KIND: &str = "event:tree";
const REVISIONS: u32 = 10_000;
const BASE: u32 = 1;

fn body() -> Vec<u8> {
    let mut workspaces = Vec::new();
    let mut i = 0;
    loop {
        workspaces.push(json!({
            "id": i,
            "name": format!("workspace {i}"),
            "cwd": format!("/Users/someone/fun/project-{i}/src"),
            "color": "blue",
            "unread": i % 7,
            "pinned": i % 3 == 0,
            "panes": [
                {"id": i * 10, "title": "zsh", "cols": 120, "rows": 40, "focused": true},
                {"id": i * 10 + 1, "title": "claude", "cols": 80, "rows": 40, "focused": false}
            ],
            "meta": {"created_at": "2026-10-19T00:00:00Z", "tags": ["a", "b"], "notes": "x".repeat(20)}
        }));
        let doc = json!({"event": "tree", "seq": 42, "workspaces": workspaces});
        let bytes = serde_json::to_vec(&doc).unwrap();
        if bytes.len() >= 20 * 1024 {
            return bytes;
        }
        i += 1;
    }
}

fn change(c: Change) -> Vec<MessageChange> {
    vec![MessageChange { message: KIND.into(), change: c }]
}

/// Each scenario returns one change per revision.
fn scenario(name: &str, rev: u32) -> Change {
    let k = rev - BASE; // 1..=REVISIONS
    match name {
        // The same hot member renamed 10,000 times, on every array element.
        "rename-churn" => {
            let from = if k == 1 { "name".to_owned() } else { format!("name{}", k - 1) };
            Change::Rename { path: format!("/workspaces/*/{from}"), to: format!("name{k}") }
        }
        // 10,000 distinct members added then removed at paths the body lacks:
        // a wide trie that the message mostly never touches.
        "wide-unrelated" => {
            let slot = k.div_ceil(2);
            if k % 2 == 1 {
                Change::Add { path: format!("/ext{slot}/deep/field"), default: json!(slot) }
            } else {
                Change::Remove { path: format!("/ext{slot}/deep/field"), default: json!(slot) }
            }
        }
        // Every streaming-capable rule kind, cycling over hot paths.
        "mixed-streaming" => match k % 6 {
            0 => Change::Rename {
                path: format!("/workspaces/*/{}", chained("name", k)),
                to: format!("name_{k}"),
            },
            1 => Change::Add { path: format!("/workspaces/*/f{k}"), default: json!(k) },
            2 => {
                Change::Remove { path: format!("/workspaces/*/f{}", k - 1), default: json!(k - 1) }
            }
            3 => Change::RenameValue {
                path: "/workspaces/*/color".into(),
                from: json!(if k % 12 == 3 { "blue" } else { "azure" }),
                to: json!(if k % 12 == 3 { "azure" } else { "blue" }),
            },
            4 => Change::Fill {
                path: "/workspaces/*/panes/*/zoom".into(),
                default: json!(1),
                direction: Direction::Both,
            },
            _ => Change::Rename {
                path: format!("/workspaces/*/panes/*/{}", chained("title", k)),
                to: format!("title_{k}"),
            },
        },
        // Adds leaf retypes and cross-parent moves, which parse subtrees.
        "mixed-materializing" => match k % 4 {
            0 => Change::Retype {
                path: "/workspaces/*/unread".into(),
                up: Conversion::NumberToString,
                down: Conversion::StringToNumber,
            },
            1 => Change::Retype {
                path: "/workspaces/*/unread".into(),
                up: Conversion::StringToNumber,
                down: Conversion::NumberToString,
            },
            2 => Change::Move {
                from: "/workspaces/*/cwd".into(),
                path: "/workspaces/*/location/cwd".into(),
            },
            _ => Change::Move {
                from: "/workspaces/*/location/cwd".into(),
                path: "/workspaces/*/cwd".into(),
            },
        },
        _ => unreachable!(),
    }
}

/// The member's name before step `k` of a rename every 6 steps.
fn chained(base: &str, k: u32) -> String {
    if k <= 6 { base.to_owned() } else { format!("{base}_{}", k - 6) }
}

fn build(name: &str) -> Compat {
    let mut schema = Schema::new("bench", BASE);
    for rev in BASE + 1..=BASE + REVISIONS {
        schema.push("", change(scenario(name, rev)));
    }
    Compat::new(schema).unwrap()
}

fn time<F: FnMut()>(mut f: F, runs: usize) -> (Duration, Duration) {
    for _ in 0..runs / 10 + 10 {
        f();
    }
    let mut samples: Vec<Duration> = (0..runs)
        .map(|_| {
            let start = Instant::now();
            f();
            start.elapsed()
        })
        .collect();
    samples.sort();
    (samples[runs / 2], samples[runs * 99 / 100])
}

fn us(d: Duration) -> f64 {
    d.as_secs_f64() * 1e6
}

#[allow(dead_code)] // The test harness includes this file and calls `run` instead.
fn main() {
    run(&mut std::io::stdout(), 2000);
}

/// Runs every scenario and writes one line per scenario to `out`.
pub fn run(out: &mut dyn std::io::Write, runs: usize) {
    let input = body();
    let top = BASE + REVISIONS;
    writeln!(
        out,
        "rex_parity: body={} bytes, chain={} revisions (Rex: ~35 us upgrade, 20 KB, 10k chain)",
        input.len(),
        REVISIONS
    )
    .unwrap();
    for name in ["rename-churn", "wide-unrelated", "mixed-streaming", "mixed-materializing"] {
        let compat = build(name);
        let start = Instant::now();
        let up = compat.program(KIND, BASE, top).unwrap();
        let compile_up = start.elapsed();
        let up_out = up.rewrite(&input).unwrap().into_owned();
        let start = Instant::now();
        let down = compat.program(KIND, top, BASE).unwrap();
        let compile_down = start.elapsed();

        // Correctness: the streaming result equals rule-by-rule application.
        let mut reference: Value = serde_json::from_slice(&input).unwrap();
        up.apply_reference(&mut reference);
        assert_eq!(
            serde_json::from_slice::<Value>(&up_out).unwrap(),
            reference,
            "{name}: upgrade mismatch"
        );

        let (up_med, up_p99) =
            time(|| drop(black_box(up.rewrite(black_box(&input)).unwrap())), runs);
        let (down_med, down_p99) =
            time(|| drop(black_box(down.rewrite(black_box(&up_out)).unwrap())), runs);
        writeln!(
        out,
            "scenario={name} trie_nodes={} compile_up_ms={:.2} compile_down_ms={:.2} upgrade_median_us={:.1} upgrade_p99_us={:.1} downgrade_median_us={:.1} downgrade_p99_us={:.1}",
            up.trie_size(),
            compile_up.as_secs_f64() * 1e3,
            compile_down.as_secs_f64() * 1e3,
            us(up_med),
            us(up_p99),
            us(down_med),
            us(down_p99),
        )
        .unwrap();
    }

    // Broadcast: 1,000 peers spread over 4 revisions -> 4 translations, not 1,000.
    let compat = build("mixed-streaming");
    let peers: Vec<u32> =
        (0..1000).map(|i| [BASE, BASE + 2500, BASE + 5000, BASE + 7500][i % 4]).collect();
    for &rev in &peers[..4] {
        compat.program(KIND, top, rev).unwrap();
    }
    let mut translations = 0;
    let (med, p99) = time(
        || {
            let mut broadcast = compat.broadcast(KIND, top, &input);
            for &rev in &peers {
                black_box(broadcast.for_peer(rev).unwrap());
            }
            translations = broadcast.translations();
        },
        runs / 10,
    );
    writeln!(
        out,
        "scenario=broadcast peers={} distinct_chains={translations} total_median_us={:.1} total_p99_us={:.1}",
        peers.len(),
        us(med),
        us(p99)
    )
    .unwrap();

    // Copy floor: the cost of touching every byte once.
    let (med, _) = time(|| drop(black_box(black_box(&input).to_vec())), runs);
    writeln!(out, "scenario=memcpy-floor median_us={:.2}", us(med)).unwrap();
    let (med, _) = time(
        || drop(black_box(serde_json::from_slice::<Value>(black_box(&input)).unwrap())),
        runs / 4,
    );
    writeln!(out, "scenario=serde-parse-only median_us={:.1}", us(med)).unwrap();
}
