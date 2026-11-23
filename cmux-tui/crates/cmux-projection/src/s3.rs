//! An S3-compatible bucket as one more blob tier (hq RFD 0054, option C: Cursor-style object
//! storage under our own forge; Scion's server tier). Any store that speaks S3's signed `GET` and
//! `PUT` works: Cloudflare R2, MinIO, Garage, Ceph, AWS S3. A blob lives at
//! `<base>/objects/<id>`, where `<base>` is the endpoint, the bucket and an optional prefix in path
//! style (`https://ACCOUNT.r2.cloudflarestorage.com/BUCKET/fleet`). Every request is signed with
//! AWS Signature Version 4, so the secret never leaves the host. Objects are content-addressed and
//! immutable, so a cache in front of the bucket never needs invalidating, and every answer is still
//! hashed against its id by the chain ([`crate::peers`]): the bucket is untrusted transport.

use hmac::{Hmac, Mac as _};
use sha2::{Digest as _, Sha256};

/// The service name S3 signs with.
pub const SERVICE: &str = "s3";
/// The sha256 of an empty body: what a signed `GET` declares as its payload.
pub const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// An access key pair and the region it signs for (`auto` for R2, `us-east-1` for MinIO's default).
#[derive(Clone, PartialEq, Eq)]
pub struct Key {
    pub id: String,
    pub secret: String,
    pub region: String,
}

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never the secret, so a key in a log line or a panic message leaks nothing.
        f.debug_struct("Key").field("id", &self.id).field("region", &self.region).finish()
    }
}

impl Key {
    /// The key from a `KEY=VALUE` file (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
    /// optionally `AWS_REGION`; blank lines and `#` comments skipped), or `None` when either half
    /// is missing.
    #[must_use]
    pub fn parse(text: &str, default_region: &str) -> Option<Self> {
        let mut id = None;
        let mut secret = None;
        let mut region = None;
        for line in text.lines().map(str::trim) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let line = line.strip_prefix("export ").unwrap_or(line);
            let Some((name, value)) = line.split_once('=') else { continue };
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'').to_owned();
            match name.trim() {
                "AWS_ACCESS_KEY_ID" => id = Some(value),
                "AWS_SECRET_ACCESS_KEY" => secret = Some(value),
                "AWS_REGION" | "AWS_DEFAULT_REGION" => region = Some(value),
                _ => {}
            }
        }
        Some(Self {
            id: id.filter(|id| !id.is_empty())?,
            secret: secret.filter(|secret| !secret.is_empty())?,
            region: region.unwrap_or_else(|| default_region.to_owned()),
        })
    }
}

/// `(YYYYMMDDTHHMMSSZ, YYYYMMDD)` for a Unix time in seconds, in UTC.
#[must_use]
pub fn amz_date(unix_s: u64) -> (String, String) {
    let days = unix_s / 86_400;
    let rest = unix_s % 86_400;
    let (year, month, day) = civil(days);
    let date = format!("{year:04}{month:02}{day:02}");
    let stamp = format!("{date}T{:02}{:02}{:02}Z", rest / 3_600, rest % 3_600 / 60, rest % 60);
    (stamp, date)
}

/// The proleptic Gregorian date of a day count since 1970-01-01 (Howard Hinnant's
/// `civil_from_days`, for days on or after the epoch).
fn civil(days: u64) -> (u64, u64, u64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);
    (year, month, day)
}

/// The host and path of an `http(s)` URL with no query, the host without a port the scheme
/// already implies (what an HTTP client sends as `Host`).
fn split(url: &str) -> anyhow::Result<(String, String)> {
    let (scheme, rest) =
        url.split_once("://").ok_or_else(|| anyhow::anyhow!("{url}: no scheme"))?;
    anyhow::ensure!(matches!(scheme, "http" | "https"), "{url}: not http(s)");
    anyhow::ensure!(!rest.contains(['?', '#']), "{url}: a signed object URL takes no query");
    let (host, path) = match rest.find('/') {
        Some(at) => rest.split_at(at),
        None => (rest, "/"),
    };
    anyhow::ensure!(!host.is_empty() && !host.contains('@'), "{url}: no host");
    let host = match scheme {
        "https" => host.strip_suffix(":443").unwrap_or(host),
        _ => host.strip_suffix(":80").unwrap_or(host),
    };
    // Path segments are sent as written, so only the characters S3 leaves unescaped are allowed:
    // a bucket, a prefix and a hex id never need more.
    anyhow::ensure!(
        path.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte)),
        "{url}: the path may hold only letters, digits and / - . _ ~"
    );
    Ok((host.to_owned(), path.to_owned()))
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    // HMAC takes a key of any length, so `new_from_slice` cannot fail.
    let mut mac = Hmac::<Sha256>::new_from_slice(key).unwrap_or_else(|_| unreachable!());
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The sha256 of `bytes` in hex: a signed `PUT` declares its body's.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// The headers that sign `method url` at `unix_s` (`x-amz-date`, then `x-amz-content-sha256` for
/// S3, then `authorization`), for a body whose sha256 is `payload_sha256`. The `host` header is
/// signed too; the HTTP client sends it from the URL.
pub fn sign(
    method: &str,
    url: &str,
    key: &Key,
    service: &str,
    unix_s: u64,
    payload_sha256: &str,
) -> anyhow::Result<Vec<(&'static str, String)>> {
    let (host, path) = split(url)?;
    let (stamp, date) = amz_date(unix_s);
    let mut headers: Vec<(&'static str, String)> = vec![("host", host), ("x-amz-date", stamp)];
    if service == SERVICE {
        headers.push(("x-amz-content-sha256", payload_sha256.to_owned()));
    }
    headers.sort_by(|a, b| a.0.cmp(b.0));
    let canonical_headers: String =
        headers.iter().map(|(name, value)| format!("{name}:{}\n", value.trim())).collect();
    let signed: Vec<&str> = headers.iter().map(|(name, _)| *name).collect();
    let signed = signed.join(";");
    let request = format!("{method}\n{path}\n\n{canonical_headers}\n{signed}\n{payload_sha256}");
    let scope = format!("{date}/{}/{service}/aws4_request", key.region);
    let stamp = headers
        .iter()
        .find(|(name, _)| *name == "x-amz-date")
        .map(|(_, value)| value.clone())
        .unwrap_or_default();
    let to_sign = format!("AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{}", sha256_hex(request.as_bytes()));
    let signing = [key.region.as_str(), service, "aws4_request"]
        .iter()
        .fold(hmac(format!("AWS4{}", key.secret).as_bytes(), &date), |acc, part| hmac(&acc, part));
    let signature = hex(&hmac(&signing, &to_sign));
    let mut out: Vec<(&'static str, String)> =
        headers.into_iter().filter(|(name, _)| *name != "host").collect();
    out.push((
        "authorization",
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={signature}",
            key.id
        ),
    ));
    Ok(out)
}

/// What one `PUT` did.
#[derive(Debug, PartialEq, Eq)]
pub enum Put {
    Stored,
    /// The bucket already held it (a `HEAD` answered 200), so nothing was sent.
    Had,
}

/// Puts blobs into a bucket: what `cmux-projection s3-push` runs, so a host that holds blobs
/// seeds every other host's chain through the bucket.
pub struct Bucket {
    base: String,
    key: Key,
    client: reqwest::blocking::Client,
}

impl Bucket {
    pub fn new(base: &str, key: Key) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::blocking::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(2))
            .timeout(std::time::Duration::from_secs(60))
            .build()?;
        Ok(Self { base: base.trim_end_matches('/').to_owned(), key, client })
    }

    fn url(&self, oid: &str) -> String {
        format!("{}/objects/{oid}", self.base)
    }

    fn now() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_secs())
    }

    /// Stores `bytes` as blob `oid` unless the bucket holds it already. Refuses bytes that do not
    /// hash to `oid`, so a bucket never holds a wrong object under a right name.
    pub fn put(&self, oid: &str, bytes: &[u8]) -> anyhow::Result<Put> {
        anyhow::ensure!(crate::peers::verify(oid, bytes), "{oid}: bytes do not hash to it");
        let url = self.url(oid);
        let mut head = self.client.head(&url);
        for (name, value) in sign("HEAD", &url, &self.key, SERVICE, Self::now(), EMPTY_SHA256)? {
            head = head.header(name, value);
        }
        if head.send().is_ok_and(|response| response.status().is_success()) {
            return Ok(Put::Had);
        }
        let mut put = self.client.put(&url).body(bytes.to_vec());
        for (name, value) in sign("PUT", &url, &self.key, SERVICE, Self::now(), &sha256_hex(bytes))?
        {
            put = put.header(name, value);
        }
        let response = put.send()?;
        anyhow::ensure!(response.status().is_success(), "PUT {url}: HTTP {}", response.status());
        Ok(Put::Stored)
    }
}

#[cfg(test)]
#[path = "s3_tests.rs"]
mod tests;
