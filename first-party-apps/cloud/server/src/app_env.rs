//! The server's environment allowlist and the environment of its child
//! processes.
//!
//! The server reads only `CMUX_APP_ID`, `CMUX_APP_DATA_DIR`, `TMPDIR` and
//! `LANG` ([`AppEnv::from_process`] is the only environment read in this
//! crate). Every child (the link, `ssh`, `scp`, `ssh-agent`, `ssh-add`)
//! starts from an empty environment plus [`AppEnv::child_env`]: `TMPDIR`
//! and `LANG` when set, and `HOME` = an owner-only folder under the app's
//! data folder, so no child reads the user's home (`~/.ssh` included).
//! OpenSSH files live in `<data>/ssh` ([`AppEnv::ssh_files`]).

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

/// The OpenSSH files of this app: a server-owned config and the pinned
/// host keys. Every `ssh` and `scp` invocation names both.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SshFiles {
    /// `<data>/ssh/config` (`-F`).
    pub config: PathBuf,
    /// `<data>/ssh/known_hosts` (`UserKnownHostsFile`).
    pub known_hosts: PathBuf,
}

/// Content of `<data>/ssh/config`: every option is on the command line,
/// so the file only stops OpenSSH from reading any other config.
const SSH_CONFIG: &str = "# Owned by the cmux Cloud app. Options are passed on the command line.\n";

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

    /// The temporary folder for short socket paths: `TMPDIR`, else `/tmp`.
    pub fn temp_dir(&self) -> PathBuf {
        self.tmpdir.as_deref().map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
    }

    fn require_data_dir(&self) -> io::Result<&Path> {
        self.data_dir().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "cmux gave the Cloud app no data folder")
        })
    }

    /// The whole environment of a child process: `TMPDIR` and `LANG` when
    /// set, and `HOME` = `<data>/home` (created owner-only).
    pub fn child_env(&self) -> io::Result<Vec<(String, String)>> {
        let home = self.require_data_dir()?.join("home");
        private_dir(&home)?;
        let home = home.to_str().ok_or_else(|| io::Error::other("the data folder is not UTF-8"))?;
        let mut env = vec![("HOME".to_owned(), home.to_owned())];
        if let Some(lang) = &self.lang {
            env.push(("LANG".to_owned(), lang.clone()));
        }
        if let Some(tmpdir) = &self.tmpdir {
            env.push(("TMPDIR".to_owned(), tmpdir.clone()));
        }
        Ok(env)
    }

    /// `<data>/ssh` (owner-only) with the server-owned `config` (written
    /// each time, so its content is always this server's) and the path of
    /// `known_hosts`.
    pub fn ssh_files(&self) -> io::Result<SshFiles> {
        let dir = self.require_data_dir()?.join("ssh");
        private_dir(&dir)?;
        let config = dir.join("config");
        write_private(&config, SSH_CONFIG.as_bytes())?;
        Ok(SshFiles { config, known_hosts: dir.join("known_hosts") })
    }
}

/// An absolute path that OpenSSH option values can carry: `"` would end
/// the quoting and `$` starts `${VAR}` expansion (OpenSSH 8.4+), so both
/// are refused, as are control characters.
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

/// Replaces `path` with `bytes` (owner read and write only): written to a
/// sibling, then renamed, so a reader sees the old file or the new one.
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let staging = path.with_file_name(format!(".{name}.cmux-{}", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let written = options.open(&staging).and_then(|mut file| {
        file.write_all(bytes)?;
        file.sync_all()
    });
    let renamed = written.and_then(|()| std::fs::rename(&staging, path));
    if renamed.is_err() {
        let _ = std::fs::remove_file(&staging);
    }
    renamed
}
