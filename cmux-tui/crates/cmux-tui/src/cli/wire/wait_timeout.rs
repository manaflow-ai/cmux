//! A terminal wait that ran out of time says so the way `terminal send` and
//! `terminal run` do: `timed_out: true`, `waited_ms`, exit 124 (timeout(1)).
//!
//! The daemon answers a `terminal.wait` whose deadline passed with
//! `matched: false`, and a `terminal.wait_exit` whose deadline passed with
//! `state: "pending"`. Both are ordinary results, so `process wait` exited 0
//! on a process that still ran, and an agent read 0 as "it finished". The
//! wire answer stays as it is (the language bindings parse it strictly);
//! the CLI and the MCP tools add the fields, and the CLI picks the exit code.

use std::path::Path;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::Value;

use super::super::command::{RequestPlan, WireOperation};

/// The exit code of a wait whose time ran out, as timeout(1) has it.
pub(in crate::cli) const TIMEOUT_EXIT: i32 = 124;

/// A Cloud machine's guest `cmux` adapter (web/services/vms/guestCliDistribution.ts).
const GUEST_ADAPTER: &str = "/usr/local/libexec/cmux-cloud-adapter";

/// The line an adapter carries once it reads a timed-out `process wait`'s 124
/// as pending (web/services/vms/guestCli.ts).
const ADAPTER_READS_TIMEOUT_EXIT: &str = "cmux-adapter-reads: process-wait-124";

/// A `screen wait` (`terminal.wait`) or `process wait` (`terminal.wait_exit`)
/// request, kept to read its answer.
pub(in crate::cli) struct Wait {
    operation: ResourceOperation,
    /// The request's `timeout_ms`, a decimal string; `None` without one.
    timeout_ms: Option<String>,
}

impl Wait {
    /// `Some` for a terminal wait request, `None` for any other.
    pub(in crate::cli) fn of(plan: &RequestPlan) -> Option<Self> {
        let WireOperation::Typed(
            operation @ (ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit),
        ) = &plan.operation
        else {
            return None;
        };
        let operation = *operation;
        let timeout_ms = plan.params.get("timeout_ms").and_then(Value::as_str).map(str::to_owned);
        Some(Self { operation, timeout_ms })
    }

    /// Whether the answer means the deadline passed: no match for `screen
    /// wait`, a process still running for `process wait`. A daemon wait
    /// without a deadline answers only once its condition holds.
    pub(in crate::cli) fn ran_out(&self, result: &Value) -> bool {
        match self.operation {
            ResourceOperation::TerminalWait => result.get("matched") == Some(&Value::Bool(false)),
            _ => result.get("state").and_then(Value::as_str) == Some("pending"),
        }
    }

    /// Adds `timed_out` to the answer, and `waited_ms` (the timeout it
    /// waited, a decimal string as `terminal send` prints it) when the time
    /// ran out. The daemon's own fields stay as they are.
    pub(in crate::cli) fn mark(&self, result: &mut Value) {
        let timed_out = self.ran_out(result);
        let Some(object) = result.as_object_mut() else { return };
        object.insert("timed_out".into(), Value::Bool(timed_out));
        if timed_out {
            let waited = self.timeout_ms.as_deref().unwrap_or("0");
            object.insert("waited_ms".into(), Value::String(waited.to_owned()));
        }
    }
}

/// [`Wait::mark`] for the request `plan`; any other answer is left alone.
pub(super) fn mark(plan: &RequestPlan, result: &mut Value) {
    if let Some(wait) = Wait::of(plan) {
        wait.mark(result);
    }
}

/// 124 for a terminal wait whose time ran out, `None` for any other answer.
pub(super) fn exit_code(plan: &RequestPlan, result: &Value) -> Option<i32> {
    exit_code_with(plan, result, Path::new(GUEST_ADAPTER))
}

/// [`exit_code`] with the guest adapter at `adapter`. An adapter older than
/// this build calls `process wait` in slices and takes any exit but 0 for a
/// failed `agent --wait`, and an update that replaces only the binary (the
/// app's machine update, `link machine update`) keeps that adapter. So while
/// the installed adapter does not say it reads 124, a timed-out `process wait`
/// exits 0 as before; its answer still says `timed_out: true`. A machine with
/// no adapter is not a Cloud guest.
pub(super) fn exit_code_with(plan: &RequestPlan, result: &Value, adapter: &Path) -> Option<i32> {
    let wait = Wait::of(plan).filter(|wait| wait.ran_out(result))?;
    let old_adapter = matches!(wait.operation, ResourceOperation::TerminalWaitExit)
        && std::fs::read_to_string(adapter).is_ok_and(|text| !text.contains(ADAPTER_READS_TIMEOUT_EXIT));
    (!old_adapter).then_some(TIMEOUT_EXIT)
}
