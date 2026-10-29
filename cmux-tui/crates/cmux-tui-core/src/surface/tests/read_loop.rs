//! Local PTY terminals read on their owner's read loop:
//! fifty terminals start no `surface-<id>-reader` thread, each one's output
//! reaches its screen in order, each still ends with its own status, and
//! fifty idle terminals add only the loop's threads (and, until
//! p02-threads-237's reaper, one `surface-<id>-wait` each).

use super::*;

const WAIT: Duration = Duration::from_secs(20);
const FIRST_ID: SurfaceId = 9_500;
const FIRST_IDLE_ID: SurfaceId = 9_600;
const TERMINALS: u64 = 50;
const IDLE_CHILD_ENV: &str = "CMUX_READ_LOOP_IDLE_THREADS_CHILD";

/// The threads the read loop adds at idle: `mux-terminal-io` and one
/// parked `mux-terminal-read`.
const LOOP_THREADS: usize = 2;

/// The most workers the owner's Files lane runs at once (`cmux_threads::work`).
const FILES_LANE_WIDTH: usize = 4;

fn lines(count: u32) -> String {
    (1..=count).map(|line| format!("line-{line}")).collect::<Vec<_>>().join("\n")
}

#[test]
fn fifty_local_terminals_read_on_the_owners_loop_in_order() {
    let mux = Mux::new_for_test("read-loop-fifty", SurfaceOptions::default());
    let surfaces: Vec<_> = (0..TERMINALS)
        .map(|index| {
            // 300 numbered lines in several writes, then the exit status.
            let script = format!(
                "i=1; while [ $i -le 300 ]; do echo line-$i; i=$((i+1)); done; exit {}",
                index % 7
            );
            let options = SurfaceOptions {
                cols: 40,
                rows: 10,
                command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
                ..SurfaceOptions::default()
            };
            Surface::spawn(FIRST_ID + index, options, Arc::downgrade(&mux)).expect("spawn")
        })
        .collect();
    let readers = cmux_threads::snapshot()
        .into_iter()
        .filter(|thread| {
            thread.name.ends_with("-reader")
                && (FIRST_ID..FIRST_ID + TERMINALS)
                    .any(|id| thread.name == format!("surface-{id}-reader"))
        })
        .count();
    assert_eq!(readers, 0, "a local terminal started a reader thread");
    assert!(
        mux.terminal_reads().stats().workers
            <= crate::mux::terminal_work::read_loop::MAX_READ_WORKERS
    );

    let deadline = Instant::now() + WAIT;
    let expected_tail = lines(300).lines().skip(300 - 9).collect::<Vec<_>>().join("\n");
    for (index, surface) in surfaces.iter().enumerate() {
        let pty = surface.as_pty().expect("a PTY surface");
        assert!(
            pty.reader_completion.wait_until(deadline),
            "terminal {index}'s reader never ended"
        );
        let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
        let shown: Vec<_> =
            text.lines().map(str::trim_end).filter(|line| !line.is_empty()).collect();
        assert_eq!(shown.join("\n"), expected_tail, "terminal {index}'s screen");
        let code = i32::try_from(index % 7).unwrap();
        let ended = loop {
            if let Some(exit) = surface.terminal_exit() {
                break Some(exit);
            }
            if Instant::now() >= deadline {
                break None;
            }
            std::thread::yield_now();
        };
        assert_eq!(
            ended.map(|exit| exit.outcome),
            Some(crate::terminal_host_protocol::TerminalExitOutcome::Exit { code }),
        );
    }
    assert_eq!(wait_for_sources(&mux, 0), 0, "every ended terminal left the read loop");
}

fn wait_for_sources(mux: &Mux, sources: usize) -> usize {
    let deadline = Instant::now() + WAIT;
    loop {
        let now = mux.terminal_reads().stats().sources;
        if now == sources || Instant::now() >= deadline {
            return now;
        }
        std::thread::yield_now();
    }
}

/// Runs [`fifty_idle_local_terminals_child`] alone in its own process, so
/// the process-wide thread count changes only with its terminals.
#[test]
fn fifty_idle_local_terminals_add_only_the_loop_threads() {
    let status = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--exact",
            "surface::tests::read_loop::fifty_idle_local_terminals_child",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(IDLE_CHILD_ENV, "1")
        .status()
        .expect("runs the child");
    assert!(status.success(), "the child failed (see its output above)");
}

/// The child half of [`fifty_idle_local_terminals_add_only_the_loop_threads`]
/// (does nothing in a normal run).
#[test]
fn fifty_idle_local_terminals_child() {
    if std::env::var_os(IDLE_CHILD_ENV).is_none() {
        return;
    }
    warm_process_threads();
    let mux = Mux::new_for_test("read-loop-idle-threads", SurfaceOptions::default());
    let before = ThreadCount::now();
    let surfaces: Vec<_> = (0..TERMINALS)
        .map(|index| {
            // Prints, then waits for a line of input: idle until the test types.
            let script = format!("echo ready-{index}; read line; exit {}", index % 7);
            let options = SurfaceOptions {
                cols: 40,
                rows: 10,
                command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
                ..SurfaceOptions::default()
            };
            Surface::spawn(FIRST_IDLE_ID + index, options, Arc::downgrade(&mux)).expect("spawn")
        })
        .collect();
    let deadline = Instant::now() + WAIT;
    for (index, surface) in surfaces.iter().enumerate() {
        let ready = format!("ready-{index}");
        let shown = loop {
            let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
            if text.contains(&ready) || Instant::now() >= deadline {
                break text;
            }
            std::thread::yield_now();
        };
        assert!(shown.contains(&ready), "terminal {index} shows {shown:?}");
    }

    // At idle: the loop thread and one parked worker, whatever the count.
    // The terminals' registry publications run on the owner's one Files
    // lane (`mux-files-*`, every terminal's publication sequence shares
    // it): its workers are bounded by the lane's width, not by the number
    // of terminals, and are reclaimed after its idle timeout, so they are
    // the owner's shared pool, not threads these terminals add.
    let (added, waits, shared, os_added) = loop {
        let added = before.added();
        let waits = added
            .iter()
            .filter(|name| {
                (FIRST_IDLE_ID..FIRST_IDLE_ID + TERMINALS)
                    .any(|id| **name == format!("surface-{id}-wait"))
            })
            .count();
        let shared = added.iter().filter(|name| name.starts_with("mux-files-")).count();
        let os_added = before.os_added();
        let settled = added.len() <= LOOP_THREADS + waits + shared
            && os_added.is_none_or(|count| count <= LOOP_THREADS + waits + shared);
        if settled || Instant::now() >= deadline {
            break (added, waits, shared, os_added);
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // p02-threads-237's reaper takes the `-wait` threads; nothing else per terminal is left.
    assert!(waits <= TERMINALS as usize, "{added:?}");
    assert!(shared <= FILES_LANE_WIDTH, "the Files lane grew past its width: {added:?}");
    assert!(added.len() <= LOOP_THREADS + waits + shared, "50 idle terminals added {added:?}");
    if let Some(os_added) = os_added {
        assert!(
            os_added <= LOOP_THREADS + waits + shared,
            "50 idle terminals added {os_added} OS threads; registered: {added:?}"
        );
    }

    for (index, surface) in surfaces.iter().enumerate() {
        surface.write_bytes(b"\n").expect("types the line");
        let code = i32::try_from(index % 7).unwrap();
        let ended = loop {
            if let Some(exit) = surface.terminal_exit() {
                break Some(exit);
            }
            if Instant::now() >= deadline {
                break None;
            }
            std::thread::yield_now();
        };
        assert_eq!(
            ended.map(|exit| exit.outcome),
            Some(crate::terminal_host_protocol::TerminalExitOutcome::Exit { code }),
            "terminal {index}'s status"
        );
    }
}

/// Starts the process's one-per-process terminal threads (`surface-frames`)
/// with a terminal of another owner, as a running daemon has them already:
/// the count below is what fifty terminals of one owner add.
fn warm_process_threads() {
    let other = Mux::new_for_test("read-loop-idle-warm", SurfaceOptions::default());
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "echo warm".into()]),
        ..SurfaceOptions::default()
    };
    let surface =
        Surface::spawn(FIRST_IDLE_ID + TERMINALS, options, Arc::downgrade(&other)).expect("spawn");
    let pty = surface.as_pty().expect("a PTY surface");
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT), "the warm terminal ended");
}

/// The process's threads at one point, to name the ones started later.
struct ThreadCount {
    registered: std::collections::HashSet<u64>,
    #[cfg(target_os = "linux")]
    os: usize,
}

impl ThreadCount {
    fn now() -> Self {
        Self {
            registered: cmux_threads::snapshot().into_iter().filter_map(|row| row.tid).collect(),
            #[cfg(target_os = "linux")]
            os: Self::os_threads(),
        }
    }

    /// The names of the registered threads started since [`Self::now`] and
    /// still running.
    fn added(&self) -> Vec<String> {
        cmux_threads::snapshot()
            .into_iter()
            .filter(|row| row.tid.is_none_or(|tid| !self.registered.contains(&tid)))
            .map(|row| row.name)
            .collect()
    }

    /// Every OS thread, registered or not, started since [`Self::now`]
    /// (Linux only: `/proc/self/task`).
    fn os_added(&self) -> Option<usize> {
        #[cfg(target_os = "linux")]
        {
            Some(Self::os_threads().saturating_sub(self.os))
        }
        #[cfg(not(target_os = "linux"))]
        {
            None
        }
    }

    #[cfg(target_os = "linux")]
    fn os_threads() -> usize {
        std::fs::read_dir("/proc/self/task").expect("the process's threads").count()
    }
}
