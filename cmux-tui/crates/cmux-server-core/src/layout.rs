//! Install layout: install mode x platform to paths (server.md 4.3).
//!
//! Pure path building from home and environment values the caller read.
//! Store, profiles and `current` follow lane 1's store layout
//! (vm-image.md 4.5): `<root>/store/<sha256>/`, `<root>/profiles/<generation>/`,
//! `<root>/current`.

use crate::platform::{HostPath, InstallMode, Platform};

/// Values the caller reads from the process environment. Unset or empty
/// values are `None`. Relative values are refused (`LayoutError::NotAbsolute`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LayoutEnv {
    /// `HOME` (Linux, macOS) or `USERPROFILE` (Windows).
    pub home: Option<String>,
    pub xdg_data_home: Option<String>,
    pub xdg_state_home: Option<String>,
    pub xdg_config_home: Option<String>,
    /// Windows `%LOCALAPPDATA%`.
    pub local_app_data: Option<String>,
    /// Windows `%APPDATA%`.
    pub app_data: Option<String>,
    /// Windows `%ProgramData%`.
    pub program_data: Option<String>,
    /// Windows `%ProgramFiles%`.
    pub program_files: Option<String>,
    /// macOS only: the app bundle path when the app manages the server
    /// ("Make This Mac a Server"). The binary and the bundled launchd plist
    /// then come from the bundle (server.md 4.3, column "macOS (app)").
    pub mac_app_bundle: Option<String>,
    /// The installing user's numeric id. Required in macOS user mode, where
    /// the Postgres socket lives under `/tmp/cmux-<uid>` (server.md 8.2).
    pub uid: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LayoutError {
    /// A required environment value is missing (`HOME`, `%LOCALAPPDATA%`, …).
    Missing(&'static str),
    /// An environment value is not an absolute path on the target platform.
    NotAbsolute(&'static str),
    /// The macOS app bundle was given for another platform or for system mode.
    AppBundleNotApplicable,
}

/// How the service is registered (server.md 4.3, row "service").
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceKind {
    /// `systemd --user` unit plus `loginctl enable-linger`.
    SystemdUser { unit_path: HostPath },
    /// System unit running as user `cmux`.
    SystemdSystem { unit_path: HostPath },
    /// `~/Library/LaunchAgents/com.cmux.server.plist` (headless Mac).
    LaunchAgent { plist_path: HostPath },
    /// `/Library/LaunchDaemons/com.cmux.server.plist` (runs without a login).
    LaunchDaemon { plist_path: HostPath },
    /// `SMAppService.agent` with the plist bundled in the app.
    AppServiceAgent { bundled_plist: HostPath },
    /// Windows Scheduled Task at logon (user mode).
    ScheduledTask { task_name: &'static str },
    /// Windows service with a virtual account (system mode).
    WindowsService { service_name: &'static str },
}

pub const LAUNCHD_LABEL: &str = "com.cmux.server";
pub const SYSTEMD_UNIT: &str = "cmux-server.service";
pub const WINDOWS_SERVICE: &str = "cmux-server";
pub const SCHEDULED_TASK: &str = "cmux-server";

/// Every path the server uses on one machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    pub mode: InstallMode,
    pub platform: Platform,
    /// Root that holds `store`, `profiles` and `current`.
    pub root: HostPath,
    pub store: HostPath,
    pub profiles: HostPath,
    pub current: HostPath,
    /// The frozen unit command's binary: `<current>/bin/cmux` (`cmux.exe` on
    /// Windows; the bundled CLI on a Mac with the app).
    pub current_cmux: HostPath,
    /// Keys, Postgres, app state, backups.
    pub state: HostPath,
    pub config_file: HostPath,
    pub service: ServiceKind,
    /// The CLI shim (or the bundled CLI on a Mac with the app).
    pub cli_shim: HostPath,
    /// The installing user's numeric id, when known.
    pub uid: Option<u32>,
}

/// Where the supervisor asks the root updater to run in Linux system mode.
pub const UPDATE_REQUEST: &str = "/run/cmux/update-request";

impl Layout {
    /// `<store>/<sha256>`, or `None` unless `sha256_hex` is 64 lowercase hex.
    pub fn store_package(&self, sha256_hex: &str) -> Option<HostPath> {
        crate::manifest::valid_sha256(sha256_hex).then(|| self.store.join(sha256_hex))
    }

    pub fn profile(&self, generation: u64) -> HostPath {
        self.profiles.join(&generation.to_string())
    }

    pub fn postgres_data(&self) -> HostPath {
        self.state.join("postgres/17/data")
    }

    /// Socket directory (server.md 8.2): `/run/cmux/postgres` (0750, group
    /// `cmux-db`) in Linux system mode; `/tmp/cmux-<uid>/pg-<port>` (0700,
    /// owner-checked at every start, see `access::socket_dir_check`) in
    /// macOS user mode, because `<state>` there is too long for the 103-byte
    /// socket path limit; `<state>/postgres/run` (0700) everywhere else.
    pub fn postgres_socket_dir(&self, port: u16) -> HostPath {
        match (self.mode, self.platform, self.uid) {
            (InstallMode::System, Platform::Linux, _) => abs(Platform::Linux, "/run/cmux/postgres"),
            (InstallMode::User, Platform::MacOs, Some(uid)) => {
                abs(Platform::MacOs, &format!("/tmp/cmux-{uid}/pg-{port}"))
            }
            _ => self.state.join("postgres/run"),
        }
    }

    /// Linux system mode: the file whose appearance triggers the root
    /// `cmux-update.path` unit. `None` elsewhere (the service user owns the
    /// store and updates it itself).
    pub fn update_request(&self) -> Option<HostPath> {
        (self.mode == InstallMode::System && self.platform == Platform::Linux)
            .then(|| abs(Platform::Linux, UPDATE_REQUEST))
    }

    /// The admin secret in user mode and on Windows (server.md 8.3).
    pub fn postgres_admin_pgpass(&self) -> HostPath {
        self.state.join("postgres/admin.pgpass")
    }

    pub fn backups(&self) -> HostPath {
        self.state.join("backups")
    }

    pub fn wal_archive(&self) -> HostPath {
        self.state.join("backups/wal")
    }

    pub fn logs(&self) -> HostPath {
        self.state.join("logs")
    }

    /// Per-app state directory. The caller passes a validated app id
    /// (`pg::AppId`), so it is one clean path component.
    pub fn app_state(&self, app: &crate::pg::AppId) -> HostPath {
        self.state.join("apps").join(app.as_str())
    }

    /// `<state>/apps/<app>/pgpass` (0600), user mode only (server.md 8.3).
    pub fn app_pgpass(&self, app: &crate::pg::AppId) -> HostPath {
        self.app_state(app).join("pgpass")
    }
}

/// Computes the layout for `mode` on `platform` from `env`.
pub fn layout(
    mode: InstallMode,
    platform: Platform,
    env: &LayoutEnv,
) -> Result<Layout, LayoutError> {
    if env.mac_app_bundle.is_some() && (platform != Platform::MacOs || mode != InstallMode::User) {
        return Err(LayoutError::AppBundleNotApplicable);
    }
    let uid = env.uid;
    if platform == Platform::MacOs && mode == InstallMode::User && uid.is_none() {
        return Err(LayoutError::Missing("uid"));
    }
    let parts = match (platform, mode) {
        (Platform::Linux, InstallMode::User) => linux_user(env)?,
        (Platform::Linux, InstallMode::System) => linux_system(),
        (Platform::MacOs, InstallMode::User) => macos_user(env)?,
        (Platform::MacOs, InstallMode::System) => macos_system(),
        (Platform::Windows, InstallMode::User) => windows_user(env)?,
        (Platform::Windows, InstallMode::System) => windows_system(env)?,
    };
    let current = parts.root.join("current");
    // With the macOS app, the binary is the app's bundled CLI, not a store
    // profile (server.md 4.3, column "macOS (app)").
    let current_cmux = match parts.service {
        ServiceKind::AppServiceAgent { .. } => parts.cli_shim.clone(),
        _ => current.join("bin").join(platform.cmux_exe()),
    };
    Ok(Layout {
        mode,
        platform,
        store: parts.store,
        profiles: parts.root.join("profiles"),
        current,
        current_cmux,
        root: parts.root,
        state: parts.state,
        config_file: parts.config_file,
        service: parts.service,
        cli_shim: parts.cli_shim,
        uid,
    })
}

struct Parts {
    root: HostPath,
    store: HostPath,
    state: HostPath,
    config_file: HostPath,
    service: ServiceKind,
    cli_shim: HostPath,
}

fn abs(platform: Platform, literal: &str) -> HostPath {
    HostPath::new(platform, literal).expect("absolute literal")
}

fn env_path(
    platform: Platform,
    value: &Option<String>,
    name: &'static str,
) -> Result<Option<HostPath>, LayoutError> {
    match value.as_deref() {
        None | Some("") => Ok(None),
        Some(v) => HostPath::new(platform, v).map(Some).ok_or(LayoutError::NotAbsolute(name)),
    }
}

fn required(
    platform: Platform,
    value: &Option<String>,
    name: &'static str,
) -> Result<HostPath, LayoutError> {
    env_path(platform, value, name)?.ok_or(LayoutError::Missing(name))
}

fn linux_user(env: &LayoutEnv) -> Result<Parts, LayoutError> {
    let p = Platform::Linux;
    let home = required(p, &env.home, "HOME")?;
    let data = env_path(p, &env.xdg_data_home, "XDG_DATA_HOME")?
        .unwrap_or_else(|| home.join(".local/share"));
    let state = env_path(p, &env.xdg_state_home, "XDG_STATE_HOME")?
        .unwrap_or_else(|| home.join(".local/state"));
    let config = env_path(p, &env.xdg_config_home, "XDG_CONFIG_HOME")?
        .unwrap_or_else(|| home.join(".config"));
    let root = data.join("cmux");
    Ok(Parts {
        store: root.join("store"),
        root,
        state: state.join("cmux/server"),
        config_file: config.join("cmux/server.json"),
        service: ServiceKind::SystemdUser {
            unit_path: config.join("systemd/user").join(SYSTEMD_UNIT),
        },
        cli_shim: home.join(".local/bin/cmux"),
    })
}

fn linux_system() -> Parts {
    let p = Platform::Linux;
    let root = abs(p, "/opt/cmux");
    Parts {
        store: root.join("store"),
        root,
        state: abs(p, "/var/lib/cmux"),
        config_file: abs(p, "/etc/cmux/server.json"),
        service: ServiceKind::SystemdSystem {
            unit_path: abs(p, "/etc/systemd/system").join(SYSTEMD_UNIT),
        },
        cli_shim: abs(p, "/usr/local/bin/cmux"),
    }
}

fn macos_user(env: &LayoutEnv) -> Result<Parts, LayoutError> {
    let p = Platform::MacOs;
    let home = required(p, &env.home, "HOME")?;
    let support = home.join("Library/Application Support/cmux");
    let config_file = home.join(".config/cmux/server.json");
    let state = support.join("server");
    let plist = format!("{LAUNCHD_LABEL}.plist");
    match env_path(p, &env.mac_app_bundle, "app bundle")? {
        Some(bundle) => Ok(Parts {
            store: support.join("store"),
            root: support,
            state,
            config_file,
            service: ServiceKind::AppServiceAgent {
                bundled_plist: bundle.join("Contents/Library/LaunchAgents").join(&plist),
            },
            cli_shim: bundle.join("Contents/Resources/bin/cmux"),
        }),
        None => Ok(Parts {
            store: support.join("store"),
            root: support,
            state,
            config_file,
            service: ServiceKind::LaunchAgent {
                plist_path: home.join("Library/LaunchAgents").join(&plist),
            },
            cli_shim: home.join(".local/bin/cmux"),
        }),
    }
}

/// macOS system mode is the LaunchDaemon variant that the
/// `restart.notLoggedIn` fix installs (server.md 9.3). server.md 4.3 has no
/// column for it; these paths are this crate's proposal.
fn macos_system() -> Parts {
    let p = Platform::MacOs;
    let root = abs(p, "/Library/Application Support/cmux");
    Parts {
        store: root.join("store"),
        state: root.join("server"),
        config_file: root.join("server.json"),
        root,
        service: ServiceKind::LaunchDaemon {
            plist_path: abs(p, "/Library/LaunchDaemons").join(&format!("{LAUNCHD_LABEL}.plist")),
        },
        cli_shim: abs(p, "/usr/local/bin/cmux"),
    }
}

fn windows_user(env: &LayoutEnv) -> Result<Parts, LayoutError> {
    let p = Platform::Windows;
    let local = required(p, &env.local_app_data, "LOCALAPPDATA")?;
    let roaming = required(p, &env.app_data, "APPDATA")?;
    let root = local.join("cmux");
    Ok(Parts {
        store: root.join("store"),
        state: root.join("server"),
        cli_shim: root.join("bin/cmux.exe"),
        root,
        config_file: roaming.join("cmux/server.json"),
        service: ServiceKind::ScheduledTask { task_name: SCHEDULED_TASK },
    })
}

/// Windows system mode: binaries and the store under `%ProgramFiles%\cmux`
/// (writable by administrators only), state and config under
/// `%ProgramData%\cmux` with the ACL from `access::access_policy`.
fn windows_system(env: &LayoutEnv) -> Result<Parts, LayoutError> {
    let p = Platform::Windows;
    let data = required(p, &env.program_data, "ProgramData")?;
    let files = required(p, &env.program_files, "ProgramFiles")?;
    let root = files.join("cmux");
    Ok(Parts {
        store: root.join("store"),
        cli_shim: root.join("bin/cmux.exe"),
        root,
        state: data.join("cmux/server"),
        config_file: data.join("cmux/server.json"),
        service: ServiceKind::WindowsService { service_name: WINDOWS_SERVICE },
    })
}
