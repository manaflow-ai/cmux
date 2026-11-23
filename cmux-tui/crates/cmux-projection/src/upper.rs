//! The upper folder's file calls (Linux). Each call reaches its folder one name at a time from a
//! descriptor of the upper folder (`openat` with `O_NOFOLLOW`), so a path of any length works (the
//! mount's own paths may be longer than `PATH_MAX` once the state folder is put in front) and no
//! link the agent made is followed out of the folder.

use std::ffi::CString;
use std::fs;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// `stat` of an upper path, the fields the overlay uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stat {
    pub dev: u64,
    pub ino: u64,
    /// The whole `st_mode`: type and permission bits.
    pub mode: u32,
    pub nlink: u32,
    pub uid: u32,
    pub gid: u32,
    pub rdev: u64,
    pub size: u64,
    pub blocks: u64,
    pub atime_ns: i64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
}

impl Stat {
    #[allow(clippy::unnecessary_cast)]
    fn of(st: &libc::stat) -> Self {
        let ns = |secs: i64, nanos: i64| secs.saturating_mul(1_000_000_000).saturating_add(nanos);
        Self {
            dev: st.st_dev as u64,
            ino: st.st_ino as u64,
            mode: st.st_mode as u32,
            nlink: u32::try_from(st.st_nlink).unwrap_or(u32::MAX),
            uid: st.st_uid,
            gid: st.st_gid,
            rdev: st.st_rdev as u64,
            size: u64::try_from(st.st_size).unwrap_or(0),
            blocks: u64::try_from(st.st_blocks).unwrap_or(0),
            atime_ns: ns(st.st_atime as i64, st.st_atime_nsec as i64),
            mtime_ns: ns(st.st_mtime as i64, st.st_mtime_nsec as i64),
            ctime_ns: ns(st.st_ctime as i64, st.st_ctime_nsec as i64),
        }
    }

    /// The `S_IFMT` part of the mode.
    #[must_use]
    pub fn format(&self) -> u32 {
        self.mode & libc::S_IFMT
    }

    #[must_use]
    pub fn is_dir(&self) -> bool {
        self.format() == libc::S_IFDIR
    }
}

/// A time to set: a moment, now, or left alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetTime {
    At(i64),
    Now,
}

fn timespec(time: Option<SetTime>) -> libc::timespec {
    match time {
        None => libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_OMIT },
        Some(SetTime::Now) => libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW },
        Some(SetTime::At(ns)) => libc::timespec {
            tv_sec: ns.div_euclid(1_000_000_000),
            tv_nsec: ns.rem_euclid(1_000_000_000),
        },
    }
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO)
}

fn check(ret: libc::c_int) -> Result<libc::c_int, i32> {
    if ret < 0 { Err(errno()) } else { Ok(ret) }
}

fn name(name: &str) -> Result<CString, i32> {
    CString::new(name).map_err(|_| libc::EINVAL)
}

fn split(path: &str) -> (&str, &str) {
    path.rfind('/').map_or(("", path), |cut| {
        (path.get(..cut).unwrap_or_default(), path.get(cut + 1..).unwrap_or_default())
    })
}

/// Opens `file` (its descriptor's own path, `/proc/self/fd/N`) with std, for folder listings.
fn proc_path(fd: &OwnedFd) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", fd.as_raw_fd()))
}

/// The upper folder.
pub struct Upper {
    root: OwnedFd,
    path: PathBuf,
    /// Reads through this layer leave access times alone (`O_NOATIME`), as the mount's `noatime`
    /// says; off, the disk under it keeps them as its own mount says.
    keep_atime: AtomicBool,
}

impl Upper {
    /// The upper folder at `path` (made when missing).
    pub fn open(path: &Path) -> std::io::Result<Self> {
        fs::create_dir_all(path)?;
        let c = CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|_| std::io::Error::from_raw_os_error(libc::EINVAL))?;
        // SAFETY: `c` is a valid NUL-terminated path; the result is checked before use.
        let fd =
            unsafe { libc::open(c.as_ptr(), libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `fd` was just opened and is owned by nothing else.
        Ok(Self {
            root: unsafe { OwnedFd::from_raw_fd(fd) },
            path: path.to_path_buf(),
            keep_atime: AtomicBool::new(true),
        })
    }

    /// The upper folder's own path.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The folder at relative `dir` (empty for the upper folder itself), never through a link.
    pub fn dir(&self, dir: &str) -> Result<OwnedFd, i32> {
        let mut at =
            self.root.try_clone().map_err(|error| error.raw_os_error().unwrap_or(libc::EIO))?;
        for part in dir.split('/').filter(|part| !part.is_empty()) {
            let part = name(part)?;
            // SAFETY: `at` is an open descriptor and `part` a valid C string; checked below.
            let fd = unsafe {
                libc::openat(
                    at.as_raw_fd(),
                    part.as_ptr(),
                    libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(errno());
            }
            // SAFETY: `fd` was just opened and is owned by nothing else.
            at = unsafe { OwnedFd::from_raw_fd(fd) };
        }
        Ok(at)
    }

    /// The folder holding `path`, and `path`'s last name.
    fn parent(&self, path: &str) -> Result<(OwnedFd, CString), i32> {
        let (dir, last) = split(path);
        if last.is_empty() {
            return Err(libc::EINVAL);
        }
        Ok((self.dir(dir)?, name(last)?))
    }

    /// `lstat` of `path` (empty for the upper folder itself).
    pub fn stat(&self, path: &str) -> Result<Stat, i32> {
        // SAFETY: a zeroed stat is a valid out buffer.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if path.is_empty() {
            // SAFETY: the root descriptor is open; an empty path with AT_EMPTY_PATH stats it.
            check(unsafe {
                libc::fstatat(self.root.as_raw_fd(), c"".as_ptr(), &mut st, libc::AT_EMPTY_PATH)
            })?;
            return Ok(Stat::of(&st));
        }
        let (dir, last) = self.parent(path)?;
        // SAFETY: `dir` is open, `last` is a valid C string, `st` a valid out buffer.
        check(unsafe {
            libc::fstatat(dir.as_raw_fd(), last.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW)
        })?;
        Ok(Stat::of(&st))
    }

    /// `fstat` of an open file.
    pub fn fstat(file: &fs::File) -> Result<Stat, i32> {
        // SAFETY: a zeroed stat is a valid out buffer; the file is open.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        check(unsafe { libc::fstat(file.as_raw_fd(), &mut st) })?;
        Ok(Stat::of(&st))
    }

    pub fn mkdir(&self, path: &str, mode: u32) -> Result<(), i32> {
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe { libc::mkdirat(dir.as_raw_fd(), last.as_ptr(), mode) }).map(drop)
    }

    /// A fifo, socket or device node (`mode` carries the type).
    pub fn mknod(&self, path: &str, mode: u32, rdev: u64) -> Result<(), i32> {
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe { libc::mknodat(dir.as_raw_fd(), last.as_ptr(), mode, rdev) }).map(drop)
    }

    pub fn symlink(&self, target: &[u8], path: &str) -> Result<(), i32> {
        let (dir, last) = self.parent(path)?;
        let target = CString::new(target).map_err(|_| libc::EINVAL)?;
        // SAFETY: valid descriptor and C strings.
        check(unsafe { libc::symlinkat(target.as_ptr(), dir.as_raw_fd(), last.as_ptr()) }).map(drop)
    }

    /// A second name `to` for the file at `from`.
    pub fn link(&self, from: &str, to: &str) -> Result<(), i32> {
        let (from_dir, from_name) = self.parent(from)?;
        let (to_dir, to_name) = self.parent(to)?;
        // SAFETY: valid descriptors and C strings.
        check(unsafe {
            libc::linkat(
                from_dir.as_raw_fd(),
                from_name.as_ptr(),
                to_dir.as_raw_fd(),
                to_name.as_ptr(),
                0,
            )
        })
        .map(drop)
    }

    pub fn unlink(&self, path: &str) -> Result<(), i32> {
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe { libc::unlinkat(dir.as_raw_fd(), last.as_ptr(), 0) }).map(drop)
    }

    pub fn rmdir(&self, path: &str) -> Result<(), i32> {
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe { libc::unlinkat(dir.as_raw_fd(), last.as_ptr(), libc::AT_REMOVEDIR) })
            .map(drop)
    }

    /// `renameat2` (`flags`: 0, `RENAME_NOREPLACE` or `RENAME_EXCHANGE`).
    pub fn rename(&self, from: &str, to: &str, flags: u32) -> Result<(), i32> {
        let (from_dir, from_name) = self.parent(from)?;
        let (to_dir, to_name) = self.parent(to)?;
        // The raw syscall: musl, which the Linux release binaries link, has no `renameat2`
        // wrapper, so `libc::renameat2` left the musl builds with an undefined symbol.
        // SAFETY: valid descriptors and C strings; renameat2 takes exactly these arguments.
        let done = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                from_dir.as_raw_fd(),
                from_name.as_ptr(),
                to_dir.as_raw_fd(),
                to_name.as_ptr(),
                flags,
            )
        };
        check(done as libc::c_int).map(drop)
    }

    /// Moves a file from outside the upper folder (the scratch folder, same disk) to `to`.
    pub fn adopt(&self, from: &Path, to: &str) -> Result<(), i32> {
        let from = CString::new(from.as_os_str().as_encoded_bytes()).map_err(|_| libc::EINVAL)?;
        let (to_dir, to_name) = self.parent(to)?;
        // SAFETY: valid C strings and descriptor; AT_FDCWD for the absolute source.
        check(unsafe {
            libc::renameat(libc::AT_FDCWD, from.as_ptr(), to_dir.as_raw_fd(), to_name.as_ptr())
        })
        .map(drop)
    }

    pub fn readlink(&self, path: &str) -> Result<Vec<u8>, i32> {
        let (dir, last) = self.parent(path)?;
        let mut buffer = vec![0u8; libc::PATH_MAX as usize + 1];
        // SAFETY: valid descriptor and C string; the buffer is as long as the length passed.
        let read = unsafe {
            libc::readlinkat(
                dir.as_raw_fd(),
                last.as_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
            )
        };
        if read < 0 {
            return Err(errno());
        }
        buffer.truncate(usize::try_from(read).unwrap_or(0));
        Ok(buffer)
    }

    /// Permission bits of `path` (never a link: Linux has no link modes).
    pub fn chmod(&self, path: &str, mode: u32) -> Result<(), i32> {
        if path.is_empty() {
            let dir = self.dir("")?;
            return Self::chmod_fd(&dir, mode);
        }
        // fchmodat follows a link at the last name: a link is never chmod-ed (nor its target).
        if self.stat(path)?.format() == libc::S_IFLNK {
            return Err(libc::EOPNOTSUPP);
        }
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe { libc::fchmodat(dir.as_raw_fd(), last.as_ptr(), mode & 0o7777, 0) }).map(drop)
    }

    /// Permission bits through a descriptor (`O_PATH` ones too, through `/proc`).
    pub fn chmod_fd(fd: &OwnedFd, mode: u32) -> Result<(), i32> {
        let path =
            CString::new(proc_path(fd).as_os_str().as_encoded_bytes()).map_err(|_| libc::EINVAL)?;
        // SAFETY: a valid C string.
        check(unsafe { libc::chmod(path.as_ptr(), mode & 0o7777) }).map(drop)
    }

    /// Owner and group of `path` (`u32::MAX` leaves one alone), never through a link.
    pub fn chown(&self, path: &str, uid: u32, gid: u32) -> Result<(), i32> {
        if path.is_empty() {
            let dir = self.dir("")?;
            // SAFETY: valid descriptor; AT_EMPTY_PATH acts on it.
            return check(unsafe {
                libc::fchownat(dir.as_raw_fd(), c"".as_ptr(), uid, gid, libc::AT_EMPTY_PATH)
            })
            .map(drop);
        }
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor and C string.
        check(unsafe {
            libc::fchownat(dir.as_raw_fd(), last.as_ptr(), uid, gid, libc::AT_SYMLINK_NOFOLLOW)
        })
        .map(drop)
    }

    /// Access and modification times of `path`, never through a link.
    pub fn utimes(
        &self,
        path: &str,
        atime: Option<SetTime>,
        mtime: Option<SetTime>,
    ) -> Result<(), i32> {
        let times = [timespec(atime), timespec(mtime)];
        if path.is_empty() {
            let dir = self.dir("")?;
            let path = CString::new(proc_path(&dir).as_os_str().as_encoded_bytes())
                .map_err(|_| libc::EINVAL)?;
            // SAFETY: valid C string and a two-element times array.
            return check(unsafe {
                libc::utimensat(libc::AT_FDCWD, path.as_ptr(), times.as_ptr(), 0)
            })
            .map(drop);
        }
        let (dir, last) = self.parent(path)?;
        // SAFETY: valid descriptor, C string and a two-element times array.
        check(unsafe {
            libc::utimensat(
                dir.as_raw_fd(),
                last.as_ptr(),
                times.as_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        })
        .map(drop)
    }

    /// Opens `path` (never through a link) with `flags` (`O_CREAT` uses `mode`).
    pub fn open_file(&self, path: &str, flags: i32, mode: u32) -> Result<fs::File, i32> {
        let (dir, last) = self.parent(path)?;
        let fd = self.open_at(&dir, &last, flags | libc::O_CLOEXEC | libc::O_NOFOLLOW, mode)?;
        Ok(fs::File::from(fd))
    }

    /// Whether reads through this layer leave access times alone ([`Upper::open_file`] opens with
    /// `O_NOATIME`); on until the mount says otherwise.
    pub fn set_keep_atime(&self, keep: bool) {
        self.keep_atime.store(keep, Ordering::Relaxed);
    }

    /// `openat`, with `O_NOATIME` while access times are kept; without it where the kernel refuses
    /// it (a file this daemon neither owns nor may override the owner of).
    fn open_at(
        &self,
        dir: &OwnedFd,
        name: &CString,
        flags: i32,
        mode: u32,
    ) -> Result<OwnedFd, i32> {
        let open = |flags: i32| {
            // SAFETY: valid descriptor and C string; the result is checked.
            let fd = unsafe {
                libc::openat(dir.as_raw_fd(), name.as_ptr(), flags, libc::c_uint::from(mode))
            };
            if fd < 0 {
                return Err(errno());
            }
            // SAFETY: `fd` was just opened and is owned by nothing else.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        };
        if !self.keep_atime.load(Ordering::Relaxed) {
            return open(flags);
        }
        match open(flags | libc::O_NOATIME) {
            Err(libc::EPERM) => open(flags),
            opened => opened,
        }
    }

    /// Opens an existing upper file, its mode notwithstanding. The kernel has already checked the
    /// caller's right at its own open (the mount runs with `default_permissions`); a file made
    /// without the owner's read or write bit (git makes its objects read only) is still reached
    /// by lifting that bit for this one open and putting it back.
    pub fn open_existing(&self, path: &str, flags: i32) -> Result<fs::File, i32> {
        match self.open_file(path, flags, 0) {
            Err(libc::EACCES) => {}
            other => return other,
        }
        let mode = self.stat(path)?.mode & 0o7777;
        let lift = match flags & libc::O_ACCMODE {
            libc::O_RDONLY => 0o400,
            libc::O_WRONLY => 0o200,
            _ => 0o600,
        };
        self.chmod(path, mode | lift)?;
        let opened = self.open_file(path, flags, 0);
        let _ = self.chmod(path, mode);
        opened
    }

    /// The names in folder `dir` with each one's inode number and whether it is a folder, a link
    /// or something else (`d_type`).
    pub fn list(&self, dir: &str) -> Result<Vec<(String, u64, u32)>, i32> {
        let at = self.dir(dir)?;
        let dot = name(".")?;
        // Read through a descriptor of its own (O_NOATIME while access times are kept): a
        // listing leaves the folder's access time as the mount says.
        let fd =
            self.open_at(&at, &dot, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC, 0)?;
        // SAFETY: `fd` is an open folder; fdopendir takes it over (closedir closes it).
        let stream = unsafe { libc::fdopendir(std::os::fd::IntoRawFd::into_raw_fd(fd)) };
        if stream.is_null() {
            return Err(errno());
        }
        let mut out = Vec::new();
        loop {
            // SAFETY: `stream` is open; the entry it returns lives until the next readdir64.
            let entry = unsafe { libc::readdir64(stream) };
            if entry.is_null() {
                break;
            }
            // SAFETY: a non-null entry from readdir64 holds a NUL-terminated name.
            let (raw, ino, d_type) = unsafe {
                let entry = &*entry;
                (std::ffi::CStr::from_ptr(entry.d_name.as_ptr()), entry.d_ino, entry.d_type)
            };
            let Ok(found) = raw.to_str() else { continue };
            if found == "." || found == ".." {
                continue;
            }
            let format = match d_type {
                libc::DT_DIR => libc::S_IFDIR,
                libc::DT_REG => libc::S_IFREG,
                libc::DT_LNK => libc::S_IFLNK,
                libc::DT_FIFO => libc::S_IFIFO,
                libc::DT_SOCK => libc::S_IFSOCK,
                libc::DT_CHR => libc::S_IFCHR,
                libc::DT_BLK => libc::S_IFBLK,
                // A disk that names no type: its stat does.
                _ => match self.stat(&if dir.is_empty() {
                    found.to_owned()
                } else {
                    format!("{dir}/{found}")
                }) {
                    Ok(stat) => stat.format(),
                    Err(_) => continue,
                },
            };
            out.push((found.to_owned(), ino, format));
        }
        // SAFETY: `stream` is open and closed once.
        unsafe { libc::closedir(stream) };
        Ok(out)
    }

    /// The upper folder's file system's sizes.
    pub fn statvfs(&self) -> Result<libc::statvfs, i32> {
        // SAFETY: a zeroed statvfs is a valid out buffer; the descriptor is open.
        let mut out: libc::statvfs = unsafe { std::mem::zeroed() };
        let path =
            CString::new(self.path.as_os_str().as_encoded_bytes()).map_err(|_| libc::EINVAL)?;
        // SAFETY: valid C string and out buffer.
        check(unsafe { libc::statvfs(path.as_ptr(), &mut out) })?;
        Ok(out)
    }
}
