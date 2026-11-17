//! Bench: what one lifecycle call costs in the ledger as it grows, and the
//! GCP adapter's request build. `cargo run --release -p cmux-machine-provider
//! --example machine_provider_bench [-- DIR]`. DIR defaults to the temp dir;
//! each call syncs, so the disk under DIR sets the floor.

use cmux_machine_provider::{
    AccessToken, CreateSpec, FakeProvider, GcpProvider, IdempotencyKey, Ledger, MachineProvider,
    Op, Request, Transport, TransportError,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn spec() -> CreateSpec {
    CreateSpec {
        image: "projects/cmux-images/global/images/cmux-linux-2026-11-17".into(),
        machine_type: "e2-standard-4".into(),
        zone: "us-central1-a".into(),
        disk_gb: 50,
        idle_grace_minutes: 30,
        labels: BTreeMap::new(),
    }
}

fn pct(samples: &mut [Duration], p: f64) -> Duration {
    samples.sort();
    samples[((samples.len() as f64 - 1.0) * p).round() as usize]
}

struct Ok200;
impl Transport for Ok200 {
    fn send(
        &self,
        _: &str,
        _: &str,
        _: &AccessToken,
        _: Option<&Value>,
    ) -> Result<(u16, Value), TransportError> {
        Ok((200, serde_json::json!({"name": "operation-1", "status": "RUNNING"})))
    }
}

fn main() {
    let root = std::env::args().nth(1).map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    println!(
        "ledger entries | open ms | new op p50 us | new op p95 us | replay p50 us | lost-answer settle p50 us"
    );
    // 1,000 real entries (each call syncs), then copies of them under other
    // keys for the larger ledgers.
    let seed_path = root.join(format!("cmux-mp-bench-{}-seed.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&seed_path);
    {
        let fake = FakeProvider::new();
        let mut ledger = Ledger::open(&seed_path).unwrap();
        for i in 0..1_000 {
            let key = IdempotencyKey::new(&format!("fill-{i}")).unwrap();
            ledger.run(&fake, &key, &Request::create(spec())).unwrap();
        }
    }
    let seed = std::fs::read_to_string(&seed_path).unwrap();
    let _ = std::fs::remove_file(&seed_path);
    for size in [0usize, 1_000, 10_000, 100_000] {
        let path = root.join(format!("cmux-mp-bench-{}-{size}.jsonl", std::process::id()));
        let text: String = (0..size / 1_000)
            .map(|copy| seed.replace("\"fill-", &format!("\"fill{copy}-")))
            .collect();
        std::fs::write(&path, text).unwrap();
        let fake = FakeProvider::new();
        let opened = Instant::now();
        let mut ledger = Ledger::open(&path).unwrap();
        let open_ms = opened.elapsed().as_secs_f64() * 1e3;
        let (mut fresh, mut replay, mut settle) = (Vec::new(), Vec::new(), Vec::new());
        for i in 0..200 {
            let key = IdempotencyKey::new(&format!("bench-{i}")).unwrap();
            let t = Instant::now();
            let out = ledger.run(&fake, &key, &Request::create(spec())).unwrap();
            fresh.push(t.elapsed());
            let t = Instant::now();
            ledger.run(&fake, &key, &Request::create(spec())).unwrap();
            replay.push(t.elapsed());
            let machine = out.receipt().machine.clone();
            let stop = IdempotencyKey::new(&format!("stop-{i}")).unwrap();
            fake.lose_next_answer.set(true);
            let _ = ledger.run(&fake, &stop, &Request::on(Op::Stop, &machine));
            let t = Instant::now();
            ledger.run(&fake, &stop, &Request::on(Op::Stop, &machine)).unwrap();
            settle.push(t.elapsed());
        }
        println!(
            "{size:>14} | {open_ms:>7.1} | {:>13.0} | {:>13.0} | {:>13.1} | {:>24.0}",
            pct(&mut fresh, 0.5).as_secs_f64() * 1e6,
            pct(&mut fresh, 0.95).as_secs_f64() * 1e6,
            pct(&mut replay, 0.5).as_secs_f64() * 1e6,
            pct(&mut settle, 0.5).as_secs_f64() * 1e6,
        );
        let _ = std::fs::remove_file(&path);
    }
    let provider = GcpProvider::new(
        "my-project",
        "us-central1-a",
        AccessToken::new(b"t").unwrap(),
        Box::new(Ok200),
    )
    .unwrap();
    let key = IdempotencyKey::new("build").unwrap();
    let machine = provider.machine_for(&key);
    let spec = spec();
    let mut build = Vec::new();
    for _ in 0..10_000 {
        let t = Instant::now();
        std::hint::black_box(provider.insert_body(&key, &machine, &spec));
        build.push(t.elapsed());
    }
    println!(
        "gcp insert body build: p50 {:.1} us, p95 {:.1} us",
        pct(&mut build, 0.5).as_secs_f64() * 1e6,
        pct(&mut build, 0.95).as_secs_f64() * 1e6
    );
}
