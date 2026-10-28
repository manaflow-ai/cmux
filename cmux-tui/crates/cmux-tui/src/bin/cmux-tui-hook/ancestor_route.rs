//! Route for agents that run hooks with a cleared environment.
//!
//! Muse Code starts each hook command through `$SHELL -c` with only a small
//! allowlist of variables (HOME, PATH, SHELL, TERM, USER and a few more), so
//! `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID` never reach the hook. The
//! agent process itself still has them: it was started in the cmux-tui
//! terminal. The helper walks up its parent processes and takes the values
//! from the first ancestor whose start environment names a session socket.
//! It passes only processes Muse started for the hook: one whose environment
//! has nothing but the hook allowlist, or one whose environment the system
//! does not show (macOS hides it for Apple-signed programs such as /bin/zsh,
//! the usual `$SHELL`). The first ancestor with any other environment is the
//! agent, and the walk ends there: an agent started outside cmux-tui reports
//! nothing even when an older ancestor ran in a cmux-tui terminal. Only
//! same-user processes are readable; an unreadable process ends the walk.

use std::path::PathBuf;

/// Agents whose hook commands get a cleared environment.
pub(super) fn clears_environment(source: &str) -> bool {
    source == "muse"
}

/// Parent levels examined: the hook's shell (or shells) and the agent.
const MAX_ANCESTORS: usize = 6;

/// The variables Muse Code passes to a hook command (measured on Muse 0.1 and
/// documented as "a cleared environment with a small allowlist"), the ones a
/// POSIX shell sets itself, and terminal and session variables a later Muse
/// may let through. A process whose start environment has only these is one
/// Muse started for the hook, not the agent.
const CLEARED_ENVIRONMENT: &[&[u8]] = &[
    b"COLORTERM",
    b"DISPLAY",
    b"HOME",
    b"LANG",
    b"LOGNAME",
    b"OLDPWD",
    b"PATH",
    b"PWD",
    b"SHELL",
    b"SHLVL",
    b"TERM",
    b"TMPDIR",
    b"TZ",
    b"USER",
    b"WAYLAND_DISPLAY",
    b"XDG_RUNTIME_DIR",
    b"_",
    b"__CF_USER_TEXT_ENCODING",
];

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Route {
    pub(super) socket: PathBuf,
    pub(super) terminal: Option<String>,
}

pub(super) fn ancestor_terminal() -> Option<Route> {
    // SAFETY: getppid has no preconditions and cannot fail.
    let mut pid = u32::try_from(unsafe { libc::getppid() }).ok()?;
    for _ in 0..MAX_ANCESTORS {
        if pid <= 1 {
            return None;
        }
        let process = platform::read(pid)?;
        if let Some(route) = route_from_environment(&process.environment) {
            return Some(route);
        }
        // A hidden environment reads back empty; like the cleared one it is
        // a process Muse started for the hook.
        if !is_cleared(&process.environment) {
            return None;
        }
        pid = process.parent;
    }
    None
}

fn is_cleared(environment: &[Vec<u8>]) -> bool {
    environment.iter().all(|entry| {
        let name = entry.split(|byte| *byte == b'=').next().unwrap_or_default();
        // Muse's own MUSE_*/TBH_* names may ride on a process it starts for
        // the hook; they never mark the agent itself.
        [b"LC_".as_slice(), b"MUSE_", b"TBH_"].iter().any(|prefix| name.starts_with(prefix))
            || CLEARED_ENVIRONMENT.contains(&name)
    })
}

/// The session route named by one start environment (`NAME=value` entries).
fn route_from_environment(environment: &[Vec<u8>]) -> Option<Route> {
    let value = |name: &[u8]| {
        environment.iter().find_map(|entry| {
            let rest = entry.strip_prefix(name)?.strip_prefix(b"=")?;
            if rest.is_empty() { None } else { String::from_utf8(rest.to_vec()).ok() }
        })
    };
    let socket = value(b"CMUX_TUI_SOCKET")?;
    Some(Route { socket: PathBuf::from(socket), terminal: value(b"CMUX_TUI_TERMINAL_ID") })
}

struct Process {
    parent: u32,
    environment: Vec<Vec<u8>>,
}

#[cfg(target_os = "linux")]
mod platform {
    use super::Process;

    pub(super) fn read(pid: u32) -> Option<Process> {
        let stat = cmux_blocking::fs::read(format!("/proc/{pid}/stat")).ok()?;
        // `pid (comm) state ppid ...`; comm may hold spaces, parentheses and
        // bytes that are not UTF-8.
        let after_comm =
            std::str::from_utf8(&stat[stat.iter().rposition(|b| *b == b')')? + 1..]).ok()?;
        let parent = after_comm.split_whitespace().nth(1)?.parse().ok()?;
        let environ = cmux_blocking::fs::read(format!("/proc/{pid}/environ")).ok()?;
        let environment = environ
            .split(|byte| *byte == 0)
            .filter(|entry| !entry.is_empty())
            .map(<[u8]>::to_vec)
            .collect();
        Some(Process { parent, environment })
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Process;

    pub(super) fn read(pid: u32) -> Option<Process> {
        Some(Process { parent: parent(pid)?, environment: environment(pid)? })
    }

    fn parent(pid: u32) -> Option<u32> {
        let pid = libc::c_int::try_from(pid).ok()?;
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
        // SAFETY: `info` is a writable buffer of exactly `size` bytes.
        let written = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
        };
        if written != size {
            return None;
        }
        // SAFETY: proc_pidinfo filled the whole structure.
        Some(unsafe { info.assume_init() }.pbi_ppid)
    }

    fn environment(pid: u32) -> Option<Vec<Vec<u8>>> {
        let mut argmax: libc::c_int = 0;
        let mut size = size_of::<libc::c_int>();
        let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
        // SAFETY: `argmax` is a writable c_int and `size` is its size.
        let status = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                2,
                (&mut argmax as *mut libc::c_int).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        let capacity = usize::try_from(argmax).ok().filter(|_| status == 0)?;
        if capacity == 0 || capacity > 16 * 1024 * 1024 {
            return None;
        }
        let mut buffer = vec![0_u8; capacity];
        let mut size = buffer.len();
        let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, libc::c_int::try_from(pid).ok()?];
        // SAFETY: `buffer` is writable for `size` bytes.
        let status = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                buffer.as_mut_ptr().cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if status != 0 {
            return None;
        }
        parse_procargs2(&buffer[..size.min(buffer.len())])
    }

    /// `KERN_PROCARGS2`: argc (i32), the exec path, NUL padding, argc
    /// arguments, then the environment, ended by an empty string. For an
    /// Apple-signed program the system leaves the environment out, so it
    /// reads back empty.
    fn parse_procargs2(data: &[u8]) -> Option<Vec<Vec<u8>>> {
        let argc = usize::try_from(i32::from_ne_bytes(data.get(..4)?.try_into().ok()?)).ok()?;
        let mut strings = data[4..].split(|byte| *byte == 0);
        strings.next()?; // exec path
        let mut rest = strings.skip_while(|entry| entry.is_empty());
        for _ in 0..argc {
            rest.next()?;
        }
        Some(rest.take_while(|entry| !entry.is_empty()).map(<[u8]>::to_vec).collect())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    use super::Process;

    pub(super) fn read(_pid: u32) -> Option<Process> {
        None
    }
}
