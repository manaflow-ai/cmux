use std::collections::HashSet;
use std::io;
use std::time::{Duration, Instant};

const PROCESS_TREE_MAX_ROUNDS: usize = 64;
const PROCESS_TREE_RETRY_INTERVAL: Duration = Duration::from_millis(10);
#[cfg(test)]
const PROCESS_TREE_RETRY_TIMEOUT: Duration = Duration::from_secs(1);

#[cfg(test)]
thread_local! {
    static RAW_PID_SIGNAL_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn ensure_helper_active() -> io::Result<()> {
    if super::legacy_helper_cancelled() {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "legacy cleanup helper was cancelled",
        ));
    }
    Ok(())
}

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
        #[cfg(test)]
        RAW_PID_SIGNAL_COUNT.set(RAW_PID_SIGNAL_COUNT.get() + 1);
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

    fn signal_in_session(
        self,
        session: libc::pid_t,
        signal: libc::c_int,
    ) -> io::Result<ExactSignalResult> {
        let Some(current) = Self::capture(self.pid)? else {
            return Ok(ExactSignalResult::Gone);
        };
        if current != self {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "process identity changed"));
        }
        // SAFETY: getsid only queries the exact process revalidated above.
        let current_session = unsafe { libc::getsid(self.pid) };
        if current_session < 0 {
            let error = io::Error::last_os_error();
            return if error.raw_os_error() == Some(libc::ESRCH) {
                Ok(ExactSignalResult::Gone)
            } else {
                Err(error)
            };
        }
        if current_session != session {
            return Ok(ExactSignalResult::Gone);
        }
        self.signal(signal)
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

#[cfg(test)]
pub(super) fn terminate_process_tree(process: ProcessIdentity) -> io::Result<()> {
    terminate_process_tree_until(process, Instant::now() + PROCESS_TREE_RETRY_TIMEOUT)
}

pub(super) fn terminate_process_tree_until(
    process: ProcessIdentity,
    deadline: Instant,
) -> io::Result<()> {
    retry_process_tree_termination(process, deadline, |_| {
        let tree = FrozenProcessTree::freeze(process, deadline)?;
        tree.kill()
    })
}

fn retry_process_tree_termination(
    process: ProcessIdentity,
    deadline: Instant,
    mut attempt: impl FnMut(Instant) -> io::Result<()>,
) -> io::Result<()> {
    loop {
        ensure_helper_active()?;
        let error = match attempt(deadline) {
            Ok(()) => return Ok(()),
            Err(error) => error,
        };
        match ProcessIdentity::capture(process.pid) {
            Ok(None) => return Ok(()),
            Ok(Some(current)) if current != process => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "server process identity changed during termination",
                ));
            }
            Ok(Some(_)) | Err(_) => {}
        }
        if Instant::now() >= deadline {
            return Err(error);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(PROCESS_TREE_RETRY_INTERVAL),
        );
    }
}

pub(super) fn capture_process_tree_until(
    process: ProcessIdentity,
    deadline: Instant,
) -> io::Result<CapturedProcessTree> {
    let tree = freeze_process_tree(process, deadline)?;
    let sessions = tree.captured_sessions()?;
    drop(tree);
    Ok(CapturedProcessTree { root: process, sessions })
}

fn freeze_process_tree(
    process: ProcessIdentity,
    deadline: Instant,
) -> io::Result<FrozenProcessTree> {
    loop {
        ensure_helper_active()?;
        let error = match FrozenProcessTree::freeze(process, deadline) {
            Ok(tree) => return Ok(tree),
            Err(error) => error,
        };
        match ProcessIdentity::capture(process.pid) {
            Ok(None) => {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "server exited before its process tree was fenced",
                ));
            }
            Ok(Some(current)) if current != process => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "server process identity changed during termination",
                ));
            }
            Ok(Some(_)) | Err(_) => {}
        }
        if Instant::now() >= deadline {
            return Err(error);
        }
        std::thread::sleep(PROCESS_TREE_RETRY_INTERVAL);
    }
}

pub(super) struct CapturedProcessTree {
    root: ProcessIdentity,
    sessions: Vec<CapturedSession>,
}

impl CapturedProcessTree {
    fn contains_process(&self, process: ProcessIdentity) -> bool {
        self.sessions.iter().any(|session| session.members.contains(&process))
    }

    pub(super) fn terminate_until(self, deadline: Instant) -> io::Result<()> {
        for session in &self.sessions {
            if !session.kill_until_empty(deadline)? {
                return Err(io::Error::other(
                    "captured PTY session did not exit before the legacy shutdown deadline",
                ));
            }
        }
        terminate_process_tree_until(self.root, deadline)
    }
}

pub(super) struct CapturedProcessSession(CapturedSession);

impl CapturedProcessSession {
    pub(super) fn id(&self) -> libc::pid_t {
        self.0.id
    }

    pub(super) fn terminate_until(self, deadline: Instant) -> io::Result<()> {
        if self.0.kill_until_empty(deadline)? {
            Ok(())
        } else {
            Err(io::Error::other(
                "captured PTY session did not exit before the legacy shutdown deadline",
            ))
        }
    }
}

pub(super) fn capture_process_session(
    pid: libc::pid_t,
    server: ProcessIdentity,
    captured: &CapturedProcessTree,
    deadline: Instant,
) -> io::Result<Option<CapturedProcessSession>> {
    if pid <= 1
        || pid == server.pid
        || pid == libc::pid_t::try_from(std::process::id()).unwrap_or(0)
    {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid PTY owner process"));
    }
    let Some(process) = ProcessIdentity::capture(pid)? else { return Ok(None) };
    if !captured.contains_process(process) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "PTY owner was not captured in the verified server process tree",
        ));
    }
    if process.signal(libc::SIGSTOP)? == ExactSignalResult::Gone {
        return Ok(None);
    }
    let captured = (|| {
        ensure_helper_active()?;
        if ProcessIdentity::capture(pid)? != Some(process) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "PTY owner process identity changed after fencing",
            ));
        }
        // SAFETY: getsid only queries exact processes revalidated above.
        let session = unsafe { libc::getsid(pid) };
        if session <= 1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the server identity remains validated by the caller.
        let server_session = unsafe { libc::getsid(server.pid) };
        // SAFETY: getsid(0) only queries the detached helper.
        let helper_session = unsafe { libc::getsid(0) };
        if session == server_session || session == helper_session {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PTY owner shares a protected process session",
            ));
        }
        let mut members = Vec::new();
        for member in cmux_tui_core::process_session::session_member_pids_until(session, deadline)?
        {
            if let Some(identity) = ProcessIdentity::capture(member)? {
                members.push(identity);
            }
        }
        if !members.contains(&process) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "PTY owner left its process session while being captured",
            ));
        }
        members.sort_by_key(|member| member.pid);
        members.dedup();
        Ok(CapturedProcessSession(CapturedSession { id: session, members }))
    })();
    let _ = process.signal(libc::SIGCONT);
    captured.map(Some)
}

struct CapturedSession {
    id: libc::pid_t,
    members: Vec<ProcessIdentity>,
}

impl CapturedSession {
    fn kill_until_empty(&self, deadline: Instant) -> io::Result<bool> {
        loop {
            ensure_helper_active()?;
            let error = match SessionProbe::acquire(self) {
                Ok(Some(mut probe)) => {
                    match cmux_tui_core::process_session::kill_until_only_reserved(
                        self.id,
                        probe.process.pid,
                        deadline,
                    ) {
                        Ok(true) => match probe.kill() {
                            Ok(()) => return Ok(true),
                            Err(error) => error,
                        },
                        Ok(false) => return Ok(false),
                        Err(error) => error,
                    }
                }
                Ok(None) => {
                    match cmux_tui_core::process_session::session_is_empty_until(self.id, deadline)
                    {
                        Ok(true) => return Ok(true),
                        Ok(false) => io::Error::other(
                            "captured PTY session lost every exact process before termination",
                        ),
                        Err(error) => error,
                    }
                }
                Err(error) => error,
            };
            if Instant::now() >= deadline {
                return Err(error);
            }
            std::thread::sleep(
                deadline.saturating_duration_since(Instant::now()).min(PROCESS_TREE_RETRY_INTERVAL),
            );
        }
    }
}

struct SessionProbe {
    process: ProcessIdentity,
    session: libc::pid_t,
    armed: bool,
}

impl SessionProbe {
    fn acquire(session: &CapturedSession) -> io::Result<Option<Self>> {
        for process in &session.members {
            ensure_helper_active()?;
            if ProcessIdentity::capture(process.pid)? != Some(*process) {
                continue;
            }
            if process.signal_in_session(session.id, libc::SIGSTOP)? != ExactSignalResult::Signaled
            {
                continue;
            }
            return Ok(Some(Self { process: *process, session: session.id, armed: true }));
        }
        Ok(None)
    }

    fn kill(&mut self) -> io::Result<()> {
        let _ = self.process.signal_in_session(self.session, libc::SIGKILL)?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for SessionProbe {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.process.signal_in_session(self.session, libc::SIGCONT);
        }
    }
}

struct FrozenProcessTree {
    root: ProcessIdentity,
    descendants: Vec<ProcessIdentity>,
    armed: bool,
}

impl FrozenProcessTree {
    fn freeze(root: ProcessIdentity, deadline: Instant) -> io::Result<Self> {
        ensure_helper_active()?;
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
            ensure_helper_active()?;
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "legacy process tree did not stabilize before the shutdown deadline",
                ));
            }
            let parents =
                std::iter::once(root).chain(tree.descendants.iter().copied()).collect::<Vec<_>>();
            let mut added = false;
            for parent in parents {
                ensure_helper_active()?;
                for pid in direct_child_pids(parent.pid)? {
                    ensure_helper_active()?;
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

    fn captured_sessions(&self) -> io::Result<Vec<CapturedSession>> {
        // SAFETY: getsid only queries live, exact processes held stopped by
        // this FrozenProcessTree.
        let root_session = unsafe { libc::getsid(self.root.pid) };
        if root_session < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: getsid(0) only queries the detached helper.
        let helper_session = unsafe { libc::getsid(0) };
        if helper_session < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut sessions = Vec::<CapturedSession>::new();
        for process in &self.descendants {
            // SAFETY: every descendant remains stopped and exact until this
            // FrozenProcessTree is dropped.
            let session = unsafe { libc::getsid(process.pid) };
            if session < 0 {
                return Err(io::Error::last_os_error());
            }
            if session > 1 && session != root_session && session != helper_session {
                if let Some(captured) = sessions.iter_mut().find(|captured| captured.id == session)
                {
                    captured.members.push(*process);
                } else {
                    sessions.push(CapturedSession { id: session, members: vec![*process] });
                }
            }
        }
        sessions.sort_by_key(|session| session.id);
        for session in &mut sessions {
            session.members.sort_by_key(|process| process.pid);
            session.members.dedup();
        }
        Ok(sessions)
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
        match macos_process_status(pid)? {
            None | Some(libc::SZOMB) => return Ok(None),
            Some(_) => {}
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
    if info.pbi_status == libc::SZOMB {
        return Ok(None);
    }
    let started_at = (u128::from(info.pbi_start_tvsec) << 64) | u128::from(info.pbi_start_tvusec);
    Ok(Some(ProcessSnapshot { identity: ProcessIdentity { pid, started_at }, parent }))
}

#[cfg(target_os = "macos")]
fn macos_process_status(pid: libc::pid_t) -> io::Result<Option<u32>> {
    use std::ffi::c_void;
    use std::mem::{ManuallyDrop, offset_of, size_of};

    #[allow(dead_code)]
    #[repr(C)]
    union ProcessStart {
        links: [*mut c_void; 2],
        started_at: ManuallyDrop<libc::timeval>,
    }

    #[allow(dead_code)]
    #[repr(C)]
    struct ExternProcessPrefix {
        start: ProcessStart,
        vmspace: *mut c_void,
        signal_actions: *mut c_void,
        flags: libc::c_int,
        status: libc::c_char,
        pid: libc::pid_t,
    }

    let mut query = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
    let query_len = libc::c_uint::try_from(query.len())
        .map_err(|_| io::Error::other("process status query overflow"))?;
    let mut record_len = 0;
    // SAFETY: the query is a valid KERN_PROC_PID MIB and a null output
    // buffer asks the kernel for the record size.
    if unsafe {
        libc::sysctl(
            query.as_mut_ptr(),
            query_len,
            std::ptr::null_mut(),
            &raw mut record_len,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        let error = io::Error::last_os_error();
        if matches!(error.raw_os_error(), Some(libc::ESRCH) | Some(libc::ENOENT)) {
            return Ok(None);
        }
        return Err(error);
    }
    if record_len == 0 {
        return Ok(None);
    }
    let mut record = vec![0_u8; record_len];
    // SAFETY: `record` owns a writable buffer of `record_len` bytes.
    if unsafe {
        libc::sysctl(
            query.as_mut_ptr(),
            query_len,
            record.as_mut_ptr().cast(),
            &raw mut record_len,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        let error = io::Error::last_os_error();
        if matches!(error.raw_os_error(), Some(libc::ESRCH) | Some(libc::ENOENT)) {
            return Ok(None);
        }
        return Err(error);
    }
    if record_len < size_of::<ExternProcessPrefix>() {
        if record_len == 0 {
            return Ok(None);
        }
        return Err(io::Error::other("process status record was truncated"));
    }
    // KERN_PROC_PID returns `kinfo_proc`, whose first field is
    // `extern_proc`. Read only the stable prefix that contains status and
    // PID, without depending on the private remainder of either structure.
    let record_pid = unsafe {
        record
            .as_ptr()
            .add(offset_of!(ExternProcessPrefix, pid))
            .cast::<libc::pid_t>()
            .read_unaligned()
    };
    if record_pid != pid {
        return Err(io::Error::other("process status id mismatch"));
    }
    let status = unsafe {
        record.as_ptr().add(offset_of!(ExternProcessPrefix, status)).cast::<libc::c_char>().read()
    };
    u32::try_from(status).map(Some).map_err(|_| io::Error::other("invalid process status"))
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
    let task_root = format!("/proc/{parent}/task");
    let tasks = match std::fs::read_dir(task_root) {
        Ok(tasks) => tasks,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut pids = HashSet::new();
    for task in tasks {
        let task = match task {
            Ok(task) => task,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        let children = match std::fs::read_to_string(task.path().join("children")) {
            Ok(children) => children,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        for pid in children.split_whitespace() {
            let pid = pid
                .parse::<libc::pid_t>()
                .map_err(|_| io::Error::other("invalid child process id"))?;
            if pid > 1 {
                pids.insert(pid);
            }
        }
    }
    let mut pids = pids.into_iter().collect::<Vec<_>>();
    pids.sort_unstable();
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
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    #[cfg(target_os = "linux")]
    use std::sync::mpsc;

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

    #[test]
    fn process_identity_never_signals_through_a_reusable_pid() {
        let mut child = Command::new("sleep")
            .arg("60")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let process =
            ProcessIdentity::capture(libc::pid_t::try_from(child.id()).unwrap()).unwrap().unwrap();
        RAW_PID_SIGNAL_COUNT.set(0);

        assert_eq!(process.signal(libc::SIGCONT).unwrap(), ExactSignalResult::Signaled);
        let raw_signals = RAW_PID_SIGNAL_COUNT.get();

        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(
            raw_signals, 0,
            "legacy cleanup used a reusable PID instead of a stable process identity"
        );
    }

    #[test]
    fn termination_accepts_a_verified_process_that_already_exited() {
        let mut child = Command::new("sleep")
            .arg("60")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let process =
            ProcessIdentity::capture(libc::pid_t::try_from(child.id()).unwrap()).unwrap().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();

        terminate_process_tree(process).unwrap();
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn process_tree_termination_retries_post_freeze_metadata_errors() {
        let mut child = Command::new("sleep")
            .arg("60")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let process =
            ProcessIdentity::capture(libc::pid_t::try_from(child.id()).unwrap()).unwrap().unwrap();
        let mut attempts = 0;

        let result = retry_process_tree_termination(
            process,
            Instant::now() + Duration::from_secs(1),
            |_| {
                attempts += 1;
                if attempts == 1 {
                    Err(io::Error::other("transient process metadata read"))
                } else {
                    Ok(())
                }
            },
        );
        child.kill().unwrap();
        child.wait().unwrap();

        assert!(result.is_ok());
        assert_eq!(attempts, 2);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn captured_session_waits_for_an_unavailable_exact_member_to_exit() {
        let mut command = Command::new("sleep");
        command.arg("60").stdout(Stdio::null()).stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command.spawn().unwrap();
        let pid = libc::pid_t::try_from(child.id()).unwrap();
        let process = ProcessIdentity::capture(pid).unwrap().unwrap();
        let unavailable =
            ProcessIdentity { pid: process.pid, started_at: process.started_at.wrapping_add(1) };
        let session = CapturedSession { id: pid, members: vec![unavailable] };
        let reaper = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            child.kill().unwrap();
            child.wait().unwrap()
        });

        let result = session.kill_until_empty(Instant::now() + Duration::from_secs(1));
        reaper.join().unwrap();

        assert!(result.unwrap());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_child_enumeration_includes_children_spawned_by_worker_threads() {
        let (child_tx, child_rx) = mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            let child =
                Command::new("yes").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
            child_tx.send(child.id()).unwrap();
            child
        });
        let child_pid = child_rx.recv().unwrap();
        let parent = libc::pid_t::try_from(std::process::id()).unwrap();
        let child_pid = libc::pid_t::try_from(child_pid).unwrap();

        let children = direct_child_pids(parent).unwrap();

        let mut child = worker.join().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(
            children.contains(&child_pid),
            "worker child {child_pid} missing from {children:?}"
        );
    }
}
