//! The processes of this user, read once on request for the agent runtime
//! inventory (RFC #20149).
//!
//! Nothing here runs in the background: [`scan`] reads the operating system
//! when a request asks for it, and the result is dropped with the reply.
//! The scan is bounded: at most [`MAX_INVENTORY_PROCESSES`] processes, each
//! with at most [`MAX_ARGS`] arguments of [`MAX_ARG_BYTES`] bytes in all.
//! Only processes of this daemon's effective user are read; another user's
//! processes are skipped, never reported.
//!
//! Arguments are returned as read, for the vendor adapters that classify a
//! process. They can hold secrets: whoever puts them on the wire redacts
//! them first.

use crate::process_resources::Sampler;

/// Largest number of processes one scan reports. More are cut in pid order
/// and the inventory is marked truncated.
pub const MAX_INVENTORY_PROCESSES: usize = 4096;

/// Largest number of arguments (argv[0] included) kept per process.
pub const MAX_ARGS: usize = 32;

/// Largest total size of the arguments kept per process.
pub const MAX_ARG_BYTES: usize = 4096;

/// One process of this user at scan time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventoryProcess {
    pub pid: u32,
    pub ppid: u32,
    pub pgid: u32,
    pub sid: u32,
    /// Controlling terminal device, `None` without one.
    pub tty: Option<u64>,
    /// Wall-clock start, milliseconds since the epoch. With the pid it names
    /// one process generation: a reused pid starts later.
    pub started_ms: u64,
    /// Full path of the executable, when the system reports it.
    pub exe: Option<String>,
    /// Executable basename, or the kernel's short name without a path.
    pub name: String,
    /// The first arguments, argv[0] first, cut at [`MAX_ARGS`] and
    /// [`MAX_ARG_BYTES`]. Raw: redact before exposing.
    pub args: Vec<String>,
    /// The process had more arguments than were kept.
    pub args_truncated: bool,
    /// Cumulative user plus system CPU time, when readable.
    pub cpu_ns: Option<u64>,
    /// macOS physical footprint; Linux resident set size.
    pub memory_bytes: Option<u64>,
}

/// The result of one scan.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProcessInventory {
    /// This user's processes in ascending pid order.
    pub processes: Vec<InventoryProcess>,
    /// More of this user's processes existed than were reported.
    pub truncated: bool,
    /// Processes that were listed but could not be read (exited during the
    /// scan, or denied). The inventory is incomplete when this is nonzero.
    pub unreadable: usize,
}

/// Fields of one `/proc/<pid>/stat` line the inventory uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinuxStat {
    pub name: String,
    pub ppid: u32,
    pub pgid: u32,
    pub sid: u32,
    /// `tty_nr`; 0 without a controlling terminal.
    pub tty_nr: u64,
    /// Start time in clock ticks after boot.
    pub start_ticks: u64,
}

/// Parse `/proc/<pid>/stat`. The command name is in parentheses and may hold
/// spaces and parentheses itself, so the fields start after the last `)`.
pub fn parse_linux_stat(stat: &str) -> Option<LinuxStat> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat.get(open + 1..close)?.to_string();
    // After the name: state(3) ppid(4) pgrp(5) session(6) tty_nr(7) ...
    // starttime(22), so ppid is index 1 and starttime 19 of the rest.
    let fields: Vec<&str> = stat.get(close + 1..)?.split_whitespace().collect();
    Some(LinuxStat {
        name,
        ppid: fields.get(1)?.parse().ok()?,
        pgid: fields.get(2)?.parse().ok()?,
        sid: fields.get(3)?.parse().ok()?,
        tty_nr: fields.get(4)?.parse::<i64>().ok().and_then(|tty| u64::try_from(tty).ok())?,
        start_ticks: fields.get(19)?.parse().ok()?,
    })
}

/// The arguments of a NUL-separated argument block, cut at [`MAX_ARGS`]
/// and [`MAX_ARG_BYTES`]. Returns the kept arguments and whether any were
/// left out. An argument that does not fit whole is left out, not cut.
pub fn bounded_args<'a>(args: impl IntoIterator<Item = &'a [u8]>) -> (Vec<String>, bool) {
    let mut kept = Vec::new();
    let mut bytes = 0;
    for arg in args {
        if kept.len() == MAX_ARGS || bytes + arg.len() > MAX_ARG_BYTES {
            return (kept, true);
        }
        bytes += arg.len();
        kept.push(String::from_utf8_lossy(arg).into_owned());
    }
    (kept, false)
}

/// Split `/proc/<pid>/cmdline`: arguments end in NUL, so a trailing empty
/// piece is the terminator, not an argument.
pub fn split_cmdline(cmdline: &[u8]) -> impl Iterator<Item = &[u8]> {
    let cmdline = cmdline.strip_suffix(&[0]).unwrap_or(cmdline);
    cmdline.split(|byte| *byte == 0).filter(move |_| !cmdline.is_empty())
}

/// The arguments of a macOS `KERN_PROCARGS2` block: argc (i32), the exec
/// path, NUL padding, then argc arguments. The environment after them is
/// never read.
pub fn procargs2_args(data: &[u8]) -> Option<Vec<&[u8]>> {
    let argc = usize::try_from(i32::from_ne_bytes(data.get(..4)?.try_into().ok()?)).ok()?;
    let mut strings = data.get(4..)?.split(|byte| *byte == 0);
    strings.next()?; // exec path
    let rest = strings.skip_while(|entry| entry.is_empty());
    // Only what the bound can keep is walked, however large argc claims.
    Some(rest.take(argc.min(MAX_ARGS + 1)).collect())
}

/// The basename of an executable path.
fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Read this user's processes once, at most `limit` of them.
pub fn scan(limit: usize) -> ProcessInventory {
    let sampler = Sampler::new();
    let mut pids = imp::all_pids();
    pids.sort_unstable();
    pids.dedup();
    let mut inventory = ProcessInventory::default();
    let mut reader = imp::Reader::new();
    for pid in pids {
        if pid == 0 {
            continue;
        }
        let process = match reader.read(pid) {
            imp::Read::Process(process) => process,
            imp::Read::OtherUser => continue,
            imp::Read::Unreadable => {
                inventory.unreadable += 1;
                continue;
            }
        };
        if inventory.processes.len() == limit {
            inventory.truncated = true;
            break;
        }
        let sample = sampler.sample(pid);
        inventory.processes.push(InventoryProcess {
            cpu_ns: sample.as_ref().map(|sample| sample.cpu_ns),
            memory_bytes: sample.map(|sample| sample.memory_bytes),
            ..process
        });
    }
    inventory
}

#[cfg(target_os = "linux")]
mod imp {
    use std::os::unix::fs::MetadataExt;

    use super::{InventoryProcess, basename, bounded_args, parse_linux_stat, split_cmdline};

    pub(super) enum Read {
        Process(InventoryProcess),
        OtherUser,
        Unreadable,
    }

    pub(super) fn all_pids() -> Vec<u32> {
        std::fs::read_dir("/proc")
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
            .collect()
    }

    pub(super) struct Reader {
        uid: u32,
        ticks_per_second: u64,
        boot_ms: Option<u64>,
    }

    impl Reader {
        pub(super) fn new() -> Self {
            // SAFETY: sysconf has no preconditions.
            let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
            let boot_ms = std::fs::read_to_string("/proc/stat").ok().and_then(|stat| {
                let seconds: u64 = stat
                    .lines()
                    .find_map(|line| line.strip_prefix("btime "))?
                    .trim()
                    .parse()
                    .ok()?;
                Some(seconds.saturating_mul(1000))
            });
            Self {
                // SAFETY: geteuid has no preconditions and cannot fail.
                uid: unsafe { libc::geteuid() },
                ticks_per_second: u64::try_from(ticks).ok().filter(|t| *t > 0).unwrap_or(100),
                boot_ms,
            }
        }

        pub(super) fn read(&mut self, pid: u32) -> Read {
            // /proc/<pid> is owned by the process's effective user.
            let Ok(meta) = std::fs::metadata(format!("/proc/{pid}")) else {
                return Read::Unreadable;
            };
            if meta.uid() != self.uid {
                return Read::OtherUser;
            }
            let (Some(stat), Some(boot_ms)) = (
                std::fs::read_to_string(format!("/proc/{pid}/stat"))
                    .ok()
                    .and_then(|stat| parse_linux_stat(&stat)),
                self.boot_ms,
            ) else {
                return Read::Unreadable;
            };
            let exe = std::fs::read_link(format!("/proc/{pid}/exe")).ok().map(|link| {
                let text = link.to_string_lossy();
                text.strip_suffix(" (deleted)").unwrap_or(&text).to_string()
            });
            let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
            let (args, args_truncated) = bounded_args(split_cmdline(&cmdline));
            let name = exe
                .as_deref()
                .map(basename)
                .filter(|name| !name.is_empty())
                .map_or_else(|| stat.name.clone(), str::to_string);
            Read::Process(InventoryProcess {
                pid,
                ppid: stat.ppid,
                pgid: stat.pgid,
                sid: stat.sid,
                tty: (stat.tty_nr != 0).then_some(stat.tty_nr),
                started_ms: boot_ms
                    .saturating_add(stat.start_ticks.saturating_mul(1000) / self.ticks_per_second),
                exe,
                name,
                args,
                args_truncated,
                cpu_ns: None,
                memory_bytes: None,
            })
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{InventoryProcess, basename, bounded_args, procargs2_args};

    pub(super) enum Read {
        Process(InventoryProcess),
        OtherUser,
        Unreadable,
    }

    /// Kernel `NODEV`: no controlling terminal.
    const NO_DEVICE: u32 = u32::MAX;

    pub(super) fn all_pids() -> Vec<u32> {
        // SAFETY: a null buffer asks for the process count only.
        let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        let Ok(count) = usize::try_from(count) else {
            return Vec::new();
        };
        // Room for processes started between the two calls.
        let mut pids = vec![0 as libc::pid_t; count + 64];
        let Ok(bytes) = libc::c_int::try_from(pids.len().saturating_mul(size_of::<libc::pid_t>()))
        else {
            return Vec::new();
        };
        // SAFETY: `pids` owns a writable buffer of exactly `bytes` bytes.
        let written = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
        let Ok(written) = usize::try_from(written) else {
            return Vec::new();
        };
        pids.truncate(written.min(pids.len()));
        pids.into_iter().filter_map(|pid| u32::try_from(pid).ok()).collect()
    }

    pub(super) struct Reader {
        uid: u32,
        /// One `KERN_PROCARGS2` buffer for the whole scan.
        args: Vec<u8>,
    }

    impl Reader {
        pub(super) fn new() -> Self {
            // SAFETY: geteuid has no preconditions and cannot fail.
            Self { uid: unsafe { libc::geteuid() }, args: argmax_buffer().unwrap_or_default() }
        }

        pub(super) fn read(&mut self, pid: u32) -> Read {
            let Ok(raw) = libc::c_int::try_from(pid) else {
                return Read::Unreadable;
            };
            // SAFETY: proc_bsdinfo is plain old data; all-zero is valid.
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let Ok(size) = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()) else {
                return Read::Unreadable;
            };
            // SAFETY: `info` is a writable buffer of `size` bytes for this flavor.
            let written = unsafe {
                libc::proc_pidinfo(raw, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
            };
            if written != size {
                return Read::Unreadable;
            }
            if info.pbi_uid != self.uid {
                return Read::OtherUser;
            }
            // SAFETY: getsid has no memory preconditions; -1 when gone.
            let sid = u32::try_from(unsafe { libc::getsid(raw) }).unwrap_or(0);
            let exe = pid_path(raw);
            let comm = info.pbi_comm.iter().take_while(|byte| **byte != 0).map(|byte| *byte as u8);
            let comm = String::from_utf8_lossy(&comm.collect::<Vec<u8>>()).into_owned();
            let name = exe
                .as_deref()
                .map(basename)
                .filter(|name| !name.is_empty())
                .map_or(comm, str::to_string);
            let (args, args_truncated) = match self.procargs(raw) {
                Some(data) => procargs2_args(data).map(bounded_args).unwrap_or_default(),
                None => (Vec::new(), false),
            };
            Read::Process(InventoryProcess {
                pid,
                ppid: info.pbi_ppid,
                pgid: info.pbi_pgid,
                sid,
                tty: (info.e_tdev != NO_DEVICE).then_some(u64::from(info.e_tdev)),
                started_ms: info
                    .pbi_start_tvsec
                    .saturating_mul(1000)
                    .saturating_add(info.pbi_start_tvusec / 1000),
                exe,
                name,
                args,
                args_truncated,
                cpu_ns: None,
                memory_bytes: None,
            })
        }

        fn procargs(&mut self, pid: libc::c_int) -> Option<&[u8]> {
            let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
            let mut size = self.args.len();
            if size == 0 {
                return None;
            }
            // SAFETY: `self.args` is writable for `size` bytes.
            let status = unsafe {
                libc::sysctl(
                    mib.as_mut_ptr(),
                    3,
                    self.args.as_mut_ptr().cast(),
                    &mut size,
                    std::ptr::null_mut(),
                    0,
                )
            };
            (status == 0).then(|| &self.args[..size.min(self.args.len())])
        }
    }

    fn argmax_buffer() -> Option<Vec<u8>> {
        let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
        let mut argmax: libc::c_int = 0;
        let mut size = size_of::<libc::c_int>();
        // SAFETY: `argmax` is a writable c_int of `size` bytes.
        let status = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                2,
                (&raw mut argmax).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        let argmax = usize::try_from(argmax).ok().filter(|_| status == 0)?;
        (argmax > 0 && argmax <= 16 * 1024 * 1024).then(|| vec![0; argmax])
    }

    fn pid_path(pid: libc::c_int) -> Option<String> {
        let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: proc_pidpath writes at most `path.len()` bytes and returns
        // the written byte count (0 or less on failure).
        let written =
            unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
        let written = usize::try_from(written).ok().filter(|n| *n > 0)?;
        let path = std::str::from_utf8(&path[..written.min(path.len())]).ok()?;
        (!path.is_empty()).then(|| path.to_string())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod imp {
    use super::InventoryProcess;

    pub(super) enum Read {
        #[allow(dead_code)]
        Process(InventoryProcess),
        #[allow(dead_code)]
        OtherUser,
        Unreadable,
    }

    pub(super) fn all_pids() -> Vec<u32> {
        Vec::new()
    }

    pub(super) struct Reader;

    impl Reader {
        pub(super) fn new() -> Self {
            Self
        }

        pub(super) fn read(&mut self, _pid: u32) -> Read {
            Read::Unreadable
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stat_fields_survive_a_name_with_spaces_and_parens() {
        // pid (name) state ppid pgrp session tty_nr tpgid ... starttime(22)
        let stat = "4821 (codex (app) server) S 1 4821 4821 0 -1 4194560 \
                    1 0 0 0 5 3 0 0 20 0 9 0 777 1 1";
        let parsed = parse_linux_stat(stat).expect("parses");
        assert_eq!(parsed.name, "codex (app) server");
        assert_eq!((parsed.ppid, parsed.pgid, parsed.sid, parsed.tty_nr), (1, 4821, 4821, 0));
        assert_eq!(parsed.start_ticks, 777);
    }

    #[test]
    fn args_are_cut_at_the_count_and_byte_bounds() {
        let many: Vec<Vec<u8>> = (0..MAX_ARGS + 5).map(|i| format!("a{i}").into_bytes()).collect();
        let (kept, truncated) = bounded_args(many.iter().map(Vec::as_slice));
        assert_eq!((kept.len(), truncated), (MAX_ARGS, true));

        let big = vec![b'x'; MAX_ARG_BYTES];
        let (kept, truncated) = bounded_args([b"codex".as_slice(), big.as_slice()]);
        assert_eq!((kept, truncated), (vec!["codex".to_string()], true));

        let (kept, truncated) = bounded_args([b"claude".as_slice(), b"--resume".as_slice()]);
        assert_eq!((kept.len(), truncated), (2, false));
    }

    #[test]
    fn cmdline_terminator_is_not_an_argument() {
        let args: Vec<&[u8]> = split_cmdline(b"codex\0app-server\0").collect();
        assert_eq!(args, [b"codex".as_slice(), b"app-server".as_slice()]);
        assert_eq!(split_cmdline(b"").count(), 0);
    }

    #[test]
    fn procargs2_reads_arguments_and_never_the_environment() {
        let mut data = 2i32.to_ne_bytes().to_vec();
        data.extend_from_slice(b"/opt/codex\0\0\0codex\0app-server\0OPENAI_API_KEY=secret\0\0");
        let args = procargs2_args(&data).expect("parses");
        assert_eq!(args, [b"codex".as_slice(), b"app-server".as_slice()]);
    }

    #[test]
    fn procargs2_with_a_huge_argc_walks_only_the_bound() {
        let mut data = i32::MAX.to_ne_bytes().to_vec();
        data.extend_from_slice(b"/bin/x\0");
        for _ in 0..MAX_ARGS * 4 {
            data.extend_from_slice(b"a\0");
        }
        let args = procargs2_args(&data).expect("parses");
        assert_eq!(args.len(), MAX_ARGS + 1);
        assert!(bounded_args(args).1);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_scan_finds_this_process_as_one_generation() {
        let own = std::process::id();
        let inventory = scan(MAX_INVENTORY_PROCESSES);
        let process = inventory
            .processes
            .iter()
            .find(|process| process.pid == own)
            .expect("this process is in its own user's inventory");
        let started = crate::process_identity::started_ms(own).expect("own start time");
        assert!(process.started_ms.abs_diff(started) <= 1_000);
        let exe = std::env::current_exe().expect("own exe");
        assert_eq!(process.name, basename(&exe.to_string_lossy()));
        assert!(process.memory_bytes.is_some_and(|bytes| bytes > 0));
        assert!(inventory.processes.windows(2).all(|pair| pair[0].pid < pair[1].pid));
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_scan_past_its_limit_says_it_was_cut() {
        let inventory = scan(1);
        assert_eq!(inventory.processes.len(), 1);
        assert!(inventory.truncated);
    }
}
