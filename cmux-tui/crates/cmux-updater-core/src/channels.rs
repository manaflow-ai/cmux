//! Settings > Updates' channels view: each ring's recent builds (CmuxNextUpdater's
//! `ChannelTrack.tracks`). The app passes the feed documents it fetched; this lists the builds.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde::{Deserialize, Serialize};

use crate::feed::Ring;
use crate::numeric;

/// The GitHub repository builds link to.
pub const REPOSITORY: &str = "https://github.com/manaflow-ai/cmux";

/// One `notes/index.json` entry.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexEntry {
    pub build: String,
    pub short_version: String,
    pub date: String,
    #[serde(default)]
    pub head: Option<String>,
}

/// One `pulled.json` entry.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Pulled {
    pub build: String,
    pub reason: String,
}

/// An appcast item, as much of it as the tracks read.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedItem {
    pub version: String,
    pub display_version: String,
    /// Seconds since 1970.
    #[serde(default)]
    pub date: Option<f64>,
    #[serde(default)]
    pub sparkle_channel: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Health {
    Promoted,
    Held,
    Pulled,
    Pending,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Build {
    pub build: String,
    pub short_version: String,
    pub date: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    pub health: Health,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pulled_reason: Option<String>,
    pub is_installed: bool,
    pub is_kept: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub ring: Ring,
    pub builds: Vec<Build>,
    pub is_followed: bool,
    #[serde(rename = "releaseURL", skip_serializing_if = "Option::is_none")]
    pub release_url: Option<String>,
}

/// The inputs of [`tracks`].
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub index: Vec<IndexEntry>,
    #[serde(default)]
    pub verdicts: BTreeMap<String, String>,
    #[serde(default)]
    pub pulled: Vec<Pulled>,
    pub installed_build: String,
    #[serde(default)]
    pub kept_builds: BTreeSet<String>,
    pub followed: Ring,
    #[serde(default = "default_limit")]
    pub limit: i64,
    #[serde(default)]
    pub feed_items: Vec<FeedItem>,
    #[serde(default)]
    pub tip_feed: bool,
}

fn default_limit() -> i64 {
    10
}

/// A canary verdict's badge.
pub fn health(verdict: Option<&str>) -> Health {
    match verdict {
        Some("pass") => Health::Promoted,
        Some("fail") => Health::Held,
        _ => Health::Pending,
    }
}

/// `YYYY-MM-DD` in UTC.
pub fn day(seconds: f64) -> String {
    let Ok(date) = time::OffsetDateTime::from_unix_timestamp(seconds.floor() as i64) else {
        return String::new();
    };
    format!("{:04}-{:02}-{:02}", date.year(), u8::from(date.month()), date.day())
}

/// A hex commit id, so a feed value never becomes another URL path.
pub fn is_commit(value: &str) -> bool {
    (7..=40).contains(&value.chars().count()) && value.chars().all(|c| c.is_ascii_hexdigit())
}

/// The commit page a build was cut from.
pub fn commit_url(commit: Option<&str>) -> Option<String> {
    commit.filter(|c| is_commit(c)).map(|c| format!("{REPOSITORY}/commit/{c}"))
}

/// The compare page from the installed build's commit to this one.
pub fn compare_url(from: Option<&str>, to: Option<&str>) -> Option<String> {
    let (from, to) = (from?, to?);
    (from != to && is_commit(from) && is_commit(to))
        .then(|| format!("{REPOSITORY}/compare/{from}...{to}"))
}

fn newest_first(builds: &mut [Build]) {
    builds.sort_by(|a, b| numeric::compare(&b.build, &a.build));
}

/// The feed items the Nightly track lists that the index lacks: each offered on the Nightly ring
/// or the followed one, whichever is faster.
fn nightly_feed_only<'a>(
    items: &'a [FeedItem],
    indexed: &HashSet<&str>,
    followed: Ring,
) -> Vec<&'a FeedItem> {
    let accepted = followed.max(Ring::Nightly).accepted_sparkle_channels();
    let mut seen = HashSet::new();
    items
        .iter()
        .filter(|item| {
            !item.version.is_empty()
                && !indexed.contains(item.version.as_str())
                && item.sparkle_channel.as_deref().is_none_or(|c| accepted.contains(&c))
                && seen.insert(item.version.as_str())
        })
        .collect()
}

/// The tracks, one per ring, slowest first. Nightly is the index plus the builds the feed offers
/// that it lacks; Dev adds the feed's other unindexed, unpulled builds; Stable and Canary are
/// empty until CI publishes them.
pub fn tracks(request: &Request) -> Vec<Track> {
    let limit = usize::try_from(request.limit.max(0)).unwrap_or(usize::MAX);
    let mut pulled: BTreeMap<&str, &Pulled> = BTreeMap::new();
    for entry in &request.pulled {
        pulled.entry(entry.build.as_str()).or_insert(entry);
    }
    let badge = |build: &str| {
        if pulled.contains_key(build) {
            Health::Pulled
        } else {
            health(request.verdicts.get(build).map(String::as_str))
        }
    };
    let from_index = request.index.iter().take(limit).map(|entry| Build {
        build: entry.build.clone(),
        short_version: entry.short_version.clone(),
        date: entry.date.clone(),
        commit: entry.head.clone(),
        health: badge(&entry.build),
        pulled_reason: pulled.get(entry.build.as_str()).map(|p| p.reason.clone()),
        is_installed: entry.build == request.installed_build,
        is_kept: request.kept_builds.contains(&entry.build),
    });
    let indexed: HashSet<&str> = request.index.iter().map(|e| e.build.as_str()).collect();
    let feed_build = |item: &FeedItem, health: Health, pulled_reason: Option<String>| Build {
        build: item.version.clone(),
        short_version: item.display_version.clone(),
        date: item.date.map(day).unwrap_or_default(),
        commit: None,
        health,
        pulled_reason,
        is_installed: item.version == request.installed_build,
        is_kept: request.kept_builds.contains(&item.version),
    };
    let ahead: Vec<Build> = if request.tip_feed {
        Vec::new()
    } else {
        nightly_feed_only(&request.feed_items, &indexed, request.followed)
            .into_iter()
            .map(|item| {
                feed_build(
                    item,
                    badge(&item.version),
                    pulled.get(item.version.as_str()).map(|p| p.reason.clone()),
                )
            })
            .collect()
    };
    let mut nightly: Vec<Build> = from_index.chain(ahead).collect();
    newest_first(&mut nightly);
    nightly.truncate(limit);
    let from_feed = request
        .feed_items
        .iter()
        .filter(|item| {
            !indexed.contains(item.version.as_str()) && !pulled.contains_key(item.version.as_str())
        })
        .map(|item| feed_build(item, Health::Pending, None));
    let mut dev: Vec<Build> = nightly.iter().cloned().chain(from_feed).collect();
    newest_first(&mut dev);
    dev.truncate(limit);
    Ring::ALL
        .iter()
        .map(|ring| Track {
            ring: *ring,
            builds: match ring {
                Ring::Nightly => nightly.clone(),
                Ring::Dev => dev.clone(),
                Ring::Stable | Ring::Canary => Vec::new(),
            },
            is_followed: *ring == request.followed,
            release_url: (*ring == Ring::Nightly)
                .then(|| format!("{REPOSITORY}/releases/tag/nightly-next")),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn request(value: serde_json::Value) -> Request {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn nightly_lists_the_index_and_the_feed_builds_it_lacks() {
        let tracks = tracks(&request(json!({
            "index": [
                {"build": "1204", "shortVersion": "0.9.4", "date": "2026-11-24", "head": "abcdef1"},
                {"build": "1203", "shortVersion": "0.9.3", "date": "2026-11-23"},
            ],
            "verdicts": {"1204": "pass", "1203": "fail"},
            "pulled": [{"build": "1203", "reason": "crash"}],
            "installedBuild": "1205",
            "keptBuilds": ["1204"],
            "followed": "nightly",
            "feedItems": [
                {"version": "1205", "displayVersion": "0.9.5", "date": 1795478400.0, "sparkleChannel": "cmux-next"},
                {"version": "1206", "displayVersion": "0.9.6", "sparkleChannel": "cmux-next-canary"},
            ],
        })));
        let nightly = &tracks[1];
        assert_eq!(nightly.ring, Ring::Nightly);
        assert!(nightly.is_followed);
        let builds: Vec<&str> = nightly.builds.iter().map(|b| b.build.as_str()).collect();
        assert_eq!(builds, ["1205", "1204", "1203"]);
        assert!(nightly.builds[0].is_installed);
        assert_eq!(nightly.builds[0].date, "2026-11-24");
        assert_eq!(nightly.builds[1].health, Health::Promoted);
        assert!(nightly.builds[1].is_kept);
        assert_eq!(nightly.builds[2].health, Health::Pulled);
        assert_eq!(nightly.builds[2].pulled_reason.as_deref(), Some("crash"));
        let dev: Vec<&str> = tracks[3].builds.iter().map(|b| b.build.as_str()).collect();
        assert_eq!(dev, ["1206", "1205", "1205", "1204", "1203"]);
        assert!(tracks[0].builds.is_empty() && tracks[2].builds.is_empty());
        assert_eq!(
            nightly.release_url.as_deref(),
            Some("https://github.com/manaflow-ai/cmux/releases/tag/nightly-next")
        );
    }

    #[test]
    fn a_faster_followed_ring_widens_the_nightly_track_and_tip_feeds_do_not() {
        let base = json!({
            "index": [], "installedBuild": "1", "followed": "canary",
            "feedItems": [{"version": "7", "displayVersion": "7", "sparkleChannel": "cmux-next-canary"}],
        });
        assert_eq!(tracks(&request(base.clone()))[1].builds.len(), 1);
        let mut tip = base;
        tip["tipFeed"] = json!(true);
        let tracks = tracks(&request(tip));
        assert!(tracks[1].builds.is_empty());
        assert_eq!(tracks[3].builds.len(), 1);
    }

    #[test]
    fn limit_caps_each_track() {
        let tracks = tracks(&request(json!({
            "index": [{"build": "3", "shortVersion": "3", "date": ""}, {"build": "2", "shortVersion": "2", "date": ""}],
            "installedBuild": "0", "followed": "nightly", "limit": 1,
        })));
        assert_eq!(tracks[1].builds.len(), 1);
        assert_eq!(tracks[1].builds[0].build, "3");
    }

    #[test]
    fn commit_links_only_for_hex_ids() {
        assert_eq!(
            commit_url(Some("abcdef1")).as_deref(),
            Some("https://github.com/manaflow-ai/cmux/commit/abcdef1")
        );
        assert_eq!(commit_url(Some("abc")), None);
        assert_eq!(commit_url(Some("../../evil")), None);
        assert_eq!(
            compare_url(Some("abcdef1"), Some("1234567")).as_deref(),
            Some("https://github.com/manaflow-ai/cmux/compare/abcdef1...1234567")
        );
        assert_eq!(compare_url(Some("abcdef1"), Some("abcdef1")), None);
        assert_eq!(compare_url(None, Some("abcdef1")), None);
    }

    #[test]
    fn day_is_utc() {
        assert_eq!(day(0.0), "1970-01-01");
        assert_eq!(day(1795564799.0), "2026-11-24");
    }
}
