//! Whether a socket peer runs under an acpmux agent (review of 2fe73a9a):
//! the process or one of its parents carries the session name acpmux sets
//! for every agent it spawns (`ACPMUX_SESSION_NAME`, acpmux
//! agent/command.rs). The agent process keeps it even when the caller
//! clears its own environment; a caller that leaves its parents behind (a
//! double fork) is not seen here, which is why loosening a Chief gate also
//! needs the verified app connection (chief_control.rs `require_app_owner`).

/// The variable acpmux sets in each agent's environment.
const SESSION_ENV: &[u8] = b"ACPMUX_SESSION_NAME=";
/// Most processes walked: agent trees are shallow.
const MAX_DEPTH: usize = 32;

/// Whether `pid` or one of its parents (up to [`MAX_DEPTH`], below pid 1)
/// has a non-empty `ACPMUX_SESSION_NAME`. A process whose environment cannot
/// be read counts as having none.
pub(super) fn under_acpmux_agent(pid: i32) -> bool {
    let mut current = pid;
    for _ in 0..MAX_DEPTH {
        if current <= 1 {
            return false;
        }
        if has_session_name(current) {
            return true;
        }
        match parent_pid(current) {
            Some(parent) => current = parent,
            None => return false,
        }
    }
    false
}

fn names_session(entry: &[u8]) -> bool {
    entry.strip_prefix(SESSION_ENV).is_some_and(|value| !value.is_empty())
}

#[cfg(target_os = "linux")]
fn parent_pid(pid: i32) -> Option<i32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid ...`; comm may hold spaces and parentheses.
    stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(target_os = "linux")]
fn has_session_name(pid: i32) -> bool {
    std::fs::read(format!("/proc/{pid}/environ"))
        .is_ok_and(|bytes| bytes.split(|byte| *byte == 0).any(names_session))
}

#[cfg(target_os = "macos")]
fn parent_pid(pid: i32) -> Option<i32> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info` and
    // returns the initialized byte count.
    let written = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the full structure.
    let info = unsafe { info.assume_init() };
    i32::try_from(info.pbi_ppid).ok()
}

#[cfg(target_os = "macos")]
fn has_session_name(pid: i32) -> bool {
    let mut argmax: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: the out buffer is a c_int and `size` is its size.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    let Ok(argmax) = usize::try_from(argmax) else { return false };
    if read != 0 || argmax == 0 || argmax > 16 * 1024 * 1024 {
        return false;
    }
    let mut buffer = vec![0_u8; argmax];
    let mut filled = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: the buffer is writable for `filled` bytes, which is passed.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &raw mut filled,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return false;
    }
    environment(&buffer[..filled.min(buffer.len())])
        .is_some_and(|mut entries| entries.any(names_session))
}

/// The environment entries of a `KERN_PROCARGS2` answer: argc (i32), the
/// exec path, NUL padding, argc arguments, then the environment.
#[cfg(target_os = "macos")]
fn environment(data: &[u8]) -> Option<impl Iterator<Item = &[u8]>> {
    let argc = usize::try_from(i32::from_ne_bytes(data.get(..4)?.try_into().ok()?)).ok()?;
    let rest = &data[4..];
    let path_end = rest.iter().position(|byte| *byte == 0)?;
    let start = path_end + rest[path_end..].iter().position(|byte| *byte != 0)?;
    let mut strings = rest[start..].split(|byte| *byte == 0);
    if strings.by_ref().take(argc).count() != argc {
        return None;
    }
    Some(strings.skip_while(|entry| entry.is_empty()).take_while(|entry| !entry.is_empty()))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn parent_pid(_pid: i32) -> Option<i32> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn has_session_name(_pid: i32) -> bool {
    false
}
