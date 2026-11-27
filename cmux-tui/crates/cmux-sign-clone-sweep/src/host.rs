//! This Mac's inputs to a pass: the `X` folder, this process's start, the
//! kernel's open-file answer, the installed apps and the volume's free space.

use std::ffi::{CStr, CString, OsStr, c_int, c_uint, c_ulong, c_void};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::{Budget, Probe, Report, Row, USER_FOLDERS_ROOT};

/// `_IOWR('A', 21, uint32_t)`: not in the SDK headers; Chromium defines it the
/// same way (code_sign_clone_manager.mm, macOS 10.15 and later).
const FSIOC_FD_ONLY_OPEN_ONCE: c_ulong = 0xC004_4115;

unsafe extern "C" {
    fn ffsctl(fd: c_int, request: c_ulong, data: *mut c_void, options: c_uint) -> c_int;
}

/// `confstr(_CS_DARWIN_USER_TEMP_DIR)`: the per-user temp folder, never `$TMPDIR`.
pub fn user_temp_dir() -> Option<PathBuf> {
    let mut buf = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: confstr writes at most `buf.len()` bytes, NUL included.
    let len = unsafe {
        libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len())
    };
    if len == 0 || len > buf.len() {
        return None;
    }
    let path = CStr::from_bytes_until_nul(&buf).ok()?.to_bytes();
    (!path.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(path)))
}

/// This user's `X` folder, resolved and checked (`crate::x_dir`).
pub fn x_dir() -> Option<PathBuf> {
    crate::x_dir(&user_temp_dir()?, Path::new(USER_FOLDERS_ROOT))
}

/// When this process started, from its own kernel record.
pub fn process_start() -> Option<SystemTime> {
    // SAFETY: proc_bsdinfo is plain old data; all zeroes is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as c_int;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info`.
    let got = unsafe {
        libc::proc_pidinfo(
            libc::getpid(),
            libc::PROC_PIDTBSDINFO,
            0,
            (&raw mut info).cast::<c_void>(),
            size,
        )
    };
    (got == size).then(|| {
        UNIX_EPOCH
            + Duration::from_secs(info.pbi_start_tvsec)
            + Duration::from_micros(info.pbi_start_tvusec)
    })
}

/// Free bytes for this user on the volume of `path`.
pub fn free_bytes(path: &Path) -> Option<i64> {
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: statvfs is plain old data; all zeroes is a valid value.
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is NUL-terminated and `stats` is writable.
    if unsafe { libc::statvfs(path.as_ptr(), &raw mut stats) } != 0 {
        return None;
    }
    i64::try_from(u64::from(stats.f_bavail).saturating_mul(stats.f_frsize)).ok()
}

/// Whether the file at `path` is open anywhere besides this check's own open
/// (Chromium's `IsFileOpenMoreThanOnce`); `None` when it cannot tell.
pub fn open_elsewhere(path: &Path) -> Option<bool> {
    let file = std::fs::File::open(path).ok()?;
    let mut value: u32 = 0;
    // SAFETY: the request reads and writes one u32, `value`.
    let result =
        unsafe { ffsctl(file.as_raw_fd(), FSIOC_FD_ONLY_OPEN_ONCE, (&raw mut value).cast(), 0) };
    if result == 0 {
        return Some(false);
    }
    (std::io::Error::last_os_error().raw_os_error() == Some(libc::EBUSY)).then_some(true)
}

/// The Mac's probe: the kernel's open-file answer, and the copies of an app in
/// /Applications and ~/Applications.
pub struct MacProbe;

impl Probe for MacProbe {
    fn open_elsewhere(&mut self, path: &Path) -> Option<bool> {
        open_elsewhere(path)
    }

    fn installed_apps(&mut self, app_name: &OsStr) -> Vec<PathBuf> {
        let mut roots = vec![PathBuf::from("/Applications")];
        if let Some(home) = std::env::var_os("HOME") {
            roots.push(Path::new(&home).join("Applications"));
        }
        roots.into_iter().map(|root| root.join(app_name)).collect()
    }
}

/// One pass on this Mac, clones made before `started` only, with the volume's
/// free-space change; `None` when the temp folder cannot be read.
pub fn run_pass(started: SystemTime, budget: Budget, dry_run: bool) -> Option<(Vec<Row>, Report)> {
    user_temp_dir()?;
    let Some(x) = x_dir() else {
        return Some((Vec::new(), Report::default()));
    };
    let before = free_bytes(&x);
    let (rows, mut report) = crate::pass(&x, started, budget, dry_run, &mut MacProbe);
    if let (Some(before), Some(after)) = (before, free_bytes(&x)) {
        report.free_space_delta_bytes = after.saturating_sub(before);
    }
    Some((rows, report))
}
