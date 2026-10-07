//! The host installer's OpenH264 step (feature `openh264-download`): it
//! downloads Cisco's prebuilt OpenH264 from Cisco's server
//! (ciscobinary.openh264.org) on the user's machine when the host is
//! enabled. Cisco's patent license covers only a binary that each user
//! downloads from Cisco, so the library is never bundled in an app, an image
//! or a release artifact, and never built from source for the product path.
//!
//! Integrity: the decompressed library must have the SHA-256 pinned in
//! [`CiscoBinary`] (Cisco serves the files over plain HTTP, so the pin, not
//! the transport, is the check). Nothing is written when the hash differs.
//!
//! Storage: one file per user, `<data dir>/cmux/openh264/<Cisco file name>`
//! ([`default_dir`]): `$XDG_DATA_HOME` or `~/.local/share` on Linux,
//! `~/Library/Application Support` on macOS, `%LOCALAPPDATA%` on Windows.
//! It is written to a temporary file in the same directory, flushed, and
//! renamed into place, so a reader never sees a partial library.
//!
//! Loading: [`crate::openh264::load_verified`] reads the file, checks the
//! pinned SHA-256 again and only then loads it with `dlopen`
//! (`LoadLibrary` on Windows).

use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::Digest;

use crate::openh264::{CiscoBinary, Platform};

/// Largest compressed download accepted (Cisco's files are under 1 MB).
pub const MAX_COMPRESSED_BYTES: usize = 16 << 20;
/// Largest decompressed library accepted (Cisco's are under 2 MB).
pub const MAX_LIBRARY_BYTES: usize = 64 << 20;
/// Download timeout in seconds.
pub const DOWNLOAD_TIMEOUT_S: u64 = 120;

/// Why the library was not installed.
#[derive(Debug)]
pub enum InstallError {
    /// No per-user data directory is known (no HOME or LOCALAPPDATA).
    NoDataDir,
    Io(std::io::Error),
    /// The download failed or Cisco's server did not answer 200.
    Download(String),
    /// The download or the decompressed library passed its size limit.
    TooLarge,
    /// The download is not a valid bzip2 file.
    Decompress(std::io::Error),
    /// The decompressed library is not Cisco's pinned build.
    HashMismatch {
        expected: &'static str,
        actual: String,
    },
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoDataDir => write!(f, "no per-user data directory (set HOME)"),
            Self::Io(e) => write!(f, "cannot write the OpenH264 library: {e}"),
            Self::Download(e) => write!(f, "cannot download OpenH264 from Cisco: {e}"),
            Self::TooLarge => write!(f, "the OpenH264 download is larger than expected"),
            Self::Decompress(e) => write!(f, "the OpenH264 download is not a bzip2 file: {e}"),
            Self::HashMismatch { expected, actual } => write!(
                f,
                "the downloaded OpenH264 is not Cisco's pinned build (sha256 {actual}, expected {expected})"
            ),
        }
    }
}

impl std::error::Error for InstallError {}

/// The per-user directory that holds Cisco's library, from the process
/// environment. `None` when no home or local data directory is set.
pub fn default_dir() -> Option<PathBuf> {
    dir_from(std::env::consts::OS, |key| std::env::var_os(key))
}

/// [`default_dir`] for operating system `os` (`std::env::consts::OS`) and
/// an environment lookup. Relative directories are ignored.
pub fn dir_from(os: &str, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    let absolute = |key: &str| env(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let base = match os {
        "windows" => absolute("LOCALAPPDATA")?,
        "macos" => absolute("HOME")?.join("Library").join("Application Support"),
        _ => absolute("XDG_DATA_HOME").or_else(|| Some(absolute("HOME")?.join(".local/share")))?,
    };
    Some(base.join("cmux").join("openh264"))
}

/// Where the library for `platform` lives in `dir`.
pub fn library_path(dir: &Path, platform: Platform) -> PathBuf {
    dir.join(CiscoBinary::for_platform(platform).file_name)
}

/// Downloads Cisco's library for `platform` from Cisco into `dir`, unless
/// a verified copy is already there. Returns the library's path.
pub fn install(dir: &Path, platform: Platform) -> Result<PathBuf, InstallError> {
    install_with(dir, &CiscoBinary::for_platform(platform), download)
}

/// [`install`] with the binary description and the download function
/// given (tests use a local file and a fake fetch).
pub fn install_with(
    dir: &Path,
    binary: &CiscoBinary,
    fetch: impl FnOnce(&str) -> Result<Vec<u8>, InstallError>,
) -> Result<PathBuf, InstallError> {
    let path = dir.join(binary.file_name);
    if std::fs::read(&path).is_ok_and(|bytes| sha256_hex(&bytes) == binary.sha256) {
        return Ok(path);
    }
    let compressed = fetch(binary.url)?;
    if compressed.len() > MAX_COMPRESSED_BYTES {
        return Err(InstallError::TooLarge);
    }
    let mut library = Vec::new();
    bzip2::read::BzDecoder::new(compressed.as_slice())
        .take(MAX_LIBRARY_BYTES as u64 + 1)
        .read_to_end(&mut library)
        .map_err(InstallError::Decompress)?;
    if library.len() > MAX_LIBRARY_BYTES {
        return Err(InstallError::TooLarge);
    }
    let actual = sha256_hex(&library);
    if actual != binary.sha256 {
        return Err(InstallError::HashMismatch { expected: binary.sha256, actual });
    }
    std::fs::create_dir_all(dir).map_err(InstallError::Io)?;
    let tmp = dir.join(format!(".{}.{}.partial", binary.file_name, std::process::id()));
    let written = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(&library)?;
        file.sync_all()?;
        std::fs::rename(&tmp, &path)?;
        // The rename is durable once the directory is flushed (Unix only).
        #[cfg(unix)]
        std::fs::File::open(dir)?.sync_all()?;
        Ok(())
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(InstallError::Io(e));
    }
    Ok(path)
}

/// GETs `url` from Cisco's server (plain HTTP, as Cisco publishes it; the
/// pinned hash is the integrity check), at most [`MAX_COMPRESSED_BYTES`].
/// attohttpc is already in the cmux-tui lockfile; without its TLS features
/// it is a small blocking HTTP/1.1 client.
fn download(url: &str) -> Result<Vec<u8>, InstallError> {
    let response = attohttpc::get(url)
        .timeout(std::time::Duration::from_secs(DOWNLOAD_TIMEOUT_S))
        .send()
        .map_err(|e| InstallError::Download(e.to_string()))?;
    let (status, _, reader) = response.split();
    if status != attohttpc::StatusCode::OK {
        return Err(InstallError::Download(format!("HTTP {status}")));
    }
    let mut body = Vec::new();
    reader
        .take(MAX_COMPRESSED_BYTES as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|e| InstallError::Download(e.to_string()))?;
    if body.len() > MAX_COMPRESSED_BYTES {
        return Err(InstallError::TooLarge);
    }
    Ok(body)
}

fn sha256_hex(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}
