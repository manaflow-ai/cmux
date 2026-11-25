//! Browser profiles: which profile a tab gets, the profile records and their book (naming,
//! ordering, validation, deletion tombstones), a profile's proxy as the engines take it, the
//! deleted profiles' cleanup claims and the off-the-record (incognito) profiles' lifetime.
//!
//! Ported 1:1 from the app's Swift: `BrowserProfileCascade`, `BrowserProfileProxy`,
//! `BrowserProfileRecord`, `BrowserProfileBookError`, `BrowserProfileStorageCleanup`
//! (`CmuxNextBrowserCore/Core/Profiles/`), `OffTheRecordProfiles`
//! (`CmuxNextBrowserCore/Core/OffTheRecordProfiles.swift`), `BrowserProfileBook` and
//! `BrowserProfileCleanupClaims` (`CmuxNextBrowser/Core/Profiles/`). The wire shapes are the ones
//! Swift's `Codable` gives those types.
//!
//! Left in Swift: making a new id (`UUID()`), the localized default name, reading and writing the
//! book file, removing Chromium directories from disk, building WebKit's `ProxyConfiguration`, the
//! off-the-record end observers, and the async import migration loop. Each is I/O, an Apple
//! framework value or a closure the app runs; the app passes their facts to these rules.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;

/// The built-in profile's wire id (`BrowserProfileRecord.defaultID`). Its store is
/// [`BrowserProfileId::default_profile`].
pub const DEFAULT_ID: &str = "default";

/// The built-in profile's engine UUID (`BrowserProfileID.default`). It has its own fixed UUID so
/// that its storage is a normal identified store, never the engine's shared default store.
pub const DEFAULT_ENGINE_UUID: &str = "8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11";

/// The 9 group color names (`GroupColor`), the colors a profile may have.
pub const GROUP_COLORS: [&str; 9] =
    ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];

/// The number of grapheme clusters in `text`, as Swift's `String.count` counts them.
fn grapheme_count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// The canonical (uppercase) form of a UUID string, or nil when `text` is not one
/// (`UUID(uuidString:)`: 36 characters, dashes at 8, 13, 18 and 23, hex digits elsewhere, any case).
pub fn parse_uuid(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    for (index, byte) in bytes.iter().enumerate() {
        let ok = match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        };
        if !ok {
            return None;
        }
    }
    Some(text.to_ascii_uppercase())
}

/// Identity of a browser profile in the engines (`BrowserProfileID`): a UUID, written as Swift's
/// `UUID.uuidString` writes it (uppercase). Each engine derives its storage from it.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BrowserProfileId(String);

impl BrowserProfileId {
    /// The profile of a UUID string in any case; nil when it is not a UUID.
    pub fn parse(text: &str) -> Option<Self> {
        parse_uuid(text).map(Self)
    }

    /// The built-in profile (`BrowserProfileID.default`).
    pub fn default_profile() -> Self {
        Self(DEFAULT_ENGINE_UUID.to_owned())
    }

    /// The UUID, uppercase (`rawValue.uuidString`).
    pub fn uuid_string(&self) -> &str {
        &self.0
    }
}

impl Serialize for BrowserProfileId {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for BrowserProfileId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text).ok_or_else(|| serde::de::Error::custom("not a UUID"))
    }
}

// MARK: - Cascade

/// Why a tab has its profile, as far as today's defaults say (the profile menu's header line). A
/// tab keeps the profile it was made with, so this reads the tab's profile against the defaults now
/// (`BrowserProfileCascade.Source`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CascadeSource {
    /// The workspace's browser profile.
    Workspace,
    /// The space's browser profile.
    Space,
    /// The built-in default, with no default naming another.
    BuiltIn,
    /// None of the defaults: chosen for this tab (or a default changed after the tab was made).
    Tab,
}

/// Which browser profile a new tab gets (plans/cmux-next/data-model.md section 5;
/// `BrowserProfileCascade.resolve`). The result is stored on the tab at creation and never follows
/// a later default change, so a live page never changes cookie jar.
///
/// The first known id of: an explicit choice, the workspace's browser profile, its room's; else
/// `default`. There is no window level: a window's browser profile is its room's.
pub fn resolve(
    explicit: Option<&str>,
    workspace: Option<&str>,
    room: Option<&str>,
    known: impl Fn(&str) -> bool,
) -> String {
    for candidate in [explicit, workspace, room].into_iter().flatten() {
        if !candidate.is_empty() && known(candidate) {
            return candidate.to_owned();
        }
    }
    DEFAULT_ID.to_owned()
}

/// The source of `tab_profile` (nil = `default`; `BrowserProfileCascade.source`): the workspace's
/// default when it names it, else the space's when no workspace default stands before it, else the
/// built-in default, else the tab.
pub fn source(
    tab_profile: Option<&str>,
    workspace: Option<&str>,
    room: Option<&str>,
    known: impl Fn(&str) -> bool,
) -> CascadeSource {
    let id = tab_profile.unwrap_or(DEFAULT_ID);
    let usable = |candidate: &&str| !candidate.is_empty() && known(candidate);
    if let Some(workspace) = workspace.filter(usable) {
        return if workspace == id { CascadeSource::Workspace } else { CascadeSource::Tab };
    }
    if let Some(room) = room.filter(usable) {
        return if room == id { CascadeSource::Space } else { CascadeSource::Tab };
    }
    if id == DEFAULT_ID { CascadeSource::BuiltIn } else { CascadeSource::Tab }
}

/// A tab shows a profile dot when its profile differs from the one new tabs of its workspace get
/// (a record without an id is `default`; `BrowserProfileCascade.showsTabBadge`).
pub fn shows_tab_badge(tab_profile: Option<&str>, workspace_effective: &str) -> bool {
    tab_profile.unwrap_or(DEFAULT_ID) != workspace_effective
}

// MARK: - Proxy

/// How the engines talk to the proxy (`BrowserProfileProxy.Scheme`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProxyScheme {
    /// An HTTP proxy (CONNECT for HTTPS pages).
    Http,
    /// An HTTP proxy reached over TLS.
    Https,
    /// A SOCKS5 proxy; host names resolve at the proxy.
    Socks5,
}

impl ProxyScheme {
    /// The wire name (`rawValue`).
    pub fn raw_value(self) -> &'static str {
        match self {
            ProxyScheme::Http => "http",
            ProxyScheme::Https => "https",
            ProxyScheme::Socks5 => "socks5",
        }
    }
}

/// A browser profile's own proxy (#24432; `BrowserProfileProxy`): every page of the profile, in
/// either engine, exits through it; a profile without one stays direct.
///
/// The record holds no secret. An upstream that needs credentials goes behind a local relay
/// (`127.0.0.1:PORT`) the profile points at, so no password reaches cmux's records, exports, CLI
/// output or logs.
///
/// Both engines fail closed: Chromium gets one fixed server and no direct fallback, WebKit one
/// proxy configuration on the profile's data store, so a dead proxy shows a proxy error instead of
/// loading over the direct path.
///
/// ```
/// use cmux_browser_rules::profiles::{ProfileProxy, ProxyScheme};
/// let proxy = ProfileProxy::new(ProxyScheme::Socks5, "127.0.0.1", 1080, vec![]);
/// assert_eq!(proxy.chromium_server(), "socks5://127.0.0.1:1080");
/// ```
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProfileProxy {
    /// How the engines talk to the proxy.
    pub scheme: ProxyScheme,
    /// The proxy's host name or IP address (no brackets for IPv6).
    pub host: String,
    /// The proxy's port, 1-65535.
    pub port: i64,
    /// Hosts that skip the proxy (Chromium bypass rules, e.g. `*.corp.test`); empty: none.
    pub bypass: Vec<String>,
}

impl ProfileProxy {
    /// A proxy of `scheme` at `host:port`, skipped for `bypass` hosts.
    pub fn new(scheme: ProxyScheme, host: &str, port: i64, bypass: Vec<String>) -> Self {
        Self { scheme, host: host.to_owned(), port, bypass }
    }

    /// The host as a URL authority writes it: an IPv6 address in brackets.
    pub fn authority_host(&self) -> String {
        if self.host.contains(':') { format!("[{}]", self.host) } else { self.host.clone() }
    }

    /// Chromium's `proxy.server` preference value: `scheme://host:port`.
    pub fn chromium_server(&self) -> String {
        format!("{}://{}:{}", self.scheme.raw_value(), self.authority_host(), self.port)
    }

    /// Chromium's `proxy.bypass_list` preference value: the bypass rules, `;`-separated.
    pub fn chromium_bypass_list(&self) -> String {
        self.bypass.join(";")
    }

    /// The port WebKit's proxy configuration gets, nil when it is out of range (then the proxy has
    /// no WebKit configuration; `webKitConfiguration`).
    pub fn webkit_port(&self) -> Option<u16> {
        if (1..=65535).contains(&self.port) { u16::try_from(self.port).ok() } else { None }
    }

    /// WebKit's `excludedDomains`: the bypass rules with a leading `*.` dropped; nil when there
    /// are none (the configuration keeps its default).
    pub fn webkit_excluded_domains(&self) -> Option<Vec<String>> {
        if self.bypass.is_empty() {
            return None;
        }
        Some(
            self.bypass
                .iter()
                .map(|rule| rule.strip_prefix("*.").unwrap_or(rule).to_owned())
                .collect(),
        )
    }
}

// MARK: - Record

/// One browser profile (plans/cmux-next/data-model.md section 5; `BrowserProfileRecord`): a name,
/// an optional color and icon, and its own storage in every engine. The wire id is `default` or a
/// lowercase UUID; engines key their stores by the matching [`BrowserProfileId`] (WebKit
/// `WKWebsiteDataStore(forIdentifier:)`, Chromium `Profile-<UUID>`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileRecord {
    pub id: String,
    pub name: String,
    /// One of the 9 group color names ([`GROUP_COLORS`]), or nil.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// An SF Symbol name or one emoji, or nil (the name's first letter shows).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub position: i64,
    /// Where an imported profile came from (`browser`, `profile_dir`, `display_name`); nil for a
    /// profile made in cmux.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<BTreeMap<String, String>>,
    /// The profile's own proxy (#24432), nil when direct.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<ProfileProxy>,
}

impl ProfileRecord {
    /// A record with no color, icon, source or proxy.
    pub fn new(id: &str, name: &str, position: i64) -> Self {
        Self {
            id: id.to_owned(),
            name: name.to_owned(),
            color: None,
            icon: None,
            position,
            source: None,
            proxy: None,
        }
    }

    /// True for the built-in profile.
    pub fn is_default(&self) -> bool {
        self.id == DEFAULT_ID
    }

    /// The engine store of this profile.
    pub fn engine_profile(&self) -> BrowserProfileId {
        engine_profile(Some(&self.id)).unwrap_or_else(BrowserProfileId::default_profile)
    }

    /// What a badge shows: the icon, else the name's first letter.
    pub fn monogram(&self) -> String {
        if let Some(icon) = self.icon.as_deref().filter(|icon| !icon.is_empty()) {
            return icon.to_owned();
        }
        self.name.graphemes(true).next().map(str::to_uppercase).unwrap_or_else(|| "?".to_owned())
    }
}

/// `default` -> [`BrowserProfileId::default_profile`]; a lowercase UUID -> that UUID; anything
/// else (nil, uppercase, a room id) -> nil (`BrowserProfileRecord.engineProfile(for:)`).
pub fn engine_profile(wire_id: Option<&str>) -> Option<BrowserProfileId> {
    let wire_id = wire_id?;
    if wire_id == DEFAULT_ID {
        return Some(BrowserProfileId::default_profile());
    }
    if !is_valid_id(wire_id) {
        return None;
    }
    BrowserProfileId::parse(wire_id)
}

/// The wire id of an engine profile (`BrowserProfileRecord.wireID(for:)`).
pub fn wire_id(profile: &BrowserProfileId) -> String {
    if *profile == BrowserProfileId::default_profile() {
        DEFAULT_ID.to_owned()
    } else {
        profile.uuid_string().to_lowercase()
    }
}

/// `default` or a lowercase UUID (the daemon's `validate_browser_profile_ref`;
/// `BrowserProfileRecord.isValidID`).
pub fn is_valid_id(id: &str) -> bool {
    if id == DEFAULT_ID {
        return true;
    }
    if grapheme_count(id) != 36 || parse_uuid(id).is_none() {
        return false;
    }
    id == id.to_lowercase()
}

/// Why a browser profile edit was refused (`BrowserProfileBookError`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProfileBookError {
    UnknownProfile,
    /// The default profile cannot be deleted.
    DefaultProfile,
    InvalidName,
    #[serde(rename = "invalidID")]
    InvalidId,
    /// Engine files for this identifier are still being removed.
    PendingCleanup,
    InvalidColor,
    InvalidIcon,
}

// MARK: - Validation

/// Swift's `CharacterSet.whitespaces`: the space separators (Zs) and tab.
fn is_swift_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Swift's `CharacterSet.whitespacesAndNewlines`: [`is_swift_whitespace`], U+000A-U+000D, U+0085
/// and the line and paragraph separators.
fn is_swift_whitespace_or_newline(c: char) -> bool {
    is_swift_whitespace(c) || matches!(c, '\n'..='\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// A profile name: trimmed, 1 to 64 characters (`BrowserProfileBook.validName`).
pub fn valid_name(name: &str) -> Result<String, ProfileBookError> {
    let trimmed = name.trim_matches(is_swift_whitespace_or_newline);
    if trimmed.is_empty() || grapheme_count(trimmed) > 64 {
        return Err(ProfileBookError::InvalidName);
    }
    Ok(trimmed.to_owned())
}

/// A profile color: nil or empty is none, else one of the group color names
/// (`BrowserProfileBook.validColor`).
pub fn valid_color(color: Option<&str>) -> Result<Option<String>, ProfileBookError> {
    let Some(color) = color.filter(|color| !color.is_empty()) else { return Ok(None) };
    if !GROUP_COLORS.contains(&color) {
        return Err(ProfileBookError::InvalidColor);
    }
    Ok(Some(color.to_owned()))
}

/// `sha256-<64 lowercase hex>` (`IconValue.isAssetID`).
fn is_asset_id(text: &str) -> bool {
    text.strip_prefix("sha256-").is_some_and(|digest| {
        digest.len() == 64
            && digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// A stored image or SVG icon (`image:`/`svg:` asset ref; `IconValue(wire:)`'s `.image`, `.svg`).
fn is_asset_icon(icon: &str) -> bool {
    ["image:", "svg:"].iter().any(|prefix| icon.strip_prefix(prefix).is_some_and(is_asset_id))
}

/// An SF Symbol name (ASCII letters, digits, dots), one grapheme (an emoji) or a stored image or
/// SVG (`image:`/`svg:` asset ref; `BrowserProfileBook.validIcon`).
pub fn valid_icon(icon: Option<&str>) -> Result<Option<String>, ProfileBookError> {
    let Some(icon) = icon.map(|icon| icon.trim_matches(is_swift_whitespace)) else {
        return Ok(None);
    };
    if icon.is_empty() {
        return Ok(None);
    }
    if is_asset_icon(icon) {
        return Ok(Some(icon.to_owned()));
    }
    let count = grapheme_count(icon);
    let symbol = count <= 64 && icon.chars().all(|c| c.is_ascii_alphanumeric() || c == '.');
    if !(symbol || count == 1) {
        return Err(ProfileBookError::InvalidIcon);
    }
    Ok(Some(icon.to_owned()))
}

// MARK: - Book

/// Every browser profile of this app install plus the per-workspace defaults the home daemon
/// cannot hold yet (plans/cmux-next/data-model.md section 5; `BrowserProfileBook`). A value: the
/// app keeps one, edits it on the main actor and saves it. The default profile always exists.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ProfileBook {
    profiles: Vec<ProfileRecord>,
    /// Browser profile of a qualified workspace (`<session>|<key>`) when the home daemon lacks
    /// `profiles-v1`; with it, the daemon's `personal_workspaces.browser_profile_id` is used
    /// instead.
    #[serde(rename = "workspace_defaults")]
    pub workspace_defaults: BTreeMap<String, String>,
    /// Deleted profiles whose engine data is not removed yet (Chromium keeps a loaded profile's
    /// files open until the next launch).
    #[serde(rename = "pending_cleanup")]
    pending_cleanup: Vec<String>,
    /// True once imports made before profiles existed moved into their own profiles
    /// (`ImportedDataStore.retarget`).
    #[serde(rename = "imports_migrated")]
    pub imports_migrated: bool,
    /// True once this file's records were copied into the home daemon (`browser-profiles-v1`);
    /// the daemon's records are used from then on.
    #[serde(rename = "records_migrated")]
    pub records_migrated: bool,
}

/// The book file as stored, every key optional (an older file).
#[derive(Deserialize)]
struct StoredBook {
    #[serde(default)]
    profiles: Option<Vec<ProfileRecord>>,
    #[serde(default)]
    workspace_defaults: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pending_cleanup: Option<Vec<String>>,
    #[serde(default)]
    imports_migrated: Option<bool>,
    #[serde(default)]
    records_migrated: Option<bool>,
}

impl ProfileBook {
    /// A book of only the default profile, named `default_name` (the app's localized "Default").
    pub fn new(default_name: &str) -> Self {
        Self {
            profiles: vec![ProfileRecord::new(DEFAULT_ID, default_name, 0)],
            workspace_defaults: BTreeMap::new(),
            pending_cleanup: Vec::new(),
            imports_migrated: false,
            records_migrated: false,
        }
    }

    /// Reads a stored book (`init(from:)`): tolerates missing keys (an older file), drops records
    /// with an invalid or repeated id, and restores the default profile if a file lost it.
    pub fn from_json(value: serde_json::Value, default_name: &str) -> serde_json::Result<Self> {
        let stored: StoredBook = serde_json::from_value(value)?;
        let mut book = Self::new(default_name);
        let mut seen = BTreeSet::new();
        let valid: Vec<ProfileRecord> = stored
            .profiles
            .unwrap_or_default()
            .into_iter()
            .filter(|record| is_valid_id(&record.id) && seen.insert(record.id.clone()))
            .collect();
        if !valid.is_empty() {
            if valid.iter().any(ProfileRecord::is_default) {
                book.profiles = valid;
            } else {
                book.profiles.extend(valid);
            }
        }
        book.workspace_defaults = stored.workspace_defaults.unwrap_or_default();
        book.pending_cleanup = stored.pending_cleanup.unwrap_or_default();
        book.imports_migrated = stored.imports_migrated.unwrap_or(false);
        book.records_migrated = stored.records_migrated.unwrap_or(false);
        Ok(book)
    }

    /// Every profile, in stored order.
    pub fn profiles(&self) -> &[ProfileRecord] {
        &self.profiles
    }

    /// Deleted profiles whose engine data is not removed yet.
    pub fn pending_cleanup(&self) -> &[String] {
        &self.pending_cleanup
    }

    /// Profiles in display order, the default one first unless moved.
    pub fn ordered(&self) -> Vec<ProfileRecord> {
        let mut order = self.profiles.clone();
        order.sort_by(|a, b| (a.position, &a.id).cmp(&(b.position, &b.id)));
        order
    }

    /// The record of `id`.
    pub fn record(&self, id: &str) -> Option<&ProfileRecord> {
        self.profiles.iter().find(|record| record.id == id)
    }

    /// True when the book has `id`.
    pub fn contains(&self, id: &str) -> bool {
        self.record(id).is_some()
    }

    /// The engine store for a tab record's profile id. A deleted profile's id maps to the default
    /// store, so a stray tab never recreates it; a valid id this book does not know (a tab made on
    /// another Mac) keeps its own store.
    pub fn engine_profile(&self, wire_id: Option<&str>) -> BrowserProfileId {
        match wire_id {
            Some(wire_id) if !self.pending_cleanup.iter().any(|id| id == wire_id) => {
                engine_profile(Some(wire_id)).unwrap_or_else(BrowserProfileId::default_profile)
            }
            _ => BrowserProfileId::default_profile(),
        }
    }

    /// Adds a profile. An existing id returns its record unchanged, so a retried import finds the
    /// profile it made before. The app makes the id (`BrowserProfileRecord.newID()`).
    pub fn create(
        &mut self,
        id: &str,
        name: &str,
        color: Option<&str>,
        icon: Option<&str>,
        source: Option<BTreeMap<String, String>>,
    ) -> Result<ProfileRecord, ProfileBookError> {
        if !is_valid_id(id) {
            return Err(ProfileBookError::InvalidId);
        }
        self.require_reusable(id)?;
        if let Some(existing) = self.record(id) {
            return Ok(existing.clone());
        }
        let record = ProfileRecord {
            id: id.to_owned(),
            name: valid_name(name)?,
            color: valid_color(color)?,
            icon: valid_icon(icon)?,
            position: self.profiles.iter().map(|record| record.position).max().unwrap_or(0) + 1,
            source,
            proxy: None,
        };
        self.profiles.push(record.clone());
        Ok(record)
    }

    /// Refuses with `pendingCleanup` while a deletion of `id` still owns its disk stores: reusing
    /// the id then can resurrect old cookies or let an in-flight cleanup erase new data. `create`
    /// calls it, and so does the app's daemon-backed create (the home daemon stores the record,
    /// but this Mac still owns the queued Chromium and WebKit deletion).
    pub fn require_reusable(&self, id: &str) -> Result<(), ProfileBookError> {
        if self.pending_cleanup.iter().any(|pending| pending == id) {
            return Err(ProfileBookError::PendingCleanup);
        }
        Ok(())
    }

    /// Renames a profile.
    pub fn rename(&mut self, id: &str, name: &str) -> Result<(), ProfileBookError> {
        let name = valid_name(name)?;
        self.edit(id, |record| record.name = name)
    }

    /// Sets or clears a profile's color.
    pub fn set_color(&mut self, id: &str, color: Option<&str>) -> Result<(), ProfileBookError> {
        let color = valid_color(color)?;
        self.edit(id, |record| record.color = color)
    }

    /// Sets or clears a profile's icon.
    pub fn set_icon(&mut self, id: &str, icon: Option<&str>) -> Result<(), ProfileBookError> {
        let icon = valid_icon(icon)?;
        self.edit(id, |record| record.icon = icon)
    }

    /// Moves a profile to `index` in display order.
    pub fn move_to(&mut self, id: &str, index: i64) -> Result<(), ProfileBookError> {
        let mut order = self.ordered();
        let from = order
            .iter()
            .position(|record| record.id == id)
            .ok_or(ProfileBookError::UnknownProfile)?;
        let moved = order.remove(from);
        let at = usize::try_from(index.max(0)).unwrap_or(usize::MAX).min(order.len());
        order.insert(at, moved);
        for (position, record) in order.iter().enumerate() {
            if let Some(slot) = self.profiles.iter_mut().find(|slot| slot.id == record.id) {
                slot.position = i64::try_from(position).unwrap_or(i64::MAX);
            }
        }
        Ok(())
    }

    /// Removes a profile and every workspace default naming it, and queues its engine data for
    /// removal. The caller moves its tabs first.
    pub fn delete(&mut self, id: &str) -> Result<(), ProfileBookError> {
        if id == DEFAULT_ID {
            return Err(ProfileBookError::DefaultProfile);
        }
        if !self.contains(id) {
            return Err(ProfileBookError::UnknownProfile);
        }
        self.mark_deleted(id);
        Ok(())
    }

    /// `delete` for a profile whose record lives in the home daemon: drops any local copy and
    /// defaults, and queues its engine data (this Mac's).
    pub fn mark_deleted(&mut self, id: &str) {
        if id == DEFAULT_ID {
            return;
        }
        self.profiles.retain(|record| record.id != id);
        self.workspace_defaults.retain(|_, profile| profile != id);
        if !self.pending_cleanup.iter().any(|pending| pending == id) {
            self.pending_cleanup.push(id.to_owned());
        }
    }

    /// The engine data of `ids` is gone.
    pub fn finish_cleanup(&mut self, ids: &[String]) {
        self.pending_cleanup.retain(|pending| !ids.contains(pending));
    }

    fn edit(
        &mut self,
        id: &str,
        change: impl FnOnce(&mut ProfileRecord),
    ) -> Result<(), ProfileBookError> {
        let record = self
            .profiles
            .iter_mut()
            .find(|record| record.id == id)
            .ok_or(ProfileBookError::UnknownProfile)?;
        change(record);
        Ok(())
    }
}

/// Which records of an import migration to migrate (`BrowserProfileBook.migrateImports`): those
/// whose proposed profile id is valid, in order. The app runs each and keeps its ticket when one
/// waits for a pending deletion.
pub fn migratable_imports(ids: &[String]) -> Vec<usize> {
    ids.iter().enumerate().filter(|(_, id)| is_valid_id(id)).map(|(index, _)| index).collect()
}

/// The log reason of an import migration refused because its profile is pending deletion.
pub const PENDING_DELETION_REASON: &str = "browser profile is pending deletion";

// MARK: - Storage cleanup

/// Directory names of `id`'s Chromium stores among `names`: its `Profile-<UUID>` directory and
/// every remote-localhost derived store `Profile-<UUID>-m-*` (plans/cmux-next/data-model.md
/// section 5; `BrowserProfileStorageCleanup.chromiumDirectories`). `default` and invalid ids own
/// none.
pub fn chromium_directories(id: &str, names: &[String]) -> Vec<String> {
    if id == DEFAULT_ID {
        return Vec::new();
    }
    let Some(profile) = engine_profile(Some(id)) else { return Vec::new() };
    let base = format!("Profile-{}", profile.uuid_string());
    let derived = format!("{base}-m-");
    names.iter().filter(|name| **name == base || name.starts_with(&derived)).cloned().collect()
}

/// The ids whose Chromium data the cleanup removes (`removeChromiumData`): `default` and invalid
/// ids are skipped.
pub fn chromium_cleanup_ids(ids: &[String]) -> Vec<String> {
    ids.iter()
        .filter(|id| id.as_str() != DEFAULT_ID && engine_profile(Some(id.as_str())).is_some())
        .cloned()
        .collect()
}

/// The deleted profiles whose engine data is being removed now (SW-08, #30757;
/// `BrowserProfileCleanupClaims`). An in-flight deletion owns its id until both engines' data is
/// gone, so a second cleanup task never runs for it and never races a later re-creation. The app
/// keeps one in memory; it is never saved, since a new launch has no cleanup in flight.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupClaims {
    #[serde(default)]
    pub in_flight: BTreeSet<String>,
}

impl CleanupClaims {
    /// Claims and returns the ids of `pending` that no cleanup runs for yet and whose store no
    /// engine opened in this process (`is_open`: Chromium and WebKit keep an opened store's files
    /// until the process ends, so those wait for the next launch).
    pub fn claim(
        &mut self,
        pending: &[String],
        is_open: impl Fn(&BrowserProfileId) -> bool,
    ) -> Vec<String> {
        let ready: Vec<String> = pending
            .iter()
            .filter(|id| {
                if self.in_flight.contains(*id) {
                    return false;
                }
                match engine_profile(Some(id.as_str())) {
                    None => true,
                    Some(profile) => !is_open(&profile),
                }
            })
            .cloned()
            .collect();
        self.in_flight.extend(ready.iter().cloned());
        ready
    }

    /// The cleanup of `ids` ended, whether it removed their data or not; a later pass may claim
    /// them again.
    pub fn release(&mut self, ids: &[String]) {
        for id in ids {
            self.in_flight.remove(id);
        }
    }
}

// MARK: - Off the record

/// Browser profiles that keep nothing on disk: the store of an incognito window
/// (plans/cmux-next/data-model.md, section 5; `OffTheRecordProfiles`). One profile id names one
/// off-the-record session in every engine: WebKit gives it a non-persistent data store, Chromium
/// an in-memory request context, site settings an in-memory store. `end` tells every engine to
/// drop it, which deletes its data (cookies, caches, storage, permissions).
///
/// The app holds one and passes it to both engines and every store, so all read the same answer
/// to "is this profile off the record". The end observers stay in the app.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OffTheRecordProfiles {
    /// Profiles begun and not ended yet.
    #[serde(default)]
    pub active: BTreeSet<BrowserProfileId>,
    /// Profiles that ended. A page or store still asking for one after its end must never get a
    /// persistent store.
    #[serde(default)]
    pub ended: BTreeSet<BrowserProfileId>,
}

impl OffTheRecordProfiles {
    /// Begins `profile`, a new off-the-record profile (the app makes its UUID).
    pub fn begin(&mut self, profile: BrowserProfileId) {
        self.active.insert(profile);
    }

    /// True while `profile` is active.
    pub fn contains(&self, profile: &BrowserProfileId) -> bool {
        self.active.contains(profile)
    }

    /// True when `profile` is or was off the record: stores use this, so a late request for an
    /// ended profile still gets an in-memory store.
    pub fn is_off_the_record(&self, profile: &BrowserProfileId) -> bool {
        self.active.contains(profile) || self.ended.contains(profile)
    }

    /// Ends `profile`: every engine drops its data. Close its pages first. True when it was active
    /// (then the app runs its end observers); false changes nothing.
    pub fn end(&mut self, profile: &BrowserProfileId) -> bool {
        if !self.active.remove(profile) {
            return false;
        }
        self.ended.insert(profile.clone());
        true
    }
}
