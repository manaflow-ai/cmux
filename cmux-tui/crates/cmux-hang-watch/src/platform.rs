//! What the watch asks the OS: the watcher's QoS, a thread's native id and its CPU time.

/// The watcher's class (threading-model.md: utility). A macOS thread starts at its creator's class.
/// Linux: the thread keeps its creator's nice value.
#[cfg(target_vendor = "apple")]
pub(crate) fn run_at_utility_qos() {
    // SAFETY: sets the calling thread's own QoS class; no pointer arguments.
    unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0) };
}

#[cfg(not(target_vendor = "apple"))]
pub(crate) fn run_at_utility_qos() {}

#[cfg(target_vendor = "apple")]
pub(crate) fn native_thread_id() -> u64 {
    // SAFETY: pthread_self has no preconditions and its result is the calling thread's handle.
    u64::from(unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn native_thread_id() -> u64 {
    // SAFETY: gettid has no arguments and no preconditions.
    let tid = unsafe { libc::syscall(libc::SYS_gettid) };
    u64::try_from(tid).unwrap_or(0)
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "linux", target_os = "android"))))]
pub(crate) fn native_thread_id() -> u64 {
    // SAFETY: pthread_self has no preconditions.
    unsafe { libc::pthread_self() as usize as u64 }
}

#[cfg(windows)]
pub(crate) fn native_thread_id() -> u64 {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        safe fn GetCurrentThreadId() -> u32;
    }
    u64::from(GetCurrentThreadId())
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn native_thread_id() -> u64 {
    0
}

/// The thread's user and system time, from `thread_info` on its Mach port.
#[cfg(target_vendor = "apple")]
pub(crate) fn thread_cpu_ns(native_thread_id: u64) -> Option<u64> {
    let port = libc::mach_port_t::try_from(native_thread_id).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::thread_basic_info>::zeroed();
    let mut count = libc::THREAD_BASIC_INFO_COUNT;
    // SAFETY: `info` has room for THREAD_BASIC_INFO_COUNT integers and `count` says so; the call
    // writes at most that many. A port that is no longer a thread fails with an error code.
    let status = unsafe {
        libc::thread_info(
            port,
            libc::THREAD_BASIC_INFO as libc::thread_flavor_t,
            info.as_mut_ptr().cast(),
            &mut count,
        )
    };
    if status != libc::KERN_SUCCESS {
        return None;
    }
    // SAFETY: the call succeeded, so it filled the struct.
    let info = unsafe { info.assume_init() };
    let ns = |time: libc::time_value_t| -> Option<u64> {
        Some(
            u64::try_from(time.seconds).ok()? * 1_000_000_000
                + u64::try_from(time.microseconds).ok()? * 1_000,
        )
    };
    Some(ns(info.user_time)? + ns(info.system_time)?)
}

/// The thread's CPU clock, the id glibc's `pthread_getcpuclockid` builds from a tid (the kernel's
/// `MAKE_THREAD_CPUCLOCK(tid, CPUCLOCK_SCHED)`).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn thread_cpu_ns(native_thread_id: u64) -> Option<u64> {
    let tid = u32::try_from(native_thread_id).ok()?;
    let clock = ((!tid) << 3) as libc::clockid_t | 6;
    let mut time = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `time` is a valid timespec to write; an id that is no longer a thread of this
    // process fails with EINVAL.
    if unsafe { libc::clock_gettime(clock, &mut time) } != 0 {
        return None;
    }
    Some(u64::try_from(time.tv_sec).ok()? * 1_000_000_000 + u64::try_from(time.tv_nsec).ok()?)
}

/// The thread's kernel and user time, from `GetThreadTimes` on a handle opened by its id.
#[cfg(windows)]
pub(crate) fn thread_cpu_ns(native_thread_id: u64) -> Option<u64> {
    use std::ffi::c_void;

    #[repr(C)]
    #[derive(Default)]
    struct FileTime {
        low: u32,
        high: u32,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenThread(access: u32, inherit: i32, thread_id: u32) -> *mut c_void;
        fn GetThreadTimes(
            thread: *mut c_void,
            creation: *mut FileTime,
            exit: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> i32;
        fn CloseHandle(handle: *mut c_void) -> i32;
    }
    const THREAD_QUERY_LIMITED_INFORMATION: u32 = 0x0800;

    let thread_id = u32::try_from(native_thread_id).ok()?;
    // SAFETY: OpenThread takes plain values and returns null on failure.
    let thread = unsafe { OpenThread(THREAD_QUERY_LIMITED_INFORMATION, 0, thread_id) };
    if thread.is_null() {
        return None;
    }
    let [mut creation, mut exit, mut kernel, mut user] = <[FileTime; 4]>::default();
    // SAFETY: `thread` is the open handle above and each pointer is a FILETIME to write.
    let read = unsafe { GetThreadTimes(thread, &mut creation, &mut exit, &mut kernel, &mut user) };
    // SAFETY: `thread` is open and closed once, here.
    unsafe { CloseHandle(thread) };
    // FILETIME counts 100 ns intervals.
    let ns = |time: FileTime| ((u64::from(time.high) << 32) | u64::from(time.low)) * 100;
    (read != 0).then(|| ns(kernel) + ns(user))
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android", windows)))]
pub(crate) fn thread_cpu_ns(_native_thread_id: u64) -> Option<u64> {
    None
}
