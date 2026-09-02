//! `cmux-tui bench interact`: a client-side interaction benchmark.
//!
//! It drives a session over the raw control protocol as an ordinary client and
//! records, per user intent, the latencies an interactive frontend or an agent
//! actually feels: request to response, request to the tree delta that makes
//! the new resource visible on a separate subscriber, attach to first frame,
//! and close to response. It adds no protocol command and no resource
//! operation; it only sends existing commands. The output feeds the IX0
//! baseline of `plans/cmux-tui-zero-wait-interaction.md`.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const READ_LIMIT: usize = 16 * 1024 * 1024;
const RPC_TIMEOUT: Duration = Duration::from_secs(20);
/// How long to wait for the visibility delta after a response arrives.
const VISIBILITY_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct BenchPlan {
    pub creates_per_client: usize,
    pub clients: usize,
    pub typing_probes: usize,
}

pub(super) fn run(global: GlobalArgs, plan: BenchPlan) -> i32 {
    match execute(&global, &plan) {
        Ok(report) => match global.output {
            OutputMode::Human => {
                let mut out = io::stdout().lock();
                let _ = out.write_all(render_text(&report).as_bytes());
                let _ = out.flush();
                0
            }
            output => super::wire::print_local_success(&report.to_json(), output),
        },
        Err(error) => super::wire::print_local_error(
            &json!({"code":"bench.failed","message":error,"details":{},"retryable":false}),
            global.output,
            3,
        ),
    }
}

// ---- percentiles --------------------------------------------------------

/// Nearest-rank percentile of `samples` in milliseconds (f64). `samples` is
/// sorted in place. Returns `None` for an empty slice.
fn percentile(samples: &mut [f64], quantile: f64) -> Option<f64> {
    if samples.is_empty() {
        return None;
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let rank = (quantile * (samples.len() as f64 - 1.0)).round() as usize;
    Some(samples[rank.min(samples.len() - 1)])
}

#[derive(Default)]
struct Metric {
    samples: Vec<f64>,
}

impl Metric {
    fn record(&mut self, value: Duration) {
        self.samples.push(value.as_secs_f64() * 1000.0);
    }

    fn summary(&self) -> Option<MetricSummary> {
        if self.samples.is_empty() {
            return None;
        }
        let mut sorted = self.samples.clone();
        Some(MetricSummary {
            count: sorted.len(),
            p50: percentile(&mut sorted, 0.50).unwrap(),
            p90: percentile(&mut sorted, 0.90).unwrap(),
            p99: percentile(&mut sorted, 0.99).unwrap(),
            max: sorted.iter().copied().fold(f64::MIN, f64::max),
        })
    }
}

#[derive(Clone, Copy)]
struct MetricSummary {
    count: usize,
    p50: f64,
    p90: f64,
    p99: f64,
    max: f64,
}

// ---- visibility matching ------------------------------------------------

/// One timestamped event seen on the subscriber connection.
#[derive(Clone)]
struct TimedEvent {
    at: Instant,
    value: Value,
}

/// Find the earliest event at or after `sent` whose payload references
/// `surface_id`, and return how long after `sent` it arrived. Deltas may
/// arrive before the command response, so callers time from the request write,
/// not from the response.
fn visibility_delay(events: &[TimedEvent], sent: Instant, surface_id: u64) -> Option<Duration> {
    events
        .iter()
        .filter(|event| event.at >= sent)
        .filter(|event| event_references_surface(&event.value, surface_id))
        .map(|event| event.at.duration_since(sent))
        .min()
}

/// True if `value` mentions `surface_id` as a `surface` field anywhere in the
/// tree-delta payload (the delta carries the created surface in its entity).
fn event_references_surface(value: &Value, surface_id: u64) -> bool {
    match value {
        Value::Object(map) => {
            if map.get("surface").and_then(Value::as_u64) == Some(surface_id) {
                return true;
            }
            map.values().any(|child| event_references_surface(child, surface_id))
        }
        Value::Array(items) => {
            items.iter().any(|child| event_references_surface(child, surface_id))
        }
        _ => false,
    }
}

// ---- raw connection -----------------------------------------------------

struct Conn {
    reader: BufReader<Box<dyn transport::Stream>>,
    next_id: u64,
}

impl Conn {
    fn open(socket: &std::path::Path) -> Result<Self, String> {
        let stream = transport::connect(socket).map_err(|e| format!("connect: {e}"))?;
        stream.set_read_timeout(Some(RPC_TIMEOUT)).map_err(|e| format!("timeout: {e}"))?;
        stream.set_write_timeout(Some(RPC_TIMEOUT)).map_err(|e| format!("timeout: {e}"))?;
        Ok(Self { reader: BufReader::new(stream), next_id: 1 })
    }

    fn send(&mut self, mut request: Value) -> Result<u64, String> {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        let mut line = serde_json::to_vec(&request).map_err(|e| e.to_string())?;
        line.push(b'\n');
        self.reader.get_mut().write_all(&line).map_err(|e| format!("write: {e}"))?;
        self.reader.get_mut().flush().map_err(|e| format!("flush: {e}"))?;
        Ok(id)
    }

    fn read_value(&mut self) -> Result<Value, String> {
        let mut bytes = Vec::new();
        let read = self
            .reader
            .by_ref()
            .take((READ_LIMIT + 2) as u64)
            .read_until(b'\n', &mut bytes)
            .map_err(|e| format!("read: {e}"))?;
        if read == 0 {
            return Err("connection closed".into());
        }
        if !bytes.ends_with(b"\n") {
            return Err("partial line".into());
        }
        bytes.pop();
        serde_json::from_slice(&bytes).map_err(|e| format!("decode: {e}"))
    }

    /// Send a command and return its `data`, ignoring any event lines.
    fn request(&mut self, request: Value) -> Result<Value, String> {
        let id = self.send(request)?;
        loop {
            let value = self.read_value()?;
            if value.get("event").is_some() {
                continue;
            }
            if value.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if value.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(value.get("data").cloned().unwrap_or(Value::Null));
            }
            return Err(value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("command failed")
                .to_string());
        }
    }

    fn identify(&mut self) -> Result<Value, String> {
        self.request(json!({"cmd":"identify"}))
    }
}

// ---- execution ----------------------------------------------------------

struct SessionGuard {
    socket: std::path::PathBuf,
    owner: Option<crate::local_owner::EnsuredOwnerHandle>,
}

fn execute(global: &GlobalArgs, plan: &BenchPlan) -> Result<Report, String> {
    let (socket, guard) = ensure_session(global)?;

    // Subscriber connection: timestamp every tree delta.
    let mut subscriber = Conn::open(&socket)?;
    subscriber.identify()?;
    subscriber.request(json!({"cmd":"subscribe","tree_events":"deltas"}))?;
    let events: Arc<Mutex<Vec<TimedEvent>>> = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let subscriber_thread = spawn_subscriber(subscriber, Arc::clone(&events), Arc::clone(&stop));

    // A baseline terminal to type into.
    let mut control = Conn::open(&socket)?;
    control.identify()?;
    let baseline = control.request(json!({"cmd":"new-workspace"}))?;
    let baseline_surface = baseline["surface"].as_u64().ok_or("baseline surface missing")?;
    let active_pane = fetch_active_pane(&mut control)?;

    let report = Arc::new(Mutex::new(Report::new(&socket)));

    // Concurrent create loops.
    let mut handles = Vec::new();
    for client in 0..plan.clients.max(1) {
        let socket = socket.clone();
        let events = Arc::clone(&events);
        let report = Arc::clone(&report);
        let creates = plan.creates_per_client;
        let pane = active_pane;
        handles.push(thread::spawn(move || {
            if let Err(error) = run_create_loop(&socket, creates, client, pane, &events, &report) {
                report.lock().unwrap().errors.push(error);
            }
        }));
    }

    // Typing probe on a separate connection while creates are in flight.
    let mut probe = Conn::open(&socket)?;
    probe.identify()?;
    for _ in 0..plan.typing_probes {
        let start = Instant::now();
        match probe.request(json!({"cmd":"send","surface":baseline_surface,"text":"x"})) {
            Ok(_) => report.lock().unwrap().typing_separate.record(start.elapsed()),
            Err(error) => report.lock().unwrap().errors.push(format!("typing(separate): {error}")),
        }
    }

    for handle in handles {
        let _ = handle.join();
    }
    stop.store(true, std::sync::atomic::Ordering::Release);
    let _ = subscriber_thread.join();

    // Typing probe on the control connection after its own creates, for a
    // same-connection head-of-line comparison.
    for _ in 0..plan.typing_probes {
        let start = Instant::now();
        match control.request(json!({"cmd":"send","surface":baseline_surface,"text":"x"})) {
            Ok(_) => report.lock().unwrap().typing_same.record(start.elapsed()),
            Err(error) => report.lock().unwrap().errors.push(format!("typing(same): {error}")),
        }
    }

    drop(guard);
    Arc::try_unwrap(report)
        .map(|m| m.into_inner().unwrap())
        .map_err(|_| "report still shared".into())
}

fn run_create_loop(
    socket: &std::path::Path,
    creates: usize,
    client: usize,
    pane: u64,
    events: &Arc<Mutex<Vec<TimedEvent>>>,
    report: &Arc<Mutex<Report>>,
) -> Result<(), String> {
    let mut conn = Conn::open(socket)?;
    conn.identify()?;
    for index in 0..creates {
        let kind = index % 3;
        let command = match kind {
            0 => json!({"cmd":"new-workspace"}),
            1 => json!({"cmd":"new-tab"}),
            _ => json!({"cmd":"split","pane":pane,"dir":"right"}),
        };
        let start = Instant::now();
        let data = match conn.request(command) {
            Ok(data) => data,
            Err(error) => {
                report.lock().unwrap().errors.push(format!("create[{client}:{kind}]: {error}"));
                continue;
            }
        };
        let response = start.elapsed();
        let surface = data["surface"].as_u64();
        let terminal_id = data.get("terminal_id").and_then(Value::as_str).map(str::to_owned);

        {
            let mut report = report.lock().unwrap();
            report.create_response.record(response);
            report.record_lifecycle(data.get("lifecycle").and_then(Value::as_str));
        }

        if let Some(surface_id) = surface {
            // Give the delta a moment; it may already be recorded.
            let delay = wait_for_visibility(events, start, surface_id, VISIBILITY_GRACE);
            if let Some(delay) = delay {
                report.lock().unwrap().create_visible.record(delay);
            } else {
                report.lock().unwrap().visibility_misses += 1;
            }

            if let Some(first_frame) = measure_first_frame(socket, surface_id) {
                report.lock().unwrap().first_frame.record(first_frame);
            }

            // View-only close of this surface (default destroy for a tab).
            let close_start = Instant::now();
            match conn.request(json!({"cmd":"close-surface","surface":surface_id})) {
                Ok(_) => report.lock().unwrap().close_surface.record(close_start.elapsed()),
                Err(error) => report.lock().unwrap().errors.push(format!("close-surface: {error}")),
            }
        }

        // For terminals with a stable id, also measure the process-terminating
        // close, which blocks on host exit escalation (terminal.close_wait).
        if let Some(terminal_id) = terminal_id {
            let close_start = Instant::now();
            match conn.request(json!({"cmd":"close-terminal","terminal_id":terminal_id})) {
                Ok(_) => report.lock().unwrap().close_terminal.record(close_start.elapsed()),
                Err(error) => {
                    // A tab close may already have retired it; not an error worth failing on.
                    let _ = error;
                }
            }
        }
    }
    Ok(())
}

fn wait_for_visibility(
    events: &Arc<Mutex<Vec<TimedEvent>>>,
    sent: Instant,
    surface_id: u64,
    grace: Duration,
) -> Option<Duration> {
    let deadline = Instant::now() + grace;
    loop {
        if let Some(delay) = visibility_delay(&events.lock().unwrap(), sent, surface_id) {
            return Some(delay);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(1));
    }
}

fn measure_first_frame(socket: &std::path::Path, surface_id: u64) -> Option<Duration> {
    let mut conn = Conn::open(socket).ok()?;
    conn.identify().ok()?;
    let start = Instant::now();
    let id =
        conn.send(json!({"cmd":"attach-surface","surface":surface_id,"mode":"render"})).ok()?;
    let deadline = Instant::now() + RPC_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return None;
        }
        let value = conn.read_value().ok()?;
        if value.get("event").and_then(Value::as_str) == Some("render-state") {
            return Some(start.elapsed());
        }
        // A failed attach response ends the attempt.
        if value.get("id").and_then(Value::as_u64) == Some(id)
            && value.get("ok").and_then(Value::as_bool) == Some(false)
        {
            return None;
        }
    }
}

fn fetch_active_pane(conn: &mut Conn) -> Result<u64, String> {
    let tree = conn.request(json!({"cmd":"list-workspaces"}))?;
    let workspaces = tree["workspaces"].as_array().ok_or("no workspaces")?;
    let workspace = workspaces
        .iter()
        .find(|ws| ws["active"].as_bool() == Some(true))
        .or_else(|| workspaces.last())
        .ok_or("no active workspace")?;
    let screens = workspace["screens"].as_array().ok_or("no screens")?;
    let screen = screens
        .iter()
        .find(|s| s["active"].as_bool() == Some(true))
        .or_else(|| screens.first())
        .ok_or("no screen")?;
    screen["active_pane"].as_u64().ok_or_else(|| "no active pane".into())
}

fn spawn_subscriber(
    mut conn: Conn,
    events: Arc<Mutex<Vec<TimedEvent>>>,
    stop: Arc<std::sync::atomic::AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while !stop.load(std::sync::atomic::Ordering::Acquire) {
            match conn.read_value() {
                Ok(value) if value.get("event").is_some() => {
                    events.lock().unwrap().push(TimedEvent { at: Instant::now(), value });
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
    })
}

fn ensure_session(global: &GlobalArgs) -> Result<(std::path::PathBuf, SessionGuard), String> {
    if let Some(socket) = &global.socket {
        return Ok((socket.clone(), SessionGuard { socket: socket.clone(), owner: None }));
    }
    if let Some(session) = &global.session {
        let socket = cmux_tui_core::server::try_default_socket_path(session)
            .map_err(|e| format!("socket path: {e}"))?;
        let owner = crate::local_owner::ensure_owner_for_bench(session, &socket)?;
        return Ok((socket.clone(), SessionGuard { socket, owner: Some(owner) }));
    }
    let session = format!("bench-{:08x}", fastrand_u32());
    let socket = cmux_tui_core::server::try_default_socket_path(&session)
        .map_err(|e| format!("socket path: {e}"))?;
    let owner = crate::local_owner::ensure_owner_for_bench(&session, &socket)?;
    Ok((socket.clone(), SessionGuard { socket, owner: Some(owner) }))
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        if let Some(owner) = self.owner.take() {
            owner.stop(&self.socket);
        }
    }
}

fn fastrand_u32() -> u32 {
    let mut buf = [0u8; 4];
    getrandom::fill(&mut buf).ok();
    u32::from_le_bytes(buf)
}

// ---- report -------------------------------------------------------------

struct Report {
    socket: String,
    create_response: Metric,
    create_visible: Metric,
    first_frame: Metric,
    close_surface: Metric,
    close_terminal: Metric,
    typing_separate: Metric,
    typing_same: Metric,
    lifecycle_counts: std::collections::BTreeMap<String, u64>,
    visibility_misses: u64,
    errors: Vec<String>,
}

impl Report {
    fn new(socket: &std::path::Path) -> Self {
        Self {
            socket: socket.display().to_string(),
            create_response: Metric::default(),
            create_visible: Metric::default(),
            first_frame: Metric::default(),
            close_surface: Metric::default(),
            close_terminal: Metric::default(),
            typing_separate: Metric::default(),
            typing_same: Metric::default(),
            lifecycle_counts: std::collections::BTreeMap::new(),
            visibility_misses: 0,
            errors: Vec::new(),
        }
    }

    fn record_lifecycle(&mut self, lifecycle: Option<&str>) {
        if let Some(lifecycle) = lifecycle {
            *self.lifecycle_counts.entry(lifecycle.to_string()).or_insert(0) += 1;
        }
    }

    fn metrics(&self) -> [(&'static str, &Metric); 7] {
        [
            ("create.response_ms", &self.create_response),
            ("create.visible_ms", &self.create_visible),
            ("create.first_frame_ms", &self.first_frame),
            ("close.surface_response_ms", &self.close_surface),
            ("close.terminal_response_ms", &self.close_terminal),
            ("typing.separate_conn_ms", &self.typing_separate),
            ("typing.same_conn_ms", &self.typing_same),
        ]
    }

    fn to_json(&self) -> Value {
        let mut metrics = serde_json::Map::new();
        for (name, metric) in self.metrics() {
            if let Some(summary) = metric.summary() {
                metrics.insert(
                    name.to_string(),
                    json!({
                        "count": summary.count,
                        "p50": round(summary.p50),
                        "p90": round(summary.p90),
                        "p99": round(summary.p99),
                        "max": round(summary.max),
                    }),
                );
            }
        }
        json!({
            "commit": option_env!("CMUX_TUI_BUILD_COMMIT").unwrap_or("unknown"),
            "platform": std::env::consts::OS,
            "socket": self.socket,
            "metrics": Value::Object(metrics),
            "lifecycle_counts": self.lifecycle_counts,
            "visibility_misses": self.visibility_misses,
            "errors": self.errors,
        })
    }
}

fn round(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

fn render_text(report: &Report) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "cmux-tui bench interact ({}, socket {})\n",
        std::env::consts::OS,
        report.socket
    ));
    out.push_str(&format!(
        "{:<30}{:>8}{:>10}{:>10}{:>10}{:>10}\n",
        "metric", "count", "p50", "p90", "p99", "max"
    ));
    for (name, metric) in report.metrics() {
        if let Some(s) = metric.summary() {
            out.push_str(&format!(
                "{:<30}{:>8}{:>10.2}{:>10.2}{:>10.2}{:>10.2}\n",
                name, s.count, s.p50, s.p90, s.p99, s.max
            ));
        }
    }
    if !report.lifecycle_counts.is_empty() {
        out.push_str(&format!("lifecycle on create response: {:?}\n", report.lifecycle_counts));
    }
    if report.visibility_misses > 0 {
        out.push_str(&format!(
            "visibility misses (no delta within grace): {}\n",
            report.visibility_misses
        ));
    }
    if !report.errors.is_empty() {
        out.push_str(&format!("errors: {}\n", report.errors.len()));
        for error in report.errors.iter().take(10) {
            out.push_str(&format!("  {error}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_is_nearest_rank() {
        let mut data = vec![10.0, 20.0, 30.0, 40.0, 50.0];
        assert_eq!(percentile(&mut data.clone(), 0.0), Some(10.0));
        assert_eq!(percentile(&mut data.clone(), 0.5), Some(30.0));
        assert_eq!(percentile(&mut data, 1.0), Some(50.0));
        assert_eq!(percentile(&mut Vec::<f64>::new(), 0.5), None);
    }

    #[test]
    fn metric_summarizes_counts_and_max() {
        let mut metric = Metric::default();
        for ms in [5u64, 1, 3, 9, 7] {
            metric.record(Duration::from_millis(ms));
        }
        let summary = metric.summary().unwrap();
        assert_eq!(summary.count, 5);
        assert_eq!(summary.max, 9.0);
        assert_eq!(summary.p50, 5.0);
    }

    #[test]
    fn visibility_matches_earliest_referencing_event() {
        let base = Instant::now();
        let events = vec![
            TimedEvent { at: base, value: json!({"event":"tab-added","entity":{"surface":7}}) },
            TimedEvent {
                at: base + Duration::from_millis(5),
                value: json!({"event":"tab-added","surface":42,"index":1}),
            },
            TimedEvent {
                at: base + Duration::from_millis(9),
                value: json!({"event":"tab-added","surface":42,"index":2}),
            },
        ];
        // Sent one ms before the first matching event at +5ms.
        let sent = base + Duration::from_millis(4);
        let delay = visibility_delay(&events, sent, 42).unwrap();
        assert_eq!(delay, Duration::from_millis(1));
        // A surface never referenced returns None.
        assert!(visibility_delay(&events, sent, 999).is_none());
        // An event before `sent` is ignored.
        assert!(visibility_delay(&events, base + Duration::from_millis(6), 7).is_none());
    }

    #[test]
    fn deep_entity_reference_is_found() {
        let value = json!({
            "event":"workspace-added",
            "entity":{"screens":[{"panes":[{"tabs":[{"surface":99}]}]}]}
        });
        assert!(event_references_surface(&value, 99));
        assert!(!event_references_surface(&value, 98));
    }
}
