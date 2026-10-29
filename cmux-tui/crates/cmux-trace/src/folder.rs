//! Where a process's rings go (plans/cmux-next/chrome-parity/p09-observability.md, task 095,
//! "Folders"): every process but the holder writes into the app's trace folder, which the hang
//! reports read (Swift `TraceBlackBoxFileSteps.appDirectory`, `HangReportFieldSources.RingFolders`).
//!
//! - `CMUX_TRACE_FLOWS` names the folder when set: the key-flow recording must be a file there
//!   (`cmux-flow-trace`), and the hang reports read that folder too.
//! - macOS: `~/Library/Logs/<CMUX_BUNDLE_ID>/trace`, the app's own folder; the app passes its
//!   bundle id to the daemon, which passes it to its hosts. A process with no bundle id (one
//!   started with a cleared environment) uses the default app's folder.
//! - Other unix: `$XDG_STATE_HOME/cmux/trace`, else `~/.local/state/cmux/trace`.
//! - Windows: `%LOCALAPPDATA%\cmux\trace`.
//!
//! With no home folder at all, `<temp>/cmux-trace`.

use std::ffi::OsString;
use std::path::PathBuf;

/// The variable that turns on key-press flows and names their folder (`cmux-flow-trace`).
const FLOWS_ENV: &str = "CMUX_TRACE_FLOWS";
/// The app's bundle id, which the app sets for the daemon and the daemon's children inherit.
const BUNDLE_ENV: &str = "CMUX_BUNDLE_ID";
/// The bundle whose folder a process with no bundle id uses (Swift's `appDirectory` default).
const DEFAULT_BUNDLE_ID: &str = "com.cmuxterm.app.next";

/// The folder rule of one platform.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Platform {
    MacLogs,
    XdgState,
    LocalAppData,
}

impl Platform {
    const CURRENT: Platform = if cfg!(target_os = "macos") {
        Platform::MacLogs
    } else if cfg!(windows) {
        Platform::LocalAppData
    } else {
        Platform::XdgState
    };
}

/// This process's ring folder, from its environment and home folder (see the module doc).
pub fn process_dir() -> PathBuf {
    process_dir_with(|key| std::env::var_os(key), home_dir())
}

/// [`process_dir`] with the environment and the home folder given.
pub fn process_dir_with(env: impl Fn(&str) -> Option<OsString>, home: Option<PathBuf>) -> PathBuf {
    dir_for(Platform::CURRENT, env, home)
}

fn dir_for(
    platform: Platform,
    env: impl Fn(&str) -> Option<OsString>,
    home: Option<PathBuf>,
) -> PathBuf {
    let set = |key: &str| env(key).filter(|value| !value.is_empty());
    if let Some(flows) = set(FLOWS_ENV) {
        return PathBuf::from(flows);
    }
    let home = home.filter(|home| home.is_absolute());
    match platform {
        Platform::MacLogs => {
            let bundle = set(BUNDLE_ENV)
                .and_then(|bundle| bundle.into_string().ok())
                .filter(|bundle| is_bundle_id(bundle))
                .unwrap_or_else(|| DEFAULT_BUNDLE_ID.to_owned());
            home.map(|home| home.join("Library/Logs").join(bundle).join("trace"))
        }
        Platform::XdgState => set("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|state| state.is_absolute())
            .or_else(|| home.map(|home| home.join(".local/state")))
            .map(|state| state.join("cmux").join("trace")),
        Platform::LocalAppData => set("LOCALAPPDATA")
            .map(PathBuf::from)
            .filter(|local| local.is_absolute())
            .map(|local| local.join("cmux").join("trace")),
    }
    .unwrap_or_else(|| std::env::temp_dir().join("cmux-trace"))
}

/// A bundle id that is one plain folder name: `[A-Za-z0-9._-]`, not `.` or `..`.
fn is_bundle_id(bundle: &str) -> bool {
    !bundle.is_empty()
        && bundle.len() <= 255
        && bundle != "."
        && bundle != ".."
        && bundle
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// `$HOME`, else this user's home in the password database (a process started with a cleared
/// environment, such as the app host).
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|home| !home.is_empty()).map(PathBuf::from).or_else(user_home)
}

#[cfg(unix)]
fn user_home() -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = vec![0 as libc::c_char; 4096];
    // SAFETY: passwd is plain old data; all zero is a valid value.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: valid out pointers and a buffer of the length given; getuid cannot fail.
    let status = unsafe {
        libc::getpwuid_r(libc::getuid(), &mut entry, buffer.as_mut_ptr(), buffer.len(), &mut found)
    };
    if status != 0 || found.is_null() || entry.pw_dir.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r succeeded, so pw_dir is a NUL-terminated string inside `buffer`.
    let dir = unsafe { CStr::from_ptr(entry.pw_dir) };
    let dir = std::path::Path::new(std::ffi::OsStr::from_bytes(dir.to_bytes()));
    (!dir.as_os_str().is_empty()).then(|| dir.to_path_buf())
}

#[cfg(not(unix))]
fn user_home() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |key| pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| value.into())
    }

    #[test]
    fn the_flows_folder_wins() {
        let dir = dir_for(
            Platform::MacLogs,
            env(&[("CMUX_TRACE_FLOWS", "/tmp/flows"), ("CMUX_BUNDLE_ID", "com.x")]),
            Some("/Users/a".into()),
        );
        assert_eq!(dir, PathBuf::from("/tmp/flows"));
    }

    #[test]
    fn macos_uses_the_apps_logs_folder() {
        let home = Some(PathBuf::from("/Users/a"));
        let tagged = dir_for(
            Platform::MacLogs,
            env(&[("CMUX_BUNDLE_ID", "com.cmuxterm.app.next.debug.tag")]),
            home.clone(),
        );
        assert_eq!(
            tagged,
            PathBuf::from("/Users/a/Library/Logs/com.cmuxterm.app.next.debug.tag/trace")
        );
        let plain = dir_for(Platform::MacLogs, env(&[]), home.clone());
        assert_eq!(plain, PathBuf::from("/Users/a/Library/Logs/com.cmuxterm.app.next/trace"));
        for bad in [&[("CMUX_BUNDLE_ID", "../x")][..], &[("CMUX_BUNDLE_ID", "..")][..]] {
            let dir = dir_for(Platform::MacLogs, env(bad), home.clone());
            assert_eq!(dir, plain, "a bundle id that is not one folder name is ignored");
        }
    }

    #[test]
    fn linux_uses_the_state_folder() {
        let home = Some(PathBuf::from("/home/a"));
        let state = dir_for(Platform::XdgState, env(&[("XDG_STATE_HOME", "/st")]), home.clone());
        assert_eq!(state, PathBuf::from("/st/cmux/trace"));
        let relative = dir_for(Platform::XdgState, env(&[("XDG_STATE_HOME", "st")]), home);
        assert_eq!(relative, PathBuf::from("/home/a/.local/state/cmux/trace"));
    }

    #[test]
    fn no_home_falls_back_to_temp() {
        let dir = dir_for(Platform::MacLogs, env(&[]), None);
        assert_eq!(dir, std::env::temp_dir().join("cmux-trace"));
        let relative = dir_for(Platform::XdgState, env(&[]), Some("home".into()));
        assert_eq!(relative, std::env::temp_dir().join("cmux-trace"));
    }

    #[cfg(unix)]
    #[test]
    fn the_password_database_has_a_home() {
        assert!(user_home().is_some_and(|home| home.is_absolute()));
    }
}
