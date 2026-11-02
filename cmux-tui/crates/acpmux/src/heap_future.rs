//! A future that a large async fn awaits, built in a frame of its own and polled from the heap.
//!
//! A request is polled through a chain of async fns: the connection's request task,
//! `server::list_reply::scope`, `server::chats::route`, `server::requests::handle_request`,
//! `server::requests::dispatch_request`, then the hub. Each poll is a stack frame, and the whole
//! chain is on the worker's stack at once. A build without optimization (acpmux is opt-level 0
//! in the dev profile, which every test and debug build uses) keeps a separate stack slot for
//! each future that a function awaits, in every match arm, not only the arm that runs, and copies
//! each future through two of them. On Linux x86_64 the poll frame of `dispatch_request` (about
//! 130 awaits) was 744 KiB, and the chain needed 2.1-2.3 MiB: more than tokio's 2 MiB worker
//! stack. An in-process hub on such a worker aborted with "has overflowed its stack" (cmux-tui
//! `agent_message_launch_credential` and `agent_message_reply_in_place`, 2026-11-02). The acpmux
//! daemon gives its workers 8 MiB (`cli::entry::WORKER_STACK_BYTES`); that is room for the
//! hub's deeper paths, not for this chain.
//!
//! `heap(|| f(..)).await` builds the future of `f` inside [`heap`], whose frame is gone before
//! the first poll, and moves it to the heap: the frame that awaits it keeps one pointer. Use it
//! on the request path for a future of a few KiB or more (`-Zprint-type-sizes` gives the size).
//! `tests/request_stack.rs` runs requests on a 2 MiB worker.

use std::future::Future;
use std::pin::Pin;

/// The future that `make` returns, boxed. Never inlined, so the future is never in the frame of
/// the caller, in any build.
#[inline(never)]
pub(crate) fn heap<F: Future>(make: impl FnOnce() -> F) -> Pin<Box<F>> {
    Box::pin(make())
}
