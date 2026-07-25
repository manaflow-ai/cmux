//! Platform decisions for cmux-tui.

use std::path::{Path, PathBuf};

pub mod transport {
    use std::io::{self, Read, Write};
    use std::net::Shutdown;
    use std::path::Path;
    use std::time::Duration;

    pub trait Stream: Read + Write + Send + Sync {
        fn try_clone_box(&self) -> io::Result<Box<dyn Stream>>;
        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn shutdown(&self, how: Shutdown) -> io::Result<()>;
        fn peer_process_id(&self) -> io::Result<Option<u32>> {
            Ok(None)
        }
    }

    pub struct Listener {
        inner: imp::Listener,
    }

    pub fn listen(path: &Path) -> io::Result<Listener> {
        imp::listen(path).map(|inner| Listener { inner })
    }

    pub fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
        imp::connect(path)
    }

    impl Listener {
        pub fn accept(&self) -> io::Result<Box<dyn Stream>> {
            self.inner.accept()
        }
    }

    #[cfg(unix)]
    mod imp {
        use std::io;
        use std::os::unix::net::{UnixListener, UnixStream};
        use std::path::Path;
        use std::time::Duration;

        use super::Stream;

        pub(super) struct Listener {
            inner: UnixListener,
        }

        pub(super) fn listen(path: &Path) -> io::Result<Listener> {
            UnixListener::bind(path).map(|inner| Listener { inner })
        }

        pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(UnixStream::connect(path)?))
        }

        impl Listener {
            pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
                let (stream, _) = self.inner.accept()?;
                Ok(Box::new(stream))
            }
        }

        impl Stream for UnixStream {
            fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
                Ok(Box::new(self.try_clone()?))
            }

            fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_read_timeout(self, timeout)
            }

            fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_write_timeout(self, timeout)
            }

            fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
                UnixStream::shutdown(self, how)
            }

            fn peer_process_id(&self) -> io::Result<Option<u32>> {
                peer_process_id(self)
            }
        }

        #[cfg(target_os = "macos")]
        fn peer_process_id(stream: &UnixStream) -> io::Result<Option<u32>> {
            use std::mem::size_of;
            use std::os::fd::AsRawFd;

            let mut pid: libc::pid_t = 0;
            let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
            let result = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_LOCAL,
                    libc::LOCAL_PEERPID,
                    (&raw mut pid).cast(),
                    &raw mut length,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::pid_t>() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"));
            }
            u32::try_from(pid)
                .map(Some)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"))
        }

        #[cfg(target_os = "linux")]
        fn peer_process_id(stream: &UnixStream) -> io::Result<Option<u32>> {
            use std::mem::{size_of, zeroed};
            use std::os::fd::AsRawFd;

            let mut credentials = unsafe { zeroed::<libc::ucred>() };
            let mut length = size_of::<libc::ucred>() as libc::socklen_t;
            let result = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    (&raw mut credentials).cast(),
                    &raw mut length,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::ucred>() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid peer credentials"));
            }
            u32::try_from(credentials.pid)
                .map(Some)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"))
        }

        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        fn peer_process_id(_stream: &UnixStream) -> io::Result<Option<u32>> {
            Ok(None)
        }
    }

    #[cfg(windows)]
    mod imp {
        use std::io;
        use std::path::Path;
        use std::time::Duration;

        use super::Stream;
        use uds_windows::{UnixListener, UnixStream};

        pub(super) struct Listener {
            inner: UnixListener,
        }

        pub(super) fn listen(path: &Path) -> io::Result<Listener> {
            UnixListener::bind(path).map(|inner| Listener { inner })
        }

        pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(UnixStream::connect(path)?))
        }

        impl Listener {
            pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
                let (stream, _) = self.inner.accept()?;
                Ok(Box::new(stream))
            }
        }

        impl Stream for UnixStream {
            fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
                Ok(Box::new(self.try_clone()?))
            }

            fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_read_timeout(self, timeout)
            }

            fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_write_timeout(self, timeout)
            }

            fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
                UnixStream::shutdown(self, how)
            }
        }
    }
}

/// Runtime socket/pidfile directory for the current user.
pub fn runtime_dir() -> PathBuf {
    runtime_base_dir().join(format!("cmux-tui-{}", user_id_component()))
}

/// Short, user-private runtime directory used when the preferred runtime
/// directory would make a Unix-domain socket path too long for `sockaddr_un`.
///
/// Keep this path stable across frontends: clients must derive the same
/// fallback without first connecting to the server.
#[cfg(unix)]
pub fn fallback_runtime_dir() -> PathBuf {
    PathBuf::from("/tmp").join(format!("cmux-tui-{}", user_id_component()))
}

/// Default root for durable workspace/session state. Runtime sockets stay in
/// the short-lived runtime directory; canonical identities and mutation
/// ledgers live here across daemon and machine reboots.
pub fn workspace_state_dir() -> Option<PathBuf> {
    if let Some(path) = env_path("CMUX_TUI_STATE_DIR") {
        return Some(path);
    }
    #[cfg(target_os = "macos")]
    {
        home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("sessions")
        })
    }
    #[cfg(target_os = "linux")]
    {
        env_path("XDG_STATE_HOME").map(|state| state.join("cmux-tui").join("sessions")).or_else(
            || {
                home_dir()
                    .map(|home| home.join(".local").join("state").join("cmux-tui").join("sessions"))
            },
        )
    }
    #[cfg(windows)]
    {
        return env_path("LOCALAPPDATA").map(|dir| dir.join("cmux-tui").join("sessions"));
    }
    #[cfg(all(not(target_os = "macos"), not(target_os = "linux"), not(windows)))]
    {
        env_path("XDG_STATE_HOME").map(|state| state.join("cmux-tui").join("sessions")).or_else(
            || {
                home_dir()
                    .map(|home| home.join(".local").join("state").join("cmux-tui").join("sessions"))
            },
        )
    }
}

/// User config file path, honoring explicit env overrides before the default
/// cmux config directory. `cmux-tui.json` is preferred, with `mux.json`
/// retained as a compatibility fallback for existing installs.
pub fn config_path() -> Option<PathBuf> {
    if let Some(path) = env_path("CMUX_TUI_CONFIG").or_else(|| env_path("CMUX_MUX_CONFIG")) {
        return Some(path);
    }
    config_dir().map(preferred_config_path)
}

#[cfg(not(windows))]
fn config_dir() -> Option<PathBuf> {
    env_path("XDG_CONFIG_HOME")
        .map(|config_home| config_home.join("cmux"))
        .or_else(|| home_dir().map(|home| home.join(".config").join("cmux")))
}

#[cfg(windows)]
fn config_dir() -> Option<PathBuf> {
    env_path("APPDATA").map(|appdata| appdata.join("cmux"))
}

fn preferred_config_path(dir: PathBuf) -> PathBuf {
    let preferred = dir.join("cmux-tui.json");
    if preferred.exists() {
        return preferred;
    }
    let legacy = dir.join("mux.json");
    if legacy.exists() { legacy } else { preferred }
}

/// Default interactive shell for spawned PTY surfaces.
#[cfg(not(windows))]
pub fn default_shell() -> String {
    if let Some(shell) = env_string("SHELL") {
        return shell;
    }

    if Path::new("/bin/bash").is_file() { "/bin/bash".to_string() } else { "/bin/sh".to_string() }
}

/// Default interactive shell for spawned PTY surfaces.
#[cfg(windows)]
pub fn default_shell() -> String {
    find_on_path(&["pwsh.exe", "powershell.exe", "cmd.exe"])
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| "cmd.exe".to_string())
}

/// Candidate Chrome/Chromium-family binaries in platform discovery order.
pub fn chrome_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    #[cfg(target_os = "macos")]
    {
        push_unique(
            &mut candidates,
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".into(),
        );
        push_unique(&mut candidates, "/Applications/Chromium.app/Contents/MacOS/Chromium".into());
        push_unique(
            &mut candidates,
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser".into(),
        );
        push_unique(
            &mut candidates,
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge".into(),
        );
        push_path_candidates(
            &mut candidates,
            &[
                "google-chrome",
                "google-chrome-stable",
                "chromium",
                "chromium-browser",
                "brave-browser",
                "microsoft-edge",
            ],
        );
    }

    #[cfg(target_os = "linux")]
    {
        push_path_candidates(
            &mut candidates,
            &["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
        );
        for path in [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
            "/opt/google/chrome/chrome",
            "/opt/chromium.org/chromium/chromium",
        ] {
            push_unique(&mut candidates, path.into());
        }
    }

    #[cfg(windows)]
    {
        push_path_candidates(
            &mut candidates,
            &["chrome.exe", "google-chrome.exe", "chromium.exe", "msedge.exe", "brave.exe"],
        );
        for base in ["PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA"] {
            if let Some(dir) = env_path(base) {
                for path in [
                    dir.join("Google").join("Chrome").join("Application").join("chrome.exe"),
                    dir.join("Chromium").join("Application").join("chrome.exe"),
                    dir.join("BraveSoftware")
                        .join("Brave-Browser")
                        .join("Application")
                        .join("brave.exe"),
                    dir.join("Microsoft").join("Edge").join("Application").join("msedge.exe"),
                ] {
                    push_unique(&mut candidates, path);
                }
            }
        }
    }

    #[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
    {
        push_path_candidates(
            &mut candidates,
            &["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
        );
    }

    candidates
}

/// Candidate Ghostty config files used to seed selection colors.
pub fn ghostty_config_paths() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(config_home) = env_path("XDG_CONFIG_HOME") {
        push_unique(&mut candidates, config_home.join("ghostty").join("config"));
    }
    if let Some(home) = home_dir() {
        push_unique(&mut candidates, home.join(".config").join("ghostty").join("config"));
        #[cfg(target_os = "macos")]
        push_unique(
            &mut candidates,
            home.join("Library")
                .join("Application Support")
                .join("com.mitchellh.ghostty")
                .join("config"),
        );
    }
    candidates
}

/// A Ghostty config resolver and the resources that must accompany it.
///
/// The executable and resource directory are kept together because a helper
/// embedded in another app bundle cannot infer `Contents/Resources/ghostty`
/// from its own location the way Ghostty.app can.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyInstallation {
    pub binary: PathBuf,
    pub resources_dir: Option<PathBuf>,
}

/// Candidate Ghostty installations, in the order cmux-tui should probe them.
///
/// An explicit `GHOSTTY_BIN` remains authoritative. Otherwise, prefer the
/// standalone CLI helper and resources shipped beside this exact cmux-tui
/// executable, then the intact pinned dogfood app, before considering a PATH
/// or system Ghostty. The package-local helper must be built with Ghostty's
/// `cli-helper` target; copying a macOS app executable without its Frameworks
/// directory is not sufficient. Failed candidates are skipped by the config
/// resolver. This keeps a packaged cmux frontend from silently resolving its
/// theme with an unrelated Ghostty installation.
pub fn ghostty_installations() -> Vec<GhosttyInstallation> {
    let current_exe = std::env::current_exe().ok();
    let explicit_binary = env_path("GHOSTTY_BIN");
    let explicit_resources = env_path("GHOSTTY_RESOURCES_DIR");
    let home = home_dir();
    let path_binary = find_on_path(&["ghostty"]);
    let mut candidates = ghostty_installation_candidates(
        explicit_binary,
        explicit_resources,
        current_exe.as_deref(),
        home.as_deref(),
        path_binary,
    );
    candidates.retain(|candidate| is_executable_file(&candidate.binary));
    for candidate in &mut candidates {
        candidate.resources_dir =
            candidate.resources_dir.take().filter(|path| path.is_dir()).or_else(|| {
                candidate
                    .binary
                    .canonicalize()
                    .ok()
                    .and_then(|path| ghostty_resources_for_binary(&path))
                    .filter(|path| path.is_dir())
            });
    }
    candidates
}

/// Compatibility view for callers that only need executable paths.
pub fn ghostty_binary_paths() -> Vec<PathBuf> {
    ghostty_installations().into_iter().map(|candidate| candidate.binary).collect()
}

/// Theme directories in Ghostty's resolution order.
///
/// A user-supplied theme overrides a bundled one with the same name. Include
/// cmux's bundled Ghostty resources as well so the headless fallback works
/// when cmux is installed without the standalone Ghostty app.
pub fn ghostty_theme_dirs() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(config_home) = env_path("XDG_CONFIG_HOME") {
        push_unique(&mut candidates, config_home.join("ghostty").join("themes"));
    } else if let Some(home) = home_dir() {
        push_unique(&mut candidates, home.join(".config").join("ghostty").join("themes"));
    }
    let current_exe = std::env::current_exe().ok();
    for installation in ghostty_installation_candidates(
        env_path("GHOSTTY_BIN"),
        env_path("GHOSTTY_RESOURCES_DIR"),
        current_exe.as_deref(),
        home_dir().as_deref(),
        find_on_path(&["ghostty"]),
    ) {
        if let Some(path) = installation.resources_dir {
            push_unique(&mut candidates, path.join("themes"));
        }
    }
    candidates
}

fn ghostty_installation_candidates(
    explicit_binary: Option<PathBuf>,
    explicit_resources: Option<PathBuf>,
    current_exe: Option<&Path>,
    home: Option<&Path>,
    path_binary: Option<PathBuf>,
) -> Vec<GhosttyInstallation> {
    let mut candidates = Vec::new();

    if let Some(binary) = explicit_binary.as_ref() {
        push_unique_installation(
            &mut candidates,
            binary.clone(),
            explicit_resources.clone().or_else(|| ghostty_resources_for_binary(binary)),
        );
    }

    if let Some(current_exe) = current_exe {
        for candidate in packaged_ghostty_installations(current_exe) {
            push_unique_installation(&mut candidates, candidate.binary, candidate.resources_dir);
        }
    }

    if let Some(home) = home {
        push_app_installation(
            &mut candidates,
            &home.join("Applications").join("Ghostty-cmux-pinned.app"),
        );
    }
    push_app_installation(&mut candidates, Path::new("/Applications/Ghostty-cmux-pinned.app"));

    // `GHOSTTY_RESOURCES_DIR` is commonly inherited from the terminal that
    // launched cmux, so it is a resource hint rather than proof that a helper
    // matches this build. Only use a binary inferred from it after package-local
    // and explicitly pinned installations.
    if let Some(resources) = explicit_resources.as_ref() {
        for binary in ghostty_binaries_for_resources(resources) {
            push_unique_installation(&mut candidates, binary, Some(resources.clone()));
        }
    }
    push_unique_installation(
        &mut candidates,
        PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/ghostty"),
        Some(PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty")),
    );

    if let Some(binary) = path_binary {
        push_unique_installation(
            &mut candidates,
            binary.clone(),
            ghostty_resources_for_binary(&binary),
        );
    }
    push_app_installation(&mut candidates, Path::new("/Applications/Ghostty.app"));
    candidates
}

fn packaged_ghostty_installations(current_exe: &Path) -> Vec<GhosttyInstallation> {
    let mut candidates = Vec::new();
    let Some(executable_dir) = current_exe.parent() else { return candidates };

    // macOS app bundle: cmux-tui is installed in Contents/Helpers while a
    // standalone Ghostty `cli-helper` build and resources live in
    // Contents/Resources. Do not copy Ghostty.app's MacOS executable here: it
    // has app-relative framework dependencies that are absent in this layout.
    if executable_dir.file_name().is_some_and(|name| name == "Helpers" || name == "MacOS")
        && let Some(contents) = executable_dir.parent()
        && contents.file_name().is_some_and(|name| name == "Contents")
    {
        let resources = contents.join("Resources");
        push_unique_installation(
            &mut candidates,
            resources.join("bin").join("ghostty"),
            Some(resources.join("ghostty")),
        );
    }

    // Flat release artifact: cmux-tui, bin/ghostty, and ghostty/ share a root.
    push_unique_installation(
        &mut candidates,
        executable_dir.join("bin").join("ghostty"),
        Some(executable_dir.join("ghostty")),
    );

    // Conventional prefix: bin/cmux-tui + bin/ghostty + share/ghostty.
    if executable_dir.file_name().is_some_and(|name| name == "bin")
        && let Some(prefix) = executable_dir.parent()
    {
        push_unique_installation(
            &mut candidates,
            executable_dir.join("ghostty"),
            Some(prefix.join("share").join("ghostty")),
        );
    }
    candidates
}

fn ghostty_binaries_for_resources(resources: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    let Some(parent) = resources.parent() else { return candidates };
    if parent.file_name().is_some_and(|name| name == "Resources") {
        push_unique(&mut candidates, parent.join("bin").join("ghostty"));
        if let Some(contents) = parent.parent()
            && contents.file_name().is_some_and(|name| name == "Contents")
        {
            push_unique(&mut candidates, contents.join("MacOS").join("ghostty"));
        }
    } else if parent.file_name().is_some_and(|name| name == "share") {
        if let Some(prefix) = parent.parent() {
            push_unique(&mut candidates, prefix.join("bin").join("ghostty"));
        }
    } else {
        push_unique(&mut candidates, parent.join("bin").join("ghostty"));
    }
    candidates
}

fn ghostty_resources_for_binary(binary: &Path) -> Option<PathBuf> {
    let binary_dir = binary.parent()?;
    if binary_dir.file_name().is_some_and(|name| name == "MacOS") {
        let contents = binary_dir.parent()?;
        if contents.file_name().is_some_and(|name| name == "Contents") {
            return Some(contents.join("Resources").join("ghostty"));
        }
    }
    if binary_dir.file_name().is_some_and(|name| name == "bin") {
        let parent = binary_dir.parent()?;
        if parent.file_name().is_some_and(|name| name == "Resources") {
            return Some(parent.join("ghostty"));
        }
        return Some(parent.join("share").join("ghostty"));
    }
    None
}

fn push_app_installation(candidates: &mut Vec<GhosttyInstallation>, app: &Path) {
    push_unique_installation(
        candidates,
        app.join("Contents").join("MacOS").join("ghostty"),
        Some(app.join("Contents").join("Resources").join("ghostty")),
    );
}

fn push_unique_installation(
    candidates: &mut Vec<GhosttyInstallation>,
    binary: PathBuf,
    resources_dir: Option<PathBuf>,
) {
    if let Some(existing) = candidates.iter_mut().find(|candidate| candidate.binary == binary) {
        if existing.resources_dir.is_none() {
            existing.resources_dir = resources_dir;
        }
        return;
    }
    candidates.push(GhosttyInstallation { binary, resources_dir });
}

/// Persistent profile directory for launched Chrome/Chromium sessions.
pub fn chrome_user_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("chrome-profile")
        })
    }

    #[cfg(target_os = "linux")]
    {
        env_path("XDG_DATA_HOME")
            .map(|data_home| data_home.join("cmux-tui").join("chrome-profile"))
            .or_else(|| {
                home_dir().map(|home| {
                    home.join(".local").join("share").join("cmux-tui").join("chrome-profile")
                })
            })
    }

    #[cfg(windows)]
    {
        env_path("LOCALAPPDATA").map(|dir| dir.join("cmux-tui").join("chrome-profile"))
    }

    #[cfg(all(not(target_os = "macos"), not(target_os = "linux"), not(windows)))]
    {
        env_path("XDG_DATA_HOME").map(|dir| dir.join("cmux-tui").join("chrome-profile")).or_else(
            || {
                home_dir().map(|home| {
                    home.join(".local").join("share").join("cmux-tui").join("chrome-profile")
                })
            },
        )
    }
}

pub fn restrict_directory(path: &Path) -> std::io::Result<()> {
    restrict_permissions(path, 0o700)
}

pub fn restrict_file(path: &Path) -> std::io::Result<()> {
    restrict_permissions(path, 0o600)
}

pub fn is_executable_file(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

#[cfg(not(windows))]
fn runtime_base_dir() -> PathBuf {
    env_path("XDG_RUNTIME_DIR")
        .or_else(|| env_path("TMPDIR"))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

#[cfg(windows)]
fn runtime_base_dir() -> PathBuf {
    env_path("TEMP").or_else(|| env_path("TMP")).unwrap_or_else(std::env::temp_dir)
}

#[cfg(not(windows))]
pub fn home_dir() -> Option<PathBuf> {
    env_path("HOME")
}

#[cfg(windows)]
pub fn home_dir() -> Option<PathBuf> {
    env_path("USERPROFILE").or_else(|| {
        let drive = std::env::var_os("HOMEDRIVE")?;
        let path = std::env::var_os("HOMEPATH")?;
        let mut home = PathBuf::from(drive);
        home.push(path);
        Some(home)
    })
}

fn env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    (!value.is_empty()).then(|| PathBuf::from(value))
}

#[cfg(not(windows))]
fn env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.trim().is_empty())
}

#[cfg(unix)]
fn user_id_component() -> String {
    unsafe { libc::getuid() }.to_string()
}

#[cfg(windows)]
fn user_id_component() -> String {
    std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string())
}

fn push_path_candidates(candidates: &mut Vec<PathBuf>, names: &[&str]) {
    for name in names {
        if let Some(candidate) = find_on_path(&[*name]) {
            push_unique(candidates, candidate);
        }
    }
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for name in names {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(name);
            if is_executable_file(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

fn push_unique(candidates: &mut Vec<PathBuf>, path: PathBuf) {
    if !candidates.iter().any(|candidate| candidate == &path) {
        candidates.push(path);
    }
}

#[cfg(unix)]
fn restrict_permissions(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn unix_transport_reports_the_kernel_peer_process() {
        use std::os::unix::net::UnixStream;

        use transport::Stream as _;

        let (client, server) = UnixStream::pair().unwrap();

        assert_eq!(client.peer_process_id().unwrap(), Some(std::process::id()));
        assert_eq!(server.peer_process_id().unwrap(), Some(std::process::id()));
    }

    fn position(candidates: &[GhosttyInstallation], expected: impl AsRef<Path>) -> usize {
        let expected = expected.as_ref();
        candidates
            .iter()
            .position(|candidate| candidate.binary == expected)
            .unwrap_or_else(|| panic!("missing Ghostty candidate {}", expected.display()))
    }

    #[test]
    fn packaged_and_pinned_ghostty_precede_path_and_system_installs() {
        let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
        let home = Path::new("/Users/tester");
        let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            None,
            Some(browser),
            Some(home),
            Some(path_binary.clone()),
        );

        let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/bin/ghostty");
        let pinned = home
            .join("Applications")
            .join("Ghostty-cmux-pinned.app")
            .join("Contents")
            .join("MacOS")
            .join("ghostty");
        let system = Path::new("/Applications/Ghostty.app/Contents/MacOS/ghostty");
        assert!(position(&candidates, packaged) < position(&candidates, &pinned));
        assert!(position(&candidates, &pinned) < position(&candidates, &path_binary));
        assert!(position(&candidates, &path_binary) < position(&candidates, system));

        let packaged_installation = &candidates[position(&candidates, packaged)];
        assert_eq!(
            packaged_installation.resources_dir.as_deref(),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty"))
        );
    }

    #[test]
    fn explicit_ghostty_installation_remains_authoritative() {
        let explicit = PathBuf::from("/custom/pinned/bin/ghostty");
        let resources = PathBuf::from("/custom/pinned/share/ghostty");
        let candidates = ghostty_installation_candidates(
            Some(explicit.clone()),
            Some(resources.clone()),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
            Some(Path::new("/Users/tester")),
            Some(PathBuf::from("/usr/local/bin/ghostty")),
        );

        assert_eq!(candidates[0].binary, explicit);
        assert_eq!(candidates[0].resources_dir, Some(resources));
    }

    #[test]
    fn inherited_resource_hint_does_not_outrank_pinned_installation() {
        let home = Path::new("/Users/tester");
        let inherited_resources =
            PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            Some(inherited_resources),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
            Some(home),
            Some(PathBuf::from("/usr/local/bin/ghostty")),
        );
        let pinned = home
            .join("Applications")
            .join("Ghostty-cmux-pinned.app")
            .join("Contents")
            .join("MacOS")
            .join("ghostty");
        let inherited_helper = Path::new("/Applications/cmux.app/Contents/Resources/bin/ghostty");

        assert!(position(&candidates, &pinned) < position(&candidates, inherited_helper));
    }

    #[test]
    fn packaged_theme_resources_precede_legacy_ghostty_resources() {
        let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
        let home = Path::new("/Users/tester");
        let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
        let inherited = PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            Some(inherited.clone()),
            Some(browser),
            Some(home),
            Some(path_binary),
        )
        .into_iter()
        .filter_map(|candidate| candidate.resources_dir)
        .collect::<Vec<_>>();

        let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty");
        let pinned = Path::new(
            "/Users/tester/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty",
        );
        let global_pinned =
            Path::new("/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty");
        let system = Path::new("/Applications/Ghostty.app/Contents/Resources/ghostty");
        let position = |expected: &Path| {
            candidates
                .iter()
                .position(|candidate| candidate == expected)
                .unwrap_or_else(|| panic!("missing Ghostty resources {}", expected.display()))
        };
        assert!(position(packaged) < position(pinned));
        assert!(position(pinned) < position(&inherited));
        assert!(position(global_pinned) < position(&inherited));
        assert!(position(pinned) < position(system));
    }

    #[test]
    fn derives_resource_paths_for_app_bundle_and_packaged_helper() {
        assert_eq!(
            ghostty_resources_for_binary(Path::new(
                "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            )),
            Some(PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty"))
        );
        assert_eq!(
            ghostty_resources_for_binary(Path::new(
                "/Applications/cmux-browser.app/Contents/Resources/bin/ghostty"
            )),
            Some(PathBuf::from("/Applications/cmux-browser.app/Contents/Resources/ghostty"))
        );
    }
}
