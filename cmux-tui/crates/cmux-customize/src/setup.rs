//! Setups: a whole customization in a git repo, like dotfiles, that installs
//! in one step from its URL (`cmux setup install github.com/OWNER/REPO`).
//!
//! A setup repo is marked by [`SETUP_FILE`] at its root. That file is a
//! profile (`cmuxProfile: 1`, the format `cmux customize save` writes and
//! `use` reads) with a listing header on top (`cmuxSetup: 1`, id, name,
//! description, screenshots, `engines.cmux`, `extensions`) and the
//! cmux-next.json `actions` it adds. The setup's files sit in the repo at
//! their logical paths (`keybindings.json`, `themes/NAME.json`,
//! `customize/...`, `agent-pane/theme.css`), or inline in `files`.
//!
//! A setup may carry fonts for the agent chat the way a community theme
//! does ([`crate::community::fonts`]): `fonts/*` beside `themes/`,
//! `"fontLicense"` in [`SETUP_FILE`], the license text included, at most 8
//! files of at most 2 MiB. Install copies them to
//! `<config dir>/fonts/setup-OWNER-NAME/` and points the setup's theme files'
//! `file:../fonts/NAME` faces there; remove deletes them.
//!
//! Installing one is a profile import like any other: checked whole before a
//! byte is written, applied as one generation that the library keeps as one
//! entry, so removing it takes off exactly that layer. What the setup did is
//! kept as a [`Receipt`] in `<state dir>/setups.json`, which `update` and
//! `remove` read. Fetching the repo and installing its extensions belong to
//! the caller (the CLI); this module reads a folder and writes files.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_app_manifest::hidden;
use cmux_config::migrations::{Notice, NoticeKind};
use cmux_config::{Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::community::{self, fonts};
use crate::profile::{Profile, Settled, Skipped};
use crate::redact::find_secret;
use crate::store::Kind;
use crate::tree::{self, MAX_FILE_BYTES, MAX_FILES_PER_PART, Part, SETTINGS, STYLE_SURFACES};
use crate::{Applied, Customize, Error};

/// The root file that marks a setup repo.
pub const SETUP_FILE: &str = "cmux-setup.json";
/// The setup format version this cmux reads and writes.
pub const FORMAT: u32 = 1;
/// The GitHub topic that lists a setup repo.
pub const TOPIC: &str = "cmux-setup";
/// The most `actions` one setup adds.
pub const MAX_ACTIONS: usize = 100;
/// The most extensions one setup lists.
pub const MAX_EXTENSIONS: usize = 30;
const MAX_SETUP_FILE_BYTES: u64 = 1024 * 1024;
const MAX_ACTION_BYTES: usize = 16 * 1024;
/// What the consent card shows in place of a replaced value that holds a credential.
pub const HIDDEN: &str = "(hidden: holds a credential)";

/// What a setup's actions replaced, by name (`None`: there was none).
pub type PriorActions = BTreeMap<String, Option<Value>>;
/// The badge image every setup README links to its page with.
pub const BADGE_URL: &str = "https://cmux.com/extensions/badge.svg";

/// `cmux-setup.json`: a listing header over a profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    /// The setup format version, 1.
    #[serde(rename = "cmuxSetup")]
    pub format: u32,
    /// `OWNER/NAME`, lowercase; OWNER is the repo's owner.
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tagline: Option<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    /// The setup's own version; a release is the tag `v<version>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Repo-relative image paths for its page.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub screenshots: Vec<String>,
    #[serde(default, skip_serializing_if = "Engines::is_empty")]
    pub engines: Engines,
    /// Extension references (`github.com/OWNER/REPO[/PATH][@REF]`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extensions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    /// The profile format of the part below, 1.
    #[serde(rename = "cmuxProfile", default = "one")]
    pub profile_format: u32,
    /// Settings by dotted key, as in a profile.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub settings: BTreeMap<String, Value>,
    /// Inline files by logical path, as in a profile.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub files: BTreeMap<String, String>,
    /// cmux-next.json `actions` entries, by name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub actions: BTreeMap<String, Value>,
}

fn one() -> u32 {
    1
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Engines {
    /// The oldest cmux it works on: `>=X.Y.Z`, `^X.Y` or `X.Y.Z`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux: Option<String>,
}

impl Engines {
    fn is_empty(&self) -> bool {
        self.cmux.is_none()
    }
}

/// A setup read from a folder: its header, the profile it applies, and a
/// hash of everything it applies (recorded at install, checked on a
/// reinstall of the same commit).
#[derive(Debug, Clone, PartialEq)]
pub struct Setup {
    pub manifest: Manifest,
    pub profile: Profile,
    pub sha256: String,
    /// The fonts it carries in `fonts/` (none for most setups).
    pub fonts: fonts::Fonts,
}

impl Setup {
    pub fn actions(&self) -> &BTreeMap<String, Value> {
        &self.manifest.actions
    }

    /// The same setup under another id (a local try of a look not
    /// published yet: `cmux setup install ./DIR --as OWNER/NAME`). The
    /// library entry it becomes is named for the new id.
    pub fn renamed(mut self, id: &str) -> Setup {
        self.manifest.id = id.to_owned();
        self.profile.name = profile_name(id);
        self
    }
}

pub mod check;
mod export;
mod history;
pub mod layers;
mod reference;
mod secrets;
mod variant;
pub use check::{
    CheckOptions, Deprecated, Finding, NoHistory, Report, RetiredKeys, SettingsHistory, Severity,
    check_dir, codes,
};
pub use export::readme_text;
pub use history::{SetupState, SetupStep, SetupSteps};
pub use reference::Reference;
use reference::plain;
pub use variant::THEME_FILE_KEY;

/// The id rule every repo listing follows: `OWNER/NAME`, lowercase, starting
/// with the repo's owner; `cmux/` and `manaflow-ai/` only from manaflow-ai.
pub fn check_id(id: &str, owner: &str) -> Result<(), Error> {
    let Some((first, name)) = id.split_once('/') else {
        return Err(Error::Setup(format!("the setup id {id:?} is not OWNER/NAME")));
    };
    if id != id.to_ascii_lowercase() || !plain(first) || !plain(name) {
        return Err(Error::Setup(format!(
            "the setup id {id:?} is not OWNER/NAME in lowercase letters, digits, '.', '-' and '_'"
        )));
    }
    let owner = owner.to_ascii_lowercase();
    if matches!(first, "cmux" | "manaflow-ai") && owner != "manaflow-ai" {
        return Err(Error::Setup(format!("the setup id {id:?} is reserved for cmux's own setups")));
    }
    if first != owner {
        return Err(Error::Setup(format!(
            "the setup id {id:?} must start with the repo's owner ({owner}/...)"
        )));
    }
    Ok(())
}

/// Whether this cmux (`running`, `X.Y.Z`) meets `engines.cmux`. An unstamped
/// build (`0.0.0`) or a requirement it cannot read passes: the check is for
/// a clear message, never a lock.
pub fn engine_ok(required: Option<&str>, running: &str) -> Result<(), Error> {
    let Some(required) = required else { return Ok(()) };
    let Some(min) = version(required.trim_start_matches(['>', '=', '^', '~', ' ', 'v'])) else {
        return Ok(());
    };
    let Some(have) = version(running.trim_start_matches('v')) else { return Ok(()) };
    if have == (0, 0, 0) || have >= min {
        return Ok(());
    }
    Err(Error::Setup(format!(
        "this setup requires cmux {}.{}.{} or later; this is {running}",
        min.0, min.1, min.2
    )))
}

fn version(text: &str) -> Option<(u64, u64, u64)> {
    let core = text.split(['-', '+', ' ']).next()?;
    let mut parts = core.split('.').map(|part| part.parse::<u64>());
    let major = parts.next()?.ok()?;
    let minor = parts.next().unwrap_or(Ok(0)).ok()?;
    let patch = parts.next().unwrap_or(Ok(0)).ok()?;
    Some((major, minor, patch))
}

/// Reads the setup in `dir` (a checked-out repo, or the folder in it that
/// holds [`SETUP_FILE`]). Reads only; checks the format, not the content.
pub fn read_dir(dir: &Path) -> Result<Setup, Error> {
    let mut findings = Vec::new();
    let setup = read_parts(dir, &mut findings).map_err(|finding| Error::Setup(finding.message))?;
    check::first_error(findings, Error::Setup)?;
    Ok(setup)
}

/// [`read_dir`] that goes on past a file it cannot take: the setup without
/// it, and a finding for it in `findings`. `Err` only when there is no
/// setup to read (no header, or one that does not read).
pub(crate) fn read_parts(dir: &Path, findings: &mut Vec<Finding>) -> Result<Setup, Box<Finding>> {
    let unreadable = |message: String| Finding::error(codes::SETUP_UNREADABLE, SETUP_FILE, message);
    let file = dir.join(SETUP_FILE);
    let metadata = std::fs::symlink_metadata(&file).map_err(|_| {
        unreadable(format!("there is no {SETUP_FILE} at the root, so this is not a cmux setup"))
            .fix(format!("add {SETUP_FILE} with \"cmuxSetup\": 1, an id and a name"))
    })?;
    if !metadata.is_file() || metadata.len() > MAX_SETUP_FILE_BYTES {
        return Err(unreadable(format!("{SETUP_FILE} is not a file under 1 MB")).into());
    }
    let text = std::fs::read_to_string(&file)
        .map_err(|error| unreadable(format!("{SETUP_FILE}: {error}")))?;
    let mut value = jsonc::parse(&text)
        .map_err(|error| unreadable(format!("{SETUP_FILE} is not JSON: {error}")))?;
    crate::file_refs::resolve(&mut value, dir).map_err(unreadable)?;
    let fonts = fonts::read_fonts(dir, &value).map_err(|error| unreadable(refusal_text(error)))?;
    let manifest: Manifest = serde_json::from_value(value).map_err(|error| {
        unreadable(format!("{SETUP_FILE} is not a cmux setup: {}", strip_value(&error)))
    })?;
    if manifest.format != FORMAT {
        return Err(Finding::error(
            codes::SETUP_FORMAT,
            SETUP_FILE,
            format!("this setup is format {}; this cmux reads format {FORMAT}", manifest.format),
        )
        .key("cmuxSetup")
        .into());
    }
    let mut files = manifest.files.clone();
    for (path, text) in repo_files(dir, findings) {
        if files.insert(path.clone(), text).is_some() {
            findings.push(
                Finding::error(
                    codes::FILE_UNREADABLE,
                    path.clone(),
                    format!("{path} is both in {SETUP_FILE}'s files and in the repo; keep one"),
                )
                .key(format!("files.{path}")),
            );
        }
    }
    if !fonts.files.is_empty() {
        let entry = fonts_entry(&manifest.id);
        for (path, text) in &mut files {
            if path.starts_with("themes/") && path.ends_with(".json") {
                *text = fonts::rewrite(text, path, &entry, &fonts)
                    .map_err(|error| unreadable(refusal_text(error)))?;
            }
        }
    }
    let profile = Profile {
        version: manifest.profile_format,
        name: profile_name(&manifest.id),
        description: manifest.description.clone(),
        created_ms: 0,
        settings: manifest.settings.clone(),
        files,
    };
    let sha256 = {
        let parts = (&manifest.settings, &manifest.actions, &profile.files);
        let canonical = if fonts.files.is_empty() {
            serde_json::to_vec(&parts).unwrap_or_default()
        } else {
            // The font bytes are part of what it applies; a setup without
            // fonts hashes as it always did.
            let mut digests = Vec::new();
            for path in fonts.files.iter().chain(&fonts.licenses) {
                let bytes = std::fs::read(dir.join(path))
                    .map_err(|error| unreadable(format!("{path}: {error}")))?;
                digests.push((path.as_str(), tree::sha256(&bytes)));
            }
            serde_json::to_vec(&(parts.0, parts.1, parts.2, &digests)).unwrap_or_default()
        };
        tree::sha256(&canonical)
    };
    Ok(Setup { manifest, profile, sha256, fonts })
}

/// The folder name a setup's fonts are copied to under `<config dir>/fonts/`:
/// `setup-OWNER-NAME`, its library entry's name.
pub fn fonts_entry(id: &str) -> String {
    profile_name(id)
}

/// A font-pack refusal worded for a setup ([`fonts`] words it for a theme).
fn setup_refusal(error: Error) -> Error {
    match error {
        Error::Community(why) => Error::Setup(
            why.replace(community::THEME_MARKER, SETUP_FILE)
                .replace("a community theme's", "a setup's")
                .replace("a theme", "a setup"),
        ),
        other => other,
    }
}

/// [`setup_refusal`]'s message, for a finding.
fn refusal_text(error: Error) -> String {
    match setup_refusal(error) {
        Error::Setup(message) => message,
        other => other.to_string(),
    }
}

/// The serde message without the value it quotes.
fn strip_value(error: &serde_json::Error) -> String {
    let message = error.to_string();
    let message = message.split(" at line ").next().unwrap_or(&message);
    match message.split_once(": ") {
        Some((head, _)) if head.starts_with("invalid type") => head.to_owned(),
        _ => message.to_owned(),
    }
}

/// `setup-OWNER-NAME`, as a profile (and so a library entry) name.
fn profile_name(id: &str) -> String {
    let mut name: String = format!("setup-{id}")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect();
    name.truncate(64);
    name.trim_end_matches('-').to_owned()
}

/// The customization files a setup repo holds at their logical paths; one
/// it cannot take is a finding, and left out.
fn repo_files(dir: &Path, findings: &mut Vec<Finding>) -> BTreeMap<String, String> {
    let mut found = BTreeMap::new();
    let unreadable =
        |logical: &str, message: String| Finding::error(codes::FILE_UNREADABLE, logical, message);
    let mut take = |logical: String, file: &Path, findings: &mut Vec<Finding>| {
        let metadata = match std::fs::symlink_metadata(file) {
            Ok(metadata) => metadata,
            Err(error) => {
                return findings.push(unreadable(&logical, format!("{logical}: {error}")));
            }
        };
        if metadata.file_type().is_symlink() {
            return findings.push(
                unreadable(&logical, format!("{logical} is a link; a setup holds plain files"))
                    .fix("put the file itself in the repo"),
            );
        }
        if !metadata.is_file() {
            return;
        }
        if metadata.len() > MAX_FILE_BYTES {
            return findings.push(unreadable(&logical, format!("{logical} is larger than 2 MB")));
        }
        match std::fs::read(file).map(String::from_utf8) {
            Ok(Ok(text)) => {
                found.insert(logical, text);
            }
            Ok(Err(_)) => findings.push(unreadable(&logical, format!("{logical} is not text"))),
            Err(error) => findings.push(unreadable(&logical, format!("{logical}: {error}"))),
        }
    };
    let keys = dir.join("keybindings.json");
    if std::fs::symlink_metadata(&keys).is_ok() {
        take("keybindings.json".to_owned(), &keys, findings);
    }
    for surface in STYLE_SURFACES {
        let css = dir.join(surface).join("theme.css");
        if std::fs::symlink_metadata(&css).is_ok() {
            take(format!("{surface}/theme.css"), &css, findings);
        }
    }
    for part in ["themes", "customize"] {
        let mut listed = Vec::new();
        if let Err(finding) = walk(&dir.join(part), part, &mut listed) {
            findings.push(*finding);
            continue;
        }
        if listed.len() > MAX_FILES_PER_PART {
            findings.push(unreadable(
                part,
                format!("{part}/ holds more than {MAX_FILES_PER_PART} files"),
            ));
            continue;
        }
        for (logical, file) in listed {
            if part == "themes" && !logical.ends_with(".json") {
                continue;
            }
            take(logical, &file, findings);
        }
    }
    found
}

fn walk(dir: &Path, logical: &str, out: &mut Vec<(String, PathBuf)>) -> Result<(), Box<Finding>> {
    let unreadable = |message: String| Finding::error(codes::FILE_UNREADABLE, logical, message);
    let metadata = match std::fs::symlink_metadata(dir) {
        Ok(metadata) => metadata,
        Err(_) => return Ok(()),
    };
    if metadata.file_type().is_symlink() {
        return Err(unreadable(format!("{logical} is a link; a setup holds plain files"))
            .fix("put the folder itself in the repo")
            .into());
    }
    if !metadata.is_dir() {
        return Ok(());
    }
    let io = |error: std::io::Error| unreadable(format!("{logical}: {error}"));
    let mut entries: Vec<_> =
        std::fs::read_dir(dir).map_err(io)?.collect::<Result<_, _>>().map_err(io)?;
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.ends_with('~') || name == "node_modules" {
            continue;
        }
        let path = entry.path();
        let child = format!("{logical}/{name}");
        if out.len() > MAX_FILES_PER_PART {
            return Ok(());
        }
        if entry.file_type().map_err(io)?.is_dir() {
            walk(&path, &child, out)?;
        } else {
            out.push((child, path));
        }
    }
    Ok(())
}

/// What an install would change, for the consent card. Values that look
/// like a credential are never in it: a setup with one is refused.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Plan {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The theme file it selects (`appearance.themeFile`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    pub settings: Vec<PlannedSetting>,
    pub files: Vec<PlannedFile>,
    /// How many shortcuts it adds (merged into yours).
    pub keybindings: usize,
    pub actions: Vec<PlannedAction>,
    pub extensions: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requires: Option<String>,
    /// The app its views install as, in a layer of its own
    /// (`local/setup-OWNER-NAME`); your own customize folder is not touched.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    /// The font files it copies into `<config dir>/fonts/setup-OWNER-NAME/`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub fonts: Vec<String>,
    /// Their `"fontLicense"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font_license: Option<String>,
    /// Settings it names by an older name, or set to a choice a row renamed:
    /// they install under the new name and value (`settings` lists those).
    pub renamed: Vec<Notice>,
    /// Settings it sets that this cmux leaves out, and why: a key cmux
    /// removed, or one this cmux has no setting for (a newer cmux may).
    pub skipped: Vec<Skipped>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PlannedSetting {
    pub key: String,
    pub value: Value,
    /// Your value now, when you set one and it differs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replaces: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PlannedFile {
    pub path: String,
    pub part: Part,
    /// A file of yours at that path that it changes (never a view: views
    /// go to the setup's own layer).
    pub replaces: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PlannedAction {
    pub name: String,
    /// `command` or `agent`.
    pub kind: String,
    /// The shell command it runs, or the agent it starts (and its args).
    pub runs: String,
    /// An action of yours with that name that it changes.
    pub replaces: bool,
}

impl Plan {
    /// Whether it changes nothing of cmux's own (it may still list extensions).
    pub fn is_empty(&self) -> bool {
        self.settings.is_empty() && self.files.is_empty() && self.actions.is_empty()
    }
}

/// What an install changed, to undo it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Installed {
    /// The apply that recorded it; `None` when it changed nothing.
    pub applied: Option<Applied>,
    /// The generation that was current before it.
    pub before: Option<u32>,
    /// What the setup's actions replaced, by name (`None`: there was none).
    pub prior_actions: PriorActions,
    /// The install made the library entry `applied` names (`false`: the
    /// apply matched one you already had).
    pub library_created: bool,
    /// The folder of its own views layer (its `customize/` files), under
    /// the setups folder; `None` when it carries no views.
    pub layer: Option<String>,
}

/// Where an installed setup came from: a repo at a reference, or a folder
/// on this machine (`cmux setup install ./DIR`), which `update` reads again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum SetupSource {
    Repo { reference: Reference },
    Folder { path: PathBuf },
}

impl SetupSource {
    /// What a second install of the same source matches on: the repo's
    /// reference key (`host/owner/repo[/path]`), or the folder.
    pub fn key(&self) -> String {
        match self {
            SetupSource::Repo { reference } => reference.key(),
            SetupSource::Folder { path } => path.display().to_string(),
        }
    }

    pub fn reference(&self) -> Option<&Reference> {
        match self {
            SetupSource::Repo { reference } => Some(reference),
            SetupSource::Folder { .. } => None,
        }
    }

    pub fn folder(&self) -> Option<&Path> {
        match self {
            SetupSource::Folder { path } => Some(path),
            SetupSource::Repo { .. } => None,
        }
    }
}

impl std::fmt::Display for SetupSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SetupSource::Repo { reference } => write!(f, "{reference}"),
            SetupSource::Folder { path } => write!(f, "{}", path.display()),
        }
    }
}

/// An installed setup, as `update`, `remove`, `on`, `off` and `order` read
/// it. Keyed by its id: one install per id, whatever its source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "ReceiptWire")]
pub struct Receipt {
    pub id: String,
    pub name: String,
    pub source: SetupSource,
    /// The repo it names (`github.com/OWNER/REPO`), or the folder.
    pub repository: String,
    pub commit: String,
    pub sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The generation the install recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<u32>,
    /// The generation current before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<u32>,
    /// The library entry it is, which `remove` takes off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub library: Option<String>,
    /// The install made that entry, so `remove` deletes it; otherwise the
    /// entry was yours already and `remove` only turns it off.
    #[serde(default)]
    pub library_created: bool,
    /// The actions it set, and what each replaced (`null`: none).
    #[serde(default)]
    pub actions: BTreeMap<String, Value>,
    #[serde(default)]
    pub prior_actions: PriorActions,
    #[serde(default)]
    pub extensions: Vec<ExtensionReceipt>,
    pub installed_ms: u64,
    /// Whether its layer is on (`cmux setup off ID` keeps it installed).
    pub on: bool,
    /// Its own views layer: the folder under the setups folder that holds
    /// its `customize/` files as the app `local/<layer>` ([`layers`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
}

impl Receipt {
    /// The receipt of `setup` installed from `source` at `commit`.
    pub fn new(
        setup: &Setup,
        installed: &Installed,
        source: SetupSource,
        commit: &str,
        extensions: Vec<ExtensionReceipt>,
        now_ms: u64,
    ) -> Receipt {
        let repository = match &source {
            SetupSource::Repo { reference } => reference.repository(),
            SetupSource::Folder { path } => path.display().to_string(),
        };
        Receipt {
            id: setup.manifest.id.clone(),
            name: setup.manifest.name.clone(),
            source,
            repository,
            commit: commit.to_owned(),
            sha256: setup.sha256.clone(),
            version: setup.manifest.version.clone(),
            generation: installed.applied.as_ref().map(|applied| applied.generation.n),
            before: installed.before,
            library: installed.applied.as_ref().and_then(|applied| applied.library.clone()),
            library_created: installed.library_created,
            actions: setup.actions().clone(),
            prior_actions: installed.prior_actions.clone(),
            extensions,
            installed_ms: now_ms,
            on: true,
            layer: installed.layer.clone(),
        }
    }
}

/// A receipt as `setups.json` holds it: the current form (`source`), or the
/// first one (a repo `reference`, and `local` for a folder), read the same.
#[derive(Deserialize)]
struct ReceiptWire {
    id: String,
    name: String,
    #[serde(default)]
    source: Option<SetupSource>,
    #[serde(default)]
    reference: Option<Reference>,
    #[serde(default)]
    local: Option<PathBuf>,
    repository: String,
    commit: String,
    sha256: String,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    generation: Option<u32>,
    #[serde(default)]
    before: Option<u32>,
    #[serde(default)]
    library: Option<String>,
    #[serde(default)]
    library_created: bool,
    #[serde(default)]
    actions: BTreeMap<String, Value>,
    #[serde(default)]
    prior_actions: PriorActions,
    #[serde(default)]
    extensions: Vec<ExtensionReceipt>,
    installed_ms: u64,
    #[serde(default = "on")]
    on: bool,
    #[serde(default)]
    layer: Option<String>,
}

fn on() -> bool {
    true
}

impl TryFrom<ReceiptWire> for Receipt {
    type Error = String;

    fn try_from(wire: ReceiptWire) -> Result<Receipt, String> {
        let source = match (wire.source, wire.local, wire.reference) {
            (Some(source), _, _) => source,
            (None, Some(path), _) => SetupSource::Folder { path },
            (None, None, Some(reference)) => SetupSource::Repo { reference },
            (None, None, None) => return Err(format!("the setup {} names no source", wire.id)),
        };
        Ok(Receipt {
            id: wire.id,
            name: wire.name,
            source,
            repository: wire.repository,
            commit: wire.commit,
            sha256: wire.sha256,
            version: wire.version,
            generation: wire.generation,
            before: wire.before,
            library: wire.library,
            library_created: wire.library_created,
            actions: wire.actions,
            prior_actions: wire.prior_actions,
            extensions: wire.extensions,
            installed_ms: wire.installed_ms,
            on: wire.on,
            layer: wire.layer,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtensionReceipt {
    pub reference: String,
    /// The app id it installed as, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// This setup installed it (it was not installed before), so removing
    /// the setup removes it.
    pub installed_by_setup: bool,
}

/// `<state dir>/setups.json`: the installed setups, top layer first.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ReceiptsFile {
    /// 2 since receipts name their source and are kept in layer order; a
    /// file without it is the first form, read the same ([`ReceiptWire`]).
    #[serde(rename = "cmuxSetups", default)]
    format: u32,
    #[serde(default)]
    setups: Vec<Receipt>,
}

const RECEIPTS_FORMAT: u32 = 2;

/// What a remove put back.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Removed {
    pub id: String,
    /// The library entry taken off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub library: Option<String>,
    /// The views layer deleted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    /// Actions taken out or put back to yours.
    pub actions: Vec<String>,
    /// Actions left as they are: you changed them after the install.
    pub kept_actions: Vec<String>,
    /// Actions another installed setup also sets: they stay that setup's
    /// (the topmost one's, when several do).
    pub shared_actions: Vec<String>,
}

/// What an export wrote.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Exported {
    pub dir: PathBuf,
    pub id: String,
    pub settings: usize,
    pub files: Vec<String>,
    pub actions: Vec<String>,
    pub left_out: Vec<String>,
    pub page_url: String,
}

/// The header fields `export` writes.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExportHeader {
    pub id: String,
    pub name: String,
    pub description: String,
    /// `OWNER/REPO` on GitHub the repo will be pushed to (for the badge and
    /// install line); the id when empty.
    pub repo: String,
    pub extensions: Vec<String>,
}

impl Customize {
    fn setup_receipts_path(&self) -> PathBuf {
        self.roots().state_dir.join("setups.json")
    }

    fn read_setup_receipts(&self) -> Result<ReceiptsFile, Error> {
        match std::fs::read_to_string(self.setup_receipts_path()) {
            Ok(text) => serde_json::from_str(&text)
                .map_err(|_| Error::Setup("setups.json is not readable".to_owned())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(ReceiptsFile::default())
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Writes the receipts, and the layer index the daemon reads from them
    /// (every receipt that is on and has views, in the same order).
    fn write_setup_receipts(&self, file: &ReceiptsFile) -> Result<(), Error> {
        let file = ReceiptsFile { format: RECEIPTS_FORMAT, setups: file.setups.clone() };
        let mut text = serde_json::to_string_pretty(&file).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.setup_receipts_path(), text.as_bytes())?;
        layers::write_index(&self.roots().setups_dir(), &file.setups)?;
        Ok(())
    }

    /// The installed setups, top layer first.
    pub fn setups(&self) -> Result<Vec<Receipt>, Error> {
        Ok(self.read_setup_receipts()?.setups)
    }

    /// The installed setup `which` names: its id, its repo reference (any
    /// form), or its folder.
    pub fn setup(&self, which: &str) -> Result<Option<Receipt>, Error> {
        let key = Reference::parse(which).ok().map(|reference| reference.key());
        let folder = std::fs::canonicalize(which).ok();
        Ok(self.setups()?.into_iter().find(|receipt| {
            receipt.id == which
                || Some(receipt.source.key()) == key
                || folder.as_deref().is_some_and(|dir| receipt.source.folder() == Some(dir))
        }))
    }

    /// Keeps `receipt`: in place of the one with its id (an update keeps
    /// its place in the order), else on top.
    pub fn record_setup(&self, receipt: Receipt) -> Result<(), Error> {
        let _lock = self.store().lock()?;
        self.put_receipt_locked(receipt)
    }

    fn put_receipt_locked(&self, receipt: Receipt) -> Result<(), Error> {
        let mut file = self.read_setup_receipts()?;
        match file.setups.iter_mut().find(|old| old.id == receipt.id) {
            Some(old) => *old = receipt,
            None => file.setups.insert(0, receipt),
        }
        self.write_setup_receipts(&file)
    }

    /// Turns installed setup `id` on or off: its library entry (its
    /// settings, theme, shortcuts, styles) and its views layer, as one
    /// generation. Off keeps it installed, in its place in the order.
    pub fn set_setup_on(
        &self,
        id: &str,
        on: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Receipt, Error> {
        self.no_preview_open()?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let mut file = self.read_setup_receipts()?;
        let Some(receipt) = file.setups.iter_mut().find(|receipt| receipt.id == id) else {
            return Err(Error::Setup(format!("{id} is not an installed setup")));
        };
        if let Some(name) = &receipt.library {
            let label = format!("setup {id}: {}", if on { "on" } else { "off" });
            self.library_set_on_locked(name, on, &label, origin, now_ms)?;
        }
        receipt.on = on;
        let receipt = receipt.clone();
        self.write_setup_receipts(&file)?;
        Ok(receipt)
    }

    /// Puts the installed setups in `ids`' order, top first (any not named
    /// keep their order, below them). Their library entries take the same
    /// order among the slots setups hold, so a key two setups set takes the
    /// higher one's value; entries of your own stay where they are.
    pub fn order_setups(
        &self,
        ids: &[String],
        origin: &str,
        now_ms: u64,
    ) -> Result<Vec<Receipt>, Error> {
        self.no_preview_open()?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let mut file = self.read_setup_receipts()?;
        for id in ids {
            if !file.setups.iter().any(|receipt| &receipt.id == id) {
                return Err(Error::Setup(format!("{id} is not an installed setup")));
            }
        }
        let rank =
            |receipt: &Receipt| ids.iter().position(|id| id == &receipt.id).unwrap_or(ids.len());
        file.setups.sort_by_key(rank);
        let order: Vec<String> =
            file.setups.iter().filter_map(|receipt| receipt.library.clone()).collect();
        self.library_reorder_locked(&order, "setups: order", origin, now_ms)?;
        self.write_setup_receipts(&file)?;
        Ok(file.setups)
    }

    /// Checks `setup` whole, writing nothing, and says what it would change.
    /// `owner` is the repo's owner (the id rule); `running` this cmux's
    /// version (`engines.cmux`).
    pub fn plan_setup(&self, setup: &Setup, owner: &str, running: &str) -> Result<Plan, Error> {
        let manifest = &setup.manifest;
        check::first_error(header_findings(manifest, owner, running), Error::Setup)?;
        let settled = self.check_setup(setup)?;

        let live = tree::read(self.roots(), SETTINGS)?
            .map(|bytes| jsonc::parse(&String::from_utf8_lossy(&bytes)).unwrap_or(Value::Null))
            .unwrap_or(Value::Null);
        let schema = Schema::embedded();
        let settings = settled
            .profile
            .settings
            .iter()
            .map(|(key, value)| {
                let row = schema.row(key);
                let url = row.is_some_and(|row| matches!(row.kind, cmux_config::schema::Kind::Url));
                let replaces = row
                    .and_then(|row| cmux_config::value::value_at(&live, &row.path).cloned())
                    .filter(|now| now != value)
                    // The card prints what a setting replaces: never a credential.
                    .map(|now| {
                        if crate::redact::sensitive_value(&now, url)
                            || find_secret(&now.to_string()).is_some()
                        {
                            Value::String(HIDDEN.to_owned())
                        } else {
                            now
                        }
                    });
                PlannedSetting { key: key.clone(), value: value.clone(), replaces }
            })
            .collect();
        let mut files = Vec::new();
        for (path, text) in &setup.profile.files {
            // Views go to the setup's own layer: never over a file of yours.
            let mine = match layers::is_view(path) {
                true => None,
                false => tree::read(self.roots(), path)?,
            };
            files.push(PlannedFile {
                path: path.clone(),
                part: Part::of(path),
                replaces: mine.is_some_and(|mine| mine != text.as_bytes()),
            });
        }
        let keybindings = setup
            .profile
            .files
            .get(crate::library::keys::KEYBINDINGS)
            .and_then(|text| jsonc::parse(text).ok())
            .and_then(|value| value.as_array().map(Vec::len))
            .unwrap_or(0);
        let actions = manifest
            .actions
            .iter()
            .map(|(name, value)| {
                let now = cmux_config::value::value_at(&live, &["actions", name.as_str()]);
                PlannedAction {
                    name: name.clone(),
                    kind: action_kind(value).to_owned(),
                    runs: action_runs(value),
                    replaces: now.is_some_and(|now| now != value),
                }
            })
            .collect();
        Ok(Plan {
            id: manifest.id.clone(),
            name: manifest.name.clone(),
            description: manifest.description.clone(),
            version: manifest.version.clone(),
            theme: settled
                .profile
                .settings
                .get("appearance.themeFile")
                .and_then(Value::as_str)
                .map(str::to_owned),
            settings,
            files,
            keybindings,
            actions,
            extensions: manifest.extensions.clone(),
            requires: manifest.engines.cmux.clone(),
            layer: installed_layer_name(setup).map(|_| layers::app_id(&manifest.id)),
            fonts: setup.fonts.files.clone(),
            font_license: setup.fonts.license.clone().filter(|_| !setup.fonts.files.is_empty()),
            renamed: settled
                .notices
                .iter()
                .filter(|notice| notice.kind != NoticeKind::Removed)
                .cloned()
                .collect(),
            skipped: settled
                .notices
                .iter()
                .filter(|notice| notice.kind == NoticeKind::Removed)
                .map(|notice| Skipped { key: notice.from.clone(), reason: notice.message() })
                .chain(settled.skipped)
                .collect(),
        })
    }

    /// Applies `setup` as one generation (and one library entry): its
    /// profile through the same path `cmux customize use` takes, then its
    /// actions into the settings file, then apply. Its views (`customize/`
    /// files) never go into your own customize folder: they are written as
    /// its own layer, the app `local/setup-OWNER-NAME` in the setups folder
    /// ([`layers`]). The caller showed the plan ([`Customize::plan_setup`])
    /// and has the person's yes. A preview that is open is kept by number
    /// first, as a profile import keeps it.
    pub fn install_setup(
        &self,
        setup: &Setup,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Installed, Error> {
        let settled = self.check_setup(setup)?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let before = self.current_generation()?;
        let receipts = self.read_setup_receipts()?;
        let installed = self.install_setup_locked(setup, &settled.profile, label, origin, now_ms);
        if installed.is_err() {
            // The receipts as they were (an install can disown an action
            // you changed from the setups that set it).
            let _ = self.write_setup_receipts(&receipts);
        }
        if installed.is_err()
            && let Some(n) = before
        {
            // All or nothing: what was live before comes back (the preview
            // and a half-written settings file are kept as a discarded
            // generation, never lost).
            let why = format!("setup {}: install failed", setup.manifest.id);
            let _ = self.restore_locked(n, Kind::Discarded, origin, &why, now_ms);
        }
        installed.map(|installed| Installed { before, ..installed })
    }

    /// Updates `old` to `setup` as one change, under one hold of the store
    /// lock (no other change can land between its steps): `old` comes off,
    /// `setup` goes on in `old`'s place in the order (above it stays what
    /// was above it, your own later changes included), and when a step
    /// fails, `old` is back as it was (the library file, what was live, its
    /// views layer, its receipt).
    pub fn replace_setup(
        &self,
        old: &Receipt,
        setup: &Setup,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Installed, Error> {
        let settled = self.check_setup(setup)?;
        self.no_preview_open()?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let before = self.current_generation()?;
        let library = self.library_snapshot()?;
        let receipts = self.read_setup_receipts()?;
        let new_id = &setup.manifest.id;
        if new_id != &old.id && receipts.setups.iter().any(|receipt| &receipt.id == new_id) {
            return Err(Error::Setup(format!(
                "{} now reads as {new_id}, which is another installed setup; remove one first",
                old.id
            )));
        }
        let setups_dir = self.roots().setups_dir();
        let slot = old
            .library
            .as_ref()
            .and_then(|name| self.library_names().ok()?.iter().position(|entry| entry == name));
        let stash = layers::stash(&setups_dir, old.layer.as_deref())?;
        let replaced = self.remove_setup_locked(old, origin, now_ms).and_then(|_| {
            let between = self.current_generation()?;
            let installed =
                self.install_setup_locked(setup, &settled.profile, label, origin, now_ms)?;
            if let (Some(at), Some(name)) =
                (slot, installed.applied.as_ref().and_then(|applied| applied.library.as_ref()))
            {
                let label = format!("setup {}: keeps its place", setup.manifest.id);
                self.library_move_locked(name, at, &label, origin, now_ms)?;
            }
            Ok(Installed { before: between, ..installed })
        });
        match &replaced {
            Ok(installed) => {
                layers::drop_stash(stash);
                // The install step replaced (or removed) the old fonts in
                // place; an update to another id leaves the old folder
                // behind, so it goes.
                let old_fonts = fonts_entry(&old.id);
                if old_fonts != fonts_entry(new_id) {
                    let _ = fonts::remove(&self.roots().config_dir, &old_fonts);
                }
                // Its place in the order, until the caller records the new
                // receipt over it (by id).
                // The file as the remove left it (other setups' actions
                // spliced), with `old` back where it was.
                let mut file = self.read_setup_receipts()?;
                let at = receipts.setups.iter().position(|receipt| receipt.id == old.id);
                let mut held = old.clone();
                // Under the id the caller records the new receipt by, so
                // it replaces this one in place (a manifest whose id
                // changed leaves no second receipt behind).
                held.id = new_id.clone();
                held.library =
                    installed.applied.as_ref().and_then(|applied| applied.library.clone());
                held.layer = installed.layer.clone();
                held.on = true;
                let at = at.unwrap_or(0).min(file.setups.len());
                file.setups.insert(at, held);
                self.write_setup_receipts(&file)?;
            }
            Err(_) => {
                if let Some(layer) = &installed_layer_name(setup) {
                    let _ = layers::remove_layer(&setups_dir, layer);
                }
                let _ = layers::restore_stash(stash);
                let _ = self.library_write_back(library.as_deref());
                if let Some(n) = before {
                    let why = format!("setup {}: update failed", old.id);
                    let _ = self.restore_locked(n, Kind::Discarded, origin, &why, now_ms);
                }
                let _ = self.write_setup_receipts(&receipts);
            }
        }
        replaced
    }

    /// Checks `setup` whole and says what of its profile installs here: its
    /// settings migrated, and those this cmux has no setting for left out
    /// ([`crate::profile::settle_lenient`]). Everything else is all or
    /// nothing, as before: a bad value for a known setting, a setting only
    /// the person may change, a file or an action that does not check out
    /// refuses the whole setup.
    pub(crate) fn check_setup(&self, setup: &Setup) -> Result<Settled, Error> {
        let settled = crate::profile::settle_lenient(&setup.profile);
        self.check_profile(&settled.profile)?;
        check_actions(setup.actions())?;
        check::first_error(secrets::secret_findings(setup), Error::Setup)?;
        Ok(settled)
    }

    fn no_preview_open(&self) -> Result<(), Error> {
        if self.store().draft()?.is_some() {
            return Err(Error::Setup(
                "a preview is open: apply or discard it first (`cmux customize`)".to_owned(),
            ));
        }
        Ok(())
    }

    /// `profile` is `setup`'s as [`Customize::check_setup`] settled it.
    fn install_setup_locked(
        &self,
        setup: &Setup,
        profile: &Profile,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Installed, Error> {
        let id = &setup.manifest.id;
        let layer_name = layers::name(id);
        if let Some(other) = self
            .read_setup_receipts()?
            .setups
            .iter()
            .find(|receipt| &receipt.id != id && receipt.layer.as_deref() == Some(&layer_name))
        {
            return Err(Error::Setup(format!(
                "{id} and the installed setup {} would share the views layer {layer_name}; remove it first",
                other.id
            )));
        }
        let (profile, views) = layers::split_views(profile);
        let had = self.library_names()?;
        // The fonts first, so a theme file never points at fonts that are not
        // there; until `keep`, a failed step puts the earlier ones back.
        let config_dir = &self.roots().config_dir;
        let entry = fonts_entry(&setup.manifest.id);
        let staged_fonts = fonts::install(config_dir, &entry, &setup.fonts)?;
        self.preview_profile_locked(&profile, origin, now_ms)?;
        let mut prior_actions = BTreeMap::new();
        if !setup.actions().is_empty() {
            let mut text = settings_text(self)?;
            let file = jsonc::parse(&text).unwrap_or(Value::Null);
            let mut receipts = self.read_setup_receipts()?;
            let mut disowned = false;
            for (name, value) in setup.actions() {
                let path = action_path(name);
                let current = cmux_config::value::value_at(&file, &path).cloned();
                let (prior, disown) = action_base_at_install(&receipts.setups, id, name, current);
                if disown {
                    // You changed it after the setups that set it: it is
                    // yours now, and none of them puts it back on remove.
                    for other in receipts.setups.iter_mut().filter(|other| &other.id != id) {
                        other.actions.remove(name);
                        other.prior_actions.remove(name);
                    }
                    disowned = true;
                }
                prior_actions.insert(name.clone(), prior);
                text = jsonc::set(&text, &path, value).map_err(settings_error)?;
            }
            tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
            if disowned {
                self.write_setup_receipts(&receipts)?;
            }
        }
        let applied = self.apply_locked(Some(label), origin, now_ms)?;
        match staged_fonts {
            Some(staged) => staged.keep(),
            // An update that no longer carries fonts: the old copy goes.
            None => {
                fonts::remove(config_dir, &entry)?;
            }
        }
        let applied = applied.recorded.then_some(applied);
        // An apply that matched an entry you already had names that entry:
        // it is yours, and removing the setup only turns it off.
        let library_created = applied
            .as_ref()
            .and_then(|applied| applied.library.as_ref())
            .is_some_and(|name| !had.contains(name));
        let layer = layers::write_layer(&self.roots().setups_dir(), id, &views)?;
        Ok(Installed { applied, before: None, prior_actions, library_created, layer })
    }

    /// Undoes an installed setup, and only it: its library entry off (and
    /// removed when the install made it; what was under it comes back), its
    /// views layer deleted, its actions out (or back to yours), its receipt
    /// dropped. An action you changed since stays as it is; one another
    /// installed setup also sets stays that setup's (the topmost one's), and
    /// only an action no other setup sets goes back to what was there before
    /// the setups. Your own customize folder
    /// and every other setup's layer are not touched. Extensions are the
    /// caller's (it names them in the receipt).
    pub fn remove_setup(
        &self,
        receipt: &Receipt,
        origin: &str,
        now_ms: u64,
    ) -> Result<Removed, Error> {
        self.no_preview_open()?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let removed = self.remove_setup_locked(receipt, origin, now_ms)?;
        fonts::remove(&self.roots().config_dir, &fonts_entry(&receipt.id))?;
        Ok(removed)
    }

    fn remove_setup_locked(
        &self,
        receipt: &Receipt,
        origin: &str,
        now_ms: u64,
    ) -> Result<Removed, Error> {
        // The files its layer held: a theme file among them that the
        // settings still name once it is gone is cleared below.
        let layer_files = match &receipt.library {
            Some(name) => self.library_entry_files(name)?.unwrap_or_default(),
            None => Vec::new(),
        };
        let library = match &receipt.library {
            Some(name) if self.library_names()?.contains(name) => {
                self.library_take_off_locked(name, receipt.library_created, origin, now_ms)?;
                Some(name.clone())
            }
            _ => None,
        };
        let mut file = self.read_setup_receipts()?;
        file.setups.retain(|old| old.id != receipt.id);
        let mut actions = Vec::new();
        let mut kept_actions = Vec::new();
        let mut shared_actions = Vec::new();
        let mut changed = false;
        if !receipt.actions.is_empty() {
            let mut text = settings_text(self)?;
            let settings = jsonc::parse(&text).unwrap_or(Value::Null);
            for (name, value) in &receipt.actions {
                let path = action_path(name);
                let current = cmux_config::value::value_at(&settings, &path);
                match action_after_remove(&file.setups, receipt, name, value, current) {
                    ActionAfterRemove::Yours => kept_actions.push(name.clone()),
                    ActionAfterRemove::Owned(None) => shared_actions.push(name.clone()),
                    ActionAfterRemove::Owned(Some(top)) => {
                        text = jsonc::set(&text, &path, &top).map_err(settings_error)?;
                        changed = true;
                        shared_actions.push(name.clone());
                    }
                    ActionAfterRemove::Base(base) => {
                        let edit = match base {
                            Some(prior) => jsonc::set(&text, &path, &prior),
                            None => jsonc::remove(&text, &path),
                        };
                        text = edit.map_err(settings_error)?;
                        changed = true;
                        actions.push(name.clone());
                    }
                }
                // Every setup still setting it puts back the same value on
                // its last remove: what was there before any setup set it.
                let base = action_base(&file.setups, Some(receipt), name);
                for other in file.setups.iter_mut().filter(|other| other.actions.contains_key(name))
                {
                    other.prior_actions.insert(name.clone(), base.clone());
                }
            }
            if changed {
                tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
            }
        }
        // A theme file its layer took away that the settings still name.
        let cleared_theme = self.clear_removed_theme_file(&layer_files)?;
        if changed || cleared_theme {
            let label = format!("setup {}: removed", receipt.id);
            self.apply_locked(Some(&label), origin, now_ms)?;
        }
        self.write_setup_receipts(&file)?;
        if let Some(layer) = &receipt.layer {
            layers::remove_layer(&self.roots().setups_dir(), layer)?;
        }
        Ok(Removed {
            id: receipt.id.clone(),
            library,
            layer: receipt.layer.clone(),
            actions,
            kept_actions,
            shared_actions,
        })
    }
}

/// What a remove does with one of the removed setup's actions.
#[derive(Debug, PartialEq)]
enum ActionAfterRemove {
    /// You changed it since: it stays as it is.
    Yours,
    /// Another installed setup sets it: the topmost one's value, written
    /// when it differs from what is there (`None`: it is there already).
    Owned(Option<Value>),
    /// No other setup sets it: what was there before any setup did
    /// (`None`: nothing, the action comes out).
    Base(Option<Value>),
}

/// Action `name` once `removed` (which set it to `value`) is off, with
/// `remaining` the other receipts, top first, and `current` what the
/// settings file holds. Ownership goes by the order: the topmost remaining
/// setup that sets it wins, whatever its value; only when none does is
/// what was there before the setups put back. Never by matching values
/// alone, so two setups that set the same action never undo each other.
fn action_after_remove(
    remaining: &[Receipt],
    removed: &Receipt,
    name: &str,
    value: &Value,
    current: Option<&Value>,
) -> ActionAfterRemove {
    let owners: Vec<&Value> =
        remaining.iter().filter_map(|other| other.actions.get(name)).collect();
    let set_by_a_setup = current == Some(value) || owners.iter().any(|own| Some(*own) == current);
    if !set_by_a_setup {
        return ActionAfterRemove::Yours;
    }
    match owners.first() {
        Some(top) if Some(*top) == current => ActionAfterRemove::Owned(None),
        Some(top) => ActionAfterRemove::Owned(Some((*top).clone())),
        None => ActionAfterRemove::Base(action_base(remaining, Some(removed), name)),
    }
}

/// What action `name` was before any of the setups that set it (`also`
/// included) did. Each records it as its prior; a receipt file from before
/// that rule chains them instead (a prior that is another setup's value),
/// so the prior that is no setup's value wins, then any.
fn action_base(receipts: &[Receipt], also: Option<&Receipt>, name: &str) -> Option<Value> {
    let members: Vec<&Receipt> =
        receipts.iter().chain(also).filter(|receipt| receipt.actions.contains_key(name)).collect();
    let priors = members.iter().filter_map(|receipt| receipt.prior_actions.get(name));
    let mut first = None;
    for prior in priors {
        let is_a_setup_value = prior.as_ref().is_some_and(|prior| {
            members.iter().any(|member| member.actions.get(name) == Some(prior))
        });
        if !is_a_setup_value {
            return prior.clone();
        }
        first.get_or_insert(prior);
    }
    first.cloned().flatten()
}

/// What setup `id` records as the prior of action `name` it is about to
/// set over `current`, and whether the setups that set it before lose it.
/// When one of them is what is there, the prior is what was there before
/// any of them (so every receipt names the same one); when none is, you
/// changed it since: your value is the prior, and they disown it.
fn action_base_at_install(
    receipts: &[Receipt],
    id: &str,
    name: &str,
    current: Option<Value>,
) -> (Option<Value>, bool) {
    let others: Vec<Receipt> = receipts
        .iter()
        .filter(|receipt| receipt.id != id && receipt.actions.contains_key(name))
        .cloned()
        .collect();
    if others.is_empty() {
        return (current, false);
    }
    if others.iter().any(|other| other.actions.get(name) == current.as_ref()) {
        return (action_base(&others, None, name), false);
    }
    (current, true)
}

/// The views layer `setup` installs as, when it carries views.
fn installed_layer_name(setup: &Setup) -> Option<String> {
    setup
        .profile
        .files
        .keys()
        .any(|path| layers::is_view(path))
        .then(|| layers::name(&setup.manifest.id))
}

fn settings_error(error: jsonc::JsoncError) -> Error {
    Error::Setup(format!("your settings file: {}", crate::redact::text(&error.to_string())))
}

fn settings_text(customize: &Customize) -> Result<String, Error> {
    let bytes = tree::read(customize.roots(), SETTINGS)?.unwrap_or_default();
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Ok(if text.trim().is_empty() { "{}\n".to_owned() } else { text })
}

fn action_path(name: &str) -> Vec<String> {
    vec!["actions".to_owned(), name.to_owned()]
}

fn action_kind(value: &Value) -> &str {
    match value.get("type").and_then(Value::as_str) {
        Some(kind) => kind,
        None if value.get("agent").is_some() => "agent",
        None => "command",
    }
}

fn action_runs(value: &Value) -> String {
    let field = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default();
    match action_kind(value) {
        "agent" if !field("args").is_empty() => format!("{} {}", field("agent"), field("args")),
        "agent" => field("agent").to_owned(),
        _ => field("command").to_owned(),
    }
}

/// What install refuses in the header: the id rule, `engines.cmux`, a
/// hidden character in its text, and its extensions.
fn header_findings(manifest: &Manifest, owner: &str, running: &str) -> Vec<Finding> {
    let mut findings = Vec::new();
    let refused = |code: &'static str, key: &str, error: Error| {
        Finding::error(code, SETUP_FILE, error.to_string()).key(key)
    };
    if let Err(error) = check_id(&manifest.id, owner) {
        findings.push(
            refused(codes::SETUP_ID, "id", error)
                .fix(format!("set id to \"{}/NAME\" in lowercase", owner.to_ascii_lowercase())),
        );
    }
    if let Err(error) = engine_ok(manifest.engines.cmux.as_deref(), running) {
        findings.push(refused(codes::SETUP_ENGINES, "engines.cmux", error));
    }
    let texts = [("name", &manifest.name), ("description", &manifest.description)]
        .into_iter()
        .chain(manifest.tagline.as_ref().map(|tagline| ("tagline", tagline)));
    for (key, text) in texts {
        if let Some(mark) = hidden::first_hidden(text, hidden::Context::ManifestString) {
            findings.push(
                Finding::error(
                    codes::HIDDEN_TEXT,
                    SETUP_FILE,
                    format!(
                        "the setup's name or description has {} ({})",
                        mark.describe(),
                        mark.code_point
                    ),
                )
                .key(key),
            );
        }
    }
    if manifest.extensions.len() > MAX_EXTENSIONS {
        findings.push(
            Finding::error(
                codes::EXTENSION,
                SETUP_FILE,
                format!("a setup lists at most {MAX_EXTENSIONS} extensions"),
            )
            .key("extensions"),
        );
    }
    for (n, extension) in manifest.extensions.iter().enumerate() {
        if let Err(error) = Reference::parse(extension) {
            findings.push(refused(codes::EXTENSION, &format!("extensions.{n}"), error));
        }
    }
    findings
}

/// Every action is a named object cmux reads (`type` command or agent, with
/// its command or agent), with no hidden character and no secret.
fn check_actions(actions: &BTreeMap<String, Value>) -> Result<(), Error> {
    check::first_error(action_findings(actions), Error::Setup)
}

fn action_findings(actions: &BTreeMap<String, Value>) -> Vec<Finding> {
    let mut findings = Vec::new();
    let refuse = |name: &str, code: &'static str, message: String| {
        Finding::error(code, SETUP_FILE, message).key(format!("actions.{name}"))
    };
    if actions.len() > MAX_ACTIONS {
        findings.push(
            Finding::error(
                codes::ACTION_INVALID,
                SETUP_FILE,
                format!("a setup adds at most {MAX_ACTIONS} actions"),
            )
            .key("actions"),
        );
    }
    for (name, value) in actions {
        let named = !name.is_empty()
            && name.len() <= 64
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
        if !named {
            findings.push(refuse(
                name,
                codes::ACTION_INVALID,
                format!("the action name {name:?} is not letters, digits, '.', '-' and '_'"),
            ));
            continue;
        }
        let Some(fields) = value.as_object() else {
            findings.push(refuse(
                name,
                codes::ACTION_INVALID,
                format!("the action {name} is not an object"),
            ));
            continue;
        };
        let text = value.to_string();
        if text.len() > MAX_ACTION_BYTES {
            findings.push(refuse(
                name,
                codes::ACTION_INVALID,
                format!("the action {name} is larger than 16 KB"),
            ));
            continue;
        }
        if let Some(mark) = hidden::first_hidden(&text, hidden::Context::ManifestString) {
            findings.push(refuse(
                name,
                codes::HIDDEN_TEXT,
                format!("the action {name} has {} ({})", mark.describe(), mark.code_point),
            ));
        }
        if find_secret(&text).is_some() {
            findings.push(refuse(
                name,
                codes::SECRET,
                format!("the action {name} looks like it holds a secret"),
            ));
        }
        let string = |key: &str| {
            fields.get(key).and_then(Value::as_str).is_some_and(|s| !s.trim().is_empty())
        };
        let ok = match action_kind(value) {
            "command" => string("command"),
            "agent" => string("agent"),
            _ => false,
        };
        if !ok {
            findings.push(
                refuse(
                    name,
                    codes::ACTION_INVALID,
                    format!(
                        "the action {name} needs type \"command\" with a command, or type \"agent\" with an agent"
                    ),
                )
                .fix(r#"{ "type": "command", "command": "..." } or { "type": "agent", "agent": "..." }"#),
            );
        }
    }
    findings
}

#[cfg(test)]
mod tests;
