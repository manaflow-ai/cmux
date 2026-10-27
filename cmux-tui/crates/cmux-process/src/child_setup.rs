//! The std path's child side: what runs between std's fork and its exec, on
//! Linux and other non-Apple Unix for every child that needs more than std,
//! and on macOS only for a child that needs a controlling terminal
//! ([`crate::Command::open_stdin_path`] with [`crate::Command::new_session`]),
//! which `posix_spawn` cannot give. Only async-signal-safe calls on data the
//! parent prepared; nothing here allocates or takes a lock.

use std::ffi::CString;
use std::io;
use std::os::fd::RawFd;

/// What one child does before its exec, in this order: (macOS) set its QoS
/// class, leave the session, change to its directory, set its open-file
/// limit, reset its signals and mark every descriptor close-on-exec
/// ([`DescriptorSweep`]), open its stdin path and make it the controlling
/// terminal, place its inherited descriptors, install its process-group
/// fence.
pub(crate) struct ChildSetup {
    pub(crate) new_session: bool,
    pub(crate) cwd_fd: Option<RawFd>,
    /// `Command::isolate`.
    pub(crate) sweep: Option<DescriptorSweep>,
    /// (path, also onto 1, also onto 2).
    pub(crate) stdin_path: Option<(CString, bool, bool)>,
    /// (descriptor, the number the child gets it at); no descriptor is
    /// numbered as any target.
    pub(crate) inherit: Vec<(RawFd, RawFd)>,
    pub(crate) process_group_fence: bool,
    pub(crate) open_file_limit: Option<u64>,
    /// After `new_session` and the open of `stdin_path`: make that terminal
    /// the controlling terminal (`TIOCSCTTY` on descriptor 0), so its line
    /// discipline sends SIGINT, SIGQUIT and SIGTSTP to the foreground group
    /// and its hangup reaches the session.
    pub(crate) controlling_terminal: bool,
    /// macOS: the QoS class the child's thread runs at before its exec. A
    /// forked child keeps the spawning thread's class across the exec (a
    /// `posix_spawn` child starts at its attribute's), so a shell started
    /// from a UserInteractive echo thread would run at it.
    #[cfg(target_vendor = "apple")]
    pub(crate) qos_class: libc::qos_class_t,
}

impl ChildSetup {
    /// Run in the forked child.
    pub(crate) fn run(&self) -> io::Result<()> {
        // SAFETY: one system call on the calling (only) thread, with no lock
        // (the holder makes the same call after its fork).
        #[cfg(target_vendor = "apple")]
        unsafe {
            libc::pthread_set_qos_class_self_np(self.qos_class, 0);
        }
        // SAFETY: setsid and fchdir are async-signal-safe and change only
        // this (child) process.
        unsafe {
            if self.new_session && libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if let Some(dir) = self.cwd_fd
                && libc::fchdir(dir) < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        if let Some(soft) = self.open_file_limit {
            set_open_file_limit(soft)?;
        }
        if let Some(sweep) = &self.sweep {
            reset_signals()?;
            // Before the descriptors below are placed: those must stay open.
            sweep.mark_close_on_exec()?;
        }
        // SAFETY: open, dup2, close and fcntl are async-signal-safe and touch
        // only the child's own table.
        unsafe {
            // After setsid: a terminal opened here becomes the controlling
            // terminal of the new session.
            if let Some((path, onto_out, onto_err)) = &self.stdin_path {
                let fd = libc::open(path.as_ptr(), libc::O_RDWR);
                if fd < 0 {
                    return Err(io::Error::last_os_error());
                }
                for (wanted, target) in [(true, 0), (*onto_out, 1), (*onto_err, 2)] {
                    if wanted && fd != target && libc::dup2(fd, target) < 0 {
                        return Err(io::Error::last_os_error());
                    }
                }
                if fd > 2 {
                    libc::close(fd);
                }
                // Linux acquires the terminal at that open; macOS does not
                // when the open runs before setsid (as in posix_spawn), so ask
                // for it, and fail the spawn when the terminal cannot become
                // the controlling one instead of starting a shell that Ctrl-C
                // never reaches. On the session's own terminal it is a no-op.
                if self.controlling_terminal && libc::ioctl(0, libc::TIOCSCTTY as _, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            // No source is numbered as a target (`fd::lift_sources_above_targets`
            // ran in the parent), so each dup2 reads an intact source and
            // gives the child a copy without close-on-exec.
            for &(fd, at) in &self.inherit {
                if libc::dup2(fd, at) < 0 {
                    return Err(io::Error::last_os_error());
                }
            }
        }
        if self.process_group_fence {
            install_process_group_fence()?;
        }
        Ok(())
    }
}

/// `setrlimit(RLIMIT_NOFILE)` with `soft` (at most the hard limit).
fn set_open_file_limit(soft: u64) -> io::Result<()> {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit and setrlimit are async-signal-safe; `limit` is
    // valid storage for one rlimit.
    unsafe {
        if libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) != 0 {
            return Err(io::Error::last_os_error());
        }
        limit.rlim_cur = (soft as libc::rlim_t).min(limit.rlim_max);
        if libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Every signal back to its default disposition and an empty signal mask
/// (both survive exec, and std keeps the parent thread's mask). A signal the
/// C library reserves refuses the disposition change, which is harmless.
fn reset_signals() -> io::Result<()> {
    #[cfg(target_os = "linux")]
    const LAST_SIGNAL: libc::c_int = 64;
    #[cfg(not(target_os = "linux"))]
    const LAST_SIGNAL: libc::c_int = 31;
    for signal in 1..=LAST_SIGNAL {
        if signal == libc::SIGKILL || signal == libc::SIGSTOP {
            continue;
        }
        // SAFETY: sigaction is async-signal-safe; a zeroed action with
        // SIG_DFL is a valid default disposition.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = libc::SIG_DFL;
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    // SAFETY: sigemptyset and sigprocmask are async-signal-safe; the set is
    // initialized before use.
    unsafe {
        let mut empty = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
        if libc::sigemptyset(empty.as_mut_ptr()) != 0
            || libc::sigprocmask(libc::SIG_SETMASK, empty.as_ptr(), std::ptr::null_mut()) != 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Marks every descriptor above stderr close-on-exec in the child, so it
/// passes on only what the setup places after it. Marking, not closing:
/// std's private close-on-exec pipe reports an exec failure, and closing it
/// would make a failed exec look successful.
pub(crate) struct DescriptorSweep {
    /// The descriptor limit, read before the fork.
    limit: RawFd,
}

/// The individual scan never runs past this many descriptor numbers: a
/// larger table fails the spawn (EOVERFLOW) instead of turning into hundreds
/// of thousands of syscalls in the forked child.
#[cfg(target_os = "linux")]
const MAX_INDIVIDUAL_DESCRIPTOR_LIMIT: RawFd = 65_536;

impl DescriptorSweep {
    pub(crate) fn new() -> Self {
        // SAFETY: getdtablesize takes no arguments.
        Self { limit: unsafe { libc::getdtablesize() }.max(3) }
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn with_limit(limit: RawFd) -> Self {
        Self { limit }
    }

    /// Linux: `close_range(CLOSE_RANGE_CLOEXEC)` (5.11+), else the child's
    /// own descriptor directory, else each number up to the limit. macOS:
    /// the child's own descriptor directory, else each number up to the
    /// limit. The directory is `/proc/self/fd` on Linux and `/dev/fd` on
    /// macOS (fdesc: the calling process's own table), as Chromium's
    /// `CloseSuperfluousFds` reads it.
    pub(crate) fn mark_close_on_exec(&self) -> io::Result<()> {
        #[cfg(target_os = "linux")]
        {
            const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
            // SAFETY: affects only the child's descriptor table.
            let result = unsafe {
                libc::syscall(
                    libc::SYS_close_range,
                    3 as libc::c_uint,
                    libc::c_uint::MAX,
                    CLOSE_RANGE_CLOEXEC,
                )
            };
            if result == 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if !matches!(
                error.raw_os_error(),
                Some(libc::ENOSYS) | Some(libc::EINVAL) | Some(libc::EPERM)
            ) {
                return Err(error);
            }
        }
        if let Ok(directory) = open_own_descriptor_directory() {
            let result = mark_listed_close_on_exec(directory);
            // The directory is close-on-exec, so a failed close cannot leak
            // through exec; no retry after EINTR (the number may already be
            // reused).
            // SAFETY: the descriptor opened just above.
            unsafe { libc::close(directory) };
            return result;
        }
        #[cfg(target_os = "linux")]
        if self.limit > MAX_INDIVIDUAL_DESCRIPTOR_LIMIT {
            return Err(io::Error::from_raw_os_error(libc::EOVERFLOW));
        }
        for descriptor in 3..self.limit {
            match mark_close_on_exec(descriptor) {
                Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
                result => result?,
            }
        }
        Ok(())
    }
}

/// Open the child's own descriptor directory (after the fork, so it names
/// the child's table): Linux `/proc/self/fd` with a raw syscall (no
/// allocator or libc lock), macOS `/dev/fd` with `open(2)`, which is
/// async-signal-safe.
fn open_own_descriptor_directory() -> io::Result<RawFd> {
    #[cfg(target_os = "linux")]
    const DIRECTORY: &[u8] = b"/proc/self/fd\0";
    #[cfg(not(target_os = "linux"))]
    const DIRECTORY: &[u8] = b"/dev/fd\0";
    loop {
        #[cfg(target_os = "linux")]
        // SAFETY: a NUL-terminated path; the result is a new descriptor or -1.
        let descriptor = unsafe {
            libc::syscall(
                libc::SYS_openat,
                libc::AT_FDCWD,
                DIRECTORY.as_ptr().cast::<libc::c_char>(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0,
            )
        };
        #[cfg(not(target_os = "linux"))]
        // SAFETY: a NUL-terminated path; the result is a new descriptor or -1.
        let descriptor = i64::from(unsafe {
            libc::open(
                DIRECTORY.as_ptr().cast::<libc::c_char>(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        });
        if descriptor >= 0 {
            return RawFd::try_from(descriptor)
                .map_err(|_| io::Error::from_raw_os_error(libc::EOVERFLOW));
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

/// Where a directory entry's record length and name are (Linux
/// `linux_dirent64`; macOS the 64-bit-inode `struct dirent` that
/// `__getdirentries64` fills: ino, seekoff, reclen, namlen, type, name).
#[cfg(target_os = "linux")]
const DIRENT_NAME_OFFSET: usize = 19;
#[cfg(not(target_os = "linux"))]
const DIRENT_NAME_OFFSET: usize = 21;
const DIRENT_RECORD_LENGTH_OFFSET: usize = 16;

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    /// libsystem_kernel's directory read (what `readdir` calls), with no
    /// allocation or lock: a raw system call into the caller's buffer.
    fn __getdirentries64(
        fd: libc::c_int,
        buffer: *mut libc::c_void,
        length: libc::size_t,
        base: *mut libc::off_t,
    ) -> libc::ssize_t;
}

/// Read the next directory entries of `directory` into `entries`: the byte
/// count, 0 at the end.
fn read_directory_entries(directory: RawFd, entries: &mut [u8]) -> io::Result<usize> {
    loop {
        #[cfg(target_os = "linux")]
        // SAFETY: getdents64 fills at most `entries.len()` bytes.
        let count = unsafe {
            libc::syscall(libc::SYS_getdents64, directory, entries.as_mut_ptr(), entries.len())
        };
        #[cfg(target_vendor = "apple")]
        let count = {
            let mut base: libc::off_t = 0;
            // SAFETY: fills at most `entries.len()` bytes and writes `base`.
            unsafe {
                __getdirentries64(directory, entries.as_mut_ptr().cast(), entries.len(), &mut base)
            }
        };
        #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
        let count: isize = {
            let _ = (directory, &entries);
            return Err(io::Error::from_raw_os_error(libc::ENOSYS));
        };
        if count >= 0 {
            return Ok(count as usize);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

/// Mark each descriptor the child's own descriptor directory lists (read
/// into a stack buffer).
fn mark_listed_close_on_exec(directory: RawFd) -> io::Result<()> {
    let mut entries = [0_u8; 4096];
    loop {
        let count = read_directory_entries(directory, &mut entries)?;
        if count == 0 {
            return Ok(());
        }
        let mut offset = 0;
        while offset < count {
            let remaining = &entries[offset..count];
            if remaining.len() <= DIRENT_NAME_OFFSET {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            let record_length = u16::from_ne_bytes([
                remaining[DIRENT_RECORD_LENGTH_OFFSET],
                remaining[DIRENT_RECORD_LENGTH_OFFSET + 1],
            ]) as usize;
            if record_length <= DIRENT_NAME_OFFSET || record_length > remaining.len() {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            let name = &remaining[DIRENT_NAME_OFFSET..record_length];
            let name = &name[..name.iter().position(|byte| *byte == 0).unwrap_or(name.len())];
            if let Some(descriptor) = parse_descriptor(name)
                && descriptor >= 3
                && descriptor != directory
            {
                match mark_close_on_exec(descriptor) {
                    Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
                    result => result?,
                }
            }
            offset += record_length;
        }
    }
}

fn parse_descriptor(name: &[u8]) -> Option<RawFd> {
    if name.is_empty() {
        return None;
    }
    name.iter().try_fold(0_i32, |value, byte| {
        byte.is_ascii_digit()
            .then(|| value.checked_mul(10)?.checked_add(i32::from(*byte - b'0')))
            .flatten()
    })
}

fn mark_close_on_exec(descriptor: RawFd) -> io::Result<()> {
    let flags = loop {
        // SAFETY: F_GETFD reads one descriptor's flags.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        if flags != -1 {
            break flags;
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    };
    if flags & libc::FD_CLOEXEC != 0 {
        return Ok(());
    }
    loop {
        // SAFETY: F_SETFD sets one descriptor's flags.
        if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } != -1 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

/// `Command::process_group_fence`: a seccomp filter (with `no_new_privs`)
/// that fails `setsid` and `setpgid` with EPERM and kills a process of
/// another syscall architecture.
#[cfg(target_os = "linux")]
fn install_process_group_fence() -> io::Result<()> {
    const SECCOMP_DATA_NR_OFFSET: u32 = 0;
    const SECCOMP_DATA_ARCH_OFFSET: u32 = 4;
    const X32_SYSCALL_BIT: u32 = 0x4000_0000;
    #[cfg(target_arch = "x86_64")]
    const AUDIT_ARCH: u32 = 0xc000_003e;
    #[cfg(target_arch = "aarch64")]
    const AUDIT_ARCH: u32 = 0xc000_00b7;
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    compile_error!("the process-group fence needs a Linux seccomp audit architecture");

    let statement = |code: u32, k: u32| libc::sock_filter { code: code as u16, jt: 0, jf: 0, k };
    let jump =
        |code: u32, k: u32, jt: u8, jf: u8| libc::sock_filter { code: code as u16, jt, jf, k };
    let denied = libc::SECCOMP_RET_ERRNO | libc::EPERM as u32;
    let mut filter = [
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, SECCOMP_DATA_ARCH_OFFSET),
        jump(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K, AUDIT_ARCH, 1, 0),
        statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_KILL_PROCESS),
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, SECCOMP_DATA_NR_OFFSET),
        statement(libc::BPF_ALU | libc::BPF_AND | libc::BPF_K, !X32_SYSCALL_BIT),
        jump(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K, libc::SYS_setsid as u32, 0, 1),
        statement(libc::BPF_RET | libc::BPF_K, denied),
        jump(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K, libc::SYS_setpgid as u32, 0, 1),
        statement(libc::BPF_RET | libc::BPF_K, denied),
        statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_ALLOW),
    ];
    let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };
    // SAFETY: prctl with a live filter program; it changes only this process.
    unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, &raw const program) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn install_process_group_fence() -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "a process-group fence needs Linux"))
}

/// The sweep's fallbacks, run where seccomp takes away the faster path (a
/// container that denies `close_range`, or also `openat` and `fcntl`).
#[cfg(all(test, target_os = "linux"))]
pub(crate) mod tests {
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};

    use super::DescriptorSweep;

    /// Runs `name` again in a new copy of this test binary with `env` set,
    /// so a seccomp filter it installs stays out of this process.
    pub(crate) fn rerun(name: &str, env: &str) {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([name, "--exact", "--nocapture"])
            .env(env, "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{name} failed in its own process:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// A descriptor numbered 200 or more without close-on-exec.
    fn inheritable_high_descriptor() -> (File, i32) {
        let source = File::open("/dev/null").unwrap();
        // SAFETY: F_DUPFD returns a new descriptor or -1.
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        // SAFETY: a new descriptor this test owns.
        (unsafe { File::from_raw_fd(descriptor) }, descriptor)
    }

    #[test]
    fn an_oversized_descriptor_limit_fails_without_a_scan_when_the_fast_paths_are_denied() {
        const CHILD: &str = "CMUX_PROCESS_SWEEP_OVERSIZED_CHILD";
        if std::env::var_os(CHILD).is_none() {
            return rerun(
                "child_setup::tests::an_oversized_descriptor_limit_fails_without_a_scan_when_the_fast_paths_are_denied",
                CHILD,
            );
        }
        let (_inherited, _) = inheritable_high_descriptor();
        deny(&[libc::SYS_close_range, libc::SYS_openat, libc::SYS_fcntl]);
        let error = DescriptorSweep::with_limit(1_048_576)
            .mark_close_on_exec()
            .expect_err("an oversized table must fail before an individual scan");
        assert_eq!(error.raw_os_error(), Some(libc::EOVERFLOW));
    }

    /// Without `close_range` the sweep reads `/proc/self/fd` (the
    /// process's own table) and marks what it lists. Spawned through the
    /// crate's own `isolate` path: the child must not see the descriptor.
    #[test]
    fn without_close_range_an_isolated_child_still_inherits_nothing() {
        const CHILD: &str = "CMUX_PROCESS_SWEEP_PROC_CHILD";
        if std::env::var_os(CHILD).is_none() {
            return rerun(
                "child_setup::tests::without_close_range_an_isolated_child_still_inherits_nothing",
                CHILD,
            );
        }
        deny(&[libc::SYS_close_range]);
        let (_inherited, descriptor) = inheritable_high_descriptor();
        let status = crate::Command::new("/bin/sh")
            .args(["-c", &format!("test ! -e /proc/self/fd/{descriptor}")])
            .isolate()
            .status()
            .unwrap();
        assert!(status.success(), "the isolated child inherited descriptor {descriptor}");
    }

    /// Fail each of `syscalls` with EPERM in this process from now on.
    pub(crate) fn deny(syscalls: &[libc::c_long]) {
        let mut filter = vec![libc::sock_filter {
            code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
            jt: 0,
            jf: 0,
            k: 0,
        }];
        for &syscall in syscalls {
            filter.push(libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 0,
                jf: 1,
                k: syscall as u32,
            });
            filter.push(libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
            });
        }
        filter.push(libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ALLOW,
        });
        let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };
        // SAFETY: prctl with a live filter program, in this re-run process.
        unsafe {
            assert_eq!(
                libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0),
                0,
                "{}",
                io::Error::last_os_error()
            );
            assert_eq!(
                libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, &raw const program),
                0,
                "{}",
                io::Error::last_os_error()
            );
        }
    }
}
