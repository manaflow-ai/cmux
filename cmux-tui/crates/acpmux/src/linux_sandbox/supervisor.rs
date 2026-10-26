//! E1 write-open supervision; no production caller until G2.
//! Activation also requires F: every mutation must hold the same process-wide
//! mutex and per-uid flock through resolve/check/perform, across all supervisors.
//! Bwrap supplies read-only mounts and masks; this is not a standalone sandbox.
//! Activation requires A2 to reject mounts under writable roots that are not
//! whole filesystems, and G1 to reject group/world-writable roots. Shared-root
//! resolve/check/perform serialization across daemon processes belongs to E1b/F.
//! Stricter than Seatbelt: only the filesystem allowlist below is supported;
//! casefold directories and unverified flags on ext4/f2fs/tmpfs are refused.
//! Device filesystems are traversed only for the existing /dev aliases/devices.
//! Stricter: non-UTF-8 paths and anonymous/deleted proc-fd targets are refused.
//! Opens use O_NONBLOCK while acquiring the fd (a FIFO without a reader fails
//! ENXIO); the requested blocking mode is restored before handing it over.
//! Only regular files, FIFOs and character devices 1:{3,5,7,8,9} may be reopened
//! for writes (plus directories for O_TMPFILE). No tty or block-device opens.
//! Unlike native open, policy-permitted O_TRUNC may take effect before ADDFD
//! reports EMFILE. Creation is exclusive and rolled back on delivery failure
//! only while the name still addresses our inode; no placeholder fd is injected.
#![allow(dead_code)]

use super::{lookup, rules::WritePolicy};
use libc::*;
use std::{
    collections::VecDeque,
    ffi::CString,
    io,
    os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd},
    path::Path,
};

mod locking;

type Result<T> = std::result::Result<T, i32>;
fn error() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(EACCES)
}
fn checked(rc: i32) -> Result<i32> {
    if rc < 0 { Err(error()) } else { Ok(rc) }
}

// All syscall pointers below refer to live CStrings, initialized C-layout
// structs, or sized buffers. Returned descriptors become owned exactly once.
fn open_at(dir: RawFd, path: &str, flags: i32, mode: u32) -> Result<OwnedFd> {
    let path = CString::new(path).map_err(|_| EACCES)?;
    let fd = checked(unsafe { openat(dir, path.as_ptr(), flags | O_CLOEXEC, mode) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn stat(fd: RawFd) -> Result<stat> {
    let mut out = unsafe { std::mem::zeroed() };
    checked(unsafe { fstat(fd, &mut out) }).map_err(|_| EACCES)?;
    Ok(out)
}

fn link_at(dir: RawFd, path: &str) -> Result<String> {
    let path = CString::new(path).map_err(|_| EACCES)?;
    let mut buf = [0u8; PATH_MAX as usize];
    let n = checked(
        unsafe { readlinkat(dir, path.as_ptr(), buf.as_mut_ptr().cast(), buf.len()) } as i32
    )? as usize;
    if n == buf.len() {
        return Err(ENAMETOOLONG);
    }
    String::from_utf8(buf[..n].to_vec()).map_err(|_| EACCES)
}

/// Reads each target byte at most once; stops at NUL, PATH_MAX, or read error.
fn copy_path(pid: u32, address: u64) -> Result<String> {
    let mut buf = [0u8; PATH_MAX as usize];
    let mut used = 0;
    while used < buf.len() {
        let local = iovec { iov_base: buf[used..].as_mut_ptr().cast(), iov_len: buf.len() - used };
        let remote = iovec {
            iov_base: address.checked_add(used as u64).ok_or(EFAULT)? as *mut c_void,
            iov_len: local.iov_len,
        };
        let n = unsafe { process_vm_readv(pid as i32, &local, 1, &remote, 1, 0) };
        if n <= 0 {
            return Err(EFAULT);
        }
        let end = used + n as usize;
        if let Some(nul) = buf[used..end].iter().position(|b| *b == 0) {
            return String::from_utf8(buf[..used + nul].to_vec()).map_err(|_| EACCES);
        }
        used = end;
    }
    Err(ENAMETOOLONG)
}

fn components(path: &str) -> VecDeque<String> {
    path.split('/').filter(|s| !s.is_empty()).map(str::to_owned).collect()
}

struct Resolved {
    parent: OwnedFd,
    name: String,
    logical: String,
    object: Option<OwnedFd>,
    directory_required: bool,
}

/// Consumes components; symlink expansion is capped at 40. `..` pops only
/// held directories and cannot leave root. Procfs is recognized by fstatfs,
/// including mounts reached through aliases. Symlinks are read through their
/// pinned O_PATH fd, never through a mutable directory entry a second time.
/// Relative starts use one additional absolute walk to verify cwd/dirfd identity;
/// this recursion ends immediately because the verified start is absolute.
fn resolve(task: RawFd, dir: i32, path: &str, flags: i32, nspid: &str) -> Result<Resolved> {
    resolve_inner(task, dir, path, flags, nspid, &directory_flags, true)
}

fn proc_fd_number(name: &str) -> Result<u32> {
    if name.is_empty()
        || name.len() > 10
        || (name.len() > 1 && name.starts_with('0'))
        || !name.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(ENOENT);
    }
    name.parse::<i32>().map(|fd| fd as u32).map_err(|_| ENOENT)
}

// O_PATH descriptors cannot receive GETFLAGS; reopen the pinned directory.
fn directory_flags(fd: RawFd) -> Result<c_long> {
    let readable = open_at(fd, ".", O_RDONLY | O_DIRECTORY | O_NONBLOCK, 0).map_err(|_| EACCES)?;
    let mut flags: c_long = 0;
    checked(unsafe { ioctl(readable.as_raw_fd(), FS_IOC_GETFLAGS, &mut flags) })?;
    Ok(flags)
}

// The injectable reader makes casefold enforcement testable on ordinary CI disks.
fn resolve_with_flags(
    task: RawFd,
    dir: i32,
    path: &str,
    flags: i32,
    nspid: &str,
    read_flags: &dyn Fn(RawFd) -> Result<c_long>,
) -> Result<Resolved> {
    resolve_inner(task, dir, path, flags, nspid, read_flags, false)
}

fn resolve_inner(
    task: RawFd,
    dir: i32,
    path: &str,
    flags: i32,
    nspid: &str,
    read_flags: &dyn Fn(RawFd) -> Result<c_long>,
    verify_filesystem: bool,
) -> Result<Resolved> {
    if path.is_empty() {
        return Err(ENOENT);
    }
    let root = open_at(task, "root", O_PATH | O_DIRECTORY, 0).map_err(|_| EACCES)?;
    let check_directory = |fd, device_route| {
        if verify_filesystem {
            let verified = lookup::verify_dir(unsafe { BorrowedFd::borrow_raw(fd) });
            if verified.is_ok() {
                return Ok(());
            }
            // devtmpfs may lack FS_IOC_GETFLAGS. It is allowed only on the
            // already-special-cased /dev routes; all other mounts fail closed.
            if device_route {
                let mut fs: statfs = unsafe { std::mem::zeroed() };
                if checked(unsafe { fstatfs(fd, &mut fs) }).is_ok()
                    && fs.f_type as u64 == 0x0102_1994
                {
                    return Ok(());
                }
            }
            return Err(EACCES);
        }
        let mut fs: statfs = unsafe { std::mem::zeroed() };
        checked(unsafe { fstatfs(fd, &mut fs) }).map_err(|_| EACCES)?;
        lookup::classify(fs.f_type as u64, read_flags(fd), Err(ENOTTY)).map_err(|reason| {
            eprintln!("sandbox directory refused: {reason}");
            EACCES
        })
    };
    check_directory(root.as_raw_fd(), false)?;
    let mut directory_required = path.ends_with('/');
    let start = if path.starts_with('/') {
        path.to_owned()
    } else {
        let at = if dir == AT_FDCWD { "cwd".to_owned() } else { format!("fd/{dir}") };
        let actual = open_at(task, &at, O_PATH, 0).map_err(|_| EACCES)?;
        let actual = stat(actual.as_raw_fd())?;
        if actual.st_mode & S_IFMT != S_IFDIR {
            return Err(ENOTDIR);
        }
        let cwd = link_at(task, &at).map_err(|_| EACCES)?;
        if !cwd.starts_with('/') || cwd.ends_with(" (deleted)") {
            return Err(EACCES);
        }
        let walked =
            resolve_inner(task, AT_FDCWD, &cwd, O_DIRECTORY, nspid, read_flags, verify_filesystem)?;
        let pin = open_at(walked.parent.as_raw_fd(), &walked.name, O_PATH | O_NOFOLLOW, 0)?;
        let walked_stat = stat(pin.as_raw_fd())?;
        if (actual.st_dev, actual.st_ino) != (walked_stat.st_dev, walked_stat.st_ino) {
            return Err(EACCES);
        }
        format!("{}/{path}", walked.logical)
    };
    let mut queue = components(&start);
    let mut stack = vec![root];
    let mut logical = std::path::PathBuf::from("/");
    let mut links = 0;
    let mut magic = None;
    while let Some(name) = queue.pop_front() {
        if name == "." {
            continue;
        }
        if name == ".." {
            if stack.len() > 1 {
                stack.pop();
                logical.pop();
            }
            continue;
        }
        let parent = stack.last().ok_or(EACCES)?.as_raw_fd();
        let target = logical.join(&name);
        let pin = match open_at(parent, &name, O_PATH | O_NOFOLLOW, 0) {
            Ok(fd) => fd,
            Err(ENOENT) if queue.is_empty() && magic.is_none() => {
                return Ok(Resolved {
                    parent: stack.pop().ok_or(EACCES)?,
                    name,
                    logical: target.to_str().ok_or(EACCES)?.into(),
                    object: None,
                    directory_required,
                });
            }
            Err(e) => return Err(e),
        };
        let mut fs: statfs = unsafe { std::mem::zeroed() };
        checked(unsafe { fstatfs(pin.as_raw_fd(), &mut fs) }).map_err(|_| EACCES)?;
        // libc's statfs field and PROC_SUPER_MAGIC use architecture-dependent
        // integer aliases; normalize both before comparing across Linux ABIs.
        #[allow(clippy::useless_conversion)]
        let is_proc = i64::try_from(fs.f_type).map_err(|_| EACCES)?
            == i64::try_from(PROC_SUPER_MAGIC).map_err(|_| EACCES)?;
        if is_proc {
            if target != Path::new("/proc")
                || queue.len() != 3
                || magic.is_some()
                || !matches!(queue[0].as_str(), "self" | "thread-self") && queue[0] != nspid
                || queue[1] != "fd"
                || flags & O_NOFOLLOW != 0
            {
                return Err(EACCES);
            }
            let number = proc_fd_number(&queue[2])?;
            let object = open_at(task, &format!("fd/{number}"), O_PATH, 0)?;
            let current = link_at(AT_FDCWD, &format!("/proc/self/fd/{}", object.as_raw_fd()))
                .map_err(|_| EACCES)?;
            if !current.starts_with('/') || current.ends_with(" (deleted)") {
                return Err(EACCES);
            }
            magic = Some(object);
            queue = components(&current);
            stack.truncate(1);
            logical = "/".into();
            continue;
        }
        let metadata = stat(pin.as_raw_fd())?;
        if metadata.st_mode & S_IFMT == S_IFLNK {
            if queue.is_empty() && flags & O_NOFOLLOW != 0 {
                return Err(ELOOP);
            }
            if queue.is_empty() && flags & (O_CREAT | O_EXCL) == (O_CREAT | O_EXCL) {
                return Err(EEXIST);
            }
            links += 1;
            if links > 40 {
                return Err(ELOOP);
            }
            let target = link_at(pin.as_raw_fd(), "")?;
            if queue.is_empty() && target.ends_with('/') {
                directory_required = true;
            }
            if target.starts_with('/') {
                stack.truncate(1);
                logical = "/".into();
            }
            let mut next = components(&target);
            next.append(&mut queue);
            queue = next;
            continue;
        }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            let device_route = target == Path::new("/dev")
                && (queue.is_empty()
                    || (queue.len() == 1
                        && matches!(
                            queue[0].as_str(),
                            "null"
                                | "zero"
                                | "full"
                                | "random"
                                | "urandom"
                                | "tty"
                                | "stdout"
                                | "stderr"
                        ))
                    || (queue.len() == 2 && queue[0] == "fd"));
            check_directory(pin.as_raw_fd(), device_route)?;
        } else if queue.is_empty() && directory_required {
            return Err(ENOTDIR);
        }
        logical = target;
        if queue.is_empty() {
            if let Some(original) = magic {
                let original = stat(original.as_raw_fd())?;
                if (original.st_dev, original.st_ino) != (metadata.st_dev, metadata.st_ino) {
                    return Err(EACCES);
                }
                // Reopen the walked object: its mount is the sandbox's mount,
                // even if the inherited target fd came from a writable host bind.
                return Ok(Resolved {
                    parent: stack.pop().ok_or(EACCES)?,
                    name,
                    logical: logical.to_str().ok_or(EACCES)?.into(),
                    object: Some(pin),
                    directory_required,
                });
            }
            return Ok(Resolved {
                parent: stack.pop().ok_or(EACCES)?,
                name,
                logical: logical.to_str().ok_or(EACCES)?.into(),
                object: None,
                directory_required,
            });
        }
        if metadata.st_mode & S_IFMT != S_IFDIR {
            return Err(ENOTDIR);
        }
        stack.push(pin);
    }
    if magic.is_some() {
        return Err(EACCES);
    }
    Ok(Resolved {
        parent: stack.pop().ok_or(EACCES)?,
        name: ".".into(),
        logical: logical.to_str().ok_or(EACCES)?.into(),
        object: None,
        directory_required,
    })
}

fn arguments(data: &seccomp_data) -> Result<(i32, u64, i32, u32)> {
    let a = data.args;
    if data.nr as c_long == SYS_openat {
        return Ok((a[0] as i32, a[1], a[2] as i32, a[3] as u32));
    }
    #[cfg(target_arch = "x86_64")]
    {
        const SYS_OPEN: c_long = libc::SYS_open;
        const SYS_CREAT: c_long = libc::SYS_creat;
        match data.nr as c_long {
            n if n == SYS_OPEN => return Ok((AT_FDCWD, a[0], a[1] as i32, a[2] as u32)),
            n if n == SYS_CREAT => {
                return Ok((AT_FDCWD, a[0], O_WRONLY | O_CREAT | O_TRUNC, a[1] as u32));
            }
            _ => {}
        }
    }
    Err(EACCES)
}

fn valid_errno(errno: i32) -> Result<bool> {
    match errno {
        EINTR => Ok(true),
        ENOENT => Ok(false),
        _ => Err(EACCES),
    }
}

/// Checks the notification id, retrying EINTR until the stop fd is readable.
fn valid(fd: RawFd, id: &u64, stop: RawFd) -> Result<bool> {
    loop {
        if unsafe { ioctl(fd, SECCOMP_IOCTL_NOTIF_ID_VALID, id) } == 0 {
            return Ok(true);
        }
        let errno = error();
        match valid_errno(errno) {
            Ok(true) => {
                let mut pollfd = pollfd { fd: stop, events: POLLIN, revents: 0 };
                let rc = unsafe { poll(&mut pollfd, 1, 10) };
                if rc < 0 && error() != EINTR {
                    return Err(EACCES);
                }
                if pollfd.revents & POLLIN != 0 {
                    return Err(ECANCELED);
                }
            }
            Ok(false) => return Ok(false),
            Err(errno) => return Err(errno),
        }
    }
}

fn reject_write_device(mode: mode_t, rdev: dev_t) -> Result<()> {
    match mode & S_IFMT {
        S_IFREG | S_IFIFO => Ok(()),
        S_IFDIR => Err(EISDIR),
        S_IFLNK => Err(ELOOP),
        S_IFCHR if [3, 5, 7, 8, 9].iter().any(|minor| rdev == makedev(1, *minor)) => Ok(()),
        _ => Err(EACCES),
    }
}

fn open_mode(mode: u32, _mask: u32) -> u32 {
    mode
}

/// Pins and inspects the inode actually reopened. A competing creator gets
/// one retry (two attempts total), then EAGAIN. The test hook models a leaf
/// replacement after inspection; it cannot redirect the pinned proc-fd reopen.
fn open_leaf(
    resolved: &Resolved,
    flags: i32,
    mode: u32,
    after_inspect: impl FnOnce(),
) -> Result<(OwnedFd, bool)> {
    let mut hook = Some(after_inspect);
    for attempt in 0..2 {
        let pin = match resolved.object.as_ref() {
            Some(object) => object.try_clone().map_err(|_| EACCES),
            None => open_at(resolved.parent.as_raw_fd(), &resolved.name, O_PATH | O_NOFOLLOW, 0),
        };
        match pin {
            Ok(pin) => {
                if flags & (O_CREAT | O_EXCL) == (O_CREAT | O_EXCL) {
                    return Err(EEXIST);
                }
                let info = stat(pin.as_raw_fd())?;
                let tmpfile = flags & O_TMPFILE == O_TMPFILE;
                if !tmpfile || info.st_mode & S_IFMT != S_IFDIR {
                    reject_write_device(info.st_mode, info.st_rdev)?;
                }
                if let Some(hook) = hook.take() {
                    hook();
                }
                // The pinned inode, never the mutable leaf name, is reopened.
                // O_EXCL has independent meaning for anonymous O_TMPFILE files.
                let acquired = (flags & !(O_CREAT | O_NOFOLLOW | if tmpfile { 0 } else { O_EXCL }))
                    | O_NONBLOCK
                    | O_NOCTTY;
                let suffix = if resolved.directory_required { "/" } else { "" };
                let opened = open_at(
                    AT_FDCWD,
                    &format!("/proc/self/fd/{}{suffix}", pin.as_raw_fd()),
                    acquired,
                    mode,
                )?;
                return Ok((opened, false));
            }
            Err(ENOENT) if attempt != 0 => return Err(EAGAIN),
            Err(ENOENT) if flags & O_CREAT != 0 => {
                if let Some(hook) = hook.take() {
                    hook();
                }
                match open_at(
                    resolved.parent.as_raw_fd(),
                    &resolved.name,
                    flags | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY,
                    mode,
                ) {
                    Ok(opened) => return Ok((opened, true)),
                    Err(EEXIST) if flags & O_EXCL == 0 => {}
                    Err(errno) => return Err(errno),
                }
            }
            Err(errno) => return Err(errno),
        }
    }
    Err(EAGAIN)
}

// Called under both transaction locks; never remove a replacement inode.
fn rollback_created(resolved: &Resolved, opened: &OwnedFd) {
    let Ok(info) = stat(opened.as_raw_fd()) else { return };
    let Ok(name) = CString::new(resolved.name.as_str()) else { return };
    let mut current: stat = unsafe { std::mem::zeroed() };
    if unsafe {
        fstatat(resolved.parent.as_raw_fd(), name.as_ptr(), &mut current, AT_SYMLINK_NOFOLLOW)
    } == 0
        && (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino)
    {
        unsafe {
            unlinkat(resolved.parent.as_raw_fd(), name.as_ptr(), 0);
        }
    }
}

fn emulate(fd: RawFd, request: &seccomp_notif, policy: &WritePolicy, stop: RawFd) -> Result<()> {
    let (dir, address, flags, mode) = arguments(&request.data)?;
    // Pin this task's proc directory before copying memory; PID reuse cannot
    // redirect later root/cwd/fd/status lookups to another process.
    let task = open_at(AT_FDCWD, &format!("/proc/{}", request.pid), O_PATH | O_DIRECTORY, 0)
        .map_err(|_| EACCES)?;
    let path = copy_path(request.pid, address);
    if !valid(fd, &request.id, stop)? {
        return Ok(());
    }
    let path = path?;
    let status = std::fs::read_to_string(format!("/proc/self/fd/{}/status", task.as_raw_fd()))
        .map_err(|_| EACCES)?;
    let field = |name: &str| status.lines().find_map(|line| line.strip_prefix(name));
    let mask = u32::from_str_radix(field("Umask:").ok_or(EACCES)?.trim(), 8).map_err(|_| EACCES)?;
    let nspid = field("NSpid:").and_then(|p| p.split_whitespace().last()).ok_or(EACCES)?;
    let mut resolved = resolve(task.as_raw_fd(), dir, &path, flags, nspid)?;
    if resolved.directory_required {
        resolved.name.push('/');
    }
    policy.check(Path::new(&resolved.logical)).map_err(|_| EACCES)?;
    if !valid(fd, &request.id, stop)? {
        return Ok(());
    }
    let previous_umask = unsafe { umask(mask as mode_t) };
    let opened_result = open_leaf(&resolved, flags, open_mode(mode, mask), || {});
    unsafe { umask(previous_umask) };
    let (opened, created) = opened_result?;
    let delivery = (|| {
        if flags & (O_NONBLOCK | O_PATH) == 0 {
            let current = checked(unsafe { fcntl(opened.as_raw_fd(), F_GETFL) })?;
            checked(unsafe { fcntl(opened.as_raw_fd(), F_SETFL, current & !O_NONBLOCK) })?;
        }
        let add = seccomp_notif_addfd {
            id: request.id,
            flags: SECCOMP_ADDFD_FLAG_SEND as u32,
            srcfd: opened.as_raw_fd() as u32,
            newfd: 0,
            newfd_flags: (flags & O_CLOEXEC) as u32,
        };
        checked(unsafe { ioctl(fd, SECCOMP_IOCTL_NOTIF_ADDFD, &add) }).map(|_| ())
    })();
    if delivery.is_err() && created {
        rollback_created(&resolved, &opened);
    }
    delivery
}

/// E1b owns the notification loop. E1a keeps the resolver callable and
/// uncalled so this boundary can land independently.
pub(crate) fn run(_notify_fd: OwnedFd, _policy: WritePolicy, _stop: OwnedFd) -> io::Result<()> {
    Err(io::Error::other("user-notify supervisor not implemented"))
}

/// Resolver regression loops terminate at the end of their fixed input tables.
#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::symlink,
        sync::atomic::{AtomicUsize, Ordering},
    };

    struct Fixture(std::path::PathBuf);

    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "acpmux-resolver-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(path.join(".git/hooks")).expect("fixture directory");
            fs::create_dir_all(path.join("a/b")).expect("nested fixture directory");
            fs::write(path.join(".git/config"), b"protected").expect("fixture file");
            symlink(".git/config", path.join("link")).expect("fixture symlink");
            Self(fs::canonicalize(path).expect("canonical fixture"))
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn task() -> OwnedFd {
        open_at(AT_FDCWD, &format!("/proc/{}", std::process::id()), O_PATH | O_DIRECTORY, 0)
            .expect("proc task")
    }

    fn nspid() -> String {
        std::fs::read_to_string("/proc/self/status")
            .expect("status")
            .lines()
            .find_map(|line| line.strip_prefix("NSpid:").and_then(|p| p.split_whitespace().last()))
            .expect("NSpid")
            .to_owned()
    }

    #[test]
    fn review_write_open_rejects_unapproved_devices() {
        assert!(reject_write_device(S_IFCHR, makedev(5, 0)).is_err());
        assert!(reject_write_device(S_IFBLK, makedev(8, 0)).is_err());
    }

    #[test]
    fn delivery_object_types_use_device_numbers() {
        for minor in [3, 5, 7, 8, 9] {
            assert_eq!(reject_write_device(S_IFCHR | 0o666, makedev(1, minor)), Ok(()));
        }
        for (kind, device) in
            [(S_IFCHR, makedev(5, 0)), (S_IFCHR, makedev(1, 1)), (S_IFBLK, 0), (S_IFSOCK, 0)]
        {
            assert_eq!(reject_write_device(kind, device), Err(EACCES));
        }
        assert_eq!(reject_write_device(S_IFDIR, 0), Err(EISDIR));
    }

    #[test]
    fn review_id_valid_retries_interrupted_ioctl() {
        assert_eq!(valid_errno(EINTR), Ok(true));
        assert_eq!(valid_errno(ENOENT), Ok(false));
        assert!(valid_errno(EACCES).is_err());
    }

    // Finite hook-controlled swaps avoid racing test timing or privileged mounts.
    #[test]
    fn delivery_reopens_the_inspected_inode() {
        let fixture = Fixture::new();
        let leaf = fixture.0.join("leaf");
        fs::write(&leaf, b"original").unwrap();
        let resolved =
            resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid())
                .unwrap();
        let original = fs::File::open(&leaf).unwrap();
        let opened = open_leaf(&resolved, O_WRONLY, 0, || {
            fs::rename(&leaf, fixture.0.join("old")).unwrap();
            fs::write(&leaf, b"replacement").unwrap();
        })
        .unwrap()
        .0;
        assert_eq!(
            stat(opened.as_raw_fd()).unwrap().st_ino,
            stat(original.as_raw_fd()).unwrap().st_ino
        );
    }

    #[test]
    fn delivery_rolls_back_only_its_own_created_inode() {
        let fixture = Fixture::new();
        let leaf = fixture.0.join("new");
        let resolved = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            leaf.to_str().unwrap(),
            O_CREAT | O_WRONLY,
            &nspid(),
        )
        .unwrap();
        let opened = open_at(
            resolved.parent.as_raw_fd(),
            &resolved.name,
            O_CREAT | O_EXCL | O_WRONLY,
            0o600,
        )
        .unwrap();
        rollback_created(&resolved, &opened);
        assert!(!leaf.exists());
        fs::write(&leaf, b"replacement").unwrap();
        rollback_created(&resolved, &opened);
        assert_eq!(fs::read(&leaf).unwrap(), b"replacement");
    }

    #[test]
    fn delivery_fifo_swap_never_opens_the_replacement() {
        let fixture = Fixture::new();
        let leaf = fixture.0.join("leaf");
        fs::write(&leaf, b"original").unwrap();
        let fifo = CString::new(fixture.0.join("fifo").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let resolved =
            resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid())
                .unwrap();
        let opened = open_leaf(&resolved, O_WRONLY, 0, || {
            fs::rename(fixture.0.join("fifo"), &leaf).unwrap();
        })
        .unwrap()
        .0;
        assert_eq!(stat(opened.as_raw_fd()).unwrap().st_mode & S_IFMT, S_IFREG);
        assert!(matches!(open_leaf(&resolved, O_WRONLY, 0, || {}), Err(ENXIO)));
    }

    #[test]
    fn delivery_competing_creator_is_reopened_only_without_excl() {
        let fixture = Fixture::new();
        for exclusive in [0, O_EXCL] {
            let leaf = fixture.0.join(format!("created-{exclusive}"));
            let resolved = resolve(
                task().as_raw_fd(),
                AT_FDCWD,
                leaf.to_str().unwrap(),
                O_CREAT | O_WRONLY,
                &nspid(),
            )
            .unwrap();
            let result = open_leaf(&resolved, O_CREAT | O_WRONLY | exclusive, 0o600, || {
                fs::write(&leaf, b"competitor").unwrap();
            });
            if exclusive != 0 {
                assert!(matches!(result, Err(EEXIST)));
            } else {
                assert!(!result.unwrap().1, "must not roll back another creator's name");
            }
            assert_eq!(fs::read(&leaf).unwrap(), b"competitor");
        }
    }

    #[test]
    fn delivery_device_swap_never_opens_the_replacement() {
        let fixture = Fixture::new();
        let device = CString::new(fixture.0.join("device").to_str().unwrap()).unwrap();
        if unsafe { mknod(device.as_ptr(), S_IFCHR | 0o600, makedev(5, 0)) } < 0 {
            let errno = error();
            assert!(matches!(errno, EPERM | EACCES | EOPNOTSUPP));
            eprintln!("skipped: device fixture requires mknod permission: {errno}");
            return;
        }
        let leaf = fixture.0.join("leaf");
        fs::write(&leaf, b"original").unwrap();
        let resolved =
            resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid())
                .unwrap();
        let opened = open_leaf(&resolved, O_WRONLY, 0, || {
            fs::rename(fixture.0.join("device"), &leaf).unwrap();
        })
        .unwrap()
        .0;
        assert_eq!(stat(opened.as_raw_fd()).unwrap().st_mode & S_IFMT, S_IFREG);
        assert!(matches!(open_leaf(&resolved, O_WRONLY, 0, || {}), Err(EACCES)));
    }

    #[test]
    fn review_open_mode_preserves_umask_for_default_acl() {
        assert_eq!(open_mode(0o666, 0o077), 0o666);
    }

    #[test]
    fn review_filesystem_runner_directory_remains_supported() {
        let fixture = Fixture::new();
        let fd = open_at(AT_FDCWD, fixture.0.to_str().unwrap(), O_RDONLY | O_DIRECTORY, 0).unwrap();
        let _ = fd;
        let path = format!("{}/ordinary", fixture.0.display());
        let resolved =
            resolve(task().as_raw_fd(), AT_FDCWD, &path, O_CREAT | O_WRONLY, &nspid()).unwrap();
        assert_eq!(resolved.logical, path);
    }

    #[test]
    fn review_proc_fd_number_requires_canonical_decimal() {
        for (name, number) in [("0", 0), ("3", 3), ("2147483647", 2147483647)] {
            assert_eq!(proc_fd_number(name), Ok(number));
        }
        for name in [
            "03",
            "+3",
            "00",
            "-1",
            "",
            " 3",
            "3 ",
            "3x",
            "٣",
            "2147483648",
            "4294967295",
            "00000000003",
            "99999999999",
        ] {
            assert_eq!(proc_fd_number(name), Err(ENOENT), "noncanonical proc fd: {name:?}");
        }
    }

    #[test]
    fn review_proc_fd_aliases_reject_noncanonical_spelling() {
        let fixture = Fixture::new();
        let file = fs::File::create(fixture.0.join("output")).unwrap();
        let number = file.as_raw_fd();
        // Include the exact review examples, plus aliases of a known live fd.
        for spelling in
            ["03".to_owned(), "+3".to_owned(), format!("0{number}"), format!("+{number}")]
        {
            let path = format!("/proc/self/fd/{spelling}");
            assert!(matches!(open_at(AT_FDCWD, &path, O_PATH, 0), Err(ENOENT)));
            assert!(
                matches!(
                    resolve(task().as_raw_fd(), AT_FDCWD, &path, O_WRONLY | O_TRUNC, &nspid()),
                    Err(ENOENT)
                ),
                "translated invalid alias: {path}"
            );
        }
        assert_eq!(fs::metadata(fixture.0.join("output")).unwrap().len(), 0);
    }

    #[test]
    fn review_casefold_directory_checks_cover_entire_walk() {
        let fixture = Fixture::new();
        let target = format!("{}/a/b/new", fixture.0.display());
        // Every finite case marks a different directory, including root and
        // final parent; the injected reader identifies objects by inode.
        for directory in
            [Path::new("/"), fixture.0.as_path(), &fixture.0.join("a"), &fixture.0.join("a/b")]
        {
            let marked =
                open_at(AT_FDCWD, directory.to_str().unwrap(), O_PATH | O_DIRECTORY, 0).unwrap();
            let marked = stat(marked.as_raw_fd()).unwrap();
            let reader = |fd| {
                let current = stat(fd)?;
                Ok(if (current.st_dev, current.st_ino) == (marked.st_dev, marked.st_ino) {
                    0x4000_0000 // FS_CASEFOLD_FL
                } else {
                    0
                })
            };
            assert!(
                matches!(
                    resolve_with_flags(
                        task().as_raw_fd(),
                        AT_FDCWD,
                        &target,
                        O_CREAT | O_WRONLY,
                        &nspid(),
                        &reader
                    ),
                    Err(EACCES)
                ),
                "casefold directory: {}",
                directory.display()
            );
        }
        let directory = format!("{}/a/b", fixture.0.display());
        assert!(matches!(
            resolve_with_flags(
                task().as_raw_fd(),
                AT_FDCWD,
                &directory,
                O_RDONLY,
                &nspid(),
                &|_| Ok(0x4000_0000)
            ),
            Err(EACCES)
        ));
    }

    #[test]
    fn review_casefold_real_directory_refused() {
        let fixture = Fixture::new();
        let directory = fixture.0.join("folded");
        fs::create_dir(&directory).unwrap();
        let fd = open_at(AT_FDCWD, directory.to_str().unwrap(), O_RDONLY | O_DIRECTORY, 0).unwrap();
        let mut flags: c_long = 0;
        if unsafe { ioctl(fd.as_raw_fd(), FS_IOC_GETFLAGS, &mut flags) } < 0 {
            assert!(matches!(error(), EOPNOTSUPP | ENOTTY | EINVAL | EPERM | EACCES));
            eprintln!(
                "skipped: filesystem cannot read directory flags: {}",
                io::Error::last_os_error()
            );
            return;
        }
        flags |= 0x4000_0000;
        if unsafe { ioctl(fd.as_raw_fd(), FS_IOC_SETFLAGS, &flags) } < 0 {
            let errno = error();
            assert!(
                matches!(errno, EOPNOTSUPP | ENOTTY | EINVAL | EPERM | EACCES),
                "unexpected casefold setup errno: {errno}"
            );
            eprintln!(
                "skipped: cannot enable casefold on fixture filesystem: {}",
                io::Error::from_raw_os_error(errno)
            );
            return;
        }
        fs::write(directory.join("CLAUDE.md"), b"protected").unwrap();
        let target = format!("{}/claude.md", directory.display());
        assert!(matches!(
            resolve(task().as_raw_fd(), AT_FDCWD, &target, O_WRONLY | O_TRUNC, &nspid()),
            Err(EACCES)
        ));
    }

    #[test]
    fn review_trailing_slash_regular_file_is_not_write_opened() {
        let fixture = Fixture::new();
        symlink(".git/config/", fixture.0.join("slash-link")).unwrap();
        // The kernel rejects both original and symlink-target trailing slash.
        for suffix in [".git/config/", "slash-link"] {
            let path = format!("{}/{suffix}", fixture.0.display());
            assert!(matches!(open_at(AT_FDCWD, &path, O_WRONLY | O_TRUNC, 0), Err(ENOTDIR)));
            assert!(matches!(
                resolve(task().as_raw_fd(), AT_FDCWD, &path, O_WRONLY | O_TRUNC, &nspid()),
                Err(ENOTDIR)
            ));
        }
        assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
    }

    #[test]
    fn review_trailing_slash_requirement_survives_resolution() {
        let fixture = Fixture::new();
        symlink("missing/", fixture.0.join("missing-link")).unwrap();
        symlink("a/b/", fixture.0.join("directory-link")).unwrap();
        for suffix in ["missing/", "missing-link", "a/b/", "directory-link"] {
            let path = format!("{}/{suffix}", fixture.0.display());
            let resolved = resolve(task().as_raw_fd(), AT_FDCWD, &path, 0, &nspid()).unwrap();
            assert!(resolved.directory_required, "lost trailing slash: {suffix}");
        }
    }

    #[test]
    fn review_dirfd_must_be_an_actual_directory() {
        let fixture = Fixture::new();
        symlink("a", fixture.0.join("directory-link")).unwrap();
        for suffix in ["directory-link", ".git/config"] {
            let path = format!("{}/{suffix}", fixture.0.display());
            let fd = open_at(AT_FDCWD, &path, O_PATH | O_NOFOLLOW, 0).unwrap();
            assert!(matches!(
                open_at(fd.as_raw_fd(), "new", O_CREAT | O_WRONLY, 0o600),
                Err(ENOTDIR)
            ));
            assert!(matches!(
                resolve(task().as_raw_fd(), fd.as_raw_fd(), "new", O_CREAT | O_WRONLY, &nspid()),
                Err(ENOTDIR)
            ));
        }
        assert!(!fixture.0.join("a/new").exists());
    }

    #[test]
    fn review_cwd_and_dirfd_identity_must_match_rooted_walk() {
        let fixture = Fixture::new();
        let fake = fixture.0.join("task");
        let root = fixture.0.join("root-view");
        fs::create_dir_all(fake.join("fd")).unwrap();
        let actual = fixture.0.join("a/b");
        fs::create_dir_all(root.join(actual.strip_prefix("/").unwrap())).unwrap();
        symlink(&root, fake.join("root")).unwrap();
        symlink(&actual, fake.join("cwd")).unwrap();
        symlink(&actual, fake.join("fd/42")).unwrap();
        let task = open_at(AT_FDCWD, fake.to_str().unwrap(), O_PATH | O_DIRECTORY, 0).unwrap();
        // Both logical start paths exist under root, but address different inodes.
        for dir in [AT_FDCWD, 42] {
            assert!(matches!(
                resolve(task.as_raw_fd(), dir, "new", O_CREAT | O_WRONLY, &nspid()),
                Err(EACCES)
            ));
        }
    }

    #[test]
    fn walks_dotdot_and_symlink_to_a_logical_absolute_path() {
        let fixture = Fixture::new();
        let target = fixture.0.join("a/b/../../link");
        let target = target.to_str().expect("utf8 target");
        let resolved = resolve(task().as_raw_fd(), AT_FDCWD, target, O_WRONLY, &nspid())
            .expect("resolved link");
        assert_eq!(resolved.logical, format!("{}/.git/config", fixture.0.display()));
    }

    #[test]
    fn keeps_missing_final_component_as_parent_and_name() {
        let fixture = Fixture::new();
        let target = format!("{}/new-file", fixture.0.display());
        let resolved = resolve(task().as_raw_fd(), AT_FDCWD, &target, O_CREAT | O_WRONLY, &nspid())
            .expect("resolved missing final component");
        assert_eq!(resolved.name, "new-file");
        assert_eq!(resolved.logical, target);
        assert!(resolved.object.is_none());
    }

    #[test]
    fn refuses_proc_paths_except_fd_aliases() {
        assert!(matches!(
            resolve(task().as_raw_fd(), AT_FDCWD, "/proc/self/mem", O_WRONLY, &nspid()),
            Err(EACCES)
        ));
        // CI stdout may be an anonymous pipe, which the resolver deliberately
        // refuses. Use a named object, as the forked supervisor fixture does,
        // without replacing the test process's shared stdout descriptor.
        let fixture = Fixture::new();
        let target = fixture.0.join("output");
        let output = fs::File::create(&target).expect("named output");
        let number = output.as_raw_fd();
        let pid = nspid();
        // The finite alias table covers the same proc-fd route as /dev/stdout.
        for alias in [
            format!("/proc/self/fd/{number}"),
            format!("/proc/thread-self/fd/{number}"),
            format!("/proc/{pid}/fd/{number}"),
            format!("/dev/fd/{number}"),
        ] {
            let resolved = resolve(task().as_raw_fd(), AT_FDCWD, &alias, O_WRONLY, &pid)
                .expect("named fd alias");
            assert_eq!(Path::new(&resolved.logical), target.as_path());
            assert!(resolved.object.is_some());
        }
        let (socket, _peer) = std::os::unix::net::UnixStream::pair().expect("anonymous socket");
        let alias = format!("/proc/self/fd/{}", socket.as_raw_fd());
        assert!(matches!(
            resolve(task().as_raw_fd(), AT_FDCWD, &alias, O_WRONLY, &pid),
            Err(EACCES)
        ));
    }

    #[test]
    fn policy_is_checked_on_the_walked_logical_path() {
        let fixture = Fixture::new();
        let params = [
            ("CWD", fixture.0.clone()),
            ("TMPDIR", fixture.0.join("tmp")),
            ("HOME", fixture.0.join("home")),
            ("CLAUDE_TMP_PROJECT", fixture.0.join("scratch")),
            ("CLAUDE_PROJECT", fixture.0.join("transcript")),
        ]
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect();
        let policy = WritePolicy::from_profile(crate::hub::remote_sandbox::PROFILE, &params)
            .expect("profile policy");
        let resolved = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            &format!("{}/link", fixture.0.display()),
            O_WRONLY,
            &nspid(),
        )
        .expect("resolved policy path");
        assert!(policy.check(Path::new(&resolved.logical)).is_err());
    }
}
