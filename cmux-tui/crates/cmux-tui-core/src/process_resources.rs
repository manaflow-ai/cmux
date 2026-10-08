//! Process resources of a terminal, read on request for `terminal-resources`.
//!
//! Nothing here runs in the background: a [`Sampler`] reads the operating
//! system once when a request asks for it and is dropped with the reply. There
//! is no cache between requests and no timer.
//!
//! The process tree is a pure breadth-first walk ([`walk_tree`]) over a
//! children function, so it is tested without live processes. On Linux the
//! children come from one `/proc` scan per request ([`ChildIndex`] over the
//! pid to ppid map); on macOS from `proc_listchildpids` per visited process.

use std::collections::{HashMap, HashSet, VecDeque};

/// Largest number of processes reported for one terminal. A larger tree is
/// cut in breadth-first order and reported as truncated.
pub const MAX_PROCESSES_PER_TERMINAL: usize = 512;

/// One process of a walked tree and the parent it was reached from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TreeNode {
    pub pid: u32,
    /// The walk parent. `None` for the root, whose parent is outside the tree.
    pub parent: Option<u32>,
}

/// A process tree in breadth-first order, root first, each pid once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessTree {
    pub nodes: Vec<TreeNode>,
    /// The tree had more processes than the cap.
    pub truncated: bool,
}

/// Walk the tree under `root` breadth-first. Each pid appears at most once,
/// so a pid cycle or a reused pid that shows up again ends that branch. At
/// most `cap` processes are returned; `truncated` is set when a further
/// process was found.
pub fn walk_tree(
    root: u32,
    cap: usize,
    mut children_of: impl FnMut(u32) -> Vec<u32>,
) -> ProcessTree {
    if cap == 0 {
        return ProcessTree { nodes: Vec::new(), truncated: true };
    }
    let mut nodes = vec![TreeNode { pid: root, parent: None }];
    let mut visited = HashSet::from([root]);
    let mut queue = VecDeque::from([root]);
    while let Some(pid) = queue.pop_front() {
        for child in children_of(pid) {
            if !visited.insert(child) {
                continue;
            }
            if nodes.len() == cap {
                return ProcessTree { nodes, truncated: true };
            }
            nodes.push(TreeNode { pid: child, parent: Some(pid) });
            queue.push_back(child);
        }
    }
    ProcessTree { nodes, truncated: false }
}

/// Children of every process, built from a pid to ppid map. Children are in
/// ascending pid order so a walk is deterministic.
#[derive(Debug, Default)]
pub struct ChildIndex {
    children: HashMap<u32, Vec<u32>>,
}

impl ChildIndex {
    pub fn from_ppid_map(ppids: &HashMap<u32, u32>) -> Self {
        let mut children = HashMap::<u32, Vec<u32>>::new();
        for (&pid, &ppid) in ppids {
            if pid != ppid {
                children.entry(ppid).or_default().push(pid);
            }
        }
        for list in children.values_mut() {
            list.sort_unstable();
        }
        Self { children }
    }

    pub fn children(&self, pid: u32) -> Vec<u32> {
        self.children.get(&pid).cloned().unwrap_or_default()
    }
}

/// Resource figures of one process at sample time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessSample {
    /// Executable basename.
    pub name: String,
    /// Cumulative user plus system CPU time since the process started.
    pub cpu_ns: u64,
    /// macOS physical footprint; Linux resident set size; Windows private
    /// working set.
    pub memory_bytes: u64,
}

/// One line of `/proc/<pid>/stat`, reduced to the fields this module uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcStat {
    pub ppid: u32,
    pub name: String,
    /// utime + stime in clock ticks.
    pub cpu_ticks: u64,
}

/// Parse `/proc/<pid>/stat`. The command name is in parentheses and may hold
/// spaces and parentheses itself, so the fields start after the last `)`.
pub fn parse_proc_stat(stat: &str) -> Option<ProcStat> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat.get(open + 1..close)?.to_string();
    // After the name: state(3) ppid(4) ... utime(14) stime(15), so ppid is
    // index 1 and utime/stime are 11 and 12 of the remaining fields.
    let fields: Vec<&str> = stat.get(close + 1..)?.split_whitespace().collect();
    let ppid = fields.get(1)?.parse().ok()?;
    let utime: u64 = fields.get(11)?.parse().ok()?;
    let stime: u64 = fields.get(12)?.parse().ok()?;
    Some(ProcStat { ppid, name, cpu_ticks: utime.saturating_add(stime) })
}

/// Resident pages from `/proc/<pid>/statm` (the second field).
pub fn parse_statm_resident_pages(statm: &str) -> Option<u64> {
    statm.split_whitespace().nth(1)?.parse().ok()
}

/// The basename of an executable path.
pub fn executable_basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Monotonic clock in nanoseconds: `CLOCK_UPTIME_RAW` on macOS,
/// `CLOCK_MONOTONIC` on Linux. Other platforms count from the first call in
/// this process.
pub fn monotonic_now_ns() -> u64 {
    imp::monotonic_now_ns()
}

/// Operating-system reads for one request.
pub struct Sampler {
    inner: imp::Sampler,
}

impl Sampler {
    /// Read what a request needs up front. On Linux this is one `/proc` scan.
    pub fn new() -> Self {
        Self { inner: imp::Sampler::new() }
    }

    /// The process tree under `root`, capped at
    /// [`MAX_PROCESSES_PER_TERMINAL`].
    pub fn tree(&self, root: u32) -> ProcessTree {
        walk_tree(root, MAX_PROCESSES_PER_TERMINAL, |pid| self.inner.children(pid))
    }

    /// The parent pid, when the process still exists.
    pub fn parent(&self, pid: u32) -> Option<u32> {
        self.inner.parent(pid)
    }

    /// Name, CPU time and memory, or `None` when the process is gone or the
    /// platform does not report it.
    pub fn sample(&self, pid: u32) -> Option<ProcessSample> {
        self.inner.sample(pid)
    }

    /// The process runs this daemon's own executable.
    pub fn runs_own_executable(&self, pid: u32) -> bool {
        self.inner.runs_own_executable(pid)
    }
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::collections::HashMap;
    use std::path::PathBuf;

    use super::{ChildIndex, ProcStat, ProcessSample, parse_proc_stat, parse_statm_resident_pages};

    pub(super) fn monotonic_now_ns() -> u64 {
        // SAFETY: timespec is plain old data; all-zero is valid.
        let mut now: libc::timespec = unsafe { std::mem::zeroed() };
        // SAFETY: `now` is a valid, writable timespec.
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut now) } != 0 {
            return 0;
        }
        let secs = u64::try_from(now.tv_sec).unwrap_or(0);
        let nanos = u64::try_from(now.tv_nsec).unwrap_or(0);
        secs.saturating_mul(1_000_000_000).saturating_add(nanos)
    }

    pub(super) struct Sampler {
        stats: HashMap<u32, ProcStat>,
        children: ChildIndex,
        ticks_per_second: u64,
        page_size: u64,
    }

    impl Sampler {
        pub(super) fn new() -> Self {
            let mut stats = HashMap::new();
            for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
                let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse().ok())
                else {
                    continue;
                };
                // A process that exits during the scan has no stat file left.
                let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
                    continue;
                };
                if let Some(stat) = parse_proc_stat(&stat) {
                    stats.insert(pid, stat);
                }
            }
            let ppids = stats.iter().map(|(pid, stat)| (*pid, stat.ppid)).collect();
            // SAFETY: sysconf has no preconditions.
            let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
            // SAFETY: sysconf has no preconditions.
            let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
            Self {
                children: ChildIndex::from_ppid_map(&ppids),
                stats,
                ticks_per_second: u64::try_from(ticks).ok().filter(|t| *t > 0).unwrap_or(100),
                page_size: u64::try_from(page).ok().filter(|p| *p > 0).unwrap_or(4096),
            }
        }

        pub(super) fn children(&self, pid: u32) -> Vec<u32> {
            self.children.children(pid)
        }

        pub(super) fn parent(&self, pid: u32) -> Option<u32> {
            self.stats.get(&pid).map(|stat| stat.ppid)
        }

        pub(super) fn sample(&self, pid: u32) -> Option<ProcessSample> {
            let stat = self.stats.get(&pid)?;
            let statm = std::fs::read_to_string(format!("/proc/{pid}/statm")).ok()?;
            let pages = parse_statm_resident_pages(&statm)?;
            let cpu_ns =
                u128::from(stat.cpu_ticks) * 1_000_000_000 / u128::from(self.ticks_per_second);
            Some(ProcessSample {
                name: stat.name.clone(),
                cpu_ns: u64::try_from(cpu_ns).unwrap_or(u64::MAX),
                memory_bytes: pages.saturating_mul(self.page_size),
            })
        }

        pub(super) fn runs_own_executable(&self, pid: u32) -> bool {
            let exe = |path: String| -> Option<(PathBuf, Option<(u64, u64)>)> {
                use std::os::unix::fs::MetadataExt;
                let link = std::fs::read_link(&path).ok()?;
                // After an in-place upgrade the link reads "<path> (deleted)".
                let text = link.to_string_lossy();
                let link = PathBuf::from(text.strip_suffix(" (deleted)").unwrap_or(&text));
                let inode = std::fs::metadata(&path).ok().map(|meta| (meta.dev(), meta.ino()));
                Some((link, inode))
            };
            let (Some(own), Some(other)) =
                (exe("/proc/self/exe".to_string()), exe(format!("/proc/{pid}/exe")))
            else {
                return false;
            };
            own.0 == other.0 || (own.1.is_some() && own.1 == other.1)
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::os::raw::{c_int, c_void};

    use super::{ProcessSample, executable_basename};

    /// `struct rusage_info_v4` from `<sys/resource.h>`.
    #[repr(C)]
    struct RusageInfoV4 {
        uuid: [u8; 16],
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        /// proc_start_abstime through runnable_time: 27 more `uint64_t`.
        rest: [u64; 27],
    }

    #[repr(C)]
    #[derive(Default)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }

    const RUSAGE_INFO_V4: c_int = 4;
    const CLOCK_UPTIME_RAW: u32 = 8;

    unsafe extern "C" {
        fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *mut c_void) -> c_int;
        fn proc_name(pid: c_int, buffer: *mut c_void, size: u32) -> c_int;
        fn mach_timebase_info(info: *mut Timebase) -> c_int;
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }

    pub(super) fn monotonic_now_ns() -> u64 {
        // SAFETY: CLOCK_UPTIME_RAW is a valid clock id; the call has no
        // other preconditions and returns 0 on failure.
        unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    pub(super) struct Sampler {
        timebase: Timebase,
        own_path: Option<String>,
    }

    impl Sampler {
        pub(super) fn new() -> Self {
            let mut timebase = Timebase::default();
            // SAFETY: `timebase` is a valid, writable mach_timebase_info_data_t.
            if unsafe { mach_timebase_info(&raw mut timebase) } != 0 || timebase.denom == 0 {
                timebase = Timebase { numer: 1, denom: 1 };
            }
            Self { timebase, own_path: pid_path(std::process::id()) }
        }

        pub(super) fn children(&self, pid: u32) -> Vec<u32> {
            let Ok(pid) = libc::pid_t::try_from(pid) else {
                return Vec::new();
            };
            // SAFETY: a null buffer asks libproc for the child count only.
            let count = unsafe { libc::proc_listchildpids(pid, std::ptr::null_mut(), 0) };
            let Ok(count) = usize::try_from(count) else {
                return Vec::new();
            };
            if count == 0 {
                return Vec::new();
            }
            // Room for children forked between the two calls.
            let mut children = vec![0 as libc::pid_t; count + 16];
            let Ok(bytes) =
                c_int::try_from(children.len().saturating_mul(size_of::<libc::pid_t>()))
            else {
                return Vec::new();
            };
            // SAFETY: `children` owns a writable buffer of exactly `bytes` bytes.
            let written =
                unsafe { libc::proc_listchildpids(pid, children.as_mut_ptr().cast(), bytes) };
            let Ok(written) = usize::try_from(written) else {
                return Vec::new();
            };
            children.truncate(written.min(children.len()));
            let mut children: Vec<u32> = children
                .into_iter()
                .filter(|child| *child > 0)
                .filter_map(|child| u32::try_from(child).ok())
                .collect();
            children.sort_unstable();
            children
        }

        pub(super) fn parent(&self, pid: u32) -> Option<u32> {
            let pid = c_int::try_from(pid).ok()?;
            // SAFETY: proc_bsdinfo is plain old data; all-zero is valid.
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let size = c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
            // SAFETY: `info` is a writable buffer of `size` bytes for this flavor.
            let written = unsafe {
                libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
            };
            (written == size).then_some(info.pbi_ppid)
        }

        pub(super) fn sample(&self, pid: u32) -> Option<ProcessSample> {
            let raw_pid = c_int::try_from(pid).ok()?;
            let mut usage = std::mem::MaybeUninit::<RusageInfoV4>::zeroed();
            // SAFETY: `usage` is a writable buffer of sizeof(rusage_info_v4)
            // bytes, the size the V4 flavor writes.
            if unsafe { proc_pid_rusage(raw_pid, RUSAGE_INFO_V4, usage.as_mut_ptr().cast()) } != 0 {
                return None;
            }
            // SAFETY: zero-initialized and then filled by the kernel; every
            // field is a plain integer.
            let usage = unsafe { usage.assume_init() };
            // CPU times are Mach absolute units (ticks on Apple silicon).
            let ticks = u128::from(usage.user_time) + u128::from(usage.system_time);
            let cpu_ns =
                ticks * u128::from(self.timebase.numer) / u128::from(self.timebase.denom.max(1));
            let name = pid_path(pid)
                .map(|path| executable_basename(&path).to_string())
                .filter(|name| !name.is_empty())
                .or_else(|| short_name(raw_pid))
                .unwrap_or_default();
            Some(ProcessSample {
                name,
                cpu_ns: u64::try_from(cpu_ns).unwrap_or(u64::MAX),
                memory_bytes: usage.phys_footprint,
            })
        }

        pub(super) fn runs_own_executable(&self, pid: u32) -> bool {
            self.own_path.is_some() && pid_path(pid) == self.own_path
        }
    }

    fn pid_path(pid: u32) -> Option<String> {
        let pid = c_int::try_from(pid).ok()?;
        let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: proc_pidpath writes at most `path.len()` bytes and returns
        // the written byte count (0 or less on failure).
        let written =
            unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
        let written = usize::try_from(written).ok().filter(|n| *n > 0)?;
        let path = std::str::from_utf8(&path[..written.min(path.len())]).ok()?;
        (!path.is_empty()).then(|| path.to_string())
    }

    fn short_name(pid: c_int) -> Option<String> {
        let mut name = [0u8; 256];
        // SAFETY: proc_name writes at most `name.len()` bytes and returns the
        // written byte count (0 or less on failure).
        let written = unsafe { proc_name(pid, name.as_mut_ptr().cast(), name.len() as u32) };
        let written = usize::try_from(written).ok().filter(|n| *n > 0)?;
        let name = std::str::from_utf8(&name[..written.min(name.len())]).ok()?;
        let name = name.trim_end_matches('\0');
        (!name.is_empty()).then(|| name.to_string())
    }
}

/// Windows: ToolHelp for the tree, and usage only of processes this daemon
/// started (`windows_processes`: in a terminal job, our user, our session).
#[cfg(windows)]
mod imp {
    use std::collections::HashMap;
    use std::sync::OnceLock;
    use std::time::Instant;

    use super::{ChildIndex, ProcessSample};
    use crate::windows_processes::{self as wp, Entry};

    pub(super) fn monotonic_now_ns() -> u64 {
        static EPOCH: OnceLock<Instant> = OnceLock::new();
        let elapsed = EPOCH.get_or_init(Instant::now).elapsed().as_nanos();
        u64::try_from(elapsed).unwrap_or(u64::MAX)
    }

    pub(super) struct Sampler {
        processes: HashMap<u32, Entry>,
        children: ChildIndex,
    }

    impl Sampler {
        pub(super) fn new() -> Self {
            let processes = wp::snapshot();
            let ppids = processes.iter().map(|(pid, entry)| (*pid, entry.parent)).collect();
            Self { children: ChildIndex::from_ppid_map(&ppids), processes }
        }

        /// Children born after their parent (a recorded parent pid can be a
        /// reused one).
        pub(super) fn children(&self, pid: u32) -> Vec<u32> {
            let parent_created = wp::created(pid);
            self.children
                .children(pid)
                .into_iter()
                .filter(|child| wp::born_after(parent_created, wp::created(*child)))
                .collect()
        }

        pub(super) fn parent(&self, pid: u32) -> Option<u32> {
            self.processes.get(&pid).map(|entry| entry.parent)
        }

        pub(super) fn sample(&self, pid: u32) -> Option<ProcessSample> {
            let (cpu_ns, memory_bytes) = wp::usage(pid)?;
            let name = self.processes.get(&pid).map(|entry| entry.exe.clone()).unwrap_or_default();
            Some(ProcessSample { name, cpu_ns, memory_bytes })
        }

        pub(super) fn runs_own_executable(&self, pid: u32) -> bool {
            wp::runs_own_executable(pid)
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
mod imp {
    use std::sync::OnceLock;
    use std::time::Instant;

    use super::ProcessSample;

    pub(super) fn monotonic_now_ns() -> u64 {
        static EPOCH: OnceLock<Instant> = OnceLock::new();
        let elapsed = EPOCH.get_or_init(Instant::now).elapsed().as_nanos();
        u64::try_from(elapsed).unwrap_or(u64::MAX)
    }

    /// Process trees are not read on this platform: every terminal reports
    /// no processes and no host.
    pub(super) struct Sampler;

    impl Sampler {
        pub(super) fn new() -> Self {
            Self
        }

        pub(super) fn children(&self, _pid: u32) -> Vec<u32> {
            Vec::new()
        }

        pub(super) fn parent(&self, _pid: u32) -> Option<u32> {
            None
        }

        pub(super) fn sample(&self, _pid: u32) -> Option<ProcessSample> {
            None
        }

        pub(super) fn runs_own_executable(&self, _pid: u32) -> bool {
            false
        }
    }
}

/// Whether this platform reads process trees for `terminal-resources`.
pub const fn reads_process_trees() -> bool {
    cfg!(any(target_os = "linux", target_os = "macos", windows))
}

#[cfg(test)]
#[path = "process_resources_tests.rs"]
mod tests;
