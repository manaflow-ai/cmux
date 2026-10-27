//! A process's side of the daemon's `trace-start`, `trace-stop` and `trace-status`
//! (plans/cmux-next/chrome-parity/p09-observability.md, task 015): the daemon, a terminal host and
//! acpmux each run [`apply`] when the daemon asks. As Chrome's tracing service tells each child to
//! start its `TraceLog` (`services/tracing/public/cpp/perfetto/perfetto_traced_process.h`), the
//! caller names no file: each process records into its own directory.

use std::path::Path;

use crate::tracer::TracerConfig;
use crate::{Role, Status, TraceError};

/// What the daemon asks of one process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlOp {
    /// Record `categories` on top of the black box ([`crate::start_recording`]).
    Start { categories: u64 },
    /// Back to the black box ([`crate::stop`]).
    Stop,
    /// Report only.
    Status,
}

/// Runs `op` in this process. A start in a process whose black box has not started yet (a `main`
/// from before task 095, or a test) starts it first, as `role` in `dir`, so a recording does not
/// depend on start-up order; a stop or a status there is [`TraceError::NotInitialized`].
/// Blocking: the first start maps the recording file.
pub fn apply(op: ControlOp, dir: &Path, role: Role) -> Result<Status, TraceError> {
    match op {
        ControlOp::Start { categories } => {
            if crate::status().is_none() {
                // The ring-open thread finishes on its own; nobody waits for it.
                drop(crate::init_process(TracerConfig::for_process(dir, role)));
            }
            crate::start_recording(categories)
        }
        ControlOp::Stop => crate::stop(),
        ControlOp::Status => crate::status().ok_or(TraceError::NotInitialized),
    }
}

impl Role {
    /// The bytes of this role's recording ring file: what a `trace-start` maps in a process of
    /// this role, which the daemon counts against its total cap before it asks.
    pub fn recording_bytes(self) -> u64 {
        crate::RingLayout::of(self.recording_sizes()).total_bytes as u64
    }
}
