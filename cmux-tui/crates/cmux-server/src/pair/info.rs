//! The facts a pairing shows the approver: host name, OS, version,
//! architecture and the running cmux version (backend `PairingInfo`).

use super::api::HostInfo;

const MAX_TEXT: usize = 80;

/// At most 80 printable characters (the backend's limit).
pub fn clean(text: &str, fallback: &str) -> String {
    let out: String = text.trim().chars().filter(|c| !c.is_control()).take(MAX_TEXT).collect();
    if out.is_empty() { fallback.to_owned() } else { out }
}

pub fn platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    }
}

pub fn arch_name() -> &'static str {
    if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" }
}

#[cfg(unix)]
fn host_name() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates
    // or truncates within it.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return None;
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = String::from_utf8_lossy(&buf[..end]).into_owned();
    // `studio.local` -> `studio`.
    Some(name.strip_suffix(".local").map(str::to_owned).unwrap_or(name))
}

#[cfg(not(unix))]
fn host_name() -> Option<String> {
    std::env::var("COMPUTERNAME").ok()
}

/// `PRETTY_NAME` from os-release, or the macOS product version.
fn os_version() -> Option<String> {
    if cfg!(target_os = "macos") {
        let plist =
            std::fs::read_to_string("/System/Library/CoreServices/SystemVersion.plist").ok()?;
        let after = plist.split("<key>ProductVersion</key>").nth(1)?;
        let value = after.split("<string>").nth(1)?.split("</string>").next()?;
        return Some(format!("macOS {value}"));
    }
    let text = std::fs::read_to_string("/etc/os-release").ok()?;
    text.lines()
        .find_map(|line| line.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_owned()))
}

/// This machine's facts.
pub fn host_info(cmux_version: &str) -> HostInfo {
    HostInfo {
        name: clean(&host_name().unwrap_or_default(), "cmux server"),
        platform: platform_name().to_owned(),
        os_version: clean(&os_version().unwrap_or_default(), "unknown"),
        arch: arch_name().to_owned(),
        cmux_version: clean(cmux_version, "unknown").chars().take(40).collect(),
    }
}
