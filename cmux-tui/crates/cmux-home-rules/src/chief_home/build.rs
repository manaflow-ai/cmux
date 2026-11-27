//! The slice of `BuildIdentity` (CmuxNextCompat `BuildIdentity.swift`, `BuildStatePaths.swift`) the Chief
//! home rules read: a build's kind, key and whether it isolates shared state. cmux-agent-pane-policy
//! `build_identity.rs` holds the whole Rust mirror; this crate keeps its two dependencies, so the few rules
//! it needs are here (both follow `schemas/build-identity/vectors.json`).

/// The bundle id prefixes, longest first, and the kind each one names.
const KINDS: [(&str, Kind); 5] = [
    ("com.cmuxterm.app.nightly", Kind::Nightly),
    ("com.cmuxterm.app.staging", Kind::Staging),
    ("com.cmuxterm.app.debug", Kind::Dev),
    ("com.cmuxterm.app.rc", Kind::Rc),
    ("com.cmuxterm.app", Kind::Release),
];

/// The kind of build a bundle id names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Nightly,
    Release,
    Rc,
    Dev,
    Staging,
    Unbundled,
}

/// One build: its bundle id, kind and the key of its state roots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Identity {
    pub bundle_id: Option<String>,
    pub kind: Kind,
    pub key: String,
}

impl Identity {
    /// `BuildIdentity(bundleID:bundledTag:)`.
    pub fn new(bundle_id: Option<&str>, bundled_tag: Option<&str>) -> Self {
        let Some(bundle_id) = bundle_id.map(str::trim).filter(|id| !id.is_empty()) else {
            return Self { bundle_id: None, kind: Kind::Unbundled, key: "unbundled".into() };
        };
        let (kind, suffix) = KINDS
            .iter()
            .find_map(|(prefix, kind)| {
                if bundle_id == *prefix {
                    Some((*kind, None))
                } else {
                    bundle_id
                        .strip_prefix(prefix)?
                        .strip_prefix('.')
                        .map(|rest| (*kind, Some(rest)))
                }
            })
            .map(|(kind, suffix)| {
                if kind == Kind::Release && suffix.is_some() {
                    (Kind::Dev, suffix)
                } else {
                    (kind, suffix)
                }
            })
            .unwrap_or((Kind::Dev, None));
        let suffix_tag = suffix.and_then(tag_slug);
        let shipped = bundled_tag.and_then(tag_slug);
        let hash = || format!("{:08x}", fnv1a32(bundle_id.as_bytes()));
        let mut key = match key_component(bundle_id) {
            Some(name) if name == bundle_id => name,
            Some(name) => format!("{name}--{}", hash()),
            None => format!("unbundled--{}", hash()),
        };
        if let Some(shipped) = shipped.as_deref().filter(|s| suffix_tag.as_deref() != Some(*s)) {
            key = format!("{key}--{shipped}");
        }
        Self { bundle_id: Some(bundle_id.to_owned()), kind, key }
    }

    /// `needsBuildSpace`: a DEV build (`com.cmuxterm.app.debug[.x]`) or a tagged staging build.
    pub fn needs_build_space(&self) -> bool {
        let Some(id) = self.bundle_id.as_deref() else { return false };
        let within = |prefix: &str, bare: bool| {
            if id == prefix {
                return bare;
            }
            id.strip_prefix(prefix).is_some_and(|rest| rest.starts_with('.'))
        };
        within("com.cmuxterm.app.debug", true) || within("com.cmuxterm.app.staging", false)
    }

    /// `isolatesSharedState`.
    pub fn isolates_shared_state(&self) -> bool {
        self.kind == Kind::Dev || self.needs_build_space()
    }

    /// `stateFolderName(for:)`.
    pub fn state_folder_name(&self, bundle_id: Option<&str>) -> Option<String> {
        let bundle_id = bundle_id.filter(|id| !id.is_empty())?;
        if !self.isolates_shared_state() || self.bundle_id.as_deref() != Some(bundle_id) {
            return Some(bundle_id.to_owned());
        }
        Some(self.key.clone())
    }
}

/// FNV-1a 32.
pub(crate) fn fnv1a32(bytes: &[u8]) -> u32 {
    bytes
        .iter()
        .fold(0x811c_9dc5_u32, |hash, byte| (hash ^ u32::from(*byte)).wrapping_mul(0x0100_0193))
}

/// FNV-1a 64.
pub(crate) fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// `BuildIdentity.tagSlug(of:)`: lowercase, runs outside `[a-z0-9]` become one `-`, trimmed of `-`.
pub(crate) fn tag_slug(raw: &str) -> Option<String> {
    let mut slug = String::new();
    for c in raw.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            slug.push(c);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let trimmed = slug.trim_matches('-');
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// `BuildIdentity.component(of:)` and `ChiefHome.component(of:)`: runs outside `[A-Za-z0-9._]` become one
/// `-`, trimmed of `-` and `.`; None when nothing is left.
pub(crate) fn key_component(raw: &str) -> Option<String> {
    let mut out = String::new();
    for c in raw.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches(|c| c == '-' || c == '.');
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}
