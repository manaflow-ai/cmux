//! `browser.hibernation` and its companions as the rules read them. The app parses cmux.json
//! (BrowserHibernationSetting.swift, with its diagnostics) and passes the values here; what an
//! unset `browser.hibernation` means is decided here, by [`Setting::default`].

use serde::de::{self, Deserializer};
use serde::{Deserialize, Serialize, Serializer};

/// When hidden pages are discarded.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    /// Never, at any memory pressure.
    Off,
    /// After 30 minutes hidden (later for a tab the person keeps coming back to); earlier under
    /// memory pressure.
    Moderate,
    /// After 10 minutes hidden; every eligible hidden page under pressure.
    Aggressive,
    /// After this many minutes hidden.
    Minutes(f64),
}

impl Mode {
    /// Minutes hidden before a page is discarded; `None` when off.
    pub fn hidden_minutes(self) -> Option<f64> {
        match self {
            Mode::Off => None,
            Mode::Moderate => Some(30.0),
            Mode::Aggressive => Some(10.0),
            Mode::Minutes(minutes) => Some(minutes),
        }
    }
}

/// The JSON form is cmux.json's: `"off"`, `"moderate"`, `"aggressive"` or a number of minutes.
impl Serialize for Mode {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Mode::Off => serializer.serialize_str("off"),
            Mode::Moderate => serializer.serialize_str("moderate"),
            Mode::Aggressive => serializer.serialize_str("aggressive"),
            Mode::Minutes(minutes) => serializer.serialize_f64(*minutes),
        }
    }
}

impl<'de> Deserialize<'de> for Mode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match serde_json::Value::deserialize(deserializer)? {
            serde_json::Value::String(text) => match text.as_str() {
                "off" => Ok(Mode::Off),
                "moderate" => Ok(Mode::Moderate),
                "aggressive" => Ok(Mode::Aggressive),
                other => Err(de::Error::custom(format!("unknown hibernation mode {other:?}"))),
            },
            serde_json::Value::Number(number) => match number.as_f64() {
                Some(minutes) if minutes > 0.0 && minutes.is_finite() => Ok(Mode::Minutes(minutes)),
                _ => Err(de::Error::custom("hibernation minutes must be > 0")),
            },
            _ => {
                Err(de::Error::custom("expected \"off\", \"moderate\", \"aggressive\" or minutes"))
            }
        }
    }
}

/// The settings the rules read. Every field is optional on the wire; a missing one is its default.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Setting {
    /// `browser.hibernation`. `None`: cmux.json does not set it.
    pub mode: Option<Mode>,
    /// `browser.hibernationExclusions`: `example.com` (and its subdomains) or `*.example.com`
    /// (subdomains only) never hibernate.
    pub exclusions: Vec<String>,
    /// `browser.hibernatePinnedTabs`: pinned tabs hibernate too (default false).
    pub includes_pinned_tabs: bool,
    /// `browser.freezeHiddenTabs`: seconds hidden before a page freezes; `None` never.
    pub freeze_seconds: Option<f64>,
}

impl Default for Setting {
    fn default() -> Self {
        Setting {
            mode: None,
            exclusions: Vec::new(),
            includes_pinned_tabs: false,
            freeze_seconds: Some(30.0),
        }
    }
}

impl Setting {
    /// The mode in force. An unset `browser.hibernation` is `moderate`: hidden tabs are discarded
    /// after 30 minutes hidden, sooner under memory pressure (Leo, 2026-11-14, "4 yes": hidden
    /// browser tabs discarded by default, kept when they play audio, hold an unsaved form or are
    /// pinned). Before, unset only froze them and never discarded one on its own.
    pub fn effective_mode(&self) -> Mode {
        self.mode.unwrap_or(Mode::Moderate)
    }

    pub fn is_enabled(&self) -> bool {
        self.effective_mode() != Mode::Off
    }

    /// True when `host` matches an exclusion.
    pub fn excludes(&self, host: Option<&str>) -> bool {
        let Some(host) = host.map(str::to_lowercase).filter(|host| !host.is_empty()) else {
            return false;
        };
        self.exclusions.iter().any(|pattern| {
            let pattern = pattern.to_lowercase();
            match pattern.strip_prefix('*') {
                Some(suffix) if suffix.starts_with('.') => host.ends_with(suffix),
                _ => host == pattern || host.ends_with(&format!(".{pattern}")),
            }
        })
    }
}
