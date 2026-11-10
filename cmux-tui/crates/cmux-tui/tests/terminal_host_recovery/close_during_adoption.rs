//! A terminal closed while the restarted owner still adopts it, with the
//! owner stopped right after the close, must not leave the host and its
//! shell running. Dogfood repro on feat d2e95d56: the CLI's `terminal <id>
//! close` (rc 0) plus `server stop` within about 2 s of an owner start left
//! the idle host alive with its shell; its sample shows the accept loop and
//! the child wait, and no client: the host never got Terminate. An adopting
//! terminal has a host but no runtime here. The `terminal.close` effect
//! ended only a runtime, while the legacy `close-terminal` also ends a
//! pending terminal's host. Both entry points are tested. A debug seam holds
//! the adoption after it connected and before it finishes, so the close
//! comes at that moment without a timer. The host must end in the same
//! owner life, not at the next start.

use std::io::Read as _;
use std::os::unix::ffi::OsStrExt as _;

use cmux_tui_core::terminal_host_runtime::wait_for_terminal_host_exit;

use super::*;

fn make_fifo(path: &Path) {
    let path = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path; mkfifo only creates the node.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0, "mkfifo failed");
}

/// Reads `fifo` to its end on a thread; the channel gets the result once the
/// last writer closed it.
fn read_fifo_to_end(fifo: &Path) -> mpsc::Receiver<std::io::Result<()>> {
    let (done, receiver) = mpsc::channel();
    let fifo = fifo.to_path_buf();
    std::thread::spawn(move || {
        let result = fs::File::open(&fifo).and_then(|mut reader| {
            reader.read_to_end(&mut Vec::new())?;
            Ok(())
        });
        let _ = done.send(result);
    });
    receiver
}

/// How the test closes the terminal.
#[derive(Clone, Copy, Debug)]
enum CloseEntry {
    /// The resource operation `terminal.close` (the CLI's `terminal <id> close`).
    ResourceTerminalClose,
    /// The legacy `close-terminal` command.
    LegacyCloseTerminal,
}

#[test]
fn a_closed_terminal_host_ends_when_terminal_close_comes_during_a_connected_adoption() {
    close_during_a_connected_adoption(CloseEntry::ResourceTerminalClose);
}

#[test]
fn a_closed_terminal_host_ends_when_close_terminal_comes_during_a_connected_adoption() {
    close_during_a_connected_adoption(CloseEntry::LegacyCloseTerminal);
}

fn close_during_a_connected_adoption(entry: CloseEntry) {
    let mut harness = RecoveryHarness::start("close-during-adoption");
    // The shell holds this FIFO open for writing until it ends, so EOF on it
    // is the shell's exit.
    let shell_fifo = harness.dir.join("shell.fifo");
    make_fifo(&shell_fifo);
    let shell_ended = read_fifo_to_end(&shell_fifo);
    let shell_fifo = shell_fifo.to_str().unwrap();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "exec 3>\"$1\"; exec cat", "sh", shell_fifo],
            "new_workspace": true,
            "name": "close-during-adoption",
        }),
    );
    let host_terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let terminals = resource_request(
        &harness.socket,
        "close-during-adoption-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "{terminals:?}");
    let terminal = terminals[0]["id"].as_str().unwrap().to_string();

    // The host holds its live marker's lease for its whole life, so taking
    // the lease is its exit event.
    let (exited, host_exit) = mpsc::channel();
    {
        let record = record.clone();
        std::thread::spawn(move || {
            let result = wait_for_terminal_host_exit(&record_path, &record);
            let _ = exited.send(result.map_err(|error| format!("{error:#}")));
        });
    }

    // An orderly owner stop keeps the host. The next owner's adoption
    // connects to it and then waits on the seam until it is released.
    harness.terminate();
    let held_fifo = harness.dir.join("adoption-held.fifo");
    let release_fifo = harness.dir.join("adoption-release.fifo");
    make_fifo(&held_fifo);
    make_fifo(&release_fifo);
    harness.extra_env.push((
        "CMUX_TUI_TEST_ADOPTION_HOLD_FIFOS".into(),
        format!("{}:{}", held_fifo.display(), release_fifo.display()),
    ));
    let held = read_fifo_to_end(&held_fifo);
    harness.restart();
    let held = held.recv_timeout(test_timeout(Duration::from_secs(30)));
    assert!(matches!(held, Ok(Ok(()))), "the restarted owner's adoption never connected: {held:?}");

    match entry {
        CloseEntry::ResourceTerminalClose => {
            resource_request(
                &harness.socket,
                "close-during-adoption-close",
                "terminal.close",
                serde_json::json!({"machine":"current","session":"current","terminal":&terminal}),
                Some("close-during-adoption-close"),
            );
        }
        CloseEntry::LegacyCloseTerminal => {
            let closed = request(
                &harness.socket,
                serde_json::json!({
                    "id": 2,
                    "cmd": "close-terminal",
                    "terminal_id": &host_terminal_id,
                    "terminal_incarnation": &incarnation,
                }),
            );
            assert_eq!(closed["terminal_id"].as_str(), Some(host_terminal_id.as_str()), "{closed}");
        }
    }
    // The owner stops right after the close, as `server stop` did in the
    // repro, while its adoption still waits on the seam.
    harness.terminate();

    let ended = host_exit.recv_timeout(test_timeout(Duration::from_secs(30)));
    assert!(
        matches!(ended, Ok(Ok(()))),
        "the host of a terminal closed ({entry:?}) during its connected adoption outlived its \
         owner: {ended:?} (host pid {})",
        record.host_pid
    );
    let shell = shell_ended.recv_timeout(test_timeout(Duration::from_secs(10)));
    assert!(
        matches!(shell, Ok(Ok(()))),
        "the closed terminal's shell still runs ({entry:?}): {shell:?}"
    );
}
