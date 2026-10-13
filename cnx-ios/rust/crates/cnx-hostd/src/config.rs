//! cnx-hostd configuration, read from the environment (README.md lists
//! every variable).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::auth::{DEFAULT_STACK_API, DEFAULT_STACK_PROJECT, TokenSource};

/// Where the `acpmux` service connects.
#[derive(Debug, Clone)]
pub enum AcpmuxTarget {
    /// Read `websocket.listen` and `websocket.token` from
    /// `<home>/config.json` at every open (the port can move).
    Home(PathBuf),
    /// A fixed URL and token (tests).
    Fixed { url: String, token: Option<String> },
}

/// What the link services may reach.
#[derive(Debug, Clone)]
pub struct ServiceConfig {
    /// `$TMPDIR/cmux-tui-<uid>`: the cmux-tui session sockets.
    pub tui_socket_dir: PathBuf,
    pub default_session: String,
    /// Workspace roots the `file` service may read below. Empty denies all.
    pub file_roots: Vec<PathBuf>,
    pub acpmux: AcpmuxTarget,
}

#[derive(Debug, Clone)]
pub struct HostConfig {
    pub base_url: String,
    pub team_id: String,
    pub device_id: String,
    pub device_name: String,
    pub tokens: TokenSource,
    /// The Stack user whose phones may dial; defaults to the token's `sub`.
    pub owner_user_id: Option<String>,
    pub include_loopback: bool,
    /// Never offer or use 100.64.0.0/10 (Tailscale) addresses.
    pub exclude_cgnat: bool,
    pub services: ServiceConfig,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())
}

fn env_or_file(name: &str) -> Result<Option<String>> {
    if let Some(value) = env(name) {
        return Ok(Some(value));
    }
    if let Some(path) = env(&format!("{name}_FILE")) {
        let text = std::fs::read_to_string(&path).with_context(|| format!("reading {name}_FILE {path}"))?;
        return Ok(Some(text.trim().to_owned()).filter(|v| !v.is_empty()));
    }
    Ok(None)
}

pub fn default_tui_socket_dir() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    tmp.join(format!("cmux-tui-{uid}"))
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

pub fn default_state_dir() -> PathBuf {
    env("CNX_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("Library/Application Support/cnx-hostd"))
}

fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates
    // on success when the name fits.
    let ok = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0;
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(0);
    if ok && end > 0 { String::from_utf8_lossy(&buffer[..end]).into_owned() } else { "Mac".into() }
}

/// A persistent device id: a UUID stored in `<state>/device-id`.
pub fn persistent_device_id(state_dir: &Path) -> Result<String> {
    let path = state_dir.join("device-id");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Ok(id) = uuid::Uuid::parse_str(text.trim())
    {
        return Ok(id.to_string());
    }
    std::fs::create_dir_all(state_dir).with_context(|| format!("creating {}", state_dir.display()))?;
    let id = uuid::Uuid::new_v4().to_string();
    std::fs::write(&path, &id).with_context(|| format!("writing {}", path.display()))?;
    Ok(id)
}

impl HostConfig {
    pub fn from_env() -> Result<Self> {
        let base_url = env("CNX_BASE_URL").context("CNX_BASE_URL is required")?;
        let team_id = env("CNX_TEAM_ID").context("CNX_TEAM_ID is required")?;
        let tokens = if let Some(refresh_token) = env_or_file("CNX_REFRESH_TOKEN")? {
            TokenSource::Refresh {
                refresh_token,
                project_id: env("CNX_STACK_PROJECT_ID").unwrap_or_else(|| DEFAULT_STACK_PROJECT.into()),
                publishable_key: env("CNX_STACK_PUBLISHABLE_KEY"),
                api: env("CNX_STACK_API").unwrap_or_else(|| DEFAULT_STACK_API.into()),
            }
        } else if let Some(token) = env_or_file("CNX_ACCESS_TOKEN")? {
            TokenSource::Access(token)
        } else {
            bail!("set CNX_REFRESH_TOKEN(_FILE) or CNX_ACCESS_TOKEN(_FILE)");
        };
        let device_id = match env("CNX_DEVICE_ID") {
            Some(id) => id,
            None => persistent_device_id(&default_state_dir())?,
        };
        let acpmux = match env("CNX_ACPMUX_URL") {
            Some(url) => AcpmuxTarget::Fixed { url, token: env("CNX_ACPMUX_TOKEN") },
            None => AcpmuxTarget::Home(
                env("ACPMUX_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".acpmux")),
            ),
        };
        let file_roots = env("CNX_FILE_ROOTS")
            .map(|roots| roots.split(':').filter(|r| !r.is_empty()).map(PathBuf::from).collect())
            .unwrap_or_default();
        Ok(Self {
            base_url,
            team_id,
            device_id,
            device_name: env("CNX_DEVICE_NAME").unwrap_or_else(hostname),
            tokens,
            owner_user_id: env("CNX_OWNER_USER_ID"),
            include_loopback: env("CNX_INCLUDE_LOOPBACK").is_some_and(|v| v == "1"),
            exclude_cgnat: env("CNX_EXCLUDE_CGNAT").is_some_and(|v| v == "1"),
            services: ServiceConfig {
                tui_socket_dir: env("CNX_TUI_SOCKET_DIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(default_tui_socket_dir),
                default_session: env("CNX_TUI_SESSION").unwrap_or_else(|| "main".into()),
                file_roots,
                acpmux,
            },
        })
    }
}
