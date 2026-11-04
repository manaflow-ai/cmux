//! A terminal's output reader applies the next output frame while a durable publication of its earlier output
//! waits for the workspace registry (#35413, L6 typing echo stall).
//!
//! A terminal's output can change durable facts: the shell's directory (OSC 7), progress and program status
//! (OSC 9;4, OSC 7501), the command and prompt facts, and "last output", which it pushes at most every 5 s while
//! the terminal prints. Each is a resource commit under the workspace registry lock. The reader made them itself,
//! between two output frames. Under the L6 load that lock waited up to 1.5 s, and the next frame (the echo of a
//! key the person typed) waited behind it: in the s17d diagnostic rounds every echo gap over 20 ms (16, to
//! 501 ms) began inside one of those commits, with the input lane on and off.
//!
//! Here another thread holds the registry, as a long commit does under load. The terminal's first output makes
//! a publication due (its first "last output" fact and its launch directory). The next frame must still reach the
//! terminal at once.

use super::*;

/// The most a frame may take to reach the terminal while the registry is held. Generous for a loaded runner:
/// the reader that published inline did not apply the frame at all until the registry was free.
const APPLIED_WITHIN: Duration = Duration::from_secs(2);

/// How long after `since` the terminal's screen first showed `text`, or `None` when it did not within
/// [`APPLIED_WITHIN`].
fn shown_after(surface: &Surface, text: &str, since: Instant) -> Option<Duration> {
    loop {
        let screen = surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        if screen.contains(text) {
            return Some(since.elapsed());
        }
        if since.elapsed() >= APPLIED_WITHIN {
            return None;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// Holds `mux`'s workspace registry on another thread until the returned sender fires (or drops).
fn hold_registry(mux: &Arc<Mux>) -> (std::sync::mpsc::SyncSender<()>, std::thread::JoinHandle<()>) {
    let (entered, held) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, released))
    };
    held.recv_timeout(Duration::from_secs(10)).expect("the holder took the workspace registry");
    (release, holder)
}

#[test]
fn hosted_output_reaches_the_terminal_while_the_registry_is_held() {
    let mux = Mux::new_for_test("output-publications-hosted", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    // A public terminal id: its publications are resource commits, as every terminal's are in the daemon.
    let surface = Surface::spawn_hosted(
        1,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            adopted: false,
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: Some(TerminalPublicId::random().unwrap()),
            resource_identity: None,
        },
    )
    .unwrap();
    host.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
    let send = |host: &mut std::os::unix::net::UnixStream, sequence: u64, text: &str| {
        let mut output = Frame::new(MessageKind::Output, text.as_bytes().to_vec());
        output.sequence = sequence;
        crate::terminal_host_protocol::write_frame(host, &output).unwrap();
        Instant::now()
    };

    let (release, holder) = hold_registry(&mux);
    let first = send(&mut host, 1, "first-output ");
    let first_shown = shown_after(&surface, "first-output", first);
    let echo = send(&mut host, 2, "key-echo");
    let echo_shown = shown_after(&surface, "key-echo", echo);
    release.send(()).unwrap();
    holder.join().unwrap();

    assert!(first_shown.is_some(), "the first output frame never reached the terminal");
    assert!(
        echo_shown.is_some(),
        "the next output frame did not reach the terminal within {APPLIED_WITHIN:?} while another thread held the \
         workspace registry: the reader waited in the durable publication of the first frame"
    );
}

/// The same for a terminal the daemon runs on a local PTY (`local_output.rs`).
#[test]
fn local_output_reaches_the_terminal_while_the_registry_is_held() {
    let mux = Mux::new_for_test("output-publications-local", SurfaceOptions::default());
    // The program prints only when a line arrives, so the test decides when each output frame comes.
    let script =
        "stty -echo; read first; printf 'first-output '; read echo; printf key-echo; sleep 30";
    let surface = Surface::spawn(
        1,
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .unwrap();
    assert!(surface.terminal_public_id().is_some(), "a local terminal has a public id");

    let (release, holder) = hold_registry(&mux);
    let first = Instant::now();
    surface.write_bytes(b"1\n").unwrap();
    let first_shown = shown_after(&surface, "first-output", first);
    let echo = Instant::now();
    surface.write_bytes(b"2\n").unwrap();
    let echo_shown = shown_after(&surface, "key-echo", echo);
    release.send(()).unwrap();
    holder.join().unwrap();
    surface.kill();

    assert!(first_shown.is_some(), "the first output never reached the terminal");
    assert!(
        echo_shown.is_some(),
        "the next output did not reach the terminal within {APPLIED_WITHIN:?} while another thread held the \
         workspace registry: the reader waited in the durable publication of the first output"
    );
}
