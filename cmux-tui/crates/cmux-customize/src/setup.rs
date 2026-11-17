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
//! Installing one is a profile import like any other: checked whole before a
//! byte is written, applied as one generation that the library keeps as one
//! entry, so removing it takes off exactly that layer. What the setup did is
//! kept as a [`Receipt`] in `<state dir>/setups.json`, which `update` and
//! `remove` read. Fetching the repo and installing its extensions belong to
//! the caller (the CLI); this module reads a folder and writes files.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_app_manifest::hidden;
use cmux_config::{Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::profile::Profile;
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
}

impl Setup {
    pub fn actions(&self) -> &BTreeMap<String, Value> {
        &self.manifest.actions
    }
}

mod reference;
pub use reference::Reference;
use reference::plain;

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
    let file = dir.join(SETUP_FILE);
    let metadata = std::fs::symlink_metadata(&file).map_err(|_| {
        Error::Setup(format!("there is no {SETUP_FILE} at the root, so this is not a cmux setup"))
    })?;
    if !metadata.is_file() || metadata.len() > MAX_SETUP_FILE_BYTES {
        return Err(Error::Setup(format!("{SETUP_FILE} is not a file under 1 MB")));
    }
    let text = std::fs::read_to_string(&file)
        .map_err(|error| Error::Setup(format!("{SETUP_FILE}: {error}")))?;
    let value = jsonc::parse(&text)
        .map_err(|error| Error::Setup(format!("{SETUP_FILE} is not JSON: {error}")))?;
    let manifest: Manifest = serde_json::from_value(value).map_err(|error| {
        Error::Setup(format!("{SETUP_FILE} is not a cmux setup: {}", strip_value(&error)))
    })?;
    if manifest.format != FORMAT {
        return Err(Error::Setup(format!(
            "this setup is format {}; this cmux reads format {FORMAT}",
            manifest.format
        )));
    }
    let mut files = manifest.files.clone();
    for (path, text) in repo_files(dir)? {
        if files.insert(path.clone(), text).is_some() {
            return Err(Error::Setup(format!(
                "{path} is both in {SETUP_FILE}'s files and in the repo; keep one"
            )));
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
        let canonical =
            serde_json::to_vec(&(&manifest.settings, &manifest.actions, &profile.files))
                .map_err(std::io::Error::other)?;
        tree::sha256(&canonical)
    };
    Ok(Setup { manifest, profile, sha256 })
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

/// The customization files a setup repo holds at their logical paths.
fn repo_files(dir: &Path) -> Result<BTreeMap<String, String>, Error> {
    let mut found = BTreeMap::new();
    let mut take = |logical: String, file: &Path| -> Result<(), Error> {
        let metadata = std::fs::symlink_metadata(file)?;
        if metadata.file_type().is_symlink() {
            return Err(Error::Setup(format!("{logical} is a link; a setup holds plain files")));
        }
        if !metadata.is_file() {
            return Ok(());
        }
        if metadata.len() > MAX_FILE_BYTES {
            return Err(Error::Setup(format!("{logical} is larger than 2 MB")));
        }
        let text = String::from_utf8(std::fs::read(file)?)
            .map_err(|_| Error::Setup(format!("{logical} is not text")))?;
        found.insert(logical, text);
        Ok(())
    };
    let keys = dir.join("keybindings.json");
    if keys.exists() || std::fs::symlink_metadata(&keys).is_ok() {
        take("keybindings.json".to_owned(), &keys)?;
    }
    for surface in STYLE_SURFACES {
        let css = dir.join(surface).join("theme.css");
        if std::fs::symlink_metadata(&css).is_ok() {
            take(format!("{surface}/theme.css"), &css)?;
        }
    }
    for part in ["themes", "customize"] {
        let mut listed = Vec::new();
        walk(&dir.join(part), part, &mut listed)?;
        if listed.len() > MAX_FILES_PER_PART {
            return Err(Error::Setup(format!(
                "{part}/ holds more than {MAX_FILES_PER_PART} files"
            )));
        }
        for (logical, file) in listed {
            if part == "themes" && !logical.ends_with(".json") {
                continue;
            }
            take(logical, &file)?;
        }
    }
    Ok(found)
}

fn walk(dir: &Path, logical: &str, out: &mut Vec<(String, PathBuf)>) -> Result<(), Error> {
    let metadata = match std::fs::symlink_metadata(dir) {
        Ok(metadata) => metadata,
        Err(_) => return Ok(()),
    };
    if metadata.file_type().is_symlink() {
        return Err(Error::Setup(format!("{logical} is a link; a setup holds plain files")));
    }
    if !metadata.is_dir() {
        return Ok(());
    }
    let mut entries: Vec<_> = std::fs::read_dir(dir)?.collect::<Result<_, _>>()?;
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
        if entry.file_type()?.is_dir() {
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
    /// A file of yours at that path that it changes.
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
}

/// An installed setup, as `update` and `remove` read it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Receipt {
    pub id: String,
    pub name: String,
    pub reference: Reference,
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
    /// The actions it set, and what each replaced (`null`: none).
    #[serde(default)]
    pub actions: BTreeMap<String, Value>,
    #[serde(default)]
    pub prior_actions: PriorActions,
    #[serde(default)]
    pub extensions: Vec<ExtensionReceipt>,
    pub installed_ms: u64,
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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ReceiptsFile {
    #[serde(default)]
    setups: Vec<Receipt>,
}

/// What a remove put back.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Removed {
    pub id: String,
    /// The library entry taken off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub library: Option<String>,
    /// Actions taken out or put back to yours.
    pub actions: Vec<String>,
    /// Actions left as they are: you changed them after the install.
    pub kept_actions: Vec<String>,
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

    fn write_setup_receipts(&self, file: &ReceiptsFile) -> Result<(), Error> {
        let mut text = serde_json::to_string_pretty(file).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.setup_receipts_path(), text.as_bytes())?;
        Ok(())
    }

    /// The installed setups, newest first.
    pub fn setups(&self) -> Result<Vec<Receipt>, Error> {
        Ok(self.read_setup_receipts()?.setups)
    }

    /// The installed setup `which` names: its reference (any form), or id.
    pub fn setup(&self, which: &str) -> Result<Option<Receipt>, Error> {
        let key = Reference::parse(which).ok().map(|reference| reference.key());
        Ok(self
            .setups()?
            .into_iter()
            .find(|receipt| receipt.id == which || Some(receipt.reference.key()) == key))
    }

    /// Keeps `receipt`, replacing one for the same repo.
    pub fn record_setup(&self, receipt: Receipt) -> Result<(), Error> {
        let _lock = self.store().lock()?;
        let mut file = self.read_setup_receipts()?;
        file.setups.retain(|old| old.reference.key() != receipt.reference.key());
        file.setups.insert(0, receipt);
        self.write_setup_receipts(&file)
    }

    /// Checks `setup` whole, writing nothing, and says what it would change.
    /// `owner` is the repo's owner (the id rule); `running` this cmux's
    /// version (`engines.cmux`).
    pub fn plan_setup(&self, setup: &Setup, owner: &str, running: &str) -> Result<Plan, Error> {
        let manifest = &setup.manifest;
        check_id(&manifest.id, owner)?;
        engine_ok(manifest.engines.cmux.as_deref(), running)?;
        for text in
            [&manifest.name, &manifest.description].into_iter().chain(manifest.tagline.as_ref())
        {
            if let Some(mark) = hidden::first_hidden(text, hidden::Context::ManifestString) {
                return Err(Error::Setup(format!(
                    "the setup's name or description has {} ({})",
                    mark.describe(),
                    mark.code_point
                )));
            }
        }
        if manifest.extensions.len() > MAX_EXTENSIONS {
            return Err(Error::Setup(format!("a setup lists at most {MAX_EXTENSIONS} extensions")));
        }
        for extension in &manifest.extensions {
            Reference::parse(extension)?;
        }
        self.check_profile(&setup.profile)?;
        check_actions(&manifest.actions)?;

        let live = tree::read(self.roots(), SETTINGS)?
            .map(|bytes| jsonc::parse(&String::from_utf8_lossy(&bytes)).unwrap_or(Value::Null))
            .unwrap_or(Value::Null);
        let schema = Schema::embedded();
        let settings = setup
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
            let mine = tree::read(self.roots(), path)?;
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
            theme: setup
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
        })
    }

    /// Applies `setup` as one generation (and one library entry): its
    /// profile through the same path `cmux customize use` takes, then its
    /// actions into the settings file, then apply. The caller showed the
    /// plan ([`Customize::plan_setup`]) and has the person's yes. A preview
    /// that is open is kept by number first, as a profile import keeps it.
    pub fn install_setup(
        &self,
        setup: &Setup,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Installed, Error> {
        self.check_profile(&setup.profile)?;
        check_actions(setup.actions())?;
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let before = self.current_generation()?;
        match self.install_setup_locked(setup, label, origin, now_ms) {
            Ok((applied, prior_actions)) => Ok(Installed { applied, before, prior_actions }),
            Err(error) => {
                // All or nothing: what was live before comes back (the preview
                // and a half-written settings file are kept as a discarded
                // generation, never lost).
                if let Some(n) = before {
                    let why = format!("setup {}: install failed", setup.manifest.id);
                    let _ = self.restore_locked(n, Kind::Discarded, origin, &why, now_ms);
                }
                Err(error)
            }
        }
    }

    /// Updates `old` to `setup` as one change: `old` comes off, `setup` goes
    /// on, and when the second step fails, `old` is put back as it was (its
    /// library entry, what was live, its receipt).
    pub fn replace_setup(
        &self,
        old: &Receipt,
        setup: &Setup,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Installed, Error> {
        self.check_profile(&setup.profile)?;
        check_actions(setup.actions())?;
        self.ensure_baseline(now_ms)?;
        let before = self.current_generation()?;
        let library = self.library_snapshot()?;
        let error = match self
            .remove_setup(old, origin, now_ms)
            .and_then(|_| self.install_setup(setup, label, origin, now_ms))
        {
            Ok(installed) => return Ok(installed),
            Err(error) => error,
        };
        // Back to exactly what was there: the library file, what was live
        // (what the failed steps wrote stays as a discarded generation), and
        // the old receipt.
        if let Ok(_lock) = self.store().lock() {
            let _ = self.library_write_back(library.as_deref());
            if let Some(n) = before {
                let why = format!("setup {}: update failed", old.id);
                let _ = self.restore_locked(n, Kind::Discarded, origin, &why, now_ms);
            }
        }
        let _ = self.record_setup(old.clone());
        Err(error)
    }

    fn install_setup_locked(
        &self,
        setup: &Setup,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<(Option<Applied>, PriorActions), Error> {
        self.preview_profile_locked(&setup.profile, origin, now_ms)?;
        let mut prior_actions = BTreeMap::new();
        if !setup.actions().is_empty() {
            let mut text = settings_text(self)?;
            let file = jsonc::parse(&text).unwrap_or(Value::Null);
            for (name, value) in setup.actions() {
                let path = action_path(name);
                prior_actions
                    .insert(name.clone(), cmux_config::value::value_at(&file, &path).cloned());
                text = jsonc::set(&text, &path, value).map_err(|error| {
                    Error::Setup(format!(
                        "your settings file: {}",
                        crate::redact::text(&error.to_string())
                    ))
                })?;
            }
            tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
        }
        let applied = self.apply_locked(Some(label), origin, now_ms)?;
        Ok((applied.recorded.then_some(applied), prior_actions))
    }

    /// Undoes an installed setup: its library entry off and removed (what
    /// was under it comes back), its actions out (or back to yours), its
    /// receipt dropped. An action you changed since stays as you left it.
    /// Extensions are the caller's (it names them in the receipt).
    pub fn remove_setup(
        &self,
        receipt: &Receipt,
        origin: &str,
        now_ms: u64,
    ) -> Result<Removed, Error> {
        if self.store().draft()?.is_some() {
            return Err(Error::Setup(
                "a preview is open: apply or discard it first (`cmux customize`)".to_owned(),
            ));
        }
        let library = match &receipt.library {
            Some(name) if self.library()?.entries.iter().any(|entry| &entry.name == name) => {
                self.library_remove(name, origin, now_ms)?;
                Some(name.clone())
            }
            _ => None,
        };
        let mut actions = Vec::new();
        let mut kept_actions = Vec::new();
        if !receipt.actions.is_empty() {
            let _lock = self.store().lock()?;
            let mut text = settings_text(self)?;
            let file = jsonc::parse(&text).unwrap_or(Value::Null);
            for (name, value) in &receipt.actions {
                let path = action_path(name);
                if cmux_config::value::value_at(&file, &path) != Some(value) {
                    kept_actions.push(name.clone());
                    continue;
                }
                let changed = match receipt.prior_actions.get(name).cloned().flatten() {
                    Some(prior) => jsonc::set(&text, &path, &prior),
                    None => jsonc::remove(&text, &path),
                };
                text = changed.map_err(|error| {
                    Error::Setup(format!(
                        "your settings file: {}",
                        crate::redact::text(&error.to_string())
                    ))
                })?;
                actions.push(name.clone());
            }
            if !actions.is_empty() {
                tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
                let label = format!("setup {}: removed", receipt.id);
                self.apply_locked(Some(&label), origin, now_ms)?;
            }
        }
        let _lock = self.store().lock()?;
        let mut file = self.read_setup_receipts()?;
        file.setups.retain(|old| old.reference.key() != receipt.reference.key());
        self.write_setup_receipts(&file)?;
        Ok(Removed { id: receipt.id.clone(), library, actions, kept_actions })
    }

    /// Writes what is live now as a setup repo in `dir` (empty, absent, or a
    /// setup repo already): [`SETUP_FILE`], the files at their logical
    /// paths, and a README with the install line and badge. What a profile
    /// leaves out (credentials, settings only you can change, automations)
    /// it leaves out, and says so.
    pub fn export_setup(
        &self,
        dir: &Path,
        header: &ExportHeader,
        now_ms: u64,
    ) -> Result<Exported, Error> {
        let (owner, _) = header.id.split_once('/').unwrap_or_default();
        check_id(&header.id, owner)?;
        for extension in &header.extensions {
            Reference::parse(extension)?;
        }
        if dir.exists() {
            let empty = std::fs::read_dir(dir)?
                .filter_map(Result::ok)
                .all(|entry| entry.file_name().to_string_lossy().starts_with('.'));
            if !empty && !dir.join(SETUP_FILE).is_file() {
                return Err(Error::Setup(format!(
                    "{} is not empty and is not a setup repo; name a new folder",
                    dir.display()
                )));
            }
        }
        let (profile, mut left_out) =
            self.shareable_profile(&profile_name(&header.id), &header.description, now_ms)?;
        let mut actions = BTreeMap::new();
        let live = settings_text(self)?;
        if let Some(Value::Object(found)) =
            jsonc::parse(&live).ok().and_then(|file| file.get("actions").cloned())
        {
            for (name, value) in found {
                if find_secret(&value.to_string()).is_some() {
                    left_out.push(format!("the action {name}: it looks like it holds a secret"));
                } else if check_actions(&BTreeMap::from([(name.clone(), value.clone())])).is_err() {
                    left_out.push(format!("the action {name}: not one a setup can carry"));
                } else {
                    actions.insert(name, value);
                }
            }
        }
        let repo = if header.repo.is_empty() { header.id.clone() } else { header.repo.clone() };
        let manifest = Manifest {
            format: FORMAT,
            id: header.id.clone(),
            name: header.name.clone(),
            tagline: None,
            description: header.description.clone(),
            version: Some("1.0.0".to_owned()),
            screenshots: Vec::new(),
            engines: Engines::default(),
            extensions: header.extensions.clone(),
            license: None,
            repository: Some(format!("https://github.com/{repo}")),
            profile_format: 1,
            settings: profile.settings.clone(),
            files: BTreeMap::new(),
            actions: actions.clone(),
        };
        std::fs::create_dir_all(dir)?;
        for (path, text) in &profile.files {
            if path.split('/').any(|piece| piece.is_empty() || piece == "." || piece == "..") {
                continue;
            }
            let file = dir.join(path);
            if let Some(parent) = file.parent() {
                std::fs::create_dir_all(parent)?;
            }
            cmux_config::fsio::write_atomic(&file, text.as_bytes())?;
        }
        let mut text = serde_json::to_string_pretty(&manifest).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&dir.join(SETUP_FILE), text.as_bytes())?;
        let readme = dir.join("README.md");
        if !readme.exists() {
            cmux_config::fsio::write_atomic(&readme, readme_text(&manifest, &repo).as_bytes())?;
        }
        Ok(Exported {
            dir: dir.to_path_buf(),
            id: header.id.clone(),
            settings: profile.settings.len(),
            files: profile.files.keys().cloned().collect(),
            actions: actions.keys().cloned().collect(),
            left_out,
            page_url: format!("https://cmux.com/setups/{repo}"),
        })
    }
}

/// The README `export` writes: what it is, how to install it, the badge.
pub fn readme_text(manifest: &Manifest, repo: &str) -> String {
    let mut text = format!(
        "# {}\n\n[![Get it on cmux]({BADGE_URL})](https://cmux.com/setups/{repo})\n\n",
        manifest.name
    );
    if !manifest.description.is_empty() {
        text.push_str(&manifest.description);
        text.push_str("\n\n");
    }
    text.push_str(&format!(
        "A cmux setup: a whole customization in one repo. Install it in one step:\n\n```sh\ncmux setup install github.com/{repo}\n```\n\n`cmux setup remove github.com/{repo}` puts back what you had.\n"
    ));
    if !manifest.extensions.is_empty() {
        text.push_str("\nExtensions it installs:\n\n");
        for extension in &manifest.extensions {
            text.push_str(&format!("- {extension}\n"));
        }
    }
    text
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

/// Every action is a named object cmux reads (`type` command or agent, with
/// its command or agent), with no hidden character and no secret.
fn check_actions(actions: &BTreeMap<String, Value>) -> Result<(), Error> {
    if actions.len() > MAX_ACTIONS {
        return Err(Error::Setup(format!("a setup adds at most {MAX_ACTIONS} actions")));
    }
    for (name, value) in actions {
        let named = !name.is_empty()
            && name.len() <= 64
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
        if !named {
            return Err(Error::Setup(format!(
                "the action name {name:?} is not letters, digits, '.', '-' and '_'"
            )));
        }
        let Some(fields) = value.as_object() else {
            return Err(Error::Setup(format!("the action {name} is not an object")));
        };
        let text = value.to_string();
        if text.len() > MAX_ACTION_BYTES {
            return Err(Error::Setup(format!("the action {name} is larger than 16 KB")));
        }
        if let Some(mark) = hidden::first_hidden(&text, hidden::Context::ManifestString) {
            return Err(Error::Setup(format!(
                "the action {name} has {} ({})",
                mark.describe(),
                mark.code_point
            )));
        }
        if find_secret(&text).is_some() {
            return Err(Error::Setup(format!("the action {name} looks like it holds a secret")));
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
            return Err(Error::Setup(format!(
                "the action {name} needs type \"command\" with a command, or type \"agent\" with an agent"
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
