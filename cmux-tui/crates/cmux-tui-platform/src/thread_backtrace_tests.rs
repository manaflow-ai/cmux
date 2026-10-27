//! Backtraces of a busy thread: the interrupted pc names the function it
//! runs, each frame carries its image's build id, a capture stops the thread
//! well under a millisecond, and the thread keeps running afterwards.

use std::hint::black_box;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::image_id::{gnu_build_id, hex, mach_uuid};
use super::*;

/// The function the busy thread is in when it is captured: a loop with no
/// call, so the interrupted pc is inside it.
#[inline(never)]
fn backtrace_test_spin(stop: &AtomicBool, spins: &AtomicU64) {
    while !stop.load(Ordering::Relaxed) {
        spins.fetch_add(1, Ordering::Relaxed);
        std::hint::spin_loop();
    }
}

/// Another busy function, for a thread that must never be the one captured.
#[cfg(target_os = "linux")]
#[inline(never)]
fn backtrace_test_bystander(stop: &AtomicBool, spins: &AtomicU64) {
    while !stop.load(Ordering::Relaxed) {
        spins.fetch_add(1, Ordering::Relaxed);
        std::hint::spin_loop();
    }
}

/// The demangled names of the function that holds the pc `address` and of
/// every function inlined there, from the test binary's debug info.
fn function_names(address: usize) -> Vec<String> {
    return_address_names(address + 1)
}

/// As [`function_names`] for a return address: `backtrace::resolve` looks
/// up the byte before it (the call), so a pc at a function's first byte is
/// passed one past it.
fn return_address_names(address: usize) -> Vec<String> {
    let mut names = Vec::new();
    backtrace::resolve(address as *mut std::ffi::c_void, |symbol| {
        if let Some(name) = symbol.name() {
            names.push(name.to_string());
        }
    });
    names
}

fn assert_in_function(address: usize, function: &str) {
    let names = function_names(address);
    assert!(
        names.iter().any(|name| name.contains(function)),
        "{address:#x} is in {names:?}, not {function}"
    );
}

/// `p` (0..=100) of sorted `times`.
fn percentile(times: &[Duration], p: usize) -> Duration {
    times[(times.len() - 1) * p / 100]
}

struct Spinner {
    handle: ThreadHandle,
    stop: Arc<AtomicBool>,
    spins: Arc<AtomicU64>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Spinner {
    fn start() -> Self {
        Self::running(backtrace_test_spin)
    }

    fn running(body: fn(&AtomicBool, &AtomicU64)) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let spins = Arc::new(AtomicU64::new(0));
        let (sender, receiver) = mpsc::channel();
        let thread = std::thread::spawn({
            let stop = stop.clone();
            let spins = spins.clone();
            move || {
                sender.send(ThreadHandle::current()).unwrap();
                body(black_box(&stop), black_box(&spins));
            }
        });
        let handle = receiver.recv().unwrap().expect("a thread handle");
        // Wait until the thread is inside the loop.
        let deadline = Instant::now() + Duration::from_secs(5);
        while spins.load(Ordering::Relaxed) == 0 {
            assert!(Instant::now() < deadline, "the spinner never started");
            std::thread::yield_now();
        }
        Self { handle, stop, spins, thread: Some(thread) }
    }
}

impl Drop for Spinner {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

#[test]
fn request_watchdog_stack_captures_the_function_a_busy_thread_runs() {
    let spinner = Spinner::start();
    let backtrace = capture(spinner.handle).expect("a capture");
    let frames = backtrace.frames();
    assert!(!frames.is_empty(), "{backtrace:?}");
    assert_in_function(frames[0], "backtrace_test_spin");

    // The image and offset stored for offline symbolication point at the
    // same function: the offset is relative to the image's load address.
    let symbolicated = backtrace.symbolicate();
    assert_eq!(symbolicated.len(), frames.len());
    let entry_address = backtrace_test_spin as *const () as usize;
    let entry = symbolicate_address(entry_address);
    assert!(entry.image.is_some(), "the test binary is a loaded image: {entry:?}");
    let top = &symbolicated[0];
    assert_eq!(top.image, entry.image, "{top:?}");
    let image_base = entry_address - entry.offset;
    assert_in_function(image_base + top.offset, "backtrace_test_spin");

    // The callers: walked where the build keeps frame pointers, otherwise
    // only the pc, marked truncated.
    if cfg!(any(target_os = "macos", cmux_frame_pointers)) {
        assert!(!backtrace.truncated(), "{backtrace:?}");
        assert!(
            frames[1..].iter().any(|&address| return_address_names(address)
                .iter()
                .any(|name| name.contains("running::{closure"))),
            "the walk reaches the spawning closure: {backtrace:?} {:?}",
            frames.iter().map(|&address| return_address_names(address)).collect::<Vec<_>>()
        );
    } else {
        assert!(backtrace.truncated(), "{backtrace:?}");
        assert_eq!(frames.len(), 1, "{backtrace:?}");
    }

    // The thread runs on after the capture.
    let before = spinner.spins.load(Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(5);
    while spinner.spins.load(Ordering::Relaxed) == before {
        assert!(Instant::now() < deadline, "the captured thread did not run again");
        std::thread::yield_now();
    }
}

/// The test binary's build id, read from its file: the ELF NT_GNU_BUILD_ID
/// in hex, or the Mach-O LC_UUID as dwarfdump prints it.
fn test_binary_id() -> Option<String> {
    use object::Object;

    let data = std::fs::read(std::env::current_exe().unwrap()).unwrap();
    let file = object::File::parse(&*data).unwrap();
    if let Some(uuid) = file.mach_uuid().unwrap() {
        let text = hex(&uuid).to_uppercase();
        return Some(format!(
            "{}-{}-{}-{}-{}",
            &text[..8],
            &text[8..12],
            &text[12..16],
            &text[16..20],
            &text[20..]
        ));
    }
    file.build_id().unwrap().map(hex)
}

#[test]
fn request_watchdog_stack_frames_carry_the_image_build_id() {
    let spinner = Spinner::start();
    let backtrace = capture(spinner.handle).expect("a capture");
    let top = &backtrace.symbolicate()[0];
    let expected = test_binary_id();
    assert_eq!(top.image_id, expected, "{top:?}");
    if cfg!(target_os = "macos") {
        assert!(expected.is_some(), "ld64 always writes LC_UUID");
    }
    let entry = symbolicate_address(backtrace_test_spin as *const () as usize);
    assert_eq!(entry.image_id, expected, "{entry:?}");
}

#[test]
fn request_watchdog_stack_reads_build_ids_from_notes_and_load_commands() {
    fn note(kind: u32, name: &[u8], desc: &[u8], align: usize) -> Vec<u8> {
        let pad = |bytes: &mut Vec<u8>| bytes.resize(bytes.len().div_ceil(align) * align, 0);
        let mut note = Vec::new();
        note.extend((name.len() as u32).to_ne_bytes());
        note.extend((desc.len() as u32).to_ne_bytes());
        note.extend(kind.to_ne_bytes());
        note.extend(name);
        pad(&mut note);
        note.extend(desc);
        pad(&mut note);
        note
    }
    // One segment, as lld links it: an 8-aligned .note.gnu.property, then
    // 4-aligned notes.
    let mut notes = note(5, b"GNU\0", &[9; 16], 8);
    notes.extend(note(1, b"GNU\0", &[1; 16], 4));
    notes.extend(note(3, b"Go\0", &[7; 5], 4));
    notes.extend(note(3, b"GNU\0", &[0xab, 0xcd, 0xef], 4));
    assert_eq!(gnu_build_id(&notes), Some(&[0xab, 0xcd, 0xef][..]));
    assert_eq!(gnu_build_id(&notes[..notes.len() - 4]), None, "cut short");
    assert_eq!(gnu_build_id(&notes[..20]), None, "no build id");

    let mut header = vec![0u8; 32];
    header[..4].copy_from_slice(&0xfeed_facf_u32.to_ne_bytes());
    header[16..20].copy_from_slice(&2u32.to_ne_bytes());
    // LC_SEGMENT_64 (0x19) of 16 bytes, then LC_UUID (0x1b, 24 bytes).
    header.extend(0x19u32.to_ne_bytes());
    header.extend(16u32.to_ne_bytes());
    header.extend([0; 8]);
    header.extend(0x1bu32.to_ne_bytes());
    header.extend(24u32.to_ne_bytes());
    header.extend((0..16u8).map(|byte| byte * 0x11));
    assert_eq!(mach_uuid(&header).as_deref(), Some("00112233-4455-6677-8899-AABBCCDDEEFF"));
    header[..4].copy_from_slice(&0xfeed_face_u32.to_ne_bytes());
    assert_eq!(mach_uuid(&header), None, "a 32-bit header is not read");
}

/// How long the busy thread is stopped is what the watchdog costs it: its
/// p95 over 200 captures stays under a millisecond (on macOS the suspend to
/// resume window, so a descheduled capturer counts). The call's own wall
/// time also holds two scheduler wakes on Linux and waits for other tests'
/// captures (one at a time), so only its median is held to the bound.
#[test]
fn request_watchdog_stack_capture_takes_under_a_millisecond() {
    let spinner = Spinner::start();
    let (mut stopped, mut wall): (Vec<Duration>, Vec<Duration>) = (0..200)
        .map(|_| {
            let start = Instant::now();
            let backtrace = capture(spinner.handle).expect("a capture");
            (backtrace.stopped(), start.elapsed())
        })
        .unzip();
    stopped.sort();
    wall.sort();
    let report = |times: &[Duration]| {
        format!(
            "p50 {:?} p95 {:?} p99 {:?} max {:?}",
            percentile(times, 50),
            percentile(times, 95),
            percentile(times, 99),
            percentile(times, 100)
        )
    };
    println!("thread stopped: {}; capture call: {}", report(&stopped), report(&wall));
    assert!(percentile(&stopped, 95) < Duration::from_millis(1), "stopped {}", report(&stopped));
    assert!(percentile(&wall, 50) < Duration::from_millis(1), "capture call {}", report(&wall));
}

#[test]
fn request_watchdog_stack_refuses_the_current_thread() {
    let current = ThreadHandle::current().expect("captures run on this OS");
    assert_eq!(capture(current).unwrap_err(), BacktraceError::CurrentThread);
}

#[test]
fn request_watchdog_stack_fails_cleanly_for_an_exited_thread() {
    let handle = std::thread::spawn(ThreadHandle::current).join().unwrap().expect("a handle");
    let result = capture(handle);
    // Linux hands out tids in order, so the exited tid is not reused here:
    // the signal finds no thread, or one still exiting that never answers.
    #[cfg(target_os = "linux")]
    assert!(
        matches!(result, Err(BacktraceError::Signal(libc::ESRCH) | BacktraceError::Timeout)),
        "{result:?}"
    );
    // A Mach port name can be reused at once; a capture that succeeds read
    // the registers of a live thread, so it has at least its pc.
    #[cfg(target_os = "macos")]
    match result {
        Ok(backtrace) => assert!(!backtrace.frames().is_empty(), "{backtrace:?}"),
        Err(error) => assert!(
            matches!(error, BacktraceError::Suspend(_) | BacktraceError::ThreadState(_)),
            "{error}"
        ),
    }
}

/// A stale capture signal arriving on another thread during a capture
/// never makes the real target's answer get lost (`timeout`) or answered
/// by the wrong thread.
#[cfg(target_os = "linux")]
#[test]
fn request_watchdog_stack_ignores_a_stale_signal_on_another_thread() {
    let bystander = Spinner::running(backtrace_test_bystander);
    let target = Spinner::start();
    capture(target.handle).expect("installs the handler");
    let stop = Arc::new(AtomicBool::new(false));
    let sent = Arc::new(AtomicU64::new(0));
    let bystander_tid = libc::pid_t::try_from(bystander.handle.raw()).unwrap();
    let signals = std::thread::spawn({
        let stop = stop.clone();
        let sent = sent.clone();
        move || {
            while !stop.load(Ordering::Relaxed) {
                // SAFETY: a signal to a live thread of this process whose
                // handler is installed.
                unsafe {
                    libc::syscall(libc::SYS_tgkill, libc::getpid(), bystander_tid, libc::SIGURG)
                };
                sent.fetch_add(1, Ordering::Relaxed);
            }
        }
    });
    // Capture while the stale signals flow: at least 300 captures over at
    // least 2,000 signals.
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut captures = 0;
    while captures < 300 || sent.load(Ordering::Relaxed) < 2_000 {
        assert!(Instant::now() < deadline, "{captures} captures, {sent:?} signals");
        let backtrace = capture(target.handle).expect("the target answers despite the signals");
        assert_in_function(backtrace.frames()[0], "backtrace_test_spin");
        captures += 1;
    }
    stop.store(true, Ordering::Relaxed);
    signals.join().unwrap();
}

#[test]
fn request_watchdog_stack_handle_round_trips_through_a_word() {
    assert_eq!(ThreadHandle::from_raw(0), None);
    let handle = ThreadHandle::current().expect("a thread handle");
    assert_eq!(ThreadHandle::from_raw(handle.raw()), Some(handle));
    assert_eq!(ThreadHandle::current(), Some(handle), "cached per thread");
}

#[test]
fn request_watchdog_stack_walk_stops_at_unreadable_or_descending_records() {
    // Records at 0x1000 -> 0x1100 -> 0x1080 (descends: stop).
    let read = |fp: usize| match fp {
        0x1000 => Some([0x1100, 0xaaa]),
        0x1100 => Some([0x1080, 0xbbb]),
        0x1080 => Some([0x1200, 0xccc]),
        _ => None,
    };
    let backtrace = walk(0x42, 0x1000, 0x0f00, read);
    assert_eq!(backtrace.frames(), &[0x42, 0xaaa, 0xbbb]);

    // An unreadable first record keeps only the pc.
    assert_eq!(walk(0x42, 0x9000, 0x0f00, |_| None).frames(), &[0x42]);
    // A frame pointer below the stack pointer is not followed.
    assert_eq!(walk(0x42, 0x0e00, 0x0f00, read).frames(), &[0x42]);
    // A cycle is bounded by the frame cap... and by the climb rule first.
    let cycle = |fp: usize| Some([fp, 0xddd]);
    assert_eq!(walk(0x42, 0x1000, 0x0f00, cycle).frames(), &[0x42, 0xddd]);
    // A long chain stops at MAX_FRAMES.
    let chain = |fp: usize| Some([fp + 16, 0xeee]);
    assert_eq!(walk(0x42, 0x1000, 0x0f00, chain).frames().len(), MAX_FRAMES);
}
