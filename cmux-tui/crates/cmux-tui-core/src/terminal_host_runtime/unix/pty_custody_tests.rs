use super::*;

#[test]
fn pty_custody_payload_round_trips_and_rejects_bad_bounds() {
    let payload = encode_pty_custody(41, 41);
    assert_eq!(payload.len(), PTY_CUSTODY_PAYLOAD_LEN);
    assert_eq!(decode_pty_custody(&payload).unwrap(), (41, 41));
    assert!(decode_pty_custody(&payload[..9]).is_err(), "truncated");
    let mut long = payload.clone();
    long.push(0);
    assert!(decode_pty_custody(&long).is_err(), "trailing byte");
    let mut version = payload;
    version[0] = 2;
    assert!(decode_pty_custody(&version).is_err(), "unknown version");
    assert!(decode_pty_custody(&encode_pty_custody(0, 41)).is_err(), "no pid");
    assert!(decode_pty_custody(&encode_pty_custody(41, 0)).is_err(), "no session");
}

#[test]
fn pty_custody_descriptor_crosses_a_socket_pair() {
    let (left, right) = UnixStream::pair().unwrap();
    let (pipe_read, mut pipe_write) = std::io::pipe().unwrap();
    let mut custody = Frame::new(MessageKind::PtyCustody, encode_pty_custody(7, 7));
    custody.request_id = CUSTODY_REQUEST_ID;
    let bytes = crate::terminal_host_protocol::encode_frame(&custody).unwrap();
    send_with_descriptor(&left, &bytes, pipe_read.as_raw_fd()).unwrap();
    drop(pipe_read);
    let (received, fd) = receive_with_descriptor(&right, PTY_CUSTODY_FRAME_LEN).unwrap();
    assert_eq!(received, bytes);
    let fd = fd.expect("descriptor");
    // SAFETY: F_GETFD on the received, owned descriptor.
    assert_ne!(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
    pipe_write.write_all(b"x").unwrap();
    let mut byte = [0u8; 1];
    File::from(fd).read_exact(&mut byte).unwrap();
    assert_eq!(&byte, b"x");
}
