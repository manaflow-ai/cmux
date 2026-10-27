//! Local PTY terminals read on their owner's read loop (p07-memory-095):
//! fifty terminals start no `surface-<id>-reader` thread, each one's output
//! reaches its screen in order, and each still ends with its own status.

use super::*;

const WAIT: Duration = Duration::from_secs(20);
const FIRST_ID: SurfaceId = 9_500;
const TERMINALS: u64 = 50;

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
