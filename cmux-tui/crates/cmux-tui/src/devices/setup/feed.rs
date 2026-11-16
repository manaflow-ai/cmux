//! The NIGHTLY Sparkle feed: which build `cmux device setup` installs.

use super::*;

/// The NIGHTLY to install: the feed's newest build offered to Nightly apps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Nightly {
    pub build: u64,
    pub url: String,
    pub length: u64,
}

pub(super) static ITEM: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?s)<item>.*?</item>").ok());
pub(super) static VERSION: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>").ok());
pub(super) static CHANNEL: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>").ok());
pub(super) static ENCLOSURE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r#"<enclosure\s[^>]*?url="([^"]+\.dmg)"[^>]*?length="(\d+)"[^>]*>"#).ok()
});

/// nightly.py's `pick`: the newest item offered to Nightly apps (never a Dev-ring or Canary
/// build) with a DMG and a length; its DMG must be under [`DMG_PREFIXES`].
pub(crate) fn pick(feed: &str) -> Result<Nightly, String> {
    let (Some(items), Some(version), Some(enclosures), Some(channels)) =
        (ITEM.as_ref(), VERSION.as_ref(), ENCLOSURE.as_ref(), CHANNEL.as_ref())
    else {
        return Err("the feed patterns did not compile".into());
    };
    let best = items
        .find_iter(feed)
        .filter_map(|item| {
            let item = item.as_str();
            let build = version.captures(item)?.get(1)?.as_str().parse::<u64>().ok()?;
            let enclosure = enclosures.captures(item)?;
            let channel = channels.captures(item).and_then(|c| c.get(1)).map(|c| c.as_str());
            if !NIGHTLY_CHANNELS.contains(&channel) {
                return None;
            }
            let url = enclosure.get(1)?.as_str().to_owned();
            let length = enclosure.get(2)?.as_str().parse::<u64>().ok()?;
            Some(Nightly { build, url, length })
        })
        .max_by(|a, b| (a.build, &a.url, a.length).cmp(&(b.build, &b.url, b.length)))
        .ok_or("the NIGHTLY feed has no item with a DMG offered to Nightly apps")?;
    if !allowed_dmg(&best.url) {
        return Err(format!("{} is not a nightly-next download", best.url));
    }
    Ok(best)
}

pub(super) fn allowed_dmg(url: &str) -> bool {
    DMG_PREFIXES.iter().any(|prefix| url.starts_with(prefix))
        && !url.contains(['\n', '\r', '\'', '"', ' ', '\\'])
}
