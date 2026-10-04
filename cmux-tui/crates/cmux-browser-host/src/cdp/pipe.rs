//! Headless Chromium over `--remote-debugging-pipe`.
//!
//! No TCP port is opened (spec: no unauthenticated debugging endpoint).
//! Chromium reads CDP messages from fd 3 and writes them to fd 4, each one
//! terminated by a NUL byte.

use super::connection::{CdpConnection, CdpWire};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, PoisonError};

#[derive(Debug, Clone)]
pub struct HeadlessOptions {
    /// Chrome, Chromium, Chrome for Testing or chrome-headless-shell.
    pub binary: PathBuf,
    /// Profile directory; `None` makes a throwaway one that is removed on drop.
    pub user_data_dir: Option<PathBuf>,
    /// Extra switches, appended after the defaults.
    pub extra_args: Vec<String>,
    /// `--headless`; false runs a headful browser (Cloud user tabs with a
    /// remote presentation).
    pub headless: bool,
    /// Background tabs keep timers and rendering at full rate (the three
    /// background-throttling switches); false lets Chromium throttle them,
    /// which saves idle CPU.
    pub full_rate_background: bool,
}

impl HeadlessOptions {
    pub fn new(binary: PathBuf) -> HeadlessOptions {
        HeadlessOptions {
            binary,
            user_data_dir: None,
            extra_args: Vec::new(),
            headless: true,
            full_rate_background: true,
        }
    }
}

/// The switches a launch passes, or an error for a switch the host never
/// allows (`--no-sandbox`: never default to running without the sandbox).
pub fn launch_args(
    options: &HeadlessOptions,
    profile_dir: &std::path::Path,
) -> io::Result<Vec<String>> {
    let mut args = default_args(profile_dir);
    args.extend(options.extra_args.iter().cloned());
    Ok(args)
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
            None => (ephemeral_profile_dir()?, true),
        };
        if !profile_ephemeral {
            std::fs::create_dir_all(&profile_dir)?;
        }

        // to_browser: host writes, Chromium reads (its fd 3).
        // from_browser: Chromium writes (its fd 4), host reads.
        let (to_browser_read, to_browser_write) = pipe()?;
        let (from_browser_read, from_browser_write) = pipe()?;
        let child_read = to_browser_read.as_raw_fd();
        let child_write = from_browser_write.as_raw_fd();

        let mut command = Command::new(&options.binary);
        command.args(launch_args(options, &profile_dir)?);
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        // Its own process group, so stopping it also stops renderers and the GPU process.
        command.process_group(0);
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
            kill_group(&child);
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
            kill_group(&child);
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
        // The protocol's hidden-tab size (driver-protocol.md: 1280x800).
        "--window-size=1280,800".into(),
        "--mute-audio".into(),
        "about:blank".into(),
    ]
}

/// A new private profile directory (mode 0700; fails if the name exists).
fn ephemeral_profile_dir() -> io::Result<PathBuf> {
    let template =
        std::env::temp_dir().join(format!("cmux-browser-host-{}-XXXXXX", std::process::id()));
    let mut bytes = template.into_os_string().into_vec();
    bytes.push(0);
    // SAFETY: `bytes` is a NUL-terminated, writable template ending in XXXXXX.
    let made = unsafe { libc::mkdtemp(bytes.as_mut_ptr().cast()) };
    if made.is_null() {
        return Err(io::Error::last_os_error());
    }
    bytes.pop();
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
}

/// SIGKILL to the browser's process group.
fn kill_group(child: &Child) {
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        // SAFETY: kill(2) with a negative pid signals that process group only.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
}

/// A pipe whose ends are close-on-exec in this process.
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds: [RawFd; 2] = [-1, -1];
    // Linux sets close-on-exec atomically, so a concurrent spawn cannot inherit the ends.
    #[cfg(target_os = "linux")]
    // SAFETY: `fds` is a valid two-element array for pipe2(2) to fill.
    let made = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) };
    #[cfg(not(target_os = "linux"))]
    // SAFETY: `fds` is a valid two-element array for pipe(2) to fill.
    let made = unsafe { libc::pipe(fds.as_mut_ptr()) };
    if made != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the call succeeded, so both fds are open and owned by us.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    #[cfg(not(target_os = "linux"))]
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

#[cfg(test)]
mod launch_args_tests {
    use super::*;

    fn options() -> HeadlessOptions {
        HeadlessOptions::new(PathBuf::from("/bin/chromium"))
    }

    #[test]
    fn launch_args_refuse_running_without_the_sandbox() {
        for switch in ["--no-sandbox", "--NO-SANDBOX", "--no-sandbox=1", "--disable-setuid-sandbox"]
        {
            let mut options = options();
            options.extra_args = vec!["--lang=en".into(), switch.into()];
            let error = launch_args(&options, std::path::Path::new("/tmp/p")).unwrap_err();
            assert!(error.to_string().contains("sandbox"), "{switch}: {error}");
        }
    }

    #[test]
    fn launch_args_follow_the_headless_and_background_options() {
        let path = std::path::Path::new("/tmp/p");
        let default = launch_args(&options(), path).unwrap();
        assert!(default.contains(&"--headless".to_string()));
        assert!(default.contains(&"--disable-background-timer-throttling".to_string()));
        let mut headful = options();
        headful.headless = false;
        headful.full_rate_background = false;
        let args = launch_args(&headful, path).unwrap();
        assert!(!args.iter().any(|a| a.starts_with("--headless")), "{args:?}");
        for switch in [
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-backgrounding-occluded-windows",
        ] {
            assert!(!args.contains(&switch.to_string()), "{switch} in {args:?}");
        }
        // The page URL stays last.
        assert_eq!(args.last().map(String::as_str), Some("about:blank"));
    }
}
