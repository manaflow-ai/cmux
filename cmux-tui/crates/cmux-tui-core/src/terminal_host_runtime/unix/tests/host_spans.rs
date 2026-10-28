//! The terminal host's trace slices: `task.host_pty_read` per PTY read,
//! `task.host_parse` per parser command and `task.host_input_write` per client-input write, each
//! with the terminal's hash. `task` is recording-only, so the black box never holds them.
//!
//! The ring is per process and other tests run beside these, so each test finds its records by
//! its own host's terminal hash.

use std::sync::{OnceLock, PoisonError};

use cmux_kitty_media::KittyMediaRewriter;
use cmux_trace::{Decoded, DecodedRecord, Phase, Role, category, decode};

use super::super::super::shared::host_parser::parser_command_trace_arg;
use super::super::super::shared::host_shared::InputWrite;
use super::super::super::shared::host_start::{PtyRead, read_pty_once};
use super::host_fixture::test_host_shared_with_budget;
use super::*;

/// Opens this test process's rings once. Both ring files are mapped first (a recording starts and
/// stops) and then unlinked, so a test run leaves no file behind; the mappings stay valid.
fn open_rings() {
    static OPENED: OnceLock<()> = OnceLock::new();
    OPENED.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("cmux-host-spans-{}", std::process::id()));
        if let Some(open) = cmux_trace::init_blackbox(&dir, Role::TerminalHost) {
            let _ = open.wait();
        }
        cmux_trace::start_recording(category::TASK).expect("a recording starts");
        cmux_trace::stop().expect("the recording stops");
        let _ = fs::remove_dir_all(&dir);
    });
}

/// How many [`Recording`]s are alive: the first starts the `task` recording, the last stops it.
static RECORDING_USERS: Mutex<usize> = Mutex::new(0);

/// A `task` recording held while a test runs, so the tests beside these do not record.
struct Recording;

fn recording() -> Recording {
    open_rings();
    let mut users = RECORDING_USERS.lock().unwrap_or_else(PoisonError::into_inner);
    if *users == 0 {
        cmux_trace::start_recording(category::TASK).expect("a recording starts");
    }
    *users += 1;
    assert!(cmux_trace::enabled(category::TASK));
    Recording
}

impl Drop for Recording {
    fn drop(&mut self) {
        let mut users = RECORDING_USERS.lock().unwrap_or_else(PoisonError::into_inner);
        *users -= 1;
        if *users == 0 {
            let _ = cmux_trace::stop();
        }
    }
}

/// The ring's records named `name` with arg0 `hash`, in the order their thread wrote them.
fn records(name: &str, hash: u64) -> Vec<DecodedRecord> {
    let decoded: Decoded =
        decode(&cmux_trace::snapshot_active().expect("tracing started")).expect("the ring decodes");
    let mut named: Vec<DecodedRecord> = decoded
        .records
        .iter()
        .filter(|record| decoded.name(record.name) == Some(name))
        .copied()
        .collect();
    named.sort_by_key(|record| {
        (record.thread_index, record.thread_generation, record.position, record.slot)
    });
    // An end record carries its own numbers: keep each end that follows a begin of this hash on
    // its thread.
    let mut kept = Vec::new();
    let mut open_on = None;
    for record in named {
        let thread = (record.thread_index, record.thread_generation);
        if record.phase == Phase::Begin as u8 {
            open_on = (record.arg0 == hash).then_some(thread);
            if open_on.is_some() {
                kept.push(record);
            }
        } else if record.phase == Phase::End as u8 {
            if open_on.take() == Some(thread) {
                kept.push(record);
            }
        } else if record.arg0 == hash {
            kept.push(record);
        }
    }
    kept
}

fn host_with_parser_queue() -> (Arc<HostShared>, Receiver<ParserCommand>) {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
    );
    (host, receiver)
}

fn hash_of(host: &HostShared) -> u64 {
    cmux_trace::terminal_hash(host.terminal_id.as_bytes())
}

#[test]
fn host_spans_one_pty_read_slice_per_read_with_its_byte_count() {
    let _recording = recording();
    let (host, receiver) = host_with_parser_queue();
    let (mut pty, mut reader) = UnixStream::pair().unwrap();
    reader.set_nonblocking(true).unwrap();
    let mut buffer = [0u8; 64];
    let (mut kitty, mut scratch) = (KittyMediaRewriter::new(), Vec::new());

    let read = read_pty_once(&host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::Retry, "a wake with nothing to read waits again");
    assert!(!read.ends());
    pty.write_all(b"hello").unwrap();
    let read = read_pty_once(&host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::Published);
    assert!(
        matches!(receiver.try_recv(), Ok(ParserCommand::Output { bytes, .. }) if bytes == b"hello")
    );
    drop(pty);
    let read = read_pty_once(&host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::Eof);
    assert!(read.ends(), "end of file ends the reader");
    let read = read_pty_once(&host, &mut FailingRead, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::Failed);
    assert!(read.ends(), "a read error ends the reader");

    let slices = records("task.host_pty_read", hash_of(&host));
    let phases: Vec<u8> = slices.iter().map(|record| record.phase).collect();
    let (begin, end) = (Phase::Begin as u8, Phase::End as u8);
    assert_eq!(phases, [begin, end, begin, end, begin, end, begin, end], "{slices:?}");
    // Each end: the bytes read, and what the read did.
    let ends: Vec<(u64, u64)> =
        slices.iter().skip(1).step_by(2).map(|record| (record.arg0, record.arg1)).collect();
    assert_eq!(
        ends,
        [
            (0, PtyRead::Retry as u64),
            (5, PtyRead::Published as u64),
            (0, PtyRead::Eof as u64),
            (0, PtyRead::Failed as u64),
        ]
    );
    assert!(slices[0].t_ns <= slices[1].t_ns);
}

/// A PTY whose reads fail.
struct FailingRead;

impl Read for FailingRead {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        Err(std::io::Error::other("the pty is gone"))
    }
}

/// A PTY writer whose writes fail.
struct FailingWrite;

impl Write for FailingWrite {
    fn write(&mut self, _bytes: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::other("the pty is gone"))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn host_spans_one_parse_slice_per_parser_command() {
    let _recording = recording();
    let (host, receiver) = host_with_parser_queue();
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let parser_host = host.clone();
    let parser = thread::spawn(move || {
        run_host_parser(parser_host, receiver, initial_colors, ParserSignals::new());
    });
    let output = ParserCommand::Output {
        bytes: b"parsed".to_vec(),
        source_cursor: host.smart.publish(Frame::new(MessageKind::Output, b"parsed".to_vec())),
        accounted_bytes: 0,
    };
    let output_arg = parser_command_trace_arg(&output);
    assert_eq!(output_arg, 6, "an Output's arg is kind 0 and its byte count");
    host.parser_commands.send(output).unwrap();
    assert_eq!(parser_command_trace_arg(&ParserCommand::Drain), 6 << 56);
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().expect("the parser applied every command");

    let slices = records("task.host_parse", hash_of(&host));
    let begins: Vec<u64> = slices
        .iter()
        .filter(|record| record.phase == Phase::Begin as u8)
        .map(|record| record.arg1)
        .collect();
    assert_eq!(begins, [output_arg, 6 << 56], "one slice per command: {slices:?}");
    let ends = slices.iter().filter(|record| record.phase == Phase::End as u8).count();
    assert_eq!(ends, 2, "every command's slice ended: {slices:?}");
}

#[test]
fn host_spans_one_input_write_slice_per_client_write() {
    let _recording = recording();
    let host = test_host_shared();
    let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();
    *host.writer.lock().unwrap() = Box::new(pty_writer);
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, _target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

    assert!(host.write_input(b"typed", 0, 0, &target));
    let mut typed = [0u8; 5];
    pty_reader.read_exact(&mut typed).unwrap();
    assert_eq!(&typed, b"typed");

    // A write that fails reports no bytes written, so it never looks delivered.
    *host.writer.lock().unwrap() = Box::new(FailingWrite);
    assert!(!host.write_input(b"lost", 7, 0, &target), "a receipted write that failed");

    let slices = records("task.host_input_write", hash_of(&host));
    let phases: Vec<u8> = slices.iter().map(|record| record.phase).collect();
    let (begin, end) = (Phase::Begin as u8, Phase::End as u8);
    assert_eq!(phases, [begin, end, begin, end], "{slices:?}");
    assert_eq!(slices[0].arg1, 5, "the begin carries the payload's bytes");
    assert_eq!((slices[1].arg0, slices[1].arg1), (5, InputWrite::Written as u64));
    assert_eq!(slices[2].arg1, 4);
    assert_eq!((slices[3].arg0, slices[3].arg1), (0, InputWrite::Failed as u64));
}

/// A master whose input queue is `queue`'s unread bytes (`FIONREAD` counts a socket's as a PTY's).
#[cfg(target_os = "macos")]
struct QueuedMaster {
    size: Mutex<PtySize>,
    queue: UnixStream,
}

#[cfg(target_os = "macos")]
impl MasterPty for QueuedMaster {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    fn as_raw_fd(&self) -> Option<RawFd> {
        Some(AsRawFd::as_raw_fd(&self.queue))
    }

    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

/// Interactive wheel input the child's full input queue cannot take is dropped: its slice ends
/// with no bytes written and the Dropped outcome, unlike a delivered write.
#[cfg(target_os = "macos")]
#[test]
fn host_spans_dropped_wheel_input_ends_with_no_bytes_written() {
    let _recording = recording();
    let host = test_host_shared();
    let (pty_writer, _pty_reader) = UnixStream::pair().unwrap();
    *host.writer.lock().unwrap() = Box::new(pty_writer);
    let (mut filler, queue) = UnixStream::pair().unwrap();
    filler.write_all(&[b'k'; 1000]).unwrap();
    *host.master.lock().unwrap() =
        Box::new(QueuedMaster { size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS)), queue });
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, _target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

    let wheel = b"\x1b[<65;27;20M";
    assert!(host.write_input(wheel, 0, 0, &target), "interactive input is best-effort");

    let slices = records("task.host_input_write", hash_of(&host));
    let phases: Vec<u8> = slices.iter().map(|record| record.phase).collect();
    assert_eq!(phases, [Phase::Begin as u8, Phase::End as u8], "{slices:?}");
    assert_eq!(slices[0].arg1, wheel.len() as u64);
    assert_eq!((slices[1].arg0, slices[1].arg1), (0, InputWrite::Dropped as u64));
}
