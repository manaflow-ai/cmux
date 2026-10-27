//! Runtime builders that tell this crate what each thread does.

use std::future::Future;
use std::sync::Arc;

use tokio::runtime::{Builder, Runtime};

use crate::{Role, RoleScope, set_role};

type Hook = Arc<dyn Fn() + Send + Sync + 'static>;

/// Thread hooks for [`multi_thread_with`]. Tokio keeps one hook of each kind,
/// and this crate needs the start and unpark hooks, so other programs
/// (thread registration, hang watch) pass theirs here, not to the builder.
/// Each runs after this crate's own.
#[derive(Clone, Default)]
pub struct ThreadHooks {
    start: Option<Hook>,
    stop: Option<Hook>,
    park: Option<Hook>,
    unpark: Option<Hook>,
}

impl ThreadHooks {
    pub fn new() -> Self {
        Self::default()
    }

    /// Tokio's `on_thread_start`: every runtime thread, workers and
    /// blocking-pool threads alike.
    pub fn on_thread_start(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.start = Some(Arc::new(hook));
        self
    }

    /// Tokio's `on_thread_stop`.
    pub fn on_thread_stop(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.stop = Some(Arc::new(hook));
        self
    }

    /// Tokio's `on_thread_park`: a scheduler worker about to park.
    pub fn on_thread_park(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.park = Some(Arc::new(hook));
        self
    }

    /// Tokio's `on_thread_unpark`: a scheduler worker that unparked.
    pub fn on_thread_unpark(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.unpark = Some(Arc::new(hook));
        self
    }
}

fn run(hook: Option<&Hook>) {
    if let Some(hook) = hook {
        hook();
    }
}

/// `Builder::new_multi_thread().enable_all()` whose blocking wrappers are
/// compensated with `block_in_place`. Do not set thread hooks on the returned
/// builder (that replaces this crate's); use [`multi_thread_with`].
pub fn multi_thread() -> Builder {
    multi_thread_with(ThreadHooks::new())
}

/// [`multi_thread`] that also runs `hooks`.
pub fn multi_thread_with(hooks: ThreadHooks) -> Builder {
    let ThreadHooks { start, stop, park, unpark } = hooks;
    let mut builder = Builder::new_multi_thread();
    builder
        .enable_all()
        .on_thread_start(move || {
            set_role(Role::RuntimeThread);
            run(start.as_ref());
        })
        .on_thread_stop(move || run(stop.as_ref()))
        .on_thread_park(move || run(park.as_ref()))
        .on_thread_unpark(move || {
            // Tokio calls this only from a scheduler worker, never from a
            // blocking-pool closure.
            set_role(Role::Worker);
            run(unpark.as_ref());
        });
    // Lab builds also watch every task poll ([`crate::poll_watch`]).
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    crate::poll_watch::PollWatch::lab().instrument(&mut builder);
    builder
}

/// `Builder::new_current_thread().enable_all()`. Its tasks run on the thread
/// that calls [`block_on`]. Lab builds also watch every task poll
/// ([`crate::poll_watch`]).
pub fn current_thread() -> Builder {
    let mut builder = Builder::new_current_thread();
    builder.enable_all();
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    crate::poll_watch::PollWatch::lab().instrument(&mut builder);
    builder
}

/// `runtime.block_on(future)` on a thread that disallows blocking until it
/// returns (Chrome's `ScopedDisallowBlocking`): a wrapped blocking call there
/// stalls every task of a current_thread runtime, or the future itself on a
/// multi_thread one, and is recorded. Blocking the caller until the future
/// ends is itself a `BlockOn` call, checked at the caller.
#[track_caller]
pub fn block_on<F: Future>(runtime: &Runtime, future: F) -> F::Output {
    cmux_threads::blocking::assert_blocking_allowed(cmux_threads::BlockingKind::BlockOn);
    let _driver = RoleScope::enter(Role::Driver);
    cmux_threads::blocking::with_blocking_disallowed(|| runtime.block_on(future))
}
