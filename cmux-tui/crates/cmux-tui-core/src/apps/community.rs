//! The App Store's Community source (extensions-in-git, "Obsidian model"
//! sections E and F): the public registry's index of community extensions
//! and setups, merged into `catalog.list` / `catalog.get`, and the installed
//! community items a person's devices share.
//!
//! - `catalog.list {source: "community", query?, category?, kind?, sort?,
//!   cursor?, limit?, refresh?}` answers community rows from the cached index
//!   (never the network): `{source, listings, next_cursor, fetched_at, stale,
//!   refreshing, error?, on_other_devices}`.
//! - `catalog.get {source: "community", ref}` answers one row plus its
//!   `readme` (markdown), `changelog`, `screenshots`, `license`.
//! - Install from a row is `apps.install {app: row.install_app}`
//!   (`HOST/OWNER/REPO[/PATH]@COMMIT`, the reviewed commit): the git install
//!   path and its consent card, never anything here.
//! - `apps.community.installs` answers `{here, elsewhere}`: the community
//!   (git) apps installed on this machine, which a sync pushes to the
//!   person's account, and the ones the account says another device has
//!   that this one lacks ("Install on this Mac"; consent card each time).
//! - `apps.community.synced.put {items, idempotency_key}` stores what the
//!   account synced down (verified app connection only, `store_op_mutates`).
//!
//! The index comes from the registry (`GET /v1/extensions`, `/v1/setups`)
//! on a background thread, bounded (pages, bytes, time), cached on disk with
//! a TTL and read offline. A stale or failed fetch only marks the answer
//! `stale` / `error`; the local catalog never waits on it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::store::{bad_request, params, to_value};
use super::supervisor::{ApiError, Supervisor, now_ms};
use crate::panic_free::RecoverPoison;

/// The registry's production origin (cmux-platform); `CMUX_EXTENSIONS_REGISTRY`
/// points a build at another one.
pub(super) const DEFAULT_REGISTRY: &str = "https://cmux-platform-production.debussy.workers.dev";
const REGISTRY_ENV: &str = "CMUX_EXTENSIONS_REGISTRY";
/// How long a fetched index is fresh, and how long a failed fetch waits.
pub(super) const TTL: Duration = Duration::from_secs(60 * 60);
pub(super) const RETRY_AFTER: Duration = Duration::from_secs(5 * 60);
/// Fetch bounds: items per page, pages per kind, bytes per page, time per request.
const PAGE_LIMIT: u32 = 100;
pub(super) const MAX_PAGES: usize = 5;
pub(super) const MAX_PAGE_BYTES: usize = 8 << 20;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// The registry routes read, and the kind each one lists. Extensions are
/// required for a good refresh; setups are best effort.
const KINDS: [(&str, &str, bool); 2] =
    [("extensions", "extension", true), ("setups", "setup", false)];
const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;
const MAX_README: usize = 512 << 10;
const MAX_SYNCED: usize = 500;
const SYNCED_KINDS: [&str; 5] = ["extension", "setup", "theme", "snippet", "plugin"];

/// Reads one registry URL. An implementation bounds the time and the body
/// (`MAX_PAGE_BYTES`); Err is a one-line reason.
pub trait RegistryFetch: Send + Sync {
    fn get(&self, url: &str) -> Result<Vec<u8>, String>;
}

/// The production reader: one current-thread runtime per request, off the
/// UI path (the refresh thread).
pub struct HttpRegistryFetch;

impl RegistryFetch for HttpRegistryFetch {
    fn get(&self, url: &str) -> Result<Vec<u8>, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        runtime.block_on(async move {
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(REQUEST_TIMEOUT)
                .build()
                .map_err(|e| e.to_string())?;
            let mut response = client.get(url).send().await.map_err(|e| e.to_string())?;
            let status = response.status();
            if !status.is_success() {
                return Err(format!("registry answered {}", status.as_u16()));
            }
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
                if body.len() + chunk.len() > MAX_PAGE_BYTES {
                    return Err("registry page is larger than 8 MiB".into());
                }
                body.extend_from_slice(&chunk);
            }
            Ok(body)
        })
    }
}

/// The cached index (`<state>/apps/community/index.json`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub(super) struct Index {
    pub base: String,
    pub fetched_at: u64,
    /// Registry listings as served (kind filled in), readme included.
    pub items: Vec<Value>,
}

#[derive(Default)]
struct State {
    loaded: bool,
    index: Option<Arc<Index>>,
    refreshing: bool,
    error: Option<String>,
    failed_at: Option<Instant>,
}

pub struct Community {
    dir: Option<PathBuf>,
    base: String,
    fetch: Arc<dyn RegistryFetch>,
    state: Mutex<State>,
}

/// What a list answer says about the cache.
struct Status {
    index: Option<Arc<Index>>,
    stale: bool,
    refreshing: bool,
    error: Option<String>,
}

impl Community {
    pub fn new(state_dir: Option<&Path>, base: &str, fetch: Arc<dyn RegistryFetch>) -> Arc<Self> {
        Arc::new(Self {
            dir: state_dir.map(|d| d.join("apps").join("community")),
            base: base.trim_end_matches('/').to_string(),
            fetch,
            state: Mutex::new(State::default()),
        })
    }

    fn index_file(&self) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join("index.json"))
    }

    pub(super) fn synced_file(&self) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join("synced.json"))
    }

    /// The cached index, read from disk once (a cache of another registry is
    /// ignored), and whether a refresh is due. With `start`, a due refresh is
    /// claimed (`refreshing`), and the caller runs [`Self::refresh`].
    fn status(&self, force: bool, start: bool) -> (Status, bool) {
        let mut state = self.state.lock().recover_poison();
        if !state.loaded {
            state.loaded = true;
            state.index = self
                .index_file()
                .and_then(|path| std::fs::read(path).ok())
                .and_then(|raw| serde_json::from_slice::<Index>(&raw).ok())
                .filter(|index| index.base == self.base)
                .map(Arc::new);
        }
        let age = state.index.as_ref().map(|i| now_ms().saturating_sub(i.fetched_at));
        let stale = age.is_none_or(|age| age >= TTL.as_millis() as u64);
        let backing_off = state.failed_at.is_some_and(|at| at.elapsed() < RETRY_AFTER);
        let due = !state.refreshing && (force || (stale && !backing_off));
        if due && start {
            state.refreshing = true;
        }
        let status = Status {
            index: state.index.clone(),
            stale,
            refreshing: state.refreshing,
            error: state.error.clone(),
        };
        (status, due && start)
    }

    /// Fetches the whole index (bounded) and replaces the cache; a failure
    /// keeps the old cache and records why. Runs off the UI path.
    pub(super) fn refresh(&self) -> Result<(), String> {
        let result = fetch_index(self.fetch.as_ref(), &self.base);
        let mut state = self.state.lock().recover_poison();
        state.refreshing = false;
        match result {
            Ok(items) => {
                let index = Index { base: self.base.clone(), fetched_at: now_ms(), items };
                if let (Some(dir), Some(file)) = (&self.dir, self.index_file()) {
                    let _ = write_atomic(dir, &file, &index);
                }
                state.index = Some(Arc::new(index));
                state.error = None;
                state.failed_at = None;
                Ok(())
            }
            Err(error) => {
                state.error = Some(error.clone());
                state.failed_at = Some(Instant::now());
                Err(error)
            }
        }
    }
}

fn write_atomic(dir: &Path, file: &Path, value: &impl Serialize) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let temp = file.with_extension("json.tmp");
    std::fs::write(&temp, serde_json::to_vec(value).map_err(std::io::Error::other)?)?;
    std::fs::rename(&temp, file)
}

fn encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

/// Every listing of every kind, at most `MAX_PAGES` pages of `PAGE_LIMIT` each.
pub(super) fn fetch_index(fetch: &dyn RegistryFetch, base: &str) -> Result<Vec<Value>, String> {
    let mut items = Vec::new();
    for (route, kind, required) in KINDS {
        match fetch_kind(fetch, base, route, kind) {
            Ok(mut page) => items.append(&mut page),
            Err(error) if required => return Err(format!("{route}: {error}")),
            Err(_) => {}
        }
    }
    Ok(items)
}

fn fetch_kind(
    fetch: &dyn RegistryFetch,
    base: &str,
    route: &str,
    kind: &str,
) -> Result<Vec<Value>, String> {
    let mut items = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..MAX_PAGES {
        let mut url = format!("{base}/v1/{route}?limit={PAGE_LIMIT}");
        if let Some(cursor) = &cursor {
            url.push_str("&cursor=");
            url.push_str(&encode(cursor));
        }
        let body = fetch.get(&url)?;
        if body.len() > MAX_PAGE_BYTES {
            return Err("registry page is larger than 8 MiB".into());
        }
        let page: Value = serde_json::from_slice(&body).map_err(|e| format!("bad JSON: {e}"))?;
        let list = page["items"].as_array().ok_or("no items in the registry answer")?;
        for item in list {
            let mut item = item.clone();
            if !item["kind"].is_string() {
                item["kind"] = Value::String(kind.to_string());
            }
            if row(&item, &Installed::default()).is_some() {
                items.push(item);
            }
        }
        cursor = page["next"].as_str().filter(|c| !c.is_empty()).map(str::to_string);
        if cursor.is_none() {
            break;
        }
    }
    Ok(items)
}

/// One release of a community item.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub(super) struct Release {
    pub version: String,
    pub tag: String,
    pub commit: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
}

/// One Community row.
#[derive(Debug, Clone, Serialize)]
pub(super) struct CommunityRow {
    /// Always `community`.
    pub source: &'static str,
    /// `HOST/OWNER/REPO[/PATH]`.
    #[serde(rename = "ref")]
    pub reference: String,
    /// The manifest id, when the registry knows it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// `extension`, `setup` (later `theme`, `snippet`).
    pub kind: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tagline: Option<String>,
    pub description: String,
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author_url: Option<String>,
    /// `https://HOST/OWNER/REPO`.
    pub repository: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_url: Option<String>,
    pub categories: Vec<String>,
    /// Install pings plus release asset downloads, as the registry counts them.
    pub downloads: u64,
    pub stars: u64,
    /// ISO 8601.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_release: Option<Release>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// `engines.cmux`, e.g. `^2.0`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_cmux: Option<String>,
    /// The reviewed commit (40 hex).
    pub commit: String,
    /// What `apps.install {app}` takes to install this row: `ref@commit`.
    pub install_app: String,
    pub installed: bool,
}

/// `catalog.get {source: "community"}`.
#[derive(Debug, Serialize)]
pub(super) struct CommunityDetail {
    #[serde(flatten)]
    pub row: CommunityRow,
    /// Markdown at the reviewed commit.
    pub readme: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changelog: Option<String>,
    pub screenshots: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    pub versions: Vec<Release>,
}

fn string(item: &Value, key: &str) -> Option<String> {
    item[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

fn is_commit(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// `HOST/OWNER/REPO[/PATH]` with a dotted host and plain segments.
pub(super) fn is_ref(s: &str) -> bool {
    let parts: Vec<&str> = s.split('/').collect();
    parts.len() >= 3
        && parts[0].contains('.')
        && parts.iter().all(|p| {
            !p.is_empty()
                && *p != "."
                && *p != ".."
                && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        })
}

fn reference(item: &Value) -> Option<String> {
    let reference = string(item, "ref").or_else(|| {
        let (host, owner, repo) =
            (string(item, "host")?, string(item, "owner")?, string(item, "repo")?);
        let path = string(item, "path").map(|p| format!("/{p}")).unwrap_or_default();
        Some(format!("{host}/{owner}/{repo}{path}"))
    })?;
    is_ref(&reference).then_some(reference)
}

fn release(value: &Value) -> Option<Release> {
    Some(Release {
        version: string(value, "version")?,
        tag: string(value, "tag")?,
        commit: string(value, "commit").filter(|c| is_commit(c))?,
        date: string(value, "date"),
    })
}

/// What is installed here, to mark rows.
#[derive(Default)]
pub(super) struct Installed {
    pub apps: BTreeSet<String>,
    /// Lowercased refs.
    pub refs: BTreeSet<String>,
}

/// A registry listing as a row; `None` for a listing missing a ref or a
/// reviewed commit (never shown, never installable).
pub(super) fn row(item: &Value, installed: &Installed) -> Option<CommunityRow> {
    let reference = reference(item)?;
    let commit = string(item, "commit").filter(|c| is_commit(c))?;
    let app = string(item, "id");
    let publisher = &item["publisher"];
    let author = string(item, "author")
        .or_else(|| string(publisher, "name"))
        .or_else(|| string(item, "owner"))
        .unwrap_or_default();
    let latest_release = item
        .get("latestRelease")
        .and_then(release)
        .or_else(|| item["versions"].as_array().and_then(|v| v.first()).and_then(release));
    let downloads = item["downloads"].as_u64().or_else(|| item["installs"].as_u64()).unwrap_or(0);
    let is_installed = app.as_ref().is_some_and(|a| installed.apps.contains(a))
        || installed.refs.contains(&reference.to_lowercase());
    Some(CommunityRow {
        source: "community",
        install_app: format!("{reference}@{commit}"),
        app,
        kind: string(item, "kind").unwrap_or_else(|| "extension".into()),
        name: string(item, "name").unwrap_or_else(|| reference.clone()),
        tagline: string(item, "tagline"),
        description: string(item, "description").unwrap_or_default(),
        author,
        author_url: string(publisher, "url"),
        repository: string(item, "repository")
            .unwrap_or_else(|| format!("https://{}", repo_of(&reference))),
        page_url: string(item, "pageUrl"),
        icon_url: string(item, "iconUrl"),
        categories: strings(&item["categories"]),
        downloads,
        stars: item["stars"].as_u64().unwrap_or(0),
        updated_at: string(item, "updatedAt"),
        latest_release,
        version: string(item, "version"),
        min_cmux: string(item, "minCmux"),
        commit,
        installed: is_installed,
        reference,
    })
}

fn strings(value: &Value) -> Vec<String> {
    value.as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect()
}

/// `HOST/OWNER/REPO` of a ref.
fn repo_of(reference: &str) -> String {
    reference.split('/').take(3).collect::<Vec<_>>().join("/")
}

pub(super) fn detail(item: &Value, installed: &Installed) -> Option<CommunityDetail> {
    let row = row(item, installed)?;
    let mut readme = item["readme"].as_str().unwrap_or_default().to_string();
    if readme.len() > MAX_README {
        let mut end = MAX_README;
        while !readme.is_char_boundary(end) {
            end -= 1;
        }
        readme.truncate(end);
    }
    Some(CommunityDetail {
        row,
        readme,
        changelog: string(item, "changelog"),
        screenshots: strings(&item["screenshots"]),
        license: string(item, "license"),
        versions: item["versions"].as_array().into_iter().flatten().filter_map(release).collect(),
    })
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Sort {
    /// The registry's order (most stars first).
    Featured,
    Downloads,
    Updated,
    Stars,
    Name,
}

/// Unknown fields are ignored: the page router adds the local catalog's
/// (`developer`, `shelf`) to every `catalog.list`.
#[derive(Debug, Default, Deserialize)]
struct ListParams {
    #[allow(dead_code)]
    source: String,
    query: Option<String>,
    category: Option<String>,
    kind: Option<String>,
    sort: Option<Sort>,
    cursor: Option<String>,
    limit: Option<u32>,
    /// Fetch now even when the cache is fresh (still answers from the cache).
    refresh: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct GetParams {
    #[allow(dead_code)]
    source: String,
    /// A ref (`github.com/OWNER/REPO[/PATH]`) or the manifest id.
    #[serde(rename = "ref")]
    reference: String,
}

#[derive(Debug, Serialize)]
struct ListResult {
    source: &'static str,
    listings: Vec<CommunityRow>,
    next_cursor: Option<String>,
    /// When the cached index was fetched (ms since the epoch); null before
    /// the first fetch.
    fetched_at: Option<u64>,
    /// The cache is older than its TTL (or absent).
    stale: bool,
    /// A fetch is running; `apps-changed {transaction: "community"}` follows it.
    refreshing: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    /// Installed on another of the person's devices, not on this one.
    on_other_devices: Vec<ElsewhereRow>,
}

/// One installed community item as it syncs across devices.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SyncRecord {
    #[serde(rename = "ref")]
    pub reference: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    pub commit: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl SyncRecord {
    fn check(&self) -> Result<(), String> {
        if !is_ref(&self.reference) {
            return Err(format!("{}: not HOST/OWNER/REPO[/PATH]", self.reference));
        }
        if !is_commit(&self.commit) {
            return Err(format!("{}: commit must be 40 hex", self.reference));
        }
        if !SYNCED_KINDS.contains(&self.kind.as_str()) {
            return Err(format!("{}: unknown kind {}", self.reference, self.kind));
        }
        Ok(())
    }
}

/// A synced item this device lacks: the UI offers "Install on this Mac",
/// which is `apps.install {app: install_app}` and its consent card.
#[derive(Debug, Clone, Serialize)]
pub(super) struct ElsewhereRow {
    #[serde(flatten)]
    pub record: SyncRecord,
    pub install_app: String,
    /// Always `install_on_this_mac`.
    pub action: &'static str,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Synced {
    #[serde(default)]
    updated_at: u64,
    #[serde(default)]
    items: Vec<SyncRecord>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncedPutParams {
    items: Vec<SyncRecord>,
    #[allow(dead_code)]
    idempotency_key: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct InstallsParams {}

#[derive(Debug, Serialize)]
pub(super) struct InstallsResult {
    /// Installed here: what a sync pushes to the account.
    pub here: Vec<SyncRecord>,
    /// Synced from the account, not installed here.
    pub elsewhere: Vec<ElsewhereRow>,
    pub synced_at: Option<u64>,
}

/// Whether a `catalog.list` / `catalog.get` asks for the Community source.
pub(super) fn wants(args: &Value) -> bool {
    args["source"] == "community"
}

fn registry_base() -> String {
    std::env::var(REGISTRY_ENV)
        .ok()
        .filter(|base| base.starts_with("https://") || base.starts_with("http://127.0.0.1"))
        .unwrap_or_else(|| DEFAULT_REGISTRY.to_string())
}

/// The git apps installed here (`<state>/apps/git/sources.json`, written by
/// the git install path), read best effort: id -> record.
fn git_sources(state_dir: Option<&Path>) -> BTreeMap<String, Value> {
    let Some(dir) = state_dir else { return BTreeMap::new() };
    std::fs::read(dir.join("apps/git/sources.json"))
        .ok()
        .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
        .and_then(|index| index["apps"].as_object().cloned())
        .map(|apps| apps.into_iter().collect())
        .unwrap_or_default()
}

fn source_ref(source: &Value) -> Option<String> {
    let (host, owner, repo) =
        (string(source, "host")?, string(source, "owner")?, string(source, "repo")?);
    let path = string(source, "path").map(|p| format!("/{p}")).unwrap_or_default();
    Some(format!("{host}/{owner}/{repo}{path}")).filter(|r| is_ref(r))
}

impl Supervisor {
    /// The Community source, made on first use.
    pub(super) fn community(&self) -> Arc<Community> {
        self.community
            .get_or_init(|| {
                Community::new(
                    self.config.state_dir.as_deref(),
                    &registry_base(),
                    Arc::new(HttpRegistryFetch),
                )
            })
            .clone()
    }

    /// Runs a Community op (see the module doc).
    pub(super) fn community_call(&self, op: &str, args: Value) -> Result<Value, ApiError> {
        match op.strip_prefix("cmux.").unwrap_or(op) {
            "apps.catalog.list" => params(args).and_then(|p| to_value(self.community_list(p)?)),
            "apps.catalog.get" => params(args).and_then(|p| to_value(self.community_get(p)?)),
            "apps.community.installs" => {
                params::<InstallsParams>(args).and_then(|_| to_value(self.community_installs()))
            }
            "apps.community.synced.put" => params(args).and_then(|p| self.community_synced_put(p)),
            other => {
                Err(ApiError::new("apps.op.unknown", format!("{other} is not a Community op")))
            }
        }
    }

    /// The cache's status, starting a background refresh when one is due.
    fn community_status(&self, force: bool) -> Status {
        let community = self.community();
        let (status, start) = community.status(force, true);
        if start {
            let me = self.me.clone();
            let worker = community.clone();
            let spawned =
                std::thread::Builder::new().name("apps-community".into()).spawn(move || {
                    let _ = worker.refresh();
                    if let Some(supervisor) = me.upgrade() {
                        supervisor.community_changed();
                    }
                });
            if spawned.is_err() {
                community.state.lock().recover_poison().refreshing = false;
            }
        }
        status
    }

    /// Tells clients (and the App Store page) to read the catalog again; an
    /// `apps-changed` with no app, so nothing reconciles or activates.
    fn community_changed(&self) {
        let (sinks, revision) = {
            let inner = self.inner.lock().recover_poison();
            (inner.sinks.clone(), inner.mirror.revision)
        };
        let event =
            json!({ "event": "apps-changed", "revision": revision, "transaction": "community" });
        for sink in sinks.values() {
            sink(&event);
        }
    }

    pub(super) fn community_installed(&self) -> (Installed, Vec<SyncRecord>) {
        let sources = git_sources(self.config.state_dir.as_deref());
        let apps: BTreeSet<String> = {
            let inner = self.inner.lock().recover_poison();
            inner
                .mirror
                .apps
                .iter()
                .filter(|(_, r)| r.installed)
                .map(|(id, _)| id.clone())
                .collect()
        };
        let index = self.community().status(false, false).0.index;
        let kind_of = |reference: &str| -> (String, Option<String>) {
            index
                .as_ref()
                .and_then(|i| {
                    i.items.iter().find(|item| {
                        reference_lower(item).is_some_and(|r| r == reference.to_lowercase())
                    })
                })
                .map_or(("extension".into(), None), |item| {
                    (
                        string(item, "kind").unwrap_or_else(|| "extension".into()),
                        string(item, "name"),
                    )
                })
        };
        let mut here = Vec::new();
        let mut refs = BTreeSet::new();
        for (id, source) in &sources {
            if !apps.contains(id) {
                continue;
            }
            let (Some(reference), Some(commit)) =
                (source_ref(source), string(source, "commit").filter(|c| is_commit(c)))
            else {
                continue;
            };
            refs.insert(reference.to_lowercase());
            let (kind, name) = kind_of(&reference);
            here.push(SyncRecord {
                reference,
                kind,
                tag: string(source, "tag"),
                commit,
                app: Some(id.clone()),
                name,
            });
        }
        (Installed { apps, refs }, here)
    }

    fn community_elsewhere(&self, installed: &Installed) -> (Vec<ElsewhereRow>, Option<u64>) {
        let synced: Synced = self
            .community()
            .synced_file()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|raw| serde_json::from_slice(&raw).ok())
            .unwrap_or_default();
        let at = (synced.updated_at > 0).then_some(synced.updated_at);
        let rows = synced
            .items
            .into_iter()
            .filter(|r| r.check().is_ok())
            .filter(|r| {
                !installed.refs.contains(&r.reference.to_lowercase())
                    && !r.app.as_ref().is_some_and(|a| installed.apps.contains(a))
            })
            .map(|record| ElsewhereRow {
                install_app: format!("{}@{}", record.reference, record.commit),
                record,
                action: "install_on_this_mac",
            })
            .collect();
        (rows, at)
    }

    fn community_list(&self, p: ListParams) -> Result<ListResult, ApiError> {
        let offset = match p.cursor.as_deref() {
            None => 0,
            Some(cursor) => cursor.parse::<usize>().map_err(|_| bad_request("bad cursor"))?,
        };
        let limit = p.limit.map_or(DEFAULT_LIMIT, |l| l as usize).clamp(1, MAX_LIMIT);
        let status = self.community_status(p.refresh == Some(true));
        let (installed, _) = self.community_installed();
        let query = p.query.as_deref().map(str::to_lowercase).filter(|q| !q.trim().is_empty());
        let mut rows: Vec<CommunityRow> = status
            .index
            .as_ref()
            .map(|index| index.items.iter().filter_map(|item| row(item, &installed)).collect())
            .unwrap_or_default();
        rows.retain(|row| {
            p.kind.as_deref().is_none_or(|kind| row.kind == kind)
                && p.category.as_deref().is_none_or(|c| row.categories.iter().any(|x| x == c))
                && query.as_deref().is_none_or(|q| matches(row, q))
        });
        match p.sort.unwrap_or(Sort::Featured) {
            Sort::Featured => {}
            Sort::Downloads => rows.sort_by(|a, b| b.downloads.cmp(&a.downloads)),
            Sort::Stars => rows.sort_by(|a, b| b.stars.cmp(&a.stars)),
            Sort::Updated => rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at)),
            Sort::Name => rows.sort_by_key(|r| r.name.to_lowercase()),
        }
        let total = rows.len();
        let listings: Vec<CommunityRow> = rows.into_iter().skip(offset).take(limit).collect();
        let end = offset.saturating_add(limit);
        let (on_other_devices, _) = self.community_elsewhere(&installed);
        Ok(ListResult {
            source: "community",
            listings,
            next_cursor: (end < total).then(|| end.to_string()),
            fetched_at: status.index.as_ref().map(|i| i.fetched_at),
            stale: status.stale,
            refreshing: status.refreshing,
            error: status.error,
            on_other_devices,
        })
    }

    fn community_get(&self, p: GetParams) -> Result<CommunityDetail, ApiError> {
        let status = self.community_status(false);
        let (installed, _) = self.community_installed();
        let wanted = p.reference.to_lowercase();
        status
            .index
            .as_ref()
            .and_then(|index| {
                index.items.iter().find(|item| {
                    reference_lower(item).is_some_and(|r| r == wanted)
                        || string(item, "id").is_some_and(|id| id == p.reference)
                })
            })
            .and_then(|item| detail(item, &installed))
            .ok_or_else(|| ApiError::new("apps.community.unknown", "no such community item"))
    }

    pub(super) fn community_installs(&self) -> InstallsResult {
        let (installed, here) = self.community_installed();
        let (elsewhere, synced_at) = self.community_elsewhere(&installed);
        InstallsResult { here, elsewhere, synced_at }
    }

    fn community_synced_put(&self, p: SyncedPutParams) -> Result<Value, ApiError> {
        if p.items.len() > MAX_SYNCED {
            return Err(bad_request(format!("at most {MAX_SYNCED} synced items")));
        }
        for item in &p.items {
            item.check().map_err(bad_request)?;
        }
        let community = self.community();
        let (Some(dir), Some(file)) = (community.dir.clone(), community.synced_file()) else {
            return Err(ApiError::new("operation.failed", "no state directory"));
        };
        write_atomic(&dir, &file, &Synced { updated_at: now_ms(), items: p.items })
            .map_err(|e| ApiError::new("operation.failed", e.to_string()))?;
        to_value(self.community_installs())
    }
}

fn reference_lower(item: &Value) -> Option<String> {
    reference(item).map(|r| r.to_lowercase())
}

/// A case-insensitive substring of the name, tagline, description, author,
/// ref or a category.
fn matches(row: &CommunityRow, query: &str) -> bool {
    [&row.name, &row.description, &row.author, &row.reference]
        .into_iter()
        .chain(row.tagline.as_ref())
        .chain(row.categories.iter())
        .any(|field| field.to_lowercase().contains(query))
}

#[cfg(test)]
#[path = "community_tests.rs"]
pub(super) mod tests;
