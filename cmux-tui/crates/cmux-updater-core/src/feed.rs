//! Which appcast a build follows and what it accepts in it: CmuxUpdaterCore's
//! `UpdateFeedResolver`, `UpdateRing` and `UpdateManualDownloadRecovery`.
//!
//! Nightly and RC feeds are per architecture: a channel `appcast.xml` (or the older
//! `appcast-universal.xml`) becomes `appcast-arm64.xml` or `appcast-x86_64.xml`, so a universal
//! build moves onto the thin one and an x86_64 build under Rosetta onto the native one.

use serde::{Deserialize, Serialize};

/// The appcast used when `SUFeedURL` is missing or empty.
pub const FALLBACK_FEED_URL: &str =
    "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml";

/// The direct stable DMG: the asset of the release the stable feed points at.
pub const STABLE_DOWNLOAD_URL: &str =
    "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg";

/// cmux.com's redirect to the DMG of the cmux-next feed's newest item. cmux-next ships for Apple
/// silicon only, so it is the same on every Mac.
pub const NIGHTLY_NEXT_DOWNLOAD_URL: &str = "https://cmux.com/api/download/next";

/// The `sparkle:channel` every cmux-next item carries.
pub const NIGHTLY_NEXT_SPARKLE_CHANNEL: &str = "cmux-next";

/// The CPU architecture an update targets (Rosetta already resolved to `arm64` by the app).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Architecture {
    #[serde(rename = "arm64")]
    Arm64,
    #[serde(rename = "x86_64")]
    X86_64,
}

impl Architecture {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Arm64 => "arm64",
            Self::X86_64 => "x86_64",
        }
    }
}

/// The release channel a feed URL belongs to, from its path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Channel {
    Stable,
    Nightly,
    Rc,
    NightlyNext,
}

impl Channel {
    /// Classifies `feed_url` by the channel path segment it contains.
    pub fn classify(feed_url: &str) -> Self {
        if feed_url.contains("/nightly-next/") {
            Self::NightlyNext
        } else if feed_url.contains("/nightly/") {
            Self::Nightly
        } else if feed_url.contains("/rc/") {
            Self::Rc
        } else {
            Self::Stable
        }
    }

    fn uses_per_architecture_feeds(self) -> bool {
        !matches!(self, Self::Stable)
    }

    /// The `sparkle:channel` tags accepted on `ring` besides untagged items. Only the cmux-next
    /// feed has rings.
    pub fn allowed_sparkle_channels(self, ring: Ring) -> Vec<&'static str> {
        match self {
            Self::NightlyNext => ring.accepted_sparkle_channels(),
            Self::Stable | Self::Nightly | Self::Rc => Vec::new(),
        }
    }

    /// The direct DMG a failed in-app update can fall back to.
    pub fn manual_download_url(self, architecture: Architecture) -> String {
        let arch = architecture.as_str();
        match self {
            Self::Stable => STABLE_DOWNLOAD_URL.to_owned(),
            Self::Nightly => format!(
                "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-{arch}.dmg"
            ),
            Self::Rc => format!(
                "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-{arch}.dmg"
            ),
            Self::NightlyNext => NIGHTLY_NEXT_DOWNLOAD_URL.to_owned(),
        }
    }
}

/// The release ring a cmux NEXT build follows inside its one appcast (`updates.channel`), slowest
/// first. Each ring accepts its own tag and every slower ring's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ring {
    Stable,
    Nightly,
    Canary,
    Dev,
}

impl Ring {
    pub const ALL: [Ring; 4] = [Ring::Stable, Ring::Nightly, Ring::Canary, Ring::Dev];

    /// The `sparkle:channel` tag of items published to this ring.
    pub fn sparkle_channel(self) -> &'static str {
        match self {
            Self::Stable => "cmux-next-stable",
            Self::Nightly => NIGHTLY_NEXT_SPARKLE_CHANNEL,
            Self::Canary => "cmux-next-canary",
            Self::Dev => "cmux-next-dev",
        }
    }

    /// The tags this ring accepts, slowest first.
    pub fn accepted_sparkle_channels(self) -> Vec<&'static str> {
        Self::ALL.iter().filter(|ring| **ring <= self).map(|ring| ring.sparkle_channel()).collect()
    }
}

/// The feed the updater queries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Resolution {
    pub url: String,
    pub channel: Channel,
    pub used_fallback: bool,
}

/// Resolves the feed from `SUFeedURL`, for `architecture`.
pub fn resolve(info_feed_url: Option<&str>, architecture: Architecture) -> Resolution {
    let Some(info) = info_feed_url.filter(|url| !url.is_empty()) else {
        return Resolution {
            url: FALLBACK_FEED_URL.to_owned(),
            channel: Channel::Stable,
            used_fallback: true,
        };
    };
    let channel = Channel::classify(info);
    let url = if channel.uses_per_architecture_feeds() {
        architecture_specific_feed_url(info, architecture)
    } else {
        info.to_owned()
    };
    Resolution { url, channel, used_fallback: false }
}

/// Rewrites a legacy `appcast.xml` or `appcast-universal.xml` to the per-architecture feed; any
/// other URL is returned unchanged.
pub fn architecture_specific_feed_url(feed_url: &str, architecture: Architecture) -> String {
    for legacy in ["/appcast.xml", "/appcast-universal.xml"] {
        if let Some(stem) = feed_url.strip_suffix(legacy) {
            return format!("{stem}/appcast-{}.xml", architecture.as_str());
        }
    }
    feed_url.to_owned()
}

/// Whether `bundle_id` is a DEV or staging build, which is never compared against the public
/// appcast (#6292).
pub fn is_dev_like_bundle_identifier(bundle_id: Option<&str>) -> bool {
    let Some(id) = bundle_id else { return false };
    ["com.cmuxterm.app.debug", "com.cmuxterm.app.staging"]
        .iter()
        .any(|base| id == *base || id.strip_prefix(base).is_some_and(|rest| rest.starts_with('.')))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_empty_feed_falls_back_to_stable() {
        for info in [None, Some("")] {
            let resolution = resolve(info, Architecture::Arm64);
            assert_eq!(resolution.url, FALLBACK_FEED_URL);
            assert_eq!(resolution.channel, Channel::Stable);
            assert!(resolution.used_fallback);
        }
    }

    #[test]
    fn channel_feeds_become_per_architecture() {
        let nightly = "https://files.cmux.com/nightly/appcast.xml";
        assert_eq!(
            resolve(Some(nightly), Architecture::X86_64).url,
            "https://files.cmux.com/nightly/appcast-x86_64.xml"
        );
        assert_eq!(
            resolve(Some("https://x/rc/appcast-universal.xml"), Architecture::Arm64).url,
            "https://x/rc/appcast-arm64.xml"
        );
        let next = resolve(Some("https://x/nightly-next/appcast.xml"), Architecture::Arm64);
        assert_eq!(next.channel, Channel::NightlyNext);
        assert_eq!(next.url, "https://x/nightly-next/appcast-arm64.xml");
        assert_eq!(
            resolve(Some("https://x/nightly/appcast-arm64.xml"), Architecture::X86_64).url,
            "https://x/nightly/appcast-arm64.xml"
        );
    }

    #[test]
    fn stable_feed_is_kept_as_is() {
        let stable = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml";
        let resolution = resolve(Some(stable), Architecture::X86_64);
        assert_eq!(resolution.url, stable);
        assert_eq!(resolution.channel, Channel::Stable);
        assert!(!resolution.used_fallback);
    }

    #[test]
    fn rings_accept_their_tag_and_every_slower_one() {
        assert_eq!(Ring::Stable.accepted_sparkle_channels(), vec!["cmux-next-stable"]);
        assert_eq!(
            Ring::Canary.accepted_sparkle_channels(),
            vec!["cmux-next-stable", "cmux-next", "cmux-next-canary"]
        );
        assert_eq!(Ring::Dev.accepted_sparkle_channels().len(), 4);
        assert!(Channel::Nightly.allowed_sparkle_channels(Ring::Dev).is_empty());
        assert_eq!(
            Channel::NightlyNext.allowed_sparkle_channels(Ring::Nightly),
            vec!["cmux-next-stable", "cmux-next"]
        );
    }

    #[test]
    fn manual_download_follows_the_feed_channel() {
        assert_eq!(
            Channel::classify("https://x/nightly/appcast-arm64.xml")
                .manual_download_url(Architecture::Arm64),
            "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-arm64.dmg"
        );
        assert_eq!(
            Channel::Rc.manual_download_url(Architecture::X86_64),
            "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-x86_64.dmg"
        );
        assert_eq!(
            Channel::NightlyNext.manual_download_url(Architecture::X86_64),
            NIGHTLY_NEXT_DOWNLOAD_URL
        );
        assert_eq!(
            Channel::classify("").manual_download_url(Architecture::Arm64),
            STABLE_DOWNLOAD_URL
        );
    }

    #[test]
    fn dev_and_staging_bundles_are_dev_like() {
        for id in [
            "com.cmuxterm.app.debug",
            "com.cmuxterm.app.debug.tag",
            "com.cmuxterm.app.staging",
            "com.cmuxterm.app.staging.x",
        ] {
            assert!(is_dev_like_bundle_identifier(Some(id)), "{id}");
        }
        for id in [Some("com.cmuxterm.app"), Some("com.cmuxterm.app.debugger"), None] {
            assert!(!is_dev_like_bundle_identifier(id));
        }
    }
}
