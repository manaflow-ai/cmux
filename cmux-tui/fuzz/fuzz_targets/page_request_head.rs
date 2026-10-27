//! The request head the daemon's WebSocket listener reads from any local
//! connection (`page_files::read_request_head`, server/page_files.rs), before
//! the Host/Origin rule. The first byte sets how many bytes each read returns
//! (1..=256, as a slow or split TCP stream delivers them). The second sets the
//! head limit: 255 is the daemon's PAGE_REQUEST_HEAD_MAX_BYTES (64 KiB), any
//! other value N is 16 * (N + 1) bytes, so short inputs reach the 431 branch
//! that a 64 KiB input past libFuzzer's grown max_len rarely does. The rest is
//! what the peer sends.
//!
//! A head it accepts was read up to the stream's first blank line, every byte
//! it returns is a prefix of the stream, its request line is exactly
//! `method SP target SP HTTP/1.x` with a token method and a non-empty
//! target, every field name is a token (so no whitespace before a colon and
//! no obs-fold line), and its target and Host and Origin values hold no
//! control byte but HTAB. It answers only an oversized head (431), only after
//! reading the whole limit and only when no blank line ended in what it read.

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
    let [read_size, limit, sent @ ..] = data else {
        return;
    };
    let max_bytes = match limit {
        255 => PAGE_REQUEST_HEAD_MAX_BYTES,
        limit => 16 * (usize::from(*limit) + 1),
    };
    let mut peer = Peer { sent, read_size: usize::from(*read_size) + 1, answered: Vec::new() };
    let read = page_request_head(&mut peer, max_bytes);
    let blank_line = sent.windows(BLANK_LINE.len()).position(|window| window == BLANK_LINE);
    match read {
        Some((bytes, head)) => {
            assert!(sent.starts_with(&bytes), "the bytes read are not the stream's");
            let head_end = blank_line.map(|at| at + BLANK_LINE.len());
            assert!(
                head_end.is_some_and(|end| end <= bytes.len()),
                "a head was accepted before its blank line"
            );
            let token = |text: &str| {
                !text.is_empty()
                    && text.bytes().all(|byte| {
                        byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
                    })
            };
            assert!(token(&head.method), "the method is not a token");
            let request_line = bytes.split(|&byte| byte == b'\r').next().unwrap_or_default();
            let version = request_line
                .strip_prefix(format!("{} {} ", head.method, head.target).as_bytes())
                .expect("the request line is not method SP target SP version");
            assert!(!head.target.is_empty(), "the target is empty");
            assert!(
                version.len() == 8
                    && version.starts_with(b"HTTP/1.")
                    && version[7].is_ascii_digit(),
                "the version is not HTTP/1.x"
            );
            for name in &head.header_names {
                assert!(token(name), "a field name is not a token");
            }
            let field_lines =
                blank_line.map(|end| sent[..end].windows(2).filter(|pair| pair == b"\r\n").count());
            assert_eq!(field_lines, Some(head.header_names.len()), "a field line was dropped");
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
            let consumed = sent.len() - peer.sent.len();
            assert!(consumed >= max_bytes, "431 before the head limit");
            assert!(
                blank_line.is_none_or(|at| at + BLANK_LINE.len() > consumed),
                "431 for a head whose blank line was already read"
            );
        }
        None => {}
    }
});
