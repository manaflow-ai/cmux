//! A hidden terminal's reader thread (it reads and parses) runs at utility
//! after its next byte and at the echo class after a byte once shown, with
//! no wake of its own for either change. A hosted terminal's mirror threads
//! do the same after their next frame, and every new host connection tells
//! the host the current class.

use std::time::{Duration, Instant};

use cmux_threads::{QosChange, ThreadInfo, ThreadQos};

use super::*;
use crate::mux::Mux;

fn find_row(name: &str) -> Option<ThreadInfo> {
    cmux_threads::snapshot().into_iter().find(|row| row.name == name)
}

fn reader_row(name: &str) -> ThreadInfo {
    find_row(name).unwrap_or_else(|| panic!("no registry row {name}"))
}

/// The thread's start state once its spawn applied or refused its own
/// class: the runner's, so a raised nice (an unprivileged Linux runner under
/// `nice -n 10`) starts with that refusal counted.
fn wait_started(name: &str) -> ThreadInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(row) = find_row(name)
            && (row.effective.is_some() || row.refused_changes > 0)
        {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never started: {:?}", find_row(name));
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Waits until the thread acted on a request for `qos` after `before`: it
/// runs at it, or (an unprivileged Linux thread that could never come back
/// from a raised nice) it refused it once more.
fn wait_acted(name: &str, qos: ThreadQos, before: &ThreadInfo) -> ThreadInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let row = reader_row(name);
        if row.effective == Some(qos) || row.refused_changes > before.refused_changes {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never applied {qos:?}: {row:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
fn wait_for_text(surface: &Surface, needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = surface.with_terminal(|terminal| terminal.plain_text()).unwrap().unwrap();
        if text.contains(needle) {
            return;
        }
        assert!(Instant::now() < deadline, "the PTY never echoed {needle:?}: {text:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn demotion() -> QosChange {
    if cmux_threads::reversible(HIDDEN_TERMINAL_QOS) {
        QosChange::Applied
    } else {
        QosChange::Refused
    }
}

/// The row after the thread acted on the hide: at utility, or the
/// demotion refused and counted once.
fn assert_hidden(row: &ThreadInfo, before: &ThreadInfo) {
    assert_eq!(row.desired, HIDDEN_TERMINAL_QOS, "{row:?}");
    if demotion() == QosChange::Applied {
        assert_eq!(row.effective, Some(HIDDEN_TERMINAL_QOS), "{row:?}");
        #[cfg(target_vendor = "apple")]
        assert_eq!(row.live, cmux_threads::LiveQos::Class(HIDDEN_TERMINAL_QOS), "{row:?}");
    } else {
        assert_eq!(row.refused_changes, before.refused_changes + 1, "{row:?}");
    }
}

/// The row after the thread acted on the show: back at the echo class
/// when the demotion was applied (a refused one never left it).
fn assert_shown(row: &ThreadInfo) {
    assert_eq!(row.desired, ThreadQos::UserInteractive, "{row:?}");
    if demotion() == QosChange::Applied {
        assert_eq!(row.effective, Some(ThreadQos::UserInteractive), "{row:?}");
        #[cfg(target_vendor = "apple")]
        assert_eq!(row.live, cmux_threads::LiveQos::Class(ThreadQos::UserInteractive), "{row:?}");
    }
}

#[cfg(unix)]
#[test]
fn a_hidden_terminals_reader_applies_utility_after_one_byte_and_returns_when_shown() {
    // The reader's progress publication writes sqlite (surface/directory.rs,
    // a known MQ-13 site): record it, as store_lock_blocking_tests does.
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let options = SurfaceOptions { command: Some(vec!["cat".into()]), ..SurfaceOptions::default() };
    let mux = Mux::new(format!("thread-qos-{}-{nanos}", std::process::id()), options);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let name = format!("surface-{}-reader", surface.id);
    surface.write_bytes(b"a").unwrap();
    // The reader parsed the echo and waits again: from here only a byte wakes it.
    wait_for_text(&surface, "a");
    let start = wait_started(&name);
    assert_eq!(start.desired, ThreadQos::UserInteractive);

    surface.set_threads_shown(false);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility));
    // The request alone wakes nothing: the idle reader has not acted on it.
    let idle = reader_row(&name);
    assert_eq!(idle.desired, ThreadQos::Utility);
    assert_eq!((idle.effective, idle.refused_changes), (start.effective, start.refused_changes));

    surface.write_bytes(b"b").unwrap();
    let hidden = wait_acted(&name, ThreadQos::Utility, &start);
    assert_hidden(&hidden, &start);

    surface.set_threads_shown(true);
    surface.write_bytes(b"c").unwrap();
    if demotion() == QosChange::Applied {
        assert_shown(&wait_acted(&name, ThreadQos::UserInteractive, &hidden));
    }
    assert_eq!(reader_row(&name).desired, ThreadQos::UserInteractive);
    mux.shutdown();
}

#[test]
fn an_unchanged_class_is_no_request() {
    let mux = Mux::new_for_test("thread-qos-unchanged", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    assert!(!surface.request_threads_shown(true), "a terminal starts shown");
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
    assert!(surface.request_threads_shown(false));
    assert!(!surface.request_threads_shown(false));
    assert_eq!(surface.thread_qos(), Some(HIDDEN_TERMINAL_QOS));
}

#[cfg(unix)]
mod hosted {
    use std::os::unix::net::UnixStream;

    use super::*;
    use crate::terminal_host_protocol::{
        Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame, write_frame,
    };

    /// A hosted terminal `id` on a fake host whose record takes
    /// `SetThreadQos`, and the host's end of the connection. `adopted`: a
    /// new daemon adopting a host that is already running.
    fn hosted_terminal(mux: &Arc<Mux>, id: SurfaceId, adopted: bool) -> (Arc<Surface>, UnixStream) {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (mut attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
        attachment.record.supports_thread_qos = true;
        let terminal_id = attachment.record.terminal_id.clone();
        attachment.record.workspace_key = workspace.key.clone();
        mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
        let surface = Surface::spawn_hosted(
            id,
            SurfaceOptions::default(),
            Arc::downgrade(mux),
            HostedSurfaceLaunch {
                adopted,
                attachment,
                kitty_reservation: None,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: None,
                resource_identity: None,
            },
        )
        .unwrap();
        // A safety bound for a late thread under full-suite load, not a
        // timing assertion.
        host.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        host.set_write_timeout(Some(Duration::from_secs(30))).unwrap();
        (surface, host)
    }

    /// The class of the next `SetThreadQos` the host reads.
    fn next_thread_qos(host: &mut UnixStream) -> ThreadQos {
        loop {
            let frame = read_frame(host, MAX_FRAME_PAYLOAD).unwrap().expect("the owner hung up");
            if frame.kind == MessageKind::SetThreadQos {
                assert_eq!(frame.request_id, 0, "fire and forget");
                let [raw] = frame.payload[..] else { panic!("payload {:?}", frame.payload) };
                return ThreadQos::ALL[usize::from(raw)];
            }
        }
    }

    fn write_output(host: &mut UnixStream, sequence: u64, bytes: &[u8]) {
        let mut output = Frame::new(MessageKind::Output, bytes.to_vec());
        output.sequence = sequence;
        write_frame(host, &output).unwrap();
    }

    /// A host keeps the class an earlier owner set. A new daemon adopting
    /// the host starts its terminal shown, so its first connection must
    /// raise the host again, not only lower it.
    #[test]
    fn every_new_host_connection_gets_the_current_class() {
        let mux = Mux::new_for_test("thread-qos-host-connection", SurfaceOptions::default());
        let (old_owner, mut old_host) = hosted_terminal(&mux, 236_101, false);
        assert_eq!(next_thread_qos(&mut old_host), ThreadQos::UserInteractive);
        old_owner.set_threads_shown(false);
        assert_eq!(next_thread_qos(&mut old_host), ThreadQos::Utility, "the host is demoted");

        // A new daemon adopts a host (here a fake one, like the one above
        // still at utility): its fresh terminal is shown and says so first.
        let (adopter, mut host) = hosted_terminal(&mux, 236_102, true);
        assert_eq!(adopter.thread_qos(), Some(ThreadQos::UserInteractive));
        assert_eq!(next_thread_qos(&mut host), ThreadQos::UserInteractive, "raised on connect");

        adopter.set_threads_shown(false);
        assert_eq!(next_thread_qos(&mut host), ThreadQos::Utility);
        adopter.set_threads_shown(true);
        assert_eq!(next_thread_qos(&mut host), ThreadQos::UserInteractive);
    }

    /// The hosted mirror's frame reader and reader follow the class after
    /// their next frame, as the local reader does after its next byte.
    #[test]
    fn a_hidden_hosted_terminals_mirror_threads_apply_utility_after_one_frame() {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
        let mux = Mux::new_for_test("thread-qos-hosted-mirror", SurfaceOptions::default());
        let id = 236_103;
        let (surface, mut host) = hosted_terminal(&mux, id, false);
        assert_eq!(next_thread_qos(&mut host), ThreadQos::UserInteractive);
        let names = [format!("surface-{id}-host"), format!("surface-{id}-host-frames")];
        let start = names.clone().map(|name| wait_started(&name));

        surface.set_threads_shown(false);
        assert_eq!(next_thread_qos(&mut host), ThreadQos::Utility, "the host is told");
        write_output(&mut host, 1, b"a");
        let hidden = std::array::from_fn::<_, 2, _>(|index| {
            let row = wait_acted(&names[index], ThreadQos::Utility, &start[index]);
            assert_hidden(&row, &start[index]);
            row
        });

        surface.set_threads_shown(true);
        assert_eq!(next_thread_qos(&mut host), ThreadQos::UserInteractive);
        write_output(&mut host, 2, b"b");
        if demotion() == QosChange::Applied {
            for (name, before) in names.iter().zip(&hidden) {
                assert_shown(&wait_acted(name, ThreadQos::UserInteractive, before));
            }
        }
    }
}
