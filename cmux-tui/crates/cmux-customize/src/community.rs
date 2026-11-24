//! Community themes and snippets: the two no-code tiers of customizations
//! that live in git repositories, beside extensions: a community plugin
//! ecosystem in three tiers (plugin, theme, snippet).
//!
//! Both reuse what cmux already loads; nothing here is a new format the app
//! reads:
//!
//! - A **theme** repository is marked by `cmux-theme.json` (a listing header)
//!   and holds ordinary cmux theme files at `themes/NAME.json`
//!   (`cmux_config::theme_file`). Installing one writes those files and sets
//!   `appearance.themeFile` to the one the header names. It may carry art
//!   ([`art`]) and an openly licensed font pack for the agent chat
//!   ([`fonts`]).
//! - A **snippet** repository is marked by `cmux-snippet.json`: a listing
//!   header plus a `cmuxProfile` (the format `cmux customize save` writes): a
//!   few settings and, at most, the per-surface stylesheets.
//!   Views (code), automations and theme files are refused: a snippet runs
//!   nothing.
//!
//! Either installs as one library entry ([`Customize::library_put`]): one
//! applied generation, so `cmux customize rollback`, `library off` and
//! [`Customize::community_remove`] put back what was there. Where each came
//! from (repository, ref, commit, tag, version, tree SHA-256) is kept in
//! `<state dir>/community.json`. Fetching the repository is the caller's
//! (the CLI uses the app installer's git source, so release pinning and
//! any-host fallback are the same as for extensions); this module reads the
//! fetched tree.

use std::collections::BTreeMap;
use std::path::Path;

use cmux_app_manifest::hidden;
use cmux_config::theme_file::{self, ThemeFile};
use cmux_config::{Domains, Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::library::Changed;

pub mod art;
pub mod fonts;
use crate::profile::{Profile, valid_name};
use crate::{Customize, Error};

/// The file that marks a theme repository (or directory).
pub const THEME_MARKER: &str = "cmux-theme.json";
/// The file that marks a snippet repository (or directory).
pub const SNIPPET_MARKER: &str = "cmux-snippet.json";
/// A marker file larger than this is refused unread.
pub const MAX_MARKER_BYTES: u64 = 256 * 1024;
/// The most theme files one theme repository installs.
pub const MAX_THEMES: usize = 16;
/// A stylesheet a snippet carries is at most this.
pub const MAX_SNIPPET_FILE_BYTES: u64 = 256 * 1024;
/// The files a snippet may carry, by logical path: the per-surface
/// stylesheets cmux loads. Not shortcuts: a binding can run any action.
pub const SNIPPET_FILES: &[&str] = &[
    "agent-pane/theme.css",
    "markdown/theme.css",
    "diff/theme.css",
    "picker/theme.css",
    "fileViewer/theme.css",
];
/// Where installed community items are recorded, in the state dir.
pub const RECEIPTS: &str = "community.json";

/// A no-code tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Theme,
    Snippet,
}

impl Tier {
    pub fn name(self) -> &'static str {
        match self {
            Tier::Theme => "theme",
            Tier::Snippet => "snippet",
        }
    }

    pub fn marker(self) -> &'static str {
        match self {
            Tier::Theme => THEME_MARKER,
            Tier::Snippet => SNIPPET_MARKER,
        }
    }

    /// The header key whose value (1) marks the format.
    fn format_key(self) -> &'static str {
        match self {
            Tier::Theme => "cmuxTheme",
            Tier::Snippet => "cmuxSnippet",
        }
    }

    /// The tier whose marker is in `dir`, if any.
    pub fn of_dir(dir: &Path) -> Option<Tier> {
        [Tier::Theme, Tier::Snippet].into_iter().find(|tier| dir.join(tier.marker()).is_file())
    }
}

/// A theme or snippet as read from its tree, ready to install.
#[derive(Debug, Clone, PartialEq)]
pub struct Package {
    pub tier: Tier,
    pub id: String,
    pub name: String,
    pub description: String,
    pub version: Option<String>,
    /// The marker file as read (`engines`, `screenshots`, `license`, ...).
    pub header: Value,
    /// The theme file names it installs (themes only).
    pub themes: Vec<String>,
    /// The library entry it installs as; its profile's name.
    pub profile: Profile,
    /// A theme's wallpapers, header image and flourishes (empty for a snippet).
    pub art: art::Art,
    /// A theme's font pack (empty for a snippet).
    pub fonts: fonts::Fonts,
}

/// Where an installed theme or snippet came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    pub tier: Tier,
    pub id: String,
    pub name: String,
    /// The library entry.
    pub entry: String,
    /// `HOST/OWNER/REPO[/PATH]`.
    pub reference: String,
    /// `https://HOST/OWNER/REPO`.
    pub repository: String,
    /// The ref asked for; `None` follows releases (newest version tag, else
    /// the default branch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_ref: Option<String>,
    pub commit: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The SHA-256 of the fetched tree.
    pub sha256: String,
    #[serde(default)]
    pub installed_ms: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct ReceiptsFile {
    version: u32,
    #[serde(default)]
    installed: Vec<Receipt>,
}

fn refuse(why: impl Into<String>) -> Error {
    Error::Community(why.into())
}

/// The library entry name of `tier`'s item `id` (`theme-owner-dusk`).
pub fn entry_name(tier: Tier, id: &str) -> String {
    let mut out = format!("{}-", tier.name());
    for c in id.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
        if out.len() >= 64 {
            break;
        }
    }
    out.trim_end_matches('-').to_owned()
}

/// Reads a text file of the tree, at most `limit` bytes.
fn read_text(dir: &Path, relative: &str, limit: u64) -> Result<Option<String>, Error> {
    let path = dir.join(relative);
    let Ok(metadata) = std::fs::symlink_metadata(&path) else { return Ok(None) };
    if !metadata.is_file() {
        return Err(refuse(format!("{relative}: not a plain file")));
    }
    if metadata.len() > limit {
        return Err(refuse(format!("{relative}: larger than {} KiB", limit / 1024)));
    }
    let bytes = std::fs::read(&path)?;
    String::from_utf8(bytes).map(Some).map_err(|_| refuse(format!("{relative}: not UTF-8 text")))
}

/// A header string that shows to a person: one line, no hidden characters.
fn header_text(header: &Value, key: &str, marker: &str, required: bool) -> Result<String, Error> {
    let text = match header.get(key) {
        Some(Value::String(text)) => text.trim().to_owned(),
        None | Some(Value::Null) if !required => return Ok(String::new()),
        _ => return Err(refuse(format!("{marker}: \"{key}\" must be a string"))),
    };
    if required && text.is_empty() {
        return Err(refuse(format!("{marker}: \"{key}\" is empty")));
    }
    if text.len() > 1000 || text.contains(['\n', '\r']) {
        return Err(refuse(format!("{marker}: \"{key}\" must be one line")));
    }
    if let Some(mark) = hidden::first_hidden(&text, hidden::Context::ManifestString) {
        return Err(refuse(format!(
            "{marker}: \"{key}\" has {} ({})",
            mark.describe(),
            mark.code_point
        )));
    }
    Ok(text)
}

/// Reads the theme or snippet in `dir` (a fetched tree, at the package
/// path): its marker, and the files it installs, each checked as cmux
/// checks it. The id's owner is the caller's to check ([`check_id`]).
pub fn read_package(dir: &Path) -> Result<Package, Error> {
    let tier = Tier::of_dir(dir).ok_or_else(|| {
        refuse(format!(
            "no {THEME_MARKER} or {SNIPPET_MARKER} here: not a cmux theme or snippet (an extension has cmux-app.v2.json and installs with `cmux apps install`)"
        ))
    })?;
    let marker = tier.marker();
    let text = read_text(dir, marker, MAX_MARKER_BYTES)?.unwrap_or_default();
    let header = jsonc::parse(&text)
        .ok()
        .filter(Value::is_object)
        .ok_or_else(|| refuse(format!("{marker}: not a JSON object")))?;
    match header.get(tier.format_key()).and_then(Value::as_u64) {
        Some(1) => {}
        Some(n) => {
            return Err(refuse(format!(
                "{marker}: format {n}; this cmux reads {} 1",
                tier.format_key()
            )));
        }
        None => return Err(refuse(format!("{marker}: \"{}\": 1 is missing", tier.format_key()))),
    }
    let id = header_text(&header, "id", marker, true)?;
    let valid_id = id.split_once('/').is_some_and(|(owner, name)| {
        !owner.is_empty()
            && !name.is_empty()
            && !name.contains('/')
            && id.len() <= 128
            && id.chars().all(|c| {
                c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_' | '.' | '/')
            })
    });
    if !valid_id {
        return Err(refuse(format!(
            "{marker}: id {id:?} must be OWNER/NAME in lowercase letters, digits, '-', '_' and '.'"
        )));
    }
    let name = header_text(&header, "name", marker, true)?;
    let description = header_text(&header, "description", marker, false)?;
    let version = Some(header_text(&header, "version", marker, false)?).filter(|v| !v.is_empty());
    let entry = entry_name(tier, &id);
    debug_assert!(valid_name(&entry));
    let (profile, themes, art, fonts) = match tier {
        Tier::Theme => {
            let art = art::read_art(dir, &header)?;
            let fonts = fonts::read_fonts(dir, &header)?;
            let (profile, themes) = theme_profile(dir, &header, &entry, &art, &fonts)?;
            (profile, themes, art, fonts)
        }
        Tier::Snippet => (
            snippet_profile(dir, &header)?,
            Vec::new(),
            art::Art::default(),
            fonts::Fonts::default(),
        ),
    };
    let profile = Profile { name: entry, description: description.clone(), ..profile };
    Ok(Package { tier, id, name, description, version, header, themes, profile, art, fonts })
}

/// A theme repository's profile: its theme files (backdrop and face values
/// pointed at the installed art and fonts), and the active one.
fn theme_profile(
    dir: &Path,
    header: &Value,
    entry: &str,
    art: &art::Art,
    fonts: &fonts::Fonts,
) -> Result<(Profile, Vec<String>), Error> {
    let paths: Vec<String> = match header.get("themes") {
        None | Some(Value::Null) => {
            let mut found = Vec::new();
            if let Ok(entries) = std::fs::read_dir(dir.join(theme_file::FOLDER_NAME)) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if name.ends_with(".json") && !name.starts_with('.') {
                        found.push(format!("{}/{name}", theme_file::FOLDER_NAME));
                    }
                }
            }
            found.sort();
            found
        }
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| refuse(format!("{THEME_MARKER}: \"themes\" lists paths")))
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err(refuse(format!("{THEME_MARKER}: \"themes\" must be a list"))),
    };
    if paths.is_empty() {
        return Err(refuse(format!(
            "{THEME_MARKER}: no theme files (themes/NAME.json, as `cmux theme export --save NAME` writes)"
        )));
    }
    if paths.len() > MAX_THEMES {
        return Err(refuse(format!(
            "a theme repository installs at most {MAX_THEMES} theme files"
        )));
    }
    let schema = Schema::embedded();
    let mut files = BTreeMap::new();
    let mut names = Vec::new();
    for path in &paths {
        let name = path
            .strip_prefix("themes/")
            .and_then(|rest| rest.strip_suffix(".json"))
            .filter(|name| theme_file::is_valid_name(name) && !name.contains('/'))
            .ok_or_else(|| refuse(format!("{path}: a theme file is themes/NAME.json")))?;
        let text = read_text(dir, path, theme_file::MAXIMUM_BYTES as u64)?
            .ok_or_else(|| refuse(format!("{path}: not in the repository")))?;
        let installed = art::rewrite(&text, path, entry, art)?;
        let installed = fonts::rewrite(&installed, path, entry, fonts)?;
        // Checked as written, against the tree: its `../wallpapers/` and
        // `../fonts/` values name files beside `themes/` there.
        let themes_dir = dir.join(theme_file::FOLDER_NAME);
        let file = ThemeFile::read(
            name,
            Some(Ok(text.as_str())),
            &json!({}),
            Some(&themes_dir),
            schema,
            &Domains::default(),
        );
        if file.is_unparsable || !file.diagnostics.is_empty() {
            let mut why = format!("{path} does not load as a cmux theme file");
            for diagnostic in &file.diagnostics {
                why.push_str(&format!("\n  {}", diagnostic.display()));
            }
            return Err(refuse(why));
        }
        files.insert(path.clone(), installed);
        names.push(name.to_owned());
    }
    let active = match header.get("use") {
        None | Some(Value::Null) => names.first().cloned().unwrap_or_default(),
        Some(Value::String(name)) if names.contains(name) => name.clone(),
        Some(_) => {
            return Err(refuse(format!(
                "{THEME_MARKER}: \"use\" names one of its theme files ({})",
                names.join(", ")
            )));
        }
    };
    let settings = BTreeMap::from([(theme_file::SETTING_KEY.to_owned(), Value::String(active))]);
    let profile = Profile {
        version: 1,
        name: String::new(),
        description: String::new(),
        created_ms: 0,
        settings,
        files,
    };
    Ok((profile, names))
}

/// A snippet's profile: its settings and the files it may carry.
fn snippet_profile(dir: &Path, header: &Value) -> Result<Profile, Error> {
    if header.get("cmuxProfile").and_then(Value::as_u64) != Some(1) {
        return Err(refuse(format!(
            "{SNIPPET_MARKER}: \"cmuxProfile\": 1 is missing (a snippet is a profile, as `cmux customize save` writes)"
        )));
    }
    let settings: BTreeMap<String, Value> = match header.get("settings") {
        None | Some(Value::Null) => BTreeMap::new(),
        Some(Value::Object(map)) => map.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
        Some(_) => return Err(refuse(format!("{SNIPPET_MARKER}: \"settings\" must be an object"))),
    };
    if settings.contains_key(theme_file::SETTING_KEY) {
        return Err(refuse(format!(
            "{SNIPPET_MARKER}: a snippet may not pick a theme file ({}); make it a theme repository",
            theme_file::SETTING_KEY
        )));
    }
    // Only how cmux looks: an anonymous repository does not steer agents,
    // accounts or anything else a profile may otherwise carry.
    let schema = Schema::embedded();
    for key in settings.keys() {
        if !schema.row(key).is_some_and(theme_file::is_look) {
            return Err(refuse(format!(
                "{SNIPPET_MARKER}: {key} is not a look setting; a snippet sets only how cmux looks (`cmux theme schema` lists them)"
            )));
        }
    }
    let mut files = BTreeMap::new();
    match header.get("files") {
        None | Some(Value::Null) => {}
        Some(Value::Object(map)) => {
            for (path, text) in map {
                let text = text.as_str().ok_or_else(|| {
                    refuse(format!("{SNIPPET_MARKER}: files.{path} must be the file's text"))
                })?;
                files.insert(path.clone(), text.to_owned());
            }
        }
        Some(_) => return Err(refuse(format!("{SNIPPET_MARKER}: \"files\" must be an object"))),
    }
    for path in files.keys() {
        if !SNIPPET_FILES.contains(&path.as_str()) {
            return Err(refuse(format!(
                "{path}: a snippet carries only look settings and stylesheets ({}); views and automations run code and install as an extension",
                SNIPPET_FILES.join(", ")
            )));
        }
    }
    for path in SNIPPET_FILES {
        if files.contains_key(*path) {
            continue;
        }
        if let Some(text) = read_text(dir, path, MAX_SNIPPET_FILE_BYTES)? {
            files.insert((*path).to_owned(), text);
        }
    }
    for (path, text) in &files {
        if text.len() as u64 > MAX_SNIPPET_FILE_BYTES {
            return Err(refuse(format!(
                "{path}: larger than {} KiB",
                MAX_SNIPPET_FILE_BYTES / 1024
            )));
        }
        if let Some(why) = fetches(text) {
            return Err(refuse(format!(
                "{path}: {why}; a snippet's stylesheet loads nothing from the network (inline images as data: URLs)"
            )));
        }
    }
    if settings.is_empty() && files.is_empty() {
        return Err(refuse(format!("{SNIPPET_MARKER}: the snippet sets nothing")));
    }
    Ok(Profile {
        version: 1,
        name: String::new(),
        description: String::new(),
        created_ms: 0,
        settings,
        files,
    })
}

/// The contract's id rule, as for extensions: an id from a repository
/// starts with the repository owner, lowercased (`OWNER/...`); `cmux/` and
/// `manaflow-ai/` only from manaflow-ai's repositories.
pub fn check_id(package: &Package, owner: &str) -> Result<(), Error> {
    let owner = owner.to_ascii_lowercase();
    let publisher = package.id.split('/').next().unwrap_or_default();
    if matches!(publisher, "cmux" | "manaflow-ai") && owner != "manaflow-ai" {
        return Err(refuse(format!(
            "{}: {publisher}/ comes only from manaflow-ai's repositories",
            package.id
        )));
    }
    if !matches!(publisher, "cmux" | "manaflow-ai") && publisher != owner {
        return Err(refuse(format!(
            "{}: a {} from {owner}'s repository has an id starting with {owner}/",
            package.id,
            package.tier.name()
        )));
    }
    Ok(())
}

fn triple(text: &str) -> Option<(u64, u64, u64)> {
    let core = text.trim().trim_start_matches('v').split(['-', '+']).next()?;
    let mut parts = core.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next().map_or(Some(0), |p| p.parse().ok())?;
    let patch = parts.next().map_or(Some(0), |p| p.parse().ok())?;
    Some((major, minor, patch))
}

/// The header's `engines.cmux` (`>=0.70.0`, `^0.70`, `0.70.0`, several
/// separated by spaces) against `release`, this cmux's version. A range that
/// does not parse, or a build with no release version (0.0.0), passes.
pub fn check_engines(package: &Package, release: &str) -> Result<(), Error> {
    let Some(range) = package.header.pointer("/engines/cmux").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(have) = triple(release).filter(|have| *have != (0, 0, 0)) else { return Ok(()) };
    let meets = |comparator: &str| -> bool {
        for op in [">=", "<=", ">", "<", "=", "^", "~"] {
            if let Some(text) = comparator.strip_prefix(op) {
                let Some(want) = triple(text) else { return true };
                return match op {
                    ">=" => have >= want,
                    "<=" => have <= want,
                    ">" => have > want,
                    "<" => have < want,
                    "=" => have == want,
                    "^" if want.0 == 0 => have.0 == 0 && have.1 == want.1 && have >= want,
                    "^" => have.0 == want.0 && have >= want,
                    _ => have.0 == want.0 && have.1 == want.1 && have >= want,
                };
            }
        }
        triple(comparator).is_none_or(|want| have >= want)
    };
    if range.split_whitespace().all(meets) {
        Ok(())
    } else {
        Err(refuse(format!(
            "{} {} requires cmux {range}; this cmux is {release}",
            package.tier.name(),
            package.id
        )))
    }
}

/// Why a stylesheet would load something: an `@import`, or a `url(...)`
/// that is not a `data:` URL. Comments and escapes are no way around it:
/// the text is checked with comments taken out and backslashes refused.
pub fn fetches(css: &str) -> Option<&'static str> {
    let mut plain = String::with_capacity(css.len());
    let mut rest = css;
    while let Some((before, after)) = rest.split_once("/*") {
        plain.push_str(before);
        plain.push(' ');
        rest = after.split_once("*/").map_or("", |(_, tail)| tail);
    }
    plain.push_str(rest);
    let lower = plain.to_ascii_lowercase();
    if lower.contains('\\') {
        return Some("it has a backslash escape");
    }
    if lower.contains("@import") {
        return Some("it has an @import");
    }
    if lower.contains("image-set(") || lower.contains("src(") {
        return Some("it loads an image or font by address");
    }
    let mut search = lower.as_str();
    while let Some((_, after)) = search.split_once("url(") {
        let inner = after.trim_start().trim_start_matches(['"', '\'']).trim_start();
        if !inner.starts_with("data:") {
            return Some("it has a url() that is not a data: URL");
        }
        search = after;
    }
    None
}

/// The one line shown before an install or update: what it is, where from,
/// and that no code runs. `verb`: `Install` or `Update`.
pub fn card(verb: &str, package: &Package, receipt: &Receipt, reviewed: bool) -> String {
    let at = match (&receipt.tag, &receipt.version) {
        (Some(tag), _) => format!("{tag} ({})", short(&receipt.commit)),
        (None, Some(version)) => format!("{version} ({})", short(&receipt.commit)),
        (None, None) => short(&receipt.commit).to_owned(),
    };
    let author = package.id.split('/').next().unwrap_or_default();
    let mut carries = Vec::new();
    if !package.art.images.is_empty() {
        carries.push(crate::count(package.art.images.len(), "image"));
    }
    if !package.fonts.files.is_empty() {
        let license = package.fonts.license.as_deref().unwrap_or_default();
        carries.push(format!("{} ({license})", crate::count(package.fonts.files.len(), "font")));
    }
    let with =
        if carries.is_empty() { String::new() } else { format!(", with {}", carries.join(", ")) };
    format!(
        "{verb} {} \"{}\" by {author} from {} @ {at}{with}: no code runs.{}",
        package.tier.name(),
        package.name,
        receipt.reference,
        if reviewed { "" } else { " Not reviewed by cmux." }
    )
}

fn short(commit: &str) -> &str {
    commit.get(..7).unwrap_or(commit)
}

impl Customize {
    fn receipts_path(&self) -> std::path::PathBuf {
        self.roots().state_dir.join(RECEIPTS)
    }

    fn read_receipts(&self) -> Result<ReceiptsFile, Error> {
        match std::fs::read_to_string(self.receipts_path()) {
            Ok(text) => serde_json::from_str(&text).map_err(|error| {
                refuse(format!(
                    "{}: not a cmux community list (line {})",
                    self.receipts_path().display(),
                    error.line()
                ))
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(ReceiptsFile { version: 1, installed: Vec::new() })
            }
            Err(error) => Err(error.into()),
        }
    }

    fn write_receipts(&self, file: &mut ReceiptsFile) -> Result<(), Error> {
        file.version = 1;
        let mut text = serde_json::to_string_pretty(file).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.receipts_path(), text.as_bytes())?;
        Ok(())
    }

    /// The installed themes and snippets (`tier`: only those).
    pub fn community(&self, tier: Option<Tier>) -> Result<Vec<Receipt>, Error> {
        Ok(self
            .read_receipts()?
            .installed
            .into_iter()
            .filter(|receipt| tier.is_none_or(|tier| receipt.tier == tier))
            .collect())
    }

    /// The installed item `which` names: its id, its library entry, or its
    /// reference (`HOST/OWNER/REPO[/PATH]`, any case, a ref ignored).
    pub fn community_find(&self, tier: Tier, which: &str) -> Result<Receipt, Error> {
        let which = which.trim().trim_start_matches("https://");
        let location = which.split('@').next().unwrap_or(which).trim_end_matches('/');
        self.community(Some(tier))?
            .into_iter()
            .find(|receipt| {
                receipt.id == which
                    || receipt.entry == which
                    || receipt.reference.eq_ignore_ascii_case(location)
            })
            .ok_or_else(|| {
                refuse(format!(
                    "no installed {} is {which}; `cmux {} installed` lists them",
                    tier.name(),
                    tier.name()
                ))
            })
    }

    /// Installs (`top`: to the top of the library, on) or updates (in its
    /// place, on or off as it was) `package` as its library entry, and
    /// records `receipt`. One applied generation.
    pub fn community_put(
        &self,
        package: &Package,
        receipt: Receipt,
        top: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        if receipt.entry != package.profile.name || receipt.tier != package.tier {
            return Err(refuse("the receipt is not this package's"));
        }
        let mut file = self.read_receipts()?;
        if let Some(other) = file
            .installed
            .iter()
            .find(|have| have.entry == receipt.entry && have.reference != receipt.reference)
        {
            return Err(refuse(format!(
                "{} {} is installed from {}; remove it first (`cmux {} remove {}`)",
                package.tier.name(),
                package.id,
                other.reference,
                package.tier.name(),
                package.id
            )));
        }
        // An entry by this name that no install made is someone's own: never
        // written over.
        let recorded = file.installed.iter().any(|have| have.entry == receipt.entry);
        if !recorded
            && let Some(entry) =
                self.library()?.entries.into_iter().find(|entry| entry.name == receipt.entry)
            && (entry.source != package.tier.name() || entry.code.is_some())
        {
            return Err(refuse(format!(
                "your library already has an entry named {}; rename or remove it first (`cmux customize library remove {}`)",
                receipt.entry, receipt.entry
            )));
        }
        let words = vec![format!("{} {}", package.tier.name(), receipt.reference)];
        let mut profile = package.profile.clone();
        profile.created_ms = now_ms;
        // The art and fonts first, so the theme never points at files that
        // are not there; a failed library change puts the earlier ones back.
        let config_dir = &self.roots().config_dir;
        let staged = art::install(config_dir, &receipt.entry, &package.art)?;
        let staged_fonts = fonts::install(config_dir, &receipt.entry, &package.fonts)?;
        let change = self.library_put(profile, package.tier.name(), words, top, origin, now_ms)?;
        match staged {
            Some(staged) => staged.keep(),
            // An update that no longer carries art: the old copy goes.
            None => {
                art::remove(config_dir, &receipt.entry)?;
            }
        }
        match staged_fonts {
            Some(staged) => staged.keep(),
            None => {
                fonts::remove(config_dir, &receipt.entry)?;
            }
        }
        file.installed.retain(|have| have.entry != receipt.entry);
        file.installed.push(receipt);
        self.write_receipts(&mut file)?;
        Ok(change)
    }

    /// Removes an installed item: its library entry comes off (what was
    /// under it comes back) and its receipt goes. `None` change: the entry
    /// was already gone from the library.
    pub fn community_remove(
        &self,
        tier: Tier,
        which: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<(Receipt, Option<Changed>), Error> {
        let receipt = self.community_find(tier, which)?;
        let in_library = self.library()?.entries.iter().any(|entry| entry.name == receipt.entry);
        let change = if in_library {
            Some(self.library_remove(&receipt.entry, origin, now_ms)?)
        } else {
            None
        };
        art::remove(&self.roots().config_dir, &receipt.entry)?;
        fonts::remove(&self.roots().config_dir, &receipt.entry)?;
        let mut file = self.read_receipts()?;
        file.installed.retain(|have| have.entry != receipt.entry);
        self.write_receipts(&mut file)?;
        Ok((receipt, change))
    }
}
