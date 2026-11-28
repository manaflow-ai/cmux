//! The OS sandbox the host applies to itself before it reads its first line.
//!
//! The host needs no file, network or process access after start: the
//! runtime is embedded, the app's script arrives over fd 3, and every effect
//! goes back to the supervisor as a message. So the sandbox denies all of it.
//! - Linux: `no_new_privs`, Landlock with every file system (and, from ABI 4,
//!   network) right handled and no rule granted, then a seccomp filter that
//!   refuses opening files, sockets, exec, fork/clone and kernel-surface
//!   syscalls with `EPERM` (and kills the process on a foreign architecture).
//! - macOS: `sandbox_init` with a deny-default profile.
//!
//! Anything else (Windows, other Unixes) refuses to apply, so the supervisor
//! never runs app code unsandboxed.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

use serde::Serialize;

/// What the sandbox applied.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Report {
    /// `seccomp`, `sandbox_init`.
    pub mechanism: &'static str,
    /// The Landlock ABI used, when the kernel has Landlock.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub landlock_abi: Option<u32>,
}

/// Applies the sandbox to the calling process. Irreversible.
pub fn apply() -> Result<Report, String> {
    #[cfg(target_os = "linux")]
    {
        linux::apply()
    }
    #[cfg(target_os = "macos")]
    {
        macos::apply()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Err("no OS sandbox for this platform".to_string())
    }
}

/// Self-test for the integration tests: applies the sandbox, then tries to
/// read `path`, open a TCP socket and spawn a process. Prints one JSON line.
pub fn self_test(path: &str) -> i32 {
    let report = match apply() {
        Ok(report) => report,
        Err(error) => {
            println!("{}", serde_json::json!({ "applied": false, "error": error }));
            return 1;
        }
    };
    let read = std::fs::read(path).is_ok();
    let socket = std::net::TcpListener::bind("127.0.0.1:0").is_ok()
        || std::net::TcpStream::connect_timeout(
            &([127, 0, 0, 1], 9).into(),
            std::time::Duration::from_millis(200),
        )
        .is_ok();
    let exec = std::process::Command::new("/bin/sh").arg("-c").arg("exit 0").status().is_ok();
    println!(
        "{}",
        serde_json::json!({ "applied": true, "report": report, "read": read, "socket": socket, "exec": exec })
    );
    0
}
