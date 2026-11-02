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

/// Records what a test terminal's PTY is sent.
struct InputRecorder(mpsc::Sender<Vec<u8>>);

impl Write for InputRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.send(bytes.to_vec()).unwrap();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// REOPEN-F4/F5 class (lead 2026-11-02): a terminal kept for the person's keys must never outlive the terminal its
/// id routes to. A respawn takes the dead runtime out of the tab and puts a new one in under the same placement id
/// (`terminal_respawn.rs`, `install_respawned_runtime`); the next key must reach the new shell, never the old one.
#[cfg(unix)]
#[test]
fn after_a_respawn_the_next_key_reaches_the_new_terminal() {
    let mux = test_mux();
    let (old, client, writer) = attached_terminal(&mux);
    let (old_sent, old_input) = mpsc::channel();
    old.replace_input_writer_for_test(Box::new(InputRecorder(old_sent)));
    handle_command(&mux, client, key(old.id, b'a'), &writer).unwrap();
    assert_eq!(
        old_input.try_recv().ok(),
        Some(b"a".to_vec()),
        "the first key reached the terminal"
    );

    // The respawn: the old runtime leaves the placement, a new one takes it under the same id. The old one is not
    // dead yet (its host stops after the new one is in), so only the routing says it no longer owns the id.
    let removed = mux.remove_surface_runtime_for_test(old.id).expect("the placement had a runtime");
    assert!(Arc::ptr_eq(&removed, &old));
    let respawned =
        crate::Surface::spawn_for_test(old.id, SurfaceOptions::default(), Arc::downgrade(&mux))
            .unwrap();
    let (new_sent, new_input) = mpsc::channel();
    respawned.replace_input_writer_for_test(Box::new(InputRecorder(new_sent)));
    mux.insert_surface_runtime_for_test(respawned.clone());

    handle_command(&mux, client, key(old.id, b'b'), &writer).unwrap();
    assert_eq!(
        new_input.try_recv().ok(),
        Some(b"b".to_vec()),
        "the key after the respawn did not reach the new shell"
    );
    assert!(
        old_input.try_recv().is_err(),
        "the key after the respawn went to the replaced terminal"
    );
    drop(removed);
    mux.shutdown();
}
