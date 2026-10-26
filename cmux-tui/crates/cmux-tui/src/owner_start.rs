//! Process setup that only the terminal owner (the mux server) needs.

mod background_checks;
mod crash_forward;
mod memory_guard;
mod owner_panic;
pub(crate) mod poll_watch_lab;

/// Debug builds only: the owner's hang log test trigger, once its mux
/// exists (tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub(crate) fn hang_for_test(headless: bool) {
    if headless {
        owner_panic::hang_for_test();
    }
}

/// The QoS of the owner's main thread: it serves requests a person waits
/// on, so UserInitiated (Chromium's kDefault in the `cmux_threads::qos`
/// table), below the UserInteractive echo threads.
const MAIN_THREAD_QOS: cmux_threads::ThreadQos = cmux_threads::ThreadQos::UserInitiated;

/// Lists the calling thread as `main` in the thread registry at
/// [`MAIN_THREAD_QOS`] and sets its QoS, so `cmux_threads::snapshot` (and
/// `server.threads` on it, p02-threads task 203) shows it.
/// Returns false, and changes nothing, when the thread is listed already.
fn register_main_thread() -> bool {
    cmux_threads::register_current("main", MAIN_THREAD_QOS)
}

/// Run the owner's main thread at [`MAIN_THREAD_QOS`], validate the owner's
/// storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
///
/// The headless owner also records every panic (`owner_panic`, cx-urd.59)
/// and sends the ones not sent yet to Sentry (`crash_forward`), and watches
/// its own memory (`memory_guard`), and fetches the signed invite-wave flags
/// and the daily update answer (`background_checks`).
pub(crate) fn prepare(args: &crate::Args) -> anyhow::Result<()> {
    if args.headless {
        owner_panic::install(&args.session);
        #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
        poll_watch_lab::install(&args.session);
        // Earlier panics and memory alerts not sent yet (tester rollout #7),
        // then the memory guard (#9), which sends its alerts as they happen.
        let panic_log = owner_panic::log_path(&args.session);
        let logs = panic_log
            .iter()
            .flat_map(|log| [log.clone(), memory_guard::memory_log_path(log)])
            .collect();
        let forwarder = crash_forward::start(logs);
        memory_guard::spawn(panic_log, forwarder);
        background_checks::spawn();
    }
    // After the background threads above start: a macOS thread inherits
    // its creator's class, and theirs is not the person's.
    register_main_thread();
    if args.ephemeral && args.state.is_some() {
        anyhow::bail!("--ephemeral and --state are mutually exclusive");
    }
    #[cfg(unix)]
    if let Err(error) = cmux_tui_core::raise_open_file_limit(cmux_tui_core::OPEN_FILE_LIMIT_CEILING)
    {
        crate::client_log::stderr_log!(
            "startup",
            "{}: cannot raise the open-file limit: {error}",
            crate::cli::BIN
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use cmux_threads::{LiveQos, ThreadQos};

    /// p02-threads-207: the owner's main thread is a `main` registry row at
    /// UserInitiated, and the kernel runs it at that class. On Linux the
    /// class is nice 0, which a thread started at a higher nice value (a
    /// `nice cargo test`) may not take back: it is checked from nice 0 only.
    #[test]
    fn the_main_thread_registers_at_user_initiated() {
        std::thread::spawn(|| {
            let before = cmux_threads::current();
            assert!(super::register_main_thread());
            assert!(!super::register_main_thread(), "a second call changes nothing");
            let row = cmux_threads::snapshot()
                .into_iter()
                .find(|row| row.name == "main")
                .expect("a main row");
            assert_eq!(row.declared, ThreadQos::UserInitiated);
            if cfg!(target_vendor = "apple") || before == LiveQos::Nice(0) {
                assert_eq!(row.effective, Some(ThreadQos::UserInitiated));
            }
            #[cfg(target_vendor = "apple")]
            assert_eq!(row.live, LiveQos::Class(ThreadQos::UserInitiated));
            #[cfg(target_os = "linux")]
            assert!(before != LiveQos::Nice(0) || row.live == LiveQos::Nice(0), "{:?}", row.live);
        })
        .join()
        .unwrap();
        assert!(
            cmux_threads::snapshot().iter().all(|row| row.name != "main"),
            "the row leaves with its thread"
        );
    }
}
