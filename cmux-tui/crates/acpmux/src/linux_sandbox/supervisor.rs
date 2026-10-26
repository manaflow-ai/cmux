//! E1 write-open supervision; no production caller until G2.
//! Activation also requires F: all sandbox path mutations must use this same
//! serial supervisor, so directories cannot be renamed during a checked open.
//! Bwrap supplies read-only mounts and masks; this is not a standalone sandbox.
//! Stricter: non-UTF-8 paths and anonymous/deleted proc-fd targets are refused.
//! Opens use O_NONBLOCK while acquiring the fd (a FIFO without a reader fails
//! ENXIO); the requested blocking mode is restored before handing it over.
#![allow(dead_code)]

use super::rules::WritePolicy;
use libc::*;
use std::{
    collections::VecDeque,
    ffi::CString,
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    path::Path,
};

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
}

/// Consumes components; symlink expansion is capped at 40. `..` pops only
/// held directories and cannot leave root. Procfs is recognized by fstatfs,
/// including mounts reached through aliases. Symlinks are read through their
/// pinned O_PATH fd, never through a mutable directory entry a second time.
fn resolve(task: RawFd, dir: i32, path: &str, flags: i32, nspid: &str) -> Result<Resolved> {
    if path.is_empty() {
        return Err(ENOENT);
    }
    let root = open_at(task, "root", O_PATH | O_DIRECTORY, 0).map_err(|_| EACCES)?;
    let start = if path.starts_with('/') {
        path.to_owned()
    } else {
        let at = if dir == AT_FDCWD { "cwd".to_owned() } else { format!("fd/{dir}") };
        let cwd = link_at(task, &at).map_err(|_| EACCES)?;
        if !cwd.starts_with('/') || cwd.ends_with(" (deleted)") {
            return Err(EACCES);
        }
        format!("{cwd}/{path}")
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
                });
            }
            Err(e) => return Err(e),
        };
        let mut fs: statfs = unsafe { std::mem::zeroed() };
        checked(unsafe { fstatfs(pin.as_raw_fd(), &mut fs) }).map_err(|_| EACCES)?;
        let fs_type = i64::try_from(fs.f_type).map_err(|_| EACCES)?;
        let proc_magic = i64::try_from(PROC_SUPER_MAGIC).map_err(|_| EACCES)?;
        if fs_type == proc_magic {
            if target != Path::new("/proc")
                || queue.len() != 3
                || magic.is_some()
                || !matches!(queue[0].as_str(), "self" | "thread-self") && queue[0] != nspid
                || queue[1] != "fd"
                || flags & O_NOFOLLOW != 0
            {
                return Err(EACCES);
            }
            let number: u32 = queue[2].parse().map_err(|_| EACCES)?;
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
            if target.starts_with('/') {
                stack.truncate(1);
                logical = "/".into();
            }
            let mut next = components(&target);
            next.append(&mut queue);
            queue = next;
            continue;
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
                });
            }
            return Ok(Resolved {
                parent: stack.pop().ok_or(EACCES)?,
                name,
                logical: logical.to_str().ok_or(EACCES)?.into(),
                object: None,
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
    })
}

/// E1b owns the notification loop. E1a keeps the resolver callable and
/// uncalled so this boundary can land independently.
pub(crate) fn run(_notify_fd: OwnedFd, _policy: WritePolicy, _stop: OwnedFd) -> io::Result<()> {
    Err(io::Error::other("user-notify supervisor not implemented"))
}

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
        let fd = resolve(task().as_raw_fd(), AT_FDCWD, "/proc/self/fd/1", O_WRONLY, &nspid())
            .expect("stdout fd alias");
        assert!(fd.object.is_some());
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
