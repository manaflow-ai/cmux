use std::cell::Cell;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;

use anyhow::{Context, bail};
use cmux_process::Command;
use portable_pty::ChildKiller;

use super::{Child, MasterPty, PtyCommand, PtyOpenError, PtySize};

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    fn ptsname_r(
        descriptor: libc::c_int,
        buffer: *mut libc::c_char,
        length: libc::size_t,
    ) -> libc::c_int;
}

/// The slave of a PTY [`open`] allocated: its path, which the child opens as
/// its controlling terminal, and its descriptor, held until the spawn
/// returned so the PTY never has no slave open.
pub(crate) struct Slave {
    #[allow(dead_code, reason = "held open; only the macOS input-queue test reads it")]
    file: File,
    path: PathBuf,
}

pub(crate) fn open(size: PtySize) -> anyhow::Result<(Box<dyn MasterPty + Send>, Slave)> {
    let master = open_pty_master()?;
    retry_pty_control(master.as_raw_fd(), libc::grantpt).context("failed to grant PTY slave")?;
    retry_pty_control(master.as_raw_fd(), libc::unlockpt).context("failed to unlock PTY slave")?;
    let slave_name = pty_slave_name(master.as_raw_fd())?;
    let slave = open_pty_slave(&slave_name)?;
    set_window_size(&slave, size)?;

    let master = MacOsMasterPty { file: master, took_writer: Cell::new(false), eof_on_drop: true };
    let path = PathBuf::from(OsStr::from_bytes(slave_name.to_bytes()));
    Ok((Box::new(master), Slave { file: slave, path }))
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
    if let Some(directory) = command.cwd_descriptor.as_deref() {
        process
            .current_dir_fd(directory.as_fd())
            .context("failed to keep the PTY working directory for the child")?;
    } else if let Some(cwd) = command.cwd.as_deref() {
        process.current_dir(cwd);
    }
    if command.clean_environment {
        process.env_clear();
    }
    process.envs(&command.environment);
    process.env("SHELL", shell);
    // The child leads a new session and opens the slave by path as its 0 (1
    // and 2 are copies), which becomes its controlling terminal (TIOCSCTTY),
    // so Ctrl-C's 0x03 reaches its foreground group as SIGINT. On macOS
    // cmux_process forks for this: posix_spawn opens the path before its
    // setsid, which leaves the session without a controlling terminal. The
    // child gets only 0-2 and default signals with an empty mask (`isolate`).
    process.new_session().open_stdin_path(&slave.path).isolate();
    // The original open-file limit cmux started with, not the daemon's
    // raised one (as Ghostty gives its own children).
    if let Some(soft) = crate::open_files::original_open_file_limit() {
        process.open_file_limit(soft);
    }
    // The child starts at Default whatever the class of the echo
    // or request thread that spawns it (tests: a_pty_child_of_a_user_
    // interactive_thread_runs_at_default).
    let child = process.spawn().context("failed to spawn PTY command")?;
    Ok(Box::new(NativePtyChild(child)))
}

/// A PTY's child on Unix: the session leader [`spawn`] started. A caller
/// that needs the numeric signal of its end downcasts the
/// `portable_pty::Child` to this type (portable-pty's status keeps only the
/// signal's name).
#[derive(Debug)]
pub struct NativePtyChild(cmux_process::Child);

impl NativePtyChild {
    /// [`Child::wait`] with the full status.
    pub fn wait_native(&mut self) -> io::Result<std::process::ExitStatus> {
        self.0.wait()
    }

    /// [`Child::try_wait`] with the full status.
    pub fn try_wait_native(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
        self.0.try_wait()
    }
}

/// How long a child that got SIGHUP from [`NativePtyChild::kill`] has before
/// SIGKILL (portable-pty's grace for its own children).
const HANGUP_GRACE: std::time::Duration = std::time::Duration::from_millis(250);

impl Child for NativePtyChild {
    fn try_wait(&mut self) -> io::Result<Option<portable_pty::ExitStatus>> {
        Ok(self.0.try_wait()?.map(Into::into))
    }

    fn wait(&mut self) -> io::Result<portable_pty::ExitStatus> {
        Ok(self.0.wait()?.into())
    }

    fn process_id(&self) -> Option<u32> {
        Some(self.0.id())
    }
}

impl ChildKiller for NativePtyChild {
    /// SIGHUP (a terminal's hangup), then SIGKILL if the child has not
    /// ended within [`HANGUP_GRACE`] (an exit event, not a poll).
    fn kill(&mut self) -> io::Result<()> {
        if self.0.try_wait()?.is_some() {
            return Ok(());
        }
        PtySignaller { pid: self.0.id() }.kill()?;
        // A failed wait is no proof the child ended: SIGKILL it too.
        // wakeup-allow: deadline the one hangup grace after SIGHUP; the child's exit ends the wait first
        match self.0.wait_timeout(HANGUP_GRACE) {
            Ok(Some(_)) => Ok(()),
            Ok(None) | Err(_) => self.0.kill(),
        }
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(PtySignaller { pid: self.0.id() })
    }
}

/// Sends SIGHUP to a PTY child from another thread than the one that waits
/// for it (portable-pty's `ProcessSignaller`).
#[derive(Debug)]
struct PtySignaller {
    pid: u32,
}

impl ChildKiller for PtySignaller {
    fn kill(&mut self) -> io::Result<()> {
        let pid = libc::pid_t::try_from(self.pid)
            .map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
        // SAFETY: kill(2) takes no pointers.
        if unsafe { libc::kill(pid, libc::SIGHUP) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(PtySignaller { pid: self.pid })
    }
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

/// #22265: a mouse wheel over Codex typed `[<65;30;7M` into its composer. A macOS PTY holds at most
/// 1,022 bytes of input; when the program reads slower than the wheel reports come, the kernel takes
/// a write byte by byte until the queue is full and blocks the rest. A report cut right after its
/// ESC leaves the queue ending in a lone ESC, and crossterm (Codex, and most Rust TUIs) reads that
/// as the Esc key when its read comes back short, then types the rest of the report as text.
#[cfg(all(test, target_vendor = "apple"))]
mod input_queue_tests {
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::time::Duration;

    use super::{PtySize, open};

    const WHEEL_UP: &[u8] = b"\x1b[<65;30;7M";

    fn raw(slave: &std::fs::File) {
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
        let mut termios = unsafe { termios.assume_init() };
        unsafe { libc::cfmakeraw(&mut termios) };
        assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
    }

    #[test]
    fn a_full_input_queue_never_ends_in_a_lone_escape() {
        let (master, slave) =
            open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut slave = slave.file;
        raw(&slave);
        let mut writer = master.take_writer().unwrap();
        // The program is busy: the queue holds 1,021 bytes, one short of full.
        writer.write_all(&[b'x'; 1021]).unwrap();
        let reports = std::thread::spawn(move || {
            writer.write_all(WHEEL_UP).unwrap();
            writer
        });
        // Let the writer reach the full queue (the old writer blocks there, after the ESC).
        std::thread::sleep(Duration::from_millis(200));

        // crossterm reads 1,024 bytes at a time; a short read that ends in ESC is the Esc key.
        let mut buffer = [0u8; 1024];
        let first = slave.read(&mut buffer).unwrap();
        assert!(
            buffer[first - 1] != 0x1b,
            "the program read {first} bytes ending in a lone ESC: the wheel report was cut after its ESC"
        );
        let _writer = reports.join().unwrap();
        let mut got = buffer[..first].to_vec();
        while got.len() < 1021 + WHEEL_UP.len() {
            let n = slave.read(&mut buffer).unwrap();
            got.extend_from_slice(&buffer[..n]);
        }
        assert_eq!(&got[1021..], WHEEL_UP, "the wheel report arrived changed");
    }
}
