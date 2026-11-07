//! macOS processes from libproc: `proc_listallpids`, `proc_pidinfo`
//! (`PROC_PIDTBSDINFO`: the start time), `KERN_PROCARGS2` (the executable
//! and arguments) and `proc_pid_rusage` (`RUSAGE_INFO_V4`: user and system
//! time in mach ticks, package idle and interrupt wakeups, phys_footprint).
//!
//! Reading another process's counters adds no wakeup to it: the kernel
//! answers from its own bookkeeping.

use std::ffi::{c_int, c_void};
use std::sync::OnceLock;

use super::Usage;

const PROC_PIDTBSDINFO: c_int = 3;
const RUSAGE_INFO_V4: c_int = 4;
const CTL_KERN: c_int = 1;
const KERN_ARGMAX: c_int = 8;
const KERN_PROCARGS2: c_int = 49;

#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

/// `struct proc_bsdinfo` of `<sys/proc_info.h>`; only the start time is read.
#[repr(C)]
#[allow(dead_code)]
struct ProcBsdInfo {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
    comm: [u8; 16],
    name: [u8; 32],
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    tdev: u32,
    tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
}

unsafe extern "C" {
    fn mach_timebase_info(info: *mut MachTimebase) -> c_int;
    fn proc_listallpids(buffer: *mut c_void, size: c_int) -> c_int;
    fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *mut c_void, size: c_int)
    -> c_int;
    fn proc_pidpath(pid: c_int, buffer: *mut c_void, size: u32) -> c_int;
    fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *mut *mut c_void) -> c_int;
}

/// (numer, denom) of mach ticks to nanoseconds.
fn timebase() -> (u64, u64) {
    static TIMEBASE: OnceLock<(u64, u64)> = OnceLock::new();
    *TIMEBASE.get_or_init(|| {
        let mut info = MachTimebase { numer: 0, denom: 0 };
        // SAFETY: `info` is a valid out pointer for the call.
        let status = unsafe { mach_timebase_info(&mut info) };
        if status != 0 || info.denom == 0 { (1, 1) } else { (info.numer.into(), info.denom.into()) }
    })
}

type Responsible = unsafe extern "C" fn(c_int) -> c_int;

/// `responsibility_get_pid_responsible_for_pid`, a private libSystem call:
/// looked up once, so an OS without it only loses WebKit attribution.
fn responsibility() -> Option<Responsible> {
    static FUNCTION: OnceLock<Option<Responsible>> = OnceLock::new();
    *FUNCTION.get_or_init(|| {
        // SAFETY: dlsym with RTLD_DEFAULT and a NUL-terminated name.
        let symbol = unsafe {
            libc::dlsym(libc::RTLD_DEFAULT, c"responsibility_get_pid_responsible_for_pid".as_ptr())
        };
        // SAFETY: the symbol, when present, has this C signature (pid_t -> pid_t).
        (!symbol.is_null())
            .then(|| unsafe { std::mem::transmute::<*mut c_void, Responsible>(symbol) })
    })
}

pub(super) fn responsibility_available() -> bool {
    responsibility().is_some()
}

pub(super) fn responsible(pid: i32) -> Option<i32> {
    let function = responsibility()?;
    // SAFETY: the call takes any pid and returns a pid or -1.
    let answer = unsafe { function(pid) };
    (answer > 0).then_some(answer)
}

fn all_pids() -> Vec<i32> {
    // SAFETY: a null buffer asks for the count only.
    let count = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    let mut pids = vec![0i32; count as usize + 64];
    let bytes = (pids.len() * size_of::<i32>()) as c_int;
    // SAFETY: `pids` holds `bytes` bytes.
    let filled = unsafe { proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    pids.truncate(filled.max(0) as usize);
    pids.retain(|pid| *pid > 0);
    pids
}

fn start_time(pid: i32) -> Option<u64> {
    let mut info = std::mem::MaybeUninit::<ProcBsdInfo>::zeroed();
    let size = size_of::<ProcBsdInfo>() as c_int;
    // SAFETY: `info` holds `size` bytes.
    let written = unsafe { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size) };
    if written != size {
        return None;
    }
    // SAFETY: the kernel filled all of it; any bit pattern is valid for these fields.
    let info = unsafe { info.assume_init() };
    Some(info.start_tvsec * 1_000_000 + info.start_tvusec)
}

/// The executable's path, then the arguments after argv[0], from
/// `KERN_PROCARGS2`: argc, the exec path, NUL padding, then argv.
pub(super) fn command(pid: i32) -> Option<String> {
    let mut argmax: c_int = 0;
    let mut size = size_of::<c_int>();
    let mut name = [CTL_KERN, KERN_ARGMAX];
    // SAFETY: `argmax` is `size` bytes.
    let status = unsafe {
        libc::sysctl(
            name.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 || argmax <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; argmax as usize];
    let mut size = buffer.len();
    let mut name = [CTL_KERN, KERN_PROCARGS2, pid];
    // SAFETY: `buffer` is `size` bytes.
    let status = unsafe {
        libc::sysctl(
            name.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    super::parse_procargs(&buffer[..size.min(buffer.len())])
}

pub(super) fn executable(pid: i32) -> Option<std::path::PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    // PROC_PIDPATHINFO_MAXSIZE.
    let mut buffer = vec![0u8; 4096];
    // SAFETY: `buffer` holds its length in bytes.
    let length = unsafe { proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    buffer.truncate(length as usize);
    Some(std::path::PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

/// (pid, start time) of every process.
pub(super) fn list() -> Vec<(i32, u64)> {
    all_pids().into_iter().filter_map(|pid| Some((pid, start_time(pid)?))).collect()
}

pub(super) fn usage(pid: i32) -> Option<Usage> {
    // RUSAGE_INFO_V4 in u64 words: uuid (2), user, system (mach ticks), pkg idle
    // wakeups, interrupt wakeups, pageins, wired, resident (8), phys_footprint (9), ...
    let mut words = [0u64; 64];
    // SAFETY: `words` is larger than rusage_info_v4; the call writes into it.
    let status = unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V4, words.as_mut_ptr().cast()) };
    if status != 0 {
        return None;
    }
    let (numer, denom) = timebase();
    let ticks = u128::from(words[2]) + u128::from(words[3]);
    Some(Usage {
        cpu_ns: u64::try_from(ticks * u128::from(numer) / u128::from(denom)).unwrap_or(u64::MAX),
        wakeups: words[4] + words[5],
        memory: words[9],
    })
}
