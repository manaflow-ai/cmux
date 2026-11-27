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
    /// Names every blob this machine's history needs, so the store's GC keeps them (`POST /v1/sync/roots`).
    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()>;
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

    fn path(&self, sha256: &str) -> anyhow::Result<PathBuf> {
        if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("sync.invalid_digest");
        }
        let prefix = sha256.get(..2).ok_or_else(|| anyhow::anyhow!("sync.invalid_digest"))?;
        Ok(self.dir.join(prefix).join(sha256))
    }
}

impl BlobStore for FsStore {
    fn put(&self, sha256: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if crate::sha256_hex(bytes) != sha256 {
            bail!("sync.digest_mismatch");
        }
        let path = self.path(sha256)?;
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
        std::fs::read(self.path(sha256)?).with_context(|| format!("sync.blob_not_found {sha256}"))
    }

    fn has(&self, sha256: &str) -> anyhow::Result<bool> {
        Ok(self.path(sha256)?.exists())
    }

    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        let tree = tree_bytes(hashes);
        let sha = crate::sha256_hex(&tree);
        self.put(&sha, &tree)?;
        let roots = self.dir.join("roots");
        std::fs::create_dir_all(&roots)?;
        crate::write_durable(&roots.join(pair), sha.as_bytes())?;
        Ok(())
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
        let url = self.url(&format!("/v1/sync/blobs/{sha256}"));
        self.runtime.block_on(async {
            let mut last = anyhow!("the store did not answer");
            for attempt in 0..TRIES {
                if attempt > 0 {
                    tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
                }
                match self.http.get(&url).bearer_auth(&self.credential).send().await {
                    Ok(r) if r.status().is_success() => {
                        return Ok(r
                            .bytes()
                            .await
                            .map_err(|e| anyhow!("{}", e.without_url()))?
                            .to_vec());
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

    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        let tree = tree_bytes(hashes);
        let sha = crate::sha256_hex(&tree);
        self.put(&sha, &tree)?;
        self.runtime.block_on(
            self.post_json("/v1/sync/roots", serde_json::json!({ "pair": pair, "tree": sha })),
        )?;
        Ok(())
    }

    fn describe(&self) -> String {
        format!("{} /v1/sync", self.origin)
    }
}
