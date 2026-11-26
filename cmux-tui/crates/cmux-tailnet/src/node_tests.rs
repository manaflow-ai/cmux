use super::*;
use std::io::Write;
use std::os::fd::IntoRawFd;

#[test]
fn invalid_configuration_never_reports_secret_values() {
    let error = cstring("private-auth-key\0suffix").unwrap_err().to_string();
    assert_eq!(error, "NUL byte in node configuration");
    assert!(!error.contains("private-auth-key"));
}

/// libtailscale tears its listener down when a read on its end of the socketpair returns
/// EOF. A process spawned while the listener is open holds a copy of our end; dropping the
/// listener must still end libtailscale's side.
#[test]
fn dropping_a_listener_ends_libtailscales_side_while_a_child_holds_a_copy() {
    use std::io::Read;
    let (ours, mut theirs) = UnixStream::pair().unwrap();
    let listener = Listener { fd: ours.into_raw_fd() };
    let inherited = unsafe { libc::dup(listener.fd) };
    assert!(inherited >= 0, "dup: {}", std::io::Error::last_os_error());
    drop(listener);
    theirs.set_nonblocking(true).unwrap();
    let mut byte = [0_u8; 1];
    assert_eq!(theirs.read(&mut byte).unwrap(), 0, "libtailscale's side must read EOF");
    unsafe { libc::close(inherited) };
}

#[test]
fn accept_readiness_does_not_block_and_detects_truncated_close() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    let mut listener = Listener { fd: reader.into_raw_fd() };
    assert!(listener.try_accept().unwrap().is_none());
    writer.write_all(b"partial").unwrap();
    assert!(listener.try_accept().unwrap().is_none());
    drop(writer);
    assert_eq!(listener.try_accept().unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
}

#[test]
fn a_node_configs_debug_never_shows_its_auth_key() {
    let mut config = NodeConfig::new("/tmp/state", "mac");
    config.auth_key = Some("tskey-auth-kSECRETVALUE-1234".into());
    config.control_url = Some("https://hs.example.com".into());
    config.advertise_tags = vec!["tag:cmux".into()];
    let shown = format!("{config:?} {config:#?}");
    assert!(!shown.contains("SECRETVALUE"), "{shown}");
    assert!(shown.contains("<redacted>") && shown.contains("tag:cmux"), "{shown}");
}
