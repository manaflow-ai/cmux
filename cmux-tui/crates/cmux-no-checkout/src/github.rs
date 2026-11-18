//! The GitHub REST calls a no-checkout chat makes: one branch read, one tree read, blob reads,
//! and the git data writes (blob, tree, commit, ref) plus the pull request.
//!
//! - The token is for one repository (the App installation token `cmux github` mints); it lives
//!   in this process's memory only and goes only to [`GitHub::api`]. No token reads a public
//!   repository anonymously.
//! - Every call has a deadline ([`CALL_TIMEOUT`]); a reply is read up to [`MAX_REPLY_BYTES`] and
//!   refused past it, by name.
//! - [`Meter`] counts calls and body bytes each way, so a chat (and the bench) can say what moved.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context as _, bail};
use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

pub const GITHUB_API: &str = "https://api.github.com";
/// One call, connect to last byte.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(60);
// timeout: the TCP and TLS connect only; the call itself has CALL_TIMEOUT
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// GitHub's blob API serves blobs up to 100 MB; a reply past this is refused, not truncated.
pub const MAX_REPLY_BYTES: u64 = 128 << 20;

/// A repository-scoped GitHub token, held in memory only.
pub type Token = Option<Zeroizing<String>>;

/// Calls and body bytes each way.
#[derive(Debug, Default)]
pub struct Meter {
    calls: AtomicU64,
    up: AtomicU64,
    down: AtomicU64,
}

impl Meter {
    #[must_use]
    pub fn calls(&self) -> u64 {
        self.calls.load(Ordering::Relaxed)
    }
    #[must_use]
    pub fn bytes_up(&self) -> u64 {
        self.up.load(Ordering::Relaxed)
    }
    #[must_use]
    pub fn bytes_down(&self) -> u64 {
        self.down.load(Ordering::Relaxed)
    }
}

/// GitHub answered a call with an error status.
#[derive(Debug)]
pub struct ApiError {
    pub what: String,
    pub status: u16,
    pub message: String,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: GitHub answered {} {}", self.what, self.status, self.message)
    }
}

impl std::error::Error for ApiError {}

/// A commit and its tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Head {
    pub commit: String,
    pub tree: String,
}

/// One entry of a recursive tree read.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub mode: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub sha: String,
    #[serde(default)]
    pub size: Option<u64>,
}

impl Entry {
    #[must_use]
    pub fn is_file(&self) -> bool {
        self.kind == "blob"
    }
}

/// A change to one path of a tree: its new blob (with its mode), or `None` to delete it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeChange {
    pub path: String,
    pub blob: Option<(String, String)>,
}

/// An opened pull request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pull {
    pub number: u64,
    pub url: String,
}

/// The REST client for one repository.
#[derive(Clone)]
pub struct GitHub {
    http: reqwest::Client,
    api: String,
    repo: String,
    token: Arc<Token>,
    meter: Arc<Meter>,
}

fn check_repo(repo: &str) -> anyhow::Result<()> {
    let ok = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    match repo.split_once('/') {
        Some((owner, name)) if ok(owner) && ok(name) => Ok(()),
        _ => bail!("{repo:?} is not an OWNER/NAME GitHub repository"),
    }
}

/// A path segment of a URL: a branch name or a tree path, each part escaped.
fn escape(path: &str) -> String {
    path.split('/')
        .map(|part| {
            part.bytes()
                .map(|b| {
                    if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
                        (b as char).to_string()
                    } else {
                        format!("%{b:02X}")
                    }
                })
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("/")
}

impl GitHub {
    /// A client for `repo` (`OWNER/NAME`) at `api` (GitHub's, or a loopback stand-in in tests).
    /// `proxy` sends every call through an HTTP CONNECT proxy (the bench's byte counter).
    pub fn new(api: &str, repo: &str, token: Token, proxy: Option<&str>) -> anyhow::Result<Self> {
        check_repo(repo)?;
        let url = reqwest::Url::parse(api).context("the API is not a URL")?;
        let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(url.scheme() == "https" || loopback) {
            bail!("{api} is not an https API; the token goes only to one");
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(CALL_TIMEOUT)
            .user_agent(concat!("cmux-no-checkout/", env!("CARGO_PKG_VERSION")));
        builder = match proxy {
            Some(proxy) => builder.proxy(reqwest::Proxy::all(proxy)?),
            None => builder.no_proxy(),
        };
        Ok(Self {
            http: builder.build().context("could not start an HTTP client")?,
            api: api.trim_end_matches('/').to_owned(),
            repo: repo.to_owned(),
            token: Arc::new(token),
            meter: Arc::default(),
        })
    }

    #[must_use]
    pub fn repo(&self) -> &str {
        &self.repo
    }

    #[must_use]
    pub fn api(&self) -> &str {
        &self.api
    }

    #[must_use]
    pub fn meter(&self) -> &Meter {
        &self.meter
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
        raw: bool,
    ) -> anyhow::Result<Vec<u8>> {
        let url = format!("{}/repos/{}{path}", self.api, self.repo);
        let accept = if raw { "application/vnd.github.raw" } else { "application/vnd.github+json" };
        let mut request = self
            .http
            .request(method.clone(), &url)
            .header("accept", accept)
            .header("x-github-api-version", "2022-11-28");
        if let Some(token) = self.token.as_ref() {
            request = request.bearer_auth(token.as_str());
        }
        if let Some(body) = body {
            let bytes = serde_json::to_vec(body)?;
            self.meter.up.fetch_add(bytes.len() as u64, Ordering::Relaxed);
            request = request.header("content-type", "application/json").body(bytes);
        }
        self.meter.calls.fetch_add(1, Ordering::Relaxed);
        let mut response = request
            .send()
            .await
            .with_context(|| format!("{method} {path}: GitHub did not answer"))?;
        let status = response.status();
        let mut bytes = Vec::new();
        while let Some(chunk) =
            response.chunk().await.with_context(|| format!("{method} {path}"))?
        {
            bytes.extend_from_slice(&chunk);
            if bytes.len() as u64 > MAX_REPLY_BYTES {
                bail!("{method} {path}: GitHub's answer is past {MAX_REPLY_BYTES} bytes");
            }
        }
        self.meter.down.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        if !status.is_success() {
            let message = serde_json::from_slice::<Value>(&bytes)
                .ok()
                .and_then(|v| v["message"].as_str().map(str::to_owned))
                .unwrap_or_default();
            return Err(ApiError {
                what: format!("{method} {path}"),
                status: status.as_u16(),
                message,
            }
            .into());
        }
        Ok(bytes)
    }

    async fn json(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
    ) -> anyhow::Result<Value> {
        let bytes = self.call(method.clone(), path, body, false).await?;
        serde_json::from_slice(&bytes).with_context(|| format!("{method} {path}: not JSON"))
    }

    /// The default branch's name.
    pub async fn default_branch(&self) -> anyhow::Result<String> {
        let repo = self.json(reqwest::Method::GET, "", None).await?;
        repo["default_branch"].as_str().map(str::to_owned).context("no default branch")
    }

    /// The commit `branch` points at, and its tree.
    pub async fn branch_head(&self, branch: &str) -> anyhow::Result<Head> {
        let v =
            self.json(reqwest::Method::GET, &format!("/branches/{}", escape(branch)), None).await?;
        let commit = v["commit"]["sha"].as_str().context("the branch names no commit")?;
        let tree =
            v["commit"]["commit"]["tree"]["sha"].as_str().context("the commit has no tree")?;
        Ok(Head { commit: commit.to_owned(), tree: tree.to_owned() })
    }

    /// Every entry of `tree`, recursively; refused by name when GitHub truncates it (past 100,000
    /// entries or 7 MB), which Auto sends to a checkout.
    pub async fn tree(&self, tree: &str) -> anyhow::Result<Vec<Entry>> {
        let v = self
            .json(reqwest::Method::GET, &format!("/git/trees/{}?recursive=1", escape(tree)), None)
            .await?;
        if v["truncated"] == true {
            bail!("the tree is too big to list in one read (GitHub truncated it): use a checkout");
        }
        Ok(serde_json::from_value(v["tree"].clone())?)
    }

    /// A blob's bytes: every read of a file's bytes goes through here.
    // TODO(lane/projected-fleet-checkouts): ask cmux-projection's machine-wide blob cache
    // (`blob_cache::BlobSource`) first once that branch lands, so a blob read once on the machine
    // is never fetched again.
    pub async fn blob(&self, sha: &str) -> anyhow::Result<Vec<u8>> {
        self.call(reqwest::Method::GET, &format!("/git/blobs/{}", escape(sha)), None, true).await
    }

    /// Stores `bytes` as a blob and answers its sha.
    pub async fn create_blob(&self, bytes: &[u8]) -> anyhow::Result<String> {
        let content = base64::engine::general_purpose::STANDARD.encode(bytes);
        let body = json!({"content": content, "encoding": "base64"});
        let v = self.json(reqwest::Method::POST, "/git/blobs", Some(&body)).await?;
        v["sha"].as_str().map(str::to_owned).context("no blob sha")
    }

    /// A tree that is `base` with `changes`.
    pub async fn create_tree(&self, base: &str, changes: &[TreeChange]) -> anyhow::Result<String> {
        let entries: Vec<Value> = changes
            .iter()
            .map(|c| match &c.blob {
                Some((sha, mode)) => {
                    json!({"path": c.path, "mode": mode, "type": "blob", "sha": sha})
                }
                None => json!({"path": c.path, "mode": "100644", "type": "blob", "sha": null}),
            })
            .collect();
        let body = json!({"base_tree": base, "tree": entries});
        let v = self.json(reqwest::Method::POST, "/git/trees", Some(&body)).await?;
        v["sha"].as_str().map(str::to_owned).context("no tree sha")
    }

    /// A commit of `tree` on `parent`.
    pub async fn create_commit(
        &self,
        message: &str,
        tree: &str,
        parent: &str,
    ) -> anyhow::Result<String> {
        let body = json!({"message": message, "tree": tree, "parents": [parent]});
        let v = self.json(reqwest::Method::POST, "/git/commits", Some(&body)).await?;
        v["sha"].as_str().map(str::to_owned).context("no commit sha")
    }

    /// Points `branch` at `commit`: a new branch, or a fast-forward of an existing one (never a
    /// force).
    pub async fn set_branch(&self, branch: &str, commit: &str) -> anyhow::Result<()> {
        let create = json!({"ref": format!("refs/heads/{branch}"), "sha": commit});
        match self.json(reqwest::Method::POST, "/git/refs", Some(&create)).await {
            Ok(_) => Ok(()),
            // 422: the ref exists already.
            Err(e) if e.downcast_ref::<ApiError>().is_some_and(|a| a.status == 422) => {
                let update = json!({"sha": commit, "force": false});
                let path = format!("/git/refs/heads/{}", escape(branch));
                self.json(reqwest::Method::PATCH, &path, Some(&update)).await.map(drop)
            }
            Err(e) => Err(e),
        }
    }

    /// Opens a pull request of `head` into `base`.
    pub async fn open_pull(
        &self,
        title: &str,
        body: &str,
        head: &str,
        base: &str,
        draft: bool,
    ) -> anyhow::Result<Pull> {
        let req = json!({"title": title, "body": body, "head": head, "base": base, "draft": draft});
        let v = self.json(reqwest::Method::POST, "/pulls", Some(&req)).await?;
        Ok(Pull {
            number: v["number"].as_u64().context("no pull request number")?,
            url: v["html_url"].as_str().unwrap_or_default().to_owned(),
        })
    }

    /// Closes pull request `number` unmerged.
    pub async fn close_pull(&self, number: u64) -> anyhow::Result<()> {
        let body = json!({"state": "closed"});
        self.json(reqwest::Method::PATCH, &format!("/pulls/{number}"), Some(&body)).await.map(drop)
    }

    /// Deletes `branch`.
    pub async fn delete_branch(&self, branch: &str) -> anyhow::Result<()> {
        let path = format!("/git/refs/heads/{}", escape(branch));
        self.call(reqwest::Method::DELETE, &path, None, false).await.map(drop)
    }
}

/// The git data writes a commit needs, and the pull request after it: the one seam where a writer
/// other than this REST client stands in (on a lane VM with no token, a broker that makes these
/// calls for it). [`GitHub`] is the REST one.
#[async_trait::async_trait]
pub trait GitWriter: Send + Sync {
    /// Stores `bytes` as a blob; answers its sha.
    async fn create_blob(&self, bytes: &[u8]) -> anyhow::Result<String>;
    /// A tree that is `base` with `changes`; answers its sha.
    async fn create_tree(&self, base: &str, changes: &[TreeChange]) -> anyhow::Result<String>;
    /// A commit of `tree` on `parent`; answers its sha.
    async fn create_commit(
        &self,
        message: &str,
        tree: &str,
        parent: &str,
    ) -> anyhow::Result<String>;
    /// `branch` at `commit`: created, or fast-forwarded (never forced).
    async fn set_branch(&self, branch: &str, commit: &str) -> anyhow::Result<()>;
    /// A pull request of `head` into `base`.
    async fn open_pull(
        &self,
        title: &str,
        body: &str,
        head: &str,
        base: &str,
        draft: bool,
    ) -> anyhow::Result<Pull>;
}

#[async_trait::async_trait]
impl GitWriter for GitHub {
    async fn create_blob(&self, bytes: &[u8]) -> anyhow::Result<String> {
        Self::create_blob(self, bytes).await
    }
    async fn create_tree(&self, base: &str, changes: &[TreeChange]) -> anyhow::Result<String> {
        Self::create_tree(self, base, changes).await
    }
    async fn create_commit(
        &self,
        message: &str,
        tree: &str,
        parent: &str,
    ) -> anyhow::Result<String> {
        Self::create_commit(self, message, tree, parent).await
    }
    async fn set_branch(&self, branch: &str, commit: &str) -> anyhow::Result<()> {
        Self::set_branch(self, branch, commit).await
    }
    async fn open_pull(
        &self,
        title: &str,
        body: &str,
        head: &str,
        base: &str,
        draft: bool,
    ) -> anyhow::Result<Pull> {
        Self::open_pull(self, title, body, head, base, draft).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_owner_name_repositories_and_https_or_loopback_apis() {
        for ok in ["pallets/click", "a-b/c.d_e"] {
            assert!(GitHub::new(GITHUB_API, ok, None, None).is_ok(), "{ok}");
        }
        for bad in ["", "a", "a/b/c", "../x", "a/..", "a/b c", "a/b?x"] {
            assert!(GitHub::new(GITHUB_API, bad, None, None).is_err(), "{bad}");
        }
        assert!(GitHub::new("http://api.github.com", "a/b", None, None).is_err());
        assert!(GitHub::new("http://127.0.0.1:9", "a/b", None, None).is_ok());
    }

    #[test]
    fn url_parts_are_escaped() {
        assert_eq!(escape("feat/a b#c"), "feat/a%20b%23c");
        assert_eq!(escape("main"), "main");
    }
}
