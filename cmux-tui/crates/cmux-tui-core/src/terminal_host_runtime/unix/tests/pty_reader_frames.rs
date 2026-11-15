//! The PTY reader's frames (terminal throughput, CMUX-571): a flood goes to the
//! parser and the daemon in frames of the bytes the PTY held, not one frame per
//! PTY read. A macOS PTY read returns at most 1 KiB, so a `cat` of a large file
//! cost one parser hand-off, one daemon frame and one mirror parse per KiB. A
//! lone key echo still goes out at once, as its own frame.

use super::super::super::shared::host_start::read_pty_output;
use super::*;
use std::io::Read as _;

/// A PTY master as macOS reads one: at most 1 KiB per read.
struct MacOsSizedReads(UnixStream);

impl std::io::Read for MacOsSizedReads {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let end = buffer.len().min(1024);
        self.0.read(&mut buffer[..end])
    }
}

fn start_reader() -> (Receiver<ParserCommand>, UnixStream, thread::JoinHandle<()>, HostStream) {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, parsed) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = host_fixture::test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        1 << 20,
    );
    // A socket stands in for the PTY master: the reader polls and reads a
    // descriptor either way.
    let (pty, program) = UnixStream::pair().unwrap();
    let pty_fd = pty.as_raw_fd();
    let (drain_waker, drain_waiter) = HostStream::pair().unwrap();
    let reader = thread::Builder::new()
        .name("terminal-host-pty".into())
        .spawn(move || {
            host.mark_launch_owner_stream_ready();
            read_pty_output(&host, Box::new(MacOsSizedReads(pty)), pty_fd, drain_waiter)
        })
        .unwrap();
    (parsed, program, reader, drain_waker)
}

fn next_output(parsed: &Receiver<ParserCommand>) -> Vec<u8> {
    loop {
        match parsed.recv_timeout(Duration::from_secs(10)).unwrap() {
            ParserCommand::Output { frame, .. } => return frame.payload.to_vec(),
            ParserCommand::Drain => panic!("the reader drained before the expected output"),
            _ => {}
        }
    }
}

#[test]
fn a_flood_reaches_the_parser_in_frames_of_the_waiting_bytes_not_one_per_read() {
    // One 12 KiB write: twelve 1 KiB reads.
    let flood: Vec<u8> = (0..12 * 1024).map(|i| b'a' + (i % 26) as u8).collect();
    let (parsed, mut program, reader, drain_waker) = start_reader();
    program.write_all(&flood).unwrap();
    let first = next_output(&parsed);
    assert_eq!(
        first.len(),
        flood.len(),
        "the reader published the flood's first {} bytes alone: one frame per PTY read",
        first.len()
    );
    assert_eq!(first, flood);
    drop(program);
    reader.join().unwrap();
    drop(drain_waker);
}

#[test]
fn a_lone_echo_goes_out_at_once_in_its_own_frame() {
    let (parsed, mut program, reader, drain_waker) = start_reader();
    program.write_all(b"x").unwrap();
    assert_eq!(next_output(&parsed), b"x");
    program.write_all(b"y").unwrap();
    assert_eq!(next_output(&parsed), b"y");
    drop(program);
    reader.join().unwrap();
    drop(drain_waker);
}

#[test]
fn bytes_written_before_the_end_of_stream_all_reach_the_parser() {
    let (parsed, mut program, reader, drain_waker) = start_reader();
    let tail: Vec<u8> = (0..5000).map(|i| b'0' + (i % 10) as u8).collect();
    program.write_all(&tail).unwrap();
    drop(program);
    let mut got = Vec::new();
    loop {
        match parsed.recv_timeout(Duration::from_secs(10)).unwrap() {
            ParserCommand::Output { frame, .. } => got.extend_from_slice(&frame.payload),
            ParserCommand::Drain => break,
            _ => {}
        }
    }
    assert_eq!(got, tail);
    reader.join().unwrap();
    drop(drain_waker);
}
