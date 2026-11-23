//! The object-store tier of the blob chain ([`crate::peers`]): any S3-compatible store (AWS S3,
//! Cloudflare R2, MinIO, Backblaze B2, Google Cloud Storage's XML API, ...), asked for a blob by
//! its git object id as `GET <endpoint>/<bucket>/<prefix>/<id>` (path style) or
//! `GET <scheme>://<bucket>.<host>/<prefix>/<id>` (virtual-hosted), signed with AWS Signature
//! Version 4 when it has keys. R2 is one configuration of it, and a public bucket URL another.
//!
//! The environment names the stores, each left out (with one log line) when its configuration is
//! unusable, so a bad one costs nothing at mount time rather than three deadlines:
//!
//! - `CMUX_PROJECTION_R2_URL`: a public R2 (or any public bucket) base URL, asked unsigned as
//!   `<base>/objects/<id>` (what the chain always did); an empty or non-`http(s)` value is skipped.
//! - `CMUX_PROJECTION_R2_ACCOUNT_ID` with `CMUX_PROJECTION_R2_BUCKET` and the keys
//!   `CMUX_PROJECTION_R2_ACCESS_KEY_ID` / `CMUX_PROJECTION_R2_SECRET_ACCESS_KEY`: a private R2
//!   bucket, at `https://<account>.r2.cloudflarestorage.com`, region `auto`, path style.
//! - `CMUX_PROJECTION_S3_ENDPOINT` with `CMUX_PROJECTION_S3_BUCKET`, and optionally
//!   `CMUX_PROJECTION_S3_REGION` (default `us-east-1`), `CMUX_PROJECTION_S3_PATH_STYLE` (`1`/`0`;
//!   default path style except on `amazonaws.com`), `CMUX_PROJECTION_S3_PREFIX` (default
//!   `objects`), and keys from `CMUX_PROJECTION_S3_ACCESS_KEY_ID` /
//!   `CMUX_PROJECTION_S3_SECRET_ACCESS_KEY` / `CMUX_PROJECTION_S3_SESSION_TOKEN`, else the standard
//!   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.
//!   `CMUX_PROJECTION_S3_PUBLIC=1` asks a public bucket unsigned.
//! - `CMUX_PROJECTION_S3_CONFIG`: a JSON file with the same settings (`endpoint`, `bucket`,
//!   `region`, `path_style`, `prefix`, `access_key_id`, `secret_access_key`, `session_token`,
//!   `public`); the variables above win over it.
//!
//! A private store with no keys is left out at once (it would only answer 403). A store that
//! answers 401 or 403 at run time is dropped for the rest of the fill on that first answer, not
//! after three failures.
//!
//! `cmux-projection s3-push` fills a bucket ([`Store::push`], [`Config::push_target`]): a signed
//! `HEAD` per blob, and a signed `PUT` of the blobs the bucket lacks, each checked against its id
//! first.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use sha2::{Digest as _, Sha256};

/// The SHA-256 of an empty body, the payload hash of a signed `GET` or `HEAD`.
pub const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// SigV4 keys.
#[derive(Clone, PartialEq, Eq)]
pub struct Keys {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: Option<String>,
}

impl std::fmt::Debug for Keys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Keys").field("access_key_id", &self.access_key_id).finish_non_exhaustive()
    }
}

/// Where one store's objects are and how a request to it is signed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// The chain's name for it (`r2` or `s3`), for the log and the mount's timing line.
    pub tier: &'static str,
    /// Everything before `/<id>` in an object's URL, no trailing slash.
    pub base: String,
    /// The `Host` header the request carries (with the port when it is not the scheme's).
    pub host: String,
    /// The path of `base`, as signed (`/bucket/objects` or `/objects`).
    pub path: String,
    pub region: String,
    /// `None`: asked unsigned (a public bucket).
    pub keys: Option<Keys>,
}

/// A bucket on an S3-compatible endpoint, as configured ([`Config::bucket`] checks it).
#[derive(Clone, Debug, Default)]
pub struct Bucket {
    pub endpoint: String,
    pub bucket: String,
    /// Empty: `us-east-1`.
    pub region: String,
    /// `None`: path style, except on `amazonaws.com`.
    pub path_style: Option<bool>,
    /// The key prefix the blobs sit under (`objects`).
    pub prefix: String,
    pub keys: Option<Keys>,
    /// Asked unsigned, keys or not.
    pub public: bool,
}

/// One setting read from the environment, then the config file.
type Lookup<'a> = &'a dyn Fn(&str) -> Option<String>;

/// `value` when it is a usable `http(s)` URL, without its trailing slash; `None` for an empty or
/// other value, so the chain skips it rather than failing on it three times.
#[must_use]
pub fn http_base(value: &str) -> Option<String> {
    let value = value.trim();
    let rest = value.strip_prefix("https://").or_else(|| value.strip_prefix("http://"))?;
    let host = rest.split('/').next().unwrap_or_default();
    if host.is_empty() {
        return None;
    }
    Some(value.trim_end_matches('/').to_owned())
}

/// The `(scheme, authority, path)` of an `http(s)` URL; the authority keeps a non-default port.
fn split_url(url: &str) -> Option<(&str, String, String)> {
    let (scheme, rest) = url.split_once("://")?;
    let (authority, path) = rest.split_once('/').map_or((rest, ""), |(host, path)| (host, path));
    let authority = match (scheme, authority.rsplit_once(':')) {
        ("https", Some((host, "443"))) | ("http", Some((host, "80"))) => host.to_owned(),
        _ => authority.to_owned(),
    };
    let path = path.trim_matches('/');
    let path = if path.is_empty() { String::new() } else { format!("/{path}") };
    Some((scheme, authority, path))
}

fn truthy(value: &str) -> bool {
    matches!(value.trim(), "1" | "true" | "yes" | "on")
}

impl Config {
    /// A public bucket at `base`, asked unsigned as `<base>/objects/<id>`.
    #[must_use]
    pub fn public(tier: &'static str, base: &str) -> Option<Self> {
        let base = format!("{}/objects", http_base(base)?);
        let (_, host, path) = split_url(&base)?;
        Some(Self { tier, base, host, path, region: String::new(), keys: None })
    }

    /// A bucket on an S3-compatible endpoint. `Err` says why it is unusable.
    pub fn bucket(tier: &'static str, spec: Bucket) -> Result<Self, String> {
        let Bucket { endpoint, bucket, region, path_style, prefix, keys, public } = spec;
        let endpoint =
            http_base(&endpoint).ok_or_else(|| format!("endpoint {endpoint:?} is not http(s)"))?;
        let bucket = bucket.trim();
        if bucket.is_empty() || bucket.contains('/') {
            return Err(format!("bucket {bucket:?} is not a bucket name"));
        }
        if keys.is_none() && !public {
            return Err("no access keys (set them, or mark the bucket public)".to_owned());
        }
        let (scheme, authority, root) =
            split_url(&endpoint).ok_or_else(|| format!("endpoint {endpoint:?} is not a URL"))?;
        let path_style = path_style.unwrap_or(!authority.ends_with("amazonaws.com"));
        let prefix = prefix.trim_matches('/');
        let prefix = if prefix.is_empty() { String::new() } else { format!("/{prefix}") };
        let (host, path) = if path_style {
            (authority, format!("{root}/{bucket}{prefix}"))
        } else {
            (format!("{bucket}.{authority}"), format!("{root}{prefix}"))
        };
        let base = format!("{scheme}://{host}{path}");
        let region = if region.trim().is_empty() { "us-east-1" } else { region.trim() };
        let keys = if public { None } else { keys };
        Ok(Self { tier, base, host, path, region: region.to_owned(), keys })
    }

    /// The stores `lookup` names (an environment variable's value, else the config file's), and
    /// one line per store left out saying why.
    #[must_use]
    pub fn all(lookup: Lookup<'_>) -> (Vec<Self>, Vec<String>) {
        let mut stores = Vec::new();
        let mut skipped = Vec::new();
        let get = |name: &str| lookup(name).filter(|value| !value.trim().is_empty());
        if let Some(url) = lookup("CMUX_PROJECTION_R2_URL") {
            match Self::public("r2", &url) {
                Some(store) => stores.push(store),
                None => skipped.push(format!("CMUX_PROJECTION_R2_URL {url:?} is not http(s)")),
            }
        }
        if let Some(account) = get("CMUX_PROJECTION_R2_ACCOUNT_ID") {
            let keys = keys(
                get("CMUX_PROJECTION_R2_ACCESS_KEY_ID"),
                get("CMUX_PROJECTION_R2_SECRET_ACCESS_KEY"),
                None,
            );
            let spec = Bucket {
                endpoint: format!("https://{}.r2.cloudflarestorage.com", account.trim()),
                bucket: get("CMUX_PROJECTION_R2_BUCKET").unwrap_or_default(),
                region: "auto".to_owned(),
                path_style: Some(true),
                prefix: "objects".to_owned(),
                keys,
                public: false,
            };
            match Self::bucket("r2", spec) {
                Ok(store) => stores.push(store),
                Err(why) => skipped.push(format!("R2 bucket: {why}")),
            }
        }
        if let Some(endpoint) = get("CMUX_PROJECTION_S3_ENDPOINT") {
            let keys = keys(
                get("CMUX_PROJECTION_S3_ACCESS_KEY_ID").or_else(|| get("AWS_ACCESS_KEY_ID")),
                get("CMUX_PROJECTION_S3_SECRET_ACCESS_KEY")
                    .or_else(|| get("AWS_SECRET_ACCESS_KEY")),
                get("CMUX_PROJECTION_S3_SESSION_TOKEN").or_else(|| get("AWS_SESSION_TOKEN")),
            );
            let spec = Bucket {
                endpoint,
                bucket: get("CMUX_PROJECTION_S3_BUCKET").unwrap_or_default(),
                region: get("CMUX_PROJECTION_S3_REGION").unwrap_or_default(),
                path_style: get("CMUX_PROJECTION_S3_PATH_STYLE").map(|value| truthy(&value)),
                prefix: get("CMUX_PROJECTION_S3_PREFIX").unwrap_or_else(|| "objects".to_owned()),
                keys,
                public: get("CMUX_PROJECTION_S3_PUBLIC").is_some_and(|value| truthy(&value)),
            };
            match Self::bucket("s3", spec) {
                Ok(store) => stores.push(store),
                Err(why) => skipped.push(format!("S3 bucket: {why}")),
            }
        }
        (stores, skipped)
    }

    /// The stores the process environment and `CMUX_PROJECTION_S3_CONFIG` name; each one left out
    /// is logged once.
    #[must_use]
    pub fn from_env() -> Vec<Self> {
        let file = config_file();
        let lookup = |name: &str| std::env::var(name).ok().or_else(|| from_file(&file, name));
        let (stores, skipped) = Self::all(&lookup);
        for why in skipped {
            eprintln!("cmux-projection: object store skipped: {why}");
        }
        stores
    }

    /// The bucket `cmux-projection s3-push --to BASE` writes to: the configured store whose
    /// `base` is BASE when one has keys, else BASE (everything before `/<id>`, path or virtual
    /// style) signed with the S3 keys and region the chain reads (`CMUX_PROJECTION_S3_*`, else
    /// `AWS_*`). `Err` says why it is unusable; a push always needs keys.
    pub fn push_target(to: &str, lookup: Lookup<'_>) -> Result<Self, String> {
        let base = http_base(to).ok_or_else(|| format!("--to {to:?} is not http(s)"))?;
        let (stores, _) = Self::all(lookup);
        if let Some(store) =
            stores.into_iter().find(|store| store.base == base && store.keys.is_some())
        {
            return Ok(store);
        }
        let get = |name: &str| lookup(name).filter(|value| !value.trim().is_empty());
        let keys = keys(
            get("CMUX_PROJECTION_S3_ACCESS_KEY_ID").or_else(|| get("AWS_ACCESS_KEY_ID")),
            get("CMUX_PROJECTION_S3_SECRET_ACCESS_KEY").or_else(|| get("AWS_SECRET_ACCESS_KEY")),
            get("CMUX_PROJECTION_S3_SESSION_TOKEN").or_else(|| get("AWS_SESSION_TOKEN")),
        )
        .ok_or_else(|| {
            "no access keys: CMUX_PROJECTION_S3_ACCESS_KEY_ID and \
             CMUX_PROJECTION_S3_SECRET_ACCESS_KEY, or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
                .to_owned()
        })?;
        let (_, host, path) =
            split_url(&base).ok_or_else(|| format!("--to {to:?} is not a URL"))?;
        let region = get("CMUX_PROJECTION_S3_REGION").unwrap_or_else(|| {
            if host.ends_with(".r2.cloudflarestorage.com") { "auto" } else { "us-east-1" }
                .to_owned()
        });
        Ok(Self {
            tier: "s3",
            base,
            host,
            path,
            region: region.trim().to_owned(),
            keys: Some(keys),
        })
    }

    /// [`Config::push_target`] read from the process environment and `CMUX_PROJECTION_S3_CONFIG`.
    pub fn push_target_from_env(to: &str) -> Result<Self, String> {
        let file = config_file();
        Self::push_target(to, &|name: &str| {
            std::env::var(name).ok().or_else(|| from_file(&file, name))
        })
    }

    /// The signed headers of `GET <base>/<id>` at `now` (none for a public bucket).
    #[must_use]
    pub fn headers(&self, oid: &str, now: SystemTime) -> Vec<(String, String)> {
        self.signed("GET", oid, EMPTY_SHA256, now)
    }

    /// The signed headers of `METHOD <base>/<id>` at `now` for a body whose SHA-256 is `payload`
    /// (hex; [`EMPTY_SHA256`] for `GET` and `HEAD`, the blob's for `PUT`); none for a public bucket.
    #[must_use]
    pub fn signed(
        &self,
        method: &str,
        oid: &str,
        payload: &str,
        now: SystemTime,
    ) -> Vec<(String, String)> {
        let Some(keys) = &self.keys else { return Vec::new() };
        let mut headers = vec![
            ("host".to_owned(), self.host.clone()),
            ("x-amz-content-sha256".to_owned(), payload.to_owned()),
            ("x-amz-date".to_owned(), amz_date(now)),
        ];
        if let Some(token) = &keys.session_token {
            headers.push(("x-amz-security-token".to_owned(), token.clone()));
        }
        let path = format!("{}/{oid}", self.path);
        let authorization = authorization(keys, &self.region, method, &path, "", &headers);
        headers.retain(|(name, _)| name != "host");
        headers.push(("authorization".to_owned(), authorization));
        headers
    }
}

/// The `CMUX_PROJECTION_S3_CONFIG` file's settings (`null` when it is unset or unreadable).
fn config_file() -> serde_json::Value {
    std::env::var("CMUX_PROJECTION_S3_CONFIG")
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

/// A setting of the `CMUX_PROJECTION_S3_CONFIG` file, by its variable's name.
fn from_file(file: &serde_json::Value, name: &str) -> Option<String> {
    let key = name.strip_prefix("CMUX_PROJECTION_S3_")?.to_ascii_lowercase();
    match file.get(&key)? {
        serde_json::Value::String(text) => Some(text.clone()),
        serde_json::Value::Bool(flag) => Some(if *flag { "1" } else { "0" }.to_owned()),
        _ => None,
    }
}

fn keys(id: Option<String>, secret: Option<String>, token: Option<String>) -> Option<Keys> {
    Some(Keys { access_key_id: id?, secret_access_key: secret?, session_token: token })
}

/// `YYYYMMDDTHHMMSSZ` of `now`, UTC.
#[must_use]
pub fn amz_date(now: SystemTime) -> String {
    let secs = now.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs());
    let days = i64::try_from(secs / 86_400).unwrap_or(0);
    let rest = secs % 86_400;
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The SHA-256 of `bytes` in hex: what a signed `PUT` declares as its payload.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// HMAC-SHA256 (RFC 2104).
#[must_use]
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        let digest: [u8; 32] = Sha256::digest(key).into();
        for (slot, byte) in block.iter_mut().zip(digest) {
            *slot = byte;
        }
    } else {
        for (slot, byte) in block.iter_mut().zip(key) {
            *slot = *byte;
        }
    }
    let mut inner = Sha256::new();
    inner.update(block.map(|byte| byte ^ 0x36));
    inner.update(message);
    let mut outer = Sha256::new();
    outer.update(block.map(|byte| byte ^ 0x5c));
    outer.update(inner.finalize());
    outer.finalize().into()
}

/// A path as SigV4 signs it for S3: each segment URI-encoded once, slashes kept.
fn canonical_path(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~' | b'/') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    if out.is_empty() { "/".to_owned() } else { out }
}

/// The `Authorization` header of a SigV4 request: `headers` are the signed ones (lower-case
/// names, `x-amz-date` among them); the payload is the one `x-amz-content-sha256` names.
#[must_use]
pub fn authorization(
    keys: &Keys,
    region: &str,
    method: &str,
    path: &str,
    query: &str,
    headers: &[(String, String)],
) -> String {
    let mut sorted: Vec<(String, String)> = headers
        .iter()
        .map(|(name, value)| (name.to_ascii_lowercase(), value.trim().to_owned()))
        .collect();
    sorted.sort();
    let value_of = |wanted: &str| {
        sorted.iter().find(|(name, _)| name == wanted).map(|(_, value)| value.clone())
    };
    let date = value_of("x-amz-date").unwrap_or_default();
    let payload = value_of("x-amz-content-sha256").unwrap_or_else(|| EMPTY_SHA256.to_owned());
    let day = date.get(..8).unwrap_or_default();
    let signed: Vec<&str> = sorted.iter().map(|(name, _)| name.as_str()).collect();
    let signed = signed.join(";");
    let canonical_headers: String =
        sorted.iter().map(|(name, value)| format!("{name}:{value}\n")).collect();
    let canonical = format!(
        "{method}\n{}\n{query}\n{canonical_headers}\n{signed}\n{payload}",
        canonical_path(path)
    );
    let scope = format!("{day}/{region}/s3/aws4_request");
    let to_sign = format!(
        "AWS4-HMAC-SHA256\n{date}\n{scope}\n{}",
        hex(&Sha256::digest(canonical.as_bytes()))
    );
    let mut key = hmac_sha256(format!("AWS4{}", keys.secret_access_key).as_bytes(), day.as_bytes());
    for part in [region, "s3", "aws4_request"] {
        key = hmac_sha256(&key, part.as_bytes());
    }
    let signature = hex(&hmac_sha256(&key, to_sign.as_bytes()));
    format!(
        "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={signature}",
        keys.access_key_id
    )
}

/// What a store answered that the chain's [`crate::peers::Answer`] has no word for.
#[derive(Debug, PartialEq, Eq)]
pub enum Fetched {
    Answer(crate::peers::Answer),
    /// 401 or 403: the keys are missing or wrong, so every other blob would be refused too.
    Denied(u16),
}

/// What one [`Store::push`] did.
#[derive(Debug, PartialEq, Eq)]
pub enum Pushed {
    Stored,
    /// The bucket already held it (its `HEAD` answered 2xx), so nothing was sent.
    Had,
    /// The `PUT` was answered 401 or 403: the keys may not write, so no other blob would be
    /// stored either.
    Denied(u16),
}

/// A configured store and its client.
pub struct Store {
    pub config: Config,
    client: reqwest::blocking::Client,
}

impl Store {
    pub fn new(config: Config) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::blocking::Client::builder()
            .connect_timeout(Duration::from_millis(500))
            .timeout(Duration::from_secs(20))
            .build()?;
        Ok(Self { config, client })
    }

    /// The chain's entry for this store; [`crate::peers::Chain`] finds the store by its `base`.
    #[must_use]
    pub fn remote(&self) -> crate::peers::Remote {
        crate::peers::Remote { tier: self.config.tier, base: self.config.base.clone(), token: None }
    }

    /// One `GET` of blob `oid`.
    #[must_use]
    pub fn get(&self, oid: &str, deadline: Duration) -> Fetched {
        use crate::peers::Answer;
        let mut request = self.client.get(format!("{}/{oid}", self.config.base)).timeout(deadline);
        for (name, value) in self.config.headers(oid, SystemTime::now()) {
            request = request.header(name, value);
        }
        match request.send() {
            Ok(response) => match response.status().as_u16() {
                401 | 403 => Fetched::Denied(response.status().as_u16()),
                404 => Fetched::Answer(Answer::Absent),
                429 | 503 => Fetched::Answer(Answer::Busy),
                status if (200..300).contains(&status) => Fetched::Answer(
                    response.bytes().map_or(Answer::Failed, |bytes| Answer::Found(bytes.to_vec())),
                ),
                _ => Fetched::Answer(Answer::Failed),
            },
            Err(_) => Fetched::Answer(Answer::Failed),
        }
    }

    /// Stores `bytes` as blob `oid` unless the bucket holds it already (one `HEAD`). Refuses
    /// bytes that do not hash to `oid` before any request, so the bucket never holds a wrong
    /// object under a right name. A `HEAD` that does not answer 2xx (404, or 403 from a bucket
    /// whose keys may not list) is followed by the `PUT`.
    pub fn push(&self, oid: &str, bytes: &[u8]) -> anyhow::Result<Pushed> {
        anyhow::ensure!(crate::peers::verify(oid, bytes), "{oid}: the bytes do not hash to it");
        let url = format!("{}/{oid}", self.config.base);
        let mut head = self.client.head(&url);
        for (name, value) in self.config.signed("HEAD", oid, EMPTY_SHA256, SystemTime::now()) {
            head = head.header(name, value);
        }
        if head.send().is_ok_and(|response| response.status().is_success()) {
            return Ok(Pushed::Had);
        }
        let payload = sha256_hex(bytes);
        let mut put = self.client.put(&url).timeout(PUT_TIMEOUT).body(bytes.to_vec());
        for (name, value) in self.config.signed("PUT", oid, &payload, SystemTime::now()) {
            put = put.header(name, value);
        }
        let response = put.send().map_err(|error| anyhow::anyhow!("PUT {url}: {error}"))?;
        match response.status().as_u16() {
            status @ (401 | 403) => Ok(Pushed::Denied(status)),
            status if (200..300).contains(&status) => Ok(Pushed::Stored),
            status => anyhow::bail!("PUT {url}: HTTP {status}"),
        }
    }
}

/// How long one `PUT` may take: a large blob over a slow uplink, not the 20 s a `GET` gets.
const PUT_TIMEOUT: Duration = Duration::from_secs(300);

#[cfg(test)]
#[path = "s3_tests.rs"]
mod tests;
