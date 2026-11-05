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

/// The kept-terminal tests below cover the old path (F4, TYPING FIX 2), the fallback that `CMUX_TUI_RDS_INPUT=0` keeps
/// for one nightly after the input lane became the default (R-DAEMON-STATE S1.7); server/tests/rds_input_lane.rs
/// covers the lane. S1.8 deletes them with the old path.
fn old_path_mux() -> Arc<Mux> {
    let mux = test_mux();
    mux.set_input_lane_for_test(false);
    mux
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
    let mux = old_path_mux();
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
            });
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
    let mux = old_path_mux();
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
    // The replacement takes no Kitty image budget slot: the old runtime still holds this id's slot while it lives,
    // as in a respawn (its host stops after the new runtime is in).
    let respawned =
        crate::Surface::spawn_for_test(old.id, SurfaceOptions::default(), Weak::new()).unwrap();
    let (new_sent, new_input) = mpsc::channel();
    respawned.replace_input_writer_for_test(Box::new(InputRecorder(new_sent)));
    mux.insert_surface_runtime_for_test(respawned);

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

/// A durable mutation that routes nothing (a rename, a focus or layout change) clones the session state and drops a
/// copy. That must not drop the terminal kept for the person's keys: if it did, the next key would take the session
/// lock again and wait behind automation, the F4 delay this lane removes (#31940 review).
#[cfg(unix)]
#[test]
fn a_mutation_that_routes_nothing_keeps_the_key_off_the_session_lock() {
    let mux = old_path_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    handle_command(&mux, client, key(typing.id, b'a'), &writer).unwrap();
    // A pane rename (a durable mutation through the mutation plan) and a state clone dropped, as plans do.
    let pane = mux.with_state(|state| state.pane_of(typing.id).unwrap());
    assert!(mux.rename_pane(pane, "renamed".into()), "the rename did not apply");
    drop(mux.with_state(|state| state.clone()));

    let (held, holding) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let holder = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.with_state(|_| {
                held.send(()).unwrap();
                let _ = released.recv_timeout(Duration::from_millis(300));
            });
        }
    });
    holding.recv().unwrap();
    let started = Instant::now();
    let sent = handle_command(&mux, client, key(typing.id, b'b'), &writer);
    let waited = started.elapsed();
    let _ = release.send(());
    holder.join().unwrap();
    sent.unwrap();
    eprintln!("INPUT-LANE key after a mutation that routes nothing: {waited:?}");
    assert!(
        waited < Duration::from_millis(150),
        "after a mutation that routes nothing the key waited {waited:?} for the session lock (budget 150 ms)"
    );
    mux.shutdown();
}

/// Runs `f` and counts the session lock acquisitions it made on this thread: a path proven to take none never waits
/// behind automation, with no timing in the test.
fn session_locks_of<R>(f: impl FnOnce() -> R) -> (R, u64) {
    let before = crate::mux::state_locks_taken_on_this_thread();
    let result = f();
    (result, crate::mux::state_locks_taken_on_this_thread() - before)
}

/// TYPING FIX 2 (follow-up A of #31940): the kept terminal is dropped only when its own route changes. A tab created
/// or closed in another workspace routes nothing this client types into; it must not send the person's next key back
/// to the session lock. Before, any routing write anywhere moved one process-wide generation, so every attached
/// client's next key took the lock again (O(clients) per tab create, during the agents' tab storms).
#[cfg(unix)]
#[test]
fn a_tab_created_or_closed_elsewhere_keeps_the_key_off_the_session_lock() {
    let mux = old_path_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    handle_command(&mux, client, key(typing.id, b'a'), &writer).unwrap();

    // Automation: a new workspace, a tab in it, and that tab closed again.
    let other = mux.new_workspace(Some("automation".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(other.id).unwrap());
    let tab = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    assert!(mux.close_surface(tab.id).unwrap(), "the automation tab did not close");

    let (sent, locks) =
        session_locks_of(|| handle_command(&mux, client, key(typing.id, b'b'), &writer));
    sent.unwrap();
    assert_eq!(
        locks, 0,
        "a tab created and closed in another workspace sent the person's next key to the session lock"
    );
    mux.shutdown();
}

/// TYPING FIX 2 (follow-up B of #31940): a workspace size default must not put the session lock back on the person's
/// keys. A key notes its view's activity in the sizing engine; that re-expanded the host policy, which asks whether
/// the terminal follows a workspace default, which looked the terminal's workspace up under the session lock (and
/// could walk every surface for its placements) on every key, as soon as any workspace had a default.
#[cfg(unix)]
#[test]
fn a_workspace_size_default_keeps_the_key_off_the_session_lock() {
    let mux = old_path_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    // The settings owner's host policy, and a size default on the typing terminal's workspace.
    let host = crate::mux::host_policy::HostSizePolicy {
        mode: crate::mux::host_policy::HostSizeMode::Latest,
        order: Vec::new(),
    };
    mux.adopt_host_size_policy(host, 1);
    mux.pin_latest_size_policy_for_test(typing.id);
    handle_command(&mux, client, key(typing.id, b'a'), &writer).unwrap();

    let (sent, locks) =
        session_locks_of(|| handle_command(&mux, client, key(typing.id, b'b'), &writer));
    sent.unwrap();
    assert_eq!(locks, 0, "with a workspace size default the person's key took the session lock");
    mux.shutdown();
}

/// TYPING FIX 2 (follow-up C of #31940): `send-key` (a named key such as Return or Ctrl-C from an attached view) goes
/// to the same kept terminal as `send`, under the same route rules, so it takes no session lock either. Before, it
/// looked its terminal up through the session lock on every call.
#[cfg(unix)]
#[test]
fn a_named_key_reaches_its_terminal_without_the_session_lock() {
    let mux = old_path_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    let named = |keys: &[&str]| Command::SendKey {
        surface: typing.id,
        keys: keys.iter().map(|key| (*key).to_string()).collect(),
    };
    handle_command(&mux, client, named(&["enter"]), &writer).unwrap();

    let (sent, locks) =
        session_locks_of(|| handle_command(&mux, client, named(&["ctrl+c"]), &writer));
    sent.unwrap();
    assert_eq!(locks, 0, "a named key from an attached view took the session lock");

    // The same route rule as `send`: after a respawn the next named key reaches the new shell.
    let (new_sent, new_input) = mpsc::channel();
    let removed =
        mux.remove_surface_runtime_for_test(typing.id).expect("the placement had a runtime");
    let respawned =
        crate::Surface::spawn_for_test(typing.id, SurfaceOptions::default(), Weak::new()).unwrap();
    respawned.replace_input_writer_for_test(Box::new(InputRecorder(new_sent)));
    mux.insert_surface_runtime_for_test(respawned);
    handle_command(&mux, client, named(&["enter"]), &writer).unwrap();
    assert_eq!(
        new_input.try_recv().ok(),
        Some(b"\r".to_vec()),
        "the named key after the respawn did not reach the new shell"
    );
    drop(removed);
    mux.shutdown();
}

/// Reads lines from `reader` until the reply to request `id` (stream lines of an attach come in between).
#[cfg(target_os = "macos")]
fn reply_to(reader: &mut BufReader<Box<dyn transport::Stream>>, id: u64) -> Value {
    use std::io::BufRead;
    loop {
        let mut line = String::new();
        assert!(
            reader.read_line(&mut line).unwrap() > 0,
            "the connection closed before reply {id}"
        );
        let value: Value = serde_json::from_str(&line).unwrap();
        if value["id"] == json!(id) {
            return value;
        }
    }
}

/// TYPING FIX 2 (F7): when every core is busy, a default-QoS thread waits for a CPU. The fleet probe measured up to
/// about 25 ms for each wake of a default-QoS key thread with 2 x cores busy threads (about half that, and no wait
/// in the middle of a send, at user-interactive; STATUS 6593). A key crosses three threads of its connection: the
/// `mux-conn` reader, the `mux-control-dispatch` request thread and the `mux-line-out` writer. Once a connection
/// carries the person's keys to a terminal it views, those threads run at QOS_CLASS_USER_INTERACTIVE (Chrome: the
/// thread that carries input runs at the highest priority); automation's connections keep the default.
#[cfg(target_os = "macos")]
#[test]
fn a_connection_that_carries_the_persons_keys_runs_at_user_interactive_qos() {
    use std::io::Write as _;
    let mux = test_mux();
    let surface = mux.new_workspace(Some("typing".into()), Some((80, 24))).unwrap();
    let socket = TestSocket::new("input-qos");
    let listener = transport::listen(&socket.path).unwrap();
    let client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let handler = std::thread::Builder::new()
        .name("mux-conn".into())
        .spawn({
            let mux = mux.clone();
            move || handle_connection(mux, server)
        })
        .unwrap();
    let mut writer = client.try_clone_box().unwrap();
    let mut reader = BufReader::new(client);
    let byte = base64::engine::general_purpose::STANDARD.encode(b"a");
    let requests = [
        json!({"id": 1, "cmd": "attach-surface", "surface": surface.id, "cols": 80, "rows": 24}),
        json!({"id": 2, "cmd": "send", "surface": surface.id, "bytes": byte}),
        json!({"id": 3, "cmd": "send", "surface": surface.id, "bytes": byte}),
    ];
    for request in requests {
        let id = request["id"].as_u64().unwrap();
        writeln!(writer, "{request}").unwrap();
        writer.flush().unwrap();
        let reply = reply_to(&mut reader, id);
        assert!(reply.get("error").is_none_or(Value::is_null), "request {id} failed: {reply}");
    }
    // Each thread recorded its QoS before it read, ran or wrote request 3 (its reply came after that).
    let interactive = libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE as u32;
    for role in ["mux-conn", "mux-control-dispatch", "mux-line-out"] {
        assert_eq!(
            input_qos::observed_thread_qos(role),
            Some(interactive),
            "{role} carried the person's keys at another QoS than user-interactive"
        );
    }
    drop(writer);
    drop(reader);
    handler.join().unwrap();
    mux.shutdown();
}

/// TYPING FIX 2 (F7): automation (a CLI connection that writes to a terminal it does not view) keeps the default QoS,
/// so it never competes with the person's input.
#[cfg(target_os = "macos")]
#[test]
fn an_unattached_senders_connection_keeps_the_default_qos() {
    use std::io::Write as _;
    let mux = test_mux();
    let surface = mux.new_workspace(Some("automation".into()), Some((80, 24))).unwrap();
    let socket = TestSocket::new("input-qos-cli");
    let listener = transport::listen(&socket.path).unwrap();
    let client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let handler = std::thread::spawn({
        let mux = mux.clone();
        move || handle_connection(mux, server)
    });
    let mut writer = client.try_clone_box().unwrap();
    let mut reader = BufReader::new(client);
    let byte = base64::engine::general_purpose::STANDARD.encode(b"a");
    for id in 1..=3u64 {
        let request = json!({"id": id, "cmd": "send", "surface": surface.id, "bytes": byte});
        writeln!(writer, "{request}").unwrap();
        writer.flush().unwrap();
        reply_to(&mut reader, id);
    }
    let interactive = libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE as u32;
    for role in ["mux-control-dispatch", "mux-line-out"] {
        let observed = input_qos::observed_thread_qos(role);
        assert!(observed.is_some(), "{role} recorded no QoS");
        assert_ne!(
            observed,
            Some(interactive),
            "{role} of an automation connection runs at user-interactive"
        );
    }
    drop(writer);
    drop(reader);
    handler.join().unwrap();
    mux.shutdown();
}

/// A client attached to `surface` only through read-only views (`terminal.attach read_only`), as a watcher, an agent
/// observing a terminal or a mirror attaches.
fn read_only_viewer(mux: &Arc<Mux>, surface: SurfaceId) -> (u64, MessageWriter) {
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    let lease =
        mux.control_clients.attach_surface_with_required_lease(client, surface, stream).unwrap();
    mux.control_clients.mark_view_lease_read_only(client, surface, &lease).unwrap();
    mux.control_clients.commit_surface(client, surface, stream_id, None).unwrap();
    (client, writer)
}

/// TYPING FIX 2 (F7 follow-up, lead 2026-11-02): only a client that can type into the terminal (an attach that may
/// own the keyboard, not a read-only view) carries the person's input. A read-only viewer that sends through the
/// legacy `send` or `send-key` (a watcher, an agent observing a terminal) is automation: its connection must not get
/// the person's user-interactive QoS, so it never competes with the person's keys. The app's own attach still does.
#[cfg(unix)]
#[test]
fn a_read_only_viewers_keys_do_not_get_the_persons_priority() {
    let mux = test_mux();
    let (typing, client, writer) = attached_terminal(&mux);
    let (viewer, viewer_writer) = read_only_viewer(&mux, typing.id);
    let named = || Command::SendKey { surface: typing.id, keys: vec!["enter".into()] };
    // The first key finds the terminal the long way, the next ones use the kept terminal.
    for command in [key(typing.id, b'a'), named(), key(typing.id, b'b'), named()] {
        handle_command(&mux, viewer, command, &viewer_writer).unwrap();
    }
    assert!(
        !viewer_writer.input_lane.carries_person_input(),
        "a read-only viewer's keys marked its connection as the person's input"
    );
    handle_command(&mux, client, key(typing.id, b'c'), &writer).unwrap();
    assert!(
        writer.input_lane.carries_person_input(),
        "the typing client's keys did not mark its connection as the person's input"
    );
    mux.shutdown();
}
