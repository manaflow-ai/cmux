//! The PTY reader's frames (terminal throughput, CMUX-571): a flood goes to the
//! parser and the daemon in frames of the bytes the PTY held, not one frame per
//! PTY read. A macOS PTY read returns at most 1 KiB, so a `cat` of a large file
//! cost one parser hand-off, one daemon frame and one mirror parse per KiB. A
//! lone key echo still goes out at once, as its own frame. The host reads its
//! PTY non-blocking and drains a flood without a poll per read; a blocking
//! descriptor is polled before each read. Each test runs both.

use super::super::super::shared::host_start::read_pty_output;
use super::*;
use std::time::Instant;

/// A PTY master as macOS reads one: at most 1 KiB per read.
struct MacOsSizedReads(UnixStream);

impl Read for MacOsSizedReads {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let end = buffer.len().min(1024);
        self.0.read(&mut buffer[..end])
    }
}

/// The descriptor modes a reader sees: the host's own (non-blocking) and a
/// blocking one.
const MODES: [bool; 2] = [true, false];

fn start_reader(
    nonblocking: bool,
) -> (Receiver<ParserCommand>, UnixStream, thread::JoinHandle<()>, HostStream) {
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
    pty.set_nonblocking(nonblocking).unwrap();
    let pty_fd = pty.as_raw_fd();
    let (drain_waker, drain_waiter) = HostStream::pair().unwrap();
    let reader = thread::Builder::new()
        .name("terminal-host-pty".into())
        .spawn(move || {
            host.mark_launch_owner_stream_ready();
            read_pty_output(&host, Box::new(MacOsSizedReads(pty)), pty_fd, drain_waiter);
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
    for nonblocking in MODES {
        let (parsed, mut program, reader, drain_waker) = start_reader(nonblocking);
        program.write_all(&flood).unwrap();
        let first = next_output(&parsed);
        assert_eq!(
            first.len(),
            flood.len(),
            "non-blocking {nonblocking}: the reader published the flood's first {} bytes alone",
            first.len()
        );
        assert_eq!(first, flood);
        drop(program);
        reader.join().unwrap();
        drop(drain_waker);
    }
}

#[test]
fn a_lone_echo_goes_out_at_once_in_its_own_frame() {
    for nonblocking in MODES {
        let (parsed, mut program, reader, drain_waker) = start_reader(nonblocking);
        program.write_all(b"x").unwrap();
        assert_eq!(next_output(&parsed), b"x", "non-blocking {nonblocking}");
        program.write_all(b"y").unwrap();
        assert_eq!(next_output(&parsed), b"y", "non-blocking {nonblocking}");
        drop(program);
        reader.join().unwrap();
        drop(drain_waker);
    }
}

#[test]
fn bytes_written_before_the_end_of_stream_all_reach_the_parser() {
    let tail: Vec<u8> = (0..5000).map(|i| b'0' + (i % 10) as u8).collect();
    for nonblocking in MODES {
        let (parsed, mut program, reader, drain_waker) = start_reader(nonblocking);
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
        assert_eq!(got, tail, "non-blocking {nonblocking}");
        reader.join().unwrap();
        drop(drain_waker);
    }
}

/// The bench's terminal text (scripts/cmux-next/terminal-throughput-bench.py):
/// plain lines, lines longer than the grid, 256-color SGR runs and UTF-8, as a
/// PTY hands it over (`\r\n` line ends).
fn bench_payload(bytes: usize) -> Vec<u8> {
    let words =
        ["cargo", "build", "warning:", "error[E0308]:", "src/main.rs:42:7", "Compiling", "ok"];
    let utf8 = ["é", "→", "✓", "日本語", "│", "🙂"];
    let mut state: u64 = 571;
    let mut next = move |n: usize| {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        usize::try_from(state >> 33).unwrap_or(0) % n
    };
    let mut out = Vec::with_capacity(bytes + 512);
    while out.len() < bytes {
        let kind = next(100);
        let count = 6 + next(24);
        for i in 0..count {
            if i > 0 {
                out.push(b' ');
            }
            if kind < 25 {
                out.extend_from_slice(
                    format!("\x1b[38;5;{}m{}\x1b[0m", next(256), words[next(words.len())])
                        .as_bytes(),
                );
            } else if kind < 35 {
                out.extend_from_slice(utf8[next(utf8.len())].as_bytes());
            } else {
                out.extend_from_slice(words[next(words.len())].as_bytes());
            }
        }
        out.extend_from_slice(b"\r\n");
    }
    out.truncate(bytes);
    out
}

/// The terminal host's own stage of the throughput path, with no kernel PTY
/// in the way: a program writes the payload into a socket as fast as it can,
/// the host's PTY reader reads it in macOS-sized (1 KiB) reads or whole reads,
/// and the host's parser applies it. MB/s is payload bytes over the time
/// until the parser drained the last byte. A Linux PTY read returns what the
/// line discipline holds (about 1.3 KiB a read in the daemon bench, cmux-tui
/// tests/terminal_throughput_stages.rs), a macOS one at most 1 KiB; this
/// stage fixes the read size, so it measures the host alone on any machine.
/// The `-poll` arms read a blocking descriptor, polled before every read (the
/// reader before CMUX-571's drain); the others read it non-blocking, as the
/// host reads its PTY. `CMUX_HOST_STAGE_MB` sets the payload (default 200).
#[test]
#[ignore = "a throughput bench; run with --ignored --nocapture"]
fn host_stage_throughput_bench() {
    let mb: usize = std::env::var("CMUX_HOST_STAGE_MB")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(200);
    let payload = Arc::new(bench_payload(mb * 1_000_000));
    for (label, macos_reads, nonblocking) in [
        ("host-1KiB-reads-poll", true, false),
        ("host-1KiB-reads", true, true),
        ("host-whole-reads-poll", false, false),
        ("host-whole-reads", false, true),
    ] {
        let term = Terminal::new(120, 40, 10_000_000, Callbacks::default()).unwrap();
        let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
        let host = host_fixture::test_host_shared_with_budget(
            term,
            parser_commands,
            ClipboardReads::new(Arc::new(SystemClock)),
            MAX_HOST_PARSER_QUEUED_BYTES,
        );
        let initial_colors = host.term.lock().unwrap().color_overrides();
        let signals = ParserSignals {
            pending_responses: Arc::new(Mutex::new(Vec::new())),
            title_changed: Arc::new(AtomicBool::new(false)),
            bell: Arc::new(AtomicBool::new(false)),
            program_status: Default::default(),
        };
        let parser_host = host.clone();
        let parser = thread::Builder::new()
            .name("terminal-host-parser".into())
            .spawn(move || {
                run_host_parser(parser_host, receiver, initial_colors, signals);
                thread_cpu_seconds()
            })
            .unwrap();
        let (pty, mut program) = UnixStream::pair().unwrap();
        pty.set_nonblocking(nonblocking).unwrap();
        let pty_fd = pty.as_raw_fd();
        let (drain_waker, drain_waiter) = HostStream::pair().unwrap();
        let reader_host = host.clone();
        let reader = thread::Builder::new()
            .name("terminal-host-pty".into())
            .spawn(move || {
                reader_host.mark_launch_owner_stream_ready();
                let pty: Box<dyn Read + Send> =
                    if macos_reads { Box::new(MacOsSizedReads(pty)) } else { Box::new(pty) };
                read_pty_output(&reader_host, pty, pty_fd, drain_waiter);
                thread_cpu_seconds()
            })
            .unwrap();
        let started = Instant::now();
        let source = payload.clone();
        let writer = thread::spawn(move || {
            for chunk in source.chunks(64 * 1024) {
                program.write_all(chunk).unwrap();
            }
        });
        writer.join().unwrap();
        let reader_cpu = reader.join().unwrap();
        let parser_cpu = parser.join().unwrap();
        let seconds = started.elapsed().as_secs_f64();
        drop(drain_waker);
        let mb_s = payload.len() as f64 / 1_000_000.0 / seconds;
        let reader_pct = reader_cpu / seconds * 100.0;
        let parser_pct = parser_cpu / seconds * 100.0;
        println!(
            "HOST-STAGE {{\"stage\":\"{label}\",\"bytes\":{},\"seconds\":{seconds:.4},\"mb_s\":{mb_s:.1},\"reader_cpu_pct\":{reader_pct:.1},\"parser_cpu_pct\":{parser_pct:.1}}}",
            payload.len()
        );
    }
}

/// CPU seconds the calling thread has used.
fn thread_cpu_seconds() -> f64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid timespec for clock_gettime to fill.
    let status = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut now) };
    assert_eq!(status, 0, "clock_gettime: {}", std::io::Error::last_os_error());
    now.tv_sec as f64 + now.tv_nsec as f64 / 1e9
}

/// The host parser's per-frame work, one step at a time, on the host-stage
/// payload in `CMUX_HOST_FRAME_BYTES` frames (default 16 KiB, the PTY
/// reader's flood frame): which of the steps the parser runs besides the
/// ghostty-vt parse costs what. Each step runs over the whole payload on its
/// own, so its MB/s is the cap it alone puts on the parser thread.
#[test]
#[ignore = "a throughput bench; run with --ignored --nocapture"]
fn host_parser_frame_breakdown_bench() {
    let mb: usize = std::env::var("CMUX_HOST_STAGE_MB")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(200);
    let frame_bytes: usize = std::env::var("CMUX_HOST_FRAME_BYTES")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(16 * 1024);
    let payload = bench_payload(mb * 1_000_000);
    let frames: Vec<&[u8]> = payload.chunks(frame_bytes).collect();
    let report = |step: &str, seconds: f64| {
        let mb_s = payload.len() as f64 / 1_000_000.0 / seconds;
        let ns_frame = seconds * 1e9 / frames.len() as f64;
        println!(
            "HOST-FRAME-STEP {{\"step\":\"{step}\",\"frame_bytes\":{frame_bytes},\"seconds\":{seconds:.4},\"mb_s\":{mb_s:.1},\"ns_per_frame\":{ns_frame:.0}}}"
        );
    };
    let terminal = || Terminal::new(120, 40, 10_000_000, Callbacks::default()).unwrap();

    let mut term = terminal();
    let started = Instant::now();
    for frame in &frames {
        term.vt_write(frame);
    }
    report("vt_write", started.elapsed().as_secs_f64());

    let mut term = terminal();
    let mut marks = crate::prompt_mode_reset::ShellMarks::default();
    let started = Instant::now();
    for frame in &frames {
        std::hint::black_box(crate::prompt_mode_reset::write_output(&mut term, frame, &mut marks));
    }
    report("write_output", started.elapsed().as_secs_f64());

    let mut titles = crate::terminal_title::TitleTracker::default();
    let started = Instant::now();
    for frame in &frames {
        std::hint::black_box(titles.rewrite(frame));
    }
    report("title_rewrite", started.elapsed().as_secs_f64());

    let started = Instant::now();
    for frame in &frames {
        std::hint::black_box(memchr::memmem::find(frame, b"\x1b]133;"));
    }
    report("prompt_mark_find", started.elapsed().as_secs_f64());

    let mut metadata = crate::terminal_metadata::TerminalMetadata::default();
    let started = Instant::now();
    for frame in &frames {
        metadata.observe_output(frame);
    }
    report("metadata_observe_output", started.elapsed().as_secs_f64());

    // What the parser runs instead of the two scans above: one walk.
    let mut metadata = crate::terminal_metadata::TerminalMetadata::default();
    let mut titles = crate::terminal_title::TitleTracker::default();
    let started = Instant::now();
    for frame in &frames {
        std::hint::black_box(metadata.observe_output_rewriting_titles(&mut titles, frame));
    }
    report("shared_scan", started.elapsed().as_secs_f64());

    let term = terminal();
    let started = Instant::now();
    for _ in &frames {
        std::hint::black_box(crate::terminal_activity::terminal_modes(&term));
    }
    report("terminal_modes", started.elapsed().as_secs_f64());

    let started = Instant::now();
    for frame in &frames {
        std::hint::black_box(frame.to_vec());
    }
    report("frame_copy", started.elapsed().as_secs_f64());
}
