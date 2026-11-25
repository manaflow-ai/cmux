//! The bookmark tree rules of `bookmarks-v1` (plans/cmux-next/bookmarks.md
//! sections 1 and 2.1), with no storage: the limits, the validation, the
//! op and record types, and [`Tree`], one browser profile's tree in memory
//! with the op reducer.
//!
//! The home daemon (cmux-tui-core `workspace_registry::personal_bookmarks`)
//! validates every op with these rules and writes SQLite rows in one
//! transaction; its op JSON is the replay fingerprint, so the types here
//! serialize exactly as they did there. The app is to link [`preview`]
//! through cmux-app-ffi (`cmux_layout_reducer_json` op `bookmarks_apply`,
//! one move PR with the re-pin and the Swift call): it sends
//! its confirmed tree and its pending ops and shows the tree that comes
//! back, so its optimistic view follows the daemon's rules
//! (layer-ownership.md V-11). cmux-tui-core's `bookmark_parity_tests` run
//! the same random ops through the daemon and through [`Tree`] and require
//! the same trees, results and refusals.

#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::indexing_slicing,
        clippy::string_slice
    )
)]

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize};

pub mod preview;
mod tree;

pub use tree::{Applied, Tree};

/// The Bookmarks Bar root.
pub const BOOKMARKS_BAR: &str = "bar";
/// The Other Bookmarks root.
pub const OTHER_BOOKMARKS: &str = "other";
/// The browser profile every install has.
pub const DEFAULT_BROWSER_PROFILE: &str = "default";
/// Most nodes one browser profile may hold.
pub const MAX_BOOKMARKS_PER_PROFILE: usize = 100_000;
/// Deepest node: a child of a root has depth 1.
pub const MAX_BOOKMARK_DEPTH: usize = 64;
/// Longest title, in bytes.
pub const MAX_BOOKMARK_TITLE_BYTES: usize = 4096;
/// Longest URL, in bytes.
pub const MAX_BOOKMARK_URL_BYTES: usize = 65536;
/// Longest `favicon_key` or `source_key`, in bytes.
pub const MAX_BOOKMARK_KEY_BYTES: usize = 4096;

// MARK: Errors

/// A refused bookmark op. `code` is the response envelope's `error_code`:
/// `invalid_params` or `not_found`. `reason` says which rule refused it, so
/// the app can show its own localized text; the daemon's wire does not
/// carry it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BookmarkError {
    code: &'static str,
    reason: Reason,
    message: String,
}

/// The rule that refused an op.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    /// The bookmark or browser profile is unknown.
    NotFound,
    /// The parent is not a root or a folder.
    InvalidParent,
    /// A folder would move into itself or a descendant.
    Cycle,
    InvalidUrl,
    /// A field the node's kind does not have (a folder's URL, a URL's icon).
    InvalidKind,
    /// Too many nodes, or too long a title or key.
    TooLarge,
    TooDeep,
    /// Any other refusal (a malformed id, profile, time or import).
    Invalid,
}

impl BookmarkError {
    pub const INVALID_PARAMS_CODE: &'static str = "invalid_params";
    pub const NOT_FOUND_CODE: &'static str = "not_found";

    pub fn invalid(message: impl Into<String>) -> Self {
        Self { code: Self::INVALID_PARAMS_CODE, reason: Reason::Invalid, message: message.into() }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self { code: Self::NOT_FOUND_CODE, reason: Reason::NotFound, message: message.into() }
    }

    /// The same refusal, named as `reason`.
    pub fn because(mut self, reason: Reason) -> Self {
        self.reason = reason;
        self
    }

    pub fn reason(&self) -> Reason {
        self.reason
    }

    pub fn code(&self) -> &'static str {
        self.code
    }

    /// The reason, without the "bad request: " prefix `Display` adds.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for BookmarkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.code == Self::INVALID_PARAMS_CODE {
            write!(formatter, "bad request: {}", self.message)
        } else {
            formatter.write_str(&self.message)
        }
    }
}

impl std::error::Error for BookmarkError {}

/// `ensure_valid!(Reason; condition, message...)`, or without the reason
/// for `Reason::Invalid`.
macro_rules! ensure_valid {
    ($reason:ident; $condition:expr, $($message:tt)+) => {
        if !$condition {
            let error = $crate::BookmarkError::invalid(format!($($message)+));
            return Err(error.because($crate::Reason::$reason));
        }
    };
    ($condition:expr, $($message:tt)+) => {
        if !$condition {
            return Err($crate::BookmarkError::invalid(format!($($message)+)));
        }
    };
}
pub(crate) use ensure_valid;

// MARK: Records

/// One node as `list-bookmarks` and the bookmark commands return it. Null
/// optional fields are omitted. `index` is the node's 0-based position
/// among its siblings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bookmark {
    pub id: String,
    /// A listing read back by [`Tree::from_listing`] may omit it: the tree's
    /// profile is used.
    #[serde(default)]
    pub browser_profile_id: String,
    pub parent: String,
    pub kind: String,
    /// A listing may omit it when it lists siblings in order.
    #[serde(default)]
    pub index: usize,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub favicon_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_key: Option<String>,
    pub created_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_ms: Option<u64>,
    /// Folders only (`bookmark-icon-v1`): one emoji, an SF Symbol name or a
    /// stored asset (`image:sha256-<hex>`, `svg:sha256-<hex>`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

/// Fields of `create-bookmark`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookmarkInput {
    pub id: Option<String>,
    pub browser_profile_id: String,
    pub parent: String,
    pub index: Option<usize>,
    pub kind: String,
    pub title: String,
    pub url: Option<String>,
    pub favicon_key: Option<String>,
    pub source_key: Option<String>,
    pub created_ms: Option<u64>,
}

/// Fields of `update-bookmark`: `None` unchanged, `Some(None)` clears (JSON
/// null).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookmarkUpdate {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub favicon_key: Option<Option<String>>,
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_used_ms: Option<Option<u64>>,
    /// Folders only. Skipped when absent, so the fingerprint of an update
    /// without an icon is the one it had before `bookmark-icon-v1`.
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub icon: Option<Option<String>>,
}

/// One node of `import-bookmarks`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BookmarkImportNode {
    pub kind: String,
    pub title: String,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub created_ms: Option<u64>,
    #[serde(default)]
    pub children: Option<Vec<BookmarkImportNode>>,
}

/// Fields of `import-bookmarks`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookmarkImport {
    pub browser_profile_id: String,
    pub parent: String,
    pub index: Option<usize>,
    pub source_key: Option<String>,
    #[serde(default)]
    pub replace: bool,
    pub nodes: Vec<BookmarkImportNode>,
}

/// One bookmark op. Its JSON is the fingerprint of a keyed op, so its
/// serialized shape must not change.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum BookmarkOp {
    Create(BookmarkInput),
    Update {
        bookmark: String,
        #[serde(flatten)]
        update: BookmarkUpdate,
    },
    Move {
        bookmark: String,
        parent: String,
        index: usize,
    },
    Delete {
        bookmark: String,
    },
    Import(BookmarkImport),
}

impl BookmarkOp {
    /// The command name, stored with a keyed op's replay record.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Create(_) => "create-bookmark",
            Self::Update { .. } => "update-bookmark",
            Self::Move { .. } => "move-bookmark",
            Self::Delete { .. } => "delete-bookmark",
            Self::Import(_) => "import-bookmarks",
        }
    }
}

/// An absent field is `None`; a present one, JSON null included, is `Some`.
fn present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

// MARK: Validation

/// `bm_` and 32 lowercase hex digits.
pub fn validate_bookmark_id(value: &str) -> Result<(), BookmarkError> {
    ensure_valid!(
        value.len() == 35
            && value.strip_prefix("bm_").is_some_and(|hex| hex
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))),
        "bookmark id must be \"bm_\" and 32 lowercase hex digits"
    );
    Ok(())
}

/// `default` or a lowercase UUID.
pub fn validate_profile_shape(value: &str) -> Result<(), BookmarkError> {
    let uuid = value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        });
    ensure_valid!(
        value == DEFAULT_BROWSER_PROFILE || uuid,
        "browser_profile_id must be \"default\" or a lowercase UUID"
    );
    Ok(())
}

pub fn validate_kind(kind: &str) -> Result<(), BookmarkError> {
    ensure_valid!(InvalidKind;
        kind == "url" || kind == "folder",
        "kind must be \"url\" or \"folder\""
    );
    Ok(())
}

pub fn validate_title(title: &str) -> Result<(), BookmarkError> {
    ensure_valid!(TooLarge;
        title.len() <= MAX_BOOKMARK_TITLE_BYTES,
        "title exceeds {MAX_BOOKMARK_TITLE_BYTES} bytes"
    );
    ensure_valid!(!title.contains('\0'), "title contains NUL");
    Ok(())
}

/// An absolute URL (a scheme, then anything) without control characters.
///
/// With the `url` feature (the daemon) the URL must parse with
/// `url::Url::parse`. Without it (the app, which does not link the URL
/// parser) it must start with a scheme ([`has_url_scheme`]): that accepts
/// every URL the parser accepts, so an edit the daemon would take is never
/// refused in the app; one the daemon refuses comes back as its refusal.
pub fn validate_url(url: &str) -> Result<(), BookmarkError> {
    ensure_valid!(InvalidUrl;
        url.len() <= MAX_BOOKMARK_URL_BYTES,
        "url exceeds {MAX_BOOKMARK_URL_BYTES} bytes"
    );
    ensure_valid!(InvalidUrl;
        !url.chars().any(char::is_control),
        "url contains a control character"
    );
    ensure_valid!(InvalidUrl; parses_as_absolute_url(url), "url must be an absolute URL");
    Ok(())
}

#[cfg(feature = "url")]
fn parses_as_absolute_url(url: &str) -> bool {
    url::Url::parse(url).is_ok()
}

#[cfg(not(feature = "url"))]
fn parses_as_absolute_url(url: &str) -> bool {
    has_url_scheme(url)
}

/// `scheme ":"` first (RFC 3986: a letter, then letters, digits, `+`, `-`
/// or `.`), after the leading and trailing spaces the URL parser trims.
pub fn has_url_scheme(url: &str) -> bool {
    let trimmed = url.trim_matches(' ');
    let Some((scheme, _)) = trimmed.split_once(':') else { return false };
    let mut bytes = scheme.bytes();
    bytes.next().is_some_and(|first| first.is_ascii_alphabetic())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
}

/// `url` is required for a URL and refused for a folder.
pub fn validate_kind_url(kind: &str, url: Option<&str>) -> Result<(), BookmarkError> {
    validate_kind(kind)?;
    match (kind, url) {
        ("url", Some(url)) => validate_url(url),
        ("url", None) => {
            Err(BookmarkError::invalid("a url bookmark needs a url").because(Reason::InvalidUrl))
        }
        (_, Some(_)) => {
            Err(BookmarkError::invalid("a folder has no url").because(Reason::InvalidKind))
        }
        _ => Ok(()),
    }
}

pub fn validate_key(label: &str, value: Option<&str>) -> Result<(), BookmarkError> {
    if let Some(value) = value {
        ensure_valid!(TooLarge;
            value.len() <= MAX_BOOKMARK_KEY_BYTES,
            "{label} exceeds {MAX_BOOKMARK_KEY_BYTES} bytes"
        );
        ensure_valid!(!value.chars().any(char::is_control), "{label} contains a control character");
    }
    Ok(())
}

/// A time in milliseconds as SQLite stores it.
pub fn stored_ms(label: &str, value: u64) -> Result<i64, BookmarkError> {
    i64::try_from(value).map_err(|_| BookmarkError::invalid(format!("{label} is out of range")))
}

pub fn is_root(parent: &str) -> bool {
    parent == BOOKMARKS_BAR || parent == OTHER_BOOKMARKS
}

/// Validated nodes of one import, and the tallest root's height.
pub fn validate_import_nodes(
    nodes: &[BookmarkImportNode],
) -> Result<(usize, usize), BookmarkError> {
    let mut count = 0usize;
    let mut height = 0;
    let mut stack = nodes.iter().map(|node| (node, 1usize)).collect::<Vec<_>>();
    while let Some((node, level)) = stack.pop() {
        count = count.saturating_add(1);
        ensure_valid!(TooLarge;
            count <= MAX_BOOKMARKS_PER_PROFILE,
            "a profile holds at most {MAX_BOOKMARKS_PER_PROFILE} bookmarks"
        );
        ensure_valid!(TooDeep;
            level <= MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        height = height.max(level);
        validate_kind_url(&node.kind, node.url.as_deref())?;
        validate_title(&node.title)?;
        if let Some(created_ms) = node.created_ms {
            stored_ms("created_ms", created_ms)?;
        }
        if let Some(children) = &node.children {
            ensure_valid!(InvalidKind; node.kind == "folder", "only a folder has children");
            stack.extend(children.iter().map(|child| (child, level.saturating_add(1))));
        }
    }
    Ok((count, height))
}
