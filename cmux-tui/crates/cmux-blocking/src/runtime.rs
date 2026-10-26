//! Runtime builders that mark the threads which must not block.

use std::future::Future;

use tokio::runtime::{Builder, Runtime};

use crate::{ThreadKind, ThreadKindScope, mark_thread};

/// `Builder::new_multi_thread().enable_all()` whose threads are
/// [`ThreadKind::NoBlock`]. Tokio starts its blocking pool through the same
/// hook, so a raw `tokio::task::spawn_blocking` there counts as compensated;
/// use [`crate::spawn_blocking`], which marks its closure `MayBlock`.
/// A later `on_thread_start` on the returned builder replaces this hook: call
/// [`mark_thread`] from it.
/// Lab builds also watch every task poll ([`crate::poll_watch`]).
pub fn multi_thread() -> Builder {
    let mut builder = Builder::new_multi_thread();
    builder.enable_all().on_thread_start(|| mark_thread(ThreadKind::NoBlock));
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    crate::poll_watch::PollWatch::lab().instrument(&mut builder);
    builder
}

/// `Builder::new_current_thread().enable_all()`. Its tasks run on the thread
/// that calls [`block_on`], which marks it for the length of the call.
/// Lab builds also watch every task poll ([`crate::poll_watch`]).
pub fn current_thread() -> Builder {
    let mut builder = Builder::new_current_thread();
    builder.enable_all();
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    crate::poll_watch::PollWatch::lab().instrument(&mut builder);
    builder
}

/// `runtime.block_on(future)` with the calling thread [`ThreadKind::NoBlock`]
/// until it returns: a blocking wrapper in a task then stalls every task of
/// a current_thread runtime and is recorded.
pub fn block_on<F: Future>(runtime: &Runtime, future: F) -> F::Output {
    let _no_block = ThreadKindScope::enter(ThreadKind::NoBlock);
    runtime.block_on(future)
}
