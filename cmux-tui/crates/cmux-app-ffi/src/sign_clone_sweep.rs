//! Removes the Chromium code-sign clones that cmux apps left behind
//! (`include/cmux_sign_clone_sweep.h`, Swift module `CCmuxSignCloneSweepFFI`).
//!
//! Chromium's code-sign clone (chrome/browser/mac/code_sign_clone_manager.mm)
//! copies the app bundle per launch to
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)/../X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX/<App>.app.bundle`,
//! with the main executable as a hard link and every other file an APFS clone.
//! Only its destructor, near the end of `CefShutdown`, removes that copy; a quit
//! past the app's shutdown deadline, a skipped `CefShutdown`, a signal, a crash
//! or an update restart never gets there (Chromium's own TODO,
//! crbug.com/343784575). The clone itself stays on; this removes the leftovers.
//!
//! Scope: only the clone roots of the cmux bundle-id family in that one `X`
//! folder, which must resolve under `/private/var/folders/`. The family is
//! `com.cmuxterm.app` and every plain `com.cmuxterm.app.*` id (release,
//! `.nightly`, `.debug` and `.debug.<tag>` dev builds), the rule cmux-link's
//! `sign_clone.rs` already uses. A clone is removed only when its one cloned
//! bundle's `Info.plist` names the same family id as its root, so another
//! Chromium app's clones beside ours are never touched.
//!
//! Liveness: a clone exists to run the helpers (GPU, network service,
//! renderers) of the browser that made it, and the browser keeps those running
//! from it for its whole life. A clone is in use while any of its executables is
//! open anywhere: Chromium's own `IsFileOpenMoreThanOnce` test
//! (`FSIOC_FD_ONLY_OPEN_ONCE`, kept for crbug.com/343784575); a running program
//! holds its executable open. That answers for every instance and channel, this
//! one included, without listing or reading any process
//! (plans/cmux-next/pty-holder.md, section 4). The hard-linked main executable
//! is skipped: it is the installed app's own file and is open whenever that app
//! runs, so it says nothing about the clone. An unknown answer keeps the clone.
//! Clones made after this process started are also kept, which closes the short
//! window in which a launching instance has made its clone but not yet started a
//! helper.
//!
//! Each pass removes at most `max_clones` clones and stops once it has reclaimed
//! `max_bytes`, oldest first, so a large backlog goes over a few passes.

use std::ffi::OsStr;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Every clone folder's name: this prefix and `SUFFIX_LEN` characters.
const CLONE_PREFIX: &str = "code_sign_clone.";
/// `mkdtemp`'s `XXXXXX` in Chromium's template.
const SUFFIX_LEN: usize = 6;
/// A clone root's name: `<bundle id>` and this suffix.
const ROOT_SUFFIX: &str = ".code_sign_clone";
/// The family's base bundle id (cmux.xcodeproj PRODUCT_BUNDLE_IDENTIFIER).
const FAMILY: &str = "com.cmuxterm.app";
/// Where macOS keeps per-user temp folders; an `X` folder elsewhere is refused.
pub const USER_FOLDERS_ROOT: &str = "/private/var/folders/";
/// The largest `Info.plist` read; an app's is a few kilobytes.
const MAX_INFO_PLIST: u64 = 1 << 20;

/// One pass's result (`CmuxSignCloneSweepReport` in the header).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxSignCloneSweepReport {
    /// Blocks of the removed entries that had no other name (`st_blocks * 512`
    /// of single-link entries): what the removal frees, short of APFS clone
    /// blocks still shared with the installed app.
    pub reclaimed_bytes: u64,
    /// The volume's free space after the pass minus before it.
    pub free_space_delta_bytes: i64,
    /// Clones removed.
    pub removed: u32,
    /// Clones kept because something runs from them.
    pub kept_in_use: u32,
    /// Clones kept because their bundle is not the family id of their root.
    pub kept_foreign: u32,
    /// Whether the pass stopped at its budget with clones left to check.
    pub more: bool,
}

/// One pass's limits.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub max_bytes: u64,
    pub max_clones: u32,
}

/// Whether `bundle_id` may name a folder: letters, digits, `.`, `-` and `_`,
/// no empty part. A path separator or `..` never passes.
fn plain_bundle_id(bundle_id: &str) -> bool {
    !bundle_id.is_empty()
        && bundle_id.split('.').all(|part| {
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
}

/// Whether `bundle_id` is a cmux app: `com.cmuxterm.app` or a plain
/// `com.cmuxterm.app.*` id.
pub fn in_family(bundle_id: &str) -> bool {
    plain_bundle_id(bundle_id)
        && (bundle_id == FAMILY
            || bundle_id.strip_prefix(FAMILY).is_some_and(|rest| rest.starts_with('.')))
}

/// Whether `name` is a clone folder's name: `code_sign_clone.` and six
/// characters of the portable filename set `mkdtemp` draws from.
pub fn is_clone_name(name: &OsStr) -> bool {
    name.to_str().and_then(|name| name.strip_prefix(CLONE_PREFIX)).is_some_and(|suffix| {
        suffix.len() == SUFFIX_LEN
            && suffix.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    })
}

/// The `X` folder beside `user_temp` (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
/// with every link and `..` resolved. `None` when it does not exist or does not
/// resolve under `allowed_root` (`USER_FOLDERS_ROOT` in the app).
pub fn x_dir(user_temp: &Path, allowed_root: &Path) -> Option<PathBuf> {
    let x = user_temp.join("..").join("X").canonicalize().ok()?;
    let allowed_root = allowed_root.canonicalize().ok()?;
    (x != allowed_root && x.starts_with(&allowed_root) && x.is_dir()).then_some(x)
}

/// The family's clone roots in `x`: real folders named `<family id>.code_sign_clone`.
pub fn family_roots(x: &Path) -> Vec<(String, PathBuf)> {
    let Ok(entries) = std::fs::read_dir(x) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name();
            let id = name.to_str()?.strip_suffix(ROOT_SUFFIX)?;
            let real_dir = entry.file_type().ok()?.is_dir();
            (real_dir && in_family(id)).then(|| (id.to_owned(), x.join(&name)))
        })
        .collect()
}

/// `CFBundleIdentifier` of an `Info.plist`, XML or binary.
pub fn bundle_identifier(plist: &[u8]) -> Option<String> {
    if plist.starts_with(b"bplist00") {
        return binary_plist_string(plist, "CFBundleIdentifier");
    }
    let text = std::str::from_utf8(plist).ok()?;
    let (_, after_key) = text.split_once("<key>CFBundleIdentifier</key>")?;
    let value = after_key.trim_start().strip_prefix("<string>")?;
    let (value, _) = value.split_once("</string>")?;
    Some(value.trim().to_owned())
}

/// A big-endian unsigned integer of `size` bytes at `offset`.
fn read_uint(data: &[u8], offset: usize, size: usize) -> Option<u64> {
    if size == 0 || size > 8 {
        return None;
    }
    let bytes = data.get(offset..offset.checked_add(size)?)?;
    Some(bytes.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
}

/// A big-endian unsigned integer as a `usize`.
fn read_usize(data: &[u8], offset: usize, size: usize) -> Option<usize> {
    usize::try_from(read_uint(data, offset, size)?).ok()
}

/// The string value of `key` in a binary plist's top-level dictionary.
fn binary_plist_string(data: &[u8], key: &str) -> Option<String> {
    let trailer = data.len().checked_sub(32)?;
    let offset_size = usize::from(*data.get(trailer + 6)?);
    let ref_size = usize::from(*data.get(trailer + 7)?);
    let objects = read_usize(data, trailer + 8, 8)?;
    let top = read_usize(data, trailer + 16, 8)?;
    let table = read_usize(data, trailer + 24, 8)?;
    let object_offset = |index: usize| -> Option<usize> {
        if index >= objects {
            return None;
        }
        read_usize(data, table.checked_add(index.checked_mul(offset_size)?)?, offset_size)
    };
    // A marker's count: its low nibble, or the integer object after it when 0xF.
    let count = |at: usize| -> Option<(usize, usize)> {
        let marker = *data.get(at)?;
        if marker & 0x0F != 0x0F {
            return Some((usize::from(marker & 0x0F), at + 1));
        }
        let int_marker = *data.get(at + 1)?;
        if int_marker >> 4 != 0x1 {
            return None;
        }
        let size = 1usize << (int_marker & 0x0F);
        Some((read_usize(data, at + 2, size)?, at + 2 + size))
    };
    let string_at = |index: usize| -> Option<String> {
        let at = object_offset(index)?;
        let marker = *data.get(at)?;
        let (len, start) = count(at)?;
        match marker >> 4 {
            0x5 => {
                let bytes = data.get(start..start.checked_add(len)?)?;
                std::str::from_utf8(bytes).ok().map(str::to_owned)
            }
            0x6 => {
                let bytes = data.get(start..start.checked_add(len.checked_mul(2)?)?)?;
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|pair| match pair {
                        [high, low] => u16::from_be_bytes([*high, *low]),
                        _ => 0,
                    })
                    .collect();
                String::from_utf16(&units).ok()
            }
            _ => None,
        }
    };
    let dict = object_offset(top)?;
    if *data.get(dict)? >> 4 != 0xD {
        return None;
    }
    let (entries, keys) = count(dict)?;
    let values = keys.checked_add(entries.checked_mul(ref_size)?)?;
    for i in 0..entries {
        let key_ref = read_usize(data, keys.checked_add(i.checked_mul(ref_size)?)?, ref_size)?;
        if string_at(key_ref).as_deref() == Some(key) {
            let value_at = values.checked_add(i.checked_mul(ref_size)?)?;
            return string_at(read_usize(data, value_at, ref_size)?);
        }
    }
    None
}

/// Whether the clone at `clone` holds exactly one bundle (`*.app.bundle`, a
/// real folder) whose `Info.plist` names `bundle_id`.
fn bundle_is(clone: &Path, bundle_id: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(clone) else {
        return false;
    };
    let bundles: Vec<PathBuf> = entries
        .flatten()
        .filter(|entry| {
            entry.file_type().is_ok_and(|t| t.is_dir())
                && entry.file_name().to_str().is_some_and(|name| name.ends_with(".app.bundle"))
        })
        .map(|entry| entry.path())
        .collect();
    let [bundle] = bundles.as_slice() else {
        return false;
    };
    let plist = bundle.join("Contents/Info.plist");
    let Ok(meta) = std::fs::symlink_metadata(&plist) else {
        return false;
    };
    if !meta.is_file() || meta.len() > MAX_INFO_PLIST {
        return false;
    }
    std::fs::read(&plist)
        .ok()
        .and_then(|bytes| bundle_identifier(&bytes))
        .is_some_and(|id| id == bundle_id && in_family(&id))
}

/// Walks the clone at `clone`: `None` when anything in it may be in use (an
/// executable with one name that `open_elsewhere` does not answer `Some(false)`
/// for, or a folder that cannot be read), else the bytes its single-name
/// entries hold. Links are never followed; files with more than one name (the
/// hard-linked main executable) are neither asked nor counted.
pub fn scan_clone(
    clone: &Path,
    mut open_elsewhere: impl FnMut(&Path) -> Option<bool>,
) -> Option<u64> {
    let mut bytes = 0u64;
    let mut folders = vec![clone.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(&folder).ok()? {
            let path = entry.ok()?.path();
            let meta = std::fs::symlink_metadata(&path).ok()?;
            if meta.nlink() == 1 || meta.is_dir() {
                bytes = bytes.saturating_add(meta.blocks().saturating_mul(512));
            }
            if meta.is_dir() {
                folders.push(path);
            } else if meta.is_file()
                && meta.nlink() == 1
                && meta.permissions().mode() & 0o111 != 0
                && open_elsewhere(&path) != Some(false)
            {
                return None;
            }
        }
    }
    Some(bytes)
}

/// When the folder `meta` describes was created (its change time on a file
/// system without birth times) or last changed, whichever is later.
fn last_touched(meta: &std::fs::Metadata) -> Option<SystemTime> {
    let modified = meta.modified().ok()?;
    let created = meta.created().unwrap_or(modified);
    Some(created.max(modified))
}

/// One pass over the family's clones in `x` (a resolved `x_dir`): removes, oldest
/// first, each clone that was made before `started`, whose bundle is its root's
/// family id and that nothing runs from (`scan_clone` with `open_elsewhere`),
/// within `budget`. `free_space_delta_bytes` is left for the caller.
pub fn sweep(
    x: &Path,
    started: SystemTime,
    budget: Budget,
    mut open_elsewhere: impl FnMut(&Path) -> Option<bool>,
) -> CmuxSignCloneSweepReport {
    let mut candidates = Vec::new();
    for (id, root) in family_roots(x) {
        let Ok(entries) = std::fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            if !is_clone_name(&entry.file_name()) {
                continue;
            }
            let path = entry.path();
            // symlink_metadata: a link named like a clone is never followed.
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            match last_touched(&meta) {
                Some(touched) if meta.is_dir() && touched < started => {
                    candidates.push((touched, id.clone(), path));
                }
                _ => {}
            }
        }
    }
    candidates.sort();
    let mut report = CmuxSignCloneSweepReport::default();
    for (_, id, clone) in candidates {
        if report.removed >= budget.max_clones || report.reclaimed_bytes >= budget.max_bytes {
            report.more = true;
            break;
        }
        if !bundle_is(&clone, &id) {
            report.kept_foreign += 1;
            continue;
        }
        let Some(bytes) = scan_clone(&clone, &mut open_elsewhere) else {
            report.kept_in_use += 1;
            continue;
        };
        if std::fs::remove_dir_all(&clone).is_ok() {
            report.removed += 1;
            report.reclaimed_bytes = report.reclaimed_bytes.saturating_add(bytes);
        }
    }
    report
}

#[cfg(target_os = "macos")]
mod host {
    use std::ffi::{CStr, CString, OsStr, c_int, c_uint, c_ulong, c_void};
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    /// `_IOWR('A', 21, uint32_t)`: not in the SDK headers; Chromium defines it
    /// the same way (code_sign_clone_manager.mm, macOS 10.15 and later).
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

    /// Whether the file at `path` is open anywhere besides this check's own
    /// open (Chromium's `IsFileOpenMoreThanOnce`); `None` when it cannot tell.
    pub fn open_elsewhere(path: &Path) -> Option<bool> {
        let file = std::fs::File::open(path).ok()?;
        let mut value: u32 = 0;
        // SAFETY: the request reads and writes one u32, `value`.
        let result = unsafe {
            ffsctl(file.as_raw_fd(), FSIOC_FD_ONLY_OPEN_ONCE, (&raw mut value).cast(), 0)
        };
        if result == 0 {
            return Some(false);
        }
        (std::io::Error::last_os_error().raw_os_error() == Some(libc::EBUSY)).then_some(true)
    }
}

/// The pass with this Mac's inputs; `None` when nothing could be checked.
#[cfg(target_os = "macos")]
fn sweep_host(budget: Budget) -> Option<CmuxSignCloneSweepReport> {
    let user_temp = host::user_temp_dir()?;
    let started = host::process_start()?;
    let Some(x) = x_dir(&user_temp, Path::new(USER_FOLDERS_ROOT)) else {
        return Some(CmuxSignCloneSweepReport::default());
    };
    let before = host::free_bytes(&x);
    let mut report = sweep(&x, started, budget, host::open_elsewhere);
    if let (Some(before), Some(after)) = (before, host::free_bytes(&x)) {
        report.free_space_delta_bytes = after.saturating_sub(before);
    }
    Some(report)
}

#[cfg(not(target_os = "macos"))]
fn sweep_host(_budget: Budget) -> Option<CmuxSignCloneSweepReport> {
    Some(CmuxSignCloneSweepReport::default())
}

/// One pass over the stale Chromium code-sign clones of every cmux app on this
/// Mac (module docs). Run it at idle, off the main thread, in the launch's
/// last stage; while `out->more`, run another pass later. Removes at most
/// `max_clones` clones and stops once `max_bytes` are reclaimed. Returns false,
/// with `*out` zeroed, when the temp folder or this process's start time cannot
/// be read (nothing is removed then).
///
/// # Safety
/// `out` is null or points to a writable `CmuxSignCloneSweepReport`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sign_clone_sweep(
    max_bytes: u64,
    max_clones: u32,
    out: *mut CmuxSignCloneSweepReport,
) -> bool {
    let result = sweep_host(Budget { max_bytes, max_clones });
    // SAFETY: `out` is null or writable per the contract above.
    if let Some(out) = unsafe { out.as_mut() } {
        *out = result.unwrap_or_default();
    }
    result.is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Child, Command};
    use std::time::Duration;

    const NO_LIMIT: Budget = Budget { max_bytes: u64::MAX, max_clones: u32::MAX };

    /// A fresh folder with an `X` folder in it under the system temp dir,
    /// removed on drop.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(tag: &str) -> Self {
            let nanos =
                SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
            let dir = std::env::temp_dir()
                .join(format!("sign-clone-sweep-{tag}-{}-{nanos}", std::process::id()));
            std::fs::create_dir_all(dir.join("X")).unwrap();
            Self(dir.canonicalize().unwrap())
        }

        fn x(&self) -> PathBuf {
            self.0.join("X")
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A child process running from an executable; killed on drop.
    struct Running(Child);

    impl Drop for Running {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// A clone of `bundle_id`'s app, its `Info.plist` naming `plist_id`, with a
    /// helper executable (a copy of `sleep`, so it can run) in `x`; returns the
    /// clone and the helper.
    fn make_clone(x: &Path, bundle_id: &str, plist_id: &str, suffix: &str) -> (PathBuf, PathBuf) {
        let clone = x.join(format!("{bundle_id}.code_sign_clone/code_sign_clone.{suffix}"));
        let contents = clone.join("cmux NIGHTLY.app.bundle/Contents");
        let helper_dir = contents.join("Frameworks/cmux Helper.app/Contents/MacOS");
        std::fs::create_dir_all(&helper_dir).unwrap();
        std::fs::write(
            contents.join("Info.plist"),
            format!(
                "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict>\n\
                 <key>CFBundleIdentifier</key>\n\t<string>{plist_id}</string>\n</dict></plist>\n"
            ),
        )
        .unwrap();
        let helper = helper_dir.join("cmux Helper");
        std::fs::copy("/bin/sleep", &helper).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        (clone, helper)
    }

    /// Another app instance: a process running the clone's helper.
    fn run_from(helper: &Path) -> Running {
        let child = Running(Command::new(helper).arg("60").spawn().unwrap());
        std::thread::sleep(Duration::from_millis(200));
        child
    }

    /// Linux's form of the kernel's "a program runs this file" answer, for the
    /// tests: opening a running executable for writing fails with ETXTBSY.
    fn text_busy(path: &Path) -> Option<bool> {
        const ETXTBSY: i32 = 26;
        match std::fs::OpenOptions::new().write(true).open(path) {
            Ok(_) => Some(false),
            Err(error) if error.raw_os_error() == Some(ETXTBSY) => Some(true),
            Err(_) => None,
        }
    }

    /// Birth and change times are whole ticks of the file system's clock.
    fn tick() {
        std::thread::sleep(Duration::from_millis(50));
    }

    #[test]
    fn sign_clone_sweep_removes_only_the_old_unused_clone() {
        let scratch = Scratch::new("regression");
        let x = scratch.x();
        let id = "com.cmuxterm.app.nightly";
        // Earlier launches: one left over, one whose instance still runs.
        let (old, _) = make_clone(&x, id, id, "OldAbc");
        let (busy, busy_helper) = make_clone(&x, id, id, "Busy12");
        let other_instance = run_from(&busy_helper);
        tick();
        let started = SystemTime::now();
        tick();
        // This launch's own clone, made after the process started.
        let (own, _) = make_clone(&x, id, id, "New_99");

        let report = sweep(&x, started, NO_LIMIT, text_busy);

        assert!(!old.exists(), "the leftover clone goes");
        assert!(busy.exists(), "a clone another instance runs from stays");
        assert!(own.exists(), "this launch's clone stays");
        assert_eq!((report.removed, report.kept_in_use), (1, 1), "{report:?}");
        assert!(report.reclaimed_bytes > 0, "{report:?}");
        drop(other_instance);
    }

    #[test]
    fn sign_clone_sweep_two_instances_keep_each_others_clone_until_exit() {
        let scratch = Scratch::new("two-instances");
        let x = scratch.x();
        // A release and a nightly running side by side, both older than this sweep.
        let (release, release_helper) = make_clone(&x, FAMILY, FAMILY, "RelAaa");
        let nightly_id = "com.cmuxterm.app.nightly";
        let (nightly, nightly_helper) = make_clone(&x, nightly_id, nightly_id, "NigBbb");
        let release_instance = run_from(&release_helper);
        let nightly_instance = run_from(&nightly_helper);
        tick();

        let report = sweep(&x, SystemTime::now(), NO_LIMIT, text_busy);
        assert_eq!((report.removed, report.kept_in_use), (0, 2), "{report:?}");
        assert!(release.exists() && nightly.exists());

        // The nightly quits: its clone is now a leftover; the release's stays.
        drop(nightly_instance);
        let report = sweep(&x, SystemTime::now(), NO_LIMIT, text_busy);
        assert_eq!((report.removed, report.kept_in_use), (1, 1), "{report:?}");
        assert!(!nightly.exists());
        assert!(release.exists(), "the running release keeps its clone");
        drop(release_instance);
    }

    #[test]
    fn sign_clone_sweep_never_touches_another_apps_clones() {
        let scratch = Scratch::new("foreign");
        let x = scratch.x();
        // Another Chromium app's root beside ours, a look-alike id, and a clone
        // under a family root whose bundle is not that id.
        let browser = "org.example.Browser";
        let (other_app, _) = make_clone(&x, browser, browser, "Foreig");
        let (lookalike, _) = make_clone(&x, "com.cmuxterm.appx", "com.cmuxterm.appx", "Looks1");
        let tag = "com.cmuxterm.app.debug.tag";
        let (mislabeled, _) = make_clone(&x, tag, browser, "Mislab");
        let (ours, _) = make_clone(&x, tag, tag, "Ours12");
        tick();

        let report = sweep(&x, SystemTime::now(), NO_LIMIT, text_busy);

        assert!(other_app.exists() && lookalike.exists() && mislabeled.exists());
        assert!(!ours.exists());
        assert_eq!((report.removed, report.kept_foreign), (1, 1), "{report:?}");
    }

    #[test]
    fn sign_clone_sweep_stops_at_its_budget_and_finishes_in_later_passes() {
        let scratch = Scratch::new("budget");
        let x = scratch.x();
        let id = "com.cmuxterm.app.debug";
        let root = x.join(format!("{id}.code_sign_clone"));
        for suffix in ["aaaaa1", "aaaaa2", "aaaaa3"] {
            make_clone(&x, id, id, suffix);
            tick();
        }
        let two = Budget { max_bytes: u64::MAX, max_clones: 2 };
        let first = sweep(&x, SystemTime::now(), two, text_busy);
        assert_eq!((first.removed, first.more), (2, true), "{first:?}");
        assert!(root.join("code_sign_clone.aaaaa3").exists(), "oldest first");
        let second = sweep(&x, SystemTime::now(), two, text_busy);
        assert_eq!((second.removed, second.more), (1, false), "{second:?}");
        // A byte budget stops the pass once reached.
        for suffix in ["bbbbb1", "bbbbb2"] {
            make_clone(&x, id, id, suffix);
        }
        tick();
        let one_byte = Budget { max_bytes: 1, max_clones: u32::MAX };
        let third = sweep(&x, SystemTime::now(), one_byte, text_busy);
        assert_eq!((third.removed, third.more), (1, true), "{third:?}");
    }

    #[test]
    fn sign_clone_sweep_skips_other_names_files_and_links() {
        let scratch = Scratch::new("names");
        let x = scratch.x();
        let root = x.join("com.cmuxterm.app.code_sign_clone");
        std::fs::create_dir_all(&root).unwrap();
        let outside = scratch.0.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        for name in ["code_sign_clone.short", "code_sign_clone.toolong7", "other.abcdef"] {
            std::fs::create_dir_all(root.join(name)).unwrap();
        }
        std::fs::write(root.join("code_sign_clone.file01"), b"").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("code_sign_clone.link01")).unwrap();
        // A family root that is a link is not followed either.
        let dev = "com.cmuxterm.app.dev";
        let (linked_clone, _) = make_clone(&outside, dev, dev, "Linked");
        std::os::unix::fs::symlink(
            outside.join(format!("{dev}.code_sign_clone")),
            x.join(format!("{dev}.code_sign_clone")),
        )
        .unwrap();
        tick();
        let report = sweep(&x, SystemTime::now(), NO_LIMIT, text_busy);
        assert_eq!(report, CmuxSignCloneSweepReport::default());
        assert!(outside.is_dir() && linked_clone.exists(), "a link is never followed");
    }

    #[test]
    fn sign_clone_scan_asks_only_single_name_executables() {
        let scratch = Scratch::new("scan");
        let clone = scratch.0.join("code_sign_clone.abcdef");
        let helper = clone.join("b.app.bundle/Contents/Frameworks/h.app/Contents/MacOS/h");
        std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
        std::fs::write(&helper, b"exe").unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        // Not executable: never asked.
        std::fs::write(clone.join("b.app.bundle/Contents/Info.plist"), b"").unwrap();
        // The hard-linked main executable: the installed app's own file, never asked.
        let installed = scratch.0.join("installed-main");
        std::fs::write(&installed, b"main").unwrap();
        std::fs::set_permissions(&installed, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::create_dir_all(clone.join("b.app.bundle/Contents/MacOS")).unwrap();
        std::fs::hard_link(&installed, clone.join("b.app.bundle/Contents/MacOS/b")).unwrap();
        // A link to a file outside: never followed.
        std::os::unix::fs::symlink(&installed, clone.join("link")).unwrap();

        let mut asked = Vec::new();
        let bytes = scan_clone(&clone, |file| {
            asked.push(file.to_path_buf());
            Some(false)
        });
        assert!(bytes.is_some());
        assert_eq!(asked, vec![helper.clone()]);
        assert_eq!(scan_clone(&clone, |_| Some(true)), None, "an open helper keeps the clone");
        assert_eq!(scan_clone(&clone, |_| None), None, "an unknown answer keeps the clone");
        assert_eq!(scan_clone(&scratch.0.join("missing"), |_| Some(false)), None);
    }

    #[test]
    fn sign_clone_family_is_the_cmux_ids_only() {
        for good in [
            "com.cmuxterm.app",
            "com.cmuxterm.app.nightly",
            "com.cmuxterm.app.nightly.cmux-next",
            "com.cmuxterm.app.debug",
            "com.cmuxterm.app.debug.pr-123_tag",
        ] {
            assert!(in_family(good), "{good}");
        }
        for bad in [
            "",
            "com.cmuxterm.appx",
            "com.cmuxterm.app.",
            "com.cmuxterm.app..x",
            "com.cmuxterm.app.a/b",
            "org.example.Browser",
            "xcom.cmuxterm.app",
        ] {
            assert!(!in_family(bad), "{bad}");
        }
    }

    #[test]
    fn sign_clone_name_is_prefix_and_six_mkdtemp_characters() {
        for good in ["code_sign_clone.9gP34C", "code_sign_clone.a.b_c-", "code_sign_clone.tKdILk"] {
            assert!(is_clone_name(OsStr::new(good)), "{good}");
        }
        for bad in [
            "code_sign_clone.",
            "code_sign_clone.abc",
            "code_sign_clone.abcdefg",
            "code_sign_clone.ab cd!",
            "x.code_sign_clone.abcdef",
        ] {
            assert!(!is_clone_name(OsStr::new(bad)), "{bad}");
        }
    }

    #[test]
    fn sign_clone_x_dir_resolves_only_under_the_allowed_root() {
        let scratch = Scratch::new("root");
        let allowed = scratch.0.join("folders");
        let user_temp = allowed.join("ab/cd/T");
        let x = allowed.join("ab/cd/X");
        std::fs::create_dir_all(&user_temp).unwrap();
        std::fs::create_dir_all(&x).unwrap();
        assert_eq!(x_dir(&user_temp, &allowed), Some(x.clone()));
        let elsewhere = scratch.0.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        assert_eq!(x_dir(&user_temp, &elsewhere), None);
        // An X that links out of the allowed root is resolved before the check.
        let other = allowed.join("ef/gh");
        std::fs::create_dir_all(other.join("T")).unwrap();
        std::os::unix::fs::symlink(scratch.x(), other.join("X")).unwrap();
        assert_eq!(x_dir(&other.join("T"), &allowed), None);
        assert_eq!(x_dir(&allowed.join("missing/T"), &allowed), None);
    }

    #[test]
    fn sign_clone_bundle_identifier_reads_xml_and_binary_plists() {
        let xml = b"<?xml version=\"1.0\"?><plist><dict><key>CFBundleName</key>\
                    <string>cmux</string><key>CFBundleIdentifier</key>\n  \
                    <string>com.cmuxterm.app</string></dict></plist>";
        assert_eq!(bundle_identifier(xml).as_deref(), Some("com.cmuxterm.app"));
        // plistlib.dumps({...}, fmt=FMT_BINARY) of CFBundleExecutable, CFBundleIdentifier
        // (com.cmuxterm.app.nightly) and LSMinimumSystemVersion.
        let binary = hex(
            "62706c6973743030d30102030405065f1012434642756e646c6545786563757461626c655f10124346\
             42756e646c654964656e7469666965725f10164c534d696e696d756d53797374656d56657273696f6e\
             54636d75785f1018636f6d2e636d75787465726d2e6170702e6e696768746c795431342e30080f2439\
             5257720000000000000101000000000000000700000000000000000000000000000077",
        );
        assert_eq!(bundle_identifier(&binary).as_deref(), Some("com.cmuxterm.app.nightly"));
        let cut = [&binary[..40], &binary[..binary.len() - 1], b"bplist00".as_slice(), b""];
        for truncated in cut {
            assert_eq!(bundle_identifier(truncated), None);
        }
    }

    fn hex(text: &str) -> Vec<u8> {
        let digits: Vec<u8> = text.bytes().filter(u8::is_ascii_hexdigit).collect();
        digits
            .chunks(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn sign_clone_report_layout_matches_the_header() {
        use std::mem::{offset_of, size_of};
        type R = CmuxSignCloneSweepReport;
        assert_eq!(size_of::<R>(), 32);
        assert_eq!(
            [
                offset_of!(R, reclaimed_bytes),
                offset_of!(R, free_space_delta_bytes),
                offset_of!(R, removed),
                offset_of!(R, kept_in_use),
                offset_of!(R, kept_foreign),
                offset_of!(R, more),
            ],
            [0, 8, 16, 20, 24, 28]
        );
    }

    #[test]
    fn sign_clone_sweep_ffi_tolerates_a_null_report() {
        // SAFETY: a null report is allowed by the contract.
        assert!(unsafe { cmux_sign_clone_sweep(0, 0, std::ptr::null_mut()) });
    }
}
