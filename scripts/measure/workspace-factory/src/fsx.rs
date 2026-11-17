//! Filesystem and process primitives: clone, copy, remove, usage, statfs, pid liveness.
//! libc calls are declared by hand so the crate has no dependencies.

use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::fs::{self, Metadata};
use std::io;
use std::os::raw::{c_char, c_int, c_long};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

extern "C" {
    fn kill(pid: i32, sig: c_int) -> c_int;
    fn utimensat(dirfd: c_int, path: *const c_char, times: *const Timespec, flags: c_int) -> c_int;
}

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: c_long,
}

#[cfg(target_os = "macos")]
const AT_FDCWD: c_int = -2;
#[cfg(target_os = "macos")]
const AT_SYMLINK_NOFOLLOW: c_int = 0x0020;
#[cfg(not(target_os = "macos"))]
const AT_FDCWD: c_int = -100;
#[cfg(not(target_os = "macos"))]
const AT_SYMLINK_NOFOLLOW: c_int = 0x100;

const ESRCH: i32 = 3;

pub fn cpath(p: &Path) -> io::Result<CString> {
    CString::new(p.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path has a NUL byte"))
}

/// True while `pid` exists. EPERM means it exists but is someone else's.
pub fn pid_alive(pid: i64) -> bool {
    // kill(0) and kill(-n) address process groups, not a process.
    if pid <= 0 || pid > i32::MAX as i64 {
        return false;
    }
    if unsafe { kill(pid as i32, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() != Some(ESRCH)
}

/// lstat says the path is gone (ENOENT), not merely unreadable.
pub fn gone(p: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(p) {
        Ok(_) => Ok(false),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(e) => Err(e),
    }
}

pub fn mtime_ns(m: &Metadata) -> i64 {
    m.mtime()
        .saturating_mul(1_000_000_000)
        .saturating_add(m.mtime_nsec())
}

/// Sets atime and mtime to the nanosecond, on the link itself when `nofollow`.
pub fn set_times(p: &Path, from: &Metadata, nofollow: bool) -> io::Result<()> {
    let times = [
        Timespec {
            tv_sec: from.atime(),
            tv_nsec: from.atime_nsec() as c_long,
        },
        Timespec {
            tv_sec: from.mtime(),
            tv_nsec: from.mtime_nsec() as c_long,
        },
    ];
    let c = cpath(p)?;
    let flags = if nofollow { AT_SYMLINK_NOFOLLOW } else { 0 };
    if unsafe { utimensat(AT_FDCWD, c.as_ptr(), times.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Usage {
    pub exists: bool,
    /// Non-directory entries, by name.
    pub files: u64,
    /// Allocated bytes (st_blocks * 512), each inode once.
    pub bytes: u64,
    /// Newest mtime of any entry, directories included: adding or deleting a file moves its directory's.
    pub newest_mtime_ns: i64,
}

/// Walks `root` without following symlinks or crossing onto another device.
pub fn usage(root: &Path) -> io::Result<Usage> {
    let meta = match fs::symlink_metadata(root) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Usage::default()),
        r => r?,
    };
    let dev = meta.dev();
    let mut u = Usage {
        exists: true,
        ..Usage::default()
    };
    let mut seen = HashSet::new();
    let mut account = |m: &Metadata, u: &mut Usage| {
        u.newest_mtime_ns = u.newest_mtime_ns.max(mtime_ns(m));
        if m.is_dir() {
            u.bytes += m.blocks() * 512;
            return;
        }
        u.files += 1;
        // Only multiply-linked inodes need remembering; that keeps the set small.
        if m.nlink() <= 1 || seen.insert((m.dev(), m.ino())) {
            u.bytes += m.blocks() * 512;
        }
    };
    account(&meta, &mut u);
    let mut stack = if meta.is_dir() {
        vec![root.to_path_buf()]
    } else {
        vec![]
    };
    while let Some(dir) = stack.pop() {
        let entries = match fs::read_dir(&dir) {
            // A live workspace can delete a directory while we walk it.
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            r => r?,
        };
        for ent in entries {
            let ent = ent?;
            let m = match ent.metadata() {
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                r => r?,
            };
            if m.dev() != dev {
                continue;
            }
            account(&m, &mut u);
            if m.is_dir() {
                stack.push(ent.path());
            }
        }
    }
    Ok(u)
}

/// Gives the owner rwx on every directory under `root` so a read-only tree a build left can be removed.
fn make_writable(root: &Path) -> io::Result<()> {
    let fix = |d: &Path| -> io::Result<()> {
        let mode = fs::symlink_metadata(d)?.permissions().mode();
        if mode & 0o700 != 0o700 {
            fs::set_permissions(d, fs::Permissions::from_mode(mode | 0o700))?;
        }
        Ok(())
    };
    fix(root)?;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for ent in fs::read_dir(&dir)? {
            let ent = ent?;
            // DirEntry::file_type does not follow symlinks, so a link out of the tree is left alone.
            if ent.file_type()?.is_dir() {
                let p = ent.path();
                fix(&p)?;
                stack.push(p);
            }
        }
    }
    Ok(())
}

/// Removes a file, symlink or whole tree; a missing path is fine.
pub fn remove_tree(p: &Path) -> io::Result<()> {
    let m = match fs::symlink_metadata(p) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        r => r?,
    };
    if !m.is_dir() {
        return fs::remove_file(p);
    }
    make_writable(p)?;
    fs::remove_dir_all(p)
}

/// Clones directory `src` to `dst`, which must not exist. Returns how: "clonefile" or "copy".
/// An `AlreadyExists` error means `dst` was there first and was not touched.
pub fn clone_tree(src: &Path, dst: &Path) -> io::Result<&'static str> {
    #[cfg(target_os = "macos")]
    {
        extern "C" {
            fn clonefile(src: *const c_char, dst: *const c_char, flags: u32) -> c_int;
        }
        const CLONE_NOFOLLOW: u32 = 0x0001;
        const EXDEV: i32 = 18;
        const ENOTSUP: i32 = 45;
        const EOPNOTSUPP: i32 = 102;
        let (s, d) = (cpath(src)?, cpath(dst)?);
        if unsafe { clonefile(s.as_ptr(), d.as_ptr(), CLONE_NOFOLLOW) } == 0 {
            return Ok("clonefile");
        }
        let e = io::Error::last_os_error();
        // Not APFS, or another volume: copy. Anything else (EEXIST, EACCES, ENOSPC) is real.
        if !matches!(e.raw_os_error(), Some(EXDEV | ENOTSUP | EOPNOTSUPP)) {
            return Err(e);
        }
    }
    copy_tree(src, dst)
}

/// The copy fallback. Creating `dst` first claims it: a second job racing for the same path gets EEXIST.
fn copy_tree(src: &Path, dst: &Path) -> io::Result<&'static str> {
    fs::create_dir(dst)?;
    #[cfg(target_os = "linux")]
    {
        // "src/." copies the contents and puts src's own mode and times on dst.
        let ok = std::process::Command::new("cp")
            .args(["-a", "--reflink=auto", "--"])
            .arg(src.join("."))
            .arg(dst)
            .stdin(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if ok {
            return Ok("copy");
        }
        // cp missing or partial: start over in the same claimed directory.
        make_writable(dst)?;
        for ent in fs::read_dir(dst)? {
            remove_tree(&ent?.path())?;
        }
    }
    copy_into(src, dst)?;
    Ok("copy")
}

/// Copies the contents of directory `src` into existing directory `dst`, keeping modes, symlinks,
/// hardlinks and mtimes to the nanosecond (cargo and SwiftPM compare them).
pub fn copy_into(src: &Path, dst: &Path) -> io::Result<()> {
    fn walk(src: &Path, dst: &Path, links: &mut HashMap<(u64, u64), PathBuf>) -> io::Result<()> {
        for ent in fs::read_dir(src)? {
            let ent = ent?;
            let m = ent.metadata()?;
            let (s, d) = (ent.path(), dst.join(ent.file_name()));
            let ft = m.file_type();
            if ft.is_dir() {
                fs::create_dir(&d)?;
                walk(&s, &d, links)?;
            } else if ft.is_symlink() {
                std::os::unix::fs::symlink(fs::read_link(&s)?, &d)?;
                set_times(&d, &m, true)?;
            } else if ft.is_file() {
                if m.nlink() > 1 {
                    if let Some(first) = links.get(&(m.dev(), m.ino())) {
                        fs::hard_link(first, &d)?;
                        continue;
                    }
                    links.insert((m.dev(), m.ino()), d.clone());
                }
                // fs::copy keeps the mode (and clones the file on APFS when it can).
                fs::copy(&s, &d)?;
                set_times(&d, &m, false)?;
            }
            // Sockets, fifos and devices a build leaves behind are of no use in a workspace.
        }
        // Mode and times last: writing children changes a directory's mtime, and a read-only one refuses them.
        let m = fs::symlink_metadata(src)?;
        fs::set_permissions(dst, m.permissions())?;
        set_times(dst, &m, false)
    }
    walk(src, dst, &mut HashMap::new())
}

/// (free_bytes for an unprivileged user, total_bytes) of the filesystem holding `p`.
pub fn statfs(p: &Path) -> io::Result<(u64, u64)> {
    statfs_impl(p)
}

// Each struct names only the leading fields we read; the padding is larger than the rest of the
// real struct, so the kernel never writes past our buffer.
#[cfg(target_os = "macos")]
fn statfs_impl(p: &Path) -> io::Result<(u64, u64)> {
    #[repr(C)]
    #[allow(dead_code)]
    struct StatFs {
        f_bsize: u32,
        f_iosize: i32,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        _rest: [u8; 4096],
    }
    extern "C" {
        // Intel's plain `statfs` is the old 32-bit-inode layout; arm64 has only the 64-bit one.
        #[cfg_attr(target_arch = "x86_64", link_name = "statfs$INODE64")]
        fn statfs(path: *const c_char, buf: *mut StatFs) -> c_int;
    }
    let c = cpath(p)?;
    let mut st: StatFs = unsafe { std::mem::zeroed() };
    if unsafe { statfs(c.as_ptr(), &mut st) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let bs = st.f_bsize as u64;
    Ok((st.f_bavail * bs, st.f_blocks * bs))
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn statfs_impl(p: &Path) -> io::Result<(u64, u64)> {
    #[repr(C)]
    #[allow(dead_code)]
    struct StatFs {
        f_type: i64,
        f_bsize: i64,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [i32; 2],
        f_namelen: i64,
        f_frsize: i64,
        _rest: [u8; 4096],
    }
    extern "C" {
        fn statfs(path: *const c_char, buf: *mut StatFs) -> c_int;
    }
    let c = cpath(p)?;
    let mut st: StatFs = unsafe { std::mem::zeroed() };
    if unsafe { statfs(c.as_ptr(), &mut st) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // Block counts are in fragment units; glibc's statvfs falls back to f_bsize the same way.
    let unit = if st.f_frsize > 0 {
        st.f_frsize
    } else {
        st.f_bsize
    } as u64;
    Ok((st.f_bavail * unit, st.f_blocks * unit))
}

#[cfg(not(any(
    target_os = "macos",
    all(
        target_os = "linux",
        any(target_arch = "x86_64", target_arch = "aarch64")
    )
)))]
fn statfs_impl(p: &Path) -> io::Result<(u64, u64)> {
    df(p)
}

/// `df -Pk`: the POSIX output format, in 1024-byte blocks. Used where we have no struct layout,
/// and by the tests to check the layouts above.
#[allow(dead_code)]
pub fn df(p: &Path) -> io::Result<(u64, u64)> {
    let out = std::process::Command::new("df")
        .arg("-Pk")
        .arg(p)
        .output()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let bad = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unexpected df output: {text}"),
        )
    };
    if !out.status.success() {
        return Err(bad());
    }
    // Filesystem 1024-blocks Used Available Capacity Mounted-on
    let line = text.lines().nth(1).ok_or_else(bad)?;
    let cols: Vec<&str> = line.split_whitespace().collect();
    let num = |i: usize| {
        cols.get(i)
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(bad)
    };
    Ok((num(3)? * 1024, num(1)? * 1024))
}
