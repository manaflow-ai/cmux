//! Tokio runtimes whose threads are named, registered and at a declared QoS
//! (feature `tokio`).
//!
//! Chromium names every thread it starts and gives it a ThreadType: pool
//! workers are created through `base::ThreadPoolInstance` with a name and a
//! ThreadType (base/task/thread_pool/thread_group_impl.cc), never as anonymous
//! OS threads. A tokio runtime starts its own threads, so the same rule is set
//! here once, in the builder: [`builder`] sets the thread name, and its
//! `on_thread_start` registers the thread ([`crate::register_current`]) at
//! the runtime's QoS before any task runs on it. `server.threads` then lists
//! every worker and blocking-pool thread of every daemon runtime.
//!
//! Daemon-linked crates build runtimes only here (or through cmux-blocking's
//! builders, which call [`builder_with`]); CLI-only binaries are exempt.
//! Tokio keeps one hook of each kind, so a caller that needs its own thread
//! hooks passes them as [`ThreadHooks`] to [`builder_with`], never to the
//! returned builder.
//!
//! A thread that waits for a runtime blocks: [`block_on`] and
//! [`handle_block_on`] run the wait as a checked [`BlockingKind::BlockOn`]
//! call (Chrome's `ScopedBlockingCall`), so a request or echo thread that
//! disallows blocking records the site.

use std::future::Future;
use std::sync::Arc;

use ::tokio::runtime::{Builder, Handle, Runtime};

use crate::blocking::{BlockingKind, scoped_blocking_call};
use crate::qos::ThreadQos;
use crate::registry;

/// The scheduler of a runtime from [`builder`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavor {
    /// Tasks run on the thread that calls [`block_on`]; the runtime's own
    /// threads are its blocking pool.
    CurrentThread,
    /// A pool of worker threads plus the blocking pool.
    MultiThread,
}

type Hook = Arc<dyn Fn() + Send + Sync + 'static>;

/// Extra tokio thread hooks for [`builder_with`]. Hooks of one kind run in
/// the order they were added; a start hook runs after the thread is
/// registered, a stop hook before its row is removed.
#[derive(Clone, Default)]
pub struct ThreadHooks {
    start: Option<Hook>,
    stop: Option<Hook>,
    park: Option<Hook>,
    unpark: Option<Hook>,
}

fn chain(first: Option<Hook>, then: Option<Hook>) -> Option<Hook> {
    match (first, then) {
        (Some(first), Some(then)) => Some(Arc::new(move || {
            first();
            then();
        })),
        (first, then) => first.or(then),
    }
}

fn run(hook: Option<&Hook>) {
    if let Some(hook) = hook {
        hook();
    }
}

impl ThreadHooks {
    pub fn new() -> Self {
        Self::default()
    }

    /// Tokio's `on_thread_start`: every runtime thread, workers and
    /// blocking-pool threads alike.
    pub fn on_thread_start(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.start = chain(self.start, Some(Arc::new(hook)));
        self
    }

    /// Tokio's `on_thread_stop`.
    pub fn on_thread_stop(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.stop = chain(self.stop, Some(Arc::new(hook)));
        self
    }

    /// Tokio's `on_thread_park`: a scheduler worker about to park.
    pub fn on_thread_park(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.park = chain(self.park, Some(Arc::new(hook)));
        self
    }

    /// Tokio's `on_thread_unpark`: a scheduler worker that unparked.
    pub fn on_thread_unpark(mut self, hook: impl Fn() + Send + Sync + 'static) -> Self {
        self.unpark = chain(self.unpark, Some(Arc::new(hook)));
        self
    }

    /// These hooks, then `later`'s, for each kind.
    pub fn then(self, later: ThreadHooks) -> Self {
        Self {
            start: chain(self.start, later.start),
            stop: chain(self.stop, later.stop),
            park: chain(self.park, later.park),
            unpark: chain(self.unpark, later.unpark),
        }
    }
}

/// A runtime builder of `flavor` with every driver enabled whose threads are
/// named `name`, registered and set to `qos`. Do not set thread hooks on the
/// returned builder (that replaces the registration); use [`builder_with`].
pub fn builder(name: impl Into<String>, qos: ThreadQos, flavor: Flavor) -> Builder {
    builder_with(name, qos, flavor, ThreadHooks::new())
}

/// [`builder`] that also runs `hooks` on the runtime's threads.
pub fn builder_with(
    name: impl Into<String>,
    qos: ThreadQos,
    flavor: Flavor,
    hooks: ThreadHooks,
) -> Builder {
    let name: Arc<str> = Arc::from(name.into());
    let ThreadHooks { start, stop, park, unpark } = hooks;
    let mut builder = match flavor {
        Flavor::CurrentThread => Builder::new_current_thread(),
        Flavor::MultiThread => Builder::new_multi_thread(),
    };
    let registered_name = Arc::clone(&name);
    builder
        .enable_all()
        .thread_name(&*name)
        .on_thread_start(move || {
            registry::register_current(&*registered_name, qos);
            run(start.as_ref());
        })
        .on_thread_stop(move || {
            run(stop.as_ref());
            registry::deregister_current();
        });
    if let Some(park) = park {
        builder.on_thread_park(move || park());
    }
    if let Some(unpark) = unpark {
        builder.on_thread_unpark(move || unpark());
    }
    builder
}

/// `runtime.block_on(future)` as a checked [`BlockingKind::BlockOn`] call at
/// the caller: the calling thread waits until the future ends.
#[track_caller]
pub fn block_on<F: Future>(runtime: &Runtime, future: F) -> F::Output {
    scoped_blocking_call(BlockingKind::BlockOn, || runtime.block_on(future))
}

/// [`block_on`] through a runtime handle.
#[track_caller]
pub fn handle_block_on<F: Future>(handle: &Handle, future: F) -> F::Output {
    scoped_blocking_call(BlockingKind::BlockOn, || handle.block_on(future))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier, Mutex};

    use super::{Flavor, ThreadHooks, block_on, builder, builder_with};
    use crate::blocking::{BlockingKind, BlockingMode, snapshot as blocking_snapshot, with_mode};
    use crate::{ThreadInfo, ThreadQos, current_slot, snapshot, with_blocking_disallowed};

    fn rows(name: &str) -> Vec<ThreadInfo> {
        snapshot().into_iter().filter(|row| row.name == name).collect()
    }

    /// The calling thread's name and registry slot.
    fn identity() -> (Option<String>, Option<(String, ThreadQos)>) {
        let name = std::thread::current().name().map(str::to_owned);
        let slot = current_slot().map(|slot| (slot.name().to_owned(), slot.desired()));
        (name, slot)
    }

    #[test]
    fn multi_thread_workers_are_named_and_registered_at_the_runtime_qos() {
        const NAME: &str = "cmux-threads-test-tokio-mt";
        const WORKERS: usize = 2;
        let runtime = builder(NAME, ThreadQos::Utility, Flavor::MultiThread)
            .worker_threads(WORKERS)
            .build()
            .unwrap();
        // Each task holds its worker at the barrier until every worker has
        // one, so every worker reports, with every row in the registry.
        let barrier = Arc::new(Barrier::new(WORKERS));
        let tasks: Vec<_> = (0..WORKERS)
            .map(|_| {
                let barrier = Arc::clone(&barrier);
                runtime.spawn(async move {
                    barrier.wait();
                    (identity(), rows(NAME).len())
                })
            })
            .collect();
        let reports = block_on(&runtime, async {
            let mut reports = Vec::new();
            for task in tasks {
                reports.push(task.await.unwrap());
            }
            reports
        });
        for ((name, slot), registered) in reports {
            assert_eq!(name.as_deref(), Some(NAME));
            assert_eq!(slot, Some((NAME.to_owned(), ThreadQos::Utility)));
            assert!(registered >= WORKERS, "every worker has a row: {registered}");
        }
        assert!(rows(NAME).iter().all(|row| row.declared == ThreadQos::Utility));

        drop(runtime);
        assert_eq!(rows(NAME), Vec::new(), "rows go when the runtime's threads stop");
    }

    #[test]
    fn current_thread_blocking_pool_threads_are_registered() {
        const NAME: &str = "cmux-threads-test-tokio-ct";
        let runtime = builder(NAME, ThreadQos::Background, Flavor::CurrentThread).build().unwrap();
        let identity =
            block_on(&runtime, async { ::tokio::task::spawn_blocking(identity).await.unwrap() });
        assert_eq!(identity.0.as_deref(), Some(NAME));
        assert_eq!(identity.1, Some((NAME.to_owned(), ThreadQos::Background)));
        drop(runtime);
        assert_eq!(rows(NAME), Vec::new());
    }

    #[test]
    fn hooks_run_in_order_after_registration() {
        const NAME: &str = "cmux-threads-test-tokio-hooks";
        static ORDER: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
        static REGISTERED_AT_START: AtomicUsize = AtomicUsize::new(0);
        let first = ThreadHooks::new().on_thread_start(|| {
            if current_slot().is_some_and(|slot| slot.name() == NAME) {
                REGISTERED_AT_START.fetch_add(1, Ordering::Relaxed);
            }
            ORDER.lock().unwrap().push("first");
        });
        let second = ThreadHooks::new().on_thread_start(|| ORDER.lock().unwrap().push("second"));
        let runtime =
            builder_with(NAME, ThreadQos::Utility, Flavor::MultiThread, first.then(second))
                .worker_threads(1)
                .build()
                .unwrap();
        block_on(&runtime, async {});
        drop(runtime);
        let order = ORDER.lock().unwrap().clone();
        assert!(!order.is_empty());
        assert_eq!(order.len() % 2, 0, "{order:?}");
        assert!(order.chunks(2).all(|pair| pair == ["first", "second"]), "{order:?}");
        assert_eq!(REGISTERED_AT_START.load(Ordering::Relaxed), order.len() / 2);
    }

    #[test]
    fn block_on_on_a_thread_that_disallows_blocking_records_its_site() {
        let runtime =
            builder("cmux-threads-test-tokio-site", ThreadQos::Utility, Flavor::CurrentThread)
                .build()
                .unwrap();
        let line = line!() + 2;
        with_mode(BlockingMode::Record, || {
            with_blocking_disallowed(|| block_on(&runtime, async {}));
        });
        let sites = blocking_snapshot();
        let site = sites.site(file!(), line).expect("the block_on site is recorded");
        assert!(site.kinds.contains(BlockingKind::BlockOn), "{site:?}");
    }
}
