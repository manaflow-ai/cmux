use std::cell::Cell;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, bail};
use portable_pty::{Child, MasterPty, PtySize};

pub(super) struct PtyPair {
    pub(super) slave: File,
    pub(super) master: Box<dyn MasterPty + Send>,
}

pub(super) fn open(size: PtySize) -> anyhow::Result<PtyPair> {
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

    Ok(PtyPair {
        slave,
        master: Box::new(MacOsMasterPty { file: master, took_writer: Cell::new(false) }),
    })
}

pub(super) fn spawn_command(
    slave: &File,
    argv: &[String],
    cwd: &Path,
    environment: &BTreeMap<String, String>,
    term: &str,
    clean_environment: bool,
) -> anyhow::Result<Box<dyn Child + Send + Sync>> {
    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]).current_dir(cwd);
    if clean_environment {
        command.env_clear();
    }
    command.envs(environment);
    command.env("SHELL", resolved_shell(environment, clean_environment));
    command.env("TERM", term);

    command
        .stdin(Stdio::from(slave.try_clone().context("failed to clone PTY slave for stdin")?))
        .stdout(Stdio::from(slave.try_clone().context("failed to clone PTY slave for stdout")?))
        .stderr(Stdio::from(slave.try_clone().context("failed to clone PTY slave for stderr")?));
    unsafe {
        command.pre_exec(|| {
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
            portable_pty::unix::close_random_fds();
            Ok(())
        });
    }

    let child = command.spawn().context("failed to spawn PTY command")?;
    Ok(Box::new(child))
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

fn resolved_shell(environment: &BTreeMap<String, String>, clean_environment: bool) -> OsString {
    let configured = environment
        .get("SHELL")
        .map(OsString::from)
        .or_else(|| (!clean_environment).then(|| std::env::var_os("SHELL")).flatten());
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
