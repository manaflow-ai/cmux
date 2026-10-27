//! Filesystem supervision; no production caller until G2.
//! Every mutation holds the same process-wide
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
mod mutations;

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
            // Mutation operations address a directory entry without following it.
            if queue.is_empty() && flags & (O_PATH | O_NOFOLLOW) == (O_PATH | O_NOFOLLOW) {
                if directory_required {
                    return Err(ENOTDIR);
                }
                return Ok(Resolved {
                    parent: stack.pop().ok_or(EACCES)?,
                    name,
                    logical: target.to_str().ok_or(EACCES)?.into(),
                    object: None,
                    directory_required,
                });
            }
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

/// Dedicated thread and sole listener receiver: unshares CLONE_FS before
/// clearing its own umask.
/// Stops on listener POLLHUP (all filtered processes exited), readable stop
/// eventfd, or a fatal I/O error. Every checked operation is emulated; response
/// flags are always zero, never CONTINUE. Policy/internal failures use EACCES.
/// Dropping the last listener (including acpmux death) fails pending and later
/// notified syscalls with ENOSYS: fail closed. All inner loops consume bounded
/// paths/collections; poll/RECV retries end on stop, HUP, or fatal I/O error.
pub(crate) fn run(notify_fd: OwnedFd, policy: WritePolicy, stop: OwnedFd) -> io::Result<()> {
    checked(unsafe { unshare(CLONE_FS) }).map_err(io::Error::from_raw_os_error)?;
    unsafe {
        umask(0);
    }
    let lock = locking::open(&policy).map_err(io::Error::from_raw_os_error)?;
    let mut sizes: seccomp_notif_sizes = unsafe { std::mem::zeroed() };
    checked(unsafe { syscall(SYS_seccomp, SECCOMP_GET_NOTIF_SIZES, 0, &mut sizes) } as i32)
        .map_err(io::Error::from_raw_os_error)?;
    if (sizes.seccomp_notif as usize) < size_of::<seccomp_notif>()
        || (sizes.seccomp_notif_resp as usize) < size_of::<seccomp_notif_resp>()
        || (sizes.seccomp_data as usize) < size_of::<seccomp_data>()
    {
        return Err(io::Error::from_raw_os_error(EACCES));
    }
    let mut receive = vec![0u64; (sizes.seccomp_notif as usize).div_ceil(8)];
    let mut response = vec![0u64; (sizes.seccomp_notif_resp as usize).div_ceil(8)];
    let fd = notify_fd.as_raw_fd();
    let mut polls = [
        pollfd { fd, events: POLLIN, revents: 0 },
        pollfd { fd: stop.as_raw_fd(), events: POLLIN, revents: 0 },
    ];
    loop {
        if unsafe { poll(polls.as_mut_ptr(), 2, -1) } < 0 {
            if error() == EINTR {
                continue;
            }
            return Err(io::Error::last_os_error());
        }
        if polls[0].revents & POLLHUP != 0 || polls[1].revents & POLLIN != 0 {
            return Ok(());
        }
        if polls.iter().any(|p| p.revents & (POLLERR | POLLNVAL | POLLHUP) != 0) {
            return Err(io::Error::from_raw_os_error(EACCES));
        }
        if polls[0].revents & POLLIN == 0 {
            continue;
        }
        receive.fill(0);
        if unsafe { ioctl(fd, SECCOMP_IOCTL_NOTIF_RECV, receive.as_mut_ptr()) } < 0 {
            if matches!(error(), EINTR | ENOENT | EAGAIN) {
                continue;
            }
            return Err(io::Error::last_os_error());
        }
        let request = unsafe { receive.as_ptr().cast::<seccomp_notif>().read() };
        let _transaction = match locking::acquire(&lock, stop.as_raw_fd(), fd) {
            Ok(guard) => guard,
            Err(ECANCELED) => return Ok(()),
            Err(errno) => return Err(io::Error::from_raw_os_error(errno)),
        };
        let result = if arguments(&request.data).is_ok() {
            emulate(fd, &request, &policy, stop.as_raw_fd()).map(|()| None)
        } else {
            mutations::emulate(fd, &request, &policy, stop.as_raw_fd())
        };
        let (value, errno) = match result {
            Ok(None) => continue,
            Ok(Some(value)) => (value, 0),
            Err(errno) => (0, errno),
        };
        let reply = seccomp_notif_resp { id: request.id, val: value, error: -errno, flags: 0 };
        unsafe {
            response.as_mut_ptr().cast::<seccomp_notif_resp>().write(reply);
        }
        if unsafe { ioctl(fd, SECCOMP_IOCTL_NOTIF_SEND, response.as_ptr()) } < 0
            && error() != ENOENT
        {
            return Err(io::Error::last_os_error());
        }
    }
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

#[cfg(test)]
mod notification_tests {
    include!("supervisor/review_tests.rs");
    use super::*;
    use crate::{
        hub::remote_sandbox::PROFILE,
        linux_sandbox::{rules::Params, seccomp},
    };
    use std::{
        ffi::CString,
        fs,
        os::{
            fd::{AsRawFd, FromRawFd, RawFd},
            unix::fs::{PermissionsExt, symlink},
        },
        path::PathBuf,
        sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering},
        time::Duration,
    };

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let p = std::env::temp_dir().join(format!(
                "acpmux-notify-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&p).unwrap();
            for dir in [".git/hooks", "sub", "a", "good", "tmp", "home", "scratch", "transcript"] {
                fs::create_dir_all(p.join(dir)).unwrap();
            }
            fs::write(p.join(".git/config"), b"protected").unwrap();
            fs::write(p.join("existing"), b"existing-content").unwrap();
            symlink(".git/config", p.join("link")).unwrap();
            Self(fs::canonicalize(p).unwrap())
        }
        fn policy(&self) -> WritePolicy {
            let params: Params = [
                ("CWD", ""),
                ("TMPDIR", "tmp"),
                ("HOME", "home"),
                ("CLAUDE_TMP_PROJECT", "scratch"),
                ("CLAUDE_PROJECT", "transcript"),
            ]
            .into_iter()
            .map(|(k, v)| (k.into(), if v.is_empty() { self.0.clone() } else { self.0.join(v) }))
            .collect();
            WritePolicy::from_profile(PROFILE, &params).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    // Aligned control storage; send/recv each transfer exactly one fd.
    unsafe fn transfer(socket: RawFd, fd: RawFd, send: bool) -> RawFd {
        unsafe {
            let mut byte = 0u8;
            let mut iov = iovec { iov_base: (&mut byte as *mut u8).cast(), iov_len: 1 };
            let mut control = [0usize; 8];
            let mut msg: msghdr = std::mem::zeroed();
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = CMSG_SPACE(std::mem::size_of::<RawFd>() as _) as _;
            if send {
                let c = CMSG_FIRSTHDR(&msg);
                (*c).cmsg_level = SOL_SOCKET;
                (*c).cmsg_type = SCM_RIGHTS;
                (*c).cmsg_len = CMSG_LEN(std::mem::size_of::<RawFd>() as _) as _;
                CMSG_DATA(c).cast::<RawFd>().write(fd);
                return if sendmsg(socket, &msg, MSG_NOSIGNAL) == 1 { 0 } else { -1 };
            }
            if recvmsg(socket, &mut msg, MSG_CMSG_CLOEXEC) != 1 || msg.msg_flags & MSG_CTRUNC != 0 {
                return -1;
            }
            let c = CMSG_FIRSTHDR(&msg);
            if c.is_null() {
                return -1;
            }
            let len: usize = (*c).cmsg_len as _;
            let expected_len: usize = CMSG_LEN(std::mem::size_of::<RawFd>() as _) as _;
            if (*c).cmsg_level != SOL_SOCKET || (*c).cmsg_type != SCM_RIGHTS || len != expected_len
            {
                return -1;
            }
            CMSG_DATA(c).cast::<RawFd>().read()
        }
    }

    static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Child lifetime is bounded by SIGALRM; every post-fork call is raw libc.
    /// Parent loops end at child exit/error; recv and supervisor joins have deadlines.
    fn exercise(case: u8, paths: &[CString]) -> Option<(Fixture, i32)> {
        // Serialize forks so another case cannot inherit and keep our listener alive.
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let fixture = Fixture::new();
        if case == 210 {
            fs::remove_dir_all(fixture.0.join(".git")).unwrap();
        }
        if case == 200 {
            let fifo = CString::new(fixture.0.join("fifo").to_str().unwrap()).unwrap();
            assert_eq!(unsafe { mkfifo(fifo.as_ptr(), 0o600) }, 0);
        }
        if (4..=16).contains(&case) || case == 18 {
            fs::write(fixture.0.join(".git/hooks/pre-commit.sample"), b"protected").unwrap();
            fs::write(fixture.0.join("CLAUDE.md"), b"instructions").unwrap();
            fs::write(fixture.0.join("ordinary"), b"ordinary").unwrap();
            fs::set_permissions(fixture.0.join("ordinary"), fs::Permissions::from_mode(0o600))
                .unwrap();
            if case == 4 || case == 8 {
                fs::remove_dir_all(fixture.0.join(".git")).unwrap();
                if case == 8 {
                    fs::create_dir(fixture.0.join(".git")).unwrap();
                }
            }
        }
        let mut paths = paths.to_vec();
        paths.push(
            CString::new(fixture.0.join(".git/config").as_os_str().as_encoded_bytes()).unwrap(),
        );
        let cwd = CString::new(fixture.0.as_os_str().as_encoded_bytes()).unwrap();
        let program = seccomp::filter(true).unwrap();
        unsafe {
            let mut action = SECCOMP_RET_USER_NOTIF;
            if syscall(SYS_seccomp, SECCOMP_GET_ACTION_AVAIL, 0, &mut action) < 0 {
                let e = io::Error::last_os_error();
                if matches!(e.raw_os_error(), Some(EINVAL | ENOSYS | EOPNOTSUPP)) {
                    eprintln!("skipped: kernel lacks USER_NOTIF: {e}");
                    return None;
                }
                panic!("USER_NOTIF probe: {e}");
            }
            let mut sockets = [-1; 2];
            assert_eq!(
                socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets.as_mut_ptr()),
                0
            );
            let parent = OwnedFd::from_raw_fd(sockets[0]);
            let child = OwnedFd::from_raw_fd(sockets[1]);
            let stop = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
            assert!(stop >= 0);
            let stop = OwnedFd::from_raw_fd(stop);
            let thread_stop = stop.try_clone().unwrap();
            let pid = fork();
            assert!(pid >= 0);
            if pid == 0 {
                let mut mask: sigset_t = std::mem::zeroed();
                sigemptyset(&mut mask);
                sigprocmask(SIG_SETMASK, &mask, std::ptr::null_mut());
                signal(SIGALRM, SIG_DFL);
                alarm(15);
                close(parent.as_raw_fd());
                close(stop.as_raw_fd());
                close(thread_stop.as_raw_fd());
                if chdir(cwd.as_ptr()) != 0 {
                    _exit(90);
                }
                // A real policy-allowed stdout; no dependence on the CI log sink.
                let output = open(c"stdout".as_ptr(), O_CREAT | O_WRONLY, 0o600);
                if output < 0 || dup2(output, 1) < 0 {
                    _exit(91);
                }
                close(output);
                if prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
                    _exit(92);
                }
                let prog =
                    sock_fprog { len: program.len() as u16, filter: program.as_ptr().cast_mut() };
                // UAPI TSYNC_ESRCH = 1 << 4: required with TSYNC + NEW_LISTENER.
                let listener = syscall(
                    SYS_seccomp,
                    SECCOMP_SET_MODE_FILTER,
                    SECCOMP_FILTER_FLAG_NEW_LISTENER | SECCOMP_FILTER_FLAG_TSYNC | (1 << 4),
                    &prog,
                ) as i32;
                if listener < 0 {
                    if *__errno_location() != EINVAL {
                        _exit(93);
                    }
                    // Distinguish an invalid generated BPF program from absent kernel flags.
                    let mut allow = sock_filter {
                        code: (BPF_RET | BPF_K) as u16,
                        jt: 0,
                        jf: 0,
                        k: SECCOMP_RET_ALLOW,
                    };
                    let probe = sock_fprog { len: 1, filter: &mut allow };
                    let rc = syscall(
                        SYS_seccomp,
                        SECCOMP_SET_MODE_FILTER,
                        SECCOMP_FILTER_FLAG_NEW_LISTENER | SECCOMP_FILTER_FLAG_TSYNC | (1 << 4),
                        &probe,
                    );
                    _exit(if rc < 0 && *__errno_location() == EINVAL { 77 } else { 93 });
                }
                if transfer(child.as_raw_fd(), listener, true) < 0 {
                    _exit(94);
                }
                close(listener);
                let mut ack = 0u8;
                if read(child.as_raw_fd(), (&mut ack as *mut u8).cast(), 1) != 1 {
                    _exit(95);
                }
                if ack == 77 {
                    _exit(77);
                }
                close(child.as_raw_fd());
                _exit(child_case(case, &paths));
            }
            drop(child);
            let mut ready = pollfd { fd: parent.as_raw_fd(), events: POLLIN, revents: 0 };
            assert_eq!(poll(&mut ready, 1, 20_000), 1, "listener handoff timed out");
            let fd = transfer(parent.as_raw_fd(), -1, false);
            if fd < 0 {
                let mut status = 0;
                assert_eq!(waitpid(pid, &mut status, 0), pid);
                if WIFEXITED(status) && WEXITSTATUS(status) == 77 {
                    eprintln!("skipped: kernel lacks NEW_LISTENER with TSYNC_ESRCH");
                    return None;
                }
                panic!("listener handoff failed: child status {status:#x}");
            }
            let listener = OwnedFd::from_raw_fd(fd);
            // ADDFD UAPI ioctl; an invalid notification must yield ENOENT on a supporting kernel.
            let addfd = [0u64, (fd as u64) << 32, 0];
            assert_eq!(ioctl(fd, SECCOMP_IOCTL_NOTIF_ADDFD, addfd.as_ptr()), -1);
            let missing = *__errno_location() == ENOTTY;
            assert!(
                missing || *__errno_location() == ENOENT,
                "ADDFD probe: {}",
                io::Error::last_os_error()
            );
            let (tx, rx) = std::sync::mpsc::channel();
            let handle = if case == 2 || missing {
                drop(listener);
                None
            } else {
                let policy = fixture.policy();
                Some(std::thread::spawn(move || {
                    let _ = tx.send(run(listener, policy, thread_stop));
                }))
            };
            let ack = if missing { 77u8 } else { 1 };
            let early_result = if case == 1 && !missing {
                assert_eq!(write(stop.as_raw_fd(), (&1u64 as *const u64).cast(), 8), 8);
                // Child remains alive, blocked on ack: HUP cannot satisfy this case.
                Some(rx.recv_timeout(Duration::from_secs(3)))
            } else {
                None
            };
            assert_eq!(write(parent.as_raw_fd(), (&ack as *const u8).cast(), 1), 1);
            let mut status = 0;
            loop {
                if waitpid(pid, &mut status, 0) == pid {
                    break;
                }
                assert_eq!(*__errno_location(), EINTR);
            }
            if let Some(handle) = handle {
                let result =
                    early_result.unwrap_or_else(|| rx.recv_timeout(Duration::from_secs(3)));
                if result.is_err() {
                    let _ = write(stop.as_raw_fd(), (&1u64 as *const u64).cast(), 8);
                }
                assert!(result.is_ok(), "supervisor failed to stop on child exit/eventfd");
                handle.join().unwrap();
                result.unwrap().expect("supervisor returned an internal error");
            }
            assert!(WIFEXITED(status), "child status {status:#x}");
            if missing {
                eprintln!("skipped: kernel lacks SECCOMP_IOCTL_NOTIF_ADDFD");
                return None;
            }
            Some((fixture, WEXITSTATUS(status)))
        }
    }

    /// Two children have independent filters/listeners; all forks precede the
    /// supervisor threads. Finite 1000-call loops and child alarms bound work.
    #[test]
    fn mutation_two_supervisors_cannot_create_through_a_renamed_parent() {
        if exercise(1, &[]).is_none() {
            return;
        } // Existing kernel capability probes.
        let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let fixture = Fixture::new();
        fs::create_dir(fixture.0.join("cache")).unwrap();
        let cwd = CString::new(fixture.0.as_os_str().as_encoded_bytes()).unwrap();
        let program = seccomp::filter(true).unwrap();
        let mut sockets = [[-1; 2]; 2];
        let mut listeners: Vec<OwnedFd> = Vec::new();
        let mut children = Vec::new();
        unsafe {
            for pair in &mut sockets {
                assert_eq!(
                    socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair.as_mut_ptr()),
                    0
                );
            }
            for (i, pair) in sockets.iter().enumerate() {
                let pid = fork();
                assert!(pid >= 0);
                if pid == 0 {
                    for listener in &listeners {
                        close(listener.as_raw_fd());
                    }
                    for pair in sockets {
                        for fd in pair {
                            if fd != sockets[i][1] {
                                close(fd);
                            }
                        }
                    }
                    let mut mask: sigset_t = std::mem::zeroed();
                    sigemptyset(&mut mask);
                    sigprocmask(SIG_SETMASK, &mask, std::ptr::null_mut());
                    signal(SIGALRM, SIG_DFL);
                    alarm(30);
                    if chdir(cwd.as_ptr()) != 0 || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
                        _exit(90);
                    }
                    let prog = sock_fprog {
                        len: program.len() as u16,
                        filter: program.as_ptr().cast_mut(),
                    };
                    let fd = syscall(
                        SYS_seccomp,
                        SECCOMP_SET_MODE_FILTER,
                        SECCOMP_FILTER_FLAG_NEW_LISTENER | SECCOMP_FILTER_FLAG_TSYNC | (1 << 4),
                        &prog,
                    ) as i32;
                    if fd < 0 || transfer(sockets[i][1], fd, true) < 0 {
                        _exit(91);
                    }
                    close(fd);
                    let mut ack = 0u8;
                    if read(sockets[i][1], (&mut ack as *mut u8).cast(), 1) != 1 {
                        _exit(92);
                    }
                    for _ in 0..1000 {
                        if i == 0 {
                            let fd = open(c"cache/config".as_ptr(), O_CREAT | O_WRONLY, 0o600);
                            if fd < 0 {
                                _exit(93);
                            }
                            close(fd);
                        } else {
                            let rc = renameat(
                                AT_FDCWD,
                                c"cache".as_ptr(),
                                AT_FDCWD,
                                c".git/hooks/cache".as_ptr(),
                            );
                            if rc != -1 || !matches!(*__errno_location(), EACCES | EPERM) {
                                _exit(94);
                            }
                            let rc = renameat(
                                AT_FDCWD,
                                c".git/hooks/cache".as_ptr(),
                                AT_FDCWD,
                                c"cache".as_ptr(),
                            );
                            if rc != -1 {
                                _exit(95);
                            }
                        }
                    }
                    _exit(0);
                }
                children.push(pid);
                close(pair[1]);
                let mut ready = pollfd { fd: pair[0], events: POLLIN, revents: 0 };
                assert_eq!(poll(&mut ready, 1, 5000), 1);
                let fd = transfer(pair[0], -1, false);
                assert!(fd >= 0);
                listeners.push(OwnedFd::from_raw_fd(fd));
            }
            let mut workers = Vec::new();
            for (i, listener) in listeners.into_iter().enumerate() {
                let stop = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
                assert!(stop >= 0);
                let stop = OwnedFd::from_raw_fd(stop);
                let thread_stop = stop.try_clone().unwrap();
                let policy = fixture.policy();
                let (tx, rx) = std::sync::mpsc::channel();
                let thread = std::thread::spawn(move || {
                    let _ = tx.send(run(listener, policy, thread_stop));
                });
                workers.push((stop, rx, thread));
                assert_eq!(write(sockets[i][0], (&1u8 as *const u8).cast(), 1), 1);
                close(sockets[i][0]);
            }
            let mut statuses = Vec::new();
            for pid in children {
                let mut status = 0;
                while waitpid(pid, &mut status, 0) != pid {
                    assert_eq!(error(), EINTR);
                }
                statuses.push(status);
            }
            for (stop, rx, thread) in workers {
                let result = rx.recv_timeout(Duration::from_secs(3));
                if result.is_err() {
                    let _ = write(stop.as_raw_fd(), (&1u64 as *const u64).cast(), 8);
                }
                thread.join().unwrap();
                result.unwrap().unwrap();
            }
            assert!(
                statuses.iter().all(|s| WIFEXITED(*s) && WEXITSTATUS(*s) == 0),
                "children: {statuses:?}"
            );
        }
        assert!(!fixture.0.join(".git/hooks/cache/config").exists());
        assert!(fixture.0.join("cache/config").exists());
    }

    /// Finite syscall cases; SIGALRM bounds blocking opens and the race worker.
    unsafe fn child_case(case: u8, paths: &[CString]) -> i32 {
        unsafe {
            if case >= 210 {
                return review_case(case);
            }
            if case == 1 {
                return 0;
            }
            if case == 2 {
                let fd = open(c"gone".as_ptr(), O_CREAT | O_WRONLY, 0o600);
                return if fd == -1 && *__errno_location() == ENOSYS { 0 } else { 1 };
            }
            if case == 3 {
                return race();
            }
            if case == 200 {
                if open(c"fifo".as_ptr(), O_WRONLY) != -1 || *__errno_location() != ENXIO {
                    return 78;
                }
                let fd = open(c"existing".as_ptr(), O_WRONLY);
                if fd < 0 {
                    return 79;
                }
                close(fd);
                return 0;
            }
            if case == 17 {
                let limit = rlimit { rlim_cur: 32, rlim_max: 32 };
                if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
                    return 70;
                }
                for fd in 3..1024 {
                    close(fd);
                }
                // Exactly 29 available slots; filling uses no post-fork allocation.
                for expected in 3..32 {
                    if dup(1) != expected {
                        return 73;
                    }
                }
                let fd = open(c"existing".as_ptr(), O_WRONLY | O_TRUNC);
                if fd >= 0 || *__errno_location() != EMFILE {
                    return 71;
                }
                let fd = open(c"new".as_ptr(), O_WRONLY | O_CREAT, 0o600);
                if fd >= 0 || *__errno_location() != EMFILE {
                    return 72;
                }
                for fd in 3..32 {
                    close(fd);
                }
                // Failed opens with room must not leave placeholder descriptors.
                for _ in 0..3 {
                    if open(c"absent/file".as_ptr(), O_CREAT | O_WRONLY, 0o600) != -1 {
                        return 74;
                    }
                    if open(c"a".as_ptr(), O_CREAT | O_WRONLY, 0o600) != -1 {
                        return 75;
                    }
                }
                for fd in 3..32 {
                    if fcntl(fd, F_GETFD) != -1 || *__errno_location() != EBADF {
                        return 76;
                    }
                }
                return 0;
            }
            if case >= 4 {
                return mutation_case(case);
            }
            for (i, path) in paths.iter().enumerate() {
                let fd = open(path.as_ptr(), O_CREAT | O_WRONLY | O_TRUNC, 0o666);
                if fd >= 0 {
                    close(fd);
                    return 10 + i as i32;
                }
                if !matches!(*__errno_location(), EACCES | EPERM) {
                    return 30 + i as i32;
                }
            }
            let dir = open(c".git".as_ptr(), O_RDONLY | O_DIRECTORY);
            let fd = openat(dir, c"config".as_ptr(), O_WRONLY);
            close(dir);
            if fd >= 0 || !matches!(*__errno_location(), EACCES | EPERM) {
                return 50;
            }
            if chdir(c".git".as_ptr()) != 0 {
                return 51;
            }
            let fd = open(c"config".as_ptr(), O_WRONLY);
            if fd >= 0 || !matches!(*__errno_location(), EACCES | EPERM) {
                return 52;
            }
            if chdir(c"..".as_ptr()) != 0 {
                return 53;
            }
            let original = open(c".git/config".as_ptr(), O_RDONLY);
            if original < 0 || dup2(original, 200) != 200 {
                return 54;
            }
            close(original);
            let fd = open(c"/proc/self/fd/200".as_ptr(), O_WRONLY);
            close(200);
            if fd >= 0 || !matches!(*__errno_location(), EACCES | EPERM) {
                return 55;
            }
            for path in [c"/dev/stdout", c"/proc/self/fd/1", c"/proc/thread-self/fd/1", c"ok"] {
                let fd = open(path.as_ptr(), O_WRONLY | O_CREAT | O_CLOEXEC, 0o600);
                if fd < 0
                    || fcntl(fd, F_GETFD) & FD_CLOEXEC == 0
                    || write(fd, c"x".as_ptr().cast(), 1) != 1
                {
                    return 56;
                }
                close(fd);
            }
            umask(0o027);
            let fd = open(c"mode".as_ptr(), O_CREAT | O_WRONLY, 0o666);
            if fd < 0 {
                return 57;
            }
            close(fd);
            umask(0);
            let fd = open(c"mode-unmasked".as_ptr(), O_CREAT | O_WRONLY, 0o666);
            if fd < 0 {
                return 62;
            }
            close(fd);
            #[cfg(target_arch = "x86_64")]
            {
                let fd = syscall(SYS_creat, c"created".as_ptr(), 0o600) as i32;
                if fd < 0 {
                    return 58;
                }
                close(fd);
                let fd = syscall(SYS_open, c".git/config".as_ptr(), O_WRONLY) as i32;
                if fd >= 0 || !matches!(*__errno_location(), EACCES | EPERM) {
                    return 59;
                }
            }
            0
        }
    }

    #[test]
    fn write_opens_resolve_paths_and_child_exit_stops_supervisor() {
        let paths: Vec<_> = [
            ".git/hooks/pre-commit",
            "sub/CLAUDE.md",
            "link",
            "/proc/self/mem",
            "a/../.git/config",
        ]
        .into_iter()
        .map(|p| CString::new(p).unwrap())
        .collect();
        if let Some((fixture, status)) = exercise(0, &paths) {
            assert_eq!(status, 0, "child case failed");
            assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
            assert!(!fixture.0.join("sub/CLAUDE.md").exists());
            assert_eq!(fs::read(fixture.0.join("ok")).unwrap(), b"x");
            assert_eq!(
                fs::metadata(fixture.0.join("mode")).unwrap().permissions().mode() & 0o777,
                0o640
            );
            assert_eq!(
                fs::metadata(fixture.0.join("mode-unmasked")).unwrap().permissions().mode() & 0o777,
                0o666
            );
        }
    }

    #[test]
    fn target_fd_exhaustion_rolls_back_creation_without_fd_leaks() {
        if let Some((fixture, status)) = exercise(17, &[]) {
            assert_eq!(status, 0, "child case failed");
            // Policy-permitted O_TRUNC can precede EMFILE; contents are not restored.
            assert!(!fixture.0.join("new").exists());
        }
    }

    #[test]
    fn fifo_without_reader_returns_enxio_and_supervisor_keeps_serving() {
        if let Some((_, status)) = exercise(200, &[]) {
            assert_eq!(status, 0, "FIFO open blocked or next request failed");
        }
    }

    #[test]
    fn stop_eventfd_ends_supervisor() {
        if let Some((_, status)) = exercise(1, &[]) {
            assert_eq!(status, 0);
        }
    }

    #[test]
    fn supervisor_gone_fails_closed() {
        if let Some((fixture, status)) = exercise(2, &[]) {
            assert_eq!(status, 0);
            assert!(!fixture.0.join("gone").exists());
        }
    }

    /// Each case runs a finite syscall sequence; the harness's child alarm
    /// bounds any blocking operation. No allocations or unwinding after fork.
    unsafe fn mutation_case(case: u8) -> i32 {
        unsafe {
            let at = AT_FDCWD;
            let hook = c".git/hooks/pre-commit.sample".as_ptr();
            let ordinary = c"ordinary".as_ptr();
            let times = [timespec { tv_sec: 123, tv_nsec: 456 }; 2];
            if case == 16 {
                if renameat(at, ordinary, at, c"renamed".as_ptr()) != 0 {
                    return 110;
                }
                if fchmodat(at, c"renamed".as_ptr(), 0o640, 0) != 0 {
                    return 111;
                }
                if utimensat(at, c"renamed".as_ptr(), times.as_ptr(), 0) != 0 {
                    return 112;
                }
                let fd = open(c"renamed".as_ptr(), O_RDONLY | O_CLOEXEC);
                let mut metadata: libc::stat = std::mem::zeroed();
                if fd < 0 || fstat(fd, &mut metadata) != 0 {
                    return 119;
                }
                close(fd);
                if metadata.st_mode & 0o777 != 0o640
                    || metadata.st_mtime != 123
                    || metadata.st_mtime_nsec != 456
                {
                    return 120;
                }
                if unlinkat(at, c"renamed".as_ptr(), 0) != 0 {
                    return 113;
                }
                return 0;
            }
            let rc = match case {
                4 => renameat(at, c"a".as_ptr(), at, c".git".as_ptr()) as c_long,
                18 => renameat(at, c"a".as_ptr(), at, c".git/cache".as_ptr()) as c_long,
                5 => renameat(at, ordinary, at, c".git/hooks/new".as_ptr()) as c_long,
                6 => renameat(at, c".git".as_ptr(), at, c"moved-git".as_ptr()) as c_long,
                7 => syscall(SYS_renameat2, at, ordinary, at, hook, RENAME_EXCHANGE),
                8 => unlinkat(at, c".git".as_ptr(), AT_REMOVEDIR) as c_long,
                9 => unlinkat(at, c"CLAUDE.md".as_ptr(), 0) as c_long,
                10 => fchmodat(at, hook, 0o755, 0) as c_long,
                11 | 12 => {
                    let fd = open(hook, O_RDONLY | O_CLOEXEC);
                    if fd < 0 {
                        return 114;
                    }
                    let result = if case == 11 { fchmod(fd, 0o755) } else { ftruncate(fd, 0) };
                    let saved = *__errno_location();
                    close(fd);
                    *__errno_location() = saved;
                    result as c_long
                }
                13 => utimensat(at, c".git/config".as_ptr(), times.as_ptr(), 0) as c_long,
                14 => setxattr(
                    c"CLAUDE.md".as_ptr(),
                    c"user.acpmux".as_ptr(),
                    c"x".as_ptr().cast(),
                    1,
                    0,
                ) as c_long,
                15 => {
                    syscall(SYS_renameat2, at, ordinary, at, c"whiteout".as_ptr(), RENAME_WHITEOUT)
                }
                _ => return 115,
            };
            let errno = *__errno_location();
            if rc != -1 {
                return 116;
            }
            if case == 15 {
                return if errno == EPERM { 0 } else { 117 };
            }
            if matches!(errno, EACCES | EPERM) { 0 } else { 118 }
        }
    }

    macro_rules! mutation_test {
        ($name:ident, $case:literal) => {
            #[test]
            fn $name() {
                if let Some((fixture, status)) = exercise($case, &[]) {
                    assert_eq!(
                        status, 0,
                        "mutation child failed (116 = allowed; 118 = wrong errno)"
                    );
                    assert_eq!(fs::read(fixture.0.join("ordinary")).unwrap(), b"ordinary");
                    assert_eq!(fs::read(fixture.0.join("CLAUDE.md")).unwrap(), b"instructions");
                    if $case != 4 && $case != 8 {
                        let hook = fixture.0.join(".git/hooks/pre-commit.sample");
                        assert_eq!(fs::read(&hook).unwrap(), b"protected");
                        assert_eq!(fs::metadata(hook).unwrap().permissions().mode() & 0o111, 0);
                        assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
                    }
                }
            }
        };
    }

    mutation_test!(mutation_rename_directory_to_git_denied, 4);
    mutation_test!(mutation_rename_into_hooks_denied, 5);
    mutation_test!(mutation_rename_git_away_denied, 6);
    mutation_test!(mutation_exchange_hooks_denied, 7);
    mutation_test!(mutation_remove_git_denied, 8);
    mutation_test!(mutation_remove_instructions_denied, 9);
    mutation_test!(mutation_chmod_hook_denied, 10);
    mutation_test!(mutation_fchmod_readonly_hook_denied, 11);
    mutation_test!(mutation_ftruncate_readonly_hook_denied, 12);
    mutation_test!(mutation_utimensat_git_config_denied, 13);
    mutation_test!(mutation_setxattr_instructions_denied, 14);
    mutation_test!(mutation_whiteout_always_denied, 15);
    mutation_test!(mutation_directory_relocation_requires_subtree_checks, 18);

    #[test]
    fn mutation_ordinary_cwd_changes_allowed() {
        if let Some((fixture, status)) = exercise(16, &[]) {
            assert_eq!(status, 0, "ordinary mutation failed");
            assert!(!fixture.0.join("ordinary").exists());
            assert!(!fixture.0.join("renamed").exists());
            assert_eq!(fs::read(fixture.0.join("CLAUDE.md")).unwrap(), b"instructions");
        }
    }

    #[repr(C)]
    struct RacingPath {
        prefix: AtomicU32,
        tail: [u8; 8],
        stop: AtomicBool,
    }

    /// Worker stops when the finite 10k-open loop sets stop; child alarm bounds both.
    extern "C" fn flip(data: *mut c_void) -> *mut c_void {
        let path = unsafe { &*data.cast::<RacingPath>() };
        while !path.stop.load(Ordering::Relaxed) {
            path.prefix.store(u32::from_ne_bytes(*b".git"), Ordering::Relaxed);
            path.prefix.store(u32::from_ne_bytes(*b"good"), Ordering::Relaxed);
        }
        std::ptr::null_mut()
    }

    /// Exactly 10k write-open attempts; worker is joined before its path is dropped.
    unsafe fn race() -> i32 {
        unsafe {
            let mut path = RacingPath {
                prefix: AtomicU32::new(u32::from_ne_bytes(*b"good")),
                tail: *b"/config\0",
                stop: AtomicBool::new(false),
            };
            let mut thread = std::mem::zeroed();
            if pthread_create(
                &mut thread,
                std::ptr::null(),
                flip,
                (&mut path as *mut RacingPath).cast(),
            ) != 0
            {
                return 60;
            }
            let pointer = (&path as *const RacingPath).cast::<c_char>();
            for _ in 0..10_000 {
                let fd = open(pointer, O_CREAT | O_WRONLY | O_TRUNC, 0o600);
                if fd >= 0 {
                    close(fd);
                }
            }
            path.stop.store(true, Ordering::Relaxed);
            if pthread_join(thread, std::ptr::null_mut()) != 0 {
                return 61;
            }
            0
        }
    }

    #[test]
    fn copied_path_is_not_changed_by_a_sibling_thread() {
        if let Some((fixture, status)) = exercise(3, &[]) {
            assert_eq!(status, 0);
            assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
        }
    }
}
