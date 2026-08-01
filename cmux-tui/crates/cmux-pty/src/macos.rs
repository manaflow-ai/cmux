use std::cell::Cell;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
#[cfg(target_os = "linux")]
use std::fs::OpenOptions;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
#[cfg(target_os = "linux")]
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{Context, bail};

use super::{Child, MasterPty, PtyCommand, PtySize};

pub(crate) struct Slave(File);

struct DescriptorCleanup {
    descriptor_limit: RawFd,
    #[cfg(target_os = "linux")]
    proc_fd_directory: Option<File>,
}

impl DescriptorCleanup {
    fn new(descriptor_limit: RawFd) -> Self {
        Self {
            descriptor_limit,
            #[cfg(target_os = "linux")]
            proc_fd_directory: OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
                .open("/proc/self/fd")
                .ok(),
        }
    }
}

pub(crate) fn open(size: PtySize) -> anyhow::Result<(Box<dyn MasterPty + Send>, Slave)> {
    let mut master_fd = -1;
    let mut slave_fd = -1;
    let mut window_size = libc::winsize {
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: size.pixel_width,
        ws_ypixel: size.pixel_height,
    };
    let result = unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut window_size,
        )
    };
    if result != 0 {
        bail!("failed to open PTY: {}", io::Error::last_os_error());
    }

    let master = unsafe { File::from_raw_fd(master_fd) };
    let slave = unsafe { File::from_raw_fd(slave_fd) };
    set_cloexec(&master).context("failed to configure PTY master")?;
    set_cloexec(&slave).context("failed to configure PTY slave")?;

    Ok((Box::new(MacOsMasterPty { file: master, took_writer: Cell::new(false) }), Slave(slave)))
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
        if let Some(directory) = cleanup.proc_fd_directory.as_ref() {
            return mark_proc_descriptors_close_on_exec(directory.as_raw_fd());
        }
        const MAX_BOUNDED_DESCRIPTOR_SCAN: RawFd = 65_536;
        if cleanup.descriptor_limit > MAX_BOUNDED_DESCRIPTOR_SCAN {
            return Err(error);
        }
    }
    mark_descriptors_close_on_exec_individually(cleanup.descriptor_limit)
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

fn set_cloexec(file: &File) -> io::Result<()> {
    let descriptor = file.as_raw_fd();
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
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

    let password_entry = unsafe { libc::getpwuid(libc::getuid()) };
    if !password_entry.is_null() {
        let shell = unsafe { CStr::from_ptr((*password_entry).pw_shell) };
        if !shell.to_bytes().is_empty() {
            return OsString::from_vec(shell.to_bytes().to_vec());
        }
    }
    OsString::from("/bin/sh")
}

fn is_executable(path: &OsStr) -> bool {
    let Ok(path) = CString::new(path.as_bytes()) else { return false };
    unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
}
