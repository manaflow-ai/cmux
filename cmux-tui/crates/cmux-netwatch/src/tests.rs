use super::*;

/// Address and link messages are a change; a new route or neighbour (macOS clones a host
/// route for many new connections) is none.
#[test]
fn only_address_and_link_messages_are_a_change() {
    assert!(is_change_type(libc::RTM_NEWADDR));
    assert!(is_change_type(libc::RTM_DELLINK));
    assert!(!is_change_type(libc::RTM_NEWROUTE));
    assert!(!is_change_type(libc::RTM_NEWNEIGH));
    assert!(imp::is_change(&[]), "an overflowed burst counts as a change");
}

/// The watch opens on Linux without privileges (netlink route groups are readable by any
/// user), so a link on a fleet Linux host has it too.
#[test]
fn the_watch_opens_without_privileges() {
    assert!(imp::open().is_some());
}

/// A burst of messages is one change, called once it settles; the thread ends when its
/// owner is gone.
#[test]
fn a_burst_is_one_change_and_the_thread_ends_with_its_owner() {
    let generation = NetworkWatch::manual();
    let receiver = generation.subscribe();
    // A socketpair stands in for the routing socket: three NEWADDR messages at once.
    let mut fds = [0; 2];
    // SAFETY: socketpair(2) fills two fds this test owns.
    assert_eq!(
        unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
        0
    );
    use std::os::fd::FromRawFd;
    // SAFETY: fresh fds from socketpair, owned once each.
    let (reader, writer) = unsafe {
        (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
    };
    let mut message = [0u8; 16];
    message[4..6].copy_from_slice(&libc::RTM_NEWADDR.to_ne_bytes());
    for _ in 0..3 {
        use std::os::fd::AsRawFd;
        // SAFETY: a valid buffer of the given length.
        let sent =
            unsafe { libc::send(writer.as_raw_fd(), message.as_ptr().cast(), message.len(), 0) };
        assert_eq!(sent, message.len() as isize);
    }
    let (owner, ended) = owner_pipe().expect("a wake pipe");
    let counted = generation;
    // The addresses differ after the burst from before it.
    let mut reads = 0u32;
    let usable = move || {
        reads += 1;
        Some(Usable::from([("en0".to_owned(), IpAddr::from([10, 0, 0, reads as u8]))]))
    };
    let thread = std::thread::spawn(move || {
        run_until(imp::Socket(reader), ended, usable, || counted.signal(), || {});
    });
    std::thread::sleep(SETTLE * 3);
    assert_eq!(*receiver.borrow(), 1, "a burst of three messages is one change");
    drop(owner);
    drop(writer);
    thread.join().unwrap();
}

/// An idle watch never wakes: no message, no wake (cmux-next idle wakeups). It checked for its
/// owner every 2 s (`ALIVE_EVERY`), 0.5 wakes a second in every acpmux daemon for its life,
/// where the watch is a static nobody drops. Its owner's end is now an event: the last
/// `NetworkWatch` dropped closes the wake pipe, and the thread ends at once.
#[test]
fn an_idle_watch_never_wakes_and_ends_when_its_owner_drops() {
    use std::os::fd::FromRawFd;
    use std::sync::atomic::{AtomicU32, Ordering};
    let mut fds = [0; 2];
    // SAFETY: socketpair(2) fills two fds this test owns.
    assert_eq!(
        unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
        0
    );
    // SAFETY: fresh fds from socketpair, owned once each.
    let (reader, writer) = unsafe {
        (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
    };
    let (owner, ended) = owner_pipe().expect("a wake pipe");
    let checks = Arc::new(AtomicU32::new(0));
    let counted = checks.clone();
    let thread = std::thread::spawn(move || {
        run_until(
            imp::Socket(reader),
            ended,
            || None,
            || {},
            || {
                counted.fetch_add(1, Ordering::SeqCst);
            },
        );
    });
    std::thread::sleep(Duration::from_secs(5));
    assert_eq!(checks.load(Ordering::SeqCst), 0, "the idle watch woke with nothing to read");
    let dropped = Instant::now();
    drop(owner);
    thread.join().unwrap();
    assert!(
        dropped.elapsed() < Duration::from_millis(500),
        "it ended {:?} after its owner",
        dropped.elapsed()
    );
    drop(writer);
}

/// A burst that leaves the usable addresses as they were (an address added and removed at
/// once, as a VM bridge did every minute on a busy Mac) is no change; one that leaves them
/// otherwise is.
#[test]
fn a_burst_that_leaves_the_addresses_as_they_were_is_no_change() {
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::sync::Mutex;
    let generation = NetworkWatch::manual();
    let receiver = generation.subscribe();
    let mut fds = [0; 2];
    // SAFETY: socketpair(2) fills two fds this test owns.
    assert_eq!(
        unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
        0
    );
    // SAFETY: fresh fds from socketpair, owned once each.
    let (reader, writer) = unsafe {
        (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
    };
    let send = |kind: u16| {
        let mut message = [0u8; 16];
        message[4..6].copy_from_slice(&kind.to_ne_bytes());
        // SAFETY: a valid buffer of the given length.
        let sent =
            unsafe { libc::send(writer.as_raw_fd(), message.as_ptr().cast(), message.len(), 0) };
        assert_eq!(sent, message.len() as isize);
    };
    let wifi = ("en0".to_owned(), IpAddr::from([192, 168, 1, 20]));
    let now = Arc::new(Mutex::new(Usable::from([wifi])));
    let read = now.clone();
    let (owner, ended) = owner_pipe().expect("a wake pipe");
    let counted = generation;
    let thread = std::thread::spawn(move || {
        run_until(
            imp::Socket(reader),
            ended,
            || Some(read.lock().unwrap().clone()),
            || counted.signal(),
            || {},
        );
    });
    // The bridge's flap: an address added and removed in one burst.
    send(libc::RTM_NEWADDR);
    send(libc::RTM_DELADDR);
    std::thread::sleep(SETTLE * 3);
    assert_eq!(*receiver.borrow(), 0, "an address added and removed again is no change");
    // A real change: Wi-Fi's address is another one.
    *now.lock().unwrap() = Usable::from([("en0".to_owned(), IpAddr::from([10, 1, 0, 7]))]);
    send(libc::RTM_NEWADDR);
    std::thread::sleep(SETTLE * 3);
    assert_eq!(*receiver.borrow(), 1, "a new address is a change");
    drop(owner);
    drop(writer);
    thread.join().unwrap();
}
