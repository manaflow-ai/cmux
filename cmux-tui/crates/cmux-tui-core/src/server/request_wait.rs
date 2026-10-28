//! The rest of a request that waits on another process or the network, run
//! as a work item instead of a thread of its own (p02-threads 230).
//!
//! Chrome posts such work to a `MayBlock` task runner at the priority of what
//! it serves and marks the wait `ScopedBlockingCall(BlockingType::WILL_BLOCK)`
//! (base/task/task_traits.h, base/threading/scoped_blocking_call.h): the pool
//! runs one more task meanwhile, so a slow peer never holds a slot.

use cmux_threads::work::{Lane, Refused, Shutdown};

use crate::event_cause::EventCause;
use crate::mux::Mux;

impl Mux {
    /// Runs `body` on the System lane at the priority of the request this
    /// thread serves ([`EventCause::work_priority`]), its wait outside the
    /// lane's limits ([`cmux_threads::work::will_block`]). Shutdown does not
    /// wait for it: its connection closes anyway. `Err` when shutdown has
    /// begun, `body` then dropped unrun.
    pub(crate) fn post_request_wait(
        &self,
        body: impl FnOnce() + Send + 'static,
    ) -> Result<(), Refused> {
        self.work.post(
            EventCause::current().work_priority(),
            Lane::System,
            Shutdown::ContinueOnShutdown,
            move || cmux_threads::work::will_block(body),
        )
    }
}
