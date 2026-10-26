//! The request head the daemon's WebSocket listener reads from any local
//! connection (`page_files::read_request_head`, server/page_files.rs), before
//! the Host/Origin rule. The first byte sets how many bytes each read returns
//! (1..=256, as a slow or split TCP stream delivers them); the rest is what
//! the peer sends.
//!
//! A head it accepts was read up to the stream's first blank line, every byte
//! it returns is a prefix of the stream, its method is a token, and its
//! target and Host and Origin values hold no control byte but HTAB. It
//! answers only an oversized head (431), and only after reading the whole
//! limit.

#![no_main]

use std::io::{Read, Write};

use cmux_tui_core::fuzz_entry::{PAGE_REQUEST_HEAD_MAX_BYTES, page_request_head};
use libfuzzer_sys::fuzz_target;

struct Peer<'a> {
    sent: &'a [u8],
    read_size: usize,
    answered: Vec<u8>,
}

impl Read for Peer<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let count = self.read_size.min(buffer.len()).min(self.sent.len());
        let (now, later) = self.sent.split_at(count);
        buffer[..count].copy_from_slice(now);
        self.sent = later;
        Ok(count)
    }
}

impl Write for Peer<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.answered.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

const BLANK_LINE: &[u8] = b"\r\n\r\n";

fuzz_target!(|data: &[u8]| {
    let Some((&read_size, sent)) = data.split_first() else {
        return;
    };
    let mut peer = Peer { sent, read_size: usize::from(read_size) + 1, answered: Vec::new() };
    let read = page_request_head(&mut peer);
    let blank_line = sent.windows(BLANK_LINE.len()).position(|window| window == BLANK_LINE);
    match read {
        Some((bytes, head)) => {
            assert!(sent.starts_with(&bytes), "the bytes read are not the stream's");
            let head_end = blank_line.map(|at| at + BLANK_LINE.len());
            assert!(
                head_end.is_some_and(|end| end <= bytes.len()),
                "a head was accepted before its blank line"
            );
            let token =
                |byte: u8| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte);
            assert!(
                !head.method.is_empty() && head.method.bytes().all(token),
                "the method is not a token"
            );
            for value in std::iter::once(&head.target).chain(&head.host).chain(&head.origin) {
                assert!(
                    !value.bytes().any(|byte| byte.is_ascii_control() && byte != b'\t'),
                    "a parsed part holds a control byte"
                );
            }
            assert!(!head.target.contains(' '), "the target holds a space");
            assert!(peer.answered.is_empty(), "an accepted head was answered");
        }
        None if !peer.answered.is_empty() => {
            assert!(
                peer.answered.starts_with(b"HTTP/1.1 431 "),
                "a refused head was answered with something other than 431"
            );
            let consumed = data.len() - 1 - peer.sent.len();
            assert!(consumed >= PAGE_REQUEST_HEAD_MAX_BYTES, "431 before the head limit");
        }
        None => {}
    }
});
