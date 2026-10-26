//! The holder link (`cmux_holder::wire`, CMHX frames between the daemon and
//! `cmux-holder`) and the payload decoders on it: `wire::Reader` splits what
//! a real socket delivers into frames, `SpawnRequest::decode` reads a spawn,
//! `parse_version_line` reads the holder's `--version` answer. A holder from
//! another build, or a process that took over the socket path, can send any
//! bytes.
//!
//! The input goes through a socketpair in pieces, so `Reader::fill` runs its
//! real `recvmsg` path and frames arrive split across reads.
//!
//! Properties, beyond "no crash, leak or hang":
//! - a spawn request that decodes encodes to a payload that decodes to the
//!   same request.

#![no_main]

use std::io::Write;
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

use cmux_holder::wire::{Kind, Reader};
use cmux_holder::{SpawnRequest, parse_version_line};
use libfuzzer_sys::fuzz_target;

/// Bytes written per piece. Below a Unix socket's default buffer, so the
/// single-threaded write never blocks before the next read drains it.
const PIECE: usize = 4096;

fn check_spawn(payload: &[u8]) {
    if let Ok(request) = SpawnRequest::decode(payload) {
        let again = SpawnRequest::decode(&request.encode()).expect("a re-encoded spawn decodes");
        assert_eq!(again, request, "spawn request round trip changed it");
    }
}

/// Take every buffered frame; `false` once the stream is lost.
fn drain(reader: &mut Reader) -> bool {
    loop {
        match reader.next_frame() {
            Ok(Some(frame)) => {
                let _ = Kind::from_u16(frame.kind);
                check_spawn(&frame.payload);
            }
            Ok(None) => return true,
            Err(_) => return false,
        }
    }
}

fuzz_target!(|data: &[u8]| {
    check_spawn(data);
    let _ = parse_version_line(&String::from_utf8_lossy(data));

    let Ok((mut writer, read_end)) = UnixStream::pair() else { return };
    let mut reader = Reader::default();
    for piece in data.chunks(PIECE) {
        if writer.write_all(piece).is_err() {
            return;
        }
        if !matches!(reader.fill(read_end.as_raw_fd()), Ok(true)) || !drain(&mut reader) {
            return;
        }
    }
    if writer.shutdown(Shutdown::Write).is_err() {
        return;
    }
    while matches!(reader.fill(read_end.as_raw_fd()), Ok(true)) && drain(&mut reader) {}
});
