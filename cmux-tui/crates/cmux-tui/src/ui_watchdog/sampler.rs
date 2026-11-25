//! A stack sample of the UI thread, taken from the watchdog thread.
//!
//! The watchdog sends the UI thread `SIGURG` (default: ignored, so no other code relies on it;
//! the handler is installed only while nothing else handles it). The handler walks its own stack
//! with `backtrace::trace_unsynchronized` into a fixed buffer of raw addresses and returns; the
//! watchdog waits up to 100 ms for it and names the frames afterwards, off the UI thread.
//!
//! Best effort, and said so: the unwinder may take a loader lock, so a UI thread stopped inside
//! the loader itself could wait in the handler; that hang is then a hang like any other, and the
//! restart bound ends it. The sample is warmed once on the UI thread at install, so the unwinder's
//! caches are built before any signal.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const MAX_FRAMES: usize = 64;
const SIGNAL: libc::c_int = libc::SIGURG;

static FRAMES: [AtomicUsize; MAX_FRAMES] = [const { AtomicUsize::new(0) }; MAX_FRAMES];
static FRAME_COUNT: AtomicUsize = AtomicUsize::new(0);
static REQUESTED: AtomicBool = AtomicBool::new(false);
static DONE: AtomicBool = AtomicBool::new(false);
/// The sampled thread's `pthread_self`, as an integer.
static TARGET: AtomicUsize = AtomicUsize::new(0);
static INSTALLED: AtomicBool = AtomicBool::new(false);

fn pthread_id(thread: libc::pthread_t) -> usize {
    thread as usize
}

extern "C" fn on_signal(_: libc::c_int) {
    // SAFETY: pthread_self is async-signal-safe.
    let me = pthread_id(unsafe { libc::pthread_self() });
    if me != TARGET.load(Ordering::Acquire) || !REQUESTED.swap(false, Ordering::AcqRel) {
        return;
    }
    let mut count = 0;
    // SAFETY: the unsynchronized trace takes no Rust lock; it writes only to the static buffer.
    unsafe {
        backtrace::trace_unsynchronized(|frame| {
            FRAMES[count].store(frame.ip() as usize, Ordering::Relaxed);
            count += 1;
            count < MAX_FRAMES
        });
    }
    FRAME_COUNT.store(count, Ordering::Release);
    DONE.store(true, Ordering::Release);
}

/// Samples one thread (the one that made it).
pub(crate) struct Sampler {
    /// `pthread_self` of the sampled thread, as an integer (a pointer on macOS is not `Send`).
    thread: usize,
}

impl Sampler {
    /// A sampler of the calling thread; `None` when the signal is taken by someone else.
    pub(crate) fn for_current_thread() -> Option<Self> {
        if !INSTALLED.load(Ordering::Acquire) {
            // SAFETY: sigaction with zeroed then filled structs; the previous one is only read.
            unsafe {
                let mut previous: libc::sigaction = std::mem::zeroed();
                if libc::sigaction(SIGNAL, std::ptr::null(), &mut previous) != 0 {
                    return None;
                }
                if previous.sa_sigaction != libc::SIG_DFL && previous.sa_sigaction != libc::SIG_IGN
                {
                    return None;
                }
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = on_signal as *const () as libc::sighandler_t;
                action.sa_flags = libc::SA_RESTART;
                libc::sigemptyset(&mut action.sa_mask);
                if libc::sigaction(SIGNAL, &action, std::ptr::null_mut()) != 0 {
                    return None;
                }
            }
            INSTALLED.store(true, Ordering::Release);
        }
        // Warm the unwinder here, on the UI thread, before any signal asks it to run.
        backtrace::trace(|_| false);
        // SAFETY: pthread_self has no preconditions.
        let thread = pthread_id(unsafe { libc::pthread_self() });
        Some(Sampler { thread })
    }

    /// The sampled thread's stack now, innermost first (empty when it did not answer in time).
    pub(crate) fn sample(&self) -> Vec<usize> {
        // One sample at a time in the process: the buffer and flags are shared.
        static SAMPLING: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _one = SAMPLING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        DONE.store(false, Ordering::Release);
        FRAME_COUNT.store(0, Ordering::Release);
        TARGET.store(self.thread, Ordering::Release);
        REQUESTED.store(true, Ordering::Release);
        // SAFETY: the thread is alive while its watchdog runs (the watchdog stops before the loop
        // thread returns from `run`).
        if unsafe { libc::pthread_kill(self.thread as libc::pthread_t, SIGNAL) } != 0 {
            REQUESTED.store(false, Ordering::Release);
            return Vec::new();
        }
        let until = Instant::now() + Duration::from_millis(100);
        while !DONE.load(Ordering::Acquire) {
            if Instant::now() >= until {
                REQUESTED.store(false, Ordering::Release);
                return Vec::new();
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let count = FRAME_COUNT.load(Ordering::Acquire).min(MAX_FRAMES);
        let frames = FRAMES[..count].iter().map(|frame| frame.load(Ordering::Relaxed)).collect();
        skip_signal_frames(frames)
    }
}

/// Drops the handler's own frames : the sample starts at
/// the frame the UI thread was in.
fn skip_signal_frames(frames: Vec<usize>) -> Vec<usize> {
    let handler = on_signal as *const () as usize;
    let position = frames.iter().position(|ip| {
        let mut is_handler = false;
        backtrace::resolve(*ip as *mut std::ffi::c_void, |symbol| {
            is_handler |= symbol.addr().is_some_and(|addr| addr as usize == handler);
        });
        is_handler
    });
    match position {
        // Everything after the handler: the kernel's trampoline, then the interrupted frame.
        Some(index) if index + 1 < frames.len() => frames[index + 1..].to_vec(),
        _ => frames,
    }
}

/// One line per frame: `#n 0xADDR name`, named when the binary still has symbols.
pub(crate) fn describe(frames: &[usize]) -> Vec<String> {
    frames
        .iter()
        .enumerate()
        .map(|(index, ip)| {
            let mut name = None;
            backtrace::resolve(*ip as *mut std::ffi::c_void, |symbol| {
                if name.is_none() {
                    name = symbol.name().map(|name| format!("{name:#}"));
                }
            });
            match name {
                Some(name) => format!("#{index} {ip:#x} {name}"),
                None => format!("#{index} {ip:#x}"),
            }
        })
        .collect()
}
