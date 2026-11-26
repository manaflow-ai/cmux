//! Per-message cost of the wire: `cargo run --release --example bench -p cmux-acpmux-remote-wire`.
use cmux_acpmux_remote_wire::wire::{Config, Event, Wire};
use std::time::Instant;

fn main() {
    let mut wire = Wire::new(Config { session: Some("s1".into()), ..Config::default() });
    let n = 200_000u32;
    let record = r#"{"seq":1,"kind":"transcript","payload":{"text":"hello world, a typical streamed chunk"}}"#;
    let start = Instant::now();
    let mut sink = 0usize;
    for _ in 0..n {
        sink += wire.event(Event::Record { data: record.into() }).len();
    }
    let per_event = start.elapsed().as_nanos() as f64 / f64::from(n);
    let frame = r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/typing","params":{"sessionId":"s1","on":true}}"#;
    let start = Instant::now();
    for _ in 0..n {
        let step = wire.frame(frame);
        sink += step.effects.len();
        for e in step.effects {
            if let cmux_acpmux_remote_wire::wire::Effect::Call { task, .. } = e {
                sink += wire.done(task, Ok("{}".into())).len();
            }
        }
    }
    let per_frame = start.elapsed().as_nanos() as f64 / f64::from(n);
    println!("event {per_event:.0} ns/msg, frame+answer {per_frame:.0} ns/msg (sink {sink})");
}
