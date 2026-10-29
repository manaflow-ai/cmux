use super::*;

/// Runs `f` on a new thread, so a QoS change does not leak into the test
/// runner's thread.
fn on_new_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
    std::thread::spawn(f).join().expect("the probe thread does not panic")
}

#[test]
fn types_map_to_the_chromium_thread_type_classes() {
    let classes: Vec<ThreadQos> = ThreadType::ALL.iter().map(|ty| ty.qos()).collect();
    assert_eq!(
        classes,
        [
            ThreadQos::UserInteractive,
            ThreadQos::UserInitiated,
            ThreadQos::Default,
            ThreadQos::Utility,
            ThreadQos::Background,
        ]
    );
}

/// cmux-holder sits below this crate and names its link reader's class
/// itself; it must be the class of the key echo path.
#[test]
fn holder_link_reader_is_input_critical() {
    assert_eq!(cmux_holder::link::LINK_READER_QOS, ThreadType::InputCritical.qos());
}

/// The declared class of every registered row named `name`, waiting up to
/// 5 s for the first one: a spawned thread registers as its body starts.
fn declared_rows(name: &str) -> Vec<ThreadQos> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let rows: Vec<ThreadQos> = cmux_threads::snapshot()
            .into_iter()
            .filter(|row| row.name == name)
            .map(|row| row.declared)
            .collect();
        if !rows.is_empty() || std::time::Instant::now() >= deadline {
            return rows;
        }
        std::thread::yield_now();
    }
}

/// Every running thread named `name` is registered at `qos`; waits up to
/// 5 s for the first.
pub(crate) fn assert_declared(name: &str, qos: ThreadQos) {
    let rows = declared_rows(name);
    assert!(!rows.is_empty(), "{name} is registered while it runs");
    assert!(rows.iter().all(|declared| *declared == qos), "{name}: {rows:?}");
}

/// cmux-config sits below this crate and names its watch thread's class
/// itself; it must be the Utility class.
#[test]
fn config_watch_thread_is_utility() {
    assert_eq!(cmux_config::watch::WATCH_THREAD_QOS, ThreadType::Utility.qos());
    let directory = std::env::temp_dir().join(format!("cmux-qos-config-{}", std::process::id()));
    let watcher = cmux_config::Watcher::start(vec![directory.join("cmux-next.json")], || {})
        .expect("the config watch starts");
    assert_declared("cmux-config-watch", ThreadType::Utility.qos());
    drop(watcher);
}

/// The command history worker is an upkeep thread: declared at the upkeep
/// class, each store or expiry pass lowered to utility.
#[test]
fn command_history_worker_is_an_upkeep_thread() {
    let mux = crate::Mux::new_for_test("qos-command-history", crate::SurfaceOptions::default());
    mux.set_terminal_command_history(false, None).expect("the switch is stored");
    assert_declared("terminal-command-history", crate::request_qos::UPKEEP_THREAD_QOS);
    mux.shutdown();
}

/// The project sources thread is a watcher: declared at the raisable class
/// of utility; each import pass is lowered to utility with
/// `daemonRequestQos` on (`project_watch` tests).
#[test]
fn project_sources_thread_is_a_raisable_watcher() {
    let (release, released) = std::sync::mpsc::channel::<()>();
    let thread = crate::state::project_watch::spawn_thread(move || {
        let _ = released.recv();
    })
    .expect("the project sources thread starts");
    assert_declared(
        "mux-project-sources",
        cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos()),
    );
    drop(release);
    thread.join().expect("the project sources thread ends");
}

/// The echo path threads (`echo_thread::spawn`) declare the InputCritical
/// class.
#[test]
fn echo_path_threads_are_input_critical() {
    assert_eq!(crate::echo_thread::ECHO_PATH_QOS, ThreadType::InputCritical.qos());
}

/// The class the kernel reports for the calling thread, read with
/// `pthread_get_qos_class_np`.
#[cfg(target_vendor = "apple")]
fn kernel_class() -> u32 {
    let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED as u32;
    let mut relative_priority = 0;
    // SAFETY: pthread_self is the live calling thread and both out pointers
    // are valid for the call. The class is read into a `u32`, the enum's
    // repr, so a class the enum has no variant for is still a valid value.
    let rc = unsafe {
        libc::pthread_get_qos_class_np(
            libc::pthread_self(),
            (&raw mut class).cast::<libc::qos_class_t>(),
            &mut relative_priority,
        )
    };
    assert_eq!(rc, 0, "pthread_get_qos_class_np reads the calling thread");
    class
}

#[cfg(target_vendor = "apple")]
#[test]
fn set_applies_the_class_the_kernel_reports() {
    use libc::qos_class_t::*;
    let expected = [
        (ThreadType::InputCritical, QOS_CLASS_USER_INTERACTIVE),
        (ThreadType::Interactive, QOS_CLASS_USER_INITIATED),
        (ThreadType::UnclassifiedClient, QOS_CLASS_DEFAULT),
        (ThreadType::Utility, QOS_CLASS_UTILITY),
        (ThreadType::Background, QOS_CLASS_BACKGROUND),
    ];
    for (thread_type, class) in expected {
        let (change, read) = on_new_thread(move || (set(thread_type), kernel_class()));
        assert_eq!(change, QosChange::Applied, "{thread_type:?}");
        assert_eq!(read, class as u32, "{thread_type:?}");
    }
}

/// A thread can always raise its nice value, so the two lowest classes apply
/// on Linux whatever nice the test runner starts at below them.
#[cfg(any(target_os = "linux", target_os = "android"))]
#[test]
fn set_applies_the_nice_value_on_linux() {
    use cmux_threads::LiveQos;
    for thread_type in [ThreadType::Utility, ThreadType::Background] {
        let (start, change, read) = on_new_thread(move || {
            let start = cmux_threads::current();
            (start, set(thread_type), cmux_threads::current())
        });
        let target = thread_type.qos().linux_nice();
        let LiveQos::Nice(start) = start else {
            panic!("Linux reads a nice value, got {start:?}");
        };
        if start > target {
            continue;
        }
        assert_eq!(change, QosChange::Applied, "{thread_type:?}");
        assert_eq!(read, LiveQos::Nice(target), "{thread_type:?}");
    }
}

/// What a thread reads in its own body: its declared class, its live class
/// (`pthread_get_qos_class_np` on macOS, nice on Linux) and whether it may
/// block.
#[derive(Debug, PartialEq, Eq)]
struct BodyReads {
    declared: ThreadQos,
    live: cmux_threads::LiveQos,
    may_block: bool,
}

fn body_reads() -> BodyReads {
    BodyReads {
        declared: cmux_threads::current_slot().expect("registered").declared(),
        live: cmux_threads::current(),
        may_block: !cmux_threads::blocking::is_blocking_disallowed(),
    }
}

type Probe = Box<dyn FnOnce() -> BodyReads + Send>;

/// The live class a thread the test thread starts at `class` runs at: the
/// class where the test thread can reach it, else the test thread's own (a
/// new thread starts at its creator's class or nice).
fn expected_live(class: ThreadQos) -> cmux_threads::LiveQos {
    if cmux_threads::reachable(class) {
        crate::request_qos::tests::live_at(class)
    } else {
        cmux_threads::current()
    }
}

/// Each role of threading-model.md "Daemon QoS by role"
/// starts a thread through the entry point its production threads use and
/// reads its class inside the body: request helpers through
/// `RequestQos::spawn_helper`, watchers and bulk through `spawn_raisable`,
/// the echo path through `echo_thread::spawn`. Only the echo path disallows
/// blocking: a control stream that waits for its attach to commit
/// (mux-snapshot-attach-out, mux-resource-terminal-attach) must not be one.
/// The deadline fanout worker, a control stream, is checked the same way in
/// mux/tests/cell_pixel_fanout.rs.
#[test]
fn every_role_runs_at_its_class_in_its_body() {
    type Start = fn(Probe) -> BodyReads;
    let roles: [(&str, Start, ThreadQos, bool); 4] = [
        (
            "request helper",
            |probe| {
                crate::request_qos::RequestQosGate::default()
                    .snapshot()
                    .spawn_helper("mux-role-request-helper", probe)
                    .expect("spawn")
                    .join()
                    .expect("join")
            },
            crate::request_qos::REQUEST_HELPER_QOS,
            true,
        ),
        (
            "watcher",
            |probe| {
                spawn_raisable("mux-role-watcher", ThreadType::Utility.qos(), None, probe)
                    .expect("spawn")
                    .join()
                    .expect("join")
            },
            cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos()),
            true,
        ),
        (
            "bulk",
            |probe| {
                spawn_raisable("mux-role-bulk", ThreadType::Utility.qos(), Some(256 * 1024), probe)
                    .expect("spawn")
                    .join()
                    .expect("join")
            },
            cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos()),
            true,
        ),
        (
            "echo path",
            |probe| {
                crate::echo_thread::spawn("mux-role-echo", probe)
                    .expect("spawn")
                    .join()
                    .expect("join")
            },
            crate::echo_thread::ECHO_PATH_QOS,
            false,
        ),
    ];
    for (role, start, class, may_block) in roles {
        let reads = start(Box::new(body_reads));
        assert_eq!(
            reads,
            BodyReads { declared: class, live: expected_live(class), may_block },
            "{role}"
        );
    }
}

/// Waits (bounded) until every live row named `name` that was not in
/// `before` rests at `class`: its own applied change (`effective`, set in
/// its body) and the kernel's report agree. A watcher holding a ranked lock
/// is raised for that moment, and a row is listed before its class is set,
/// so a single read may see neither.
fn new_rows_at_rest(
    name: &str,
    before: &[Option<u64>],
    class: ThreadQos,
) -> Vec<cmux_threads::ThreadInfo> {
    let effective = cmux_threads::reachable(class).then_some(class);
    let live = expected_live(class);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let rows: Vec<_> = cmux_threads::snapshot()
            .into_iter()
            .filter(|row| row.name == name && !before.contains(&row.tid))
            .collect();
        if !rows.is_empty() && rows.iter().all(|row| row.effective == effective && row.live == live)
        {
            return rows;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{name} never rested at {class} ({live:?}): {rows:?}"
        );
        std::thread::yield_now();
    }
}

/// The daemon's watchers start through `spawn_raisable` and
/// rest at its class, with no refused change: Utility where the process can
/// raise them for a lock (macOS), else Default, else (a niced Linux daemon)
/// the class it runs at.
#[test]
fn daemon_watchers_rest_at_their_raisable_class() {
    let names = ["mux-terminal-reap", "mux-idle-close"];
    let before: Vec<Option<u64>> = cmux_threads::snapshot()
        .into_iter()
        .filter(|row| names.contains(&row.name.as_str()))
        .map(|row| row.tid)
        .collect();
    let mux = crate::Mux::new_for_test("daemon-watchers-qos", crate::SurfaceOptions::default());
    let terminal_reaper = crate::start_terminal_reaper(&mux).expect("terminal reaper");
    let idle_reaper = crate::start_idle_terminal_reaper(
        std::sync::Arc::downgrade(&mux),
        crate::IDLE_CLOSE_REAP_INTERVAL,
    )
    .expect("idle reaper");
    let class = cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos());
    #[cfg(target_vendor = "apple")]
    assert_eq!(class, ThreadQos::Utility);
    for name in names {
        for row in new_rows_at_rest(name, &before, class) {
            assert_eq!(row.declared, class, "{name}");
            if cmux_threads::reachable(class) {
                assert_eq!(row.refused_changes, 0, "{name}");
            }
        }
    }
    terminal_reaper.stop();
    idle_reaper.stop();
}
