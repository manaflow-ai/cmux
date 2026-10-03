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

/// `execve(2)` on Unix, called directly (not `execvp`, which runs a file
/// that fails with ENOEXEC through `/bin/sh` on glibc). The environment is
/// this process's, without any old `CMUX_SERVER_REEXEC`, plus
/// `request.env`. Rust opens every file with `O_CLOEXEC`, so the store
/// lock and downloads do not leak into the new image. ENOEXEC and EACCES
/// (a binary for another OS or architecture, no execute permission) are
/// exit 4 with the package path.
pub struct SystemExec;

impl Exec for SystemExec {
    fn exec(&self, request: &ExecRequest) -> Error {
        #[cfg(unix)]
        {
            let e = execve(request);
            match e.raw_os_error() {
                Some(libc::ENOEXEC | libc::EACCES) => Error::rejected(format!(
                    "the verified package binary {} cannot run on this machine: {e}",
                    request.program.display()
                )),
                _ => Error::internal(format!("cannot exec {}: {e}", request.program.display())),
            }
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

/// Returns only on failure.
#[cfg(unix)]
fn execve(request: &ExecRequest) -> std::io::Error {
    use std::ffi::{CString, OsStr};
    use std::io::Write;
    use std::os::unix::ffi::OsStrExt;
    let c = |bytes: &[u8]| CString::new(bytes).map_err(|e| std::io::Error::other(e.to_string()));
    let build = || -> std::io::Result<(CString, Vec<CString>, Vec<CString>)> {
        let program = c(request.program.as_os_str().as_bytes())?;
        let mut argv = vec![program.clone()];
        for arg in &request.args {
            argv.push(c(arg.as_bytes())?);
        }
        let replaced = |key: &OsStr| {
            key == OsStr::new(cmux_server_core::reexec::GUARD_ENV)
                || request.env.iter().any(|(k, _)| OsStr::new(k) == key)
        };
        let mut envp = Vec::new();
        for (key, value) in std::env::vars_os().filter(|(k, _)| !replaced(k)) {
            let mut pair = key.as_bytes().to_vec();
            pair.push(b'=');
            pair.extend_from_slice(value.as_bytes());
            envp.push(c(&pair)?);
        }
        for (key, value) in &request.env {
            envp.push(c(format!("{key}={value}").as_bytes())?);
        }
        Ok((program, argv, envp))
    };
    let (program, argv, envp) = match build() {
        Ok(parts) => parts,
        Err(e) => return e,
    };
    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let mut envp_ptrs: Vec<*const libc::c_char> = envp.iter().map(|a| a.as_ptr()).collect();
    envp_ptrs.push(std::ptr::null());
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    // SAFETY: every pointer comes from a CString that outlives the call, and
    // both arrays end with a null pointer.
    unsafe { libc::execve(program.as_ptr(), argv_ptrs.as_ptr(), envp_ptrs.as_ptr()) };
    std::io::Error::last_os_error()
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
