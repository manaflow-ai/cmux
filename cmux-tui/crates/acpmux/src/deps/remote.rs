//! The platform's dependency cache (cmux-platform `/v1/dep-cache`), asked
//! with this machine's join credential. The credential goes only to the hub
//! the machine joined, as the bearer of these requests.
//!
//! - `GET /entries/<key>`: the archive, with its size and digest in headers;
//!   404 `dep_cache.miss` when nothing is stored, `dep_cache.not_found` when
//!   the hub has no dependency caches.
//! - `PUT /entries/<key>/uploads/<id>/parts/<n>` (64 MiB each, the last
//!   shorter, `x-dep-cache-sha256` the part's), then `POST .../commit` with
//!   the part count and the archive digest: SHA-256 over each part's raw
//!   SHA-256, in order.

use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub const PART_BYTES: u64 = 64 * 1024 * 1024;
const PREFIX: &str = "/v1/dep-cache/entries";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The archive digest, fed in order: each `part_bytes` slice is hashed, and
/// the digest is the SHA-256 of those digests.
pub struct TreeHasher {
    part_bytes: u64,
    current: Sha256,
    current_len: u64,
    parts: Vec<[u8; 32]>,
}

impl TreeHasher {
    pub fn new(part_bytes: u64) -> TreeHasher {
        TreeHasher { part_bytes, current: Sha256::new(), current_len: 0, parts: Vec::new() }
    }

    pub fn update(&mut self, mut data: &[u8]) {
        while !data.is_empty() {
            let room = (self.part_bytes - self.current_len) as usize;
            let take = room.min(data.len());
            let (head, rest) = data.split_at(take);
            self.current.update(head);
            self.current_len += take as u64;
            data = rest;
            if self.current_len == self.part_bytes {
                self.close_part();
            }
        }
    }

    fn close_part(&mut self) {
        let done = std::mem::replace(&mut self.current, Sha256::new());
        self.parts.push(done.finalize().into());
        self.current_len = 0;
    }

    /// The digest and the part count.
    pub fn finish(mut self) -> (String, usize) {
        if self.current_len > 0 || self.parts.is_empty() {
            self.close_part();
        }
        let mut tree = Sha256::new();
        for part in &self.parts {
            tree.update(part);
        }
        (hex(&tree.finalize()), self.parts.len())
    }
}

/// What a download found.
#[derive(Debug, PartialEq, Eq)]
pub enum Fetched {
    /// The archive is in the file, verified; its size.
    Hit(u64),
    Miss,
    /// The hub has no dependency caches.
    Off,
    /// Given up part way: at its pace it would have been slower than a cold
    /// install (`give_up`). The archive's size and the bytes read.
    Abandoned {
        size: u64,
        got: u64,
    },
}

/// Time a download's pace is measured over before `give_up` is asked.
const PACE_AFTER_MS: u64 = 300;

/// What an upload did.
#[derive(Debug, PartialEq, Eq)]
pub enum Stored {
    Created,
    /// Another machine stored this key first.
    Exists,
    Off,
}

/// What the machine that stored an archive measured, kept beside it so a
/// machine with no measurements of its own can still choose (`warm.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Meta {
    /// Its cold install, which this archive saves.
    pub cold_ms: u64,
    pub archive_bytes: u64,
}

/// A timing record is a few dozen bytes; anything larger is not one.
const META_MAX_BYTES: u64 = 4096;

/// The key of `key`'s timing record: an entry of its own, of the same
/// ecosystem, that no lockfile's key can equal.
pub fn meta_key(key: &str) -> Option<String> {
    let (ecosystem, _) = key.split_once('-')?;
    let digest = Sha256::digest(format!("acpmux-deps meta\n{key}").as_bytes());
    Some(format!("{ecosystem}-{}", hex(&digest)))
}

pub struct Remote {
    origin: String,
    bearer: String,
    client: reqwest::Client,
}

impl Remote {
    /// The joined machine's hub and credential, or None when this machine is not joined.
    pub fn joined() -> Result<Option<Remote>> {
        let Some(record) = crate::cli::cloud_join::machine_credential()? else {
            return Ok(None);
        };
        if record.revoked || !record.credential.starts_with("cmm_") {
            return Ok(None);
        }
        let origin = crate::cli::cloud_join::hub_origin(&record.hub_origin)?;
        Ok(Some(Remote::new(origin, record.credential)?))
    }

    pub fn new(origin: String, bearer: String) -> Result<Remote> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            // A part or a whole download; a stalled one is given up, never waited on.
            .timeout(Duration::from_secs(600))
            .build()
            .context("build dependency cache client")?;
        Ok(Remote { origin, bearer, client })
    }

    fn url(&self, key: &str, rest: &str) -> String {
        format!("{}{PREFIX}/{key}{rest}", self.origin)
    }

    /// Download `key` into `out`, verifying its size and digest as it streams.
    /// `give_up(got, size, elapsed_ms)` is asked as it goes (after a short
    /// measuring time): true ends the download as [`Fetched::Abandoned`].
    pub async fn fetch(
        &self,
        key: &str,
        out: &Path,
        give_up: impl Fn(u64, u64, u64) -> bool,
    ) -> Result<Fetched> {
        let started = std::time::Instant::now();
        let mut response = self
            .client
            .get(self.url(key, ""))
            .bearer_auth(&self.bearer)
            .send()
            .await
            .context("dependency cache unreachable")?;
        let status = response.status().as_u16();
        if status == 404 {
            let body: Value = response.json().await.unwrap_or_default();
            return Ok(match body.get("code").and_then(Value::as_str) {
                Some("dep_cache.miss") => Fetched::Miss,
                _ => Fetched::Off,
            });
        }
        if status != 200 {
            bail!("dependency cache answered {status}");
        }
        let header = |name: &str| {
            response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
        };
        let digest = header("x-dep-cache-sha256").ok_or_else(|| anyhow!("no archive digest"))?;
        let size: u64 = header("x-dep-cache-size")
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow!("no archive size"))?;
        let part_bytes: u64 = header("x-dep-cache-part-bytes")
            .and_then(|s| s.parse().ok())
            .filter(|n| *n > 0)
            .unwrap_or(PART_BYTES);
        let mut file = std::io::BufWriter::new(std::fs::File::create(out)?);
        let mut hasher = TreeHasher::new(part_bytes);
        let mut got = 0u64;
        while let Some(chunk) = response.chunk().await.context("dependency cache download")? {
            got += chunk.len() as u64;
            if got > size {
                bail!("archive is longer than its size");
            }
            hasher.update(&chunk);
            file.write_all(&chunk)?;
            let elapsed = started.elapsed().as_millis() as u64;
            if elapsed >= PACE_AFTER_MS && got < size && give_up(got, size, elapsed) {
                return Ok(Fetched::Abandoned { size, got });
            }
        }
        file.flush()?;
        if got != size {
            bail!("archive was cut short ({got} of {size} bytes)");
        }
        if hasher.finish().0 != digest {
            bail!("archive digest does not match");
        }
        Ok(Fetched::Hit(size))
    }

    /// `key`'s timing record, when its archive's uploader stored one.
    pub async fn fetch_meta(&self, key: &str) -> Result<Option<Meta>> {
        let Some(meta) = meta_key(key) else { return Ok(None) };
        let scratch = tempfile::tempdir()?;
        let path = scratch.path().join("meta.json");
        match self.fetch(&meta, &path, |_, size, _| size > META_MAX_BYTES).await? {
            Fetched::Hit(size) if size <= META_MAX_BYTES => {
                Ok(serde_json::from_slice(&std::fs::read(&path)?).ok())
            }
            _ => Ok(None),
        }
    }

    /// Store `key`'s timing record (once: a later one finds it there).
    pub async fn store_meta(&self, key: &str, meta: Meta) -> Result<Stored> {
        let Some(meta_key) = meta_key(key) else { bail!("key has no ecosystem") };
        let scratch = tempfile::tempdir()?;
        let path = scratch.path().join("meta.json");
        std::fs::write(&path, serde_json::to_vec(&meta)?)?;
        self.store(&meta_key, &path).await
    }

    /// Upload the archive in `file` under `key`.
    pub async fn store(&self, key: &str, file: &Path) -> Result<Stored> {
        let mut id = [0u8; 12];
        getrandom::fill(&mut id).map_err(|_| anyhow!("no randomness for an upload id"))?;
        let upload = hex(&id);
        let mut reader = std::fs::File::open(file)?;
        let mut tree = TreeHasher::new(PART_BYTES);
        let mut part = 0usize;
        loop {
            let mut buf = Vec::with_capacity(PART_BYTES as usize);
            (&mut reader).take(PART_BYTES).read_to_end(&mut buf)?;
            if buf.is_empty() && part > 0 {
                break;
            }
            tree.update(&buf);
            let digest = hex(&Sha256::digest(&buf));
            let full = buf.len() as u64 == PART_BYTES;
            let response = self
                .client
                .put(self.url(key, &format!("/uploads/{upload}/parts/{part}")))
                .bearer_auth(&self.bearer)
                .header("x-dep-cache-sha256", digest)
                .header("content-type", "application/octet-stream")
                .body(buf)
                .send()
                .await
                .context("dependency cache unreachable")?;
            let status = response.status().as_u16();
            let body: Value = response.json().await.unwrap_or_default();
            match status {
                200 if body.get("exists").and_then(Value::as_bool) == Some(true) => {
                    return Ok(Stored::Exists);
                }
                200 => {}
                404 => return Ok(Stored::Off),
                _ => bail!("dependency cache refused part {part}: {status} {}", code(&body)),
            }
            part += 1;
            if !full {
                break;
            }
        }
        let (digest, parts) = tree.finish();
        anyhow::ensure!(parts == part, "part count mismatch");
        let response = self
            .client
            .post(self.url(key, &format!("/uploads/{upload}/commit")))
            .bearer_auth(&self.bearer)
            .json(&json!({"parts": parts, "sha256": digest}))
            .send()
            .await
            .context("dependency cache unreachable")?;
        let status = response.status().as_u16();
        let body: Value = response.json().await.unwrap_or_default();
        match status {
            201 => Ok(Stored::Created),
            200 => Ok(Stored::Exists),
            404 => Ok(Stored::Off),
            _ => bail!("dependency cache refused the archive: {status} {}", code(&body)),
        }
    }
}

fn code(body: &Value) -> &str {
    body.get("code").and_then(Value::as_str).unwrap_or("unknown")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sha(data: &[u8]) -> [u8; 32] {
        Sha256::digest(data).into()
    }

    #[test]
    fn a_timing_record_has_a_key_of_its_own() {
        let key = format!("bun-{}", "a".repeat(64));
        let meta = meta_key(&key).unwrap();
        assert!(meta.starts_with("bun-"));
        assert_eq!(meta.len(), key.len());
        assert_ne!(meta, key);
        assert!(meta[4..].bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(meta_key(&key), Some(meta));
        assert_eq!(meta_key("nodash"), None);
    }

    #[test]
    fn tree_digest_is_the_hash_of_part_hashes_however_it_is_fed() {
        let data: Vec<u8> = (0..2500u32).map(|i| (i % 251) as u8).collect();
        let mut expected = Sha256::new();
        for part in data.chunks(1000) {
            expected.update(sha(part));
        }
        let expected = hex(&expected.finalize());
        for step in [1, 7, 1000, 2500] {
            let mut h = TreeHasher::new(1000);
            for piece in data.chunks(step) {
                h.update(piece);
            }
            assert_eq!(h.finish(), (expected.clone(), 3), "step {step}");
        }
        // Exactly one full part: no empty trailing part.
        let mut h = TreeHasher::new(1000);
        h.update(&data[..1000]);
        let mut one = Sha256::new();
        one.update(sha(&data[..1000]));
        assert_eq!(h.finish(), (hex(&one.finalize()), 1));
    }
}
