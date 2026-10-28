//! `trace-start`, `trace-stop` and `trace-status`:
//! the daemon starts, stops or reports its own trace recording and forwards
//! the call to the holder (only on a TRACE_CONTROL link), to every live
//! terminal host whose record advertises trace control, and to acpmux when it
//! runs. The reply lists each process's ring path and bytes, and the bytes per
//! role under [`TOTAL_CAP_BYTES`].
//!
//! Like Chrome's tracing service (`services/tracing/perfetto/consumer_host.cc`
//! starting every producer, and `TraceConfig`'s buffer size), the caller names
//! categories only: no parameter is a path or a command, and each process
//! records into its own directory (the daemon's under its state root; a
//! session without one, `--ephemeral`, refuses a start instead of recording
//! into a shared temporary directory). Owner only: a WebSocket or remote relay
//! client is refused before anything runs. As the tracing service changes one
//! session at a time, one call runs at a time ([`TraceControlGate`]), and a
//! terminal host answers its calls in the order they arrive.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::PoisonError;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_trace::{ControlOp, Role, category};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::Mux;
use crate::panic_free::JsonFields;
use crate::process_trace::TraceReport;

/// The bytes of recording rings one `trace-start` may have mapped across the
/// daemon and its children: the daemon (32 MiB), the holder and acpmux (8 MiB
/// each) and about 150 terminal hosts (512 KiB each). Hosts past it are not
/// asked and are reported `over_total_cap`.
pub(super) const TOTAL_CAP_BYTES: u64 = 128 * 1024 * 1024;
/// How long the daemon waits for its children's answers, all together.
const CHILD_DEADLINE: Duration = Duration::from_secs(3);

/// `trace-start`'s parameters. Nothing else is read.
#[derive(Debug, Default, Deserialize)]
pub(crate) struct StartParams {
    /// Category names (`motion`, `frame`, ...); omitted: every recording
    /// category. `key` needs `keys`.
    #[serde(default)]
    categories: Option<Vec<String>>,
    /// Record per-key records (`key`).
    #[serde(default)]
    keys: bool,
}

/// One forwarded call to a terminal host.
pub(super) struct HostCall {
    pub(super) pid: u32,
    pub(super) sent: HostSent,
}

pub(super) enum HostSent {
    /// The host's record does not advertise trace control: no frame.
    Untraced,
    /// Not asked: the total cap was reached.
    OverCap,
    /// Asked: the answer, read against the shared deadline.
    Pending(Box<dyn FnOnce() -> Result<TraceReport, String> + Send>),
    Failed(String),
}

/// What forwarding one call to the holder did: task 096's `HolderTrace`,
/// plus the cap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum HolderSent {
    /// The holder granted TRACE_CONTROL: the start or the stop went out. A
    /// status sends nothing (the holder protocol has no status frame).
    Traced,
    /// The holder refused its last TRACE_START or TRACE_STOP: its message.
    Refused(String),
    /// It did not (an older holder): no frame.
    Untraced,
    /// No holder link is open: a holder that links while the recording runs
    /// gets the start then.
    NotLinked,
    /// Not asked: the total cap was reached.
    OverCap,
}

/// acpmux, connected: the call to make once every host request is out.
pub(super) type AcpmuxCall<'a> =
    Box<dyn FnOnce(ControlOp, Duration) -> Result<TraceReport, String> + 'a>;

/// The processes one control call reaches; the server's is [`LiveTargets`].
pub(super) trait TraceTargets {
    /// Runs `op` in the daemon itself.
    fn daemon(&self, op: ControlOp) -> TraceReport;
    /// Forwards `op` to the holder; `None` when no holder runs. A start asks
    /// `admit` first and sends nothing (`OverCap`) when it says no.
    fn holder(&self, op: ControlOp, admit: &mut dyn FnMut() -> bool) -> Option<HolderSent>;
    /// Sends `op` to every live terminal host without waiting. For each host
    /// that takes trace control it asks `admit` first, and leaves the host
    /// out (`OverCap`) when `admit` says no.
    fn begin_hosts(
        &self,
        op: ControlOp,
        deadline: Instant,
        admit: &mut dyn FnMut() -> bool,
    ) -> Vec<HostCall>;
    /// Connects to acpmux; `None` when it does not run (it is never started,
    /// as on a platform without agent sessions).
    fn connect_acpmux(&self) -> Option<AcpmuxCall<'_>>;
}

/// Why a trace control call was refused before it ran.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TraceControlRefused {
    /// A WebSocket or remote relay client asked.
    NotLocal,
    /// Another trace control call is running.
    Busy,
    /// A start in a session without a state root (`--ephemeral`): its only
    /// directory would be a shared temporary one.
    NoStateRoot,
}

impl std::fmt::Display for TraceControlRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            TraceControlRefused::NotLocal => "trace control requires a trusted local connection",
            TraceControlRefused::Busy => "another trace control call is running",
            TraceControlRefused::NoStateRoot => {
                "this session has no state root to record into (it is ephemeral)"
            }
        })
    }
}

impl std::error::Error for TraceControlRefused {}

/// Lets one trace control call run at a time in a daemon (`Mux::trace_control`).
/// Each process's tracer is one session, so a stop must never pass a start
/// that is still reaching the children.
#[derive(Debug, Default)]
pub(crate) struct TraceControlGate {
    running: AtomicBool,
}

/// The running call's turn; it ends on drop.
pub(crate) struct TraceControlTurn<'a> {
    gate: &'a TraceControlGate,
}

impl TraceControlGate {
    /// The turn, or [`TraceControlRefused::Busy`] while another call runs.
    pub(crate) fn begin(&self) -> Result<TraceControlTurn<'_>, TraceControlRefused> {
        self.running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| TraceControlTurn { gate: self })
            .map_err(|_| TraceControlRefused::Busy)
    }
}

impl Drop for TraceControlTurn<'_> {
    fn drop(&mut self) {
        self.gate.running.store(false, Ordering::Release);
    }
}

/// The ring bytes one start may map, shared by every process it reaches.
struct Budget {
    /// Only a start maps rings: a stop or a status admits every process.
    start: bool,
    used: u64,
}

impl Budget {
    fn new(call: Call) -> Self {
        Self { start: matches!(call, Call::Start { .. }), used: Role::Daemon.recording_bytes() }
    }

    /// Takes `role`'s ring from the budget; false, taking nothing, when it
    /// does not fit.
    fn admit(&mut self, role: Role) -> bool {
        if !self.start {
            return true;
        }
        let fits = self.used + role.recording_bytes() <= TOTAL_CAP_BYTES;
        if fits {
            self.used += role.recording_bytes();
        }
        fits
    }

    /// Gives back a ring [`Self::admit`] took that will not be mapped.
    fn release(&mut self, role: Role) {
        if self.start {
            self.used -= role.recording_bytes();
        }
    }
}

/// Which call, with its categories.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Call {
    Start { categories: u64, keys: bool },
    Stop,
    Status,
}

impl Call {
    fn op(self) -> ControlOp {
        match self {
            Call::Start { categories, .. } => ControlOp::Start { categories },
            Call::Stop => ControlOp::Stop,
            Call::Status => ControlOp::Status,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Call::Start { .. } => "start",
            Call::Stop => "stop",
            Call::Status => "status",
        }
    }
}

/// The category bits `params` asks for.
pub(super) fn start_call(params: &StartParams) -> anyhow::Result<Call> {
    let mut categories = match &params.categories {
        None => category::RECORDING,
        Some(names) => {
            let mut bits = 0;
            for name in names {
                let Some(bit) = category::NAMES.iter().position(|known| known == name) else {
                    anyhow::bail!("unknown trace category {name:?}");
                };
                bits |= 1u64 << bit;
            }
            bits
        }
    };
    if categories & category::KEY != 0 && !params.keys {
        anyhow::bail!("the key category records per-key records: ask for it with keys: true");
    }
    if params.keys {
        categories |= category::KEY;
    }
    Ok(Call::Start { categories, keys: params.keys })
}

/// Runs `call` in this daemon and its live children, one call at a time.
/// The caller checked the client is the owner (`cmd_server::trace_control`).
pub(super) fn run_live(mux: &Arc<Mux>, call: Call) -> Result<Value, TraceControlRefused> {
    let _turn = mux.trace_control.begin()?;
    let daemon_dir = daemon_dir(mux.session_state_directory(), call)?;
    Ok(run(call, &LiveTargets { mux, daemon_dir }))
}

/// `<state root>/trace`. Only a start opens a ring, so only a start needs it.
fn daemon_dir(
    state_root: Option<PathBuf>,
    call: Call,
) -> Result<Option<PathBuf>, TraceControlRefused> {
    match state_root {
        Some(root) => Ok(Some(root.join("trace"))),
        None if matches!(call, Call::Start { .. }) => Err(TraceControlRefused::NoStateRoot),
        None => Ok(None),
    }
}

/// Runs `call` in the daemon, then in every child `targets` reaches.
pub(super) fn run(call: Call, targets: &dyn TraceTargets) -> Value {
    let op = call.op();
    let mut processes = Vec::new();
    let daemon = targets.daemon(op);
    let daemon_failed_start = matches!(call, Call::Start { .. }) && daemon.state.is_err();
    processes.push(report_json(Role::Daemon, &daemon));
    // A start the daemon refused (one runs already) goes nowhere else, so no
    // child is started twice.
    if !daemon_failed_start {
        let mut budget = Budget::new(call);
        let deadline = Instant::now() + CHILD_DEADLINE;
        let mut holder_admitted = false;
        let holder = targets.holder(op, &mut || {
            holder_admitted = budget.admit(Role::Holder);
            holder_admitted
        });
        if let Some(holder) = holder {
            // A holder sent no start maps no ring: its share goes to the hosts.
            if holder != HolderSent::Traced && holder_admitted {
                budget.release(Role::Holder);
            }
            processes.push(holder_json(call, holder));
        }
        // acpmux's share is taken only once its socket answers, and it is
        // called after every host request is on the wire, so its wait
        // overlaps theirs.
        let acpmux = targets.connect_acpmux().map(|acpmux| (budget.admit(Role::Acpmux), acpmux));
        let hosts = targets.begin_hosts(op, deadline, &mut || budget.admit(Role::TerminalHost));
        match acpmux {
            Some((true, acpmux)) => processes.push(match acpmux(op, CHILD_DEADLINE) {
                Ok(report) => report_json(Role::Acpmux, &report),
                Err(error) => failed_json(Role::Acpmux, None, &error),
            }),
            Some((false, _)) => {
                processes.push(untraced_json(Role::Acpmux, None, "over_total_cap"));
            }
            None => {}
        }
        for host in hosts {
            processes.push(host_json(host));
        }
    }
    let mut bytes_by_role = BTreeMap::<&str, u64>::new();
    for process in &processes {
        if let (Some(role), Some(bytes)) =
            (process["role"].as_str(), process["recording_bytes"].as_u64())
        {
            *bytes_by_role.entry(role).or_default() += bytes;
        }
    }
    let total: u64 = bytes_by_role.values().sum();
    let mut reply = json!({
        "op": call.name(),
        "recording": daemon.state.as_ref().is_ok_and(|traced| traced.recording),
        "processes": processes,
        "bytes_by_role": bytes_by_role,
        "total_bytes": total,
        "total_cap_bytes": TOTAL_CAP_BYTES,
    });
    if let Call::Start { categories, keys } = call {
        reply.insert("categories", json!(category_names(categories)));
        reply.insert("keys", json!(keys));
    }
    reply
}

fn category_names(categories: u64) -> Vec<&'static str> {
    category::NAMES
        .iter()
        .enumerate()
        .filter(|(bit, _)| categories & (1u64 << bit) != 0)
        .map(|(_, name)| *name)
        .collect()
}

fn report_json(role: Role, report: &TraceReport) -> Value {
    let mut fields = report.json_fields();
    fields.insert("role", json!(role.as_str()));
    fields
}

fn failed_json(role: Role, pid: Option<u32>, error: &str) -> Value {
    json!({"role": role.as_str(), "pid": pid, "state": "unanswered", "error": error})
}

fn untraced_json(role: Role, pid: Option<u32>, reason: &str) -> Value {
    json!({"role": role.as_str(), "pid": pid, "state": "untraced", "reason": reason})
}

/// The holder sends no answer, so its entry says what was sent. Only a
/// start it was sent counts a ring (its role's size, in its holder-lifetime
/// directory).
fn holder_json(call: Call, holder: HolderSent) -> Value {
    let role = Role::Holder.as_str();
    match (holder, call) {
        (HolderSent::Traced, Call::Start { .. }) => json!({
            "role": role,
            "state": "recording",
            "recording_bytes": Role::Holder.recording_bytes(),
        }),
        (HolderSent::Traced, Call::Stop) => json!({"role": role, "state": "idle"}),
        (HolderSent::Traced, Call::Status) => {
            json!({"role": role, "state": "traced", "reason": "holder_traced"})
        }
        (HolderSent::Refused(error), _) => json!({
            "role": role,
            "state": "error",
            "reason": "holder_trace_failed",
            "error": error,
        }),
        (HolderSent::Untraced, _) => untraced_json(Role::Holder, None, "holder_untraced"),
        (HolderSent::NotLinked, _) => {
            json!({"role": role, "state": "not_linked", "reason": "holder_not_linked"})
        }
        (HolderSent::OverCap, _) => untraced_json(Role::Holder, None, "over_total_cap"),
    }
}

fn host_json(host: HostCall) -> Value {
    let pid = Some(host.pid);
    match host.sent {
        HostSent::Untraced => untraced_json(Role::TerminalHost, pid, "host_untraced"),
        HostSent::OverCap => untraced_json(Role::TerminalHost, pid, "over_total_cap"),
        HostSent::Pending(wait) => match wait() {
            Ok(report) => report_json(Role::TerminalHost, &report),
            Err(error) => failed_json(Role::TerminalHost, pid, &error),
        },
        HostSent::Failed(error) => failed_json(Role::TerminalHost, pid, &error),
    }
}

/// The daemon's own process and its live children.
struct LiveTargets<'a> {
    mux: &'a Arc<Mux>,
    /// [`daemon_dir`]: `None` only for a stop or a status.
    daemon_dir: Option<PathBuf>,
}

impl TraceTargets for LiveTargets<'_> {
    fn daemon(&self, op: ControlOp) -> TraceReport {
        // A stop or a status never opens a ring, so it reads no directory.
        let dir = self.daemon_dir.clone().unwrap_or_default();
        TraceReport::of_this_process(cmux_trace::apply_control(op, &dir, Role::Daemon))
    }

    /// Through the holder service (task 096): only a holder that granted
    /// TRACE_CONTROL gets a frame, and a holder that links while the
    /// recording runs gets the start then. Never connects or starts one.
    #[cfg(unix)]
    fn holder(&self, op: ControlOp, admit: &mut dyn FnMut() -> bool) -> Option<HolderSent> {
        use crate::holder_runtime::HolderService;
        let root = self
            .mux
            .surface_options
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_host_root
            .clone()?;
        if !HolderService::may_run(&root) {
            return None;
        }
        let service = HolderService::for_root(&root).ok()?;
        Some(forward_to_holder(&*service, op, admit))
    }

    #[cfg(not(unix))]
    fn holder(&self, _: ControlOp, _: &mut dyn FnMut() -> bool) -> Option<HolderSent> {
        None
    }

    #[cfg(any(unix, windows))]
    fn begin_hosts(
        &self,
        op: ControlOp,
        deadline: Instant,
        admit: &mut dyn FnMut() -> bool,
    ) -> Vec<HostCall> {
        use crate::surface::HostTraceSent;
        self.mux
            .surface_runtimes()
            .iter()
            .filter_map(|surface| surface.begin_host_trace(op, deadline, admit))
            .map(|call| HostCall {
                pid: call.host_pid,
                sent: match call.sent {
                    HostTraceSent::Untraced => HostSent::Untraced,
                    HostTraceSent::OverCap => HostSent::OverCap,
                    HostTraceSent::Pending(pending) => {
                        HostSent::Pending(Box::new(move || pending.wait()))
                    }
                    HostTraceSent::Failed(error) => HostSent::Failed(error),
                },
            })
            .collect()
    }

    #[cfg(not(any(unix, windows)))]
    fn begin_hosts(&self, _: ControlOp, _: Instant, _: &mut dyn FnMut() -> bool) -> Vec<HostCall> {
        Vec::new()
    }

    // acpmux (agent sessions) is unix-only: no acpmux to trace elsewhere.
    #[cfg(not(unix))]
    fn connect_acpmux(&self) -> Option<AcpmuxCall<'_>> {
        None
    }

    #[cfg(unix)]
    fn connect_acpmux(&self) -> Option<AcpmuxCall<'_>> {
        use super::agent_session_attach::agent_session_link::AcpmuxLink;
        let socket = self.mux.control_clients.agent_sessions.socket()?;
        let link = AcpmuxLink::connect(&socket, |_| {}).ok()?;
        Some(Box::new(move |op, timeout| {
            let reply = link.call(ACPMUX_TRACE_METHOD, acpmux_params(op), timeout);
            reply.map_err(|error| format!("{error:?}")).and_then(|value| {
                TraceReport::from_json(&value)
                    .ok_or_else(|| "acpmux sent a malformed trace answer".to_owned())
            })
        }))
    }
}

/// The holder service's trace control (task 096), the seam a test fakes.
#[cfg(unix)]
pub(super) trait HolderTraceControl {
    fn trace_start(&self, categories: u64, budget_bytes: u64)
    -> crate::holder_runtime::HolderTrace;
    fn trace_stop(&self) -> crate::holder_runtime::HolderTrace;
    fn trace_state(&self) -> crate::holder_runtime::HolderTrace;
}

#[cfg(unix)]
impl HolderTraceControl for crate::holder_runtime::HolderService {
    fn trace_start(
        &self,
        categories: u64,
        budget_bytes: u64,
    ) -> crate::holder_runtime::HolderTrace {
        Self::trace_start(self, categories, budget_bytes)
    }

    fn trace_stop(&self) -> crate::holder_runtime::HolderTrace {
        Self::trace_stop(self)
    }

    fn trace_state(&self) -> crate::holder_runtime::HolderTrace {
        Self::trace_state(self)
    }
}

/// Forwards `op` to `service`'s holder. A start asks `admit` first and sends
/// nothing when it says no; its budget is the holder ring `admit` counted,
/// so a holder whose ring is larger refuses it.
#[cfg(unix)]
pub(super) fn forward_to_holder(
    service: &dyn HolderTraceControl,
    op: ControlOp,
    admit: &mut dyn FnMut() -> bool,
) -> HolderSent {
    use crate::holder_runtime::HolderTrace;
    let trace = match op {
        ControlOp::Start { .. } if !admit() => return HolderSent::OverCap,
        ControlOp::Start { categories } => {
            service.trace_start(categories, Role::Holder.recording_bytes())
        }
        ControlOp::Stop => service.trace_stop(),
        ControlOp::Status => service.trace_state(),
    };
    match trace {
        HolderTrace::Traced => HolderSent::Traced,
        HolderTrace::Refused(error) => HolderSent::Refused(error),
        HolderTrace::Untraced => HolderSent::Untraced,
        HolderTrace::NotLinked => HolderSent::NotLinked,
    }
}

/// acpmux's trace method (`acpmux/src/trace_control.rs`).
#[cfg(unix)]
const ACPMUX_TRACE_METHOD: &str = "_acpmux/trace";

#[cfg(unix)]
fn acpmux_params(op: ControlOp) -> Value {
    match op {
        ControlOp::Start { categories } => json!({"op": "start", "categories": categories}),
        ControlOp::Stop => json!({"op": "stop"}),
        ControlOp::Status => json!({"op": "status"}),
    }
}

// The fakes stand in for the holder service, which runs on unix only.
#[cfg(all(test, unix))]
#[path = "trace_control_tests.rs"]
mod tests;
