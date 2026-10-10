//! Values an administrator set for cmux (Swift `ManagedPreferences`). Keys
//! that start with a lowercase letter are cmux.json key paths
//! (`appearance.borders`); keys that start with an uppercase letter are
//! policy keys that are not user settings (`EnrollmentToken`, ...). Forced
//! values override the user's file; recommended values only replace the
//! product default. Any local user can write non-forced values, so policy
//! keys are read from forced values only.

#[cfg(target_os = "macos")]
mod cf;
mod policy;
mod reader;
mod team;

use std::collections::BTreeMap;

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[cfg(target_os = "macos")]
pub use cf::CfManagedReader;
pub use policy::{POLICY_KEYS, Policy, PolicyKey, PolicyType};
pub use reader::{
    FixedManagedReader, JsonFileManagedReader, ManagedReader, PlistFileManagedReader,
    default_reader, json_from_plist,
};
pub use team::TeamPolicyLayer;

/// The managed preference domain every channel reads.
pub const DOMAIN: &str = "com.manaflow.cmux";
/// The shipped updater's domain; only its forced `DisableAutoUpdate` is read.
pub const LEGACY_DOMAIN: &str = "com.cmuxterm.app";
pub const LEGACY_KEYS: [&str; 1] = ["DisableAutoUpdate"];
/// Debug builds read this file instead of the platform source.
pub const FILE_OVERRIDE_KEY: &str = "CMUX_NEXT_MANAGED_PREFS_FILE";
/// The managed file on Linux: forced keys at the top level, recommended
/// keys under `Recommended`.
pub const LINUX_MANAGED_FILE: &str = "/etc/cmux/managed.json";

/// Who manages a settings key: the device's MDM profile, or the policy of
/// the device's managing team (named).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ManagedSource {
    Device,
    Team(String),
}

impl ManagedSource {
    /// `mdm` or `team` (the status report's names).
    pub fn wire_name(&self) -> &'static str {
        match self {
            ManagedSource::Device => "mdm",
            ManagedSource::Team(_) => "team",
        }
    }

    pub fn team_name(&self) -> Option<&str> {
        match self {
            ManagedSource::Device => None,
            ManagedSource::Team(name) => Some(name),
        }
    }

    /// Swift `SettingManaged.description`.
    pub fn reason(&self, key: &str) -> String {
        match self {
            ManagedSource::Device => format!("{key} is managed by your organization"),
            ManagedSource::Team(name) if name.is_empty() => {
                format!("{key} is managed by your team")
            }
            ManagedSource::Team(name) => format!("{key} is managed by {name}"),
        }
    }

    /// `{source, team, reason}` for list rows and snapshots.
    pub fn to_json(&self, key: &str) -> Value {
        json!({"source": self.wire_name(), "team": self.team_name(), "reason": self.reason(key)})
    }
}

/// Forced and recommended managed values, keyed as written in the profile.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ManagedPreferences {
    pub forced: BTreeMap<String, Value>,
    pub recommended: BTreeMap<String, Value>,
}

impl ManagedPreferences {
    pub fn is_empty(&self) -> bool {
        self.forced.is_empty() && self.recommended.is_empty()
    }

    /// The forced `EnrollmentToken`, trimmed; `None` when absent or empty.
    pub fn enrollment_token(&self) -> Option<String> {
        let token = self.forced.get("EnrollmentToken")?.as_str()?.trim();
        (!token.is_empty()).then(|| token.to_string())
    }
}

/// Whether `key` names a cmux.json setting (as opposed to a policy key).
pub fn is_setting_key(key: &str) -> bool {
    key.chars().next().is_some_and(char::is_lowercase)
}

/// What `team.device.enroll` takes for the MDM `EnrollmentToken`:
/// base64url(SHA-256(token)) without padding.
pub fn enrollment_token_hash(token: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

/// Every key the published schema lists: the settings catalog plus the
/// policy keys (the only keys the macOS reader honors).
pub fn published_keys(schema: &crate::schema::Schema) -> Vec<String> {
    schema
        .rows
        .iter()
        .map(|row| row.key.clone())
        .chain(POLICY_KEYS.iter().map(|key| key.name.to_string()))
        .collect()
}
