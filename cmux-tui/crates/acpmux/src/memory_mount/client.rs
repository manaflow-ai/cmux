//! The memory store's HTTP API on cmux-platform (`/v1/memory/{scope}/...`), with this machine's
//! join credential as the bearer (the same one the dependency cache sends, `deps/remote.rs`).
//! The credential is never printed: errors name the route and status only.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use super::Scope;

/// One file's row in the tree and in a watch push.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub path: String,
    pub version: u64,
    #[serde(default)]
    pub sha256: String,
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub mtime: Option<serde_json::Value>,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub seq: u64,
    #[serde(default)]
    pub author: Option<String>,
}

/// `GET .../tree?since=` and each watch answer.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tree {
    pub seq: u64,
    #[serde(default)]
    pub entries: Vec<Entry>,
}

/// The version the store holds now, from a 409.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Current {
    pub version: u64,
    #[serde(default)]
    pub sha256: String,
}

/// What a PUT or DELETE did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wrote {
    /// Stored as `version`.
    Ok { version: u64 },
    /// The store's version is not the one we named (`memory.conflict`).
    Conflict(Option<Current>),
    /// The store's secret scan refused the file (`memory.secret_refused`).
    SecretRefused,
    /// Over the store's size limit (`memory.too_large`).
    TooLarge,
}

/// The memory store has no `/v1/memory` route yet (an older cmux-platform): the daemon backs
/// off for minutes, quietly.
#[derive(Debug)]
pub struct NotDeployed;

impl std::fmt::Display for NotDeployed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the memory store is not deployed on this cmux Cloud (404 on /v1/memory)")
    }
}

impl std::error::Error for NotDeployed {}

#[derive(Clone)]
pub struct Client {
    origin: String,
    bearer: String,
    http: reqwest::Client,
}

impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Client").field("origin", &self.origin).finish_non_exhaustive()
    }
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    code: String,
    #[serde(default)]
    current: Option<Current>,
}

#[derive(Deserialize, Default)]
struct PutBody {
    #[serde(default)]
    version: Option<u64>,
}

impl Client {
    /// This machine's client, or `None` when it is not joined to cmux Cloud.
    pub fn joined() -> Result<Option<Client>> {
        let Some((origin, bearer)) = crate::deps::remote::Remote::joined_bearer()? else {
            return Ok(None);
        };
        Ok(Some(Client::new(origin, bearer)?))
    }

    pub fn new(origin: String, bearer: String) -> Result<Client> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = crate::happy_dial::http_client()
            .default_headers(cmux_build_space::headers()?)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .context("build the memory store client")?;
        Ok(Client { origin: origin.trim_end_matches('/').to_owned(), bearer, http })
    }

    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// `{origin}/v1/memory/{scope}/{kind}/{path...}`, each path part escaped on its own.
    fn url(&self, scope: Scope, kind: &str, path: &str) -> Result<reqwest::Url> {
        let mut url = reqwest::Url::parse(&self.origin).context("memory store origin")?;
        {
            let mut segments =
                url.path_segments_mut().map_err(|()| anyhow::anyhow!("origin is no base URL"))?;
            segments.pop_if_empty().extend(["v1", "memory", scope.as_str(), kind]);
            segments.extend(path.split('/').filter(|p| !p.is_empty()));
        }
        Ok(url)
    }

    fn request(&self, method: reqwest::Method, url: reqwest::Url) -> reqwest::RequestBuilder {
        self.http.request(method, url).bearer_auth(&self.bearer)
    }

    /// Everything that changed after `since` (0: the whole tree, tombstones included).
    pub async fn tree(&self, scope: Scope, since: u64) -> Result<Tree> {
        let mut url = self.url(scope, "tree", "")?;
        url.query_pairs_mut().append_pair("since", &since.to_string());
        let response = self
            .request(reqwest::Method::GET, url)
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .context("memory tree")?;
        read_tree(response, "tree").await
    }

    /// The next change after `since`: a 25 s long-poll (the store answers an empty `entries`
    /// when nothing changed in that time).
    pub async fn watch(&self, scope: Scope, since: u64) -> Result<Tree> {
        let mut url = self.url(scope, "watch", "")?;
        url.query_pairs_mut().append_pair("since", &since.to_string());
        let response = self
            .request(reqwest::Method::GET, url)
            .timeout(Duration::from_secs(40))
            .send()
            .await
            .context("memory watch")?;
        if response.status() == reqwest::StatusCode::NO_CONTENT {
            return Ok(Tree { seq: since, entries: Vec::new() });
        }
        read_tree(response, "watch").await
    }

    /// A file's bytes, or `None` when the store has none (or only a tombstone).
    pub async fn get(&self, scope: Scope, path: &str) -> Result<Option<Vec<u8>>> {
        let response = self
            .request(reqwest::Method::GET, self.url(scope, "file", path)?)
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .context("memory get")?;
        match response.status() {
            s if s.is_success() => Ok(Some(response.bytes().await?.to_vec())),
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::GONE => {
                let code = error_code(response).await.code;
                if code.is_empty() || code == "memory.not_found" || code == "memory.deleted" {
                    // `memory.not_found` with no route at all reads the same; tree tells them apart.
                    Ok(None)
                } else {
                    bail!("memory get: {code}")
                }
            }
            s => bail!("memory get {path}: {s} {}", error_code(response).await.code),
        }
    }

    /// Store `bytes` at `path` when the store's version is `if_match` (0: when it has none).
    pub async fn put(
        &self,
        scope: Scope,
        path: &str,
        bytes: Vec<u8>,
        if_match: u64,
        mtime_ms: Option<u64>,
        author: &str,
    ) -> Result<Wrote> {
        let mut request = self
            .request(reqwest::Method::PUT, self.url(scope, "file", path)?)
            .timeout(Duration::from_secs(60))
            .header("If-Match-Version", if_match.to_string())
            .header("X-Memory-Author", author)
            .body(bytes);
        if let Some(mtime) = mtime_ms {
            request = request.header("X-Memory-Mtime", mtime.to_string());
        }
        let response = request.send().await.context("memory put")?;
        wrote(response, if_match, "put").await
    }

    /// Delete `path` (a tombstone) when the store's version is `if_match`.
    pub async fn delete(
        &self,
        scope: Scope,
        path: &str,
        if_match: u64,
        author: &str,
    ) -> Result<Wrote> {
        let response = self
            .request(reqwest::Method::DELETE, self.url(scope, "file", path)?)
            .timeout(Duration::from_secs(60))
            .header("If-Match-Version", if_match.to_string())
            .header("X-Memory-Author", author)
            .send()
            .await
            .context("memory delete")?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(Wrote::Ok { version: if_match });
        }
        wrote(response, if_match, "delete").await
    }

    /// A file's versions, as the store answers them.
    pub async fn history(&self, scope: Scope, path: &str) -> Result<serde_json::Value> {
        let response = self
            .request(reqwest::Method::GET, self.url(scope, "history", path)?)
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .context("memory history")?;
        let status = response.status();
        if !status.is_success() {
            bail!("memory history {path}: {status} {}", error_code(response).await.code);
        }
        response.json().await.context("memory history body")
    }
}

async fn error_code(response: reqwest::Response) -> ErrorBody {
    let bytes = response.bytes().await.unwrap_or_default();
    serde_json::from_slice(&bytes).unwrap_or(ErrorBody { code: String::new(), current: None })
}

async fn read_tree(response: reqwest::Response, what: &str) -> Result<Tree> {
    let status = response.status();
    if status == reqwest::StatusCode::NOT_FOUND {
        return Err(NotDeployed.into());
    }
    if !status.is_success() {
        bail!("memory {what}: {status} {}", error_code(response).await.code);
    }
    response.json().await.with_context(|| format!("memory {what} body"))
}

async fn wrote(response: reqwest::Response, if_match: u64, what: &str) -> Result<Wrote> {
    let status = response.status();
    if status.is_success() {
        let bytes = response.bytes().await.unwrap_or_default();
        let body: PutBody = serde_json::from_slice(&bytes).unwrap_or_default();
        return Ok(Wrote::Ok { version: body.version.unwrap_or(if_match + 1) });
    }
    let body = error_code(response).await;
    match (status.as_u16(), body.code.as_str()) {
        (409, _) | (412, _) => Ok(Wrote::Conflict(body.current)),
        (422, _) | (_, "memory.secret_refused") => Ok(Wrote::SecretRefused),
        (413, _) | (_, "memory.too_large") => Ok(Wrote::TooLarge),
        _ => bail!("memory {what}: {status} {}", body.code),
    }
}
