//! Fetching and keeping harness changelogs (`changelog.rs`). Fetched only on
//! request (`_acpmux/harness/changelog`, which the agent pane asks while an
//! update is on offer): never on a timer. A copy younger than [`FRESH`] is
//! reused; an older one is asked again with a conditional GET (`ETag`,
//! `Last-Modified`), so an unchanged changelog costs a 304. The request
//! carries no identifier (no cookie, no token, a generic user agent). The
//! parsed copy is saved next to `harness-health.json`
//! (`<acpmux home>/harness-changelog.json`) and answers when the network does
//! not, or when fetching is off (`ACPMUX_HEALTH_FETCH=0`,
//! `ACPMUX_CATALOG_FETCH=0`: no sources attached).

use super::changelog::{self, Entry, Sources};
use super::now_ms;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

/// A copy this young is used without asking again.
const FRESH_MS: u64 = 10 * 60 * 1000;
/// A copy that lacks the newest version (published to npm before its changelog) is asked again
/// after this long, not on every hover.
const RETRY_MS: u64 = 60 * 1000;
const MAX_BODY_BYTES: usize = 4 << 20;

/// Where changelogs come from and where the copy is saved.
#[derive(Clone, Debug, Default)]
pub struct Settings {
    /// None: no fetching (the saved copy only).
    pub sources: Option<Sources>,
    /// `<acpmux home>/harness-changelog.json`; None: kept in memory only.
    pub cache: Option<PathBuf>,
}

/// One family's kept changelog.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
struct Kept {
    #[serde(default)]
    etag: Option<String>,
    #[serde(default)]
    last_modified: Option<String>,
    /// When it was last fetched or confirmed unchanged (ms since the epoch).
    fetched_at: u64,
    entries: Vec<Entry>,
}

#[derive(Default)]
pub struct Changelogs {
    settings: Mutex<Settings>,
    kept: Mutex<BTreeMap<String, Kept>>,
    /// One fetch at a time.
    fetching: tokio::sync::Mutex<()>,
}

impl Changelogs {
    /// Sets the sources and the saved copy's path, and reads that copy.
    pub fn attach(&self, settings: Settings) {
        let saved = settings
            .cache
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<BTreeMap<String, Kept>>(&b).ok());
        if let Some(saved) = saved {
            *self.kept.lock().unwrap_or_else(PoisonError::into_inner) = saved;
        }
        *self.settings.lock().unwrap_or_else(PoisonError::into_inner) = settings;
    }

    /// `family`'s changelog page and entries (newest first), or None when it publishes none.
    /// `network`: this caller may fetch (a Web page reads the saved copy only). `newest`: the
    /// version the caller wants included; a copy without it is asked again sooner.
    pub async fn entries(
        &self,
        family: &str,
        newest: Option<&str>,
        network: bool,
    ) -> Option<(&'static str, Vec<Entry>)> {
        let published = changelog::published(family)?;
        let sources = self.settings.lock().unwrap_or_else(PoisonError::into_inner).sources.clone();
        if let (true, Some(sources)) = (network, sources) {
            let _one = self.fetching.lock().await;
            if self.stale(family, newest) {
                self.refresh(family, published.format, &sources).await;
            }
        }
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        Some((published.page, kept.get(family).map(|k| k.entries.clone()).unwrap_or_default()))
    }

    fn stale(&self, family: &str, newest: Option<&str>) -> bool {
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(k) = kept.get(family) else { return true };
        let age = now_ms().saturating_sub(k.fetched_at);
        let has_newest = newest.is_none_or(|v| {
            k.entries.iter().any(|e| {
                super::probe::compare_versions(&e.version, v)
                    .is_some_and(|o| o != std::cmp::Ordering::Less)
            })
        });
        age >= if has_newest { FRESH_MS } else { RETRY_MS }
    }

    async fn refresh(&self, family: &str, format: changelog::Format, sources: &Sources) {
        let Some(url) = changelog::fetch_url(family, sources) else { return };
        let (etag, last_modified) = {
            let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
            let k = kept.get(family);
            (k.and_then(|k| k.etag.clone()), k.and_then(|k| k.last_modified.clone()))
        };
        let accept = match format {
            changelog::Format::Markdown => "text/plain",
            changelog::Format::Releases { .. } => "application/vnd.github+json",
        };
        let answer = fetch(url, accept, etag.as_deref(), last_modified.as_deref()).await;
        let mut kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        match answer {
            Ok(Fetched::Unchanged) => {
                if let Some(k) = kept.get_mut(family) {
                    k.fetched_at = now_ms();
                }
            }
            Ok(Fetched::Body { text, etag, last_modified }) => {
                let entries = changelog::parse(format, &text);
                if entries.is_empty() {
                    tracing::info!(%family, "harness changelog has no versions; the copy stays");
                    return;
                }
                kept.insert(
                    family.to_owned(),
                    Kept { etag, last_modified, fetched_at: now_ms(), entries },
                );
            }
            Err(e) => {
                tracing::info!(%family, error = %e, "harness changelog not read");
                return;
            }
        }
        let cache = self.settings.lock().unwrap_or_else(PoisonError::into_inner).cache.clone();
        if let Some(path) = cache {
            save(&path, &kept);
        }
    }
}

fn save(path: &Path, kept: &BTreeMap<String, Kept>) {
    let Ok(body) = serde_json::to_vec(kept) else { return };
    let tmp = path.with_extension("json.tmp");
    if let Err(e) = std::fs::write(&tmp, body).and_then(|()| std::fs::rename(&tmp, path)) {
        tracing::info!(error = %e, "harness changelog not saved");
    }
}

enum Fetched {
    Unchanged,
    Body { text: String, etag: Option<String>, last_modified: Option<String> },
}

/// GETs `url`, conditionally when a validator is known. HTTPS only, no redirects, a short
/// timeout and a body cap, as `latest::fetch_json`. A debug build also takes a loopback
/// `http://127.0.0.1` URL (tests).
async fn fetch(
    url: &str,
    accept: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
) -> Result<Fetched, String> {
    let loopback = cfg!(debug_assertions) && url.starts_with("http://127.0.0.1:");
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .https_only(!loopback)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let mut request = client.get(url).header("Accept", accept);
    if let Some(tag) = etag {
        request = request.header("If-None-Match", tag);
    }
    if let Some(at) = last_modified {
        request = request.header("If-Modified-Since", at);
    }
    let mut response = request.send().await.map_err(|e| e.to_string())?;
    if response.status() == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(Fetched::Unchanged);
    }
    if !response.status().is_success() {
        return Err(format!("{url} answered {}", response.status()));
    }
    let header =
        |name: &str| response.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
    let (etag, last_modified) = (header("etag"), header("last-modified"));
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        crate::catalog::fetch::push_capped(&mut body, &chunk, MAX_BODY_BYTES)?;
    }
    let text = String::from_utf8(body).map_err(|e| e.to_string())?;
    Ok(Fetched::Body { text, etag, last_modified })
}
