//! Starting a named, registered thread at a declared QoS.

use std::io;
use std::thread::{Builder, JoinHandle};

use crate::qos::ThreadQos;
use crate::registry;

/// Starts thread `name` at `qos`: it registers itself, sets its QoS before
/// `f` runs, and removes its row when `f` returns or panics, so the row is
/// gone once [`JoinHandle::join`] returns.
///
/// On Linux a thread starts at its creator's nice value; a class above it
/// stays at the creator's value unless the process may lower nice (see
/// [`crate::qos`]), and the refusal is counted on the new thread's row.
pub fn spawn<F, T>(name: impl Into<String>, qos: ThreadQos, f: F) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let name = name.into();
    Builder::new().name(name.clone()).spawn(move || {
        registry::register_current(name, qos);
        let _deregister = Deregister;
        f()
    })
}

struct Deregister;

impl Drop for Deregister {
    fn drop(&mut self) {
        registry::deregister_current();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use crate::{
        LiveQos, QosChange, ThreadInfo, ThreadQos, current, current_slot, set_current, snapshot,
        spawn, with_qos,
    };

    fn row(name: &str) -> Option<ThreadInfo> {
        snapshot().into_iter().find(|row| row.name == name)
    }

    /// What `current()` reads after the calling thread asks for `qos`,
    /// given it read `before` (Linux cannot lower nice unprivileged).
    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn expected_live(qos: ThreadQos, before: LiveQos, may_lower: bool) -> LiveQos {
        let LiveQos::Nice(before) = before else {
            panic!("Linux reads a nice value, got {before:?}");
        };
        let target = qos.linux_nice();
        LiveQos::Nice(if target >= before || may_lower { target } else { before })
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn may_lower_to_zero() -> bool {
        // Ask the kernel: a thread at nice 1 tries nice 0, as root or within
        // RLIMIT_NICE that works.
        spawn("cmux-threads-test-probe", ThreadQos::Background, || {
            set_current(ThreadQos::UserInteractive)
        })
        .unwrap()
        .join()
        .unwrap()
            == QosChange::Applied
    }

    #[test]
    fn utility_thread_reads_utility() {
        let before = current();
        let live = spawn("cmux-threads-test-utility", ThreadQos::Utility, current)
            .unwrap()
            .join()
            .unwrap();
        #[cfg(target_vendor = "apple")]
        {
            let _ = before;
            assert_eq!(live, LiveQos::Class(ThreadQos::Utility));
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        assert_eq!(live, expected_live(ThreadQos::Utility, before, may_lower_to_zero()));
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        assert_eq!((before, live), (LiveQos::Unknown, LiveQos::Unknown));
    }

    #[test]
    fn registry_row_is_present_while_running_and_gone_after_join() {
        const NAME: &str = "cmux-threads-test-row";
        let (started_tx, started_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel::<()>();
        let handle = spawn(NAME, ThreadQos::Utility, move || {
            started_tx.send(()).unwrap();
            finish_rx.recv().unwrap();
        })
        .unwrap();
        started_rx.recv().unwrap();

        let running = row(NAME).expect("row while running");
        assert_eq!(running.declared, ThreadQos::Utility);
        assert_eq!(running.desired, ThreadQos::Utility);
        assert_ne!(running.live, LiveQos::Unspecified);
        #[cfg(any(target_vendor = "apple", target_os = "linux", target_os = "android"))]
        assert!(running.tid.is_some());

        finish_tx.send(()).unwrap();
        handle.join().unwrap();
        assert_eq!(row(NAME), None);
    }

    #[test]
    fn row_is_gone_after_a_panicking_thread_joins() {
        const NAME: &str = "cmux-threads-test-panic";
        let result =
            spawn(NAME, ThreadQos::Background, || panic!("expected test panic")).unwrap().join();
        assert!(result.is_err());
        assert_eq!(row(NAME), None);
    }

    #[test]
    fn with_qos_restores_the_previous_qos() {
        let (before, inside, after) =
            spawn("cmux-threads-test-with-qos", ThreadQos::UserInitiated, || {
                let before = current();
                let inside = with_qos(ThreadQos::Background, current);
                (before, inside, current())
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(after, before);
        #[cfg(target_vendor = "apple")]
        {
            assert_eq!(before, LiveQos::Class(ThreadQos::UserInitiated));
            assert_eq!(inside, LiveQos::Class(ThreadQos::Background));
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            // Background raises nice to 10; going back needs the right to
            // lower nice. Without it with_qos keeps the thread where it was.
            let restorable = may_lower_to_zero() || before == LiveQos::Nice(10);
            let expected = if restorable { LiveQos::Nice(10) } else { before };
            assert_eq!(inside, expected);
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        let _ = inside;
    }

    #[test]
    fn with_qos_restores_after_a_panic() {
        let (before, after) =
            spawn("cmux-threads-test-with-qos-panic", ThreadQos::UserInitiated, || {
                let before = current();
                let caught = std::panic::catch_unwind(|| {
                    with_qos(ThreadQos::Utility, || panic!("expected test panic"))
                });
                assert!(caught.is_err());
                (before, current())
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(after, before);
    }

    #[test]
    fn set_current_updates_effective_and_desired_slot_is_separate() {
        const NAME: &str = "cmux-threads-test-slot";
        let (ready_tx, ready_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel::<()>();
        let handle = spawn(NAME, ThreadQos::UserInitiated, move || {
            let slot = current_slot().expect("spawned threads are registered");
            slot.request(ThreadQos::Utility);
            let change = set_current(ThreadQos::Background);
            ready_tx.send(change).unwrap();
            finish_rx.recv().unwrap();
        })
        .unwrap();
        let change = ready_rx.recv().unwrap();
        let running = row(NAME).unwrap();
        assert_eq!(running.declared, ThreadQos::UserInitiated);
        assert_eq!(running.desired, ThreadQos::Utility);
        #[cfg(any(target_vendor = "apple", target_os = "linux", target_os = "android"))]
        {
            assert_eq!(change, QosChange::Applied);
            assert_eq!(running.effective, Some(ThreadQos::Background));
        }
        #[cfg(target_vendor = "apple")]
        assert_eq!(running.live, LiveQos::Class(ThreadQos::Background));
        #[cfg(any(target_os = "linux", target_os = "android"))]
        assert_eq!(running.live, LiveQos::Nice(10));
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        assert_eq!(change, QosChange::Unsupported);
        finish_tx.send(()).unwrap();
        handle.join().unwrap();
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn linux_refuses_and_records_a_nice_decrease_it_may_not_make() {
        if may_lower_to_zero() {
            return; // root or RLIMIT_NICE: the decrease is allowed here.
        }
        const NAME: &str = "cmux-threads-test-refused";
        let (ready_tx, ready_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel::<()>();
        let handle = spawn(NAME, ThreadQos::Background, move || {
            let refused_before = crate::refused_changes();
            ready_tx.send((set_current(ThreadQos::UserInteractive), refused_before)).unwrap();
            finish_rx.recv().unwrap();
        })
        .unwrap();
        let (change, refused_before) = ready_rx.recv().unwrap();
        let running = row(NAME).unwrap();
        assert_eq!(change, QosChange::Refused);
        assert!(crate::refused_changes() > refused_before);
        assert_eq!(running.refused_changes, 1);
        assert_eq!(running.effective, Some(ThreadQos::Background));
        assert_eq!(running.live, LiveQos::Nice(10));
        finish_tx.send(()).unwrap();
        handle.join().unwrap();
    }

    #[test]
    fn register_current_adds_a_row_that_leaves_with_the_thread() {
        const NAME: &str = "cmux-threads-test-register";
        let (ready_tx, ready_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel::<()>();
        #[allow(clippy::disallowed_methods)] // A thread cmux did not start, as tokio's are.
        let handle = std::thread::spawn(move || {
            let first = crate::register_current(NAME, ThreadQos::Utility);
            let second =
                crate::register_current("cmux-threads-test-register-again", ThreadQos::Background);
            ready_tx.send((first, second)).unwrap();
            finish_rx.recv().unwrap();
        });
        assert_eq!(ready_rx.recv().unwrap(), (true, false));
        assert_eq!(row(NAME).map(|row| row.declared), Some(ThreadQos::Utility));
        assert_eq!(row("cmux-threads-test-register-again"), None);
        finish_tx.send(()).unwrap();
        handle.join().unwrap();
        assert_eq!(row(NAME), None);
    }

    #[test]
    fn crate_depends_on_libc_only() {
        let manifest = include_str!("../Cargo.toml");
        let dependency_lines: Vec<&str> = manifest
            .split("\n[")
            .filter(|section| {
                section.split(']').next().is_some_and(|header| header.ends_with("dependencies"))
            })
            .flat_map(|section| section.lines().skip(1))
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .collect();
        assert_eq!(dependency_lines, ["libc.workspace = true"]);
    }
}
