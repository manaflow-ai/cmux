//! The machine this process runs on: platform, install mode, the layout
//! from the environment, the clock and the random source. Everything the
//! pure core takes as input is read here, once.

use std::time::{SystemTime, UNIX_EPOCH};

use cmux_server_core::layout::{self, Layout, LayoutEnv, LayoutError};
use cmux_server_core::{InstallMode, Platform};

use crate::error::{Error, Result};
use crate::sys;

/// This build's release target, as in server.md 4.2 step 2 (`<arch>-<os>`).
/// The channel serves one manifest per target, so a host never stages a
/// package built for another OS or architecture.
pub const TARGET: &str = target();

const fn target() -> &'static str {
    if cfg!(all(target_arch = "x86_64", target_os = "linux")) {
        "x86_64-linux"
    } else if cfg!(all(target_arch = "aarch64", target_os = "linux")) {
        "aarch64-linux"
    } else if cfg!(all(target_arch = "aarch64", target_os = "macos")) {
        "aarch64-darwin"
    } else if cfg!(all(target_arch = "x86_64", target_os = "macos")) {
        "x86_64-darwin"
    } else if cfg!(all(target_arch = "x86_64", windows)) {
        "x86_64-windows"
    } else if cfg!(all(target_arch = "aarch64", windows)) {
        "aarch64-windows"
    } else {
        "unsupported"
    }
}

/// The platform this binary was built for.
pub fn platform() -> Platform {
    if cfg!(target_os = "macos") {
        Platform::MacOs
    } else if cfg!(windows) {
        Platform::Windows
    } else {
        Platform::Linux
    }
}

fn var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// [`LayoutEnv`] from this process's environment.
pub fn layout_env() -> LayoutEnv {
    let home = if cfg!(windows) { var("USERPROFILE") } else { var("HOME") };
    LayoutEnv {
        home,
        xdg_data_home: var("XDG_DATA_HOME"),
        xdg_state_home: var("XDG_STATE_HOME"),
        xdg_config_home: var("XDG_CONFIG_HOME"),
        local_app_data: var("LOCALAPPDATA"),
        app_data: var("APPDATA"),
        program_data: var("ProgramData"),
        program_files: var("ProgramFiles"),
        mac_app_bundle: var("CMUX_SERVER_APP_BUNDLE"),
        uid: cfg!(unix).then(sys::uid),
    }
}

/// The install mode: `--system` on install, else `CMUX_SERVER_MODE` (the
/// units set it), else system when running as root, else user.
pub fn resolve_mode(system_flag: bool) -> InstallMode {
    if system_flag {
        return InstallMode::System;
    }
    match var("CMUX_SERVER_MODE").as_deref() {
        Some("system") => InstallMode::System,
        Some("user") => InstallMode::User,
        _ if sys::is_root() => InstallMode::System,
        _ => InstallMode::User,
    }
}

/// The layout for `mode` on this machine.
pub fn layout_for(mode: InstallMode, env: &LayoutEnv) -> Result<Layout> {
    layout::layout(mode, platform(), env).map_err(|e| match e {
        LayoutError::Missing(name) => Error::usage(format!("{name} is not set")),
        LayoutError::NotAbsolute(name) => Error::usage(format!("{name} is not an absolute path")),
        LayoutError::AppBundleNotApplicable => {
            Error::usage("CMUX_SERVER_APP_BUNDLE applies to macOS user mode only")
        }
    })
}

pub fn mode_str(mode: InstallMode) -> &'static str {
    match mode {
        InstallMode::User => "user",
        InstallMode::System => "system",
    }
}

/// Wall clock in Unix milliseconds.
pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// `N` bytes from the OS random source.
pub fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|e| Error::internal(format!("random source: {e}")))?;
    Ok(bytes)
}

/// Lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Parses 64 lowercase hex characters into 32 bytes.
pub fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let text = std::str::from_utf8(chunk).ok()?;
        out[i] = u8::from_str_radix(text, 16).ok()?;
    }
    Some(out)
}

/// The installing user's name (`$USER` is not trusted for this).
pub fn current_user() -> Result<String> {
    sys::user_name(sys::uid()).map_err(|e| Error::internal(format!("user name: {e}")))
}
