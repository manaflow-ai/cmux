//! Date-pinned versions: what a pin costs per connection and per reply.
//!
//! `cargo bench -p cmux-api-compat --bench version_pin` prints one line per
//! case: the median and p99 of timed runs after a warmup (no criterion; not
//! in the lockfile).
//!
//! - `resolve`: a `set-client-info {api_version}` pin resolved to a revision
//!   (once per connection), on a 24-revision dated history.
//! - `unpinned`: the per-reply cost for a client that pins nothing (the
//!   default): the daemon reads one atomic and sends the reply as is.
//! - `pinned-current`: a client pinned to the current version: the same
//!   path (its `declare` stores no translation), shown here for the record.
//! - `pinned-old-identity`: the peek and program lookup alone, for a reply
//!   kind the old version did not change.
//! - `pinned-old`: a client pinned one version back: the daemon peeks the
//!   reply's id, finds the compiled program and rewrites one renamed member
//!   of a ~2 KB `list-clients` reply (server/api_revision_wire.rs `downgrade`).

use std::hint::black_box;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use cmux_api_compat::{Change, Compat, MessageChange, Schema};
use serde::Deserialize;
use serde_json::json;

const KIND: &str = "response:list-clients";

fn history() -> Compat {
    let mut schema = Schema::new("cmux-mux", 12);
    schema.base_date = Some("2026-11-24".into());
    for month in 1..=24u32 {
        let (year, m) = (2026 + (month + 10) / 12, (month + 10) % 12 + 1);
        let date = format!("{year:04}-{m:02}-01");
        let change = if month == 24 {
            Change::Rename { path: "/data/clients/*/name".into(), to: "label".into() }
        } else {
            Change::Add { path: format!("/data/ext{month}"), default: json!(null) }
        };
        schema.push_dated(date, "", vec![MessageChange { message: KIND.into(), change }]);
    }
    Compat::new(schema).unwrap()
}

fn reply() -> Vec<u8> {
    let clients: Vec<_> = (0..12)
        .map(|i| {
            json!({"client": i, "label": format!("client {i}"), "kind": "tui",
                   "capabilities": ["shared-sizing-v1", "terminal-public-ids-v1"], "remote": false})
        })
        .collect();
    let mut data = json!({"clients": clients});
    for month in 1..24 {
        data[format!("ext{month}")] = json!(null);
    }
    serde_json::to_vec(&json!({"id": 7, "ok": true, "data": data})).unwrap()
}

#[derive(Deserialize)]
struct Peek {
    #[serde(default)]
    id: Option<serde_json::Value>,
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

fn ns(d: Duration) -> f64 {
    d.as_secs_f64() * 1e9
}

fn main() {
    let runs = 20_000;
    let compat = history();
    let schema = compat.schema();
    let current = compat.current();
    let body = reply();
    let mut out = String::new();
    let mut line = |name: &str, (median, p99): (Duration, Duration)| {
        out.push_str(&format!(
            "version_pin {name}: median {:.0} ns, p99 {:.0} ns\n",
            ns(median),
            ns(p99)
        ));
    };

    line(
        "resolve",
        time(|| drop(black_box(schema.resolve_version(black_box("2027-06-15")))), runs),
    );

    let peer = AtomicU32::new(0);
    line(
        "unpinned",
        time(
            || {
                black_box(peer.load(Ordering::Acquire) != 0);
            },
            runs,
        ),
    );

    let old = schema.resolve_version("2028-10-31").unwrap().revision;
    assert_eq!(old, current - 1);
    let program = compat.program(KIND, current, old).unwrap();
    let rewritten = program.rewrite(&body).unwrap();
    assert!(std::str::from_utf8(&rewritten).unwrap().contains(r#""name":"client 0""#));
    let (compat, body) = (&compat, &body);
    let pinned = |to: u32| {
        move || {
            let peek: Peek = serde_json::from_slice(black_box(body)).unwrap();
            black_box(peek.id);
            let program = compat.program(KIND, current, to).unwrap();
            if !program.is_identity() {
                drop(black_box(program.rewrite(black_box(body)).unwrap()));
            }
        }
    };
    let pinned_current = AtomicU32::new(0);
    line(
        "pinned-current",
        time(
            || {
                black_box(pinned_current.load(Ordering::Acquire) != 0);
            },
            runs,
        ),
    );
    line("pinned-old-identity", time(pinned(current), runs));
    line("pinned-old", time(pinned(old), runs));
    // The reply's serialization, for scale: what the daemon already spends per reply.
    let value: serde_json::Value = serde_json::from_slice(body).unwrap();
    line(
        "serialize-reply (scale)",
        time(|| drop(black_box(serde_json::to_vec(black_box(&value)).unwrap())), runs),
    );
    print!(
        "version_pin: reply={} bytes, history={} dated revisions\n{out}",
        body.len(),
        schema.revisions.len()
    );
}
