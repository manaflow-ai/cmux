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
    let owner = Arc::new(());
    let alive = Arc::downgrade(&owner);
    let counted = generation;
    let thread = std::thread::spawn(move || {
        run(imp::Socket(reader), || alive.strong_count() > 0, || counted.signal());
    });
    std::thread::sleep(SETTLE * 3);
    assert_eq!(*receiver.borrow(), 1, "a burst of three messages is one change");
    drop(owner);
    drop(writer);
    thread.join().unwrap();
}
