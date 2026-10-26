//! `trace-start`, `trace-stop` and `trace-status` (p09-observability-015):
//! the daemon starts, stops or reports its own trace recording and forwards
//! the call to the holder (only on a TRACE_CONTROL link), to every live
//! terminal host whose record advertises trace control, and to acpmux when it
//! runs. The reply lists each process's ring path and bytes, and the bytes per
//! role under [`TOTAL_CAP_BYTES`].
//!
//! Like Chrome's tracing service (`services/tracing/perfetto/consumer_host.cc`
//! starting every producer, and `TraceConfig`'s buffer size), the caller names
//! categories only: no parameter is a path or a command, and each process
//! records into its own directory (the daemon's under its state root). Owner
//! only: a WebSocket or remote relay client is refused before anything runs.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_trace::{ControlOp, Role, category};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::Mux;
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

/// What forwarding one call to the holder did.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum HolderSent {
    Untraced,
    Traced,
    Failed(String),
}

/// The processes one control call reaches; the server's is [`LiveTargets`].
pub(super) trait TraceTargets {
    /// Runs `op` in the daemon itself.
    fn daemon(&self, op: ControlOp) -> TraceReport;
    /// Forwards `op` to the holder; `None` when no holder runs.
    fn holder(&self, op: ControlOp) -> Option<HolderSent>;
    /// Sends `op` to every live terminal host without waiting. For each host
    /// that takes trace control it asks `admit` first, and leaves the host
    /// out (`OverCap`) when `admit` says no.
    fn begin_hosts(
        &self,
        op: ControlOp,
        deadline: Instant,
        admit: &mut dyn FnMut() -> bool,
    ) -> Vec<HostCall>;
    /// Calls acpmux; `None` when it does not run (it is never started).
    fn acpmux(&self, op: ControlOp, timeout: Duration) -> Option<Result<TraceReport, String>>;
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

/// Runs `call` in this daemon and its live children. The caller checked the
/// client is the owner (`cmd_server::trace_control`).
pub(super) fn run_live(mux: &Arc<Mux>, call: Call) -> Value {
    run(call, &LiveTargets { mux })
}

/// Runs `call` in the daemon, then in every child `targets` reaches.
pub(super) fn run(call: Call, targets: &dyn TraceTargets) -> Value {
    let op = call.op();
    let mut processes = Vec::new();
    let daemon = targets.daemon(op);
    let daemon_failed_start = matches!(call, Call::Start { .. }) && daemon.state.is_err();
    let mut used = Role::Daemon.recording_bytes();
    processes.push(report_json(Role::Daemon, &daemon));
    // A start the daemon refused (one runs already) goes nowhere else, so no
    // child is started twice.
    if !daemon_failed_start {
        let mut admit = |role: Role| {
            let fits = !matches!(call, Call::Start { .. })
                || used + role.recording_bytes() <= TOTAL_CAP_BYTES;
            if fits {
                used += role.recording_bytes();
            }
            fits
        };
        let deadline = Instant::now() + CHILD_DEADLINE;
        if let Some(holder) = targets.holder(op) {
            processes.push(holder_json(holder, &mut admit));
        }
        // acpmux's share is taken before the hosts', and it is called after
        // every host request is on the wire, so its wait overlaps theirs.
        let acpmux_admitted = admit(Role::Acpmux);
        let hosts = targets.begin_hosts(op, deadline, &mut || admit(Role::TerminalHost));
        if acpmux_admitted {
            match targets.acpmux(op, CHILD_DEADLINE) {
                Some(Ok(report)) => processes.push(report_json(Role::Acpmux, &report)),
                Some(Err(error)) => processes.push(failed_json(Role::Acpmux, None, &error)),
                None => {}
            }
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
        reply["categories"] = json!(category_names(categories));
        reply["keys"] = json!(keys);
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
    fields["role"] = json!(role.as_str());
    fields
}

fn failed_json(role: Role, pid: Option<u32>, error: &str) -> Value {
    json!({"role": role.as_str(), "pid": pid, "state": "unanswered", "error": error})
}

fn untraced_json(role: Role, pid: Option<u32>, reason: &str) -> Value {
    json!({"role": role.as_str(), "pid": pid, "state": "untraced", "reason": reason})
}

fn holder_json(holder: HolderSent, admit: &mut dyn FnMut(Role) -> bool) -> Value {
    match holder {
        HolderSent::Untraced => untraced_json(Role::Holder, None, "holder_untraced"),
        // The holder sends no answer: its ring is its role's size, in its
        // holder-lifetime directory.
        HolderSent::Traced if admit(Role::Holder) => json!({
            "role": Role::Holder.as_str(),
            "state": "forwarded",
            "recording_bytes": Role::Holder.recording_bytes(),
        }),
        HolderSent::Traced => untraced_json(Role::Holder, None, "over_total_cap"),
        HolderSent::Failed(error) => failed_json(Role::Holder, None, &error),
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
}

impl LiveTargets<'_> {
    /// `<state root>/trace`; the system temporary directory for an in-memory
    /// session, which has no state root.
    fn daemon_dir(&self) -> PathBuf {
        self.mux.session_state_directory().unwrap_or_else(std::env::temp_dir).join("trace")
    }
}

impl TraceTargets for LiveTargets<'_> {
    fn daemon(&self, op: ControlOp) -> TraceReport {
        TraceReport::of_this_process(cmux_trace::apply_control(
            op,
            &self.daemon_dir(),
            Role::Daemon,
        ))
    }

    #[cfg(unix)]
    fn holder(&self, op: ControlOp) -> Option<HolderSent> {
        use crate::holder_runtime::{HolderService, HolderTrace};
        let root = self.mux.surface_options.lock().unwrap().terminal_host_root.clone()?;
        if !HolderService::may_run(&root) {
            return None;
        }
        let link = HolderService::for_root(&root).ok()?.trace_link()?;
        Some(match HolderTrace::forward(&*link, op) {
            HolderTrace::Untraced => HolderSent::Untraced,
            HolderTrace::Traced => HolderSent::Traced,
            HolderTrace::Failed(error) => HolderSent::Failed(error),
        })
    }

    #[cfg(not(unix))]
    fn holder(&self, _: ControlOp) -> Option<HolderSent> {
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

    fn acpmux(&self, op: ControlOp, timeout: Duration) -> Option<Result<TraceReport, String>> {
        use super::agent_session_attach::agent_session_link::AcpmuxLink;
        let socket = self.mux.control_clients.agent_sessions.socket()?;
        let link = AcpmuxLink::connect(&socket, |_| {}).ok()?;
        let reply = link.call(ACPMUX_TRACE_METHOD, acpmux_params(op), timeout);
        Some(reply.map_err(|error| format!("{error:?}")).and_then(|value| {
            TraceReport::from_json(&value)
                .ok_or_else(|| "acpmux sent a malformed trace answer".to_owned())
        }))
    }
}

/// acpmux's trace method (`acpmux/src/trace_control.rs`).
const ACPMUX_TRACE_METHOD: &str = "_acpmux/trace";

fn acpmux_params(op: ControlOp) -> Value {
    match op {
        ControlOp::Start { categories } => json!({"op": "start", "categories": categories}),
        ControlOp::Stop => json!({"op": "stop"}),
        ControlOp::Status => json!({"op": "status"}),
    }
}

#[cfg(test)]
#[path = "trace_control_tests.rs"]
mod tests;
