//! Runtime builders that tell this crate what each thread does. They build
//! on [`cmux_threads::tokio`], so every runtime thread is also named,
//! registered and at the runtime's QoS.

use std::future::Future;

use cmux_threads::ThreadQos;
use cmux_threads::tokio::{Flavor, builder_with};
use tokio::runtime::{Builder, Runtime};

use crate::{Role, RoleScope, set_role};

/// Thread hooks for [`multi_thread_with`]. Tokio keeps one hook of each kind,
/// and this crate needs the start and unpark hooks, so other programs (hang
/// watch) pass theirs here, not to the builder. Each runs after this crate's
/// own.
pub use cmux_threads::tokio::ThreadHooks;

/// A multi_thread runtime builder with every driver enabled, threads named
/// `name` at `qos` ([`cmux_threads::tokio::builder`]), whose blocking
/// wrappers are compensated with `block_in_place`. Do not set thread hooks on
/// the returned builder (that replaces this crate's); use
/// [`multi_thread_with`].
pub fn multi_thread(name: impl Into<String>, qos: ThreadQos) -> Builder {
    multi_thread_with(name, qos, ThreadHooks::new())
}

/// [`multi_thread`] that also runs `hooks`.
pub fn multi_thread_with(name: impl Into<String>, qos: ThreadQos, hooks: ThreadHooks) -> Builder {
    let roles = ThreadHooks::new()
        .on_thread_start(|| set_role(Role::RuntimeThread))
        // Tokio calls this only from a scheduler worker, never from a
        // blocking-pool closure.
        .on_thread_unpark(|| set_role(Role::Worker));
    lab_instrumented(builder_with(name, qos, Flavor::MultiThread, roles.then(hooks)))
}

/// A current_thread runtime builder with every driver enabled, its blocking
/// pool named `name` at `qos`. Its tasks run on the thread that calls
/// [`block_on`]. Lab builds also watch every task poll
/// ([`crate::poll_watch`]).
pub fn current_thread(name: impl Into<String>, qos: ThreadQos) -> Builder {
    lab_instrumented(builder_with(name, qos, Flavor::CurrentThread, ThreadHooks::new()))
}

/// Lab builds watch every task poll of `builder`'s runtime
/// ([`crate::poll_watch`]); other builds return it as is.
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
fn lab_instrumented(mut builder: Builder) -> Builder {
    crate::poll_watch::PollWatch::lab().instrument(&mut builder);
    builder
}

#[cfg(not(all(tokio_unstable, feature = "cmux-stability")))]
fn lab_instrumented(builder: Builder) -> Builder {
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
