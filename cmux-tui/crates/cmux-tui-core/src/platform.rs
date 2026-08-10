//! Platform decisions for cmux-tui.

use std::fs::File;
#[cfg(windows)]
use std::fs::OpenOptions;
use std::io;
use std::path::{Path, PathBuf};

pub mod transport {
    use std::io::{self, Read, Write};
    use std::net::Shutdown;
    use std::path::Path;
    use std::time::Duration;

    /// Kernel-authenticated identity of the process connected to a local
    /// transport stream.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct PeerCredentials {
        pub process_id: Option<u32>,
        pub user_id: u32,
        pub group_id: u32,
    }

    pub trait Stream: Read + Write + Send + Sync {
        fn try_clone_box(&self) -> io::Result<Box<dyn Stream>>;
        fn peer_credentials(&self) -> io::Result<Option<PeerCredentials>>;
        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn shutdown(&self, how: Shutdown) -> io::Result<()>;
    }

    pub struct Listener {
        inner: imp::Listener,
    }

    pub fn listen(path: &Path) -> io::Result<Listener> {
        super::validate_unix_socket_path(path)?;
        imp::listen(path).map(|inner| Listener { inner })
    }

    pub fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
        super::validate_unix_socket_path(path)?;
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
        use std::os::fd::AsRawFd;
        use std::os::unix::net::{UnixListener, UnixStream};
        use std::path::Path;
        use std::time::Duration;

        use super::{PeerCredentials, Stream};

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

            fn peer_credentials(&self) -> io::Result<Option<PeerCredentials>> {
                peer_credentials(self).map(Some)
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

        #[cfg(any(target_os = "linux", target_os = "android"))]
        fn peer_credentials(stream: &UnixStream) -> io::Result<PeerCredentials> {
            use std::mem::{MaybeUninit, size_of};

            let mut credentials = MaybeUninit::<libc::ucred>::uninit();
            let mut length = size_of::<libc::ucred>() as libc::socklen_t;
            let status = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    credentials.as_mut_ptr().cast(),
                    &mut length,
                )
            };
            if status != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::ucred>() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "kernel returned an invalid Unix peer credential length",
                ));
            }
            let credentials = unsafe { credentials.assume_init() };
            Ok(PeerCredentials {
                process_id: u32::try_from(credentials.pid).ok(),
                user_id: credentials.uid,
                group_id: credentials.gid,
            })
        }

        #[cfg(any(
            target_os = "macos",
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly"
        ))]
        fn peer_credentials(stream: &UnixStream) -> io::Result<PeerCredentials> {
            let mut user_id = 0;
            let mut group_id = 0;
            let status =
                unsafe { libc::getpeereid(stream.as_raw_fd(), &mut user_id, &mut group_id) };
            if status != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(PeerCredentials { process_id: peer_process_id(stream)?, user_id, group_id })
        }

        #[cfg(target_os = "macos")]
        fn peer_process_id(stream: &UnixStream) -> io::Result<Option<u32>> {
            use std::mem::size_of;

            let mut process_id = 0 as libc::pid_t;
            let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
            let status = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_LOCAL,
                    libc::LOCAL_PEERPID,
                    (&mut process_id as *mut libc::pid_t).cast(),
                    &mut length,
                )
            };
            if status != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::pid_t>() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "kernel returned an invalid Unix peer process credential length",
                ));
            }
            Ok(u32::try_from(process_id).ok())
        }

        #[cfg(any(
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly"
        ))]
        fn peer_process_id(_stream: &UnixStream) -> io::Result<Option<u32>> {
            Ok(None)
        }

        #[cfg(not(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly"
        )))]
        fn peer_credentials(_stream: &UnixStream) -> io::Result<PeerCredentials> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Unix peer credentials are unavailable on this platform",
            ))
        }
    }

    #[cfg(windows)]
    mod imp {
        use std::io;
        use std::path::Path;
        use std::time::Duration;

        use super::{PeerCredentials, Stream};
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

            fn peer_credentials(&self) -> io::Result<Option<PeerCredentials>> {
                Ok(None)
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

/// Darwin's `sockaddr_un.sun_path` stores at most 103 filesystem bytes plus
/// its trailing NUL. Validate before bind/connect so the daemon and every
/// client reject the same path instead of relying on platform-specific errors.
pub fn validate_unix_socket_path(path: &Path) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;

        const DARWIN_UNIX_SOCKET_PATH_MAX: usize = 103;
        let bytes = path.as_os_str().as_bytes().len();
        if bytes > DARWIN_UNIX_SOCKET_PATH_MAX {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!(
                    "Unix socket path is {bytes} bytes; Darwin permits at most {DARWIN_UNIX_SOCKET_PATH_MAX}: {}",
                    path.display()
                ),
            ));
        }
    }
    Ok(())
}

pub fn unix_socket_path_fits(path: &Path) -> bool {
    validate_unix_socket_path(path).is_ok()
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

/// Persistent daemon-state directory, honoring an explicit environment
/// override before platform conventions. This is separate from the runtime
/// socket directory because its contents survive process and machine restarts.
pub fn state_dir() -> Option<PathBuf> {
    if let Some(path) = env_path("CMUX_TUI_STATE_DIR") {
        return Some(path);
    }
    #[cfg(target_os = "macos")]
    {
        home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("state")
        })
    }
    #[cfg(target_os = "linux")]
    {
        env_path("XDG_STATE_HOME")
            .map(|state_home| state_home.join("cmux-tui"))
            .or_else(|| home_dir().map(|home| home.join(".local/state/cmux-tui")))
    }
    #[cfg(windows)]
    {
        env_path("LOCALAPPDATA").map(|dir| dir.join("cmux-tui").join("state"))
    }
    #[cfg(all(not(target_os = "macos"), not(target_os = "linux"), not(windows)))]
    {
        env_path("XDG_STATE_HOME")
            .map(|state_home| state_home.join("cmux-tui"))
            .or_else(|| home_dir().map(|home| home.join(".local/state/cmux-tui")))
    }
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

pub fn restrict_directory(path: &Path) -> io::Result<()> {
    restrict_permissions(path, 0o700)
}

pub fn restrict_file(path: &Path) -> io::Result<()> {
    restrict_permissions(path, 0o600)
}

pub fn sync_directory(path: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        if std::fs::metadata(path)?.is_dir() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("not a directory: {}", path.display()),
            ))
        }
    }
    #[cfg(not(windows))]
    {
        File::open(path)?.sync_all()
    }
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

#[cfg(target_os = "macos")]
pub(crate) fn native_home_dir() -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;

    const FALLBACK_BUFFER_SIZE: usize = 16 * 1024;
    const MAX_BUFFER_SIZE: usize = 1024 * 1024;

    let configured_size = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let mut buffer_size = usize::try_from(configured_size)
        .ok()
        .filter(|size| *size > 0)
        .unwrap_or(FALLBACK_BUFFER_SIZE)
        .clamp(1024, MAX_BUFFER_SIZE);

    loop {
        let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0_u8; buffer_size];
        let status = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                record.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == libc::ERANGE && buffer_size < MAX_BUFFER_SIZE {
            buffer_size = (buffer_size * 2).min(MAX_BUFFER_SIZE);
            continue;
        }
        if status != 0 || result.is_null() {
            return None;
        }
        let record = unsafe { record.assume_init() };
        if record.pw_dir.is_null() {
            return None;
        }
        let bytes = unsafe { CStr::from_ptr(record.pw_dir) }.to_bytes();
        return (!bytes.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(bytes)));
    }
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn native_home_dir() -> Option<PathBuf> {
    home_dir()
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

/// Convert a terminal-reported OSC 7 working directory into a local path.
///
/// Shells normally report `file://host/path`. A URI from another host cannot
/// name a safe local spawn directory, so callers should fall back to the
/// surface's original working directory when this returns `None`.
pub fn terminal_pwd_to_local_path(value: &str) -> Option<PathBuf> {
    let plain = Path::new(value);
    if terminal_pwd_path_is_safe(plain) {
        return Some(plain.to_owned());
    }

    let mut url = url::Url::parse(value).ok()?;
    if url.scheme() != "file" {
        return None;
    }
    if let Some(host) = url.host_str()
        && !terminal_pwd_host_is_local(host)
    {
        return None;
    }
    if url.host_str().is_some() {
        url.set_host(Some("localhost")).ok()?;
    }
    url.to_file_path().ok().filter(|path| terminal_pwd_path_is_safe(path))
}

fn terminal_pwd_path_is_safe(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    #[cfg(windows)]
    {
        path.to_str().is_some_and(windows_path_is_rooted_local_drive)
    }
    #[cfg(not(windows))]
    {
        true
    }
}

/// Windows namespaces can make an "absolute" path name a network share or
/// device. OSC 7 inheritance only needs ordinary drive-rooted directories.
#[cfg(any(windows, test))]
fn windows_path_is_rooted_local_drive(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.first().is_some_and(|byte| byte.is_ascii_alphabetic())
        && bytes.get(1) == Some(&b':')
        && bytes.get(2).is_some_and(|separator| matches!(*separator, b'\\' | b'/'))
}

fn terminal_pwd_host_is_local(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host == "127.0.0.1"
        || host == "::1"
        || local_hostname().is_some_and(|local| host.eq_ignore_ascii_case(&local))
}

#[cfg(unix)]
fn local_hostname() -> Option<String> {
    let mut hostname = [0_u8; 256];
    if unsafe { libc::gethostname(hostname.as_mut_ptr().cast(), hostname.len()) } != 0 {
        return None;
    }
    let end = hostname.iter().position(|byte| *byte == 0).unwrap_or(hostname.len());
    std::str::from_utf8(&hostname[..end]).ok().filter(|value| !value.is_empty()).map(str::to_owned)
}

#[cfg(windows)]
fn local_hostname() -> Option<String> {
    std::env::var("COMPUTERNAME").ok().filter(|value| !value.is_empty())
}

fn env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    (!value.is_empty()).then(|| PathBuf::from(value))
}

/// Effective user identifier that owns local daemon trust and private files.
#[cfg(unix)]
pub fn effective_user_id() -> Option<u32> {
    Some(unsafe { libc::geteuid() })
}

/// Windows local transport does not currently expose a comparable numeric UID.
#[cfg(not(unix))]
pub fn effective_user_id() -> Option<u32> {
    None
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

fn normalized_absolute_path(path: &Path) -> std::io::Result<PathBuf> {
    if path.as_os_str().is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "private directory path is empty",
        ));
    }
    if path.components().any(|component| matches!(component, Component::ParentDir)) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("private directory path contains '..': {}", path.display()),
        ));
    }
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn validate_path_symlinks(path: &Path) -> std::io::Result<()> {
    let mut prefix = PathBuf::new();
    for component in path.components() {
        prefix.push(component.as_os_str());
        let metadata = match std::fs::symlink_metadata(&prefix) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_symlink() && !trusted_system_symlink(&metadata) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!("refusing private directory symbolic link: {}", prefix.display()),
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn trusted_system_symlink(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;

    metadata.uid() == 0
}

#[cfg(not(unix))]
fn trusted_system_symlink(_metadata: &std::fs::Metadata) -> bool {
    false
}

fn validate_creation_ancestor(path: &Path, metadata: &std::fs::Metadata) -> std::io::Result<()> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("private directory ancestor is not a real directory: {}", path.display()),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mode = metadata.permissions().mode();
        if mode & 0o022 != 0 && mode & libc::S_ISVTX as u32 == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "private directory ancestor is group/world-writable without the sticky bit: {}",
                    path.display()
                ),
            ));
        }
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;

        builder.mode(0o700);
    }
    match builder.create(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}

fn validate_private_directory_metadata(
    path: &Path,
    metadata: &std::fs::Metadata,
) -> std::io::Result<()> {
    if metadata.file_type().is_symlink() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("refusing private directory symbolic link: {}", path.display()),
        ));
    }
    if !metadata.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("private directory path is not a directory: {}", path.display()),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        validate_private_attributes(
            path,
            "directory",
            metadata.uid(),
            metadata.permissions().mode() & 0o777,
            0o700,
        )?;
    }
    Ok(())
}

#[cfg(unix)]
fn validate_private_attributes(
    path: &Path,
    kind: &str,
    owner: u32,
    mode: u32,
    expected_mode: u32,
) -> std::io::Result<()> {
    let current_user = unsafe { libc::geteuid() };
    if owner != current_user {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!(
                "private {kind} must be owned by uid {current_user}, found uid {owner}: {}",
                path.display()
            ),
        ));
    }
    if mode != expected_mode {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!(
                "private {kind} must have mode {expected_mode:04o}, found {mode:04o}: {}",
                path.display()
            ),
        ));
    }
    Ok(())
}

fn sync_created_directory_parent(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        File::open(path)?.sync_all()?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(unix)]
fn restrict_permissions(path: &Path, mode: u32) -> io::Result<()> {
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

    #[cfg(windows)]
    #[test]
    fn terminal_pwd_rejects_unc_verbatim_and_device_paths() {
        for path in [
            r"\\server\share\src",
            "//server/share/src",
            r"\\?\UNC\server\share\src",
            r"\\.\PhysicalDrive0",
            r"\\?\C:\src",
            r"\??\C:\src",
            r"C:drive-relative",
            r"\rooted-without-drive",
            "file://server/share/src",
            "file:////server/share/src",
        ] {
            assert_eq!(terminal_pwd_to_local_path(path), None, "{path}");
        }
        assert_eq!(
            terminal_pwd_to_local_path(r"C:\Users\alice\src"),
            Some(PathBuf::from(r"C:\Users\alice\src"))
        );
        assert_eq!(
            terminal_pwd_to_local_path("file:///C:/Users/alice/src"),
            Some(PathBuf::from(r"C:\Users\alice\src"))
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_sync_directory_accepts_existing_directory() {
        let root = std::env::temp_dir().join(format!(
            "cmux-sync-directory-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        sync_directory(&root).unwrap();

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn windows_path_classifier_accepts_only_rooted_local_drives() {
        for path in [r"C:\Users\alice\src", "z:/src/cmux", r"D:\"] {
            assert!(windows_path_is_rooted_local_drive(path), "{path}");
        }
        for path in [
            r"\\server\share\src",
            "//server/share/src",
            r"\\?\UNC\server\share\src",
            r"\\.\PhysicalDrive0",
            r"\\?\C:\src",
            r"\??\C:\src",
            r"C:drive-relative",
            r"\rooted-without-drive",
            "/unix/absolute",
            "",
        ] {
            assert!(!windows_path_is_rooted_local_drive(path), "{path}");
        }
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

    #[cfg(unix)]
    #[test]
    fn terminal_pwd_converts_local_osc7_urls_without_trusting_remote_hosts() {
        let mut hostname = [0_u8; 256];
        assert_eq!(unsafe { libc::gethostname(hostname.as_mut_ptr().cast(), hostname.len()) }, 0);
        let hostname_end = hostname.iter().position(|byte| *byte == 0).unwrap_or(hostname.len());
        let hostname = std::str::from_utf8(&hostname[..hostname_end]).unwrap();

        assert_eq!(
            terminal_pwd_to_local_path(&format!("file://{hostname}/tmp/a%20b")),
            Some(PathBuf::from("/tmp/a b"))
        );
        assert_eq!(
            terminal_pwd_to_local_path("file://localhost/tmp/local"),
            Some(PathBuf::from("/tmp/local"))
        );
        assert_eq!(terminal_pwd_to_local_path("/tmp/plain"), Some(PathBuf::from("/tmp/plain")));
        assert_eq!(terminal_pwd_to_local_path("file://remote.invalid/tmp/nope"), None);
    }
}
