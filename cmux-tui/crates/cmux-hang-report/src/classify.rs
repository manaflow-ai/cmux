//! Which frames are named: an image is named only when it is ours (in the app bundle) or Apple's
//! (on the sealed system volume or an OS cryptex), and only when its last path component is a
//! plain name holding none of the person's words. Everything else is `other`, with no uuid or
//! offset.

use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;

use crate::report::Frame;

pub const OWN_NAME_PREFIXES: [&str; 6] =
    ["cmux", "Cmux", "GhosttyKit", "Chromium Embedded Framework", "Sparkle", "Sentry"];
pub const MAX_OFFSET: u64 = 1 << 40;
pub const APPLE_PATH_PREFIXES: [&str; 2] = ["/System/", "/usr/lib/"];
pub const NOT_APPLE_PATH_PREFIXES: [&str; 8] = [
    "/System/Volumes/",
    "/System/Library/Caches/",
    "/System/Library/Assets/",
    "/System/Library/AssetsV2/",
    "/System/Library/PreinstalledAssets/",
    "/System/Library/PreinstalledAssetsV2/",
    "/System/Library/Speech/",
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/",
];
pub const CRYPTEX_SYSTEM_PREFIXES: [&str; 2] = [
    "/System/Volumes/Preboot/Cryptexes/OS/System/",
    "/System/Volumes/Preboot/Cryptexes/App/System/",
];
const MINIMUM_TERM_LENGTH: usize = 4;
const OWN_WORDS: [&str; 14] = [
    "cmux next nightly",
    "ghosttykit",
    "chromium embedded framework",
    "metrickit",
    "watchdog",
    "stall",
    "hang",
    "release",
    "apple",
    "intel",
    "ultra",
    "other",
    "arm64",
    "x86_64",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    Ours,
    Apple,
    Other,
}

/// An image loaded in the process, as dyld reports it. The uuid is kept uppercased.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct LoadedImage {
    pub path: String,
    pub uuid: String,
    pub base: u64,
    pub size: u64,
}

impl LoadedImage {
    pub fn new(path: &str, uuid: &str, base: u64, size: u64) -> Self {
        Self { path: path.to_owned(), uuid: uuid.to_uppercase(), base, size }
    }

    pub fn contains(&self, address: u64) -> bool {
        address >= self.base && address < self.base.wrapping_add(self.size)
    }
}

/// The classifier. `system_images` are the bare image names the app found in an Apple folder
/// (it checks the disk; see [`crate::tree::bare_name`]).
#[derive(Clone, Debug, Default)]
pub struct Classifier {
    app_bundle_path: Option<String>,
    terms: Vec<String>,
    system_images: std::collections::HashSet<String>,
}

impl Classifier {
    pub fn new<I: IntoIterator<Item = String>>(
        app_bundle_path: Option<&str>,
        forbidden_terms: &[String],
        system_images: I,
    ) -> Self {
        let app_bundle_path = app_bundle_path
            .map(|path| if path.ends_with('/') { path.to_owned() } else { format!("{path}/") });
        Self {
            app_bundle_path,
            terms: normalized_terms(forbidden_terms),
            system_images: system_images.into_iter().collect(),
        }
    }

    /// A watchdog return address: named when it falls in a named image.
    pub fn frame_at(&self, image: Option<&LoadedImage>, address: u64) -> Frame {
        match image {
            Some(image) if image.contains(address) => self.frame_in(image, address - image.base),
            _ => Frame::other(),
        }
    }

    pub fn frame_in(&self, image: &LoadedImage, offset: u64) -> Frame {
        if offset > MAX_OFFSET || self.owner(&image.path) == Owner::Other {
            return Frame::other();
        }
        match self.sendable_name(&image.path) {
            Some(name) => {
                Frame { image: name, offset: Some(offset), uuid: Some(image.uuid.clone()) }
            }
            None => Frame::other(),
        }
    }

    /// A MetricKit frame: judged by its loaded image when there is one, else by its name.
    pub fn frame_metric_kit(
        &self,
        name: Option<&str>,
        uuid: Option<&str>,
        offset: Option<u64>,
        loaded: Option<&LoadedImage>,
    ) -> Frame {
        let (Some(uuid), Some(offset)) = (uuid, offset) else { return Frame::other() };
        if !is_uuid(uuid) || offset > MAX_OFFSET {
            return Frame::other();
        }
        if let Some(loaded) = loaded {
            return self.frame_in(loaded, offset);
        }
        let Some(name) = name.filter(|name| !name.is_empty()) else { return Frame::other() };
        let who = if name.contains('/') {
            self.owner(name)
        } else if is_own_name(name) {
            Owner::Ours
        } else if self.system_images.contains(name) {
            Owner::Apple
        } else {
            Owner::Other
        };
        if who == Owner::Other {
            return Frame::other();
        }
        match self.sendable_name(name) {
            Some(sent) => {
                Frame { image: sent, offset: Some(offset), uuid: Some(uuid.to_uppercase()) }
            }
            None => Frame::other(),
        }
    }

    pub fn owner(&self, path: &str) -> Owner {
        // `/usr/lib/../../Users/x/libhook.dylib` starts with an Apple folder but is not in one.
        if !is_plain_absolute_path(path) {
            return Owner::Other;
        }
        if self.app_bundle_path.as_deref().is_some_and(|bundle| path.starts_with(bundle)) {
            return Owner::Ours;
        }
        if CRYPTEX_SYSTEM_PREFIXES.iter().any(|prefix| path.starts_with(prefix)) {
            return Owner::Apple;
        }
        if NOT_APPLE_PATH_PREFIXES.iter().any(|prefix| path.starts_with(prefix)) {
            return Owner::Other;
        }
        if APPLE_PATH_PREFIXES.iter().any(|prefix| path.starts_with(prefix)) {
            return Owner::Apple;
        }
        Owner::Other
    }

    /// The path's last component when it is a plain 1-64 character name with none of the terms.
    pub fn sendable_name(&self, path: &str) -> Option<String> {
        let name = path.split('/').rfind(|part| !part.is_empty()).unwrap_or("");
        let plain = (1..=64).contains(&name.len())
            && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b" ._+()-".contains(&byte));
        if !plain {
            return None;
        }
        let lowered = name.to_ascii_lowercase();
        if self.terms.iter().any(|term| lowered.contains(term.as_str())) {
            return None;
        }
        Some(name.to_owned())
    }

    pub fn terms(&self) -> &[String] {
        &self.terms
    }
}

pub fn is_own_name(name: &str) -> bool {
    OWN_NAME_PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

/// Starts with `/` and has no empty, `.` or `..` component after it.
pub fn is_plain_absolute_path(path: &str) -> bool {
    let Some(rest) = path.strip_prefix('/') else { return false };
    !rest.split('/').any(|part| part.is_empty() || part == "." || part == "..")
}

/// The person's words, lowercased, without short ones and without ones our own names contain
/// (a user called "cmux" must not refuse every report).
pub fn normalized_terms(terms: &[String]) -> Vec<String> {
    terms
        .iter()
        .map(|term| term.to_lowercase())
        .filter(|term| {
            term.graphemes(true).count() >= MINIMUM_TERM_LENGTH
                && !OWN_WORDS.iter().any(|word| word.contains(term.as_str()))
        })
        .collect()
}

/// `8-4-4-4-12` hex digits.
pub fn is_uuid(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(group, len)| group.len() == len && group.bytes().all(|b| b.is_ascii_hexdigit()))
}
