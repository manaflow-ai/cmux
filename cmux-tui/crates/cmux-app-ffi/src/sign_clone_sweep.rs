//! Removes Chromium's stale code-sign clones (`include/cmux_sign_clone_sweep.h`,
//! Swift module `CCmuxSignCloneSweepFFI`).
//!
//! Chromium's code-sign clone (chrome/browser/mac/code_sign_clone_manager.mm)
//! copies the app bundle per launch to
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)/../X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX`,
//! with the main executable as a hard link. Only its destructor, near the end of
//! `CefShutdown`, removes that copy; a quit past the app's shutdown deadline, a
//! skipped `CefShutdown`, a signal, a crash or an update restart never gets there
//! (Chromium's own TODO, crbug.com/343784575). Each leftover clone is about a
//! whole bundle and keeps the executable of the build it came from on disk.
//!
//! The clone itself stays on; this removes the leftovers once per launch. A clone
//! is removed only when all of these hold: its name is `code_sign_clone.` and the
//! six characters `mkdtemp` writes; it is a real folder, not a link; it was
//! created and last changed before this process started; and none of its
//! executables is in use, since helpers and the agent host may run from a clone.
//!
//! "In use" is Chromium's own test for this (`IsFileOpenMoreThanOnce`, the
//! `FSIOC_FD_ONLY_OPEN_ONCE` file system control, kept for crbug.com/343784575):
//! a running program holds its executable's file open, so opening it again
//! makes it open more than once. No process is listed or read
//! (plans/cmux-next/pty-holder.md, section 4). The hard-linked main executable
//! is skipped: it is the installed app's own file, open whenever that app
//! runs, and says nothing about the clone.

use std::ffi::{CStr, OsStr, c_char};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Every clone folder's name: this prefix and `SUFFIX_LEN` characters.
const CLONE_PREFIX: &str = "code_sign_clone.";
/// `mkdtemp`'s `XXXXXX` in Chromium's template.
const SUFFIX_LEN: usize = 6;
/// Where macOS keeps per-user temp folders; a clone root elsewhere is refused.
pub const USER_FOLDERS_ROOT: &str = "/private/var/folders/";

/// Whether `bundle_id` may name a folder: letters, digits, `.`, `-` and `_`,
/// no empty part. A path separator or `..` never passes.
fn plain_bundle_id(bundle_id: &str) -> bool {
    !bundle_id.is_empty()
        && bundle_id.split('.').all(|part| {
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
}

/// Whether `name` is a clone folder's name: `code_sign_clone.` and six
/// characters of the portable filename set `mkdtemp` draws from.
pub fn is_clone_name(name: &OsStr) -> bool {
    name.to_str().and_then(|name| name.strip_prefix(CLONE_PREFIX)).is_some_and(|suffix| {
        suffix.len() == SUFFIX_LEN
            && suffix.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    })
}

/// The folder Chromium clones `bundle_id` into, `<user_temp>/../X/<bundle_id>.code_sign_clone`,
/// with every link and `..` resolved. `None` when `bundle_id` is not a plain
/// identifier, the folder does not exist, or it does not resolve under
/// `allowed_root` (`USER_FOLDERS_ROOT` in the app).
pub fn clone_root(user_temp: &Path, bundle_id: &str, allowed_root: &Path) -> Option<PathBuf> {
    if !plain_bundle_id(bundle_id) {
        return None;
    }
    let root = user_temp
        .join("..")
        .join("X")
        .join(format!("{bundle_id}.code_sign_clone"))
        .canonicalize()
        .ok()?;
    let allowed_root = allowed_root.canonicalize().ok()?;
    (root != allowed_root && root.starts_with(&allowed_root) && root.is_dir()).then_some(root)
}

/// Whether the folder at `path` was created and last changed before `started`.
/// A file system without birth times answers by the change time alone.
fn older_than(meta: &std::fs::Metadata, started: SystemTime) -> bool {
    let Ok(modified) = meta.modified() else {
        return false;
    };
    let created = meta.created().unwrap_or(modified);
    created < started && modified < started
}

/// Whether anything in the clone at `clone` may be in use: `open_elsewhere`
/// answers for each executable file in it (`Some(true)` open elsewhere,
/// `Some(false)` not, `None` unknown). Links are never followed and files with
/// more than one name (the main executable Chromium hard-links) are skipped. An
/// unknown answer or a folder that cannot be read counts as in use.
pub fn clone_in_use(clone: &Path, mut open_elsewhere: impl FnMut(&Path) -> Option<bool>) -> bool {
    let mut folders = vec![clone.to_path_buf()];
    while let Some(folder) = folders.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else {
            return true;
        };
        for entry in entries {
            let Ok(entry) = entry else {
                return true;
            };
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                return true;
            };
            if meta.is_dir() {
                folders.push(path);
            } else if meta.is_file()
                && meta.permissions().mode() & 0o111 != 0
                && meta.nlink() == 1
                && open_elsewhere(&path) != Some(false)
            {
                return true;
            }
        }
    }
    false
}

/// Removes the stale clones in `root`, a resolved clone root (`clone_root`):
/// each entry named like a clone, a real folder, created and changed before
/// `started`, and not `in_use` (`clone_in_use` in the app). Returns the folders
/// it removed; one it could not remove is left for the next launch.
pub fn sweep(
    root: &Path,
    started: SystemTime,
    mut in_use: impl FnMut(&Path) -> bool,
) -> Vec<PathBuf> {
    // Nothing removes a stale clone yet: the regression test below is red.
    let _ = (root, started, &mut in_use);
    Vec::new()
}

#[cfg(target_os = "macos")]
mod host {
    use std::ffi::{CStr, OsStr, c_int, c_uint, c_ulong, c_void};
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

/// The sweep with this Mac's inputs; the number of clones removed, or -1 when
/// nothing could be checked.
#[cfg(target_os = "macos")]
fn sweep_host(bundle_id: &str) -> i32 {
    let Some(user_temp) = host::user_temp_dir() else {
        return -1;
    };
    let Some(root) = clone_root(&user_temp, bundle_id, Path::new(USER_FOLDERS_ROOT)) else {
        return 0;
    };
    let Some(started) = host::process_start() else {
        return -1;
    };
    let removed = sweep(&root, started, |clone| clone_in_use(clone, host::open_elsewhere));
    i32::try_from(removed.len()).unwrap_or(i32::MAX)
}

#[cfg(not(target_os = "macos"))]
fn sweep_host(_bundle_id: &str) -> i32 {
    0
}

/// Removes this app's stale Chromium code-sign clones; call once per launch,
/// off the main thread, after the browser engine started (its own clone is
/// then newer than this process and in use). `bundle_id` is the app's bundle
/// identifier, the prefix Chromium names its clone folder with. Returns the
/// number of clones removed, or -1 for a null or non-UTF-8 `bundle_id` or when
/// the user temp folder or this process's start time cannot be read (nothing
/// is removed then).
///
/// # Safety
/// `bundle_id` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sign_clone_sweep(bundle_id: *const c_char) -> i32 {
    if bundle_id.is_null() {
        return -1;
    }
    // SAFETY: non-null and NUL-terminated per the contract above.
    match unsafe { CStr::from_ptr(bundle_id) }.to_str() {
        Ok(bundle_id) => sweep_host(bundle_id),
        Err(_) => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// A fresh folder under the system temp dir, removed on drop.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(tag: &str) -> Self {
            let nanos =
                SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
            let dir = std::env::temp_dir()
                .join(format!("sign-clone-sweep-{tag}-{}-{nanos}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir.canonicalize().unwrap())
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Writes an executable file (mode 755) at `path`.
    fn write_exe(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"exe").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// A clone folder holding a bundle with a helper executable; returns the helper.
    fn make_clone(root: &Path, suffix: &str) -> PathBuf {
        let helper = root
            .join(format!("code_sign_clone.{suffix}"))
            .join("cmux NIGHTLY.app.bundle/Contents/Frameworks/cmux Helper.app/Contents/MacOS")
            .join("cmux Helper");
        write_exe(&helper);
        helper
    }

    /// Birth and change times are whole ticks of the file system's clock.
    fn tick() {
        std::thread::sleep(Duration::from_millis(50));
    }

    #[test]
    fn sign_clone_sweep_removes_only_the_old_unused_clone() {
        let scratch = Scratch::new("regression");
        let root = scratch.0.join("com.cmuxterm.app.nightly.code_sign_clone");
        std::fs::create_dir_all(&root).unwrap();
        // Earlier launches: one left over, one still running a helper.
        make_clone(&root, "OldAbc");
        let in_use_exe = make_clone(&root, "Busy12");
        tick();
        let started = SystemTime::now();
        tick();
        // This launch's own clone, made after the process started.
        let own_exe = make_clone(&root, "New_99");
        let open = [in_use_exe.clone(), own_exe.clone()];

        let removed = sweep(&root, started, |clone| {
            clone_in_use(clone, |file| Some(open.iter().any(|exe| exe == file)))
        });

        assert_eq!(removed, vec![root.join("code_sign_clone.OldAbc")]);
        assert!(!root.join("code_sign_clone.OldAbc").exists());
        assert!(in_use_exe.exists(), "a clone a process runs from stays");
        assert!(own_exe.exists(), "this launch's clone stays");
    }

    #[test]
    fn sign_clone_sweep_keeps_a_new_clone_nothing_runs_from() {
        let scratch = Scratch::new("new");
        let root = scratch.0.join("id.code_sign_clone");
        std::fs::create_dir_all(&root).unwrap();
        let started = SystemTime::now();
        tick();
        let exe = make_clone(&root, "abcdef");
        assert!(sweep(&root, started, |_| false).is_empty());
        assert!(exe.exists());
    }

    #[test]
    fn sign_clone_sweep_skips_other_names_files_and_links() {
        let scratch = Scratch::new("names");
        let root = scratch.0.join("id.code_sign_clone");
        std::fs::create_dir_all(&root).unwrap();
        let outside = scratch.0.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        for name in ["code_sign_clone.short", "code_sign_clone.toolong7", "other.abcdef"] {
            std::fs::create_dir_all(root.join(name)).unwrap();
        }
        std::fs::write(root.join("code_sign_clone.file01"), b"").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("code_sign_clone.link01")).unwrap();
        tick();
        let removed = sweep(&root, SystemTime::now(), |_| false);
        assert!(removed.is_empty(), "{removed:?}");
        assert!(outside.is_dir(), "a link is never followed");
        assert!(root.join("code_sign_clone.link01").symlink_metadata().is_ok());
    }

    #[test]
    fn sign_clone_in_use_asks_only_single_name_executables() {
        let scratch = Scratch::new("in-use");
        let clone = scratch.0.join("code_sign_clone.abcdef");
        let helper = clone.join("b.app.bundle/Contents/Frameworks/h.app/Contents/MacOS/h");
        write_exe(&helper);
        // Not executable: never asked.
        std::fs::write(clone.join("b.app.bundle/Contents/Info.plist"), b"").unwrap();
        // The hard-linked main executable: the installed app's own file, never asked.
        let installed = scratch.0.join("installed-main");
        write_exe(&installed);
        std::fs::create_dir_all(clone.join("b.app.bundle/Contents/MacOS")).unwrap();
        std::fs::hard_link(&installed, clone.join("b.app.bundle/Contents/MacOS/b")).unwrap();
        // A link to a busy file outside: never followed.
        std::os::unix::fs::symlink(&installed, clone.join("link")).unwrap();

        let mut asked = Vec::new();
        assert!(!clone_in_use(&clone, |file| {
            asked.push(file.to_path_buf());
            Some(false)
        }));
        assert_eq!(asked, vec![helper.clone()]);
        assert!(clone_in_use(&clone, |_| Some(true)), "an open helper keeps the clone");
        assert!(clone_in_use(&clone, |_| None), "an unknown answer keeps the clone");
        assert!(clone_in_use(&scratch.0.join("missing"), |_| Some(false)));
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
    fn sign_clone_root_resolves_only_under_the_allowed_root() {
        let scratch = Scratch::new("root");
        let allowed = scratch.0.join("folders");
        let user_temp = allowed.join("ab/cd/T");
        let root = allowed.join("ab/cd/X/com.cmuxterm.app.code_sign_clone");
        std::fs::create_dir_all(&user_temp).unwrap();
        std::fs::create_dir_all(&root).unwrap();
        assert_eq!(clone_root(&user_temp, "com.cmuxterm.app", &allowed), Some(root.clone()));
        // Missing folder, a bundle id that walks out, and a root outside the allowed one.
        assert_eq!(clone_root(&user_temp, "com.cmuxterm.app.other", &allowed), None);
        for bad in ["", "..", "a/b", "a..b", "../X/com.cmuxterm.app", "com.cmuxterm.app/.."] {
            assert_eq!(clone_root(&user_temp, bad, &allowed), None, "{bad:?}");
        }
        let elsewhere = scratch.0.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        assert_eq!(clone_root(&user_temp, "com.cmuxterm.app", &elsewhere), None);
        // A link out of the allowed root is resolved before the check.
        let outside_x = scratch.0.join("outside-x");
        std::fs::create_dir_all(outside_x.join("com.cmuxterm.app.dev.code_sign_clone")).unwrap();
        std::os::unix::fs::symlink(
            outside_x.join("com.cmuxterm.app.dev.code_sign_clone"),
            allowed.join("ab/cd/X/com.cmuxterm.app.dev.code_sign_clone"),
        )
        .unwrap();
        assert_eq!(clone_root(&user_temp, "com.cmuxterm.app.dev", &allowed), None);
    }

    #[test]
    fn sign_clone_sweep_ffi_refuses_null_and_non_utf8() {
        // SAFETY: null is allowed by the contract.
        assert_eq!(unsafe { cmux_sign_clone_sweep(std::ptr::null()) }, -1);
        let bad = [0xffu8, 0];
        // SAFETY: NUL-terminated.
        assert_eq!(unsafe { cmux_sign_clone_sweep(bad.as_ptr().cast()) }, -1);
    }
}
