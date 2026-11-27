//! The server's environment allowlist.
//!
//! The server reads only `CMUX_APP_ID`, `CMUX_APP_DATA_DIR`, `TMPDIR` and
//! `LANG` ([`AppEnv::from_process`] is the only environment read in this
//! crate). It starts no child process: a machine's streams go to the Mac
//! app's carrier socket (crate::link::dial).

use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};

/// The only variables the server reads.
pub const ALLOWED_VARS: [&str; 4] = ["CMUX_APP_ID", "CMUX_APP_DATA_DIR", "TMPDIR", "LANG"];

/// The allowlisted environment of this server.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AppEnv {
    app_id: Option<String>,
    data_dir: Option<PathBuf>,
    tmpdir: Option<String>,
    lang: Option<String>,
}

impl AppEnv {
    /// Reads the allowlisted variables of this process. The only
    /// environment read of the server.
    pub fn from_process() -> Self {
        Self::from_vars(
            ALLOWED_VARS.iter().filter_map(|key| std::env::var_os(key).map(|value| (*key, value))),
        )
    }

    /// Builds the environment from `vars`, ignoring every variable that is
    /// not allowlisted. Values that are not UTF-8 are dropped.
    pub fn from_vars<I, K, V>(vars: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<OsStr>,
    {
        let mut env = Self::default();
        for (key, value) in vars {
            let Some(text) = value.as_ref().to_str().map(str::to_owned) else { continue };
            match key.as_ref() {
                "CMUX_APP_ID" => env.app_id = Some(text),
                "CMUX_APP_DATA_DIR" => {
                    env.data_dir = Some(PathBuf::from(text)).filter(|p| usable_path(p));
                }
                "TMPDIR" => env.tmpdir = Some(text).filter(|t| usable_path(Path::new(t))),
                "LANG" => env.lang = Some(text).filter(|l| !l.chars().any(char::is_control)),
                _ => {}
            }
        }
        env
    }

    pub fn app_id(&self) -> Option<&str> {
        self.app_id.as_deref()
    }

    /// The app's data folder (absolute), when the host gave one.
    pub fn data_dir(&self) -> Option<&Path> {
        self.data_dir.as_deref()
    }

    /// `LANG`, when the host set a usable one.
    pub fn lang(&self) -> Option<&str> {
        self.lang.as_deref()
    }

    /// The temporary folder for short socket paths: `TMPDIR`, else `/tmp`.
    pub fn temp_dir(&self) -> PathBuf {
        self.tmpdir.as_deref().map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
    }
}

/// An absolute path with no `"`, `$` or control characters.
fn usable_path(path: &Path) -> bool {
    let text = path.to_string_lossy();
    path.is_absolute() && !text.contains(['"', '$']) && !text.chars().any(char::is_control)
}

/// Creates `path` (and its parents) and makes the folder owner-only.
pub(crate) fn private_dir(path: &Path) -> io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
