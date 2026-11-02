//! The release line a build belongs to and what the running bundle says about
//! itself for updates. The app reads `Info.plist` and classifies the feed URL
//! (`UpdateFeedResolver`, which Sparkle's delegate also reads); this decides.

use crate::version::{SystemVersion, is_whitespace};
use serde::{Deserialize, Serialize};

/// cmux NEXT DEV's bundle id (the Release compile of feat-cmux-next).
pub const TIP_BUNDLE_IDENTIFIER: &str = "com.cmuxterm.app.debug.next";
/// The feed main's DEV publisher stamps into that bundle.
pub const TIP_FEED_PREFIX: &str = "https://files.cmux.com/nightly-next/tip/";

/// The release line, which decides the Sparkle feed. The raw value is the
/// `track` of `updates.status`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum UpdateTrack {
    Stable,
    /// Classic cmux NIGHTLY: main's `/nightly/` feed.
    Nightly,
    Rc,
    Development,
    /// cmux NEXT's nightly ring: a `/nightly-next/` feed.
    NightlyNext,
}

impl UpdateTrack {
    /// Whether a test appcast may replace the baked feed: DEV and both nightly
    /// rings, never stable or RC.
    pub fn allows_test_feed(self) -> bool {
        matches!(self, Self::Nightly | Self::NightlyNext | Self::Development)
    }

    /// `updates.downloadAutomatically` for an install that never set it: off
    /// on every channel (Leo 2026-10-27; claude-sr2 2026-10-26).
    pub fn downloads_automatically_by_default(self) -> bool {
        false
    }
}

/// The channel `UpdateFeedResolver` classifies the feed URL as.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FeedChannel {
    Stable,
    Nightly,
    Rc,
    NightlyNext,
}

/// Why Sparkle does not run in this process.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DisabledReason {
    /// A tagged DEV or staging build.
    DevelopmentBuild,
    /// `SUPublicEDKey` is missing or was never substituted at build time.
    MissingPublicKey,
    /// A configuration profile forces `DisableAutoUpdate`.
    ManagedPolicy,
}

/// Whether `bundle_identifier` is a DEV (`com.cmuxterm.app.debug[.<tag>]`)
/// or staging (`com.cmuxterm.app.staging[.<tag>]`) build.
pub fn is_development_bundle(bundle_identifier: Option<&str>) -> bool {
    let Some(identifier) = bundle_identifier else { return false };
    ["com.cmuxterm.app.debug", "com.cmuxterm.app.staging"].iter().any(|base| {
        identifier == *base
            || identifier.strip_prefix(base).is_some_and(|rest| rest.starts_with('.'))
    })
}

/// Whether `SUPublicEDKey` holds a real key: non-empty after trimming spaces
/// and tabs, and not an unsubstituted `$(SPARKLE_PUBLIC_KEY)`.
pub fn has_public_key(raw: Option<&str>) -> bool {
    let key = raw.unwrap_or("").trim_matches(is_whitespace);
    !key.is_empty() && !key.starts_with("$(")
}

/// The update-relevant `Info.plist` strings (each one present only when the
/// plist holds a string there).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoStrings {
    #[serde(default)]
    pub bundle_identifier: Option<String>,
    #[serde(default)]
    pub short_version: Option<String>,
    #[serde(default)]
    pub build: Option<String>,
    #[serde(default)]
    pub minimum_system_version: Option<String>,
    #[serde(default)]
    pub feed_url: Option<String>,
    #[serde(default)]
    pub public_key: Option<String>,
}

/// `UpdateBuildIdentity(infoDictionary:)`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildInfo {
    pub bundle_identifier: Option<String>,
    /// `CFBundleShortVersionString`, else "0".
    pub short_version: String,
    /// `CFBundleVersion`, else "0".
    pub build: String,
    pub minimum_system_version: Option<SystemVersion>,
    pub info_feed_url: Option<String>,
    pub has_public_key: bool,
}

pub fn build_info(info: &InfoStrings) -> BuildInfo {
    BuildInfo {
        bundle_identifier: info.bundle_identifier.clone(),
        short_version: info.short_version.clone().unwrap_or_else(|| "0".to_owned()),
        build: info.build.clone().unwrap_or_else(|| "0".to_owned()),
        minimum_system_version: info
            .minimum_system_version
            .as_deref()
            .and_then(SystemVersion::parse),
        info_feed_url: info.feed_url.clone(),
        has_public_key: has_public_key(info.public_key.as_deref()),
    }
}

/// What the running build decides from its identity.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildFacts {
    #[serde(default)]
    pub bundle_identifier: Option<String>,
    #[serde(default)]
    pub info_feed_url: Option<String>,
    pub has_public_key: bool,
    pub feed_channel: FeedChannel,
    #[serde(default)]
    pub managed_policy_disables_updates: bool,
}

/// The tip app: cmux NEXT DEV as published. Both the exact bundle id and the
/// stamped feed are required, so a local `reload.sh --tag next` build (same
/// id, the default feed) stays development.
pub fn is_tip_build(bundle_identifier: Option<&str>, info_feed_url: Option<&str>) -> bool {
    bundle_identifier == Some(TIP_BUNDLE_IDENTIFIER)
        && info_feed_url.is_some_and(|feed| feed.starts_with(TIP_FEED_PREFIX))
}

pub fn track(facts: &BuildFacts) -> UpdateTrack {
    let bundle = facts.bundle_identifier.as_deref();
    if is_development_bundle(bundle) && !is_tip_build(bundle, facts.info_feed_url.as_deref()) {
        return UpdateTrack::Development;
    }
    match facts.feed_channel {
        FeedChannel::Stable => UpdateTrack::Stable,
        FeedChannel::Nightly => UpdateTrack::Nightly,
        FeedChannel::NightlyNext => UpdateTrack::NightlyNext,
        FeedChannel::Rc => UpdateTrack::Rc,
    }
}

/// Why Sparkle must not run, or none when it may.
pub fn sparkle_disabled_reason(facts: &BuildFacts) -> Option<DisabledReason> {
    if track(facts) == UpdateTrack::Development {
        return Some(DisabledReason::DevelopmentBuild);
    }
    if !facts.has_public_key {
        return Some(DisabledReason::MissingPublicKey);
    }
    if facts.managed_policy_disables_updates {
        return Some(DisabledReason::ManagedPolicy);
    }
    None
}

/// Whether the build may offer its bundle id's channel-switch counterpart: a
/// local build with the tip app's bundle id but not its feed offers nothing.
pub fn offers_channel_switch(facts: &BuildFacts) -> bool {
    let bundle = facts.bundle_identifier.as_deref();
    bundle != Some(TIP_BUNDLE_IDENTIFIER) || is_tip_build(bundle, facts.info_feed_url.as_deref())
}

/// Every rule of [`BuildFacts`] at once (the `updater_build_rules` answer).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildRules {
    pub is_tip_build: bool,
    pub development_bundle: bool,
    pub track: UpdateTrack,
    pub allows_test_feed: bool,
    pub downloads_automatically_by_default: bool,
    pub disabled_reason: Option<DisabledReason>,
    pub offers_channel_switch: bool,
}

pub fn build_rules(facts: &BuildFacts) -> BuildRules {
    let track = track(facts);
    BuildRules {
        is_tip_build: is_tip_build(
            facts.bundle_identifier.as_deref(),
            facts.info_feed_url.as_deref(),
        ),
        development_bundle: is_development_bundle(facts.bundle_identifier.as_deref()),
        track,
        allows_test_feed: track.allows_test_feed(),
        downloads_automatically_by_default: track.downloads_automatically_by_default(),
        disabled_reason: sparkle_disabled_reason(facts),
        offers_channel_switch: offers_channel_switch(facts),
    }
}
