//! Platform decisions for cmux-tui.

use std::fs::{File, OpenOptions};
use std::path::{Component, Path, PathBuf};

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

/// Short, private runtime directory used when environment-selected runtime
/// roots cannot fit Darwin's Unix-domain socket path limit.
pub fn short_runtime_dir() -> PathBuf {
    #[cfg(not(windows))]
    {
        PathBuf::from("/tmp").join(format!("cmux-tui-{}", user_id_component()))
    }
    #[cfg(windows)]
    {
        std::env::temp_dir().join(format!("cmux-tui-{}", user_id_component()))
    }
}

/// Environment-independent runtime directory for the macOS app service.
///
/// The Swift client derives the same per-user path. Keeping this separate from
/// [`runtime_dir`] prevents launchd and the app from choosing different sockets
/// when their `XDG_RUNTIME_DIR` or `TMPDIR` environments differ.
pub fn app_service_runtime_dir() -> PathBuf {
    short_runtime_dir()
}

/// Environment-independent persistent-state directory for the macOS app service.
///
/// The native account database is authoritative instead of `HOME`, because the
/// launch agent and app may receive different environment dictionaries.
pub fn app_service_state_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        native_home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("state")
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        state_dir()
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

/// Candidate Ghostty executables, in the order cmux-tui should probe them.
///
/// `GHOSTTY_BIN` is useful for packaged and development installations; the
/// remaining paths cover the standard CLI and macOS app bundles.
pub fn ghostty_binary_paths() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env_path("GHOSTTY_BIN") {
        push_unique(&mut candidates, path);
    }
    if let Some(path) = find_on_path(&["ghostty"]) {
        push_unique(&mut candidates, path);
    }
    push_unique(&mut candidates, PathBuf::from("/Applications/Ghostty.app/Contents/MacOS/ghostty"));
    push_unique(
        &mut candidates,
        PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/ghostty"),
    );
    candidates.retain(|path| is_executable_file(path));
    candidates
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
    push_unique(
        &mut candidates,
        PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
    );
    push_unique(
        &mut candidates,
        PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty/themes"),
    );
    candidates
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

/// Create a dedicated private directory without changing permissions on any
/// preexisting directory.
///
/// Existing targets must already be real directories owned by the current
/// user with mode `0700`. Missing path components are created one at a time
/// with mode `0700`. Group/world-writable non-sticky ancestors and
/// user-controlled symlink components are rejected before creation.
pub fn ensure_private_directory(path: &Path) -> std::io::Result<()> {
    let absolute = normalized_absolute_path(path)?;
    validate_path_symlinks(&absolute)?;

    match std::fs::symlink_metadata(&absolute) {
        Ok(metadata) => return validate_private_directory_metadata(&absolute, &metadata),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let mut missing = Vec::new();
    let mut cursor = absolute.as_path();
    let ancestor = loop {
        match std::fs::symlink_metadata(cursor) {
            Ok(metadata)
                if metadata.file_type().is_symlink() && trusted_system_symlink(&metadata) =>
            {
                let canonical = std::fs::canonicalize(cursor)?;
                let target_metadata = std::fs::metadata(&canonical)?;
                validate_creation_ancestor(&canonical, &target_metadata)?;
                break canonical;
            }
            Ok(metadata) => {
                validate_creation_ancestor(cursor, &metadata)?;
                break cursor.to_path_buf();
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(cursor.to_path_buf());
                cursor = cursor.parent().ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidInput,
                        format!("private directory has no existing ancestor: {}", path.display()),
                    )
                })?;
            }
            Err(error) => return Err(error),
        }
    };

    let mut parent = ancestor;
    for directory in missing.into_iter().rev() {
        create_private_directory(&directory)?;
        validate_private_directory(&directory)?;
        sync_created_directory_parent(&parent)?;
        parent = directory;
    }
    Ok(())
}

/// Validate that `path` is a real, current-user-owned `0700` directory.
pub fn validate_private_directory(path: &Path) -> std::io::Result<()> {
    let absolute = normalized_absolute_path(path)?;
    validate_path_symlinks(&absolute)?;
    let metadata = std::fs::symlink_metadata(&absolute)?;
    validate_private_directory_metadata(&absolute, &metadata)
}

pub(crate) fn private_file_open_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    options
}

pub(crate) fn reject_private_file_symlink(path: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("refusing private file symbolic link: {}", path.display()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub(crate) fn validate_private_file(path: &Path, file: &File) -> std::io::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("private file is not a regular file: {}", path.display()),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        validate_private_attributes(
            path,
            "file",
            metadata.uid(),
            metadata.permissions().mode() & 0o777,
            0o600,
        )?;
        if metadata.nlink() != 1 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "private file must have exactly one hard link, found {}: {}",
                    metadata.nlink(),
                    path.display()
                ),
            ));
        }
    }
    Ok(())
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

    #[cfg(unix)]
    #[test]
    fn app_service_runtime_path_is_short_and_user_scoped() {
        assert_eq!(
            app_service_runtime_dir(),
            PathBuf::from("/tmp").join(format!("cmux-tui-{}", unsafe { libc::getuid() }))
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn app_service_state_uses_native_absolute_home() {
        let state = app_service_state_dir().expect("native account home");
        assert!(state.is_absolute());
        assert!(state.ends_with("Library/Application Support/cmux-tui/state"));
    }

    #[cfg(unix)]
    #[test]
    fn private_attribute_policy_rejects_foreign_owners_and_broad_modes() {
        let current_user = unsafe { libc::geteuid() };
        let foreign_user = current_user.wrapping_add(1);
        let path = Path::new("fixture");

        let foreign = validate_private_attributes(path, "directory", foreign_user, 0o700, 0o700)
            .expect_err("foreign owner must fail");
        assert_eq!(foreign.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(foreign.to_string().contains("must be owned"));

        let broad = validate_private_attributes(path, "directory", current_user, 0o755, 0o700)
            .expect_err("broad mode must fail");
        assert_eq!(broad.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(broad.to_string().contains("must have mode 0700"));
    }

    #[cfg(unix)]
    #[test]
    fn unix_transport_retains_kernel_peer_credentials() {
        let directory = PathBuf::from("/tmp").join(format!(
            "cmux-peer-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        ensure_private_directory(&directory).unwrap();
        let socket = directory.join("peer.sock");
        let listener = transport::listen(&socket).unwrap();
        let client = transport::connect(&socket).unwrap();
        let server = listener.accept().unwrap();

        let credentials = server.peer_credentials().unwrap().expect("Unix peer credentials");
        assert_eq!(credentials.user_id, unsafe { libc::geteuid() });
        assert_eq!(credentials.group_id, unsafe { libc::getegid() });
        #[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
        assert_eq!(credentials.process_id, Some(std::process::id()));

        drop(server);
        drop(client);
        drop(listener);
        std::fs::remove_file(socket).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
