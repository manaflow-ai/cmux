//! Which cmux build a process belongs to, and the state roots it owns
//! (per-build isolation, cx-is1kf).
//!
//! Lawrence, 2026-10-14: "each dev app chiefs/imessage stuff is isolated".
//! One build never reads, starts, stops or adopts another build's state, so
//! every root that holds state is derived from one key here: the bundle id,
//! plus the tag the bundle ships (`LSEnvironment` `CMUX_TAG`) when the
//! bundle id does not end in it. The tag comes from the bundle only, never
//! from an inherited environment, so a terminal of one build cannot make a
//! child resolve another build's roots.
//!
//! NIGHTLY (`com.cmuxterm.app.nightly`, Lawrence's daily build) keeps the
//! roots every build shared before (`~/.cmux/chief/<account>`, `~/.acpmux`,
//! App Support `cmux/`) and adopts them in place. Every other build (DEV,
//! staging, cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`, RC, release)
//! gets roots of its own under its key.
//!
//! It lives in this crate because every acpmux host and client (acpmux,
//! the cmux CLI) already depends on it (it can move to its own crate
//! later, with the chief's Cargo LOCK turn); the Swift mirror is `BuildIdentity`
//! (CmuxNextCompat). Both follow
//! `schemas/build-identity/vectors.json`. Design:
//! hq `.cmux-scratch/hq6d-per-build-isolation/DESIGN.md`.

use std::path::{Path, PathBuf};

/// The one bundle that keeps the shared roots of older builds.
pub const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";
/// The key of a process outside any app bundle.
pub const UNBUNDLED_KEY: &str = "unbundled";

/// The bundle id prefixes, longest first, and the kind each one names.
const KINDS: [(&str, BuildKind); 5] = [
    ("com.cmuxterm.app.nightly", BuildKind::Nightly),
    ("com.cmuxterm.app.staging", BuildKind::Staging),
    ("com.cmuxterm.app.debug", BuildKind::Dev),
    ("com.cmuxterm.app.rc", BuildKind::Rc),
    ("com.cmuxterm.app", BuildKind::Release),
];

/// The kind of build a bundle id names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BuildKind {
    /// `com.cmuxterm.app.nightly` and `com.cmuxterm.app.nightly.<suffix>`
    /// (cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`).
    Nightly,
    /// `com.cmuxterm.app`.
    Release,
    /// `com.cmuxterm.app.rc[.<suffix>]`.
    Rc,
    /// `com.cmuxterm.app.debug[.<tag>]`, and any other `com.cmuxterm.app.*`
    /// bundle (an unknown bundle is isolated like a DEV build).
    Dev,
    /// `com.cmuxterm.app.staging[.<tag>]`.
    Staging,
    /// No bundle id: a standalone CLI or daemon.
    Unbundled,
}

impl BuildKind {
    /// The name in `schemas/build-identity/vectors.json`.
    pub fn name(self) -> &'static str {
        match self {
            Self::Nightly => "nightly",
            Self::Release => "release",
            Self::Rc => "rc",
            Self::Dev => "dev",
            Self::Staging => "staging",
            Self::Unbundled => "unbundled",
        }
    }
}

/// One build: its bundle id, its tag and the key of its state roots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildIdentity {
    bundle_id: Option<String>,
    tag: Option<String>,
    kind: BuildKind,
    key: String,
    /// The app names this build keeps from before per-build isolation
    /// ([`Self::app_session`]); `None`: names of its key.
    kept: Option<KeptNames>,
}

/// The app daemon session tag (`cmux-app[-<tag>]`) and control socket name
/// (`/tmp/cmux-<name>.sock`; `None`: release's `~/.local/state/cmux/cmux.sock`)
/// of a build that keeps the names it had before per-build isolation.
#[derive(Clone, Debug, PartialEq, Eq)]
struct KeptNames {
    session_tag: Option<String>,
    socket: Option<String>,
}

/// The untagged channel builds and the channel name in their app names.
const CHANNELS: [(&str, &str); 3] = [
    ("com.cmuxterm.app.nightly", "nightly"),
    ("com.cmuxterm.app.rc", "rc"),
    ("com.cmuxterm.app.staging", "staging"),
];
/// cmux NEXT, shipped (`nightly-next`): it keeps its names, so its installs
/// keep their daemon state.
const CMUX_NEXT_BUNDLE_ID: &str = "com.cmuxterm.app.nightly.cmux-next";
/// DEV tags whose names a shipped build owns (`cmux-app-nightly`, …): a DEV
/// build with one of them gets names of its key.
const OWNED_TAGS: [&str; 4] = ["nightly", "rc", "staging", "cmux-next"];

impl KeptNames {
    /// The names `bundle_id` (suffix `suffix` after its kind's prefix, shipped
    /// tag `shipped`) keeps: the ones that belong to exactly one build, so no
    /// state moves. Release, the untagged channels, cmux NEXT, a
    /// `scripts/reload.sh` DEV build `com.cmuxterm.app.debug.<a.b>` whose
    /// suffix is its tag, and the plain DEV bundle with a tag. A bundle that
    /// ships another tag than its id keeps nothing; neither does a DEV tag a
    /// shipped build owns, nor the untagged DEV build.
    fn of(bundle_id: &str, suffix: Option<&str>, shipped: Option<&str>) -> Option<Self> {
        // The plain DEV bundle with a tag (shipped, or from its `cmux DEV
        // <tag>.app` name) keeps that tag's names, as before; untagged: none.
        if bundle_id == "com.cmuxterm.app.debug" {
            let tag = shipped.filter(|tag| !OWNED_TAGS.contains(tag))?;
            return Some(Self {
                session_tag: Some(tag.to_owned()),
                socket: Some(format!("debug-{tag}")),
            });
        }
        let suffix_tag = suffix.and_then(tag_slug);
        if shipped.is_some() && shipped != suffix_tag.as_deref() {
            return None;
        }
        let names = |tag: Option<&str>, socket: Option<String>| {
            Some(Self { session_tag: tag.map(str::to_owned), socket })
        };
        if bundle_id == "com.cmuxterm.app" {
            return names(None, None);
        }
        if let Some((_, channel)) = CHANNELS.iter().find(|(id, _)| *id == bundle_id) {
            return names(Some(*channel), Some((*channel).to_owned()));
        }
        if bundle_id == CMUX_NEXT_BUNDLE_ID {
            return names(Some("cmux-next"), Some("nightly-cmux-next".into()));
        }
        let suffix = bundle_id.strip_prefix("com.cmuxterm.app.debug.")?;
        let reload_form = suffix.split('.').all(|segment| {
            !segment.is_empty()
                && segment.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        });
        let tag = suffix_tag?;
        if !reload_form || OWNED_TAGS.contains(&tag.as_str()) {
            return None;
        }
        names(Some(&tag), Some(format!("debug-{tag}")))
    }
}

impl BuildIdentity {
    /// The build of `bundle_id` (`CFBundleIdentifier`) with the tag its
    /// bundle ships (`LSEnvironment` `CMUX_TAG`), if any. A bundle id with a
    /// suffix after its kind's prefix (`com.cmuxterm.app.debug.<tag>`) has
    /// that suffix as its tag. Blank values count as absent.
    pub fn new(bundle_id: Option<&str>, bundled_tag: Option<&str>) -> Self {
        let bundle_id = bundle_id.map(str::trim).filter(|id| !id.is_empty());
        let Some(bundle_id) = bundle_id else {
            return Self {
                bundle_id: None,
                tag: None,
                kind: BuildKind::Unbundled,
                key: UNBUNDLED_KEY.into(),
                kept: None,
            };
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
                // `com.cmuxterm.app.<other>` is no known kind: isolated as DEV.
                if kind == BuildKind::Release && suffix.is_some() {
                    (BuildKind::Dev, suffix)
                } else {
                    (kind, suffix)
                }
            })
            .unwrap_or((BuildKind::Dev, None));
        let suffix_tag = suffix.and_then(tag_slug);
        let shipped = bundled_tag.and_then(tag_slug);
        let tag = shipped.clone().or_else(|| suffix_tag.clone());
        let hash = || format!("{:08x}", fnv1a32(bundle_id.as_bytes()));
        // A bundle id that is not already a path component (an empty
        // suffix, other characters) gets a hash of the exact id, so two
        // such ids never share roots.
        let mut key = match component(bundle_id) {
            Some(name) if name == bundle_id => name,
            Some(name) => format!("{name}--{}", hash()),
            None => format!("{UNBUNDLED_KEY}--{}", hash()),
        };
        // A shipped tag the id does not end in (two builds of one bundle id
        // with different tags) keeps the builds apart.
        if let Some(shipped) = shipped.as_deref().filter(|s| suffix_tag.as_deref() != Some(*s)) {
            key = format!("{key}--{shipped}");
        }
        let kept = KeptNames::of(bundle_id, suffix, shipped.as_deref());
        Self { bundle_id: Some(bundle_id.to_owned()), tag, kind, key, kept }
    }

    pub fn bundle_id(&self) -> Option<&str> {
        self.bundle_id.as_deref()
    }

    /// The sanitized tag (`[a-z0-9-]`): the one the bundle ships, else the
    /// bundle id's suffix.
    pub fn tag(&self) -> Option<&str> {
        self.tag.as_deref()
    }

    pub fn kind(&self) -> BuildKind {
        self.kind
    }

    /// The path component of this build's roots: the bundle id (plus
    /// `--<fnv1a32 of the id>` when the id is not already a path component
    /// of `[A-Za-z0-9._-]`), plus `--<tag>` when the bundle ships a tag its
    /// id does not end in; `unbundled` outside any bundle.
    pub fn key(&self) -> &str {
        &self.key
    }

    /// FNV-1a 32 of the key, 8 hex digits: for names that must stay short
    /// (socket paths, session names).
    pub fn key_hash(&self) -> String {
        format!("{:08x}", fnv1a32(self.key.as_bytes()))
    }

    /// Whether this build keeps the shared roots of older builds in place:
    /// NIGHTLY (`com.cmuxterm.app.nightly`) only.
    pub fn keeps_shared_roots(&self) -> bool {
        self.bundle_id.as_deref() == Some(NIGHTLY_BUNDLE_ID)
    }

    /// The Chief home: `~/.cmux/chief/<account>` for NIGHTLY and outside
    /// any bundle, else `~/.cmux/chief/<key>[@<account>]` (`account` other
    /// than `default`; `@` never appears in a key, so no account of one
    /// build names another build's home). CmuxNext `ChiefHome` and cmux-tui
    /// `cli/chief/home.rs` move to this rule when they adopt this type; today
    /// they write `<bundle id>.<account>`.
    pub fn chief_home(&self, user_home: &Path, account: &str) -> PathBuf {
        let base = user_home.join(".cmux/chief");
        let account = component(account).unwrap_or_else(|| "default".into());
        if self.keeps_shared_roots() || self.kind == BuildKind::Unbundled {
            base.join(account)
        } else if account == "default" {
            base.join(&self.key)
        } else {
            base.join(format!("{}@{account}", self.key))
        }
    }

    /// Where an untagged NIGHTLY, RC or staging app records that it adopted
    /// the old shared `cmux-app` daemon session (CmuxNext
    /// `LegacyChannelSession.marker`: beside its daemon state directory
    /// `Application Support/cmux/tags/<channel>/tui`). `None` for every other
    /// build, which never adopts it.
    pub fn legacy_session_marker(&self, user_home: &Path) -> Option<PathBuf> {
        let tag = match &self.kept {
            Some(KeptNames { session_tag: Some(tag), .. }) => tag,
            _ => return None,
        };
        if !["nightly", "rc", "staging"].contains(&tag.as_str())
            || self.bundle_id() != Some(&format!("com.cmuxterm.app.{tag}"))
        {
            return None;
        }
        Some(
            user_home
                .join("Library")
                .join("Application Support")
                .join("cmux")
                .join("tags")
                .join(tag)
                .join("legacy-session-adopted"),
        )
    }

    /// The acpmux home (`ACPMUX_HOME`): `~/.acpmux` for NIGHTLY and a
    /// standalone acpmux, else `~/.acpmux/builds/<key>`.
    pub fn acpmux_home(&self, user_home: &Path) -> PathBuf {
        let base = user_home.join(".acpmux");
        if self.keeps_shared_roots() || self.kind == BuildKind::Unbundled {
            base
        } else {
            base.join("builds").join(&self.key)
        }
    }

    /// The session of this build's app daemon: the name it had before
    /// per-build isolation where that name belongs to exactly one build
    /// (`cmux-app` for release, `cmux-app-<channel>`, `cmux-app-cmux-next`,
    /// `cmux-app-<tag>` for a `scripts/reload.sh` DEV build), else
    /// `cmux-app--<key hash>` (`--` never occurs in a tag). `None` outside
    /// any bundle.
    pub fn app_session(&self) -> Option<String> {
        if self.kind == BuildKind::Unbundled {
            return None;
        }
        Some(match &self.kept {
            Some(KeptNames { session_tag: None, .. }) => "cmux-app".into(),
            Some(KeptNames { session_tag: Some(tag), .. }) => format!("cmux-app-{tag}"),
            None => format!("cmux-app--{}", self.key_hash()),
        })
    }

    /// The control socket of this build's app (CmuxNext `ControlSocketPath`):
    /// the path it had before per-build isolation where that path belongs to
    /// exactly one build (`/tmp/cmux-<channel>.sock`,
    /// `/tmp/cmux-nightly-cmux-next.sock`, `/tmp/cmux-debug-<tag>.sock`,
    /// release's `~/.local/state/cmux/cmux.sock`), else
    /// `/tmp/cmux-<kind>--<key hash>.sock` (`debug` for DEV). `None` outside
    /// any bundle.
    pub fn control_socket(&self, user_home: &Path) -> Option<PathBuf> {
        let word = match self.kind {
            BuildKind::Unbundled => return None,
            BuildKind::Dev => "debug",
            kind => kind.name(),
        };
        Some(match &self.kept {
            Some(KeptNames { socket: None, .. }) => user_home.join(".local/state/cmux/cmux.sock"),
            Some(KeptNames { socket: Some(name), .. }) => {
                PathBuf::from(format!("/tmp/cmux-{name}.sock"))
            }
            None => PathBuf::from(format!("/tmp/cmux-{word}--{}.sock", self.key_hash())),
        })
    }

    /// This build's directory under `~/Library/Application Support/cmux`
    /// (`app_support` is that `cmux` directory): the directory itself for
    /// NIGHTLY and outside any bundle, else `builds/<key>` below it.
    pub fn app_support(&self, app_support: &Path) -> PathBuf {
        if self.keeps_shared_roots() || self.kind == BuildKind::Unbundled {
            app_support.to_path_buf()
        } else {
            app_support.join("builds").join(&self.key)
        }
    }
}

/// `ChiefHome.component`: runs outside `[A-Za-z0-9._]` become one `-`; no
/// leading or trailing `-` or `.`; nil when nothing is left.
pub fn component(raw: &str) -> Option<String> {
    let mut out = String::with_capacity(raw.len());
    for character in raw.chars() {
        if character.is_ascii_alphanumeric() || character == '.' || character == '_' {
            out.push(character);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches(|c| c == '-' || c == '.');
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// A tag as the app sanitizes it (`ControlSocketPath.sanitize`): lowercase,
/// runs outside `[a-z0-9]` become one `-`, no leading or trailing `-`.
pub fn tag_slug(raw: &str) -> Option<String> {
    let mut slug = String::with_capacity(raw.len());
    for character in raw.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    (!slug.is_empty()).then(|| slug.to_owned())
}

fn fnv1a32(bytes: &[u8]) -> u32 {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in bytes {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    hash
}
