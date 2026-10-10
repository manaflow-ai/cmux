//! System appearance (light or dark) detection for conditional Ghostty themes: macOS appearance, desktop portals, GNOME, KDE and GTK settings.

use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum GhosttyThemeMode {
    Light,
    Dark,
}

impl GhosttyThemeMode {
    fn parse(value: &std::ffi::OsStr) -> Option<Self> {
        let value = value.to_string_lossy();
        match value.trim_matches('"').to_ascii_lowercase().as_str() {
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

pub(super) fn system_ghostty_theme_mode(deadline_at: Option<Instant>) -> GhosttyThemeMode {
    system_ghostty_theme_mode_with_platform(|| platform_appearance_theme_mode(deadline_at))
}

pub(super) fn system_ghostty_theme_mode_with_platform(
    mut platform_appearance: impl FnMut() -> Option<GhosttyThemeMode>,
) -> GhosttyThemeMode {
    if let Some(mode) =
        std::env::var_os("AppleInterfaceStyle").as_deref().and_then(GhosttyThemeMode::parse)
    {
        return mode;
    }
    if let Some(mode) = platform_appearance() {
        return mode;
    }
    GhosttyThemeMode::Light
}

#[cfg(target_os = "macos")]
pub(super) fn platform_appearance_theme_mode(
    _deadline_at: Option<Instant>,
) -> Option<GhosttyThemeMode> {
    macos_appearance_theme_mode()
}

#[cfg(not(target_os = "macos"))]
pub(super) fn platform_appearance_theme_mode(
    deadline_at: Option<Instant>,
) -> Option<GhosttyThemeMode> {
    non_macos_appearance_theme_mode(deadline_at)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn non_macos_appearance_theme_mode(
    deadline_at: Option<Instant>,
) -> Option<GhosttyThemeMode> {
    if let Some(mode) = freedesktop_portal_theme_mode(deadline_at) {
        return Some(mode);
    }
    if let Some(mode) = gnome_color_scheme_theme_mode(deadline_at) {
        return Some(mode);
    }
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    if let Some(mode) = std::env::var_os("GTK_THEME")
        .as_deref()
        .and_then(|value| gtk_theme_name_theme_mode(&value.to_string_lossy()))
    {
        return Some(mode);
    }
    gtk_settings_paths()
        .into_iter()
        .find_map(|path| {
            if ghostty_config_deadline_expired(deadline_at) {
                return None;
            }
            let text = read_ghostty_regular_file(&path, 64 * 1024)?;
            gtk_settings_theme_mode(&text)
        })
        .or_else(|| kde_globals_theme_mode(deadline_at))
}

#[cfg(not(target_os = "macos"))]
pub(super) fn freedesktop_portal_theme_mode(
    deadline_at: Option<Instant>,
) -> Option<GhosttyThemeMode> {
    let output = desktop_theme_command_output(
        "gdbus",
        &[
            "call",
            "--session",
            "--dest",
            "org.freedesktop.portal.Desktop",
            "--object-path",
            "/org/freedesktop/portal/desktop",
            "--method",
            "org.freedesktop.portal.Settings.Read",
            "org.freedesktop.appearance",
            "color-scheme",
        ],
        deadline_at,
    )?;
    freedesktop_portal_color_scheme_theme_mode(&output)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn gnome_color_scheme_theme_mode(
    deadline_at: Option<Instant>,
) -> Option<GhosttyThemeMode> {
    let output = desktop_theme_command_output(
        "gsettings",
        &["get", "org.gnome.desktop.interface", "color-scheme"],
        deadline_at,
    )?;
    gnome_color_scheme_output_theme_mode(&output)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn desktop_theme_command_output(
    program: &str,
    args: &[&str],
    deadline_at: Option<Instant>,
) -> Option<String> {
    desktop_theme_command_output_with_lifecycle_signals(program, args, deadline_at, None, None)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn desktop_theme_command_output_with_lifecycle_signals(
    program: &str,
    args: &[&str],
    deadline_at: Option<Instant>,
    started_sender: Option<&mpsc::SyncSender<u32>>,
    reaped_sender: Option<&mpsc::SyncSender<()>>,
) -> Option<String> {
    let timeout =
        ghostty_config_deadline_remaining(deadline_at)?.min(GHOSTTY_DESKTOP_APPEARANCE_DEADLINE);
    if timeout.is_zero() {
        return None;
    }
    let command_deadline = Instant::now() + timeout;
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn().ok()?;
    if let Some(started_sender) = started_sender {
        let _ = started_sender.send(child.id());
    }
    #[cfg(unix)]
    let child_group = child.id() as libc::pid_t;
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_helper_child(child);
        return None;
    };
    let Some(output_reader) = read_ghostty_helper_output_async(stdout) else {
        terminate_ghostty_helper_child(child);
        return None;
    };
    let status = match child.wait_timeout(timeout) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            terminate_ghostty_helper_child(child);
            return None;
        }
    };
    if !status.success() {
        return None;
    }
    match output_reader.recv_timeout(ghostty_duration_until(command_deadline)) {
        Ok(output) => output,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            #[cfg(unix)]
            kill_ghostty_process_group(child_group);
            let reap_timeout =
                ghostty_config_deadline_remaining(deadline_at)?.min(GHOSTTY_HELPER_REAP_DEADLINE);
            if !reap_timeout.is_zero()
                && output_reader.recv_timeout(reap_timeout).is_ok()
                && let Some(reaped_sender) = reaped_sender
            {
                let _ = reaped_sender.send(());
            }
            None
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => None,
    }
}

#[cfg(any(test, not(target_os = "macos")))]
pub(super) fn freedesktop_portal_color_scheme_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    if text.contains("uint32 1") || text.contains("<1>") {
        return Some(GhosttyThemeMode::Dark);
    }
    if text.contains("uint32 2") || text.contains("<2>") {
        return Some(GhosttyThemeMode::Light);
    }
    None
}

#[cfg(any(test, not(target_os = "macos")))]
pub(super) fn gnome_color_scheme_output_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    let text = text.trim().trim_matches('\'').trim_matches('"');
    match text {
        "prefer-dark" => Some(GhosttyThemeMode::Dark),
        "prefer-light" => Some(GhosttyThemeMode::Light),
        _ => None,
    }
}

#[cfg(not(target_os = "macos"))]
pub(super) fn kde_globals_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    kde_globals_paths().into_iter().find_map(|path| {
        if ghostty_config_deadline_expired(deadline_at) {
            return None;
        }
        let text = read_ghostty_regular_file(&path, 64 * 1024)?;
        kde_globals_text_theme_mode(&text)
    })
}

#[cfg(not(target_os = "macos"))]
pub(super) fn kde_globals_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(config_home) = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from) {
        paths.push(config_home.join("kdeglobals"));
    }
    if let Some(home) = platform::home_dir() {
        let path = home.join(".config").join("kdeglobals");
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    paths
}

#[cfg(any(test, not(target_os = "macos")))]
pub(super) fn kde_globals_text_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() == "ColorScheme" {
            return gtk_theme_name_theme_mode(value.trim());
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
pub(super) fn gtk_settings_paths() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(config_home) = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from) {
        roots.push(config_home);
    }
    if let Some(home) = platform::home_dir() {
        roots.push(home.join(".config"));
    }

    let mut paths = Vec::new();
    for root in roots {
        for version in ["gtk-4.0", "gtk-3.0"] {
            let path = root.join(version).join("settings.ini");
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    paths
}

#[cfg(any(test, not(target_os = "macos")))]
pub(super) fn gtk_settings_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    let mut theme_name = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let key = key.trim();
        let value = value.trim().trim_matches('"');
        match key {
            "gtk-application-prefer-dark-theme" => match value.to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" => return Some(GhosttyThemeMode::Dark),
                "0" | "false" | "no" => {}
                _ => {}
            },
            "gtk-theme-name" => theme_name = gtk_theme_name_theme_mode(value),
            _ => {}
        }
    }
    theme_name
}

#[cfg(any(test, not(target_os = "macos")))]
pub(super) fn gtk_theme_name_theme_mode(value: &str) -> Option<GhosttyThemeMode> {
    let value = value.to_ascii_lowercase();
    if value.ends_with("dark") || value.split([':', '-', '_']).any(|part| part == "dark") {
        return Some(GhosttyThemeMode::Dark);
    }
    if value.ends_with("light") || value.split([':', '-', '_']).any(|part| part == "light") {
        return Some(GhosttyThemeMode::Light);
    }
    None
}

#[cfg(target_os = "macos")]
pub(super) fn macos_appearance_theme_mode() -> Option<GhosttyThemeMode> {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_void};
    use std::ptr;

    type CfTypeRef = *const c_void;
    type CfStringRef = *const c_void;
    type Boolean = u8;

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFPreferencesAnyApplication: CfStringRef;
        static kCFPreferencesCurrentUser: CfStringRef;
        static kCFPreferencesAnyHost: CfStringRef;

        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const c_char,
            encoding: u32,
        ) -> CfStringRef;
        fn CFPreferencesCopyValue(
            key: CfStringRef,
            application_id: CfStringRef,
            user_name: CfStringRef,
            host_name: CfStringRef,
        ) -> CfTypeRef;
        fn CFEqual(cf1: CfTypeRef, cf2: CfTypeRef) -> Boolean;
        fn CFRelease(cf: CfTypeRef);
    }

    let key = CString::new("AppleInterfaceStyle").ok()?;
    let dark = CString::new("Dark").ok()?;
    unsafe {
        let key_ref =
            CFStringCreateWithCString(ptr::null(), key.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        if key_ref.is_null() {
            return None;
        }
        let dark_ref =
            CFStringCreateWithCString(ptr::null(), dark.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        if dark_ref.is_null() {
            CFRelease(key_ref);
            return None;
        }
        let value = CFPreferencesCopyValue(
            key_ref,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        );
        let mode = if !value.is_null() && CFEqual(value, dark_ref) != 0 {
            GhosttyThemeMode::Dark
        } else {
            GhosttyThemeMode::Light
        };
        if !value.is_null() {
            CFRelease(value);
        }
        CFRelease(dark_ref);
        CFRelease(key_ref);
        Some(mode)
    }
}
