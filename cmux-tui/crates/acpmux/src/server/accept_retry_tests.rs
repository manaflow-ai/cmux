use super::{accept_ends_listener, accept_retry_delay};
use std::io::{Error, ErrorKind};
use std::time::Duration;

#[test]
fn running_out_of_descriptors_pauses_before_the_next_accept() {
    // The queued connection stays queued on EMFILE, so an immediate retry spins a core.
    #[cfg(unix)]
    assert!(accept_retry_delay(&Error::from_raw_os_error(libc::EMFILE)) > Duration::ZERO);
    #[cfg(unix)]
    assert!(accept_retry_delay(&Error::from_raw_os_error(libc::ENFILE)) > Duration::ZERO);
    assert!(accept_retry_delay(&Error::other("no buffers")) > Duration::ZERO);
}

#[test]
fn a_connection_that_died_in_the_queue_retries_at_once() {
    assert_eq!(accept_retry_delay(&Error::from(ErrorKind::ConnectionAborted)), Duration::ZERO);
    assert_eq!(accept_retry_delay(&Error::from(ErrorKind::ConnectionReset)), Duration::ZERO);
    assert_eq!(accept_retry_delay(&Error::from(ErrorKind::Interrupted)), Duration::ZERO);
}

#[test]
fn only_a_listener_that_is_gone_ends_the_accept_loop() {
    // A closed tailnet listener reports end of stream; a closed fd reports EBADF.
    assert!(accept_ends_listener(&Error::from(ErrorKind::UnexpectedEof)));
    #[cfg(unix)]
    assert!(accept_ends_listener(&Error::from_raw_os_error(libc::EBADF)));
    #[cfg(unix)]
    assert!(accept_ends_listener(&Error::from_raw_os_error(libc::EINVAL)));
    // Descriptor exhaustion, a dropped connection or one record that lost its fd pass.
    #[cfg(unix)]
    assert!(!accept_ends_listener(&Error::from_raw_os_error(libc::EMFILE)));
    #[cfg(unix)]
    assert!(!accept_ends_listener(&Error::from_raw_os_error(libc::ENFILE)));
    assert!(!accept_ends_listener(&Error::from(ErrorKind::ConnectionAborted)));
    assert!(!accept_ends_listener(&Error::other("accept failed")));
}
