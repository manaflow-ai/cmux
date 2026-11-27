//! Where sealed blobs go: the person's `/v1/sync` store (cmux-platform, R2), or a folder (tests, benches).

use anyhow::{Context, anyhow, bail};
use std::path::PathBuf;
use std::time::Duration;

/// The sync store refuses blobs over 64 MiB (`sync.too_large`).
pub const MAX_BLOB: usize = 64 << 20;

pub trait BlobStore: Send + Sync {
    fn put(&self, sha256: &str, bytes: &[u8]) -> anyhow::Result<()>;
    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>>;
    fn has(&self, sha256: &str) -> anyhow::Result<bool>;
    /// Batched existence check; HTTP stores avoid one round trip per reused replica chunk.
    fn missing(&self, hashes: &[String]) -> anyhow::Result<Vec<String>> {
        let mut missing = Vec::new();
        for hash in hashes {
            if !self.has(hash)? {
                missing.push(hash.clone());
            }
        }
        Ok(missing)
    }
    /// Names every blob this machine's history needs, so the store's GC keeps them (`POST /v1/sync/roots`).
    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()>;
    /// Reads a named root's verified tree. Older/custom stores may not support recovery.
    fn get_root(&self, _pair: &str) -> anyhow::Result<Vec<String>> {
        bail!("this store does not support reading roots")
    }
    fn describe(&self) -> String;
}

/// The tree blob a root names: `cmux-sync-tree 1`, then one hash per line (cmux-platform README, "Sync blob store").
pub fn tree_bytes(hashes: &[String]) -> Vec<u8> {
    let mut text = String::from("cmux-sync-tree 1\n");
    for hash in hashes {
        text.push_str(hash);
        text.push('\n');
    }
    text.into_bytes()
}

pub(crate) fn validate_hash(hash: &str) -> anyhow::Result<()> {
    if hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
        bail!("invalid sync blob hash");
    }
    Ok(())
}

pub(crate) fn validate_pair(pair: &str) -> anyhow::Result<()> {
    if pair.is_empty()
        || pair.len() > 128
        || pair == "."
        || pair == ".."
        || !pair.bytes().all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        bail!("invalid sync root pair");
    }
    Ok(())
}

fn read_tree(store: &dyn BlobStore, hash: &str) -> anyhow::Result<Vec<String>> {
    validate_hash(hash)?;
    let bytes = store.get(hash)?;
    if bytes.len() > MAX_BLOB || crate::sha256_hex(&bytes) != hash {
        bail!("sync root tree digest mismatch or oversized tree");
    }
    let mut lines = std::str::from_utf8(&bytes)?.lines();
    if lines.next() != Some("cmux-sync-tree 1") {
        bail!("unsupported sync root tree");
    }
    lines
        .map(|line| {
            validate_hash(line)?;
            Ok(line.to_string())
        })
        .collect()
}

/// A folder laid out as the store lays out R2: `<sha[0..2]>/<sha>`.
pub struct FsStore {
    dir: PathBuf,
}

impl FsStore {
    pub fn new(dir: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir)?;
        Ok(Self { dir })
    }

    fn path(&self, sha256: &str) -> PathBuf {
        self.dir.join(&sha256[..2]).join(sha256)
    }
}

impl BlobStore for FsStore {
    fn put(&self, sha256: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if bytes.len() > MAX_BLOB {
            bail!("sync.too_large");
        }
        if crate::sha256_hex(bytes) != sha256 {
            bail!("sync.digest_mismatch");
        }
        let path = self.path(sha256);
        if path.exists() {
            return Ok(());
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        crate::write_durable(&path, bytes)?;
        Ok(())
    }

    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>> {
        validate_hash(sha256)?;
        use std::io::Read;
        let file = std::fs::File::open(self.path(sha256))
            .with_context(|| format!("sync.blob_not_found {sha256}"))?;
        let mut bytes = Vec::new();
        file.take(MAX_BLOB as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > MAX_BLOB {
            bail!("sync.too_large");
        }
        Ok(bytes)
    }

    fn has(&self, sha256: &str) -> anyhow::Result<bool> {
        validate_hash(sha256)?;
        Ok(self.path(sha256).exists())
    }

    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        validate_pair(pair)?;
        for hash in hashes {
            validate_hash(hash)?;
        }
        let tree = tree_bytes(hashes);
        let sha = crate::sha256_hex(&tree);
        self.put(&sha, &tree)?;
        let roots = self.dir.join("roots");
        std::fs::create_dir_all(&roots)?;
        crate::write_durable(&roots.join(pair), sha.as_bytes())?;
        Ok(())
    }

    fn get_root(&self, pair: &str) -> anyhow::Result<Vec<String>> {
        validate_pair(pair)?;
        use std::io::Read;
        let mut hash = String::new();
        std::fs::File::open(self.dir.join("roots").join(pair))?
            .take(129)
            .read_to_string(&mut hash)?;
        read_tree(self, hash.trim())
    }

    fn describe(&self) -> String {
        format!("folder {}", self.dir.display())
    }
}

/// The signed-in person's `/v1/sync` store.
pub struct HttpStore {
    origin: String,
    credential: String,
    http: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

const TRIES: u32 = 4;

impl HttpStore {
    pub fn new(origin: &str, credential: &str) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime =
            tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build()?;
        let http = cmux_egress::client_builder("cmux_session_cloud::store")
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux-session-cloud/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(120))
            .build()?;
        Ok(Self {
            origin: origin.trim_end_matches('/').to_string(),
            credential: credential.to_string(),
            http,
            runtime,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.origin)
    }

    async fn post_json(
        &self,
        path: &str,
        body: serde_json::Value,
    ) -> anyhow::Result<serde_json::Value> {
        let response = self
            .http
            .post(self.url(path))
            .bearer_auth(&self.credential)
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow!("the store did not answer: {}", e.without_url()))?;
        let status = response.status();
        let value: serde_json::Value = response.json().await.unwrap_or(serde_json::Value::Null);
        if !status.is_success() {
            let code = value.get("code").and_then(|c| c.as_str()).unwrap_or("");
            bail!("the store refused {path}: {} {code}", status.as_u16());
        }
        Ok(value)
    }
}

impl BlobStore for HttpStore {
    fn put(&self, sha256: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if bytes.len() > MAX_BLOB {
            bail!("sync.too_large: {} bytes", bytes.len());
        }
        let url = self.url(&format!("/v1/sync/blobs/{sha256}"));
        self.runtime.block_on(async {
            let mut last = anyhow!("the store did not answer");
            for attempt in 0..TRIES {
                if attempt > 0 {
                    tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
                }
                let sent = self
                    .http
                    .put(&url)
                    .bearer_auth(&self.credential)
                    .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
                    .body(bytes.to_vec())
                    .send()
                    .await;
                match sent {
                    Ok(r) if r.status().is_success() => return Ok(()),
                    Ok(r) if r.status().is_server_error() => {
                        last = anyhow!("the store answered {}", r.status().as_u16());
                    }
                    Ok(r) => bail!("the store refused a blob: {}", r.status().as_u16()),
                    Err(e) => last = anyhow!("the store did not answer: {}", e.without_url()),
                }
            }
            Err(last)
        })
    }

    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>> {
        validate_hash(sha256)?;
        let url = self.url(&format!("/v1/sync/blobs/{sha256}"));
        self.runtime.block_on(async {
            let mut last = anyhow!("the store did not answer");
            for attempt in 0..TRIES {
                if attempt > 0 {
                    tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
                }
                match self.http.get(&url).bearer_auth(&self.credential).send().await {
                    Ok(mut r) if r.status().is_success() => {
                        let mut bytes = Vec::new();
                        while let Some(chunk) =
                            r.chunk().await.map_err(|e| anyhow!("{}", e.without_url()))?
                        {
                            if bytes.len().saturating_add(chunk.len()) > MAX_BLOB {
                                bail!("sync.too_large");
                            }
                            bytes.extend_from_slice(&chunk);
                        }
                        return Ok(bytes);
                    }
                    Ok(r) if r.status().is_server_error() => {
                        last = anyhow!("the store answered {}", r.status().as_u16());
                    }
                    Ok(r) => bail!("the store refused {sha256}: {}", r.status().as_u16()),
                    Err(e) => last = anyhow!("the store did not answer: {}", e.without_url()),
                }
            }
            Err(last)
        })
    }

    fn has(&self, sha256: &str) -> anyhow::Result<bool> {
        let answer = self.runtime.block_on(
            self.post_json("/v1/sync/blobs/missing", serde_json::json!({ "sha256": [sha256] })),
        )?;
        let missing =
            answer.get("missing").and_then(|m| m.as_array()).context("no missing list")?;
        Ok(missing.is_empty())
    }

    fn missing(&self, hashes: &[String]) -> anyhow::Result<Vec<String>> {
        for hash in hashes {
            validate_hash(hash)?;
        }
        let mut missing = Vec::new();
        // SyncMissingRequest accepts at most 1000 hashes.
        for batch in hashes.chunks(1000) {
            let answer = self.runtime.block_on(
                self.post_json("/v1/sync/blobs/missing", serde_json::json!({ "sha256": batch })),
            )?;
            let values =
                answer.get("missing").and_then(|m| m.as_array()).context("no missing list")?;
            if values.len() > batch.len() {
                bail!("invalid missing list");
            }
            for value in values {
                let hash = value.as_str().context("invalid missing hash")?;
                if !batch.iter().any(|requested| requested == hash) {
                    bail!("unexpected missing hash");
                }
                missing.push(hash.to_string());
            }
        }
        Ok(missing)
    }

    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        validate_pair(pair)?;
        for hash in hashes {
            validate_hash(hash)?;
        }
        let tree = tree_bytes(hashes);
        let sha = crate::sha256_hex(&tree);
        self.put(&sha, &tree)?;
        self.runtime.block_on(
            self.post_json("/v1/sync/roots", serde_json::json!({ "pair": pair, "tree": sha })),
        )?;
        Ok(())
    }

    fn get_root(&self, pair: &str) -> anyhow::Result<Vec<String>> {
        validate_pair(pair)?;
        // SyncRootRead is { pair, tree, registeredAt }; the tree remains an immutable blob.
        let hash = self.runtime.block_on(async {
            let mut response = self
                .http
                .get(self.url(&format!("/v1/sync/roots/{pair}")))
                .bearer_auth(&self.credential)
                .send()
                .await
                .map_err(|e| anyhow!("the store did not answer: {}", e.without_url()))?;
            if !response.status().is_success() {
                bail!("the store refused root read: {}", response.status().as_u16());
            }
            let mut bytes = Vec::new();
            while let Some(chunk) =
                response.chunk().await.map_err(|e| anyhow!("{}", e.without_url()))?
            {
                if bytes.len().saturating_add(chunk.len()) > 4096 {
                    bail!("oversized root response");
                }
                bytes.extend_from_slice(&chunk);
            }
            let value: serde_json::Value = serde_json::from_slice(&bytes)?;
            if value.get("pair").and_then(|v| v.as_str()) != Some(pair) {
                bail!("root response names another pair");
            }
            Ok::<_, anyhow::Error>(
                value.get("tree").and_then(|v| v.as_str()).context("root has no tree")?.to_string(),
            )
        })?;
        read_tree(self, &hash)
    }

    fn describe(&self) -> String {
        format!("{} /v1/sync", self.origin)
    }
}
