use super::*;

#[cfg(target_os = "linux")]
#[test]
fn linux_peer_credentials_report_the_kernel_uid() {
    use std::os::unix::net::UnixStream;

    let (client, server) = UnixStream::pair().unwrap();
    assert_eq!(peer_uid(&server).unwrap(), unsafe { libc::geteuid() });
    drop(client);
}
