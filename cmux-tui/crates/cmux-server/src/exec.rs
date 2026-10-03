//! Replacing this process with another binary (decision SV-R2: the one
//! re-exec into a newer staged `cmux`). Behind a trait so tests record the
//! exec instead of doing it. [`cmux_server_core::reexec`] decides whether
//! to exec; `cli` checks the staged binary before it calls [`Exec::exec`].

use std::path::PathBuf;
use std::sync::Mutex;

use crate::error::Error;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecRequest {
    pub program: PathBuf,
    /// Arguments after the program name.
    pub args: Vec<String>,
    /// Added to the inherited environment.
    pub env: Vec<(String, String)>,
}

/// Replaces the process. Returns only when the exec did not happen.
pub trait Exec: Send + Sync {
    fn exec(&self, request: &ExecRequest) -> Error;
}

/// `execve(2)` on Unix. Rust opens every file with `O_CLOEXEC`, so the
/// store lock and downloads do not leak into the new image.
pub struct SystemExec;

impl Exec for SystemExec {
    fn exec(&self, request: &ExecRequest) -> Error {
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::process::CommandExt;
            let _ = std::io::stdout().flush();
            let mut cmd = std::process::Command::new(&request.program);
            cmd.args(&request.args);
            for (key, value) in &request.env {
                cmd.env(key, value);
            }
            let e = cmd.exec();
            Error::internal(format!("cannot exec {}: {e}", request.program.display()))
        }
        #[cfg(not(unix))]
        {
            Error::internal(format!(
                "cannot exec {}: re-exec needs a Unix platform",
                request.program.display()
            ))
        }
    }
}

/// Records every request and returns an internal error (tests).
#[derive(Default)]
pub struct RecordingExec {
    requests: Mutex<Vec<ExecRequest>>,
}

impl RecordingExec {
    pub fn requests(&self) -> Vec<ExecRequest> {
        self.requests.lock().expect("exec log").clone()
    }
}

impl Exec for RecordingExec {
    fn exec(&self, request: &ExecRequest) -> Error {
        self.requests.lock().expect("exec log").push(request.clone());
        Error::internal(format!("exec of {} recorded", request.program.display()))
    }
}
