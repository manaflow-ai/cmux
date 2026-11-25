//! Chrome trace (Perfetto) output for the daemon's spans: set `CMUX_TRACE_FILE=<path>` and each
//! closed `tracing` span becomes one complete event (`"ph":"X"`) in a JSON array that
//! ui.perfetto.dev and chrome://tracing open. A span's `trace_id` field (one id per user action,
//! carried from the phone or the Mac through the hub into acpmux) is kept in `args`, and a child
//! span without one inherits its parent's, so one action's steps line up end to end.
//! Off when the variable is unset: no layer, no cost.

use std::io::Write;
use std::sync::Mutex;
use std::time::Instant;

use tracing::span::{Attributes, Id, Record};
use tracing::Subscriber;
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

/// Writes one JSON event per closed span. Perfetto reads the array without its closing `]`,
/// so a killed daemon still leaves a readable trace.
pub struct PerfTraceLayer<W: Write + Send + 'static> {
    out: Mutex<W>,
    start: Instant,
    pid: u32,
}

struct Timing {
    opened: Instant,
    args: serde_json::Map<String, serde_json::Value>,
}

struct Fields<'a>(&'a mut serde_json::Map<String, serde_json::Value>);

impl tracing::field::Visit for Fields<'_> {
    fn record_debug(&mut self, f: &tracing::field::Field, v: &dyn std::fmt::Debug) {
        self.0.insert(f.name().into(), format!("{v:?}").into());
    }
    fn record_str(&mut self, f: &tracing::field::Field, v: &str) {
        self.0.insert(f.name().into(), v.into());
    }
    fn record_u64(&mut self, f: &tracing::field::Field, v: u64) {
        self.0.insert(f.name().into(), v.into());
    }
    fn record_i64(&mut self, f: &tracing::field::Field, v: i64) {
        self.0.insert(f.name().into(), v.into());
    }
}

impl<W: Write + Send + 'static> PerfTraceLayer<W> {
    pub fn new(mut out: W) -> Self {
        let _ = out.write_all(b"[\n");
        Self { out: Mutex::new(out), start: Instant::now(), pid: std::process::id() }
    }
}

/// The layer for `CMUX_TRACE_FILE`, or None when it is unset or cannot be created.
pub fn from_env() -> Option<PerfTraceLayer<std::io::BufWriter<std::fs::File>>> {
    let path = std::env::var_os("CMUX_TRACE_FILE")?;
    let file = std::fs::File::create(path).ok()?;
    Some(PerfTraceLayer::new(std::io::BufWriter::new(file)))
}

fn thread_id() -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    std::thread::current().id().hash(&mut h);
    h.finish() % 100_000
}

impl<S, W> Layer<S> for PerfTraceLayer<W>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    W: Write + Send + 'static,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else { return };
        let mut args = serde_json::Map::new();
        attrs.record(&mut Fields(&mut args));
        if !args.contains_key("trace_id") {
            if let Some(parent) = span.parent() {
                if let Some(v) = parent.extensions().get::<Timing>().and_then(|t| t.args.get("trace_id")) {
                    args.insert("trace_id".into(), v.clone());
                }
            }
        }
        span.extensions_mut().insert(Timing { opened: Instant::now(), args });
    }

    fn on_record(&self, id: &Id, values: &Record<'_>, ctx: Context<'_, S>) {
        if let Some(span) = ctx.span(id) {
            if let Some(t) = span.extensions_mut().get_mut::<Timing>() {
                values.record(&mut Fields(&mut t.args));
            }
        }
    }

    fn on_close(&self, id: Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(&id) else { return };
        let ext = span.extensions();
        let Some(t) = ext.get::<Timing>() else { return };
        let event = serde_json::json!({
            "name": span.name(),
            "cat": span.metadata().target(),
            "ph": "X",
            "ts": t.opened.saturating_duration_since(self.start).as_micros() as u64,
            "dur": t.opened.elapsed().as_micros() as u64,
            "pid": self.pid,
            "tid": thread_id(),
            "args": t.args,
        });
        if let Ok(mut out) = self.out.lock() {
            let _ = writeln!(out, "{event},");
            let _ = out.flush();
        }
    }
}

#[cfg(test)]
#[path = "perf_trace_tests.rs"]
mod tests;
