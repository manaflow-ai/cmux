use std::collections::HashSet;
use std::io;

const PROCESS_TREE_MAX_ROUNDS: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ProcessIdentity {
    pid: libc::pid_t,
    started_at: u128,
}

impl ProcessIdentity {
    pub(super) fn from_parts(pid: libc::pid_t, started_at: u128) -> Self {
        Self { pid, started_at }
    }

    pub(super) fn pid(self) -> libc::pid_t {
        self.pid
    }

    pub(super) fn started_at(self) -> u128 {
        self.started_at
    }

    pub(super) fn capture(pid: libc::pid_t) -> io::Result<Option<Self>> {
        process_snapshot(pid).map(|snapshot| snapshot.map(|snapshot| snapshot.identity))
    }

    fn signal(self, signal: libc::c_int) -> io::Result<ExactSignalResult> {
        let Some(current) = Self::capture(self.pid)? else {
            return Ok(ExactSignalResult::Gone);
        };
        if current != self {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "process identity changed"));
        }
        // SAFETY: the PID was range-checked and its birth identity was
        // revalidated immediately before this signal.
        if unsafe { libc::kill(self.pid, signal) } == 0 {
            return Ok(ExactSignalResult::Signaled);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(ExactSignalResult::Gone)
        } else {
            Err(error)
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct ProcessSnapshot {
    identity: ProcessIdentity,
    parent: libc::pid_t,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ExactSignalResult {
    Signaled,
    Gone,
}

pub(super) fn terminate_process_tree(process: ProcessIdentity) -> io::Result<()> {
    FrozenProcessTree::freeze(process).and_then(FrozenProcessTree::kill)
}

struct FrozenProcessTree {
    root: ProcessIdentity,
    descendants: Vec<ProcessIdentity>,
    armed: bool,
}

impl FrozenProcessTree {
    fn freeze(root: ProcessIdentity) -> io::Result<Self> {
        let mut tree = Self { root, descendants: Vec::new(), armed: true };
        if root.signal(libc::SIGSTOP)? == ExactSignalResult::Gone {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "server exited before its process tree was fenced",
            ));
        }
        if ProcessIdentity::capture(root.pid)? != Some(root) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "server process identity changed after fencing",
            ));
        }

        let helper_pid = libc::pid_t::try_from(std::process::id())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid helper process id"))?;
        let mut known = HashSet::from([root.pid, helper_pid]);
        for _ in 0..PROCESS_TREE_MAX_ROUNDS {
            let parents =
                std::iter::once(root).chain(tree.descendants.iter().copied()).collect::<Vec<_>>();
            let mut added = false;
            for parent in parents {
                for pid in direct_child_pids(parent.pid)? {
                    if known.contains(&pid) {
                        continue;
                    }
                    let Some(snapshot) = process_snapshot(pid)? else {
                        continue;
                    };
                    if snapshot.parent != parent.pid {
                        continue;
                    }
                    match snapshot.identity.signal(libc::SIGSTOP)? {
                        ExactSignalResult::Gone => continue,
                        ExactSignalResult::Signaled => {}
                    }
                    if ProcessIdentity::capture(pid)? != Some(snapshot.identity) {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "descendant process identity changed after fencing",
                        ));
                    }
                    known.insert(pid);
                    tree.descendants.push(snapshot.identity);
                    added = true;
                }
            }
            if !added {
                return Ok(tree);
            }
        }
        Err(io::Error::other("legacy process tree did not stabilize"))
    }

    fn kill(mut self) -> io::Result<()> {
        if !self.armed {
            return Ok(());
        }
        for process in std::iter::once(self.root).chain(self.descendants.iter().copied()) {
            if let Some(current) = ProcessIdentity::capture(process.pid)?
                && current != process
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "frozen process identity changed",
                ));
            }
        }
        for process in self.descendants.iter().rev().copied() {
            let _ = process.signal(libc::SIGKILL)?;
        }
        let _ = self.root.signal(libc::SIGKILL)?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for FrozenProcessTree {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        for process in self.descendants.iter().rev().copied() {
            let _ = process.signal(libc::SIGCONT);
        }
        let _ = self.root.signal(libc::SIGCONT);
    }
}

#[cfg(target_os = "macos")]
fn process_snapshot(pid: libc::pid_t) -> io::Result<Option<ProcessSnapshot>> {
    use std::mem::{size_of, zeroed};

    let mut info = unsafe { zeroed::<libc::proc_bsdinfo>() };
    let expected = i32::try_from(size_of::<libc::proc_bsdinfo>())
        .map_err(|_| io::Error::other("process metadata size overflow"))?;
    // SAFETY: `info` is a writable buffer of exactly `expected` bytes.
    let result = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), expected)
    };
    if result != expected {
        // SAFETY: signal zero does not deliver a signal.
        if unsafe { libc::kill(pid, 0) } != 0
            && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            return Ok(None);
        }
        return Err(io::Error::other("could not read process birth identity"));
    }
    let info_pid =
        libc::pid_t::try_from(info.pbi_pid).map_err(|_| io::Error::other("invalid process id"))?;
    if info_pid != pid {
        return Err(io::Error::other("process metadata id mismatch"));
    }
    let parent = libc::pid_t::try_from(info.pbi_ppid)
        .map_err(|_| io::Error::other("invalid parent process id"))?;
    let started_at = (u128::from(info.pbi_start_tvsec) << 64) | u128::from(info.pbi_start_tvusec);
    Ok(Some(ProcessSnapshot { identity: ProcessIdentity { pid, started_at }, parent }))
}

#[cfg(target_os = "macos")]
fn direct_child_pids(parent: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    use std::ffi::c_void;
    use std::mem::size_of;

    // SAFETY: a null buffer with length zero asks libproc for the count.
    let count = unsafe { libc::proc_listchildpids(parent, std::ptr::null_mut(), 0) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    let mut capacity = usize::try_from(count)
        .map_err(|_| io::Error::other("invalid child process count"))?
        .saturating_add(16);
    for _ in 0..4 {
        let mut pids = vec![0; capacity];
        let bytes = capacity
            .checked_mul(size_of::<libc::pid_t>())
            .and_then(|bytes| i32::try_from(bytes).ok())
            .ok_or_else(|| io::Error::other("child process buffer overflow"))?;
        // SAFETY: `pids` owns a writable buffer of `bytes` bytes.
        let listed =
            unsafe { libc::proc_listchildpids(parent, pids.as_mut_ptr().cast::<c_void>(), bytes) };
        if listed < 0 {
            return Err(io::Error::last_os_error());
        }
        let listed =
            usize::try_from(listed).map_err(|_| io::Error::other("invalid child process count"))?;
        if listed < capacity {
            pids.truncate(listed);
            pids.retain(|pid| *pid > 1);
            return Ok(pids);
        }
        capacity = capacity
            .checked_mul(2)
            .ok_or_else(|| io::Error::other("child process buffer overflow"))?;
    }
    Err(io::Error::other("child process list did not stabilize"))
}

#[cfg(target_os = "linux")]
fn process_snapshot(pid: libc::pid_t) -> io::Result<Option<ProcessSnapshot>> {
    let path = format!("/proc/{pid}/stat");
    let stat = match std::fs::read_to_string(path) {
        Ok(stat) => stat,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let (pid_text, remainder) = stat
        .split_once(" (")
        .and_then(|(pid_text, remainder)| {
            remainder.rsplit_once(") ").map(|(_, fields)| (pid_text, fields))
        })
        .ok_or_else(|| io::Error::other("invalid process stat record"))?;
    if pid_text.parse::<libc::pid_t>().ok() != Some(pid) {
        return Err(io::Error::other("process metadata id mismatch"));
    }
    let fields = remainder.split_whitespace().collect::<Vec<_>>();
    let parent = fields
        .get(1)
        .and_then(|value| value.parse::<libc::pid_t>().ok())
        .ok_or_else(|| io::Error::other("invalid parent process id"))?;
    let started_at = fields
        .get(19)
        .and_then(|value| value.parse::<u128>().ok())
        .ok_or_else(|| io::Error::other("invalid process birth identity"))?;
    Ok(Some(ProcessSnapshot { identity: ProcessIdentity { pid, started_at }, parent }))
}

#[cfg(target_os = "linux")]
fn direct_child_pids(parent: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    let path = format!("/proc/{parent}/task/{parent}/children");
    let children = match std::fs::read_to_string(path) {
        Ok(children) => children,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut pids = children
        .split_whitespace()
        .map(|pid| {
            pid.parse::<libc::pid_t>().map_err(|_| io::Error::other("invalid child process id"))
        })
        .collect::<io::Result<Vec<_>>>()?;
    pids.retain(|pid| *pid > 1);
    Ok(pids)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn process_snapshot(_pid: libc::pid_t) -> io::Result<Option<ProcessSnapshot>> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "stable process identity is unavailable"))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn direct_child_pids(_parent: libc::pid_t) -> io::Result<Vec<libc::pid_t>> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "process tree enumeration is unavailable"))
}

#[cfg(test)]
mod tests {
    use std::process::{Command, Stdio};

    use super::*;

    #[test]
    fn stable_identity_refuses_to_signal_the_same_pid_with_a_different_birth() {
        let mut child =
            Command::new("yes").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let process =
            ProcessIdentity::capture(libc::pid_t::try_from(child.id()).unwrap()).unwrap().unwrap();
        let stale =
            ProcessIdentity { pid: process.pid, started_at: process.started_at.wrapping_add(1) };

        assert!(stale.signal(libc::SIGKILL).is_err());
        assert!(child.try_wait().unwrap().is_none());

        child.kill().unwrap();
        child.wait().unwrap();
    }
}
