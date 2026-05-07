//! M1 smoke test: spawn `echo hello` in a PTY, feed bytes through
//! libghostty-vt, assert that "hello" appears in the grid.

use std::io::Read;
use std::thread;

use libghostty_vt::{Terminal, TerminalOptions};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};

#[test]
fn echo_hello_lands_in_grid() {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .expect("openpty failed");

    let mut cmd = CommandBuilder::new("echo");
    cmd.arg("hello");

    let mut child = pair.slave.spawn_command(cmd).expect("spawn_command failed");
    // Close our slave handle; child still holds its own fds to it.
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .expect("try_clone_reader failed");

    // Drain master output on a background thread so the kernel buffer
    // never backs up. Reader hits EOF once master is dropped.
    let reader_thread = thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf);
        buf
    });

    let status = child.wait().expect("child wait failed");
    assert!(status.success(), "echo exited non-zero: {status:?}");

    // Dropping master closes our side and unblocks read_to_end on the thread.
    drop(pair.master);

    let buf = reader_thread.join().expect("reader thread panicked");
    assert!(!buf.is_empty(), "PTY yielded no output");

    let mut terminal = Terminal::new(TerminalOptions {
        cols: 80,
        rows: 24,
        max_scrollback: 0,
    })
    .expect("Terminal::new failed");
    terminal.vt_write(&buf);

    let rows = cmux_cli_core::grid::dump_rows(&terminal).expect("dump_rows failed");
    let joined = rows.join("\n");
    assert!(
        rows.iter().any(|r| r.contains("hello")),
        "expected 'hello' in some row. PTY output was {buf:?}. Grid was:\n{joined}"
    );
}
