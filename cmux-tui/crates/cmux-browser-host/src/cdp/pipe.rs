//! Headless Chromium over `--remote-debugging-pipe`.
//!
//! No TCP port is opened (spec: no unauthenticated debugging endpoint).
//! Chromium reads CDP messages from fd 3 and writes them to fd 4, each one
//! terminated by a NUL byte.

use super::connection::{CdpConnection, CdpWire};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

static PROFILE_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub struct HeadlessOptions {
    /// Chrome, Chromium, Chrome for Testing or chrome-headless-shell.
    pub binary: PathBuf,
    /// Profile directory; `None` makes a throwaway one that is removed on drop.
    pub user_data_dir: Option<PathBuf>,
    /// Extra switches, appended after the defaults.
    pub extra_args: Vec<String>,
}

/// A running headless Chromium and its CDP connection.
pub struct HeadlessChromium {
    child: Mutex<Option<Child>>,
    connection: Arc<CdpConnection>,
    profile_dir: PathBuf,
    profile_ephemeral: bool,
}

struct PipeWire(Mutex<File>);

impl CdpWire for PipeWire {
    fn send(&self, message: &str) -> io::Result<()> {
        let mut file = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        file.write_all(message.as_bytes())?;
        file.write_all(&[0])?;
        file.flush()
    }
}

impl HeadlessChromium {
    pub fn launch(options: &HeadlessOptions) -> io::Result<Self> {
        let (profile_dir, profile_ephemeral) = match &options.user_data_dir {
            Some(dir) => (dir.clone(), false),
            None => (ephemeral_profile_dir(), true),
        };
        std::fs::create_dir_all(&profile_dir)?;

        // to_browser: host writes, Chromium reads (its fd 3).
        // from_browser: Chromium writes (its fd 4), host reads.
        let (to_browser_read, to_browser_write) = pipe()?;
        let (from_browser_read, from_browser_write) = pipe()?;
        let child_read = to_browser_read.as_raw_fd();
        let child_write = from_browser_write.as_raw_fd();

        let mut command = Command::new(&options.binary);
        command.args(default_args(&profile_dir)).args(&options.extra_args);
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        // SAFETY: the closure runs in the forked child before exec and only
        // calls async-signal-safe functions (fcntl, dup2) on fds it owns.
        unsafe {
            command.pre_exec(move || install_pipe_fds(child_read, child_write));
        }
        let spawned = command.spawn();
        drop(to_browser_read);
        drop(from_browser_write);
        let child = match spawned {
            Ok(child) => child,
            Err(error) => {
                if profile_ephemeral {
                    let _ = std::fs::remove_dir_all(&profile_dir);
                }
                return Err(io::Error::new(
                    error.kind(),
                    format!("failed to launch Chromium at {}: {error}", options.binary.display()),
                ));
            }
        };

        let connection =
            CdpConnection::new(Box::new(PipeWire(Mutex::new(File::from(to_browser_write)))));
        let reader_connection = connection.clone();
        let reader = File::from(from_browser_read);
        let reader_thread = std::thread::Builder::new()
            .name("cmux-browser-host-cdp-pipe".into())
            .spawn(move || {
                let mut reader = BufReader::new(reader);
                let mut buffer = Vec::new();
                loop {
                    buffer.clear();
                    match reader.read_until(0, &mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {
                            if buffer.last() == Some(&0) {
                                buffer.pop();
                            }
                            if let Ok(text) = std::str::from_utf8(&buffer) {
                                reader_connection.receive(text);
                            }
                        }
                    }
                }
                reader_connection.close("Chromium closed its CDP pipe");
            });
        let mut child = child;
        if let Err(error) = reader_thread {
            let _ = child.kill();
            let _ = child.wait();
            if profile_ephemeral {
                let _ = std::fs::remove_dir_all(&profile_dir);
            }
            return Err(error);
        }

        Ok(HeadlessChromium {
            child: Mutex::new(Some(child)),
            connection,
            profile_dir,
            profile_ephemeral,
        })
    }

    pub fn connection(&self) -> &Arc<CdpConnection> {
        &self.connection
    }

    /// Process id of the browser process, while it runs.
    pub fn pid(&self) -> Option<u32> {
        self.child.lock().unwrap_or_else(PoisonError::into_inner).as_ref().map(Child::id)
    }

    /// Stops the browser and waits for it.
    pub fn kill(&self) {
        if let Some(mut child) = self.child.lock().unwrap_or_else(PoisonError::into_inner).take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.connection.close("Chromium was stopped");
    }
}

impl Drop for HeadlessChromium {
    fn drop(&mut self) {
        self.kill();
        if self.profile_ephemeral {
            let _ = std::fs::remove_dir_all(&self.profile_dir);
        }
    }
}

fn default_args(profile_dir: &std::path::Path) -> Vec<String> {
    vec![
        "--headless".into(),
        "--remote-debugging-pipe".into(),
        format!("--user-data-dir={}", profile_dir.display()),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--disable-background-networking".into(),
        "--disable-component-update".into(),
        "--disable-sync".into(),
        "--disable-background-timer-throttling".into(),
        "--disable-renderer-backgrounding".into(),
        "--disable-backgrounding-occluded-windows".into(),
        "--metrics-recording-only".into(),
        "--password-store=basic".into(),
        "--use-mock-keychain".into(),
        "--hide-scrollbars".into(),
        "--mute-audio".into(),
        "about:blank".into(),
    ]
}

fn ephemeral_profile_dir() -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let seq = PROFILE_SEQ.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("cmux-browser-host-{}-{nanos}-{seq}", std::process::id()))
}

/// A pipe whose ends are close-on-exec in this process.
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds: [RawFd; 2] = [-1, -1];
    // SAFETY: `fds` is a valid two-element array for pipe(2) to fill.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe(2) succeeded, so both fds are open and owned by us.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    for fd in [read.as_raw_fd(), write.as_raw_fd()] {
        // SAFETY: fd is open; F_SETFD with FD_CLOEXEC has no memory effects.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok((read, write))
}

/// Child side: move the pipe ends to fds 3 and 4. Both are first copied above
/// fd 10 so that neither dup2 can overwrite the other's source.
fn install_pipe_fds(read: RawFd, write: RawFd) -> io::Result<()> {
    // SAFETY: async-signal-safe calls on fds inherited from the parent.
    unsafe {
        let high_read = libc::fcntl(read, libc::F_DUPFD, 10);
        let high_write = libc::fcntl(write, libc::F_DUPFD, 10);
        if high_read < 0 || high_write < 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::dup2(high_read, 3) < 0 || libc::dup2(high_write, 4) < 0 {
            return Err(io::Error::last_os_error());
        }
        libc::close(high_read);
        libc::close(high_write);
    }
    Ok(())
}
