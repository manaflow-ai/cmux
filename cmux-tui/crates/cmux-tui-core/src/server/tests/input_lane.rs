//! TYPING UNDER LOAD F4 (Lawrence 2026-11-02: "typing into terminals is never laggy, even when there's a lot of
//! CLI/mcp commands and browser use and browser tabs going on in the background"). Under the measured load the
//! person's key waited in the daemon before its PTY write: socket submit to PTY arrival p95 54 ms, max 475 ms, while
//! the app's own part was p95 9 ms (STATUS 5299). A key's `send` looked its terminal up through the session lock
//! (`Mux::surface`) before the write, and its sizing note took that lock again after it, so every list, snapshot and
//! durable mutation an agent, the CLI or MCP ran held the person's typing back.
//!
//! The person's input goes before automation (CLAUDE.md, Chrome's input rule): a key reaches its terminal while other
//! threads hold the session lock for the whole time.

use super::*;
use base64::Engine;
use std::sync::mpsc;
use std::time::Instant;

fn key(surface: SurfaceId, byte: u8) -> Command {
    Command::Send(cmd_terminal_io::SendParams {
        surface: Some(surface),
        terminal_id: None,
        text: None,
        bytes: Some(base64::engine::general_purpose::STANDARD.encode([byte])),
        paste: false,
        expect_foreground: None,
        expect_agent: None,
        submit: false,
        flow: None,
    })
}

/// A typing terminal attached by a frontend client, as the app's terminal view attaches it.
fn attached_terminal(mux: &Arc<Mux>) -> (Arc<crate::Surface>, u64, MessageWriter) {
    let surface = mux.new_workspace(Some("typing".into()), Some((80, 24))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    (surface, client, writer)
}

#[cfg(unix)]
#[test]
fn a_key_reaches_its_terminal_while_automation_holds_the_session_lock() {
    let mux = test_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    // The first key of a terminal may find it the long way; every key after it must not wait.
    handle_command(&mux, client, key(typing.id, b'a'), &writer).unwrap();

    // Automation holds the session lock (a list, a snapshot, a durable tab create) for 300 ms.
    let (held, holding) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let holder = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.with_state(|_| {
                held.send(()).unwrap();
                let _ = released.recv_timeout(Duration::from_millis(300));
            })
        }
    });
    holding.recv().unwrap();
    let started = Instant::now();
    let sent = handle_command(&mux, client, key(typing.id, b'b'), &writer);
    let waited = started.elapsed();
    let _ = release.send(());
    holder.join().unwrap();
    sent.unwrap();
    eprintln!("INPUT-LANE key while the session lock is held: {waited:?}");
    assert!(
        waited < Duration::from_millis(150),
        "the key waited {waited:?} for the session lock automation held (budget 150 ms, the lock was held 300 ms)"
    );
    mux.shutdown();
}
