//! Whether the host's Chromium child processes run in the macOS sandbox.
//!
//! The host renders pages it does not control (a phone's browser tab, a remote
//! tab), so its renderer and GPU processes must run sandboxed, as Chrome's do.
//! `--smoke` checks that on a real Mac: it lists the host's child processes,
//! asks the kernel for each one whether it is sandboxed and whether it may
//! read a file outside the profile, and fails when a renderer or the GPU
//! process is not sandboxed or may read that file. The verdict is pure (this
//! module); the probe of the processes is macOS only ([`probe`]).

use std::fmt::Write as _;

/// One child process of the host: its Chromium process type (`--type=`) and
/// what the kernel said about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Child {
    /// The `--type=` value (`renderer`, `gpu-process`, `utility`, ...); empty
    /// for a child without one.
    pub kind: String,
    /// `--utility-sub-type=` for a utility process (empty otherwise).
    pub sub_kind: String,
    /// The kernel's answer: sandboxed or not; `None` when it gave none.
    pub sandboxed: Option<bool>,
    /// Whether the kernel denies the process a read of a file outside the
    /// profile; `None` when it gave no answer.
    pub outside_read_denied: Option<bool>,
}

/// The process types that must run sandboxed: they parse and run page content
/// (renderer) or talk to the GPU driver for it (gpu-process).
pub const MUST_BE_SANDBOXED: [&str; 2] = ["renderer", "gpu-process"];

/// The Chromium process type of a command line: the value of its first
/// `--type=` argument, and its `--utility-sub-type=`.
#[must_use]
pub fn kinds_of(command: &str) -> (String, String) {
    let value = |flag: &str| {
        command
            .split_whitespace()
            .find_map(|word| word.strip_prefix(flag))
            .unwrap_or_default()
            .to_string()
    };
    (value("--type="), value("--utility-sub-type="))
}

/// The verdict on the host's children: `Ok` when there is at least one
/// renderer and every renderer and GPU process is sandboxed and may not read
/// a file outside the profile; else the first failure, in words.
pub fn verdict(children: &[Child]) -> Result<(), String> {
    if !children.iter().any(|c| c.kind == "renderer") {
        return Err("sandbox: the host has no renderer process to check".to_string());
    }
    for child in children.iter().filter(|c| MUST_BE_SANDBOXED.contains(&c.kind.as_str())) {
        match child.sandboxed {
            Some(true) => {}
            Some(false) => {
                return Err(format!("sandbox: a {} process is not sandboxed", child.kind));
            }
            None => {
                return Err(format!("sandbox: no sandbox status for a {} process", child.kind));
            }
        }
        match child.outside_read_denied {
            Some(true) => {}
            Some(false) => {
                return Err(format!(
                    "sandbox: a {} process may read a file outside its profile",
                    child.kind
                ));
            }
            None => {
                return Err(format!("sandbox: no file read answer for a {} process", child.kind));
            }
        }
    }
    Ok(())
}

/// The children as a JSON array (for `result.json`).
#[must_use]
pub fn json(children: &[Child]) -> String {
    let flag = |v: Option<bool>| v.map_or("null", |v| if v { "true" } else { "false" });
    let mut out = String::from("[");
    for (i, c) in children.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let _ = write!(
            out,
            "{{\"type\":{:?},\"sub_type\":{:?},\"sandboxed\":{},\"outside_read_denied\":{}}}",
            c.kind,
            c.sub_kind,
            flag(c.sandboxed),
            flag(c.outside_read_denied)
        );
    }
    out.push(']');
    out
}

/// The kernel's sandbox answers for the host's child processes (macOS).
#[cfg(target_os = "macos")]
pub mod probe {
    use std::ffi::{CString, c_char, c_int};
    use std::path::Path;

    use super::{Child, kinds_of};

    unsafe extern "C" {
        // libsystem_sandbox (part of libSystem). With no operation it answers
        // whether `pid` is sandboxed (Chromium's Seatbelt::IsSandboxed does
        // the same); with an operation and a filter it answers whether the
        // sandbox denies that operation: 0 allowed, 1 denied, -1 error.
        fn sandbox_check(pid: c_int, operation: *const c_char, filter: c_int, ...) -> c_int;
        static SANDBOX_CHECK_NO_REPORT: c_int;
    }
    const SANDBOX_FILTER_NONE: c_int = 0;
    const SANDBOX_FILTER_PATH: c_int = 1;

    fn answer(code: c_int) -> Option<bool> {
        match code {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }

    /// The kernel's answers for each `(pid, command line)` of the host's
    /// child processes (the smoke lists them); `outside` is a file outside
    /// the profile the check asks about.
    #[must_use]
    pub fn children(processes: &[(u32, String)], outside: &Path) -> Vec<Child> {
        let path = CString::new(outside.to_string_lossy().as_bytes()).unwrap_or_default();
        let read = CString::new("file-read-data").unwrap_or_default();
        processes
            .iter()
            .map(|(pid, command)| {
                let (kind, sub_kind) = kinds_of(command);
                let pid = c_int::try_from(*pid).unwrap_or(-1);
                // SAFETY: plain values and NUL-terminated strings that outlive
                // the calls; SANDBOX_CHECK_NO_REPORT is libSystem's constant.
                let (sandboxed, denied) = unsafe {
                    let no_report = SANDBOX_CHECK_NO_REPORT;
                    (
                        sandbox_check(pid, std::ptr::null(), SANDBOX_FILTER_NONE),
                        sandbox_check(
                            pid,
                            read.as_ptr(),
                            SANDBOX_FILTER_PATH | no_report,
                            path.as_ptr(),
                        ),
                    )
                };
                Child {
                    kind,
                    sub_kind,
                    sandboxed: answer(sandboxed),
                    outside_read_denied: answer(denied),
                }
            })
            .collect()
    }
}
