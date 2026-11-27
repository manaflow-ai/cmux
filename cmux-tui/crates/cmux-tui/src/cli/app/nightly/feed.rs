//! `cmux nightly whats-in [BUILD]` and `cmux nightly which <PR>`: which PRs went into which NIGHTLY.
//!
//! Leo (2026-11-26): "hm do we display which prs go into which nightly maybe that'd be useful per
//! thing?" Every nightly publishes its release notes beside the feed, each file signed with the
//! `content-signing` key (`<file>.sig`, the key `feature_flags::verify` checks): `notes/index.json`
//! (the recent builds, newest first), `notes/<build>.json` (that build's PRs, `items`, merged since the
//! build before it) and, once the publisher writes it, `notes/pr-index.json` (each PR's first build).
//! A file whose signature does not verify counts as unreadable, never as data.
//!
//! Fields the publisher adds over time are read when present and never required: `since` (the build
//! the range starts after; else the next older build in the index), `publishedAt` (else `builtAt`,
//! else `date`), and each item's `area` (else "Other"), `url` and `mergedAt`.

use std::time::Duration;

use cmux_json::JsonGet as _;
use serde_json::{Value, json};

use crate::localization::NightlyMessages;

/// Where the nightly-next track publishes its notes.
pub(crate) const NOTES_URL: &str = "https://files-next.cmux.com/nightly-next/notes";
/// Each file (and its signature) is a few KB from a CDN.
const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
const REPO_PULL_URL: &str = "https://github.com/manaflow-ai/cmux/pull/";

/// One notes file: verified JSON, or absent from the feed (404).
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Fetched {
    Found(Value),
    Missing,
}

/// Fetches `names` (paths under [`NOTES_URL`]) at once and checks each against its signature.
pub(super) fn fetch_all(names: &[String]) -> Vec<Result<Fetched, String>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return names.iter().map(|_| Err(error.to_string())).collect(),
    };
    let client = match reqwest::Client::builder()
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .timeout(FETCH_TIMEOUT)
        .build()
    {
        Ok(client) => client,
        Err(error) => return names.iter().map(|_| Err(error.to_string())).collect(),
    };
    let key = crate::feature_flags::public_key();
    runtime.block_on(futures_util::future::join_all(
        names.iter().map(|name| fetch_one(&client, name, &key)),
    ))
}

async fn fetch_one(client: &reqwest::Client, name: &str, key: &str) -> Result<Fetched, String> {
    let get = |url: String| async move {
        let response = client.get(&url).send().await.map_err(|e| e.without_url().to_string())?;
        let status = response.status().as_u16();
        let bytes = response.bytes().await.map_err(|e| e.without_url().to_string())?;
        Ok::<_, String>((status, bytes))
    };
    let url = format!("{NOTES_URL}/{name}");
    let (body, signature) =
        futures_util::future::join(get(url.clone()), get(format!("{url}.sig"))).await;
    let (status, data) = body?;
    if status == 404 {
        return Ok(Fetched::Missing);
    }
    if !(200..300).contains(&status) {
        return Err(format!("{name}: HTTP {status}"));
    }
    match signature? {
        (200..=299, signature) if crate::feature_flags::verify(&data, &signature, key) => {}
        _ => return Err(format!("{name}: the signature does not verify")),
    }
    serde_json::from_slice(&data).map(Fetched::Found).map_err(|error| format!("{name}: {error}"))
}

/// The build number in `system.identify`'s `build` (`4572038238101` or `1.0.0-nightly.4572038238101`).
pub(super) fn build_number(identified: &str) -> Option<String> {
    let tail = identified.rsplit(['.', '-']).next()?;
    (!tail.is_empty() && tail.bytes().all(|byte| byte.is_ascii_digit())).then(|| tail.to_owned())
}

/// A PR number from `57000`, `#57000` or a pull request URL.
pub(super) fn pr_number(word: &str) -> Option<u64> {
    let word = word.trim_end_matches('/');
    let word = word.rsplit('/').next().unwrap_or(word);
    word.trim_start_matches('#').parse::<u64>().ok().filter(|number| *number > 0)
}

/// The builds `index.json` lists, newest first.
fn builds(index: &Value) -> &[Value] {
    index.get_array("builds")
}

/// The newest build the index lists.
pub(super) fn newest(index: &Value) -> Option<String> {
    builds(index)
        .iter()
        .filter_map(|build| build.get_nonempty_str("build"))
        .max_by(|a, b| super::order(a, b))
        .map(str::to_owned)
}

/// The next older build than `build` in the index: where its range starts when the notes do not say.
pub(super) fn previous(index: &Value, build: &str) -> Option<String> {
    builds(index)
        .iter()
        .filter_map(|entry| entry.get_nonempty_str("build"))
        .filter(|number| super::older(number, build))
        .max_by(|a, b| super::order(a, b))
        .map(str::to_owned)
}

fn published_at(notes: &Value) -> Option<&str> {
    notes
        .get_nonempty_str("publishedAt")
        .or_else(|| notes.get_nonempty_str("builtAt"))
        .or_else(|| notes.get_nonempty_str("date"))
}

/// `whats-in`'s report: the build's PRs grouped by area (areas by name, the unnamed last).
pub(super) fn whats_in(notes: &Value, index: Option<&Value>) -> Value {
    let build = notes.get_str("build").unwrap_or_default();
    let since = notes
        .get("since")
        .and_then(|since| match since {
            Value::String(build) => Some(json!({ "build": build })),
            Value::Object(_) => Some(since.clone()),
            _ => None,
        })
        .or_else(|| {
            index.and_then(|index| previous(index, build)).map(|build| json!({ "build": build }))
        });
    let mut groups: Vec<(Option<String>, Vec<Value>)> = Vec::new();
    for item in notes.get_array("items") {
        let area = item.get_nonempty_str("area").map(str::to_owned);
        let pr = item.get("pr").and_then(Value::as_u64);
        let entry = json!({
            "pr": pr,
            "title": item.get_str("title").unwrap_or_default(),
            "author": item.get_nonempty_str("author"),
            "url": item.get_nonempty_str("url").map(str::to_owned)
                .or_else(|| pr.map(|pr| format!("{REPO_PULL_URL}{pr}"))),
            "mergedAt": item.get_nonempty_str("mergedAt"),
        });
        match groups.iter_mut().find(|(name, _)| *name == area) {
            Some((_, items)) => items.push(entry),
            None => groups.push((area, vec![entry])),
        }
    }
    groups.sort_by(|(a, _), (b, _)| match (a, b) {
        (Some(a), Some(b)) => a.to_lowercase().cmp(&b.to_lowercase()),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    let count: usize = groups.iter().map(|(_, items)| items.len()).sum();
    json!({
        "build": build,
        "shortVersion": notes.get_nonempty_str("shortVersion"),
        "head": notes.get_nonempty_str("head"),
        "publishedAt": published_at(notes),
        "since": since,
        "count": count,
        "areas": groups.into_iter().map(|(area, items)| json!({ "area": area, "items": items })).collect::<Vec<_>>(),
    })
}

/// `whats-in` as text: a header, then each area and its PRs.
pub(super) fn whats_in_human(report: &Value, messages: &NightlyMessages) -> String {
    let since = report.get("since").and_then(|since| since.get_nonempty_str("build"));
    let header = match since {
        Some(since) => messages.whats_in_since.replace("{since}", since),
        None => messages.whats_in_first.to_owned(),
    };
    let mut out = format!(
        "{}\n",
        header
            .replace("{build}", report.get_str("build").unwrap_or_default())
            .replace("{version}", report.get_str("shortVersion").unwrap_or_default())
            .replace("{time}", report.get_str("publishedAt").unwrap_or_default())
            .replace(
                "{count}",
                &report.get("count").and_then(Value::as_u64).unwrap_or(0).to_string()
            )
    );
    let areas = report.get_array("areas");
    if areas.is_empty() {
        out.push_str(messages.whats_in_empty);
        out.push('\n');
    }
    for group in areas {
        out.push_str(&format!(
            "\n{}\n",
            group.get_nonempty_str("area").unwrap_or(messages.other_area)
        ));
        for item in group.get_array("items") {
            let pr = item
                .get("pr")
                .and_then(Value::as_u64)
                .map(|pr| format!("#{pr} "))
                .unwrap_or_default();
            let author = item
                .get_nonempty_str("author")
                .map(|author| format!(" (@{author})"))
                .unwrap_or_default();
            out.push_str(&format!("  {pr}{}{author}\n", item.get_str("title").unwrap_or_default()));
        }
    }
    out
}

/// `which` from `pr-index.json`: `{"prs": {"57000": {...}}}` or `{"57000": {...}}`, each entry naming
/// at least its `build`. `None` when the index does not list the PR.
pub(super) fn which_from_pr_index(pr_index: &Value, pr: u64) -> Option<Value> {
    let map = pr_index.get("prs").and_then(Value::as_object).or_else(|| pr_index.as_object())?;
    let entry = map.get(&pr.to_string())?;
    let build = match entry {
        Value::String(build) => build.clone(),
        _ => entry.get_nonempty_str("build")?.to_owned(),
    };
    let field = |key: &str| entry.get_nonempty_str(key).map(str::to_owned);
    Some(json!({
        "pr": pr,
        "shipped": true,
        "build": build,
        "shortVersion": field("shortVersion"),
        "publishedAt": field("publishedAt").or_else(|| field("builtAt")).or_else(|| field("date")),
    }))
}

/// `which` from the per-build notes: the oldest build whose items list the PR.
pub(super) fn which_from_notes(notes: &[Value], pr: u64) -> Option<Value> {
    notes
        .iter()
        .filter(|notes| {
            notes
                .get_array("items")
                .iter()
                .any(|item| item.get("pr").and_then(Value::as_u64) == Some(pr))
        })
        .min_by(|a, b| {
            super::order(
                a.get_str("build").unwrap_or_default(),
                b.get_str("build").unwrap_or_default(),
            )
        })
        .map(|notes| {
            json!({
                "pr": pr,
                "shipped": true,
                "build": notes.get_str("build").unwrap_or_default(),
                "shortVersion": notes.get_nonempty_str("shortVersion"),
                "publishedAt": published_at(notes),
            })
        })
}

/// The answer for a PR no listed build carries; `oldest` is how far back the feed reaches.
pub(super) fn not_shipped(pr: u64, oldest: Option<&str>) -> Value {
    json!({ "pr": pr, "shipped": false, "oldestBuild": oldest })
}

/// `which` as one line.
pub(super) fn which_human(answer: &Value, messages: &NightlyMessages) -> String {
    let pr = answer.get("pr").and_then(Value::as_u64).unwrap_or(0).to_string();
    if answer.get_bool("shipped") != Some(true) {
        return format!(
            "{}\n",
            messages
                .which_not_shipped
                .replace("{pr}", &pr)
                .replace("{oldest}", answer.get_str("oldestBuild").unwrap_or("?"))
        );
    }
    let build = answer.get_str("build").unwrap_or_default();
    format!(
        "{}\n",
        messages
            .which_shipped
            .replace("{pr}", &pr)
            .replace("{build}", build)
            .replace("{version}", answer.get_str("shortVersion").unwrap_or(build))
            .replace("{time}", answer.get_str("publishedAt").unwrap_or("?"))
    )
}
