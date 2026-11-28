//! The screenshot and screen-recording tools the pane knows and where each saves (Swift
//! `ScreenshotTool`).

use crate::rule::{IMAGES_AND_VIDEOS, MediaKind, ScanRule};
use crate::settings::SettingsFormat;

/// A third-party (or Apple) screenshot or recording tool, in menu order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tool {
    /// CleanShot X.
    CleanShotX,
    /// Shottr.
    Shottr,
    /// Xnapper.
    Xnapper,
    /// Snagit.
    Snagit,
    /// Monosnap.
    Monosnap,
    /// Skitch.
    Skitch,
    /// Flameshot.
    Flameshot,
    /// Kap.
    Kap,
    /// Cap.
    Cap,
    /// QuickTime Player's screen recordings.
    QuickTime,
}

/// A settings file a tool keeps its save folder in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettingsFile {
    /// Path below the home folder.
    pub path: &'static str,
    /// The key holding the folder.
    pub key: &'static str,
    /// The file's format.
    pub format: SettingsFormat,
}

/// A folder a tool always uses, below the home folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FixedFolder {
    /// Path below the home folder.
    pub path: &'static str,
    /// What is listed there.
    pub rule: ScanRule,
    /// Whether it is the tool's history (read-only, not a drop target) rather than its save folder.
    pub history: bool,
}

/// The names macOS gives a screen recording, in the languages the pane recognizes.
pub const RECORDING_PREFIXES: [&str; 9] = [
    "Screen Recording",
    "Bildschirmaufnahme",
    "Enregistrement de l’écran",
    "Grabación de pantalla",
    "Registrazione schermo",
    "画面収録",
    "屏幕录制",
    "螢幕錄影",
    "화면 기록",
];

impl Tool {
    /// Every tool, in menu order.
    pub const ALL: [Self; 10] = [
        Self::CleanShotX,
        Self::Shottr,
        Self::Xnapper,
        Self::Snagit,
        Self::Monosnap,
        Self::Skitch,
        Self::Flameshot,
        Self::Kap,
        Self::Cap,
        Self::QuickTime,
    ];

    /// The id part of its sources (`tool.<raw>`), Swift's raw value.
    pub const fn raw(self) -> &'static str {
        match self {
            Self::CleanShotX => "cleanShotX",
            Self::Shottr => "shottr",
            Self::Xnapper => "xnapper",
            Self::Snagit => "snagit",
            Self::Monosnap => "monosnap",
            Self::Skitch => "skitch",
            Self::Flameshot => "flameshot",
            Self::Kap => "kap",
            Self::Cap => "cap",
            Self::QuickTime => "quickTime",
        }
    }

    /// The tool whose raw value is `raw`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.raw() == raw)
    }

    /// The product's name, as its menu shows (not translated).
    pub const fn display_name(self) -> &'static str {
        match self {
            Self::CleanShotX => "CleanShot X",
            Self::Shottr => "Shottr",
            Self::Xnapper => "Xnapper",
            Self::Snagit => "Snagit",
            Self::Monosnap => "Monosnap",
            Self::Skitch => "Skitch",
            Self::Flameshot => "Flameshot",
            Self::Kap => "Kap",
            Self::Cap => "Cap",
            Self::QuickTime => "QuickTime Player",
        }
    }

    /// The preferences domains its settings may be in (direct, App Store, Setapp, yearly versions).
    pub const fn preference_domains(self) -> &'static [&'static str] {
        match self {
            Self::CleanShotX => &["pl.maketheweb.cleanshotx", "pl.maketheweb.cleanshotx-setapp"],
            Self::Shottr => &["cc.ffitch.shottr"],
            Self::Xnapper => &["com.xnapper.Xnapper", "com.xnapper.xnapper"],
            Self::Snagit => &[
                "com.TechSmith.Snagit2025",
                "com.TechSmith.Snagit2024",
                "com.TechSmith.Snagit2023",
                "com.TechSmith.Snagit2022",
                "com.TechSmith.Snagit2021",
                "com.TechSmith.Snagit2020",
                "com.TechSmith.Snagit",
            ],
            Self::Monosnap => &["com.monosnap.monosnap"],
            Self::Skitch => &["com.skitch.skitch"],
            Self::Flameshot => &["org.flameshot.flameshot"],
            Self::Kap => &["com.wulkano.kap"],
            Self::Cap => &["so.cap.desktop"],
            Self::QuickTime => &[],
        }
    }

    /// The preference keys known to hold its save folder.
    pub const fn folder_keys(self) -> &'static [&'static str] {
        match self {
            Self::CleanShotX => &["exportPath"],
            _ => &[],
        }
    }

    /// The settings file holding its save folder, for tools that keep one.
    pub const fn settings_file(self) -> Option<SettingsFile> {
        match self {
            Self::Flameshot => Some(SettingsFile {
                path: ".config/flameshot/flameshot.ini",
                key: "savePath",
                format: SettingsFormat::Ini,
            }),
            Self::Kap => Some(SettingsFile {
                path: "Library/Application Support/Kap/config.json",
                key: "kapturesDir",
                format: SettingsFormat::Json,
            }),
            _ => None,
        }
    }

    /// What its save folder lists.
    pub fn rule(self) -> ScanRule {
        match self {
            Self::Kap | Self::Cap => ScanRule { kinds: IMAGES_AND_VIDEOS, ..ScanRule::default() },
            Self::QuickTime => ScanRule {
                kinds: MediaKind::Video.bit(),
                name_prefixes: RECORDING_PREFIXES.iter().map(|p| (*p).to_owned()).collect(),
                ..ScanRule::default()
            },
            Self::Snagit => {
                ScanRule { extra_image_extensions: vec!["snagx".into()], ..ScanRule::default() }
            }
            _ => ScanRule::default(),
        }
    }

    /// The folders it always uses (history, library, default save folder).
    pub fn fixed_folders(self) -> Vec<FixedFolder> {
        match self {
            Self::CleanShotX => vec![FixedFolder {
                path: "Library/Application Support/CleanShot/media",
                rule: ScanRule::with_depth(1, Some("media_")),
                history: true,
            }],
            Self::Snagit => vec![FixedFolder {
                path: "Library/Group Containers/7TQL462TU8.com.techsmith.snagit/Snagit/Autosave",
                rule: ScanRule {
                    extra_image_extensions: vec!["snagx".into()],
                    depth: 1,
                    ..ScanRule::default()
                },
                history: true,
            }],
            Self::Monosnap => vec![FixedFolder {
                path: "Pictures/Monosnap",
                rule: ScanRule::default(),
                history: false,
            }],
            Self::Kap => vec![FixedFolder {
                path: "Movies/Kaptures",
                rule: ScanRule { kinds: IMAGES_AND_VIDEOS, ..ScanRule::default() },
                history: false,
            }],
            Self::Cap => vec![FixedFolder {
                path: "Library/Application Support/so.cap.desktop/recordings",
                rule: ScanRule { kinds: MediaKind::Video.bit(), depth: 3, ..ScanRule::default() },
                history: true,
            }],
            Self::QuickTime => {
                vec![FixedFolder { path: "Movies", rule: self.rule(), history: false }]
            }
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_values_round_trip_in_menu_order() {
        let raws: Vec<_> = Tool::ALL.iter().map(|t| t.raw()).collect();
        assert_eq!(
            raws,
            [
                "cleanShotX",
                "shottr",
                "xnapper",
                "snagit",
                "monosnap",
                "skitch",
                "flameshot",
                "kap",
                "cap",
                "quickTime"
            ]
        );
        for tool in Tool::ALL {
            assert_eq!(Tool::from_raw(tool.raw()), Some(tool));
        }
        assert_eq!(Tool::from_raw("nope"), None);
    }

    #[test]
    fn only_history_folders_are_marked_history() {
        let history: Vec<_> = Tool::ALL
            .into_iter()
            .filter(|t| t.fixed_folders().iter().any(|f| f.history))
            .map(Tool::raw)
            .collect();
        assert_eq!(history, ["cleanShotX", "snagit", "cap"]);
    }
}
