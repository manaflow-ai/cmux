//! [`LinkSpawner`]: starts link processes. Swappable on purpose: the target
//! transport is `cmux link` (lane 12), which replaces the `cmux-tui remote
//! connect` process with a carrier from the link service. Only this seam
//! changes then.
//!
//! The spawner reports stdout lines and the exit through one channel that
//! the supervisor owns. Events are the only signal: no timer, no polling.

use super::argv::LinkCommand;
use std::io::{BufRead as _, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

/// One link process: the machine and the supervisor's generation for it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LinkTag {
    pub machine: String,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkProcessEvent {
    /// One stdout line (without the newline).
    Line { tag: LinkTag, line: String },
    /// The process ended (`None`: killed by a signal).
    Exited { tag: LinkTag, code: Option<i32> },
}

/// A running link process.
pub trait LinkProcess: Send {
    fn pid(&self) -> Option<u32>;
    /// Ends the process. Its `Exited` event still arrives.
    fn terminate(&mut self);
}

pub trait LinkSpawner: Send {
    fn spawn(
        &mut self,
        tag: LinkTag,
        command: &LinkCommand,
        events: Sender<LinkProcessEvent>,
    ) -> std::io::Result<Box<dyn LinkProcess>>;
}

/// The real spawner: one child process and one reader thread per link.
pub struct ProcessSpawner;

/// Variables the child keeps from this process; everything else is cleared.
const KEPT_ENV: &[&str] = &["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"];

fn private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path)
}

impl LinkSpawner for ProcessSpawner {
    fn spawn(
        &mut self,
        tag: LinkTag,
        command: &LinkCommand,
        events: Sender<LinkProcessEvent>,
    ) -> std::io::Result<Box<dyn LinkProcess>> {
        private_dir(&command.state_dir)?;
        if let Some(dir) = command.local_socket.parent() {
            private_dir(dir)?;
        }
        // A socket left by a dead link would make the new one fail to bind.
        match std::fs::remove_file(&command.local_socket) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let mut process = Command::new(&command.binary);
        process.args(&command.args).env_clear();
        for key in KEPT_ENV {
            if let Some(value) = std::env::var_os(key) {
                process.env(key, value);
            }
        }
        process.envs(command.env.iter().map(|(k, v)| (k, v)));
        // The link's stderr goes to the server's stderr (the host's log); it
        // carries no credential because none is given to the link.
        let mut child = process.stdin(Stdio::null()).stdout(Stdio::piped()).spawn()?;
        let stdout = child.stdout.take().expect("piped stdout");
        let pid = child.id();
        let child = Arc::new(Mutex::new(Some(child)));
        let reaper = Arc::clone(&child);
        std::thread::Builder::new().name(format!("cmux-link-{}", tag.machine)).spawn(
            move || {
                let mut reader = BufReader::new(stdout);
                let mut buffer = Vec::new();
                loop {
                    buffer.clear();
                    match reader.read_until(b'\n', &mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let line = String::from_utf8_lossy(&buffer).trim_end().to_owned();
                    // A dropped receiver means the server is gone; keep draining
                    // so the link never blocks on a full pipe.
                    let _ = events.send(LinkProcessEvent::Line { tag: tag.clone(), line });
                }
                // stdout closed: the process is ending. Take it out of the shared
                // slot before the wait, so `terminate` never blocks on the lock.
                let taken = reaper.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
                let code = taken.and_then(|mut c| c.wait().ok()).and_then(|status| status.code());
                let _ = events.send(LinkProcessEvent::Exited { tag, code });
            },
        )?;
        Ok(Box::new(ChildLink { child, pid }))
    }
}

struct ChildLink {
    child: Arc<Mutex<Option<Child>>>,
    pid: u32,
}

impl LinkProcess for ChildLink {
    fn pid(&self) -> Option<u32> {
        Some(self.pid)
    }

    fn terminate(&mut self) {
        // After stdout closed the reader thread owns the child and reaps it;
        // `--exit-with-parent` ends a link that outlives the server.
        if let Some(child) =
            self.child.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_mut()
        {
            let _ = child.kill();
        }
    }
}

impl Drop for ChildLink {
    fn drop(&mut self) {
        self.terminate();
    }
}
