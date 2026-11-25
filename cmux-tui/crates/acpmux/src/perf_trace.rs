//! Chrome trace (Perfetto) output for one user action end to end: set `CMUX_TRACE_FILE=<path>`
//! on the daemon and each closed `tracing` span becomes one complete event (`"ph":"X"`) in a JSON
//! array that ui.perfetto.dev and chrome://tracing open. A span's `trace_id` field (one W3C trace
//! id per user action, minted where the action starts: the Mac app's keypress, the phone's tap)
//! is kept in `args`, and a child span without one inherits its parent's, so one action's steps
//! line up end to end.
//!
//! The daemon is the one writer. The app and its webviews record their own steps (keypress to
//! paint) and hand them over with `_acpmux/trace/spans` (`record_client_spans`), so every process
//! of one action lands in the same file on one clock: `ts` is wall-clock microseconds since the
//! Unix epoch, which the Mac app (`Date`) and a webview (`performance.timeOrigin + now()`) share.
//! Each span may carry `floor_us`, its speed-of-light floor (the least the step could cost), so a
//! trace reads as "this step took X against a floor of Y".
//!
//! Off when the variable is unset: no layer, no cost; `_acpmux/trace/spans` answers
//! `{"recorded":0}` and the app stops sending (`enabled` in `_acpmux/trace/status`).

use std::io::Write;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};
use tracing::Subscriber;
use tracing::span::{Attributes, Id, Record};
use tracing_subscriber::Layer;
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;

/// The method the app and webviews send their own spans with.
pub const METHOD_SPANS: &str = "_acpmux/trace/spans";
/// Whether this daemon writes a trace, so a client sends spans only when one is read.
pub const METHOD_STATUS: &str = "_acpmux/trace/status";

/// Most spans one `_acpmux/trace/spans` call writes, so a runaway client cannot fill the disk.
const MAX_CLIENT_SPANS: usize = 512;

type Out = Arc<Mutex<Box<dyn Write + Send>>>;

/// The one trace file of this process, shared by the span layer and the client spans.
static SINK: OnceLock<Out> = OnceLock::new();

/// Writes one JSON event per closed span. Perfetto reads the array without its closing `]`,
/// so a killed daemon still leaves a readable trace.
pub struct PerfTraceLayer {
    out: Out,
    pid: u32,
}

struct Timing {
    opened: Instant,
    opened_us: u64,
    args: Map<String, Value>,
}

struct Fields<'a>(&'a mut Map<String, Value>);

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

/// Microseconds since the Unix epoch: the one clock every process of a trace shares.
pub fn now_us() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0)
}

impl PerfTraceLayer {
    pub fn new<W: Write + Send + 'static>(mut out: W) -> Self {
        let _ = out.write_all(b"[\n");
        let _ = out.flush();
        Self { out: Arc::new(Mutex::new(Box::new(out))), pid: std::process::id() }
    }
}

/// The layer for `CMUX_TRACE_FILE`, or None when it is unset or cannot be created. It also
/// becomes the sink `_acpmux/trace/spans` writes to.
pub fn from_env() -> Option<PerfTraceLayer> {
    let path = std::env::var_os("CMUX_TRACE_FILE")?;
    let file = std::fs::File::create(path).ok()?;
    let layer = PerfTraceLayer::new(std::io::BufWriter::new(file));
    let _ = SINK.set(layer.out.clone());
    Some(layer)
}

/// Whether this process writes a trace.
pub fn enabled() -> bool {
    SINK.get().is_some()
}

/// The 32-hex trace id of a W3C `traceparent` (`00-<trace-id>-<parent-id>-<flags>`).
pub fn trace_id_of_traceparent(tp: &str) -> Option<&str> {
    let mut parts = tp.split('-');
    let (_version, id) = (parts.next()?, parts.next()?);
    (id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())).then_some(id)
}

/// The caller's end-to-end id on a request: `params._meta.traceId`, or the trace id of
/// `params._meta.traceparent` (the Mac and the phone mint one per user action and send it on
/// every request that action makes).
pub fn trace_id_of(params: Option<&Value>) -> Option<&str> {
    let meta = params?.get("_meta")?;
    let ok = |t: &&str| !t.is_empty() && t.len() <= 128;
    meta.get("traceId").and_then(Value::as_str).filter(ok).or_else(|| {
        meta.get("traceparent").and_then(Value::as_str).and_then(trace_id_of_traceparent)
    })
}

/// The span one RPC request runs in; its `trace_id` is empty when the caller sent none.
pub fn request_span(method: &str, params: Option<&Value>) -> tracing::Span {
    tracing::info_span!("rpc", method = method, trace_id = trace_id_of(params).unwrap_or(""))
}

fn thread_id() -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    std::thread::current().id().hash(&mut h);
    h.finish() % 100_000
}

fn write_event(out: &Out, event: &Value) {
    if let Ok(mut out) = out.lock() {
        let _ = writeln!(out, "{event},");
        let _ = out.flush();
    }
}

/// A process's name row in Perfetto (a metadata event), so the app, its webview and the daemon
/// read as named tracks.
fn process_name_event(pid: u64, name: &str) -> Value {
    json!({"name": "process_name", "ph": "M", "pid": pid, "tid": 0, "args": {"name": name}})
}

/// `_acpmux/trace/spans`: the app's or a webview's own steps, `{"process": "mac-app",
/// "pid": N, "spans": [{"name", "ts_us", "dur_us", "trace_id", "floor_us"?, "args"?, "tid"?}]}`,
/// written to this daemon's trace on the shared epoch clock. Answers how many it wrote.
pub fn record_client_spans(params: &Value) -> Value {
    let Some(out) = SINK.get() else { return json!({"recorded": 0, "enabled": false}) };
    write_client_spans(out, params)
}

fn write_client_spans(out: &Out, params: &Value) -> Value {
    let process = params.get("process").and_then(Value::as_str).unwrap_or("client");
    let pid = params.get("pid").and_then(Value::as_u64).unwrap_or(0);
    let spans = params.get("spans").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    if pid != 0 && !spans.is_empty() {
        write_event(out, &process_name_event(pid, process));
    }
    let mut recorded = 0;
    for s in spans.iter().take(MAX_CLIENT_SPANS) {
        let (Some(name), Some(ts), Some(dur)) = (
            s.get("name").and_then(Value::as_str),
            s.get("ts_us").and_then(Value::as_u64),
            s.get("dur_us").and_then(Value::as_u64),
        ) else {
            continue;
        };
        let mut args = s.get("args").and_then(Value::as_object).cloned().unwrap_or_default();
        if let Some(t) = s.get("trace_id").and_then(Value::as_str).filter(|t| t.len() <= 128) {
            args.insert("trace_id".into(), t.into());
        }
        if let Some(f) = s.get("floor_us").and_then(Value::as_u64) {
            args.insert("floor_us".into(), f.into());
            args.insert("gap_us".into(), dur.saturating_sub(f).into());
        }
        let event = json!({
            "name": name,
            "cat": process,
            "ph": "X",
            "ts": ts,
            "dur": dur,
            "pid": pid,
            "tid": s.get("tid").and_then(Value::as_u64).unwrap_or(1),
            "args": args,
        });
        write_event(out, &event);
        recorded += 1;
    }
    json!({"recorded": recorded, "enabled": true})
}

impl<S> Layer<S> for PerfTraceLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else { return };
        let mut args = Map::new();
        attrs.record(&mut Fields(&mut args));
        let empty = args.get("trace_id").and_then(Value::as_str).is_some_and(str::is_empty);
        if empty || !args.contains_key("trace_id") {
            let inherited = span.parent().and_then(|p| {
                p.extensions().get::<Timing>().and_then(|t| t.args.get("trace_id").cloned())
            });
            match inherited {
                Some(v) => {
                    args.insert("trace_id".into(), v);
                }
                None if empty => {
                    args.remove("trace_id");
                }
                None => {}
            }
        }
        span.extensions_mut().insert(Timing { opened: Instant::now(), opened_us: now_us(), args });
    }

    fn on_record(&self, id: &Id, values: &Record<'_>, ctx: Context<'_, S>) {
        if let Some(span) = ctx.span(id)
            && let Some(t) = span.extensions_mut().get_mut::<Timing>()
        {
            values.record(&mut Fields(&mut t.args));
        }
    }

    fn on_close(&self, id: Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(&id) else { return };
        let ext = span.extensions();
        let Some(t) = ext.get::<Timing>() else { return };
        let event = json!({
            "name": span.name(),
            "cat": span.metadata().target(),
            "ph": "X",
            "ts": t.opened_us,
            "dur": t.opened.elapsed().as_micros() as u64,
            "pid": self.pid,
            "tid": thread_id(),
            "args": t.args,
        });
        write_event(&self.out, &event);
    }
}

#[cfg(test)]
#[path = "perf_trace_tests.rs"]
mod tests;
