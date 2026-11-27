//! Chrome's "automatic downloads" rule, per site, for both engines (the count of
//! `DownloadRequestLimiter`; `AutomaticDownloadPolicy`): the first download a page starts since
//! the last user gesture on it goes ahead; each later one follows the site's stored
//! `automaticDownloads` setting (allow, block, or ask once and remember the answer). A fresh user
//! gesture (a mouse down or a key down on the page, or a load cmux starts) makes the next download
//! the first again. One value per tab; `AutomaticDownloadGate` holds it.

use serde::{Deserialize, Serialize};

/// What happens to one download a page starts (`AutomaticDownloadPolicy.Decision`). On the wire as
/// Swift's synthesized `Codable` writes an enum without raw values: `{"allow": {}}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DownloadDecision {
    Allow {},
    /// Ask the person once (Allow / Block); the answer is remembered for the site.
    Ask {},
    /// Refused without a prompt (the site is blocked).
    Refuse {},
}

/// A site's stored setting for one permission (`SitePermissionSetting`, raw values `ask`,
/// `allow`, `block`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SitePermissionSetting {
    /// Ask the user when the site requests it.
    Ask,
    Allow,
    Block,
}

/// One tab's count of downloads since the last gesture.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomaticDownloadPolicy {
    /// The site of the counted downloads, `None` after a gesture.
    #[serde(default)]
    pub site: Option<String>,
    /// Downloads `site` started since the last gesture.
    #[serde(default)]
    pub downloads_since_gesture: i64,
}

impl AutomaticDownloadPolicy {
    /// A fresh user gesture on the page.
    pub fn user_gesture(&mut self) {
        self.site = None;
        self.downloads_since_gesture = 0;
    }

    /// Counts a download a page on `site` starts. True when it is the first since the last gesture
    /// (a download from another site than the counted one starts a new count).
    pub fn count_download(&mut self, site: &str) -> bool {
        if self.site.as_deref() != Some(site) {
            self.site = Some(site.to_string());
            self.downloads_since_gesture = 0;
        }
        self.downloads_since_gesture = self.downloads_since_gesture.saturating_add(1);
        self.downloads_since_gesture == 1
    }

    /// The decision for a download: the first one goes ahead; a later one follows the site's
    /// stored setting.
    pub fn decision(is_first: bool, setting: SitePermissionSetting) -> DownloadDecision {
        if is_first {
            return DownloadDecision::Allow {};
        }
        match setting {
            SitePermissionSetting::Allow => DownloadDecision::Allow {},
            SitePermissionSetting::Block => DownloadDecision::Refuse {},
            SitePermissionSetting::Ask => DownloadDecision::Ask {},
        }
    }
}
