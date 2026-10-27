//! The peer executable is read only while the peer key or token still
//! names the same process (review 2 finding 3): a stale pid version, as a
//! process that reused the pid would have, reads nothing.

use super::peer_executable;
use crate::platform::transport::Stream;

#[test]
fn peer_executable_needs_the_peers_own_pid_version() {
    let (ours, _theirs) = std::os::unix::net::UnixStream::pair().unwrap();
    let key = Stream::peer_process_key(&ours);
    let token = Stream::peer_token(&ours);
    let own = std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
    let read = peer_executable(key.as_deref(), token.as_ref()).expect("our own executable");
    assert_eq!(std::fs::canonicalize(read).unwrap(), own);
    let key = key.unwrap();
    let (pid, _) = key.split_once('.').unwrap();
    let stale_key = format!("{pid}.1");
    let stale_token = token.map(|token| token.with_pid_version_for_test(1));
    assert_eq!(peer_executable(Some(&stale_key), stale_token.as_ref()), None);
}
