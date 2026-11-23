use super::Published;

#[derive(Default)]
struct Counter {
    value: u64,
    reads: u64,
}

fn project(counter: &Counter) -> u64 {
    counter.value
}

#[test]
fn a_change_is_published_when_its_guard_drops_and_a_read_publishes_nothing() {
    let published = Published::new(Counter::default(), project, true);
    assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 0);
    {
        let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
        guard.value = 7;
        // Not yet: the guard still holds the change.
        assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 0);
    }
    assert_eq!(
        **published.load().unwrap_or_else(|poison| poison.into_inner()),
        7,
        "the change was published when its guard dropped"
    );
    let before = published.load_full_for_test();
    {
        let guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
        assert_eq!(guard.reads, 0);
    }
    assert!(
        std::sync::Arc::ptr_eq(&before, &published.load_full_for_test()),
        "a guard that only read published nothing"
    );
}

#[test]
fn a_reader_does_not_wait_for_a_writer_that_holds_the_value() {
    let published = std::sync::Arc::new(Published::new(Counter::default(), project, true));
    let (held, holding) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel::<()>();
    let writer = std::thread::spawn({
        let published = published.clone();
        move || {
            let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
            guard.value = 1;
            let _ = held.send(());
            let _ = released.recv_timeout(std::time::Duration::from_secs(5));
        }
    });
    let _ = holding.recv();
    let started = std::time::Instant::now();
    let seen = **published.load().unwrap_or_else(|poison| poison.into_inner());
    let waited = started.elapsed();
    let _ = release.send(());
    let _ = writer.join();
    assert_eq!(seen, 0, "the reader saw the last finished change, not the one in progress");
    assert!(waited < std::time::Duration::from_millis(100), "the reader waited {waited:?}");
    assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 1);
}

/// A writer that panics in the middle of a change leaves a half-made value: its guard still drops (the unwind
/// runs it), but it publishes nothing, so no reader ever sees the half-made change, not even in the moment before
/// the mutex is marked poisoned. Readers then fail closed with the last finished projection.
#[test]
fn a_change_cut_short_by_a_panic_is_never_published() {
    let published = Published::new(Counter::default(), project, true);
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
        guard.value = 9;
        panic!("a writer panics in the middle of a change");
    }));
    let Err(poisoned) = published.load() else {
        panic!("a reader of a poisoned value must be able to fail closed");
    };
    assert_eq!(**poisoned.into_inner(), 0, "the half-made change was published");
}

#[test]
fn a_poisoned_value_gives_its_projection_in_the_error() {
    let published = Published::new(Counter::default(), project, true);
    assert!(published.load().is_ok());
    published.poison_for_test();
    assert!(published.is_poisoned());
    assert!(published.load().is_err(), "a reader can fail closed on a poisoned value");
}

/// A guard taken while the thread already unwinds (a cleanup in a `Drop`) finishes its change: it is published,
/// as std leaves such a mutex unpoisoned.
#[test]
fn a_change_made_during_an_unwind_is_published() {
    struct Cleanup<'a>(&'a Published<Counter, u64>);
    impl Drop for Cleanup<'_> {
        fn drop(&mut self) {
            self.0.lock().unwrap_or_else(|poison| poison.into_inner()).value = 5;
        }
    }
    let published = Published::new(Counter::default(), project, true);
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _cleanup = Cleanup(&published);
        panic!("an unrelated panic runs the cleanup");
    }));
    assert!(!published.is_poisoned());
    assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 5);
}

/// Off, nothing is published and a reader is told so.
#[test]
fn a_value_that_does_not_publish_says_so() {
    let published = Published::new(Counter::default(), project, false);
    assert!(!published.publishing());
    published.lock().unwrap_or_else(|poison| poison.into_inner()).value = 3;
    assert_eq!(*published.load_full_for_test(), 0, "a change was published while off");
    published.set_publishing_for_test(true);
    assert!(published.publishing());
    assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 3);
}

impl<T, S> Published<T, S> {
    fn load_full_for_test(&self) -> std::sync::Arc<S> {
        self.projection.load_full()
    }

    /// Poisons the value: a panic while it is held (fail-closed tests).
    fn poison_for_test(&self) {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _held = self.lock();
            panic!("poisons the value for a fail-closed test");
        }));
    }
}
