use std::cell::Cell;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{Context, bail};

use super::{Child, MasterPty, PtyCommand, PtyOpenError, PtySize};

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn ptsname_r(
        descriptor: libc::c_int,
        buffer: *mut libc::c_char,
        length: libc::size_t,
    ) -> libc::c_int;
}

pub(crate) struct Slave(File);

struct DescriptorCleanup {
    descriptor_limit: RawFd,
}

#[cfg(target_os = "linux")]
const MAX_INDIVIDUAL_DESCRIPTOR_LIMIT: RawFd = 65_536;

impl DescriptorCleanup {
    fn new(descriptor_limit: RawFd) -> Self {
        Self { descriptor_limit }
    }
}

pub(crate) fn open(size: PtySize) -> anyhow::Result<(Box<dyn MasterPty + Send>, Slave)> {
    let master = open_pty_master()?;
    retry_pty_control(master.as_raw_fd(), libc::grantpt).context("failed to grant PTY slave")?;
    retry_pty_control(master.as_raw_fd(), libc::unlockpt).context("failed to unlock PTY slave")?;
    let slave_name = pty_slave_name(master.as_raw_fd())?;
    let slave = open_pty_slave(&slave_name)?;
    set_window_size(&slave, size)?;

    Ok((Box::new(MacOsMasterPty { file: master, took_writer: Cell::new(false) }), Slave(slave)))
}

fn open_pty_master() -> anyhow::Result<File> {
    let flags = libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC;
    loop {
        let descriptor = unsafe { libc::posix_openpt(flags) };
        if descriptor >= 0 {
            let master = unsafe { File::from_raw_fd(descriptor) };
            require_cloexec(&master, "PTY master")?;
            return Ok(master);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(PtyOpenError::from_io(error).into());
        }
    }
}

fn retry_pty_control(
    descriptor: RawFd,
    operation: unsafe extern "C" fn(RawFd) -> libc::c_int,
) -> io::Result<()> {
    loop {
        if unsafe { operation(descriptor) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

fn pty_slave_name(descriptor: RawFd) -> anyhow::Result<CString> {
    let mut buffer = [0 as libc::c_char; 128];
    loop {
        let status = platform_ptsname_r(descriptor, buffer.as_mut_ptr(), buffer.len());
        if status == 0 {
            let name = unsafe { CStr::from_ptr(buffer.as_ptr()) };
            anyhow::ensure!(!name.to_bytes().is_empty(), "PTY slave name is empty");
            return Ok(name.to_owned());
        }
        let error = ptsname_error(status);
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error).context("failed to resolve PTY slave name");
        }
    }
}

#[cfg(target_os = "macos")]
fn platform_ptsname_r(descriptor: RawFd, buffer: *mut libc::c_char, length: usize) -> libc::c_int {
    unsafe { ptsname_r(descriptor, buffer, length) }
}

#[cfg(target_os = "linux")]
fn platform_ptsname_r(descriptor: RawFd, buffer: *mut libc::c_char, length: usize) -> libc::c_int {
    unsafe { libc::ptsname_r(descriptor, buffer, length) }
}

#[cfg(target_os = "macos")]
fn ptsname_error(_status: libc::c_int) -> io::Error {
    io::Error::last_os_error()
}

#[cfg(target_os = "linux")]
fn ptsname_error(status: libc::c_int) -> io::Error {
    io::Error::from_raw_os_error(status)
}

fn open_pty_slave(name: &CStr) -> anyhow::Result<File> {
    let flags = libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC;
    loop {
        let descriptor = unsafe { libc::open(name.as_ptr(), flags) };
        if descriptor >= 0 {
            let slave = unsafe { File::from_raw_fd(descriptor) };
            require_cloexec(&slave, "PTY slave")?;
            return Ok(slave);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(PtyOpenError::from_io(error).into());
        }
    }
}

fn require_cloexec(file: &File, role: &str) -> anyhow::Result<()> {
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error())
            .with_context(|| format!("failed to inspect {role}"));
    }
    anyhow::ensure!(flags & libc::FD_CLOEXEC != 0, "{role} was not opened close-on-exec");
    Ok(())
}

fn set_window_size(slave: &File, size: PtySize) -> anyhow::Result<()> {
    let window_size = libc::winsize {
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: size.pixel_width,
        ws_ypixel: size.pixel_height,
    };
    loop {
        if unsafe {
            libc::ioctl(
                slave.as_raw_fd(),
                libc::TIOCSWINSZ as _,
                &window_size as *const libc::winsize,
            )
        } == 0
        {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error).context("failed to configure PTY window size");
        }
    }
}

pub(crate) fn spawn(
    slave: &Slave,
    command: PtyCommand,
) -> anyhow::Result<Box<dyn Child + Send + Sync>> {
    let shell = resolved_shell(&command);
    let mut process = Command::new(&command.program);
    process.args(&command.args);
    if command.cwd_descriptor.is_none()
        && let Some(cwd) = command.cwd.as_deref()
    {
        process.current_dir(cwd);
    }
    if command.clean_environment {
        process.env_clear();
    }
    process.envs(&command.environment);
    process.env("SHELL", shell);
    let cwd_descriptor = command.cwd_descriptor;

    process
        .stdin(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stdin")?))
        .stdout(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stdout")?))
        .stderr(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stderr")?));
    let descriptor_limit = unsafe { libc::getdtablesize() };
    if descriptor_limit < 3 {
        bail!("failed to determine the process descriptor limit");
    }
    let descriptor_cleanup = DescriptorCleanup::new(descriptor_limit);
    unsafe {
        process.pre_exec(move || {
            for signal in [
                libc::SIGCHLD,
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGALRM,
            ] {
                libc::signal(signal, libc::SIG_DFL);
            }

            let mut empty_set = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
            if libc::sigemptyset(empty_set.as_mut_ptr()) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::sigprocmask(libc::SIG_SETMASK, empty_set.as_ptr(), std::ptr::null_mut()) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            #[allow(clippy::cast_lossless)]
            if libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY as _, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            if let Some(directory) = cwd_descriptor.as_ref()
                && libc::fchdir(directory.as_raw_fd()) == -1
            {
                return Err(io::Error::last_os_error());
            }
            mark_inherited_descriptors_close_on_exec(&descriptor_cleanup)?;
            Ok(())
        });
    }

    let child = process.spawn().context("failed to spawn PTY command")?;
    Ok(Box::new(child))
}

fn mark_inherited_descriptors_close_on_exec(cleanup: &DescriptorCleanup) -> io::Result<()> {
    // `Command::spawn` installs a private CLOEXEC pipe so the child can
    // report pre-exec and exec failures. Closing every descriptor here would
    // close that pipe and make a failed exec look successful. Marking the
    // child copies CLOEXEC preserves error reporting and still closes every
    // inherited descriptor when exec succeeds.
    #[cfg(target_os = "linux")]
    {
        const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
        // SAFETY: this affects only the child-side descriptor table between
        // fork and exec. CLOEXEC preserves Rust's private exec-error pipe.
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
        if let Ok(directory_fd) = open_child_proc_descriptor_directory() {
            let result = mark_proc_descriptors_close_on_exec(directory_fd);
            // The directory is already CLOEXEC, so a failed close cannot leak
            // through exec. Do not retry close after EINTR because the fd may
            // already have been reused.
            unsafe { libc::close(directory_fd) };
            return result;
        }
        // Never turn an adversarial or unusually large descriptor limit into
        // hundreds of thousands of syscalls in the post-fork child. Returning
        // an error aborts the spawn before exec, so failing closed preserves
        // descriptor isolation without stalling the parent.
        if cleanup.descriptor_limit > MAX_INDIVIDUAL_DESCRIPTOR_LIMIT {
            return Err(io::Error::from_raw_os_error(libc::EOVERFLOW));
        }
    }
    mark_descriptors_close_on_exec_individually(cleanup.descriptor_limit)
}

#[cfg(target_os = "linux")]
fn open_child_proc_descriptor_directory() -> io::Result<RawFd> {
    const PROC_SELF_FD: &[u8] = b"/proc/self/fd\0";
    loop {
        // Open after fork so `/proc/self/fd` resolves to the child's table.
        // Raw syscalls avoid allocator and libc lock state in `pre_exec`.
        let descriptor = unsafe {
            libc::syscall(
                libc::SYS_openat,
                libc::AT_FDCWD,
                PROC_SELF_FD.as_ptr().cast::<libc::c_char>(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                0,
            )
        };
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

fn mark_descriptors_close_on_exec_individually(descriptor_limit: RawFd) -> io::Result<()> {
    for descriptor in 3..descriptor_limit {
        match mark_descriptor_close_on_exec(descriptor) {
            Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
            result => result?,
        }
    }
    Ok(())
}

fn mark_descriptor_close_on_exec(descriptor: RawFd) -> io::Result<()> {
    let flags = loop {
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
        if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } != -1 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

#[cfg(target_os = "linux")]
fn mark_proc_descriptors_close_on_exec(directory_fd: RawFd) -> io::Result<()> {
    loop {
        if unsafe { libc::lseek(directory_fd, 0, libc::SEEK_SET) } != -1 {
            break;
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }

    const DIRENT_NAME_OFFSET: usize = 19;
    let mut entries = [0_u8; 4096];
    loop {
        let count = loop {
            let count = unsafe {
                libc::syscall(
                    libc::SYS_getdents64,
                    directory_fd,
                    entries.as_mut_ptr(),
                    entries.len(),
                )
            };
            if count >= 0 {
                break count as usize;
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EINTR) {
                return Err(error);
            }
        };
        if count == 0 {
            return Ok(());
        }

        let mut offset = 0;
        while offset < count {
            let remaining = &entries[offset..count];
            if remaining.len() <= DIRENT_NAME_OFFSET {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            let record_length = u16::from_ne_bytes([remaining[16], remaining[17]]) as usize;
            if record_length <= DIRENT_NAME_OFFSET || record_length > remaining.len() {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            let name = &remaining[DIRENT_NAME_OFFSET..record_length];
            let name = &name[..name.iter().position(|byte| *byte == 0).unwrap_or(name.len())];
            if let Some(descriptor) = parse_decimal_descriptor(name)
                && descriptor >= 3
            {
                match mark_descriptor_close_on_exec(descriptor) {
                    Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
                    result => result?,
                }
            }
            offset += record_length;
        }
    }
}

#[cfg(target_os = "linux")]
fn parse_decimal_descriptor(name: &[u8]) -> Option<RawFd> {
    if name.is_empty() {
        return None;
    }
    name.iter().try_fold(0_i32, |value, byte| {
        byte.is_ascii_digit()
            .then(|| value.checked_mul(10)?.checked_add(i32::from(*byte - b'0')))
            .flatten()
    })
}

struct MacOsMasterPty {
    file: File,
    took_writer: Cell<bool>,
}

impl MasterPty for MacOsMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        let window_size = libc::winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: size.pixel_width,
            ws_ypixel: size.pixel_height,
        };
        if unsafe {
            libc::ioctl(self.file.as_raw_fd(), libc::TIOCSWINSZ as _, &window_size as *const _)
        } != 0
        {
            bail!("failed to resize PTY: {}", io::Error::last_os_error());
        }
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        let mut size = std::mem::MaybeUninit::<libc::winsize>::zeroed();
        if unsafe { libc::ioctl(self.file.as_raw_fd(), libc::TIOCGWINSZ as _, size.as_mut_ptr()) }
            != 0
        {
            bail!("failed to read PTY size: {}", io::Error::last_os_error());
        }
        let size = unsafe { size.assume_init() };
        Ok(PtySize {
            rows: size.ws_row,
            cols: size.ws_col,
            pixel_width: size.ws_xpixel,
            pixel_height: size.ws_ypixel,
        })
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(MacOsMasterReader { file: self.file.try_clone()? }))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        if self.took_writer.replace(true) {
            bail!("cannot take PTY writer more than once");
        }
        Ok(Box::new(MacOsMasterWriter { file: self.file.try_clone()? }))
    }

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        match unsafe { libc::tcgetpgrp(self.file.as_raw_fd()) } {
            pid if pid > 0 => Some(pid),
            _ => None,
        }
    }

    fn as_raw_fd(&self) -> Option<RawFd> {
        Some(self.file.as_raw_fd())
    }

    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

struct MacOsMasterReader {
    file: File,
}

impl Read for MacOsMasterReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self.file.read(buffer) {
            Err(error) if error.raw_os_error() == Some(libc::EIO) => Ok(0),
            result => result,
        }
    }
}

struct MacOsMasterWriter {
    file: File,
}

impl Write for MacOsMasterWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.file.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Drop for MacOsMasterWriter {
    fn drop(&mut self) {
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        if unsafe { libc::tcgetattr(self.file.as_raw_fd(), termios.as_mut_ptr()) } == 0 {
            let termios = unsafe { termios.assume_init() };
            let end_of_transmission = termios.c_cc[libc::VEOF];
            if end_of_transmission != 0 {
                let _ = self.file.write_all(&[b'\n', end_of_transmission]);
            }
        }
    }
}

fn resolved_shell(command: &PtyCommand) -> OsString {
    let configured = command
        .environment
        .get("SHELL")
        .map(OsString::from)
        .or_else(|| (!command.clean_environment).then(|| std::env::var_os("SHELL")).flatten());
    if let Some(shell) = configured
        && is_executable(&shell)
    {
        return shell;
    }

    if let Some(shell) = account_shell(unsafe { libc::getuid() }) {
        return shell;
    }
    OsString::from("/bin/sh")
}

fn account_shell(uid: libc::uid_t) -> Option<OsString> {
    const DEFAULT_BUFFER_SIZE: usize = 1_024;
    const MAX_BUFFER_SIZE: usize = 64 * 1_024;

    let suggested_size = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let initial_size = usize::try_from(suggested_size)
        .unwrap_or(DEFAULT_BUFFER_SIZE)
        .clamp(DEFAULT_BUFFER_SIZE, MAX_BUFFER_SIZE);
    let mut buffer = vec![0_u8; initial_size];

    loop {
        let mut password_entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                password_entry.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == 0 {
            if result.is_null() {
                return None;
            }
            let shell_pointer = unsafe { (*result).pw_shell };
            if shell_pointer.is_null() {
                return None;
            }
            let shell = unsafe { CStr::from_ptr(shell_pointer) };
            return (!shell.to_bytes().is_empty())
                .then(|| OsString::from_vec(shell.to_bytes().to_vec()));
        }
        if status != libc::ERANGE || buffer.len() == MAX_BUFFER_SIZE {
            return None;
        }
        buffer.resize((buffer.len() * 2).min(MAX_BUFFER_SIZE), 0);
    }
}

fn is_executable(path: &OsStr) -> bool {
    let Ok(path) = CString::new(path.as_bytes()) else { return false };
    unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
}

#[cfg(test)]
mod shell_tests {
    use super::account_shell;

    #[test]
    fn account_shell_lookup_is_owned_and_safe_to_run_concurrently() {
        let uid = unsafe { libc::getuid() };
        let expected = account_shell(uid);
        let workers = (0..16)
            .map(|_| {
                let expected = expected.clone();
                std::thread::spawn(move || {
                    for _ in 0..64 {
                        assert_eq!(account_shell(uid), expected);
                    }
                })
            })
            .collect::<Vec<_>>();

        for worker in workers {
            worker.join().unwrap();
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod linux_tests {
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};

    use super::{DescriptorCleanup, mark_inherited_descriptors_close_on_exec};

    #[test]
    fn oversized_descriptor_limit_fails_without_scanning_when_fast_paths_are_unavailable() {
        const CHILD_ENV: &str = "CMUX_PTY_HIGH_FD_FALLBACK_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg(
                    "macos::linux_tests::oversized_descriptor_limit_fails_without_scanning_when_fast_paths_are_unavailable",
                )
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "PTY fallback scanned an oversized descriptor table:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let source = File::open("/dev/null").unwrap();
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        let _inherited = unsafe { File::from_raw_fd(descriptor) };
        install_close_range_openat_and_fcntl_eperm_filter();

        let cleanup = DescriptorCleanup::new(1_048_576);
        let error = mark_inherited_descriptors_close_on_exec(&cleanup)
            .expect_err("oversized descriptor table should fail before an individual scan");
        assert_eq!(error.raw_os_error(), Some(libc::EOVERFLOW));
    }

    #[test]
    fn close_range_fallback_enumerates_the_child_descriptor_table() {
        const CHILD_ENV: &str = "CMUX_PTY_CHILD_FD_TABLE_SECCOMP_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg(
                    "macos::linux_tests::close_range_fallback_enumerates_the_child_descriptor_table",
                )
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "PTY fallback inspected the parent's descriptor table:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        install_close_range_eperm_filter();
        let source = File::open("/dev/null").unwrap();
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        let inherited = unsafe { File::from_raw_fd(descriptor) };
        let cleanup = DescriptorCleanup::new(unsafe { libc::getdtablesize() });
        let mut child_ready = [-1; 2];
        let mut parent_ready = [-1; 2];
        assert_eq!(unsafe { libc::pipe2(child_ready.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
        assert_eq!(unsafe { libc::pipe2(parent_ready.as_mut_ptr(), libc::O_CLOEXEC) }, 0);

        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed: {}", io::Error::last_os_error());
        if child == 0 {
            unsafe {
                libc::close(child_ready[0]);
                libc::close(parent_ready[1]);
                let marker = [1_u8];
                if libc::write(child_ready[1], marker.as_ptr().cast(), marker.len()) != 1 {
                    libc::_exit(2);
                }
                let mut acknowledgement = [0_u8];
                if libc::read(
                    parent_ready[0],
                    acknowledgement.as_mut_ptr().cast(),
                    acknowledgement.len(),
                ) != 1
                {
                    libc::_exit(3);
                }
            }
            let marked =
                mark_inherited_descriptors_close_on_exec(&cleanup).is_ok_and(|()| unsafe {
                    let flags = libc::fcntl(descriptor, libc::F_GETFD);
                    flags != -1 && flags & libc::FD_CLOEXEC != 0
                });
            unsafe { libc::_exit(if marked { 0 } else { 4 }) };
        }

        unsafe {
            libc::close(child_ready[1]);
            libc::close(parent_ready[0]);
        }
        let mut marker = [0_u8];
        assert_eq!(
            unsafe { libc::read(child_ready[0], marker.as_mut_ptr().cast(), marker.len()) },
            1
        );
        drop(inherited);
        assert_eq!(
            unsafe { libc::write(parent_ready[1], marker.as_ptr().cast(), marker.len()) },
            1
        );
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(child, &mut status, 0) }, child);
        assert_eq!(status, 0, "child descriptor cleanup exited with wait status {status}");
    }

    fn install_close_range_eperm_filter() {
        let mut filter = [
            libc::sock_filter {
                code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
                jt: 0,
                jf: 0,
                k: 0,
            },
            libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 0,
                jf: 1,
                k: libc::SYS_close_range as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ALLOW,
            },
        ];
        let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

        let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
        assert_eq!(
            no_new_privileges,
            0,
            "PR_SET_NO_NEW_PRIVS failed: {}",
            io::Error::last_os_error()
        );
        let installed = unsafe {
            libc::prctl(
                libc::PR_SET_SECCOMP,
                libc::SECCOMP_MODE_FILTER,
                &program as *const libc::sock_fprog,
            )
        };
        assert_eq!(
            installed,
            0,
            "seccomp filter installation failed: {}",
            io::Error::last_os_error()
        );
    }

    fn install_close_range_openat_and_fcntl_eperm_filter() {
        let mut filter = [
            libc::sock_filter {
                code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
                jt: 0,
                jf: 0,
                k: 0,
            },
            libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 2,
                jf: 0,
                k: libc::SYS_close_range as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 1,
                jf: 0,
                k: libc::SYS_openat as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 0,
                jf: 1,
                k: libc::SYS_fcntl as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ALLOW,
            },
        ];
        let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

        let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
        assert_eq!(
            no_new_privileges,
            0,
            "PR_SET_NO_NEW_PRIVS failed: {}",
            io::Error::last_os_error()
        );
        let installed = unsafe {
            libc::prctl(
                libc::PR_SET_SECCOMP,
                libc::SECCOMP_MODE_FILTER,
                &program as *const libc::sock_fprog,
            )
        };
        assert_eq!(
            installed,
            0,
            "seccomp filter installation failed: {}",
            io::Error::last_os_error()
        );
    }
}
