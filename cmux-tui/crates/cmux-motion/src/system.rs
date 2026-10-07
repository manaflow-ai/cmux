//! The system Reduce Motion setting off macOS. cmux-next reads macOS
//! `NSWorkspace.accessibilityDisplayShouldReduceMotion` on every policy read
//! (`CmuxNextDesign/Motion/Motion.swift:29-31`); `settings.rs` does the same
//! on macOS. Linux and Windows get the same rule from their own setting,
//! kept in an atomic by a watcher thread that starts on the first read, so
//! `policy()` stays a load:
//!
//! - Linux: GNOME's `org.gnome.desktop.interface enable-animations` (what
//!   GTK's `gtk-enable-animations` and Chromium's `prefers-reduced-motion`
//!   follow there), watched with `gsettings monitor`: a change applies at
//!   once, nothing polls. Without gsettings: `gtk-enable-animations` in
//!   `$XDG_CONFIG_HOME/gtk-3.0/settings.ini` (KDE writes it there), read
//!   once. Until the first value arrives (the watcher reads it off the
//!   caller's thread: gsettings can start dconf over D-Bus) it is false.
//! - Windows: "Animation effects" (Settings > Accessibility > Visual
//!   effects), `SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION)`, what
//!   Chromium's `prefers-reduced-motion` follows there. Read at once on the
//!   first call, then again on each `WM_SETTINGCHANGE` for
//!   `SPI_SETCLIENTAREAANIMATION`, which a hidden window on the watcher
//!   thread receives (a message-only window gets no broadcasts).

#[cfg(any(target_os = "linux", target_os = "windows"))]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(any(target_os = "linux", target_os = "windows"))]
static REDUCE: AtomicBool = AtomicBool::new(false);

/// The platform setting (false where none is read).
pub fn reduce_motion() -> bool {
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    {
        static START: std::sync::Once = std::sync::Once::new();
        START.call_once(platform::start);
        REDUCE.load(Ordering::Relaxed)
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        false
    }
}

/// `gsettings get` / `gsettings monitor` output for `enable-animations`
/// ("false", "enable-animations: false"): Some(true) when animations are off.
#[cfg_attr(
    not(target_os = "linux"),
    allow(dead_code, reason = "Linux only; unit-tested everywhere")
)]
pub(crate) fn parse_gsettings(line: &str) -> Option<bool> {
    match line.rsplit(':').next()?.trim() {
        "false" => Some(true),
        "true" => Some(false),
        _ => None,
    }
}

/// `gtk-enable-animations` in a GTK `settings.ini` (the last one wins):
/// Some(true) when off.
#[cfg_attr(
    not(target_os = "linux"),
    allow(dead_code, reason = "Linux only; unit-tested everywhere")
)]
pub(crate) fn parse_gtk_ini(text: &str) -> Option<bool> {
    let (_, value) = text
        .lines()
        .filter_map(|l| l.split_once('='))
        .rfind(|(k, _)| k.trim() == "gtk-enable-animations")?;
    match value.trim().to_ascii_lowercase().as_str() {
        "0" | "false" => Some(true),
        "1" | "true" => Some(false),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::{
        io::{BufRead, BufReader},
        os::unix::process::CommandExt,
        process::{Command, Stdio},
        sync::atomic::Ordering,
    };

    const SCHEMA: &str = "org.gnome.desktop.interface";
    const KEY: &str = "enable-animations";

    pub fn start() {
        let _ = std::thread::Builder::new().name("cmux-motion-reduce".into()).spawn(|| {
            if let Some(v) = gsettings_get().or_else(gtk_ini) {
                super::REDUCE.store(v, Ordering::Relaxed);
            }
            watch();
        });
    }

    fn gsettings_get() -> Option<bool> {
        let out = Command::new("gsettings")
            .args(["get", SCHEMA, KEY])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        super::parse_gsettings(&String::from_utf8_lossy(&out.stdout))
    }

    fn gtk_ini() -> Option<bool> {
        let base =
            std::env::var_os("XDG_CONFIG_HOME").map(std::path::PathBuf::from).or_else(|| {
                std::env::var_os("HOME").map(|h| std::path::Path::new(&h).join(".config"))
            })?;
        super::parse_gtk_ini(&std::fs::read_to_string(base.join("gtk-3.0/settings.ini")).ok()?)
    }

    /// `gsettings monitor` prints one line per change. It ends with this
    /// process (PR_SET_PDEATHSIG), so it never outlives the app.
    fn watch() {
        let mut cmd = Command::new("gsettings");
        cmd.args(["monitor", SCHEMA, KEY])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // SAFETY: prctl is async-signal-safe and touches no parent state.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let Ok(mut child) = cmd.spawn() else { return };
        if let Some(out) = child.stdout.take() {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(v) = super::parse_gsettings(&line) {
                    super::REDUCE.store(v, Ordering::Relaxed);
                }
            }
        }
        let _ = child.wait();
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use std::sync::atomic::Ordering;
    use windows_sys::Win32::{
        Foundation::{HWND, LPARAM, LRESULT, WPARAM},
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, MSG, RegisterClassW,
            SPI_GETCLIENTAREAANIMATION, SPI_SETCLIENTAREAANIMATION, SystemParametersInfoW,
            TranslateMessage, WM_SETTINGCHANGE, WNDCLASSW,
        },
    };

    pub fn start() {
        // First value now, so the first policy read is already right.
        read();
        let _ = std::thread::Builder::new().name("cmux-motion-reduce".into()).spawn(listen);
    }

    fn read() {
        let mut on: windows_sys::core::BOOL = 1;
        // SAFETY: SPI_GETCLIENTAREAANIMATION writes one BOOL to pvparam.
        let ok = unsafe {
            SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, (&raw mut on).cast(), 0)
        };
        if ok != 0 {
            super::REDUCE.store(on == 0, Ordering::Relaxed);
        }
    }

    unsafe extern "system" fn wndproc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if msg == WM_SETTINGCHANGE && wparam == SPI_SETCLIENTAREAANIMATION as WPARAM {
            read();
        }
        // SAFETY: the default procedure for this window's own message.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    /// A hidden top-level window (never shown) on its own thread: broadcasts
    /// such as WM_SETTINGCHANGE reach top-level windows only.
    fn listen() {
        let class: Vec<u16> = "CmuxMotionSettingsListener\0".encode_utf16().collect();
        // SAFETY: plain Win32 window creation and a message loop on this
        // thread; the class name outlives every use (the loop never returns
        // while the window exists).
        unsafe {
            let instance = GetModuleHandleW(std::ptr::null());
            let wc = WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: instance,
                lpszClassName: class.as_ptr(),
                ..std::mem::zeroed()
            };
            if RegisterClassW(&wc) == 0 {
                return;
            }
            let hwnd = CreateWindowExW(
                0,
                class.as_ptr(),
                class.as_ptr(),
                0,
                0,
                0,
                0,
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                instance,
                std::ptr::null(),
            );
            if hwnd.is_null() {
                return;
            }
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gsettings_lines() {
        assert_eq!(parse_gsettings("false\n"), Some(true));
        assert_eq!(parse_gsettings("true"), Some(false));
        assert_eq!(parse_gsettings("enable-animations: false"), Some(true));
        assert_eq!(parse_gsettings("enable-animations: true"), Some(false));
        assert_eq!(parse_gsettings("No such schema"), None);
    }

    #[test]
    fn gtk_settings_ini() {
        assert_eq!(
            parse_gtk_ini("[Settings]\ngtk-theme-name=Breeze\ngtk-enable-animations=0\n"),
            Some(true)
        );
        assert_eq!(parse_gtk_ini("[Settings]\ngtk-enable-animations = true"), Some(false));
        assert_eq!(
            parse_gtk_ini("[Settings]\ngtk-enable-animations=1\ngtk-enable-animations=false"),
            Some(true)
        );
        assert_eq!(parse_gtk_ini("[Settings]\ngtk-theme-name=Adwaita"), None);
    }
}
