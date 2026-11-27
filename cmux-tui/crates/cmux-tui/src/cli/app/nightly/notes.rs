//! `cmux nightly whats-in [BUILD]` and `cmux nightly which <PR>`: which pull requests went into
//! which NIGHTLY, read from the signed release-notes feed the app's What's New reads.
//!
//! Leo (2026-11-26): "hm do we display which prs go into which nightly maybe that'd be useful per
//! thing?"
//!
//! The nightly publishes `notes/index.json` (its builds, newest first) and `notes/<build>.json`
//! (the commits since the previous build that had notes, one item per commit with its PR), each
//! with a `.sig` beside it: base64 Ed25519 over the exact bytes, by the `content-signing` key
//! (`ContentSignature` in the app, `feature_flags::verify` here). A file whose signature does not
//! verify is refused, never shown. A build with no notes (404) is skipped. `CMUX_NIGHTLY_NOTES_URL`
//! points the commands at another feed (an http(s) base or a directory, for tests); the key stays.
//!
//! The parsing, selection, grouping and formatting below are pure; only [`Feed`] reads.

use std::path::PathBuf;

use futures_util::StreamExt as _;
use serde_json::{Value, json};

use crate::localization::NightlyMessages;

/// Where the nightly publishes its notes.
pub(super) const FEED_BASE: &str = "https://files-next.cmux.com/nightly-next/notes";
/// Another feed base: an http(s) URL or a directory holding `index.json` and `<build>.json`.
pub(super) const FEED_ENV: &str = "CMUX_NIGHTLY_NOTES_URL";
/// The repository the PR numbers belong to.
const PULL_URL: &str = "https://github.com/manaflow-ai/cmux/pull/";
/// Notes files read at once while `which` scans the builds.
const SCAN_CONCURRENCY: usize = 8;
const HTTP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// One build of the index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Build {
    pub build: String,
    pub short_version: String,
    pub date: String,
    pub head: String,
}

/// One change of a build's notes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Item {
    pub pr: Option<u64>,
    pub title: String,
    pub author: String,
    pub area: Option<String>,
    pub internal: bool,
}

/// A build's notes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Notes {
    pub built_at: Option<String>,
    pub items: Vec<Item>,
}

impl Notes {
    pub(super) fn contains(&self, pr: u64) -> bool {
        self.items.iter().any(|item| item.pr == Some(pr))
    }
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// `index.json`'s builds, in its order (newest first).
pub(super) fn parse_index(bytes: &[u8]) -> Result<Vec<Build>, String> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|error| format!("index.json: {error}"))?;
    let builds = value
        .get("builds")
        .and_then(Value::as_array)
        .ok_or_else(|| "index.json lists no builds".to_owned())?;
    Ok(builds
        .iter()
        .filter(|build| !text(build, "build").is_empty())
        .map(|build| Build {
            build: text(build, "build"),
            short_version: text(build, "shortVersion"),
            date: text(build, "date"),
            head: text(build, "head"),
        })
        .collect())
}

/// `<build>.json`'s items. `area` is optional; an empty one counts as none.
pub(super) fn parse_notes(bytes: &[u8]) -> Result<Notes, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|error| format!("notes: {error}"))?;
    let items = value
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| Item {
                    pr: item.get("pr").and_then(Value::as_u64),
                    title: text(item, "title"),
                    author: text(item, "author"),
                    area: Some(text(item, "area")).filter(|area| !area.is_empty()),
                    internal: item.get("internal").and_then(Value::as_bool) == Some(true),
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Notes { built_at: value.get("builtAt").and_then(Value::as_str).map(str::to_owned), items })
}

/// The PR a word names: `57008`, `#57008` or a pull URL (`…/pull/57008/files`).
pub(super) fn pr_number(word: &str) -> Option<u64> {
    let digits = match word.split_once("/pull/") {
        Some((_, rest)) => rest,
        None => word.strip_prefix('#').unwrap_or(word),
    };
    let end = digits.find(|c: char| !c.is_ascii_digit()).unwrap_or(digits.len());
    if word.contains("/pull/") || end == digits.len() {
        digits.get(..end)?.parse::<u64>().ok().filter(|number| *number > 0)
    } else {
        None
    }
}

/// The newest build, or the one named.
pub(super) fn select<'a>(builds: &'a [Build], wanted: Option<&str>) -> Option<&'a Build> {
    match wanted {
        None => builds.iter().max_by(|left, right| super::order(&left.build, &right.build)),
        Some(number) => builds.iter().find(|build| build.build == number),
    }
}

/// The build just below `build` in the index: the one its notes count from.
pub(super) fn previous<'a>(builds: &'a [Build], build: &str) -> Option<&'a Build> {
    builds
        .iter()
        .filter(|candidate| super::older(&candidate.build, build))
        .max_by(|left, right| super::order(&left.build, &right.build))
}

/// Items by area, areas by name, the ones with no area last under `other`.
pub(super) fn area_groups<'a>(items: &'a [Item], other: &str) -> Vec<(String, Vec<&'a Item>)> {
    let mut named: std::collections::BTreeMap<&str, Vec<&Item>> = Default::default();
    let mut rest = Vec::new();
    for item in items {
        match item.area.as_deref() {
            Some(area) => named.entry(area).or_default().push(item),
            None => rest.push(item),
        }
    }
    let mut groups: Vec<(String, Vec<&Item>)> =
        named.into_iter().map(|(area, items)| (area.to_owned(), items)).collect();
    if !rest.is_empty() {
        groups.push((other.to_owned(), rest));
    }
    groups
}

fn short(head: &str) -> String {
    head.chars().take(8).collect()
}

fn pull_url(pr: u64) -> String {
    format!("{PULL_URL}{pr}")
}

/// One heading per area, then one line per change, its PR's URL under it.
pub(super) fn whats_in_human(
    build: &Build,
    notes: &Notes,
    since: Option<&Build>,
    messages: &NightlyMessages,
) -> String {
    let header = match since {
        Some(since) => messages.whats_in_header.replace("{since}", &since.build),
        None => messages.whats_in_header_first.to_owned(),
    };
    let mut out = header
        .replace("{build}", &build.build)
        .replace("{version}", &build.short_version)
        .replace("{date}", &build.date)
        .replace("{head}", &short(&build.head))
        .replace("{count}", &notes.items.len().to_string());
    out.push('\n');
    for (area, items) in area_groups(&notes.items, messages.whats_in_other) {
        out.push_str(&format!("\n{area}\n"));
        for item in items {
            let internal = if item.internal {
                format!(" [{}]", messages.whats_in_internal)
            } else {
                String::new()
            };
            match item.pr {
                Some(pr) => out.push_str(&format!(
                    "  #{pr} {} ({}){internal}\n      {}\n",
                    item.title,
                    item.author,
                    pull_url(pr)
                )),
                None => out.push_str(&format!("  {} ({}){internal}\n", item.title, item.author)),
            }
        }
    }
    out
}

pub(super) fn whats_in_json(build: &Build, notes: &Notes, since: Option<&Build>) -> Value {
    let items: Vec<Value> = notes
        .items
        .iter()
        .map(|item| {
            json!({ "pr": item.pr, "title": item.title, "author": item.author, "area": item.area,
                    "url": item.pr.map(pull_url), "internal": item.internal })
        })
        .collect();
    json!({ "build": build.build, "short_version": build.short_version, "date": build.date,
            "head": build.head, "built_at": notes.built_at, "since": since.map(|since| &since.build),
            "items": items })
}

pub(super) fn which_human(
    pr: u64,
    hit: Option<(&Build, &Notes)>,
    builds: &[Build],
    messages: &NightlyMessages,
) -> String {
    match hit {
        Some((build, notes)) => {
            let line = match &notes.built_at {
                Some(time) => messages.which_found_at.replace("{time}", time),
                None => messages.which_found.to_owned(),
            };
            line.replace("{pr}", &pr.to_string())
                .replace("{build}", &build.build)
                .replace("{date}", &build.date)
        }
        None => {
            let oldest =
                builds.iter().min_by(|left, right| super::order(&left.build, &right.build));
            messages
                .which_missing
                .replace("{pr}", &pr.to_string())
                .replace("{count}", &builds.len().to_string())
                .replace("{oldest}", oldest.map(|build| build.build.as_str()).unwrap_or("-"))
                .replace("{date}", oldest.map(|build| build.date.as_str()).unwrap_or("-"))
        }
    }
}

pub(super) fn which_json(pr: u64, hit: Option<(&Build, &Notes)>) -> Value {
    match hit {
        Some((build, notes)) => json!({ "pr": pr, "build": build.build,
            "short_version": build.short_version, "date": build.date, "head": build.head,
            "built_at": notes.built_at }),
        None => json!({ "pr": pr, "build": Value::Null }),
    }
}

/// Where the notes are read from.
enum Source {
    Http { client: reqwest::Client, base: String },
    Dir(PathBuf),
}

/// The notes feed, read and checked against `public_key`.
pub(super) struct Feed {
    source: Source,
    public_key: String,
}

impl Feed {
    #[cfg(test)]
    pub(super) fn dir(path: PathBuf, public_key: String) -> Self {
        Self { source: Source::Dir(path), public_key }
    }

    /// The feed `CMUX_NIGHTLY_NOTES_URL` names, else the nightly's; one HTTP client for the run.
    pub(super) fn from_env() -> Result<Self, String> {
        let base = std::env::var(FEED_ENV)
            .ok()
            .filter(|base| !base.trim().is_empty())
            .unwrap_or_else(|| FEED_BASE.to_owned());
        let public_key = crate::feature_flags::public_key();
        if !(base.starts_with("https://") || base.starts_with("http://")) {
            let path = base.strip_prefix("file://").unwrap_or(&base);
            return Ok(Self { source: Source::Dir(PathBuf::from(path)), public_key });
        }
        cmux_egress::allow_named(&base);
        let client = cmux_egress::client_builder("cmux_tui::cli::app::nightly::notes")
            .timeout(HTTP_TIMEOUT)
            .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| format!("http client: {error}"))?;
        Ok(Self {
            source: Source::Http { client, base: base.trim_end_matches('/').to_owned() },
            public_key,
        })
    }

    /// The file's bytes; None when the feed has no such file.
    async fn get(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        match &self.source {
            Source::Dir(dir) => match std::fs::read(dir.join(name)) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(format!("{name}: {error}")),
            },
            Source::Http { client, base } => {
                let url = format!("{base}/{name}");
                let response =
                    client.get(&url).send().await.map_err(|error| format!("{url}: {error}"))?;
                // R2 answers a missing key with 404 (or 403 without list rights).
                if matches!(response.status().as_u16(), 403 | 404) {
                    return Ok(None);
                }
                if !response.status().is_success() {
                    return Err(format!("{url}: HTTP {}", response.status()));
                }
                let bytes = response.bytes().await.map_err(|error| format!("{url}: {error}"))?;
                Ok(Some(bytes.to_vec()))
            }
        }
    }

    /// The file's bytes once its `.sig` verifies; None when the feed has no such file.
    async fn get_signed(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        let Some(bytes) = self.get(name).await? else { return Ok(None) };
        let signature = self
            .get(&format!("{name}.sig"))
            .await?
            .ok_or_else(|| format!("{name} has no signature"))?;
        if !crate::feature_flags::verify(&bytes, &signature, &self.public_key) {
            return Err(format!("{name}: the signature does not verify"));
        }
        Ok(Some(bytes))
    }

    pub(super) async fn index(&self) -> Result<Vec<Build>, String> {
        let bytes = self.get_signed("index.json").await?.ok_or("index.json is missing")?;
        parse_index(&bytes)
    }

    /// A build's notes; None when it published none.
    pub(super) async fn notes(&self, build: &str) -> Result<Option<Notes>, String> {
        if build.is_empty() || !build.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(format!("{build:?} is not a build number"));
        }
        match self.get_signed(&format!("{build}.json")).await? {
            Some(bytes) => parse_notes(&bytes).map(Some),
            None => Ok(None),
        }
    }
}

/// The oldest build whose notes carry `pr`, reading a few notes files at once, oldest first, and
/// stopping at the first hit.
pub(super) async fn find(
    feed: &Feed,
    builds: &[Build],
    pr: u64,
) -> Result<Option<(Build, Notes)>, String> {
    let mut oldest_first: Vec<&Build> = builds.iter().collect();
    oldest_first.sort_by(|left, right| super::order(&left.build, &right.build));
    let mut reads = futures_util::stream::iter(oldest_first)
        .map(|build| async move { (build, feed.notes(&build.build).await) })
        .buffered(SCAN_CONCURRENCY);
    while let Some((build, notes)) = reads.next().await {
        if let Some(notes) = notes? {
            if notes.contains(pr) {
                return Ok(Some((build.clone(), notes)));
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
#[path = "notes_tests.rs"]
mod tests;
