//! The host installer's OpenH264 step (feature `openh264-download`): it
//! downloads Cisco's prebuilt OpenH264 from Cisco's server
//! (ciscobinary.openh264.org) on the user's machine when the host is
//! enabled. Cisco's patent license covers only a binary that each user
//! downloads from Cisco, so the library is never bundled in an app, an image
//! or a release artifact, and never built from source for the product path.
//!
//! Integrity: the download goes over HTTPS (the workspace rustls, webpki
//! roots, certificate verification on),
//! and the decompressed library must have the SHA-256 pinned in
//! [`CiscoBinary`]. Nothing is written when the hash differs.
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

/// Largest compressed download accepted: a little above Cisco's largest
/// 2.6.0 file (linux64, 634,264 bytes).
pub const MAX_COMPRESSED_BYTES: usize = 1 << 20;
/// Largest decompressed library accepted (Cisco's largest is 1,731,128 bytes).
pub const MAX_LIBRARY_BYTES: usize = 4 << 20;
/// Largest HTTP response header accepted.
pub const MAX_HEADER_BYTES: usize = 16 << 10;
/// TCP connect timeout in seconds.
pub const CONNECT_TIMEOUT_S: u64 = 30;
/// Timeout of each socket read or write in seconds.
pub const IO_TIMEOUT_S: u64 = 30;

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

/// GETs `url` from Cisco's server over HTTPS, at most
/// [`MAX_COMPRESSED_BYTES`]. TLS is the cmux-tui workspace's rustls (ring
/// provider, TLS 1.2 and 1.3) with the webpki roots and certificate
/// verification on, so the download adds no TLS stack to any lockfile. The
/// request is one `GET` with `Connection: close` to Cisco's fixed host; the
/// response must be `200` with an identity body (no redirect, no chunked
/// encoding). The pinned SHA-256 stays the integrity check.
fn download(url: &str) -> Result<Vec<u8>, InstallError> {
    use std::net::{TcpStream, ToSocketAddrs};
    use std::sync::Arc;
    use std::time::Duration;

    let fail =
        |what: &str, e: &dyn std::fmt::Display| InstallError::Download(format!("{what}: {e}"));
    let (host, path) =
        split_url(url).ok_or_else(|| InstallError::Download(format!("not an https URL: {url}")))?;
    let timeout = Duration::from_secs(IO_TIMEOUT_S);
    let addr = (host, 443)
        .to_socket_addrs()
        .map_err(|e| fail("resolve", &e))?
        .next()
        .ok_or_else(|| InstallError::Download(format!("{host} has no address")))?;
    let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(CONNECT_TIMEOUT_S))
        .map_err(|e| fail("connect", &e))?;
    tcp.set_read_timeout(Some(timeout)).map_err(|e| fail("socket", &e))?;
    tcp.set_write_timeout(Some(timeout)).map_err(|e| fail("socket", &e))?;
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| fail("tls", &e))?
    .with_root_certificates(roots)
    .with_no_client_auth();
    let name = rustls::pki_types::ServerName::try_from(host.to_owned())
        .map_err(|e| fail("server name", &e))?;
    let conn =
        rustls::ClientConnection::new(Arc::new(config), name).map_err(|e| fail("tls", &e))?;
    let mut tls = rustls::StreamOwned::new(conn, tcp);
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: cmux-rd\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
    );
    tls.write_all(request.as_bytes()).map_err(|e| fail("request", &e))?;
    let mut raw = Vec::new();
    let limit = (MAX_COMPRESSED_BYTES + MAX_HEADER_BYTES + 4) as u64;
    match (&mut tls).take(limit + 1).read_to_end(&mut raw) {
        Ok(_) => {}
        // A server that closes without close_notify: the Content-Length
        // check in parse_response decides whether the body is complete.
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {}
        Err(e) => return Err(fail("response", &e)),
    }
    if raw.len() as u64 > limit {
        return Err(InstallError::TooLarge);
    }
    let body = parse_response(&raw)?;
    if body.len() > MAX_COMPRESSED_BYTES {
        return Err(InstallError::TooLarge);
    }
    Ok(body)
}

/// Host and path of an `https://host/path` URL.
fn split_url(url: &str) -> Option<(&str, &str)> {
    let rest = url.strip_prefix("https://")?;
    let slash = rest.find('/')?;
    let (host, path) = rest.split_at(slash);
    (!host.is_empty()).then_some((host, path))
}

/// The body of a complete HTTP/1.1 response: status 200, no
/// `Transfer-Encoding`, and exactly `Content-Length` bytes when given.
fn parse_response(raw: &[u8]) -> Result<Vec<u8>, InstallError> {
    let bad = |why: &str| InstallError::Download(why.to_owned());
    let window = &raw[..raw.len().min(MAX_HEADER_BYTES + 4)];
    let end = window
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| bad("no HTTP header within the size limit"))?;
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| bad("header is not text"))?;
    let body = &raw[end + 4..];
    if body.len() > MAX_COMPRESSED_BYTES {
        return Err(InstallError::TooLarge);
    }
    let mut lines = head.split("\r\n");
    let status = lines.next().unwrap_or_default();
    let code = status.strip_prefix("HTTP/1.").and_then(|s| s.get(2..5));
    if code != Some("200") {
        return Err(InstallError::Download(format!("Cisco answered {status:?}")));
    }
    let mut length = None;
    for line in lines {
        let Some((key, value)) = line.split_once(':') else { continue };
        let (key, value) = (key.trim().to_ascii_lowercase(), value.trim());
        if key == "transfer-encoding" {
            return Err(bad("chunked or encoded body"));
        }
        if key == "content-length" {
            length = Some(value.parse::<usize>().map_err(|_| bad("bad Content-Length"))?);
        }
    }
    if length.is_some_and(|n| n != body.len()) {
        return Err(bad("body shorter or longer than Content-Length"));
    }
    Ok(body.to_vec())
}

fn sha256_hex(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::{InstallError, MAX_COMPRESSED_BYTES, MAX_HEADER_BYTES, parse_response, split_url};

    #[test]
    fn a_200_response_with_a_matching_length_yields_its_body() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: binary/octet-stream\r\ncontent-length: 5\r\n\r\nhello";
        assert_eq!(parse_response(raw).expect("body"), b"hello");
        let no_length = b"HTTP/1.1 200 OK\r\nServer: AmazonS3\r\n\r\nbytes until close";
        assert_eq!(parse_response(no_length).expect("body"), b"bytes until close");
    }

    #[test]
    fn other_statuses_chunked_bodies_and_short_bodies_are_refused() {
        let cases: [&[u8]; 5] = [
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
            b"HTTP/1.1 301 Moved\r\nLocation: http://x/\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort",
            b"not http at all",
        ];
        for raw in cases {
            assert!(
                matches!(parse_response(raw), Err(InstallError::Download(_))),
                "{}",
                String::from_utf8_lossy(raw)
            );
        }
    }

    #[test]
    fn an_oversize_body_is_refused() {
        let mut raw = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
        raw.resize(raw.len() + MAX_COMPRESSED_BYTES + 1, 0);
        assert!(matches!(parse_response(&raw), Err(InstallError::TooLarge)));
        // The limit sits a little above Cisco's largest 2.6.0 file (634,264 bytes).
        const { assert!(MAX_COMPRESSED_BYTES > 634_264 && MAX_COMPRESSED_BYTES <= 2 << 20) };
    }

    #[test]
    fn a_truncated_body_is_refused() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 634264\r\n\r\nBZh91AY&SY";
        assert!(matches!(parse_response(raw), Err(InstallError::Download(_))));
    }

    #[test]
    fn an_oversize_header_is_refused() {
        let mut raw = b"HTTP/1.1 200 OK\r\nX-Pad: ".to_vec();
        raw.resize(raw.len() + MAX_HEADER_BYTES, b'a');
        raw.extend_from_slice(b"\r\n\r\nbody");
        assert!(matches!(parse_response(&raw), Err(InstallError::Download(_))));
    }

    #[test]
    fn only_https_urls_with_a_host_and_path_are_fetched() {
        assert_eq!(
            split_url("https://ciscobinary.openh264.org/lib.so.bz2"),
            Some(("ciscobinary.openh264.org", "/lib.so.bz2"))
        );
        assert_eq!(split_url("http://ciscobinary.openh264.org/lib.so.bz2"), None);
        assert_eq!(split_url("https://ciscobinary.openh264.org"), None);
        assert_eq!(split_url("https:///lib"), None);
    }
}
