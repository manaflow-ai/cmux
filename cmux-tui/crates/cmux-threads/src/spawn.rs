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
    start(Builder::new(), name.into(), qos, f)
}

/// [`spawn`] with a stack of `stack_size` bytes instead of the platform
/// default (`std::thread::Builder::stack_size`), for a long-lived thread
/// whose stack need is known to be small.
pub fn spawn_with_stack<F, T>(
    name: impl Into<String>,
    qos: ThreadQos,
    stack_size: usize,
    f: F,
) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    start(Builder::new().stack_size(stack_size), name.into(), qos, f)
}

fn start<F, T>(builder: Builder, name: String, qos: ThreadQos, f: F) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    builder.name(name.clone()).spawn(move || {
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
        LiveQos, QosChange, ThreadInfo, ThreadQos, current, current_slot, refused_changes,
        set_current, snapshot, spawn, spawn_with_stack, with_qos,
    };

    fn row(name: &str) -> Option<ThreadInfo> {
        snapshot().into_iter().find(|row| row.name == name)
    }

    /// The calling thread's own registry row, read from inside the thread.
    fn own_row() -> ThreadInfo {
        let slot = current_slot().expect("spawned threads are registered");
        row(slot.name()).expect("a registered thread has a row")
    }

    /// The nice value of the calling test thread. Threads it spawns start
    /// there: a Linux thread inherits its creator's nice.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn runner_nice() -> i32 {
        match current() {
            LiveQos::Nice(nice) => nice,
            other => panic!("Linux reads a nice value, got {other:?}"),
        }
    }

    /// The nice a thread that starts at `start` reads after it asks for
    /// `qos` (an unprivileged thread cannot lower its nice).
    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn expected_nice(qos: ThreadQos, start: i32, may_lower: bool) -> i32 {
        let target = qos.linux_nice();
        if target >= start || may_lower { target } else { start }
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn may_lower_to_zero() -> bool {
        // Ask the kernel: a thread at nice 10 or above tries nice 0; as root
        // or within RLIMIT_NICE that works.
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
        const NAME: &str = "cmux-threads-test-utility";
        let refused_before = refused_changes();
        let (live, own) =
            spawn(NAME, ThreadQos::Utility, || (current(), own_row())).unwrap().join().unwrap();
        assert_eq!(own.declared, ThreadQos::Utility);
        #[cfg(target_vendor = "apple")]
        {
            let _ = refused_before;
            assert_eq!(live, LiveQos::Class(ThreadQos::Utility));
            assert_eq!(own.effective, Some(ThreadQos::Utility));
            assert_eq!(own.refused_changes, 0);
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            let nice = expected_nice(ThreadQos::Utility, runner_nice(), may_lower_to_zero());
            assert_eq!(live, LiveQos::Nice(nice));
            if nice == ThreadQos::Utility.linux_nice() {
                assert_eq!(own.effective, Some(ThreadQos::Utility));
                assert_eq!(own.refused_changes, 0);
            } else {
                // The runner is above nice 5 and may not lower it: the
                // thread keeps the runner's nice and records the refusal.
                assert_eq!(own.effective, None);
                assert_eq!(own.refused_changes, 1);
                assert!(refused_changes() > refused_before);
            }
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        {
            let _ = refused_before;
            assert_eq!((live, own.effective), (LiveQos::Unknown, None));
        }
    }

    /// A row's priority is the kernel's: 20 + nice on Linux, and on macOS a
    /// UserInteractive thread runs above a Utility one.
    #[test]
    fn a_rows_priority_is_the_schedulers() {
        let read = |name: &'static str, qos| {
            spawn(name, qos, || (current(), own_row().priority)).unwrap().join().unwrap()
        };
        let (utility_live, utility) = read("cmux-threads-test-pri-utility", ThreadQos::Utility);
        let (_, interactive) =
            read("cmux-threads-test-pri-interactive", ThreadQos::UserInteractive);
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            let LiveQos::Nice(nice) = utility_live else { panic!("{utility_live:?}") };
            assert_eq!(utility, Some(20 + nice));
            assert!(interactive.is_some());
        }
        #[cfg(target_vendor = "apple")]
        {
            let _ = utility_live;
            let (utility, interactive) = (utility.unwrap(), interactive.unwrap());
            assert!(interactive > utility, "user-interactive {interactive}, utility {utility}");
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        {
            let _ = utility_live;
            assert_eq!((utility, interactive), (None, None));
        }
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
    fn a_row_names_the_object_its_thread_works_for() {
        let (before, after) = spawn("cmux-threads-test-owner", ThreadQos::Utility, || {
            let before = own_row().owner;
            current_slot().expect("spawned threads are registered").work_for(42);
            (before, own_row().owner)
        })
        .unwrap()
        .join()
        .unwrap();
        assert_eq!(before, None, "a new row works for no object");
        assert_eq!(after, Some(42));
    }

    #[test]
    fn spawn_with_stack_registers_the_thread_at_its_qos() {
        const NAME: &str = "cmux-threads-test-stack";
        let own = spawn_with_stack(NAME, ThreadQos::Utility, 256 * 1024, || {
            // A frame well inside the requested stack runs.
            let frame = std::hint::black_box([7_u8; 64 * 1024]);
            (own_row(), frame.iter().map(|byte| usize::from(*byte)).sum::<usize>())
        })
        .unwrap()
        .join()
        .unwrap();
        assert_eq!((own.0.name.as_str(), own.0.declared), (NAME, ThreadQos::Utility));
        assert_eq!(own.1, 7 * 64 * 1024);
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

    /// A thread's live QoS and registry row at one point.
    type Reading = (LiveQos, ThreadInfo);

    fn reading() -> Reading {
        (current(), own_row())
    }

    #[test]
    fn with_qos_restores_the_previous_qos() {
        let (before, inside, after) =
            spawn("cmux-threads-test-with-qos", ThreadQos::UserInitiated, || {
                let before = reading();
                let inside = with_qos(ThreadQos::Background, reading);
                (before, inside, reading())
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(after.0, before.0);
        assert_eq!(after.1.effective, before.1.effective);
        #[cfg(target_vendor = "apple")]
        {
            assert_eq!(before.0, LiveQos::Class(ThreadQos::UserInitiated));
            assert_eq!(inside.0, LiveQos::Class(ThreadQos::Background));
            assert_eq!(inside.1.effective, Some(ThreadQos::Background));
            assert_eq!(after.1.effective, Some(ThreadQos::UserInitiated));
            assert_eq!(after.1.refused_changes, 0);
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            // Without the right to lower nice, only a thread at nice 10
            // already enters Background: below 10 the restore would need a
            // decrease, above 10 entering is one. Otherwise with_qos keeps
            // the thread where it was and counts the refusal.
            let LiveQos::Nice(start) = before.0 else {
                panic!("Linux reads a nice value, got {:?}", before.0);
            };
            let background = ThreadQos::Background.linux_nice();
            if may_lower_to_zero() || start == background {
                assert_eq!(inside.0, LiveQos::Nice(background));
                assert_eq!(inside.1.effective, Some(ThreadQos::Background));
                assert_eq!(after.1.refused_changes, before.1.refused_changes);
            } else {
                assert_eq!(inside.0, before.0);
                assert_eq!(inside.1.effective, before.1.effective);
                assert_eq!(inside.1.refused_changes, before.1.refused_changes + 1);
            }
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        let _ = inside;
    }

    #[test]
    fn with_qos_restores_after_a_panic() {
        let (before, after) =
            spawn("cmux-threads-test-with-qos-panic", ThreadQos::UserInitiated, || {
                let before = (current(), own_row().effective);
                let caught = std::panic::catch_unwind(|| {
                    with_qos(ThreadQos::Utility, || panic!("expected test panic"))
                });
                assert!(caught.is_err());
                (before, (current(), own_row().effective))
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
            let effective_before = own_row().effective;
            let change = set_current(ThreadQos::Background);
            ready_tx.send((change, effective_before)).unwrap();
            finish_rx.recv().unwrap();
        })
        .unwrap();
        let (change, effective_before) = ready_rx.recv().unwrap();
        let running = row(NAME).unwrap();
        assert_eq!(running.declared, ThreadQos::UserInitiated);
        assert_eq!(running.desired, ThreadQos::Utility);
        #[cfg(target_vendor = "apple")]
        {
            let _ = effective_before;
            assert_eq!(change, QosChange::Applied);
            assert_eq!(running.effective, Some(ThreadQos::Background));
            assert_eq!(running.live, LiveQos::Class(ThreadQos::Background));
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            // A runner above nice 10 that may not lower it stays there.
            let nice = expected_nice(ThreadQos::Background, runner_nice(), may_lower_to_zero());
            assert_eq!(running.live, LiveQos::Nice(nice));
            if nice == ThreadQos::Background.linux_nice() {
                assert_eq!(change, QosChange::Applied);
                assert_eq!(running.effective, Some(ThreadQos::Background));
            } else {
                assert_eq!(change, QosChange::Refused);
                assert_eq!(running.effective, effective_before);
            }
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        {
            let _ = effective_before;
            assert_eq!(change, QosChange::Unsupported);
        }
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
            let before = own_row();
            let process_before = refused_changes();
            let change = set_current(ThreadQos::UserInteractive);
            ready_tx.send((change, before, process_before)).unwrap();
            finish_rx.recv().unwrap();
        })
        .unwrap();
        let (change, before, process_before) = ready_rx.recv().unwrap();
        let running = row(NAME).unwrap();
        assert_eq!(change, QosChange::Refused);
        assert!(refused_changes() > process_before);
        assert_eq!(running.refused_changes, before.refused_changes + 1);
        assert_eq!(running.effective, before.effective);
        // Background's nice, or the runner's when it is above that.
        let nice = expected_nice(ThreadQos::Background, runner_nice(), false);
        assert_eq!(running.live, LiveQos::Nice(nice));
        assert_eq!(before.live, running.live);
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

    /// libc is the one dependency every user builds; crossbeam-channel is
    /// optional, only for crates that enable the `crossbeam` feature.
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
        assert_eq!(
            dependency_lines,
            ["libc.workspace = true", "crossbeam-channel = { workspace = true, optional = true }"]
        );
    }
}
