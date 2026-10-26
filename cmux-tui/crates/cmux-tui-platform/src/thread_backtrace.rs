//! Frame-pointer backtrace of another thread of this process, taken while it
//! runs: the daemon's request watchdog (cmux-tui-core
//! `server/request_watchdog.rs`) stores one with each request it records.
//!
//! Chrome's sampling profiler does the same job:
//! base/profiler/suspendable_thread_delegate_mac.cc stops the thread with
//! `thread_suspend`, reads its registers with `thread_get_state` and lets it
//! go with `thread_resume`; base/profiler/stack_copier_signal.cc interrupts
//! it with a signal on Linux and waits on a futex for the handler; and
//! base/profiler/frame_pointer_unwinder.cc walks the frame records. As in
//! Chrome, nothing here allocates or takes a lock while the target is
//! stopped (it may hold the allocator's lock), and every frame record is read
//! through the kernel (`mach_vm_read_overwrite`, `process_vm_readv`), so a
//! bad frame pointer ends the walk instead of faulting.
//!
//! The walk follows frame pointers, so it runs only in a build that keeps
//! them, as Chrome uses its frame-pointer unwinder only with
//! `enable_frame_pointers` (build/config/compiler/BUILD.gn). Apple's targets
//! always keep them. Linux targets omit them unless the build passes
//! `-C force-frame-pointers=yes` (build.rs then sets `cmux_frame_pointers`):
//! without them the frame-pointer register holds data, so a capture keeps
//! only the interrupted pc and says so ([`Backtrace::truncated`]). In a
//! frame-pointer build, a thread stopped inside code linked in without them
//! (a distribution's libc, the precompiled std) can still lose or add a frame
//! at that point, as with Chrome's unwinder.
//!
//! Symbols are resolved after the thread runs again
//! ([`Backtrace::symbolicate`]): each frame's image, the image's build id
//! (Mach-O `LC_UUID`, ELF `NT_GNU_BUILD_ID`; Chrome's
//! base/profiler/module_cache.h `Module::GetId`) and offset, which `atos` or
//! `addr2line` resolve offline against that exact build, and the dynamic
//! symbol when there is one.
//!
//! On Linux the signal interrupts a system call the thread is blocked in:
//! the handler is installed with SA_RESTART, so reads and writes restart,
//! while calls Linux never restarts (poll, epoll_wait, a timed futex wait,
//! nanosleep) return EINTR, which std and mio retry.
//!
//! The watched thread pays one thread-local read per request
//! ([`ThreadHandle::current`]); nothing runs and no handler is installed
//! until the first capture.

use std::fmt;
use std::time::Duration;

mod image_id;

/// The most frames a capture keeps, the interrupted pc first.
pub const MAX_FRAMES: usize = 32;

/// A thread of this process that [`capture`] can stop and walk: its Mach
/// thread port on macOS, its kernel thread id on Linux.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThreadHandle(u64);

impl ThreadHandle {
    /// The calling thread, or `None` where [`capture`] is unsupported. A
    /// thread-local read after the thread's first call.
    pub fn current() -> Option<Self> {
        Self::from_raw(imp::current_raw())
    }

    /// The handle stored by [`ThreadHandle::raw`]; `None` for 0.
    pub fn from_raw(raw: u64) -> Option<Self> {
        (raw != 0).then_some(Self(raw))
    }

    /// The handle as one word, never 0, for an atomic slot.
    pub fn raw(self) -> u64 {
        self.0
    }
}

/// Why a capture returned no frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BacktraceError {
    /// This OS or architecture has no capture.
    Unsupported,
    /// A thread cannot stop itself.
    CurrentThread,
    /// `thread_suspend` failed (the thread exited): its `kern_return_t`.
    Suspend(i32),
    /// `thread_get_state` failed: its `kern_return_t`.
    ThreadState(i32),
    /// Installing the handler or sending the signal failed (the thread
    /// exited): the errno.
    Signal(i32),
    /// The thread did not run the signal handler in time (it blocks the
    /// signal, was not scheduled, or is exiting).
    Timeout,
}

impl BacktraceError {
    /// A stable name for diagnostics output.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::CurrentThread => "current-thread",
            Self::Suspend(_) => "suspend-failed",
            Self::ThreadState(_) => "thread-state-failed",
            Self::Signal(_) => "signal-failed",
            Self::Timeout => "timeout",
        }
    }
}

impl fmt::Display for BacktraceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Suspend(code) | Self::ThreadState(code) | Self::Signal(code) => {
                write!(formatter, "{} ({code})", self.as_str())
            }
            _ => formatter.write_str(self.as_str()),
        }
    }
}

impl std::error::Error for BacktraceError {}

/// The frames of one capture: the interrupted pc, then return addresses,
/// innermost first. Fixed size, so a capture never allocates.
#[derive(Clone, Copy)]
pub struct Backtrace {
    frames: [usize; MAX_FRAMES],
    len: usize,
    truncated: bool,
    stopped: Duration,
}

impl fmt::Debug for Backtrace {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Backtrace")
            .field("frames", &self.frames().iter().map(|pc| format!("{pc:#x}")).collect::<Vec<_>>())
            .field("truncated", &self.truncated)
            .field("stopped", &self.stopped)
            .finish()
    }
}

impl Backtrace {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    const fn empty() -> Self {
        Self { frames: [0; MAX_FRAMES], len: 0, truncated: false, stopped: Duration::ZERO }
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn push(&mut self, address: usize) -> bool {
        if self.len == MAX_FRAMES {
            return false;
        }
        self.frames[self.len] = address;
        self.len += 1;
        true
    }

    /// The captured addresses, the interrupted pc first.
    pub fn frames(&self) -> &[usize] {
        &self.frames[..self.len]
    }

    /// The capture kept only the interrupted pc because this build has no
    /// frame pointers to walk (Linux without `-C force-frame-pointers=yes`):
    /// the callers are unknown, not absent.
    pub fn truncated(&self) -> bool {
        self.truncated
    }

    /// How long the capture kept the thread from its own work: from
    /// `thread_suspend` to `thread_resume` on macOS; on Linux from the
    /// handler's entry to its answer (the kernel's signal delivery is not
    /// counted, nor the time the thread waited to be scheduled).
    pub fn stopped(&self) -> Duration {
        self.stopped
    }

    /// Each frame's image, build id and offset, and its dynamic symbol when
    /// the image exports one. Call it after the capture: it takes the
    /// loader's lock.
    pub fn symbolicate(&self) -> Vec<SymbolicatedFrame> {
        // Each image's build id is read once per capture.
        let mut image_ids: Vec<(usize, Option<String>)> = Vec::new();
        self.frames()
            .iter()
            .enumerate()
            .map(|(index, &address)| {
                // A return address can be the first byte after its function
                // when the call was its last instruction: look up the call.
                let lookup = if index == 0 { address } else { address.saturating_sub(1) };
                let (mut frame, base) = imp::symbolicate(address, lookup);
                if let Some(base) = base {
                    frame.image_id = match image_ids.iter().find(|(known, _)| *known == base) {
                        Some((_, id)) => id.clone(),
                        None => {
                            let id = image_id::of(base, lookup);
                            image_ids.push((base, id.clone()));
                            id
                        }
                    };
                }
                frame
            })
            .collect()
    }
}

/// One frame of a [`Backtrace`], resolved against the loaded images.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SymbolicatedFrame {
    /// The captured address.
    pub address: usize,
    /// The file name of the image that holds it; `None` when no loaded image does.
    pub image: Option<String>,
    /// The build id of that image, which ties `offset` to one build: the
    /// Mach-O `LC_UUID` as `dwarfdump --uuid` prints it
    /// (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`), or the ELF
    /// `NT_GNU_BUILD_ID` in lowercase hex as `readelf -n` prints it; `None`
    /// when the image has none.
    pub image_id: Option<String>,
    /// The address minus the image's load address (the address itself
    /// without an image): `addr2line -e IMAGE OFFSET`, or `atos -o IMAGE -l
    /// 0x100000000 0x100000000+OFFSET` for a Mach-O image.
    pub offset: usize,
    /// The nearest exported symbol, mangled; `None` for a local function.
    pub symbol: Option<String>,
}

/// The image, build id, offset and dynamic symbol of one code address of
/// this process, as [`Backtrace::symbolicate`] resolves a pc.
pub fn symbolicate_address(address: usize) -> SymbolicatedFrame {
    let (mut frame, base) = imp::symbolicate(address, address);
    frame.image_id = base.and_then(|base| image_id::of(base, address));
    frame
}

/// Stop `thread`, walk its frame pointers and let it run again, in well
/// under a millisecond. On Linux captures run one at a time, since the
/// signal handler answers through one shared request; on macOS each capture
/// suspends only its own target, so captures from several threads overlap.
pub fn capture(thread: ThreadHandle) -> Result<Backtrace, BacktraceError> {
    if ThreadHandle::current() == Some(thread) {
        return Err(BacktraceError::CurrentThread);
    }
    imp::capture(thread)
}

/// A frame record is an aligned pair of words above the stack pointer; the
/// span bounds a corrupt chain, the reads themselves are checked.
#[cfg(any(target_os = "macos", target_os = "linux"))]
const MAX_STACK_SPAN: usize = 1 << 30;

/// Walk the frame records from `fp`: each holds the caller's frame pointer
/// and the return address. `read` reads one record and fails on unmapped
/// memory; the chain must climb the stack. Only for code built with frame
/// pointers: elsewhere `fp` is any value.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn walk(
    pc: usize,
    mut fp: usize,
    sp: usize,
    read: impl Fn(usize) -> Option<[usize; 2]>,
) -> Backtrace {
    let mut backtrace = Backtrace::empty();
    backtrace.push(strip_pointer_authentication(pc));
    let mut lowest = sp;
    while fp != 0
        && fp.is_multiple_of(size_of::<usize>())
        && fp >= lowest
        && fp - sp <= MAX_STACK_SPAN
        && let Some([caller_fp, return_address]) = read(fp)
    {
        let return_address = strip_pointer_authentication(return_address);
        if return_address == 0 || !backtrace.push(return_address) {
            break;
        }
        lowest = fp + 2 * size_of::<usize>();
        fp = caller_fp;
    }
    backtrace
}

/// arm64e system libraries sign the return addresses they save; the user
/// address space is 47 bits (Chrome's RemovePointerAuthenticationBits).
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn strip_pointer_authentication(address: usize) -> usize {
    address & ((1 << 47) - 1)
}

#[cfg(all(
    any(target_os = "macos", target_os = "linux"),
    not(all(target_os = "macos", target_arch = "aarch64"))
))]
fn strip_pointer_authentication(address: usize) -> usize {
    address
}

/// Image, offset and dynamic symbol of `address` through `dladdr`, with the
/// image's load address (`None` without an image).
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn dladdr_frame(address: usize, lookup: usize) -> (SymbolicatedFrame, Option<usize>) {
    use std::ffi::CStr;

    let mut info = std::mem::MaybeUninit::<libc::Dl_info>::zeroed();
    // SAFETY: dladdr only reads the loader's tables and fills `info`.
    let found = unsafe { libc::dladdr(lookup as *const libc::c_void, info.as_mut_ptr()) } != 0;
    // SAFETY: zeroed is a valid Dl_info, and dladdr wrote it when it found one.
    let info = unsafe { info.assume_init() };
    let text = |pointer: *const libc::c_char| {
        // SAFETY: dladdr's strings are NUL-terminated and live with the image.
        (!pointer.is_null())
            .then(|| unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned())
    };
    let base = info.dli_fbase as usize;
    if !found || base == 0 {
        let frame = SymbolicatedFrame {
            address,
            image: None,
            image_id: None,
            offset: address,
            symbol: None,
        };
        return (frame, None);
    }
    let image = text(info.dli_fname).map(|path| match path.rsplit_once('/') {
        Some((_, name)) => name.to_string(),
        None => path,
    });
    let frame = SymbolicatedFrame {
        address,
        image,
        image_id: None,
        offset: address.wrapping_sub(base),
        symbol: text(info.dli_sname),
    };
    (frame, Some(base))
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{Backtrace, BacktraceError, SymbolicatedFrame, ThreadHandle, walk};
    use std::cell::Cell;
    use std::time::Instant;

    const KERN_SUCCESS: libc::kern_return_t = 0;

    #[cfg(target_arch = "aarch64")]
    #[repr(C)]
    #[derive(Default)]
    struct ThreadState {
        x: [u64; 29],
        fp: u64,
        lr: u64,
        sp: u64,
        pc: u64,
        cpsr: u32,
        flags: u32,
    }

    /// `ARM_THREAD_STATE64` in <mach/arm/thread_status.h>.
    #[cfg(target_arch = "aarch64")]
    const THREAD_STATE_FLAVOR: libc::c_int = 6;

    #[cfg(target_arch = "x86_64")]
    #[repr(C)]
    #[derive(Default)]
    struct ThreadState {
        rax: u64,
        rbx: u64,
        rcx: u64,
        rdx: u64,
        rdi: u64,
        rsi: u64,
        rbp: u64,
        rsp: u64,
        r8_to_r15: [u64; 8],
        rip: u64,
        rflags: u64,
        cs: u64,
        fs: u64,
        gs: u64,
    }

    /// `x86_THREAD_STATE64` in <mach/i386/thread_status.h>.
    #[cfg(target_arch = "x86_64")]
    const THREAD_STATE_FLAVOR: libc::c_int = 4;

    impl ThreadState {
        /// pc, frame pointer and stack pointer.
        #[cfg(target_arch = "aarch64")]
        fn registers(&self) -> (usize, usize, usize) {
            (self.pc as usize, self.fp as usize, self.sp as usize)
        }

        #[cfg(target_arch = "x86_64")]
        fn registers(&self) -> (usize, usize, usize) {
            (self.rip as usize, self.rbp as usize, self.rsp as usize)
        }
    }

    unsafe extern "C" {
        /// This task's port, set by libSystem before main (<mach/mach_init.h>).
        static mach_task_self_: libc::mach_port_t;
        fn thread_suspend(thread: libc::thread_t) -> libc::kern_return_t;
        fn thread_resume(thread: libc::thread_t) -> libc::kern_return_t;
        fn thread_get_state(
            thread: libc::thread_t,
            flavor: libc::c_int,
            state: *mut libc::natural_t,
            count: *mut libc::mach_msg_type_number_t,
        ) -> libc::kern_return_t;
        fn mach_vm_read_overwrite(
            task: libc::mach_port_t,
            address: libc::mach_vm_address_t,
            size: libc::mach_vm_size_t,
            data: libc::mach_vm_address_t,
            out_size: *mut libc::mach_vm_size_t,
        ) -> libc::kern_return_t;
    }

    thread_local! {
        static CURRENT: Cell<u64> = const { Cell::new(0) };
    }

    pub(super) fn current_raw() -> u64 {
        CURRENT.with(|current| {
            if current.get() == 0 {
                // SAFETY: reads the calling thread's own kernel port name.
                let port = unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) };
                current.set(u64::from(port));
            }
            current.get()
        })
    }

    /// One frame record, or `None` when the memory is not readable.
    fn read_record(address: usize) -> Option<[usize; 2]> {
        let mut record = [0usize; 2];
        let mut read = 0;
        // SAFETY: the kernel copies into `record`, whose size is passed, and
        // fails instead of faulting on unmapped memory.
        let result = unsafe {
            mach_vm_read_overwrite(
                mach_task_self_,
                address as u64,
                size_of_val(&record) as u64,
                record.as_mut_ptr() as u64,
                &raw mut read,
            )
        };
        (result == KERN_SUCCESS && read == size_of_val(&record) as u64).then_some(record)
    }

    pub(super) fn capture(thread: ThreadHandle) -> Result<Backtrace, BacktraceError> {
        let Ok(port) = libc::thread_t::try_from(thread.raw()) else {
            return Err(BacktraceError::Unsupported);
        };
        let suspending = Instant::now();
        // SAFETY: a port name of this task's thread; a stale one fails.
        let suspended = unsafe { thread_suspend(port) };
        if suspended != KERN_SUCCESS {
            return Err(BacktraceError::Suspend(suspended));
        }
        // Until thread_resume nothing allocates or locks: the stopped thread
        // may hold the allocator's or the loader's lock.
        let mut state = ThreadState::default();
        let mut count = (size_of::<ThreadState>() / size_of::<libc::natural_t>())
            as libc::mach_msg_type_number_t;
        // SAFETY: `state` is the flavor's layout and `count` its size in words.
        let read = unsafe {
            thread_get_state(port, THREAD_STATE_FLAVOR, (&raw mut state).cast(), &raw mut count)
        };
        let backtrace = (read == KERN_SUCCESS).then(|| {
            let (pc, fp, sp) = state.registers();
            walk(pc, fp, sp, read_record)
        });
        // SAFETY: balances the successful thread_suspend above.
        unsafe { thread_resume(port) };
        let stopped = suspending.elapsed();
        let mut backtrace = backtrace.ok_or(BacktraceError::ThreadState(read))?;
        backtrace.stopped = stopped;
        Ok(backtrace)
    }

    pub(super) fn symbolicate(address: usize, lookup: usize) -> (SymbolicatedFrame, Option<usize>) {
        super::dladdr_frame(address, lookup)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{Backtrace, BacktraceError, MAX_FRAMES, SymbolicatedFrame, ThreadHandle, walk};
    use std::cell::Cell;
    use std::sync::atomic::{AtomicI32, AtomicU32, AtomicU64, AtomicUsize, Ordering};
    use std::sync::{Mutex, OnceLock, PoisonError};
    use std::time::{Duration, Instant};

    /// The signal that asks a thread for its frames: SIGURG, as Chrome's
    /// stack_copier_signal.cc. Ignored by default, and the kernel sends it
    /// only for TCP urgent data to a socket's F_SETOWN owner.
    const CAPTURE_SIGNAL: libc::c_int = libc::SIGURG;

    /// How long a capture waits for the handler to run.
    const ANSWER_TIMEOUT: Duration = Duration::from_millis(50);

    /// The build keeps frame pointers (build.rs), so the handler walks them;
    /// otherwise it keeps only the interrupted pc.
    const WALKS_FRAMES: bool = cfg!(cmux_frame_pointers);

    const FUTEX_WAIT_PRIVATE: libc::c_int = 128;
    const FUTEX_WAKE_PRIVATE: libc::c_int = 129;

    /// The request word: a capture generation above a two-bit phase, so a
    /// handler can claim only the request it read the target of.
    const PHASE: u32 = 0b11;
    const GENERATION: u32 = 1 << 2;
    const IDLE: u32 = 0;
    const REQUESTED: u32 = 1;
    const WALKING: u32 = 2;
    const DONE: u32 = 3;

    fn with_phase(word: u32, phase: u32) -> u32 {
        (word & !PHASE) | phase
    }

    /// The one capture in flight, shared with the signal handler through
    /// atomics only.
    struct Request {
        /// Generation and phase: IDLE -> REQUESTED (capturer, next
        /// generation) -> WALKING -> DONE (the target's handler) -> IDLE
        /// (capturer); a capturer that times out takes REQUESTED back to
        /// IDLE.
        state: AtomicU32,
        /// The thread asked, written before its generation is published.
        target: AtomicI32,
        len: AtomicUsize,
        frames: [AtomicUsize; MAX_FRAMES],
        /// How long the handler kept its thread from its work, in ns.
        handler_ns: AtomicU64,
    }

    static REQUEST: Request = Request {
        state: AtomicU32::new(IDLE),
        target: AtomicI32::new(0),
        len: AtomicUsize::new(0),
        frames: [const { AtomicUsize::new(0) }; MAX_FRAMES],
        handler_ns: AtomicU64::new(0),
    };

    /// CLOCK_MONOTONIC in ns; clock_gettime is async-signal-safe.
    fn monotonic_ns() -> u64 {
        let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: writes only `now`.
        unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut now) };
        let seconds = u64::try_from(now.tv_sec).unwrap_or(0);
        let nanos = u64::try_from(now.tv_nsec).unwrap_or(0);
        seconds.saturating_mul(1_000_000_000).saturating_add(nanos)
    }

    /// Lock carve-out: serializes capturing threads (request watchdogs),
    /// held for one capture (< 1 ms, at most ANSWER_TIMEOUT); never taken by
    /// a watched thread or the signal handler.
    static CAPTURES: Mutex<()> = Mutex::new(());

    /// The handler installed by the first capture, with the one it replaced:
    /// Ok((previous sa_sigaction, previous sa_flags)) or the sigaction errno.
    static INSTALLED: OnceLock<Result<(usize, libc::c_int), i32>> = OnceLock::new();

    thread_local! {
        static CURRENT: Cell<u64> = const { Cell::new(0) };
    }

    pub(super) fn current_raw() -> u64 {
        CURRENT.with(|current| {
            if current.get() == 0 {
                // SAFETY: gettid has no preconditions.
                let tid = unsafe { libc::gettid() };
                current.set(u64::try_from(tid).unwrap_or(0));
            }
            current.get()
        })
    }

    fn errno() -> i32 {
        std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
    }

    fn install() -> Result<(), BacktraceError> {
        let installed = INSTALLED.get_or_init(|| {
            // SAFETY: a zeroed sigaction is valid; the handler only uses
            // async-signal-safe calls and atomics.
            unsafe {
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = handler as *const () as usize;
                action.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
                libc::sigemptyset(&raw mut action.sa_mask);
                let mut previous: libc::sigaction = std::mem::zeroed();
                if libc::sigaction(CAPTURE_SIGNAL, &raw const action, &raw mut previous) != 0 {
                    return Err(errno());
                }
                Ok((previous.sa_sigaction, previous.sa_flags))
            }
        });
        installed.map(|_| ()).map_err(BacktraceError::Signal)
    }

    /// One frame record, or `None` when the memory is not readable.
    /// process_vm_readv is a plain system call, safe in the handler.
    fn read_record(address: usize) -> Option<[usize; 2]> {
        let mut record = [0usize; 2];
        let local =
            libc::iovec { iov_base: record.as_mut_ptr().cast(), iov_len: size_of_val(&record) };
        let remote =
            libc::iovec { iov_base: address as *mut libc::c_void, iov_len: size_of_val(&record) };
        // SAFETY: the kernel writes only `local` and fails on unmapped `remote`.
        let read = unsafe {
            libc::process_vm_readv(libc::getpid(), &raw const local, 1, &raw const remote, 1, 0)
        };
        (usize::try_from(read).ok() == Some(size_of_val(&record))).then_some(record)
    }

    /// pc, frame pointer and stack pointer of the interrupted code.
    ///
    /// # Safety
    /// `context` is the handler's `ucontext_t`.
    #[cfg(target_arch = "x86_64")]
    unsafe fn registers(context: *const libc::ucontext_t) -> (usize, usize, usize) {
        // SAFETY: the kernel passes a valid ucontext_t to an SA_SIGINFO handler.
        let registers = unsafe { &(*context).uc_mcontext.gregs };
        (
            registers[libc::REG_RIP as usize] as usize,
            registers[libc::REG_RBP as usize] as usize,
            registers[libc::REG_RSP as usize] as usize,
        )
    }

    #[cfg(target_arch = "aarch64")]
    unsafe fn registers(context: *const libc::ucontext_t) -> (usize, usize, usize) {
        // SAFETY: the kernel passes a valid ucontext_t to an SA_SIGINFO handler.
        let context = unsafe { &(*context).uc_mcontext };
        (context.pc as usize, context.regs[29] as usize, context.sp as usize)
    }

    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    unsafe fn registers(_context: *const libc::ucontext_t) -> (usize, usize, usize) {
        (0, 0, 0)
    }

    fn futex_wake(word: &AtomicU32) {
        // SAFETY: a futex wake on a live atomic; safe in a signal handler.
        unsafe { libc::syscall(libc::SYS_futex, word.as_ptr(), FUTEX_WAKE_PRIVATE, i32::MAX) };
    }

    fn futex_wait(word: &AtomicU32, expected: u32, timeout: Duration) {
        let timeout = libc::timespec {
            tv_sec: libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX),
            tv_nsec: libc::c_long::from(timeout.subsec_nanos() as i32),
        };
        // SAFETY: the kernel sleeps only while the word still holds `expected`.
        unsafe {
            libc::syscall(
                libc::SYS_futex,
                word.as_ptr(),
                FUTEX_WAIT_PRIVATE,
                expected,
                &raw const timeout,
            )
        };
    }

    extern "C" fn handler(
        signal: libc::c_int,
        info: *mut libc::siginfo_t,
        context: *mut libc::c_void,
    ) {
        // SAFETY: errno is thread-local; restored so the interrupted code
        // never sees the handler's system calls.
        let saved_errno = unsafe { *libc::__errno_location() };
        // SAFETY: the kernel passes valid `info` and `context` with SA_SIGINFO.
        if !unsafe { answer(info, context) } {
            // SAFETY: forwards the same arguments to the handler we replaced.
            unsafe { chain(signal, info, context) };
        }
        // SAFETY: as above.
        unsafe { *libc::__errno_location() = saved_errno };
    }

    /// Walk this thread's frames if the signal is our request for them.
    ///
    /// # Safety
    /// `info` and `context` are the handler's arguments.
    unsafe fn answer(info: *const libc::siginfo_t, context: *const libc::c_void) -> bool {
        let entered = monotonic_ns();
        // SAFETY: valid siginfo_t from the kernel; getpid is a system call.
        let sent_here =
            unsafe { (*info).si_code == libc::SI_TKILL && (*info).si_pid() == libc::getpid() };
        if !sent_here {
            return false;
        }
        // Read the request, then its target (published before it), and
        // claim only that generation: a late signal from an earlier capture,
        // on another thread, leaves the request alone for its target.
        let request = REQUEST.state.load(Ordering::Acquire);
        // SAFETY: gettid is a system call.
        if request & PHASE != REQUESTED
            || REQUEST.target.load(Ordering::Relaxed) != unsafe { libc::gettid() }
        {
            return true;
        }
        if REQUEST
            .state
            .compare_exchange(
                request,
                with_phase(request, WALKING),
                Ordering::Acquire,
                Ordering::Relaxed,
            )
            .is_err()
        {
            // That request timed out; a newer one for this thread sends its
            // own signal, delivered when this handler returns.
            return true;
        }
        // SAFETY: the handler's ucontext_t.
        let (pc, fp, sp) = unsafe { registers(context.cast()) };
        let backtrace = if WALKS_FRAMES {
            walk(pc, fp, sp, read_record)
        } else {
            let mut backtrace = Backtrace::empty();
            backtrace.push(pc);
            backtrace
        };
        for (slot, &address) in REQUEST.frames.iter().zip(backtrace.frames()) {
            slot.store(address, Ordering::Relaxed);
        }
        REQUEST.len.store(backtrace.len, Ordering::Relaxed);
        REQUEST.handler_ns.store(monotonic_ns().saturating_sub(entered), Ordering::Relaxed);
        REQUEST.state.store(with_phase(request, DONE), Ordering::Release);
        futex_wake(&REQUEST.state);
        true
    }

    /// Run the handler that was installed before ours, if any.
    ///
    /// # Safety
    /// The handler's own arguments.
    unsafe fn chain(signal: libc::c_int, info: *mut libc::siginfo_t, context: *mut libc::c_void) {
        let Some(Ok((previous, flags))) = INSTALLED.get().copied() else { return };
        if previous == libc::SIG_DFL || previous == libc::SIG_IGN {
            return;
        }
        if flags & libc::SA_SIGINFO != 0 {
            // SAFETY: sigaction stored an SA_SIGINFO handler of this type.
            let previous: extern "C" fn(libc::c_int, *mut libc::siginfo_t, *mut libc::c_void) =
                unsafe { std::mem::transmute(previous) };
            previous(signal, info, context);
        } else {
            // SAFETY: sigaction stored a plain handler of this type.
            let previous: extern "C" fn(libc::c_int) = unsafe { std::mem::transmute(previous) };
            previous(signal);
        }
    }

    pub(super) fn capture(thread: ThreadHandle) -> Result<Backtrace, BacktraceError> {
        let Ok(tid) = libc::pid_t::try_from(thread.raw()) else {
            return Err(BacktraceError::Unsupported);
        };
        install()?;
        let _serial = CAPTURES.lock().unwrap_or_else(PoisonError::into_inner);
        // Every earlier request is IDLE now: this one is the next generation.
        let idle = REQUEST.state.load(Ordering::Relaxed);
        let request = with_phase(idle.wrapping_add(GENERATION), REQUESTED);
        REQUEST.target.store(tid, Ordering::Relaxed);
        // Release publishes the target with the request (see `answer`).
        REQUEST.state.store(request, Ordering::Release);
        let signalled = Instant::now();
        // SAFETY: tgkill names this process, so a stale tid cannot reach another one.
        if unsafe { libc::syscall(libc::SYS_tgkill, libc::getpid(), tid, CAPTURE_SIGNAL) } != 0 {
            let error = errno();
            REQUEST.state.store(with_phase(request, IDLE), Ordering::Release);
            return Err(BacktraceError::Signal(error));
        }
        let deadline = signalled + ANSWER_TIMEOUT;
        loop {
            let state = REQUEST.state.load(Ordering::Acquire);
            if state == with_phase(request, DONE) {
                break;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if state == request && remaining.is_zero() {
                if REQUEST
                    .state
                    .compare_exchange(
                        request,
                        with_phase(request, IDLE),
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    )
                    .is_ok()
                {
                    return Err(BacktraceError::Timeout);
                }
                continue;
            }
            // A walking handler finishes in bounded time: wait it out.
            let wait =
                if state == with_phase(request, WALKING) { ANSWER_TIMEOUT } else { remaining };
            futex_wait(&REQUEST.state, state, wait);
        }
        let mut backtrace = Backtrace::empty();
        let len = REQUEST.len.load(Ordering::Relaxed);
        for slot in &REQUEST.frames[..len.min(MAX_FRAMES)] {
            backtrace.push(slot.load(Ordering::Relaxed));
        }
        backtrace.stopped = Duration::from_nanos(REQUEST.handler_ns.load(Ordering::Relaxed));
        REQUEST.state.store(with_phase(request, IDLE), Ordering::Release);
        backtrace.truncated = !WALKS_FRAMES;
        Ok(backtrace)
    }

    pub(super) fn symbolicate(address: usize, lookup: usize) -> (SymbolicatedFrame, Option<usize>) {
        super::dladdr_frame(address, lookup)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::{Backtrace, BacktraceError, SymbolicatedFrame, ThreadHandle};

    pub(super) fn current_raw() -> u64 {
        0
    }

    pub(super) fn capture(_thread: ThreadHandle) -> Result<Backtrace, BacktraceError> {
        Err(BacktraceError::Unsupported)
    }

    pub(super) fn symbolicate(
        address: usize,
        _lookup: usize,
    ) -> (SymbolicatedFrame, Option<usize>) {
        let frame = SymbolicatedFrame {
            address,
            image: None,
            image_id: None,
            offset: address,
            symbol: None,
        };
        (frame, None)
    }
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
#[path = "thread_backtrace_tests.rs"]
mod tests;
