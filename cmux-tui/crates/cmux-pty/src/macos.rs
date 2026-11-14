use std::cell::Cell;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{Context, bail};

use super::{Child, MasterPty, PtyCommand, PtyOpenError, PtySize};

#[cfg(target_vendor = "apple")]
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
    /// Room for the child's descriptor list, allocated before fork (no
    /// allocation is allowed between fork and exec).
    #[cfg(target_vendor = "apple")]
    listed: Vec<libc::proc_fdinfo>,
}

#[cfg(target_os = "linux")]
const MAX_INDIVIDUAL_DESCRIPTOR_LIMIT: RawFd = 65_536;

impl DescriptorCleanup {
    fn new(descriptor_limit: RawFd) -> Self {
        Self {
            descriptor_limit,
            #[cfg(target_vendor = "apple")]
            listed: descriptor_list_buffer(),
        }
    }
}

/// A buffer for this process's descriptor list with headroom for the
/// descriptors opened before fork; empty when the count is unknown.
#[cfg(target_vendor = "apple")]
fn descriptor_list_buffer() -> Vec<libc::proc_fdinfo> {
    const HEADROOM: usize = 256;
    // SAFETY: a null buffer asks only for the size the list needs now.
    let bytes = unsafe {
        libc::proc_pidinfo(libc::getpid(), libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0)
    };
    let Ok(bytes) = usize::try_from(bytes) else { return Vec::new() };
    if bytes == 0 {
        return Vec::new();
    }
    let entries = bytes / size_of::<libc::proc_fdinfo>() + HEADROOM;
    vec![libc::proc_fdinfo { proc_fd: -1, proc_fdtype: 0 }; entries]
}

/// Mark the child's open descriptors (from `PROC_PIDLISTFDS`) close-on-exec.
/// None when the list is unavailable or may be cut short by the buffer: the
/// caller then examines every descriptor number.
#[cfg(target_vendor = "apple")]
fn mark_listed_descriptors_close_on_exec(
    listed: &mut [libc::proc_fdinfo],
) -> io::Result<Option<usize>> {
    let entry = size_of::<libc::proc_fdinfo>();
    let Ok(capacity) = libc::c_int::try_from(size_of_val(listed)) else { return Ok(None) };
    if capacity == 0 {
        return Ok(None);
    }
    // SAFETY: a raw proc_info syscall into memory allocated before fork; it
    // takes no lock and allocates nothing, so it is safe between fork and exec.
    let filled = unsafe {
        libc::proc_pidinfo(
            libc::getpid(),
            libc::PROC_PIDLISTFDS,
            0,
            listed.as_mut_ptr().cast(),
            capacity,
        )
    };
    if filled <= 0 || filled >= capacity {
        return Ok(None);
    }
    let count = usize::try_from(filled).unwrap_or(0) / entry;
    for info in &listed[..count] {
        if info.proc_fd < 3 {
            continue;
        }
        match mark_descriptor_close_on_exec(info.proc_fd) {
            Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
            result => result?,
        }
    }
    Ok(Some(count))
}

pub(crate) fn open(size: PtySize) -> anyhow::Result<(Box<dyn MasterPty + Send>, Slave)> {
    let master = open_pty_master()?;
    retry_pty_control(master.as_raw_fd(), libc::grantpt).context("failed to grant PTY slave")?;
    retry_pty_control(master.as_raw_fd(), libc::unlockpt).context("failed to unlock PTY slave")?;
    let slave_name = pty_slave_name(master.as_raw_fd())?;
    let slave = open_pty_slave(&slave_name)?;
    set_window_size(&slave, size)?;

    let master = MacOsMasterPty { file: master, took_writer: Cell::new(false), eof_on_drop: true };
    Ok((Box::new(master), Slave(slave)))
}

/// Wrap an inherited PTY master whose session another process started.
/// Its writer never sends the end-of-file sequence on drop: the session
/// belongs to whoever spawned it, not to this process.
pub(crate) fn adopt_master(
    master: std::os::fd::OwnedFd,
) -> anyhow::Result<Box<dyn MasterPty + Send>> {
    let file = File::from(master);
    if unsafe { libc::isatty(file.as_raw_fd()) } != 1 {
        bail!("inherited descriptor is not a PTY master: {}", io::Error::last_os_error());
    }
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) };
    if flags < 0
        || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        bail!("failed to mark the PTY master close-on-exec: {}", io::Error::last_os_error());
    }
    Ok(Box::new(MacOsMasterPty { file, took_writer: Cell::new(false), eof_on_drop: false }))
}

/// The code of a PTY master open that macOS refused for a moment: when many
/// masters are opened at the same time (a burst of terminal launches, such as
/// the restore of 170 kept terminals after an update), `posix_openpt` fails
/// with -6, far below `kern.tty.ptmx_max`. -6 is not a POSIX errno: it is a
/// code the kernel uses inside itself to say "drive this open again"
/// (`EREDRIVEOPEN` in XNU's `bsd/sys/errno.h`), and here it reaches the
/// caller. Measured with opens at the same moment and no second try: 44 of
/// 64 failed on macOS 26.5.2, 38 of 64 on 27.0.1. With the waits below every
/// one of 170 opened, the slowest on its 4th try.
const MASTER_OPEN_REFUSED_FOR_A_MOMENT: i32 = -6;

/// A refused master open is tried again this many times, after 1, 2, 4, 8,
/// 16, 32 ms and then 64 ms each: about 0.3 s in sum. After that the failure
/// is the caller's.
const MASTER_OPEN_SECOND_TRIES: u32 = 10;

fn open_pty_master() -> anyhow::Result<File> {
    let flags = libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC;
    let mut second_tries: u32 = 0;
    loop {
        let descriptor = unsafe { libc::posix_openpt(flags) };
        if descriptor >= 0 {
            let master = unsafe { File::from_raw_fd(descriptor) };
            require_cloexec(&master, "PTY master")?;
            return Ok(master);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        if error.raw_os_error() == Some(MASTER_OPEN_REFUSED_FOR_A_MOMENT)
            && second_tries < MASTER_OPEN_SECOND_TRIES
        {
            std::thread::sleep(Duration::from_millis(1 << second_tries.min(6)));
            second_tries += 1;
            continue;
        }
        return Err(PtyOpenError::from_io(error).into());
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

#[cfg(target_vendor = "apple")]
fn platform_ptsname_r(descriptor: RawFd, buffer: *mut libc::c_char, length: usize) -> libc::c_int {
    unsafe { ptsname_r(descriptor, buffer, length) }
}

#[cfg(target_os = "linux")]
fn platform_ptsname_r(descriptor: RawFd, buffer: *mut libc::c_char, length: usize) -> libc::c_int {
    unsafe { libc::ptsname_r(descriptor, buffer, length) }
}

#[cfg(target_vendor = "apple")]
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
    set_fd_window_size(slave.as_raw_fd(), size).context("failed to configure PTY window size")
}

/// TIOCSWINSZ on `fd`, retried on EINTR.
fn set_fd_window_size(fd: RawFd, size: PtySize) -> io::Result<()> {
    let window_size = libc::winsize {
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: size.pixel_width,
        ws_ypixel: size.pixel_height,
    };
    loop {
        if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ as _, &window_size as *const libc::winsize) }
            == 0
        {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
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
    // `PWD` names the directory as the caller spelled it. A shell keeps an
    // inherited `PWD` only when it names its working directory; otherwise
    // it shows getcwd(3), the real path, so a terminal started in /tmp read
    // /private/tmp on macOS (REOPEN-F3). A caller's own `PWD` (set or
    // removed) wins.
    if command.cwd_descriptor.is_none()
        && let Some(cwd) = command.cwd.as_deref().filter(|cwd| cwd.is_absolute())
        && !command.environment.contains_key("PWD")
        && !command.removed_environment.contains("PWD")
    {
        process.env("PWD", cwd);
    }
    // `SHELL` first, so a removal still wins over this backend's own override
    // (`PtyCommand::env_remove` promises the child never sees the key).
    process.env("SHELL", shell);
    for key in &command.removed_environment {
        process.env_remove(key);
    }
    let cwd_descriptor = command.cwd_descriptor;

    process
        .stdin(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stdin")?))
        .stdout(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stdout")?))
        .stderr(Stdio::from(slave.0.try_clone().context("failed to clone PTY slave for stderr")?));
    let descriptor_limit = unsafe { libc::getdtablesize() };
    if descriptor_limit < 3 {
        bail!("failed to determine the process descriptor limit");
    }
    let mut descriptor_cleanup = DescriptorCleanup::new(descriptor_limit);
    unsafe {
        process.pre_exec(move || {
            for signal in [
                libc::SIGCHLD,
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGALRM,
                libc::SIGPIPE,
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
            crate::open_files::restore_open_file_limit_in_child()?;
            mark_inherited_descriptors_close_on_exec(&mut descriptor_cleanup)?;
            Ok(())
        });
    }

    let child = process.spawn().context("failed to spawn PTY command")?;
    Ok(Box::new(child))
}

/// Mark every inherited descriptor above stderr close-on-exec in a forked
/// child. Returns how many descriptor numbers it examined one by one (0 when
/// a kernel fast path did it).
fn mark_inherited_descriptors_close_on_exec(cleanup: &mut DescriptorCleanup) -> io::Result<usize> {
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
            return Ok(0);
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
            return result.map(|()| 0);
        }
        // Never turn an adversarial or unusually large descriptor limit into
        // hundreds of thousands of syscalls in the post-fork child. Returning
        // an error aborts the spawn before exec, so failing closed preserves
        // descriptor isolation without stalling the parent.
        if cleanup.descriptor_limit > MAX_INDIVIDUAL_DESCRIPTOR_LIMIT {
            return Err(io::Error::from_raw_os_error(libc::EOVERFLOW));
        }
    }
    #[cfg(target_vendor = "apple")]
    if let Some(examined) = mark_listed_descriptors_close_on_exec(&mut cleanup.listed)? {
        return Ok(examined);
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
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
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

fn mark_descriptors_close_on_exec_individually(descriptor_limit: RawFd) -> io::Result<usize> {
    for descriptor in 3..descriptor_limit {
        match mark_descriptor_close_on_exec(descriptor) {
            Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
            result => result?,
        }
    }
    Ok(usize::try_from(descriptor_limit.saturating_sub(3)).unwrap_or(0))
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
    /// Whether the writer sends end-of-file to the child when dropped.
    eof_on_drop: bool,
}

impl MasterPty for MacOsMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        set_fd_window_size(self.file.as_raw_fd(), size)
            .map_err(|error| anyhow::anyhow!("failed to resize PTY: {error}"))
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
        Ok(Box::new(MacOsMasterWriter {
            file: self.file.try_clone()?,
            eof_on_drop: self.eof_on_drop,
        }))
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
    eof_on_drop: bool,
}

impl Write for MacOsMasterWriter {
    /// Never leaves the program's input queue ending right after an ESC (#22265).
    #[cfg(target_vendor = "apple")]
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        crate::input_queue::write(&mut self.file, buffer)
    }

    #[cfg(not(target_vendor = "apple"))]
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.file.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Drop for MacOsMasterWriter {
    fn drop(&mut self) {
        if !self.eof_on_drop {
            return;
        }
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
    // A removed `SHELL` is not recovered from this process's environment: the
    // caller asked for the key gone, so the account shell is used instead.
    if command.removed_environment.contains("SHELL") {
        return account_shell(unsafe { libc::getuid() })
            .unwrap_or_else(|| OsString::from("/bin/sh"));
    }
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
mod shell_tests;

#[cfg(all(test, target_os = "linux"))]
mod linux_tests;

/// #22265: a mouse wheel over Codex typed `[<65;30;7M` into its composer. A macOS PTY holds at most
/// 1,022 bytes of input; when the program reads slower than the wheel reports come, the kernel takes
/// a write byte by byte until the queue is full and blocks the rest. A report cut right after its
/// ESC leaves the queue ending in a lone ESC, and crossterm (Codex, and most Rust TUIs) reads that
/// as the Esc key when its read comes back short, then types the rest of the report as text.
#[cfg(all(test, target_vendor = "apple"))]
mod input_queue_tests;

/// A new terminal's post-fork descriptor cleanup costs what the process has
/// open, not its descriptor limit (new-terminal-100x): the daemon and host
/// raise the soft limit to 65,536, and one `fcntl` per possible descriptor
/// took about 14 ms of every terminal's launch on a fleet M4 Pro.
#[cfg(all(test, target_vendor = "apple"))]
mod descriptor_cleanup_tests;
