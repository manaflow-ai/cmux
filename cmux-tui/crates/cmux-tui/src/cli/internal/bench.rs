//! `cmux-tui bench interact`: a client-side interaction benchmark.
//!
//! It drives a session over the raw control protocol as an ordinary client and
//! records, per user intent, the latencies an interactive frontend or an agent
//! actually feels: request to response, request to the tree delta that makes
//! the new resource visible on a separate subscriber, attach to first frame,
//! and close to response. It adds no protocol command and no resource
//! operation; it only sends existing commands. The output feeds the IX0
//! baseline of `plans/cmux-tui-zero-wait-interaction.md`.
//!
//! The bench owns the session it runs against: at the end it closes every
//! terminal that appeared during the run (`server stop` keeps terminal hosts
//! alive by design, so a bench that only detached views would leak one host
//! and one shell per create), and it exits non-zero when any create, close, or
//! probe failed so a degraded environment cannot pass as a measurement.

use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use crate::cli::{GlobalArgs, OutputMode};

const READ_LIMIT: usize = 16 * 1024 * 1024;
const RPC_TIMEOUT: Duration = Duration::from_secs(20);
/// How long to wait for the visibility delta after a response arrives.
const VISIBILITY_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BenchPlan {
    pub creates_per_client: usize,
    pub clients: usize,
    pub typing_probes: usize,
}

pub(crate) fn run(global: GlobalArgs, plan: BenchPlan) -> i32 {
    match execute(&global, &plan) {
        Ok(report) => {
            // Exit 1 when any create, close, or probe errored: percentiles
            // over a partial sample are not a measurement. Usage errors are
            // 2 and transport failures 3, as in the rest of the CLI.
            let failed = !report.errors.is_empty();
            let code = match global.output {
                OutputMode::Human => {
                    let mut out = io::stdout().lock();
                    let _ = out.write_all(render_text(&report).as_bytes());
                    let _ = out.flush();
                    0
                }
                output => crate::cli::wire::print_local_success(&report.to_json(), output),
            };
            if failed { 1 } else { code }
        }
        Err(error) => crate::cli::wire::print_local_error(
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

/// The order in which a create connection submits requests before it drains
/// any response. Two same-connection typing probes exist because they answer
/// different questions: `TypingInterleaved` follows each create request, so
/// its distribution is what one keystroke waits when 1..K creates are in
/// flight ahead of it; `TypingAfterBatch` probes are all submitted after the
/// whole batch, so they share one value, the wait behind the entire batch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SubmissionKind {
    Create { index: usize, kind: usize },
    TypingInterleaved { index: usize },
    TypingAfterBatch { probe: usize },
}

fn same_connection_submission_plan(creates: usize, typing_probes: usize) -> Vec<SubmissionKind> {
    let mut submissions = Vec::with_capacity(creates * 2 + typing_probes);
    for index in 0..creates {
        submissions.push(SubmissionKind::Create { index, kind: index % 3 });
        if typing_probes > 0 {
            submissions.push(SubmissionKind::TypingInterleaved { index });
        }
    }
    submissions.extend((0..typing_probes).map(|probe| SubmissionKind::TypingAfterBatch { probe }));
    submissions
}

/// Terminal ids to `close-terminal` at teardown: every terminal that is not in
/// the pre-bench snapshot and is not already gone. The bench owns the session
/// it runs against, so anything that appeared during the run is its own.
fn teardown_close_plan<'a>(
    initial: &HashSet<String>,
    current: impl IntoIterator<Item = (&'a str, &'a str)>,
) -> Vec<String> {
    current
        .into_iter()
        .filter(|(terminal_id, _)| !initial.contains(*terminal_id))
        .filter(|(_, lifecycle)| !matches!(*lifecycle, "tombstoned" | "exited"))
        .map(|(terminal_id, _)| terminal_id.to_string())
        .collect()
}

struct PendingRequest {
    id: u64,
    sent: Instant,
    kind: SubmissionKind,
}

/// Keep all create requests unread until the separate-connection probe is on
/// the wire. The second barrier prevents a create worker from draining its
/// connection before that probe has submitted its requests.
struct ProbeGates {
    creates_submitted: Barrier,
    probes_submitted: Barrier,
    release_workers: Barrier,
}

impl ProbeGates {
    fn new(client_count: usize) -> Self {
        let parties = client_count + 1;
        Self {
            creates_submitted: Barrier::new(parties),
            probes_submitted: Barrier::new(parties),
            release_workers: Barrier::new(parties),
        }
    }
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

    // A baseline terminal to type into. Snapshot the terminal catalog first so
    // teardown can close exactly what this run created.
    let mut control = Conn::open(&socket)?;
    control.identify()?;
    let initial_terminals =
        list_terminal_ids(&mut control)?.into_iter().map(|(id, _)| id).collect();
    let baseline = control.request(json!({"cmd":"new-workspace"}))?;
    let baseline_surface = baseline["surface"].as_u64().ok_or("baseline surface missing")?;
    let active_pane = fetch_active_pane(&mut control)?;

    let report = Arc::new(Mutex::new(Report::new(&socket)));

    // Concurrent create loops. Each worker submits its whole create batch
    // before reading a response. That gives both typing probes the same
    // in-flight create load to compare.
    let client_count = plan.clients.max(1);
    let gates = Arc::new(ProbeGates::new(client_count));
    let mut handles = Vec::new();
    for client in 0..client_count {
        let socket = socket.clone();
        let events = Arc::clone(&events);
        let report = Arc::clone(&report);
        let creates = plan.creates_per_client;
        let pane = active_pane;
        let gates = Arc::clone(&gates);
        let same_connection = client == 0;
        let typing_probes = plan.typing_probes;
        handles.push(thread::spawn(move || {
            if let Err(error) = run_create_loop(
                &socket,
                creates,
                client,
                pane,
                same_connection,
                typing_probes,
                &events,
                &report,
                &gates,
                baseline_surface,
            ) {
                report.lock().unwrap().errors.push(error);
            }
        }));
    }

    // Wait until every create connection has submitted its batch, then run
    // the separate-connection probe while those requests remain unread.
    let _ = gates.creates_submitted.wait();
    run_separate_typing_probe(&socket, baseline_surface, plan.typing_probes, &report, &gates);

    for handle in handles {
        let _ = handle.join();
    }
    stop.store(true, std::sync::atomic::Ordering::Release);
    let _ = subscriber_thread.join();

    close_created_terminals(&mut control, &initial_terminals, &report);
    if let Some(owner_pid) = guard.owner.as_ref().map(|owner| owner.pid()) {
        let remaining = count_child_terminal_hosts(owner_pid);
        let mut report = report.lock().unwrap();
        report.hosts_remaining = remaining;
        if let Some(remaining) = remaining.filter(|count| *count > 0) {
            report.warnings.push(format!(
                "{remaining} terminal host process(es) still owned by the bench session at teardown"
            ));
        }
    }

    drop(guard);
    Arc::try_unwrap(report)
        .map(|m| m.into_inner().unwrap())
        .map_err(|_| "report still shared".into())
}

fn run_separate_typing_probe(
    socket: &std::path::Path,
    surface: u64,
    probes: usize,
    report: &Arc<Mutex<Report>>,
    gates: &ProbeGates,
) {
    let mut setup_error = None;
    let mut conn = match Conn::open(socket) {
        Ok(conn) => Some(conn),
        Err(error) => {
            setup_error = Some(error);
            None
        }
    };
    let identify_error = conn.as_mut().and_then(|connection| connection.identify().err());
    if let Some(error) = identify_error {
        setup_error = Some(error);
        conn = None;
    }

    // Submit the entire separate-connection probe before releasing workers.
    // Responses are drained only after the release barrier, so create response
    // timing is not inflated by waiting for every typing probe in sequence.
    let mut pending = Vec::new();
    if let Some(connection) = conn.as_mut() {
        for _ in 0..probes {
            let sent = Instant::now();
            match connection.send(json!({"cmd":"send","surface":surface,"text":"x"})) {
                Ok(id) => pending.push((id, sent)),
                Err(error) => {
                    setup_error = Some(format!("typing(separate) send: {error}"));
                    break;
                }
            }
        }
    }

    let _ = gates.probes_submitted.wait();
    let _ = gates.release_workers.wait();

    if let Some(Err(error)) =
        conn.as_mut().map(|connection| drain_separate_typing(connection, pending, report))
    {
        setup_error = Some(match setup_error {
            Some(previous) => format!("{previous}; {error}"),
            None => error,
        });
    }
    if let Some(error) = setup_error {
        report.lock().unwrap().errors.push(format!("typing(separate): {error}"));
    }
}

fn drain_separate_typing(
    conn: &mut Conn,
    pending: Vec<(u64, Instant)>,
    report: &Arc<Mutex<Report>>,
) -> Result<(), String> {
    let mut pending_by_id: HashMap<u64, Instant> = pending.into_iter().collect();
    while !pending_by_id.is_empty() {
        let value = conn.read_value()?;
        if value.get("event").is_some() {
            continue;
        }
        let Some(id) = value.get("id").and_then(Value::as_u64) else {
            continue;
        };
        let Some(sent) = pending_by_id.remove(&id) else {
            continue;
        };
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            report.lock().unwrap().typing_separate.record(sent.elapsed());
        } else {
            let error = value.get("error").and_then(Value::as_str).unwrap_or("command failed");
            report.lock().unwrap().errors.push(format!("typing(separate): {error}"));
        }
    }
    Ok(())
}

fn command_for_submission(submission: SubmissionKind, pane: u64, surface: u64) -> Value {
    match submission {
        SubmissionKind::Create { index, .. } => match index % 3 {
            0 => json!({"cmd":"new-workspace"}),
            1 => json!({"cmd":"new-tab"}),
            _ => json!({"cmd":"split","pane":pane,"dir":"right"}),
        },
        SubmissionKind::TypingInterleaved { .. } | SubmissionKind::TypingAfterBatch { .. } => {
            json!({"cmd":"send","surface":surface,"text":"x"})
        }
    }
}

/// `(terminal_id, lifecycle)` for every terminal the daemon knows about.
fn list_terminal_ids(conn: &mut Conn) -> Result<Vec<(String, String)>, String> {
    let data = conn.request(json!({"cmd":"list-terminals"}))?;
    Ok(data["terminals"]
        .as_array()
        .map(|terminals| {
            terminals
                .iter()
                .filter_map(|terminal| {
                    Some((
                        terminal["terminal_id"].as_str()?.to_string(),
                        terminal["lifecycle"].as_str().unwrap_or("").to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default())
}

/// Close every terminal this run created, including the baseline typing
/// target and creates that were only `close-surface`d (a view-only close keeps
/// the terminal, and `server stop` keeps its host alive by design).
fn close_created_terminals(
    conn: &mut Conn,
    initial: &HashSet<String>,
    report: &Arc<Mutex<Report>>,
) {
    let current = match list_terminal_ids(conn) {
        Ok(current) => current,
        Err(error) => {
            report.lock().unwrap().errors.push(format!("teardown list-terminals: {error}"));
            return;
        }
    };
    let plan =
        teardown_close_plan(initial, current.iter().map(|(id, life)| (id.as_str(), life.as_str())));
    for terminal_id in plan {
        match conn.request(json!({"cmd":"close-terminal","terminal_id":&terminal_id})) {
            Ok(_) => report.lock().unwrap().terminals_closed_at_teardown += 1,
            Err(error) => report
                .lock()
                .unwrap()
                .errors
                .push(format!("teardown close-terminal {terminal_id}: {error}")),
        }
    }
}

/// Count `__terminal-host` processes whose parent is the bench-owned session
/// owner. Hosts do not carry the session in their command line, but the owner
/// that spawned them is still their parent while it runs. `None` when the
/// platform cannot answer.
fn count_child_terminal_hosts(owner_pid: u64) -> Option<u64> {
    if !cfg!(unix) {
        return None;
    }
    let output =
        std::process::Command::new("ps").args(["-axo", "pid=,ppid=,command="]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let listing = String::from_utf8_lossy(&output.stdout);
    Some(count_hosts_in_ps_listing(&listing, owner_pid))
}

fn count_hosts_in_ps_listing(listing: &str, owner_pid: u64) -> u64 {
    listing
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let _pid = fields.next()?;
            let ppid = fields.next()?.parse::<u64>().ok()?;
            let command = fields.collect::<Vec<_>>().join(" ");
            (ppid == owner_pid && command.contains("__terminal-host")).then_some(())
        })
        .count() as u64
}

// One worker owns one connection and every knob that shapes its submission
// plan; bundling these into a struct would only move the same ten fields.
#[allow(clippy::too_many_arguments)]
fn run_create_loop(
    socket: &std::path::Path,
    creates: usize,
    client: usize,
    pane: u64,
    same_connection: bool,
    typing_probes: usize,
    events: &Arc<Mutex<Vec<TimedEvent>>>,
    report: &Arc<Mutex<Report>>,
    gates: &ProbeGates,
    baseline_surface: u64,
) -> Result<(), String> {
    let mut setup_error = None;
    let mut conn = match Conn::open(socket) {
        Ok(conn) => Some(conn),
        Err(error) => {
            setup_error = Some(error);
            None
        }
    };
    let identify_error = conn.as_mut().and_then(|connection| connection.identify().err());
    if let Some(error) = identify_error {
        setup_error = Some(error);
        conn = None;
    }

    let mut pending = Vec::new();
    if let Some(connection) = conn.as_mut() {
        let submissions = same_connection_submission_plan(
            creates,
            if same_connection { typing_probes } else { 0 },
        );
        for submission in submissions {
            let sent = Instant::now();
            match connection.send(command_for_submission(submission, pane, baseline_surface)) {
                Ok(id) => pending.push(PendingRequest { id, sent, kind: submission }),
                Err(error) => {
                    setup_error = Some(format!("create[{client}] send: {error}"));
                    break;
                }
            }
        }
    }

    // All workers reach this point before any response is read. The main
    // thread uses this barrier to start the separate-connection probe against
    // the same in-flight create load.
    let _ = gates.creates_submitted.wait();
    let _ = gates.probes_submitted.wait();
    let _ = gates.release_workers.wait();

    let Some(mut conn) = conn else {
        return Err(setup_error.unwrap_or_else(|| "create connection unavailable".into()));
    };

    let drain_error = drain_pending(&mut conn, pending, client, socket, events, report);
    match (setup_error, drain_error) {
        (None, result) => result,
        (Some(setup_error), Ok(())) => Err(setup_error),
        (Some(setup_error), Err(drain_error)) => Err(format!("{setup_error}; {drain_error}")),
    }
}

fn drain_pending(
    conn: &mut Conn,
    pending: Vec<PendingRequest>,
    client: usize,
    socket: &std::path::Path,
    events: &Arc<Mutex<Vec<TimedEvent>>>,
    report: &Arc<Mutex<Report>>,
) -> Result<(), String> {
    let mut pending_by_id: HashMap<u64, PendingRequest> =
        pending.into_iter().map(|request| (request.id, request)).collect();
    let mut completed_creates = Vec::new();

    while !pending_by_id.is_empty() {
        let value = conn.read_value()?;
        if value.get("event").is_some() {
            continue;
        }
        let Some(id) = value.get("id").and_then(Value::as_u64) else {
            continue;
        };
        let Some(request) = pending_by_id.remove(&id) else {
            continue;
        };
        if value.get("ok").and_then(Value::as_bool) != Some(true) {
            let error = value.get("error").and_then(Value::as_str).unwrap_or("command failed");
            match request.kind {
                SubmissionKind::Create { kind, .. } => {
                    report.lock().unwrap().errors.push(format!("create[{client}:{kind}]: {error}"));
                }
                SubmissionKind::TypingInterleaved { .. } => {
                    report.lock().unwrap().errors.push(format!("typing(interleaved): {error}"));
                }
                SubmissionKind::TypingAfterBatch { .. } => {
                    report.lock().unwrap().errors.push(format!("typing(after-batch): {error}"));
                }
            }
            continue;
        }

        match request.kind {
            SubmissionKind::Create { kind, .. } => {
                completed_creates.push((
                    request.sent,
                    request.sent.elapsed(),
                    kind,
                    value.get("data").cloned().unwrap_or(Value::Null),
                ));
            }
            SubmissionKind::TypingInterleaved { .. } => {
                report.lock().unwrap().typing_same_interleaved.record(request.sent.elapsed());
            }
            SubmissionKind::TypingAfterBatch { .. } => {
                report.lock().unwrap().typing_same_after_batch.record(request.sent.elapsed());
            }
        }
    }

    // No responses remain on this connection, so the close requests below
    // cannot consume another pending request while we process each create.
    for (sent, response, _kind, data) in completed_creates {
        record_create_result(conn, sent, response, data, socket, events, report);
    }
    Ok(())
}

fn record_create_result(
    conn: &mut Conn,
    sent: Instant,
    response: Duration,
    data: Value,
    socket: &std::path::Path,
    events: &Arc<Mutex<Vec<TimedEvent>>>,
    report: &Arc<Mutex<Report>>,
) {
    let surface = data["surface"].as_u64();
    let terminal_id = data.get("terminal_id").and_then(Value::as_str).map(str::to_owned);
    {
        let mut report = report.lock().unwrap();
        report.create_response.record(response);
        report.record_lifecycle(data.get("lifecycle").and_then(Value::as_str));
    }

    if let Some(surface_id) = surface {
        // Give the delta a moment; it may already be recorded.
        let delay = wait_for_visibility(events, sent, surface_id, VISIBILITY_GRACE);
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
        match conn.request(json!({"cmd":"close-terminal","terminal_id":&terminal_id})) {
            Ok(_) => report.lock().unwrap().close_terminal.record(close_start.elapsed()),
            Err(error) => {
                // Teardown closes by catalog difference, so a failure here is
                // reported, not fatal.
                report
                    .lock()
                    .unwrap()
                    .warnings
                    .push(format!("close-terminal {terminal_id}: {error}"));
            }
        }
    }
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

fn is_first_frame_for_surface(value: &Value, surface_id: u64) -> bool {
    // Attach streams share the connection's event channel, so an unrelated
    // render-state event must not satisfy this surface's frame measurement.
    value.get("event").and_then(Value::as_str) == Some("render-state")
        && value.get("surface").and_then(Value::as_u64) == Some(surface_id)
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
        if is_first_frame_for_surface(&value, surface_id) {
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
    typing_same_interleaved: Metric,
    typing_same_after_batch: Metric,
    lifecycle_counts: std::collections::BTreeMap<String, u64>,
    visibility_misses: u64,
    terminals_closed_at_teardown: u64,
    hosts_remaining: Option<u64>,
    warnings: Vec<String>,
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
            typing_same_interleaved: Metric::default(),
            typing_same_after_batch: Metric::default(),
            lifecycle_counts: std::collections::BTreeMap::new(),
            visibility_misses: 0,
            terminals_closed_at_teardown: 0,
            hosts_remaining: None,
            warnings: Vec::new(),
            errors: Vec::new(),
        }
    }

    fn record_lifecycle(&mut self, lifecycle: Option<&str>) {
        if let Some(lifecycle) = lifecycle {
            *self.lifecycle_counts.entry(lifecycle.to_string()).or_insert(0) += 1;
        }
    }

    fn metrics(&self) -> [(&'static str, &Metric); 8] {
        [
            ("create.response_ms", &self.create_response),
            ("create.visible_ms", &self.create_visible),
            ("create.first_frame_ms", &self.first_frame),
            ("close.surface_response_ms", &self.close_surface),
            ("close.terminal_response_ms", &self.close_terminal),
            ("typing.separate_conn_ms", &self.typing_separate),
            ("typing.same_conn_interleaved_ms", &self.typing_same_interleaved),
            ("typing.same_conn_after_batch_ms", &self.typing_same_after_batch),
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
            "terminals_closed_at_teardown": self.terminals_closed_at_teardown,
            "hosts_remaining": self.hosts_remaining,
            "warnings": self.warnings,
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
    // Failures first: a table over a partial sample must not read as a result.
    match report.errors.first() {
        Some(first) => out.push_str(&format!("errors: {} (first: {first})\n", report.errors.len())),
        None => out.push_str("errors: 0\n"),
    }
    out.push_str(&format!("lifecycle on create response: {:?}\n", report.lifecycle_counts));
    out.push_str(&format!(
        "{:<34}{:>6}{:>10}{:>10}{:>10}{:>10}\n",
        "metric", "n", "p50", "p90", "p99", "max"
    ));
    for (name, metric) in report.metrics() {
        if let Some(s) = metric.summary() {
            out.push_str(&format!(
                "{:<34}{:>6}{:>10.2}{:>10.2}{:>10.2}{:>10.2}\n",
                name, s.count, s.p50, s.p90, s.p99, s.max
            ));
        }
    }
    if report.visibility_misses > 0 {
        out.push_str(&format!(
            "visibility misses (no delta within grace): {}\n",
            report.visibility_misses
        ));
    }
    out.push_str(&format!(
        "teardown: closed {} terminal(s); hosts still owned by the bench session: {}\n",
        report.terminals_closed_at_teardown,
        report.hosts_remaining.map_or("unknown".to_string(), |count| count.to_string())
    ));
    for warning in &report.warnings {
        out.push_str(&format!("warning: {warning}\n"));
    }
    if report.errors.len() > 1 {
        for error in report.errors.iter().skip(1).take(9) {
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

    #[test]
    fn same_connection_probe_is_submitted_before_response_drain() {
        let submissions = same_connection_submission_plan(3, 2);
        assert_eq!(
            submissions,
            vec![
                SubmissionKind::Create { index: 0, kind: 0 },
                SubmissionKind::TypingInterleaved { index: 0 },
                SubmissionKind::Create { index: 1, kind: 1 },
                SubmissionKind::TypingInterleaved { index: 1 },
                SubmissionKind::Create { index: 2, kind: 2 },
                SubmissionKind::TypingInterleaved { index: 2 },
                SubmissionKind::TypingAfterBatch { probe: 0 },
                SubmissionKind::TypingAfterBatch { probe: 1 },
            ]
        );
    }

    #[test]
    fn interleaved_probe_follows_each_create_and_needs_probes_enabled() {
        let submissions = same_connection_submission_plan(4, 1);
        let creates =
            submissions.iter().filter(|s| matches!(s, SubmissionKind::Create { .. })).count();
        let interleaved = submissions
            .iter()
            .filter(|s| matches!(s, SubmissionKind::TypingInterleaved { .. }))
            .count();
        assert_eq!((creates, interleaved), (4, 4));
        for pair in submissions.windows(2) {
            if let SubmissionKind::Create { index, .. } = pair[0] {
                assert_eq!(pair[1], SubmissionKind::TypingInterleaved { index });
            }
        }
        // With typing probes disabled the plan is creates only.
        assert!(
            same_connection_submission_plan(2, 0)
                .iter()
                .all(|s| matches!(s, SubmissionKind::Create { .. }))
        );
    }

    #[test]
    fn teardown_closes_every_terminal_created_during_the_run() {
        let initial: HashSet<String> =
            ["pre-a".to_string(), "pre-b".to_string()].into_iter().collect();
        let current = [
            ("pre-a", "running"),
            ("pre-b", "exited"),
            ("baseline", "running"),
            ("new-tab", "running"),
            ("split", "launching"),
            ("already-gone", "tombstoned"),
            ("finished", "exited"),
        ];
        let plan = teardown_close_plan(&initial, current.iter().copied());
        assert_eq!(plan, vec!["baseline", "new-tab", "split"]);
        // Nothing created: nothing closed, including pre-existing terminals.
        assert!(teardown_close_plan(&initial, [("pre-a", "running")]).is_empty());
    }

    #[test]
    fn host_count_matches_owner_children_only() {
        let listing = "\
  100  1 /usr/bin/cmux-tui --headless --session bench-1
  101 100 /usr/bin/cmux-tui __terminal-host --bootstrap-stdio
  102 100 /usr/bin/cmux-tui __terminal-host --bootstrap-stdio
  103 999 /usr/bin/cmux-tui __terminal-host --bootstrap-stdio
  104 100 /bin/zsh -l
";
        assert_eq!(count_hosts_in_ps_listing(listing, 100), 2);
        assert_eq!(count_hosts_in_ps_listing(listing, 999), 1);
        assert_eq!(count_hosts_in_ps_listing(listing, 7), 0);
    }

    #[test]
    fn first_frame_requires_the_requested_surface() {
        assert!(!is_first_frame_for_surface(&json!({"event":"render-state","surface":41}), 42));
        assert!(is_first_frame_for_surface(&json!({"event":"render-state","surface":42}), 42));
        assert!(!is_first_frame_for_surface(&json!({"event":"render-delta","surface":42}), 42));
    }
}
