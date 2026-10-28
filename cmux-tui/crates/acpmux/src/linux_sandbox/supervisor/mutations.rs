//! Name and metadata operations; the caller holds both transaction locks.
//! Loops end after fixed arrays/buffers. Directory renames are refused because
//! checking only two names cannot protect descendants moved into persistence paths.
//! A symlink inserted after resolution is refused for truncate/chmod/fd-xattr;
//! chown, timestamps and pathname xattrs never follow the final symlink.
use super::*;

const FCHMODAT2: c_long = 452;
const SETXATTRAT: c_long = 463;
const REMOVEXATTRAT: c_long = 466;

enum Operation {
    Mkdir(mode_t),
    Mknod(mode_t, dev_t),
    Symlink(CString),
    Rename(i32, String, u32),
    Unlink(i32),
    Truncate(off_t),
    Chmod(mode_t),
    Chown(uid_t, gid_t),
    Times(Option<[timespec; 2]>),
    Xattr(CString, Option<Vec<u8>>, i32),
}

// Finite, bounded copies: no target pointers are ever passed to emulated calls.
fn bytes(pid: u32, address: u64, length: usize) -> Result<Vec<u8>> {
    if length > 65536 {
        return Err(E2BIG);
    }
    let mut data = vec![0u8; length];
    if length == 0 {
        return Ok(data);
    }
    let local = iovec { iov_base: data.as_mut_ptr().cast(), iov_len: length };
    let remote = iovec { iov_base: address as *mut c_void, iov_len: length };
    if unsafe { process_vm_readv(pid as i32, &local, 1, &remote, 1, 0) } != length as isize {
        return Err(EFAULT);
    }
    Ok(data)
}

// Only integer-only C layouts are copied by these private call sites.
fn value<T: Copy>(pid: u32, address: u64) -> Result<T> {
    let data = bytes(pid, address, size_of::<T>())?;
    Ok(unsafe { data.as_ptr().cast::<T>().read_unaligned() })
}

fn times(pid: u32, address: u64, format: u8) -> Result<Option<[timespec; 2]>> {
    if address == 0 {
        return Ok(None);
    }
    let result = match format {
        1 => {
            let t: utimbuf = value(pid, address)?;
            [timespec { tv_sec: t.actime, tv_nsec: 0 }, timespec { tv_sec: t.modtime, tv_nsec: 0 }]
        }
        2 => {
            let t: [timeval; 2] = value(pid, address)?;
            if t.iter().any(|t| !(0..1_000_000).contains(&t.tv_usec)) {
                return Err(EINVAL);
            }
            t.map(|t| timespec { tv_sec: t.tv_sec, tv_nsec: t.tv_usec * 1000 })
        }
        _ => value(pid, address)?,
    };
    Ok(Some(result))
}

pub(super) fn emulate(
    listener: RawFd,
    request: &seccomp_notif,
    policy: &WritePolicy,
    stop: RawFd,
) -> Result<Option<i64>> {
    let task = open_at(AT_FDCWD, &format!("/proc/{}", request.pid), O_PATH | O_DIRECTORY, 0)
        .map_err(|_| EACCES)?;
    let pid = request.pid;
    let mut n = request.data.nr as c_long;
    let mut a = request.data.args;
    #[allow(unused_mut)]
    let mut time_format = 0;
    // Normalize legacy layouts to their *at equivalents before copying paths.
    #[cfg(target_arch = "x86_64")]
    {
        if n == SYS_mkdir || n == SYS_mknod {
            n = if n == SYS_mkdir { SYS_mkdirat } else { SYS_mknodat };
            a = [AT_FDCWD as u64, a[0], a[1], a[2], 0, 0];
        }
        if n == SYS_symlink {
            n = SYS_symlinkat;
            a = [a[0], AT_FDCWD as u64, a[1], 0, 0, 0];
        }
        if n == SYS_rename {
            n = SYS_renameat;
            a = [AT_FDCWD as u64, a[0], AT_FDCWD as u64, a[1], 0, 0];
        }
        if n == SYS_unlink || n == SYS_rmdir {
            a = [
                AT_FDCWD as u64,
                a[0],
                if n == SYS_rmdir { AT_REMOVEDIR as u64 } else { 0 },
                0,
                0,
                0,
            ];
            n = SYS_unlinkat;
        }
        if n == SYS_chmod {
            n = SYS_fchmodat;
            a = [AT_FDCWD as u64, a[0], a[1], 0, 0, 0];
        }
        if n == SYS_chown || n == SYS_lchown {
            a = [
                AT_FDCWD as u64,
                a[0],
                a[1],
                a[2],
                if n == SYS_lchown { AT_SYMLINK_NOFOLLOW as u64 } else { 0 },
                0,
            ];
            n = SYS_fchownat;
        }
        if n == SYS_utime || n == SYS_utimes {
            time_format = if n == SYS_utime { 1 } else { 2 };
            a = [AT_FDCWD as u64, a[0], a[1], 0, 0, 0];
            n = SYS_utimensat;
        }
        if n == SYS_futimesat {
            time_format = 2;
            a[3] = 0;
            n = SYS_utimensat;
        }
    }
    let mut target_fd = None;
    if [SYS_fchmod, SYS_fchown, SYS_ftruncate, SYS_fsetxattr, SYS_fremovexattr].contains(&n) {
        target_fd = Some(a[0] as i32);
        if n == SYS_fchmod {
            n = SYS_fchmodat;
            a = [a[0], 0, a[1], 0, 0, 0];
        } else if n == SYS_fchown {
            n = SYS_fchownat;
            a = [a[0], 0, a[1], a[2], 0, 0];
        } else if n == SYS_ftruncate {
            n = SYS_truncate;
        } else if n == SYS_fsetxattr {
            n = SYS_setxattr;
        } else {
            n = SYS_removexattr;
        }
    }
    let (mut dir, address, at_flags, operation) = match n {
        x if x == SYS_mkdirat => {
            (a[0] as i32, a[1], AT_SYMLINK_NOFOLLOW, Operation::Mkdir(a[2] as mode_t))
        }
        x if x == SYS_mknodat => {
            let mode = a[2] as mode_t;
            if !matches!(mode & S_IFMT, 0 | S_IFREG | S_IFIFO) {
                return Err(EPERM);
            }
            (a[0] as i32, a[1], AT_SYMLINK_NOFOLLOW, Operation::Mknod(mode, a[3] as dev_t))
        }
        x if x == SYS_symlinkat => (
            a[1] as i32,
            a[2],
            AT_SYMLINK_NOFOLLOW,
            Operation::Symlink(CString::new(copy_path(pid, a[0])?).map_err(|_| EINVAL)?),
        ),
        x if x == SYS_renameat || x == SYS_renameat2 => {
            let flags = if x == SYS_renameat2 { a[4] as u32 } else { 0 };
            if flags & RENAME_WHITEOUT != 0 {
                return Err(EPERM);
            }
            (
                a[0] as i32,
                a[1],
                AT_SYMLINK_NOFOLLOW,
                Operation::Rename(a[2] as i32, copy_path(pid, a[3])?, flags),
            )
        }
        x if x == SYS_unlinkat => {
            (a[0] as i32, a[1], AT_SYMLINK_NOFOLLOW, Operation::Unlink(a[2] as i32))
        }
        x if x == SYS_truncate => (AT_FDCWD, a[0], 0, Operation::Truncate(a[1] as off_t)),
        x if x == SYS_fchmodat || x == FCHMODAT2 => (
            a[0] as i32,
            a[1],
            if x == FCHMODAT2 { a[3] as i32 } else { 0 },
            Operation::Chmod(a[2] as mode_t),
        ),
        x if x == SYS_fchownat => {
            (a[0] as i32, a[1], a[4] as i32, Operation::Chown(a[2] as uid_t, a[3] as gid_t))
        }
        x if x == SYS_utimensat => {
            if a[1] == 0 {
                target_fd = Some(a[0] as i32);
            }
            (a[0] as i32, a[1], a[3] as i32, Operation::Times(times(pid, a[2], time_format)?))
        }
        x if [
            SYS_setxattr,
            SYS_lsetxattr,
            SYS_removexattr,
            SYS_lremovexattr,
            SETXATTRAT,
            REMOVEXATTRAT,
        ]
        .contains(&x) =>
        {
            let is_at = x == SETXATTRAT || x == REMOVEXATTRAT;
            let setting = [SYS_setxattr, SYS_lsetxattr, SETXATTRAT].contains(&x);
            let name =
                CString::new(copy_path(pid, a[if is_at { 3 } else { 1 }])?).map_err(|_| EINVAL)?;
            let (data, flags) = if x == SETXATTRAT {
                // Linux xattr_args: aligned u64 value, u32 size, u32 flags.
                if a[5] < 16 {
                    return Err(EINVAL);
                }
                if a[5] > 4096 {
                    return Err(E2BIG);
                }
                let data = bytes(pid, a[4], a[5] as usize)?;
                if data[16..].iter().any(|b| *b != 0) {
                    return Err(E2BIG);
                }
                let pointer = unsafe { data.as_ptr().cast::<u64>().read_unaligned() };
                let size = u32::from_ne_bytes(data[8..12].try_into().map_err(|_| EINVAL)?);
                let flags = i32::from_ne_bytes(data[12..16].try_into().map_err(|_| EINVAL)?);
                (Some(bytes(pid, pointer, size as usize)?), flags)
            } else if setting {
                (Some(bytes(pid, a[2], a[3] as usize)?), a[4] as i32)
            } else {
                (None, 0)
            };
            (
                if is_at { a[0] as i32 } else { AT_FDCWD },
                a[usize::from(is_at)],
                if is_at {
                    a[2] as i32
                } else if x == SYS_lsetxattr || x == SYS_lremovexattr {
                    AT_SYMLINK_NOFOLLOW
                } else {
                    0
                },
                Operation::Xattr(name, data, flags),
            )
        }
        _ => return Err(EACCES),
    };
    if at_flags & !(AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH) != 0 {
        return Err(EINVAL);
    }
    let mut path = if target_fd.is_some() { String::new() } else { copy_path(pid, address)? };
    if path.is_empty() && at_flags & AT_EMPTY_PATH != 0 {
        if dir == AT_FDCWD {
            path = ".".into();
        } else {
            target_fd = Some(dir);
        }
    }
    if let Some(fd) = target_fd {
        path = format!("/proc/self/fd/{fd}");
        dir = AT_FDCWD;
    }
    if !valid(listener, &request.id, stop)? {
        return Ok(None);
    }
    let status = std::fs::read_to_string(format!("/proc/self/fd/{}/status", task.as_raw_fd()))
        .map_err(|_| EACCES)?;
    let nspid = status
        .lines()
        .find_map(|s| s.strip_prefix("NSpid:"))
        .and_then(|s| s.split_whitespace().last())
        .ok_or(EACCES)?;
    let resolve_checked = |dir, path: &str, nofollow| -> Result<Resolved> {
        let mut r = resolve(
            task.as_raw_fd(),
            dir,
            path,
            if nofollow { O_PATH | O_NOFOLLOW } else { 0 },
            nspid,
        )?;
        policy.check(Path::new(&r.logical)).map_err(|_| EACCES)?;
        if r.directory_required {
            r.name.push('/');
        }
        Ok(r)
    };
    let resolved =
        resolve_checked(dir, &path, target_fd.is_none() && at_flags & AT_SYMLINK_NOFOLLOW != 0)?;
    let name = CString::new(resolved.name.as_str()).map_err(|_| EACCES)?;
    let parent = resolved.parent.as_raw_fd();
    if let Operation::Rename(dir, path, flags) = operation {
        let to = resolve_checked(dir, &path, true)?;
        // A directory may contain config/HEAD that changes policy at its new
        // location. Refuse both directions, including RENAME_EXCHANGE.
        for (dir, entry) in
            [(parent, resolved.name.as_str()), (to.parent.as_raw_fd(), to.name.as_str())]
        {
            match open_at(dir, entry, O_PATH | O_NOFOLLOW, 0) {
                Ok(pin) if stat(pin.as_raw_fd())?.st_mode & S_IFMT == S_IFDIR => {
                    return Err(EACCES);
                }
                Err(ENOENT) => {}
                Err(errno) => return Err(errno),
                _ => {}
            }
        }
        let to_name = CString::new(to.name).map_err(|_| EACCES)?;
        if !valid(listener, &request.id, stop)? {
            return Ok(None);
        }
        return checked(unsafe {
            syscall(
                SYS_renameat2,
                parent,
                name.as_ptr(),
                to.parent.as_raw_fd(),
                to_name.as_ptr(),
                flags,
            )
        } as i32)
        .map(|n| Some(n as i64));
    }
    if !valid(listener, &request.id, stop)? {
        return Ok(None);
    }
    if matches!(operation, Operation::Mkdir(_) | Operation::Mknod(_, _) | Operation::Symlink(_)) {
        let mask = status.lines().find_map(|s| s.strip_prefix("Umask:")).ok_or(EACCES)?;
        let mask = u32::from_str_radix(mask.trim(), 8).map_err(|_| EACCES)?;
        // run unshares CLONE_FS; kernel umask/default ACL handling needs the original mode.
        let previous = unsafe { umask(mask as mode_t) };
        let rc = unsafe {
            match operation {
                Operation::Mkdir(mode) => mkdirat(parent, name.as_ptr(), mode),
                Operation::Mknod(mode, device) => mknodat(parent, name.as_ptr(), mode, device),
                Operation::Symlink(target) => symlinkat(target.as_ptr(), parent, name.as_ptr()),
                _ => -1,
            }
        };
        let result = checked(rc);
        unsafe {
            umask(previous);
        }
        return result.map(|n| Some(n as i64));
    }
    if let Operation::Unlink(flags) = operation {
        return checked(unsafe { unlinkat(parent, name.as_ptr(), flags) }).map(|n| Some(n as i64));
    }
    if let Some(fd) = target_fd {
        let info =
            std::fs::read_to_string(format!("/proc/self/fd/{}/fdinfo/{fd}", task.as_raw_fd()))
                .map_err(|_| EACCES)?;
        let flags = info.lines().find_map(|s| s.strip_prefix("flags:")).ok_or(EACCES)?;
        let flags = i32::from_str_radix(flags.trim(), 8).map_err(|_| EACCES)?;
        if flags & O_PATH != 0 {
            return Err(EBADF);
        }
        if matches!(operation, Operation::Truncate(_)) && flags & O_ACCMODE == O_RDONLY {
            return Err(EINVAL);
        }
    }
    if let Operation::Truncate(length) = operation {
        if resolved.directory_required {
            return Err(EISDIR);
        }
        // Missing names return ENOENT. A late symlink gets ELOOP rather than
        // following an unchecked target; never write-reopen an O_PATH proc fd.
        let file =
            open_at(parent, &resolved.name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY, 0)?;
        let info = stat(file.as_raw_fd())?;
        if info.st_mode & S_IFMT != S_IFREG {
            return Err(EINVAL);
        }
        if let Some(original) = &resolved.object {
            let pinned = stat(original.as_raw_fd())?;
            if (info.st_dev, info.st_ino) != (pinned.st_dev, pinned.st_ino) {
                return Err(EACCES);
            }
        }
        return checked(unsafe { ftruncate(file.as_raw_fd(), length) }).map(|n| Some(n as i64));
    }
    // A trailing slash must not turn the nofollow leaf into a followed component.
    let leaf = resolved.name.trim_end_matches('/');
    let pin = match resolved.object {
        Some(pin) => pin,
        None => open_at(parent, leaf, O_PATH | O_NOFOLLOW, 0)?,
    };
    let kind = stat(pin.as_raw_fd())?.st_mode & S_IFMT;
    if resolved.directory_required && kind != S_IFDIR {
        return Err(ENOTDIR);
    }
    // chown/times use the pinned inode with AT_EMPTY_PATH|AT_SYMLINK_NOFOLLOW.
    // chmod and fd-xattr proc paths are safe only for a verified non-symlink inode.
    if kind == S_IFLNK
        && (matches!(operation, Operation::Chmod(_))
            || (target_fd.is_some() && matches!(operation, Operation::Xattr(_, _, _))))
    {
        return Err(ELOOP);
    }
    let object_path =
        CString::new(format!("/proc/self/fd/{}", pin.as_raw_fd())).map_err(|_| EACCES)?;
    let rc = unsafe {
        match operation {
            Operation::Chmod(mode) => chmod(object_path.as_ptr(), mode),
            Operation::Chown(uid, gid) => fchownat(
                pin.as_raw_fd(),
                c"".as_ptr(),
                uid,
                gid,
                AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW,
            ),
            Operation::Times(times) => utimensat(
                pin.as_raw_fd(),
                c"".as_ptr(),
                times.as_ref().map_or(std::ptr::null(), |t| t.as_ptr()),
                AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW,
            ),
            Operation::Xattr(attribute, data, flags) => {
                if target_fd.is_some() {
                    match data {
                        Some(data) => setxattr(
                            object_path.as_ptr(),
                            attribute.as_ptr(),
                            data.as_ptr().cast(),
                            data.len(),
                            flags,
                        ),
                        None => removexattr(object_path.as_ptr(), attribute.as_ptr()),
                    }
                } else {
                    let path = CString::new(format!("/proc/self/fd/{parent}/{leaf}"))
                        .map_err(|_| EACCES)?;
                    match data {
                        Some(data) => lsetxattr(
                            path.as_ptr(),
                            attribute.as_ptr(),
                            data.as_ptr().cast(),
                            data.len(),
                            flags,
                        ),
                        None => lremovexattr(path.as_ptr(), attribute.as_ptr()),
                    }
                }
            }
            _ => return Err(EACCES),
        }
    };
    checked(rc).map(|n| Some(n as i64))
}
