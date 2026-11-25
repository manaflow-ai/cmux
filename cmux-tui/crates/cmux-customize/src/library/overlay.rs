//! web-dev.json's overlay as the app judges it: what is in the folder it
//! names (the manifest `web-overlay.sh install` or `cmux customize use pr:N`
//! writes last), how old it is, and whether the app refuses it for another
//! web ABI (WebDevOverride.abiRefusal). A hand-installed overlay is not a
//! library entry, so without this the library reads as empty while the app
//! shows something else, or its own pages in place of a refused overlay.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;

use super::code::{LAYER_MANIFEST, WEB_DEV, read_object};
use crate::Customize;

/// The overlay web-dev.json names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Overlay {
    pub path: String,
    /// A library layer folder (`cmux customize use pr:N`); `false`: put there
    /// by hand (`scripts/cmux-next/web-overlay.sh install`).
    pub library: bool,
    /// web-dev.json's `enabled` is not `false`.
    pub enabled: bool,
    /// The folder has a manifest.json (an install that finished).
    pub installed: bool,
    /// The commit its bundles were built from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// When it was installed: the manifest's `stamp`, else the manifest's
    /// file time, in ms since 1970.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installed_ms: Option<u64>,
    /// The web ABI its bundles need.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abi: Option<u32>,
    /// The web ABI of the app's own pages (pages/web-abi.json), when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_abi: Option<u32>,
    /// Both ABIs are known and differ: the app shows its own pages instead.
    pub refused: bool,
}

impl Customize {
    /// web-dev.json's overlay, judged against an app whose pages need web ABI
    /// `app_abi`; `None` when web-dev.json names none.
    pub fn overlay(&self, app_abi: Option<u32>) -> Option<Overlay> {
        let (object, _) = read_object(&self.roots().config_dir.join(WEB_DEV)).ok()?;
        let path = object.get("overlay").and_then(Value::as_str)?.to_owned();
        let enabled = object.get("enabled").and_then(Value::as_bool) != Some(false);
        let manifest_path = Path::new(&path).join(LAYER_MANIFEST);
        let manifest = std::fs::read(&manifest_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        let installed = manifest.is_some();
        let manifest = manifest.unwrap_or(Value::Null);
        let commit = manifest.get("commit").and_then(Value::as_str).map(str::to_owned);
        let abi = manifest.get("abi").and_then(Value::as_u64).map(|abi| abi as u32);
        let installed_ms =
            manifest.get("stamp").and_then(Value::as_str).and_then(stamp_ms).or_else(|| {
                let modified = std::fs::metadata(&manifest_path).ok()?.modified().ok()?;
                Some(modified.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64)
            });
        let refused = matches!((abi, app_abi), (Some(want), Some(have)) if want != have);
        Some(Overlay {
            library: self.is_layer_path(&path),
            path,
            enabled,
            installed,
            commit,
            installed_ms,
            abi,
            app_abi,
            refused,
        })
    }
}

impl Overlay {
    /// `web-dev overlay 01192304 (3 days, refused: abi 4, app 7)`, or for a
    /// library layer only what the entry does not already say.
    pub fn words(&self, now_ms: u64) -> Option<String> {
        let mut parts = Vec::new();
        if !self.enabled {
            parts.push("off".to_owned());
        }
        if !self.installed {
            parts.push("no manifest".to_owned());
        }
        if !self.library
            && let Some(at) = self.installed_ms
        {
            parts.push(age(now_ms.saturating_sub(at)));
        }
        if self.refused {
            parts.push(format!(
                "refused: abi {}, app {}",
                self.abi.unwrap_or_default(),
                self.app_abi.unwrap_or_default()
            ));
        }
        if self.library {
            return (!parts.is_empty()).then(|| format!("web layer {}", parts.join(", ")));
        }
        let commit =
            self.commit.as_deref().map_or("unknown", |commit| commit.get(..8).unwrap_or(commit));
        Some(if parts.is_empty() {
            format!("web-dev overlay {commit}")
        } else {
            format!("web-dev overlay {commit} ({})", parts.join(", "))
        })
    }
}

/// `3 days`, `5 hours`, `under an hour`.
pub(super) fn age(ms: u64) -> String {
    let hours = ms / 3_600_000;
    match hours {
        0 => "under an hour".to_owned(),
        1 => "1 hour".to_owned(),
        2..=47 => format!("{hours} hours"),
        _ => format!("{} days", hours / 24),
    }
}

/// web-overlay.sh's stamp, `20261112T081500Z-4242`, as ms since 1970.
fn stamp_ms(stamp: &str) -> Option<u64> {
    let digits = |range: std::ops::Range<usize>| stamp.get(range)?.parse::<i64>().ok();
    if stamp.get(8..9)? != "T" || stamp.get(15..16)? != "Z" {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(4..6)?, digits(6..8)?);
    let (hour, minute, second) = (digits(9..11)?, digits(11..13)?, digits(13..15)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second;
    u64::try_from(seconds).ok().map(|seconds| seconds * 1_000)
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Now, in ms since 1970.
pub(crate) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

#[cfg(test)]
#[path = "overlay_tests.rs"]
mod tests;
