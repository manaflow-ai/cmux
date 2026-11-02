//! The channels view's tracks (Settings > Updates): one per ring, slowest
//! first, each with its recent builds, their canary verdicts and pulls, the
//! build this Mac runs and the builds it kept for rollback.

use crate::civil;
use crate::pulled::PulledBuild;
use crate::version::compare_numeric;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const REPOSITORY: &str = "https://github.com/manaflow-ai/cmux";

/// The release rings, slowest first (`UpdateRing.allCases`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ring {
    Stable,
    Nightly,
    Canary,
    Dev,
}

impl Ring {
    pub const ALL: [Ring; 4] = [Ring::Stable, Ring::Nightly, Ring::Canary, Ring::Dev];
}

/// How a build fared after it was published.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Health {
    /// Its canary verdict passed: it was promoted.
    Promoted,
    /// Its canary verdict failed: it is held where it is.
    Held,
    /// It was taken off the feed (`pulled.json`).
    Pulled,
    /// No verdict yet, or the canary skipped it.
    Pending,
}

/// The canary verdict of `verdicts/<build>.json` as a health.
pub fn health(verdict: Option<&str>) -> Health {
    match verdict {
        Some("pass") => Health::Promoted,
        Some("fail") => Health::Held,
        _ => Health::Pending,
    }
}

/// One entry of the feed's `notes/index.json`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexEntry {
    pub build: String,
    pub short_version: String,
    /// `YYYY-MM-DD`.
    pub date: String,
    #[serde(default)]
    pub head: Option<String>,
}

/// One item of this app's own feed.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedEntry {
    pub version: String,
    pub display_version: String,
    /// Seconds since 1970.
    #[serde(default)]
    pub date: Option<f64>,
}

/// One build on a track.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelBuild {
    pub build: String,
    pub short_version: String,
    pub date: String,
    pub commit: Option<String>,
    pub health: Health,
    pub pulled_reason: Option<String>,
    /// This Mac runs it ("You are here").
    pub is_installed: bool,
    /// This Mac kept a copy, so installing it is an instant rollback.
    pub is_kept: bool,
    /// The GitHub commit page the build was cut from (as text; the app makes the URL).
    pub commit_url: Option<String>,
    /// GitHub's compare page from the track's installed build to this one.
    pub compare_url: Option<String>,
}

/// One ring's recent builds, newest first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelTrack {
    pub ring: Ring,
    pub builds: Vec<ChannelBuild>,
    /// The ring `updates.channel` picks.
    pub is_followed: bool,
    /// The GitHub release that holds this channel's downloads.
    pub release_url: Option<String>,
}

/// Swift's `Character.isHexDigit`: ASCII hex digits and their fullwidth forms.
fn is_hex_digit(c: char) -> bool {
    c.is_ascii_hexdigit()
        || matches!(c, '\u{FF10}'..='\u{FF19}' | '\u{FF21}'..='\u{FF26}' | '\u{FF41}'..='\u{FF46}')
}

/// A hex commit id (7 to 40 digits), so a feed value never becomes another URL path.
pub fn is_commit(value: &str) -> bool {
    (7..=40).contains(&value.chars().count()) && value.chars().all(is_hex_digit)
}

pub fn commit_url(commit: Option<&str>) -> Option<String> {
    commit.filter(|commit| is_commit(commit)).map(|commit| format!("{REPOSITORY}/commit/{commit}"))
}

/// What changes on installing `to` over `from`; none for the same commit or
/// when either is unknown.
pub fn compare_url(from: Option<&str>, to: Option<&str>) -> Option<String> {
    let (from, to) = (from?, to?);
    (from != to && is_commit(from) && is_commit(to))
        .then(|| format!("{REPOSITORY}/compare/{from}...{to}"))
}

/// The inputs of [`tracks`].
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracksRequest {
    /// `notes/index.json`, newest first.
    pub index: Vec<IndexEntry>,
    /// Each build's canary verdict (pass, fail, skipped).
    #[serde(default)]
    pub verdicts: BTreeMap<String, String>,
    /// The feed's `pulled.json`.
    #[serde(default)]
    pub pulled: Vec<PulledBuild>,
    /// The running build.
    pub installed_build: String,
    /// The builds this Mac kept for rollback.
    #[serde(default)]
    pub kept_builds: BTreeSet<String>,
    /// The ring `updates.channel` picks.
    pub followed: Ring,
    /// How many recent builds a track shows.
    pub limit: i64,
    /// This app's own feed: the Dev track also lists its builds the index
    /// lacks (the published DEV app's tip feed has no notes index).
    #[serde(default)]
    pub feed_items: Vec<FeedEntry>,
}

/// The tracks shown today, one per ring, slowest first. The Nightly track is
/// the feed's build index; Dev takes every build CI publishes (the index plus
/// the feed's own builds, newest first); Stable and Canary have no builds
/// until CI publishes them.
pub fn tracks(request: &TracksRequest) -> Vec<ChannelTrack> {
    let limit = usize::try_from(request.limit.max(0)).unwrap_or(usize::MAX);
    // The first entry for a build wins.
    let mut pulled: BTreeMap<&str, &PulledBuild> = BTreeMap::new();
    for entry in &request.pulled {
        pulled.entry(entry.build.as_str()).or_insert(entry);
    }
    let nightly: Vec<ChannelBuild> = request
        .index
        .iter()
        .take(limit)
        .map(|entry| {
            let pull = pulled.get(entry.build.as_str());
            ChannelBuild {
                build: entry.build.clone(),
                short_version: entry.short_version.clone(),
                date: entry.date.clone(),
                commit: entry.head.clone(),
                health: if pull.is_some() {
                    Health::Pulled
                } else {
                    health(request.verdicts.get(&entry.build).map(String::as_str))
                },
                pulled_reason: pull.map(|pull| pull.reason.clone()),
                is_installed: entry.build == request.installed_build,
                is_kept: request.kept_builds.contains(&entry.build),
                commit_url: None,
                compare_url: None,
            }
        })
        .collect();
    let indexed: BTreeSet<&str> = request.index.iter().map(|entry| entry.build.as_str()).collect();
    let from_feed = request
        .feed_items
        .iter()
        .filter(|item| {
            !indexed.contains(item.version.as_str()) && !pulled.contains_key(item.version.as_str())
        })
        .map(|item| ChannelBuild {
            build: item.version.clone(),
            short_version: item.display_version.clone(),
            date: item.date.map(civil::utc_day).unwrap_or_default(),
            commit: None,
            health: Health::Pending,
            pulled_reason: None,
            is_installed: item.version == request.installed_build,
            is_kept: request.kept_builds.contains(&item.version),
            commit_url: None,
            compare_url: None,
        });
    let mut dev: Vec<ChannelBuild> = nightly.iter().cloned().chain(from_feed).collect();
    // Stable, so builds of equal order keep their place.
    dev.sort_by(|a, b| compare_numeric(&b.build, &a.build));
    dev.truncate(limit);
    Ring::ALL
        .iter()
        .map(|ring| {
            let builds = match ring {
                Ring::Nightly => nightly.clone(),
                Ring::Dev => dev.clone(),
                Ring::Stable | Ring::Canary => Vec::new(),
            };
            ChannelTrack {
                ring: *ring,
                builds: with_links(builds),
                is_followed: *ring == request.followed,
                release_url: (*ring == Ring::Nightly)
                    .then(|| format!("{REPOSITORY}/releases/tag/nightly-next")),
            }
        })
        .collect()
}

/// Fills each build's commit link and its compare link from the track's installed build.
fn with_links(mut builds: Vec<ChannelBuild>) -> Vec<ChannelBuild> {
    let installed =
        builds.iter().find(|build| build.is_installed).and_then(|build| build.commit.clone());
    for build in &mut builds {
        build.commit_url = commit_url(build.commit.as_deref());
        build.compare_url = compare_url(installed.as_deref(), build.commit.as_deref());
    }
    builds
}
