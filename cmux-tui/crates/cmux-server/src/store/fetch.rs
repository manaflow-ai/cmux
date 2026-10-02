//! Downloads with a streaming SHA-256 and an exact size.
//!
//! [`HttpsFetcher`] refuses every URL that is not `https://` (also after a
//! redirect) unless it was built with [`HttpsFetcher::allowing_http`], which
//! only tests use. The core manifest check already refuses non-HTTPS package
//! URLs; this is the second layer.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::Duration;

use sha2::{Digest, Sha256};

use crate::error::{Error, IoContext, Result};

/// Opens a URL for reading.
pub trait Fetch: Send + Sync {
    fn open(&self, url: &str) -> Result<Box<dyn Read + Send>>;
}

/// The scheme and authority rules: `https://host[:port]/…` without userinfo
/// (`https://cmux.com@evil.example/` is refused), `http://` only when
/// `allow_http`.
pub fn check_url(url: &str, allow_http: bool) -> Result<()> {
    let rest = match url.split_once("://") {
        Some(("https", rest)) => rest,
        Some(("http", rest)) if allow_http => rest,
        _ => return Err(Error::rejected(format!("refusing a non-HTTPS URL: {url}"))),
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty()
        || authority.contains('@')
        || url.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err(Error::rejected(format!("refusing a malformed URL: {url}")));
    }
    Ok(())
}

pub struct HttpsFetcher {
    client: reqwest::blocking::Client,
    allow_http: bool,
}

impl HttpsFetcher {
    /// HTTPS only, redirects included.
    pub fn new() -> Result<HttpsFetcher> {
        HttpsFetcher::build(false)
    }

    /// Also accepts `http://`. Tests and local test channels only.
    pub fn allowing_http() -> Result<HttpsFetcher> {
        HttpsFetcher::build(true)
    }

    fn build(allow_http: bool) -> Result<HttpsFetcher> {
        // reqwest is built without a default crypto provider; the tree
        // already carries ring through rustls.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::blocking::Client::builder()
            .https_only(!allow_http)
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(30 * 60))
            .user_agent(concat!("cmux-server/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| Error::internal(format!("HTTP client: {e}")))?;
        Ok(HttpsFetcher { client, allow_http })
    }
}

impl Fetch for HttpsFetcher {
    fn open(&self, url: &str) -> Result<Box<dyn Read + Send>> {
        check_url(url, self.allow_http)?;
        let response = self
            .client
            .get(url)
            .send()
            .and_then(reqwest::blocking::Response::error_for_status)
            .map_err(|e| Error::unreachable(format!("download {url}: {e}")))?;
        Ok(Box::new(response))
    }
}

/// Reads at most `limit` bytes of `url` into memory (manifests and
/// signatures). More than `limit` bytes is refused.
pub fn fetch_small(fetcher: &dyn Fetch, url: &str, limit: u64) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    fetcher
        .open(url)?
        .take(limit + 1)
        .read_to_end(&mut out)
        .map_err(|e| Error::unreachable(format!("download {url}: {e}")))?;
    if out.len() as u64 > limit {
        return Err(Error::rejected(format!("{url} is larger than {limit} bytes")));
    }
    Ok(out)
}

/// Streams `url` into the new file `dest` (0600) and checks that it has
/// exactly `size` bytes and SHA-256 `sha256_hex`. Never reads more than
/// `size + 1` bytes. On any mismatch `dest` is removed.
pub fn download_verified(
    fetcher: &dyn Fetch,
    url: &str,
    size: u64,
    sha256_hex: &str,
    dest: &Path,
) -> Result<()> {
    let result = (|| {
        let mut file = create_private(dest).ctx(dest.display())?;
        let reader = fetcher.open(url)?;
        let (written, digest) = copy_hashing(reader.take(size + 1), &mut file)
            .map_err(|e| Error::unreachable(format!("download {url}: {e}")))?;
        file.sync_all().ctx(dest.display())?;
        if written != size {
            return Err(Error::verification(format!(
                "size mismatch for {url}: expected {size} bytes, got {}{}",
                written.min(size),
                if written > size { " or more" } else { "" }
            )));
        }
        let actual = crate::host::hex(&digest);
        if actual != sha256_hex {
            return Err(Error::verification(format!(
                "SHA-256 mismatch for {url}: expected {sha256_hex}, got {actual}"
            )));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(dest);
    }
    result
}

fn create_private(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn copy_hashing(mut reader: impl Read, out: &mut impl Write) -> io::Result<(u64, [u8; 32])> {
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n])?;
        total += n as u64;
    }
    Ok((total, hasher.finalize().into()))
}
