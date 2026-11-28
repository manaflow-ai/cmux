//! `cmux app web-cas fetch`: a web update by `cas/1` (RFD 0166, cmuxterm-hq
//! docs/rfd/0166-own-cdn.md), the HTTPS floor: the signed web update pointer's `cas` field names a
//! manifest and a pack under `cmux-next-web/cas/`, and this moves only the chunks the trees
//! already on this Mac lack, by coalesced Range GETs on the pack, instead of the whole archive.
//!
//! Every decision is `cmux_cas::fetch`'s: this file is its [`Source`] over HTTPS. One client,
//! no redirects (the objects are served where they are published), a size cap on every whole
//! read, and a Range read is taken only as a 206 of exactly the bytes asked for. Nothing read is
//! trusted before the crate checks its id. The app's web updater runs it behind the
//! default-off `updates.webCas` (CmuxNextWebUpdates `WebUpdates+Cas.swift`), as its child: it
//! ends when that app does (`Http::gone`).

use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

use cmux_cas::fetch::Source;
use cmux_cas::{Id, Store};
use serde_json::json;

use super::{AppCommand, GlobalArgs, Options, UsageError};

/// Where `cas/1` objects of the web updates are published.
pub(super) const DEFAULT_BASE: &str = "https://files.cmux.com/cmux-next-web/cas/";
/// One request, connect to last byte. A cold fetch reads one pack of about 17 MB.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

pub(in crate::cli) const USAGE: &str = "usage: cmux app web-cas fetch --manifest <id> --pack <id> --store <dir> --out <dir> [--have <dir>]... [--base <url>]\nfetch assembles the web update whose cas/1 manifest and pack the signed pointer names into --out (which must\nnot exist), reading chunks from the chunk store --store, then from the trees --have (web updates already on\ndisk), then by Range GETs on the pack under --base (default https://files.cmux.com/cmux-next-web/cas/).\nIt prints one JSON line: {\"ok\":true, tree_bytes, chunks, reused, ranges, range_bytes, meta_bytes}.";

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Command {
    Fetch(Fetch),
}

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Fetch {
    pub base: String,
    pub manifest: Id,
    pub pack: Id,
    pub store: PathBuf,
    pub have: Vec<PathBuf>,
    pub out: PathBuf,
}

/// `rest` starts with `web-cas`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(USAGE);
    let Some("fetch") = rest.get(1).map(String::as_str) else {
        return Err(usage());
    };
    let options = Options::parse(
        rest.get(2..).unwrap_or_default(),
        &["base", "manifest", "pack", "store", "have", "out"],
        &[],
    )
    .map_err(|_| usage())?;
    let id = |name: &str| {
        let text = options.value(name).ok_or_else(usage)?;
        Id::parse(text).map_err(|_| {
            UsageError::new(format!("cmux app web-cas: --{name} {text:?} is not a cas/1 id"))
        })
    };
    let dir = |name: &str| options.value(name).filter(|d| !d.is_empty()).map(PathBuf::from);
    Ok(AppCommand::WebCas(Command::Fetch(Fetch {
        base: super::web_pieces::base_url(options.value("base").unwrap_or(DEFAULT_BASE))
            .map_err(UsageError::new)?,
        manifest: id("manifest")?,
        pack: id("pack")?,
        store: dir("store").ok_or_else(usage)?,
        have: options.values("have").into_iter().map(PathBuf::from).collect(),
        out: dir("out").ok_or_else(usage)?,
    })))
}

/// How often a fetch checks that the app that started it is still its parent.
const PARENT_CHECK: Duration = Duration::from_millis(200);
/// The exit status of a fetch whose app went away.
const PARENT_GONE: i32 = 4;

pub(super) fn run(_global: &GlobalArgs, command: &Command) -> i32 {
    let Command::Fetch(fetch) = command;
    let made = made_by_fetch(&fetch.out, &fetch.store);
    // SAFETY: getppid has no preconditions and cannot fail.
    let parent = unsafe { libc::getppid() };
    // SAFETY: as above.
    let gone = move || unsafe { libc::getppid() } != parent;
    let done = Http::new(&fetch.base).and_then(|source| {
        let mut source = source.ending_when(gone, PARENT_CHECK);
        let store = Store::new(&fetch.store);
        cmux_cas::fetch::fetch(
            &mut source,
            &store,
            &fetch.manifest,
            &fetch.pack,
            &fetch.have,
            &fetch.out,
        )
    });
    if gone() {
        remove_made(&made);
        eprintln!("cmux app web-cas: the app that started this fetch went away");
        return PARENT_GONE;
    }
    match done {
        Ok(report) => {
            let mut line = serde_json::to_value(&report).unwrap_or_else(|_| json!({}));
            if let Some(fields) = line.as_object_mut() {
                fields.insert("ok".to_owned(), json!(true));
            } else {
                line = json!({ "ok": true });
            }
            let _ = writeln!(std::io::stdout().lock(), "{line}");
            0
        }
        Err(error) => {
            eprintln!("cmux app web-cas: {error}");
            3
        }
    }
}

/// The folders of `out` and `store` that do not exist yet, which this fetch will make.
fn made_by_fetch(out: &std::path::Path, store: &std::path::Path) -> Vec<PathBuf> {
    [out, store].into_iter().filter(|d| !d.exists()).map(std::path::Path::to_path_buf).collect()
}

/// Removes the folders this fetch created (`--out` must not exist before it; `--store` the app
/// names fresh), never one that was there before it started.
fn remove_made(made: &[PathBuf]) {
    for dir in made {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Resolves once `gone` says so, checking every `every`.
async fn until(gone: &(dyn Fn() -> bool + Send + Sync), every: Duration) {
    while !gone() {
        tokio::time::sleep(every).await;
    }
}

/// `cas/1` objects under one https base.
pub(super) struct Http {
    base: String,
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
    /// Ties the fetch to the app that started it (RFD 0166 step 2, review F2 of cmux#60451): the
    /// app removes `staging-*` at launch, so a fetch that outlived a force-quit would write its
    /// staging tree and chunk store again under the next launch. Every read races this check and
    /// fails once it says the parent changed (the process was reparented); [`run`] then removes
    /// what the fetch made. A cost of one `getppid` per [`PARENT_CHECK`], whatever the size.
    gone: Box<dyn Fn() -> bool + Send + Sync>,
    every: Duration,
}

impl Http {
    pub(super) fn new(base: &str) -> cmux_cas::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        let client = cmux_egress::client_builder("cmux_tui::cli::app::web_cas")
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux-web-cas/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Http {
            base: base.to_owned(),
            runtime,
            client,
            gone: Box::new(|| false),
            every: PARENT_CHECK,
        })
    }

    /// Reads fail once `gone` says so, checked every `every`.
    pub(super) fn ending_when(
        self,
        gone: impl Fn() -> bool + Send + Sync + 'static,
        every: Duration,
    ) -> Self {
        Http { gone: Box::new(gone), every, ..self }
    }

    /// The body of `path` with `range` (`None`: the whole object), read only while it stays
    /// within `max` bytes and only from the status `want`.
    fn read(
        &self,
        path: &str,
        range: Option<(u64, u64)>,
        want: reqwest::StatusCode,
        max: usize,
    ) -> cmux_cas::Result<Vec<u8>> {
        let url = format!("{}{path}", self.base);
        let read = async {
            let mut request = self.client.get(&url);
            if let Some((start, end)) = range {
                request =
                    request.header(reqwest::header::RANGE, format!("bytes={start}-{}", end - 1));
            }
            let mut response = request.send().await.map_err(|e| format!("{url}: {e}"))?;
            if response.status() != want {
                return Err(format!("{url}: HTTP {}", response.status().as_u16()).into());
            }
            if let Some((start, end)) = range {
                let said = response
                    .headers()
                    .get(reqwest::header::CONTENT_RANGE)
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or_default();
                let asked = format!("bytes {start}-{}/", end - 1);
                if !said.starts_with(&asked) {
                    return Err(format!("{url}: answered {said:?} for {asked}*").into());
                }
            }
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|e| format!("{url}: {e}"))? {
                if body.len() + chunk.len() > max {
                    return Err(format!("{url}: larger than {max} bytes").into());
                }
                body.extend_from_slice(&chunk);
            }
            Ok(body)
        };
        self.runtime.block_on(async {
            tokio::select! {
                read = read => read,
                () = until(&*self.gone, self.every) => {
                    Err(format!("{url}: the app that started this fetch went away").into())
                }
            }
        })
    }
}

impl Source for Http {
    fn get(&mut self, path: &str, max: usize) -> cmux_cas::Result<Vec<u8>> {
        self.read(path, None, reqwest::StatusCode::OK, max)
    }

    fn range(&mut self, path: &str, start: u64, end: u64) -> cmux_cas::Result<Vec<u8>> {
        if end <= start {
            return Err(format!("{path}: an empty range {start}..{end}").into());
        }
        let len = usize::try_from(end - start)?;
        let body =
            self.read(path, Some((start, end)), reqwest::StatusCode::PARTIAL_CONTENT, len)?;
        if body.len() != len {
            return Err(format!("{path}: {} bytes for a range of {len}", body.len()).into());
        }
        Ok(body)
    }
}

#[cfg(test)]
#[path = "web_cas_tests.rs"]
mod tests;
