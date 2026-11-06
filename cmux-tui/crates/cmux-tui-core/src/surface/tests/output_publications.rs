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
use crate::workspace_registry::TerminalLifecycle;

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
fn hold_registry(mux: &Arc<Mux>) -> (SyncSender<()>, std::thread::JoinHandle<()>) {
    let (entered, held) = sync_channel(1);
    let (release, released) = sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, released))
    };
    held.recv_timeout(Duration::from_secs(10)).expect("the holder took the workspace registry");
    (release, holder)
}

/// A hosted terminal on a fake host connection (the host end is the second value). It has a public terminal id:
/// its publications are resource commits, as every terminal's are in the daemon.
fn hosted_surface(name: &str) -> (Arc<Mux>, Arc<Surface>, std::os::unix::net::UnixStream) {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
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
    (mux, surface, host)
}

/// Writes `text` as the host's Output frame `sequence`; returns when it was written.
fn send_output(host: &mut std::os::unix::net::UnixStream, sequence: u64, text: &str) -> Instant {
    let mut output = Frame::new(MessageKind::Output, text.as_bytes().to_vec());
    output.sequence = sequence;
    crate::terminal_host_protocol::write_frame(host, &output).unwrap();
    Instant::now()
}

#[test]
fn hosted_output_reaches_the_terminal_while_the_registry_is_held() {
    let (mux, surface, mut host) = hosted_surface("output-publications-hosted");

    let (release, holder) = hold_registry(&mux);
    let first = send_output(&mut host, 1, "first-output ");
    let first_shown = shown_after(&surface, "first-output", first);
    let echo = send_output(&mut host, 2, "key-echo");
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

/// #35765 review: a program's OSC 7501 alert posts after the notifications of the output before it, as when the
/// reader published inline. The publication job that commits the alert's record ran ahead of the notification job
/// an earlier frame queued, and it took and posted the alert itself, so a later alert could post first.
#[test]
fn a_programs_alert_posts_after_the_notifications_of_earlier_output() {
    let (mux, surface, mut host) = hosted_surface("output-publications-order");
    let titles = || {
        let mut titles = mux
            .resource_notifications(16)
            .into_iter()
            .map(|notification| notification.title)
            .collect::<Vec<_>>();
        titles.reverse();
        titles
    };

    let (release, holder) = hold_registry(&mux);
    let first = send_output(&mut host, 1, "\x1b]9;first-note\x07first-frame ");
    let first_shown = shown_after(&surface, "first-frame", first);
    // A terminal's notifications are at least 1 s apart (its rate limit): the alert must pass it.
    std::thread::sleep(Duration::from_millis(1_100));
    let second = send_output(
        &mut host,
        2,
        "\x1b]7501;state=blocked:kind=question:app=make\x1b\\second-frame",
    );
    let second_shown = shown_after(&surface, "second-frame", second);
    release.send(()).unwrap();
    holder.join().unwrap();
    assert!(
        first_shown.is_some() && second_shown.is_some(),
        "an output frame never reached the terminal"
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    while titles().len() < 2 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        titles(),
        ["first-note", "make asks a question"],
        "notifications out of output order"
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

/// #35765 review 2 (should-fix 1): a hosted terminal whose host connection is lost commits the directory its shell
/// reported last before it becomes adopting, as the reader did when it published inline before it read the end of the
/// stream. A publication still queued when the reader commits the loss commits nothing (an adopting terminal keeps it
/// pending, and a host that is then declared dead ends it), so the dead tab and its respawn kept the old directory.
#[test]
fn a_host_loss_commits_the_directory_the_shell_reported_last() {
    const TERMINAL: &str = "00000000000040008000000000357652";
    const INCARNATION: &str = "10000000000040008000000000357652";
    let mux = Mux::new_for_test("output-publications-host-loss", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("host-loss".into()),
            Some("018f6e21-7b70-7e70-8000-000000357652".into()),
            None,
        )
        .unwrap();
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let terminal = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(TERMINAL)
        .unwrap()
        .expect("the seeded terminal's public id");
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    attachment.record.terminal_id = TERMINAL.into();
    attachment.record.incarnation = INCARNATION.into();
    attachment.record.workspace_key = workspace.key;
    // A live reader for the running terminal, as adoption makes one: the terminal is adopting while its reader
    // starts, then running.
    mux.commit_terminal_lifecycle_for_test(TERMINAL, TerminalLifecycle::Adopting, INCARNATION)
        .unwrap();
    let surface = Surface::spawn_hosted(
        mux.next_surface_id_for_test(),
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            adopted: false,
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: Some(terminal),
            resource_identity: None,
        },
    )
    .unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("the live runtime's public id");
    mux.install_live_terminal_runtime_for_test(&terminal, surface.clone()).unwrap();
    surface.release_pending_terminal_host_binding();
    mux.commit_terminal_lifecycle_for_test(TERMINAL, TerminalLifecycle::Running, INCARNATION)
        .unwrap();
    host.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
    let lifecycle = || {
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .expect("the seeded terminal's record")
            .lifecycle
    };
    assert_eq!(lifecycle(), TerminalLifecycle::Running);
    let dir = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir_text = dir.to_string_lossy().into_owned();
    {
        // The shell's last report reaches the reader, which queues its publication; then the host connection is lost.
        let _held = mux.hold_terminal_publisher_for_test();
        let report =
            send_output(&mut host, 1, &format!("\x1b]7;file://localhost{dir_text}\x07in-dir"));
        assert!(
            shown_after(&surface, "in-dir", report).is_some(),
            "the report never reached the terminal"
        );
        drop(host);
        let deadline = Instant::now() + Duration::from_secs(10);
        while lifecycle() == TerminalLifecycle::Running {
            assert!(
                Instant::now() < deadline,
                "the reader did not handle the lost host connection"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(10)),
        "the publisher did not finish"
    );
    assert_eq!(
        surface.presented_directory().as_deref(),
        Some(dir_text.as_str()),
        "the terminal whose host was lost kept the directory from before its shell's last report"
    );
}
