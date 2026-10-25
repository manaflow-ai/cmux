//! The macOS close-on-exec race (reviews 1 and 2 of pl-holder-11): the
//! daemon receives a terminal's PTY master and ring segment over the holder
//! link, and on macOS they stay inheritable from the `recvmsg` until the
//! `fcntl` after it. A child another daemon thread spawns in that window
//! must inherit neither: every daemon spawn goes through
//! `cmux_process::Command` (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The child's open
//! descriptors are read from the system (`proc_pidinfo` / `/proc`), not
//! reported by the child.

#![cfg(unix)]

#[path = "../../cmux-process/tests/support/open_descriptors.rs"]
mod support;

/// One module name in every spawn test, so a fleet step can select them all
/// (`--arg test --arg daemon_spawn::`).
mod daemon_spawn {
    use super::support::open_descriptors;
    use cmux_holder::wire::{self, Kind, Reader};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::time::Duration;

    #[derive(Clone, Copy)]
    enum Spawner {
        /// The daemon's spawn: `cmux_process::Command`.
        Helper,
        /// `std::process::Command`, the spawn the daemon used before.
        Std,
    }

    /// The child: a shell that says `ready` once it runs its script (its
    /// program is loaded: the dynamic loader opens libc on a descriptor of
    /// its own while it starts, which a read right after the spawn can see,
    /// 3 of 3,000 spawns on Linux) and then waits on its stdin.
    const CHILD: [&str; 3] = ["/bin/sh", "-c", "echo ready; read line; exit 0"];

    /// Spawn a child, wait for its `ready`, read its open descriptors, end
    /// it (closing its stdin). The child's 0 and 1 are the two pipes.
    fn child_descriptors(spawner: Spawner) -> Vec<i32> {
        use std::io::BufRead;
        match spawner {
            Spawner::Helper => {
                let mut child = cmux_process::Command::new(CHILD[0])
                    .args(&CHILD[1..])
                    .stdin(cmux_process::Stdio::piped())
                    .stdout(cmux_process::Stdio::piped())
                    .spawn()
                    .unwrap();
                let mut line = String::new();
                std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
                assert_eq!(line, "ready\n");
                let open = open_descriptors(child.id()).unwrap();
                assert!(child.wait().unwrap().success());
                open
            }
            Spawner::Std => {
                #[allow(clippy::disallowed_methods)] // the control: the old spawn
                let mut child = std::process::Command::new(CHILD[0])
                    .args(&CHILD[1..])
                    .stdin(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped())
                    .spawn()
                    .unwrap();
                let mut line = String::new();
                std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
                assert_eq!(line, "ready\n");
                let open = open_descriptors(child.id()).unwrap();
                drop(child.stdin.take());
                assert!(child.wait().unwrap().success());
                open
            }
        }
    }

    /// A SPAWNED frame with a ring, carrying two descriptors (stand-ins for a
    /// PTY master and a ring segment), sent on `link`.
    fn send_spawned(link: &UnixStream, chan: u32) -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        // The sender's copies stand for the holder's (another process): on
        // Linux they are made close-on-exec atomically, as every descriptor the
        // daemon opens there, so only the received copies are under test. macOS
        // has no pipe2; there CLOEXEC_DEFAULT keeps them from a helper child.
        #[cfg(target_os = "linux")]
        // SAFETY: pipe2 fills two descriptors.
        assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
        #[cfg(not(target_os = "linux"))]
        // SAFETY: pipe fills two descriptors.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: two new descriptors the test owns.
        let ends = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        let payload = 1234i32.to_le_bytes();
        let frame = wire::encode_with_fds(Kind::Spawned, wire::FLAG_RING, chan, &payload, 2);
        wire::send_all(link.as_raw_fd(), &frame, &[ends.0.as_raw_fd(), ends.1.as_raw_fd()])
            .unwrap();
        ends
    }

    /// Receive one SPAWNED frame and, inside the window between its `recvmsg`
    /// and the close-on-exec `fcntl`, have another thread spawn a child: the
    /// numbers the frame's descriptors got here, and the child's descriptors.
    fn spawn_inside_the_window(spawner: Spawner) -> (Vec<i32>, Vec<i32>) {
        let (sender, receiver) = UnixStream::pair().unwrap();
        let _sent = send_spawned(&sender, 1);
        let (window_open, in_window): (Sender<Vec<i32>>, Receiver<Vec<i32>>) = channel();
        let (spawned, window_close): (Sender<Vec<i32>>, Receiver<Vec<i32>>) = channel();
        let spawning = std::thread::spawn(move || {
            let received = in_window.recv().unwrap();
            spawned.send(child_descriptors(spawner)).unwrap();
            received
        });
        let mut reader = Reader::default();
        let mut child = Vec::new();
        reader
            .fill_with(receiver.as_raw_fd(), |fds| {
                window_open.send(fds.iter().map(AsRawFd::as_raw_fd).collect()).unwrap();
                // Held open until the other thread's child runs its program.
                child = window_close
                    .recv_timeout(Duration::from_secs(30))
                    .expect("the spawn never ended");
            })
            .unwrap();
        let received = spawning.join().unwrap();
        let frame = reader.next_frame().unwrap().expect("the SPAWNED frame");
        assert_eq!(frame.fds.len(), 2, "the frame brought its master and segment");
        assert_eq!(received.len(), 2, "the window saw both descriptors");
        (received, child)
    }

    /// What a helper child has with no frame arriving: 0-2 on macOS
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`). On Linux also any descriptor the test
    /// process itself inherited without close-on-exec (the std path passes
    /// those; none is a received one).
    fn baseline() -> Vec<i32> {
        let open = child_descriptors(Spawner::Helper);
        if cfg!(target_vendor = "apple") {
            assert_eq!(open, [0, 1, 2], "a macOS helper child has more than 0-2");
        }
        open
    }

    /// The fix: a child the daemon spawns while a frame's descriptors are still
    /// inheritable inherits none of them (macOS: it has 0-2 only).
    #[test]
    fn a_child_spawned_while_a_frames_descriptors_arrive_inherits_none_of_them() {
        let baseline = baseline();
        let (received, child) = spawn_inside_the_window(Spawner::Helper);
        assert!(
            received.iter().all(|fd| !child.contains(fd)),
            "the child inherited received descriptors {received:?}: it has {child:?}"
        );
        assert_eq!(child, baseline, "the child has more than a child with no frame arriving");
    }

    /// The control (macOS): std's spawn in the same window inherits both
    /// descriptors, so the test above can see the leak it guards against. On
    /// Linux the kernel made them close-on-exec at the `recvmsg`.
    #[test]
    fn a_std_child_spawned_in_the_window_inherits_the_frames_descriptors_on_macos() {
        let (received, child) = spawn_inside_the_window(Spawner::Std);
        let inherited: Vec<i32> =
            received.iter().copied().filter(|fd| child.contains(fd)).collect();
        if cfg!(target_vendor = "apple") {
            assert_eq!(inherited, received, "std's child did not inherit them: {child:?}");
        } else {
            assert!(inherited.is_empty(), "MSG_CMSG_CLOEXEC did not apply: {child:?}");
        }
    }

    /// Without the barrier: one thread receives SPAWNED frames in a loop (the
    /// sender keeps them coming) while this thread spawns children through the
    /// helper; every child has only what a child with no frame arriving has
    /// (macOS: 0-2).
    #[test]
    fn children_spawned_while_frames_keep_arriving_get_only_descriptors_0_to_2() {
        const CHILDREN: usize = 200;
        let baseline = baseline();
        let (sender, receiver) = UnixStream::pair().unwrap();
        let sending_done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop = sending_done.clone();
        let sending = std::thread::spawn(move || {
            let mut chan = 0;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                chan += 1;
                // Each pair closes here once sent: the receiver holds its copies.
                drop(send_spawned(&sender, chan));
            }
            chan
        });
        let receiving = std::thread::spawn(move || {
            let mut reader = Reader::default();
            let mut frames = 0u32;
            // Until the sender's end closes.
            while reader.fill(receiver.as_raw_fd()).unwrap() {
                while let Some(frame) = reader.next_frame().unwrap() {
                    assert_eq!(frame.fds.len(), 2);
                    frames += 1;
                }
            }
            frames
        });
        for child in 0..CHILDREN {
            let open = child_descriptors(Spawner::Helper);
            assert_eq!(open, baseline, "child {child} inherited descriptors");
        }
        sending_done.store(true, std::sync::atomic::Ordering::Relaxed);
        let sent = sending.join().unwrap();
        let received = receiving.join().unwrap();
        assert_eq!(received, sent, "every frame arrived");
        assert!(
            sent >= CHILDREN as u32,
            "only {sent} frames arrived while {CHILDREN} children ran"
        );
    }
}
