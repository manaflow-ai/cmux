//! Which files a source lists and which subfolders it enters (Swift `ScreenshotScanRule`).

use unicode_normalization::UnicodeNormalization;

/// A file's kind, from its extension (Swift `FileGridMediaKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MediaKind {
    /// A still image.
    Image,
    /// A movie.
    Video,
    /// Anything else.
    Other,
}

impl MediaKind {
    /// Its bit in a [`ScanRule::kinds`] mask.
    pub const fn bit(self) -> u32 {
        match self {
            Self::Image => 1,
            Self::Video => 2,
            Self::Other => 4,
        }
    }

    /// The kind of a C ABI raw value (1 image, 2 video, 3 other).
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            1 => Some(Self::Image),
            2 => Some(Self::Video),
            3 => Some(Self::Other),
            _ => None,
        }
    }

    /// The C ABI raw value (1 image, 2 video, 3 other).
    pub const fn raw(self) -> u32 {
        match self {
            Self::Image => 1,
            Self::Video => 2,
            Self::Other => 3,
        }
    }
}

/// The kinds mask of images and videos (the default rule).
pub const IMAGES_AND_VIDEOS: u32 = 1 | 2;

/// What a source lists: file kinds, name prefixes, how deep it looks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanRule {
    /// The kinds listed, as [`MediaKind::bit`]s; 0 lists every kind.
    pub kinds: u32,
    /// Extensions (lowercase, no dot) listed as images whatever the system says (Snagit's `snagx`).
    pub extra_image_extensions: Vec<String>,
    /// When not empty, only files whose name starts with one of these are listed.
    pub name_prefixes: Vec<String>,
    /// How many folder levels below the source folder are read (0: the folder alone).
    pub depth: usize,
    /// When set, only subfolders whose name starts with it are entered.
    pub folder_prefix: Option<String>,
}

impl Default for ScanRule {
    fn default() -> Self {
        Self {
            kinds: IMAGES_AND_VIDEOS,
            extra_image_extensions: Vec::new(),
            name_prefixes: Vec::new(),
            depth: 0,
            folder_prefix: None,
        }
    }
}

/// The extension of a file name as `NSString.pathExtension` gives it: the text after the last
/// dot of the last path component, empty when there is none or the name starts with that dot.
pub fn path_extension(name: &str) -> &str {
    let name = name.trim_end_matches('/');
    let last = name.rsplit('/').next().unwrap_or(name);
    match last.rfind('.') {
        Some(dot) if dot > 0 => last.get(dot + 1..).unwrap_or_default(),
        _ => "",
    }
}

/// Whether `text` starts with `prefix` under canonical equivalence (Swift `String.hasPrefix`):
/// a decomposed `é` a file system kept matches a composed one.
pub fn has_prefix(text: &str, prefix: &str) -> bool {
    if text.starts_with(prefix) {
        return true;
    }
    let text: String = text.nfc().collect();
    let prefix: String = prefix.nfc().collect();
    text.starts_with(&prefix)
}

impl ScanRule {
    /// Images and videos, `depth` levels down, entering only folders whose name starts with
    /// `folder_prefix` when it is set.
    pub fn with_depth(depth: usize, folder_prefix: Option<&str>) -> Self {
        Self { depth, folder_prefix: folder_prefix.map(str::to_owned), ..Self::default() }
    }

    /// Whether the rule lists `kind`.
    pub fn lists(&self, kind: MediaKind) -> bool {
        self.kinds == 0 || self.kinds & kind.bit() != 0
    }

    /// The kind of a file the rule lists, or None when it does not list it.
    ///
    /// `system_kind` is what the system says the file's extension is (the app asks UTType).
    pub fn kind_of_file_named(&self, name: &str, system_kind: MediaKind) -> Option<MediaKind> {
        if name.starts_with('.') {
            return None;
        }
        if !self.name_prefixes.is_empty() && !self.name_prefixes.iter().any(|p| has_prefix(name, p))
        {
            return None;
        }
        let ext = path_extension(name).to_lowercase();
        let kind = if !ext.is_empty() && self.extra_image_extensions.contains(&ext) {
            MediaKind::Image
        } else {
            system_kind
        };
        self.lists(kind).then_some(kind)
    }

    /// Whether a subfolder named `name` is read (depth permitting).
    pub fn enters_folder(&self, name: &str) -> bool {
        if name.starts_with('.') {
            return false;
        }
        self.folder_prefix.as_deref().is_none_or(|p| has_prefix(name, p))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::Tool;

    /// A stand-in for UTType: the extensions the parity tests use.
    pub(crate) fn system_kind(name: &str) -> MediaKind {
        match path_extension(name).to_lowercase().as_str() {
            "png" | "jpg" | "jpeg" | "heic" | "gif" | "tiff" => MediaKind::Image,
            "mov" | "mp4" | "m4v" => MediaKind::Video,
            _ => MediaKind::Other,
        }
    }

    fn kind(rule: &ScanRule, name: &str) -> Option<MediaKind> {
        rule.kind_of_file_named(name, system_kind(name))
    }

    #[test]
    fn quick_time_lists_only_screen_recordings() {
        let rule = Tool::QuickTime.rule();
        assert_eq!(kind(&rule, "Screen Recording 2026-10-19.mov"), Some(MediaKind::Video));
        assert_eq!(kind(&rule, "Holiday.mov"), None);
        assert_eq!(kind(&rule, "Screen Recording.png"), None);
    }

    #[test]
    fn snagit_lists_its_own_format_as_images() {
        assert_eq!(kind(&Tool::Snagit.rule(), "Capture.SNAGX"), Some(MediaKind::Image));
        assert_eq!(kind(&ScanRule::default(), "Capture.snagx"), None);
    }

    #[test]
    fn an_empty_kinds_set_lists_everything() {
        let rule = ScanRule { kinds: 0, ..ScanRule::default() };
        assert_eq!(kind(&rule, "notes.txt"), Some(MediaKind::Other));
        assert_eq!(kind(&rule, ".hidden.png"), None);
    }

    #[test]
    fn folder_prefix_and_hidden_folders() {
        let rule = ScanRule::with_depth(1, Some("media_"));
        assert!(rule.enters_folder("media_123"));
        assert!(!rule.enters_folder("other"));
        assert!(!rule.enters_folder(".media_1"));
        assert!(ScanRule::default().enters_folder("anything"));
    }

    #[test]
    fn prefixes_match_decomposed_names() {
        let rule = ScanRule {
            name_prefixes: vec!["Enregistrement de l’écran".into()],
            ..ScanRule::default()
        };
        let decomposed = "Enregistrement de l’e\u{301}cran 1.mov";
        assert_eq!(kind(&rule, decomposed), Some(MediaKind::Video));
    }

    #[test]
    fn path_extension_matches_nsstring() {
        assert_eq!(path_extension("a.png"), "png");
        assert_eq!(path_extension("a.tar.gz"), "gz");
        assert_eq!(path_extension("noext"), "");
        assert_eq!(path_extension(".bashrc"), "");
        assert_eq!(path_extension("dir/x.MOV"), "MOV");
    }
}
