//! Profiles: one portable file that holds a setup, so it can be saved under
//! a name, put in a dotfiles repo, sent to someone, and previewed on the
//! real window before it applies.
//!
//! Portable by construction (the ricing lessons, cmuxterm-hq#8750 items 4
//! and 5): settings travel one key at a time and only the keys an agent may
//! set, so no credential and no machine policy is in the file; files travel
//! by logical path, never an absolute one; a text that looks like a secret
//! stops the save. Applying one is a draft like any other: it is validated
//! whole before a byte is written, it previews live, and it is applied or
//! discarded by the person.

use std::collections::BTreeMap;
use std::path::PathBuf;

use cmux_app_manifest::hidden;
use cmux_config::migrations::{self, Notice};
use cmux_config::{Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::library::keys::{self, KEYBINDINGS};
use crate::redact::{self, find_secret};
use crate::setup::check::{Finding, codes, first_error};
use crate::tree::{self, Part, SETTINGS};
use crate::{Begun, Customize, Error, validate};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    /// The format version, 1.
    #[serde(rename = "cmuxProfile")]
    pub version: u32,
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(default)]
    pub created_ms: u64,
    /// Settings by dotted key.
    #[serde(default)]
    pub settings: BTreeMap<String, Value>,
    /// Whole text files by logical path (`themes/night.json`).
    #[serde(default)]
    pub files: BTreeMap<String, String>,
}

impl Profile {
    /// This profile with every key an older cmux named differently under
    /// its new name, and a removed key left out
    /// (`cmux_config::migrations`), and what changed.
    pub fn migrated(&self) -> (Profile, Vec<Notice>) {
        let (settings, notices) = migrations::migrate_dotted(&self.settings);
        (Profile { settings, ..self.clone() }, notices)
    }
}

/// A setting a setup sets that this cmux leaves out at install.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Skipped {
    pub key: String,
    pub reason: String,
}

/// A profile as it installs here: migrated, and (for a setup) without the
/// keys this cmux does not have.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Settled {
    pub profile: Profile,
    /// Keys it named by an older name, rewritten or left out.
    pub notices: Vec<Notice>,
    /// Keys this cmux has no setting for, left out.
    pub skipped: Vec<Skipped>,
}

/// `profile` migrated, with every key this cmux's schema does not have taken
/// out and listed. A setup is lenient at install (it may be written for a
/// newer cmux, or use a key a later cmux removed and this one never had);
/// a known key with a bad value, or one only the person may set, is still
/// refused by [`Customize::check_profile`].
pub(crate) fn settle_lenient(profile: &Profile) -> Settled {
    let (mut profile, notices) = profile.migrated();
    let schema = Schema::embedded();
    let mut skipped = Vec::new();
    profile.settings.retain(|key, _| {
        let known = schema.row(key).is_some();
        if !known {
            skipped.push(Skipped {
                key: key.clone(),
                reason: "this cmux has no setting by that name (a newer cmux may)".to_owned(),
            });
        }
        known
    });
    Settled { profile, notices, skipped }
}

/// What a save wrote.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Saved {
    pub name: String,
    pub path: PathBuf,
    pub settings: usize,
    pub files: Vec<String>,
    /// What is not in the file, and why, one line each.
    pub left_out: Vec<String>,
}

/// A saved profile, for a list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Listed {
    pub name: String,
    pub path: PathBuf,
    pub description: String,
    pub settings: usize,
    pub files: usize,
}

/// A profile name is a file name: lowercase letters, digits, `-` and `_`.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
        })
        && name.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
}

impl Customize {
    /// Saves what is live now as the profile `name`. The live tree must
    /// validate, as for an apply.
    pub fn save_profile(&self, name: &str, description: &str, now_ms: u64) -> Result<Saved, Error> {
        if !valid_name(name) {
            return Err(Error::Profile(format!(
                "{name:?}: a profile name is lowercase letters, digits, '-' and '_' (like \"compact-night\")"
            )));
        }
        let (profile, left_out) = self.shareable_profile(name, description, now_ms)?;
        let path = self.roots().profiles_dir().join(format!("{name}.json"));
        let mut text = serde_json::to_string_pretty(&profile).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&path, text.as_bytes())?;
        Ok(Saved {
            name: name.to_owned(),
            path,
            settings: profile.settings.len(),
            files: profile.files.keys().cloned().collect(),
            left_out,
        })
    }

    /// What is live now as a profile to share, and what was left out of it
    /// (one line each). The live tree must validate, as for an apply. What
    /// `save` writes and `cmux setup export` puts in a setup repo.
    pub(crate) fn shareable_profile(
        &self,
        name: &str,
        description: &str,
        now_ms: u64,
    ) -> Result<(Profile, Vec<String>), Error> {
        let scan = tree::scan(self.roots())?;
        let mut live = BTreeMap::new();
        for path in scan.tree.keys() {
            if let Some(bytes) = tree::read(self.roots(), path)? {
                live.insert(path.clone(), bytes);
            }
        }
        let all = validate::problems(&live);
        // A value the schema refuses in the person's own settings does not
        // stop a save: that key is left out of the profile (and said so),
        // since no one could use a profile that carries it.
        let refused: Vec<String> =
            all.iter().filter_map(validate::Problem::refused_setting).map(str::to_owned).collect();
        let problems = validate::introduced(all.clone(), &all);
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
        }
        // The description is shared with the profile: it is held to the same
        // scans as a file, and refused rather than left out (it is the one
        // field the person typed for this save).
        if let Some((_, what)) = find_secret(description) {
            return Err(Error::Profile(format!(
                "the description looks like it holds a secret ({what}); a profile is for sharing"
            )));
        }
        if let Some(mark) = hidden::first_hidden(description, hidden::Context::ManifestString) {
            return Err(Error::Profile(format!(
                "the description has {} ({})",
                mark.describe(),
                mark.code_point
            )));
        }
        let mut profile = Profile {
            version: 1,
            name: name.to_owned(),
            description: description.trim().to_owned(),
            created_ms: now_ms,
            settings: BTreeMap::new(),
            files: BTreeMap::new(),
        };
        let mut left_out = Vec::new();
        let home = std::env::var("HOME").ok().filter(|home| home.len() > 1);
        for (path, bytes) in &live {
            match Part::of(path) {
                Part::Settings => {
                    let (settings, credentials, private) =
                        shareable_settings(&String::from_utf8_lossy(bytes));
                    profile.settings = settings;
                    for key in &refused {
                        if profile.settings.remove(key).is_some() {
                            left_out.push(format!(
                                "the setting {key}: its value is one this setting does not accept"
                            ));
                        }
                    }
                    for key in credentials {
                        left_out.push(format!(
                            "the setting {key}: its value carries a credential (a user, password or token)"
                        ));
                    }
                    if private > 0 {
                        left_out.push(format!(
                            "{} that only you can change (accounts, policy, this machine)",
                            crate::count(private, "setting")
                        ));
                    }
                }
                Part::Automations => {}
                _ => match std::str::from_utf8(bytes) {
                    // A profile is for sharing: a file with a credential
                    // in it stays here, and the answer says which line.
                    Ok(text) => match find_secret(text) {
                        Some((line, what)) => left_out.push(format!(
                            "{path}: line {line} looks like a secret ({what}); take it out of the file to share it"
                        )),
                        None => {
                            profile.files.insert(path.clone(), text.to_owned());
                        }
                    },
                    Err(_) => left_out.push(format!("{path} (not text)")),
                },
            }
        }
        let automations = live.keys().filter(|path| Part::of(path) == Part::Automations).count();
        if automations > 0 {
            left_out.push(format!(
                "{} (they name folders and accounts on this machine)",
                crate::count(automations, "automation")
            ));
        }
        for (path, text) in &profile.files {
            if home.as_ref().is_some_and(|home| text.contains(home.as_str())) {
                left_out.push(format!(
                    "note: {path} names your home folder, which another machine does not have"
                ));
            }
        }
        Ok((profile, left_out))
    }

    /// The saved profiles, by name.
    pub fn profiles(&self) -> Result<Vec<Listed>, Error> {
        let dir = self.roots().profiles_dir();
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.into()),
        };
        let mut listed = Vec::new();
        for entry in entries {
            let path = entry?.path();
            if path.extension().is_none_or(|extension| extension != "json") {
                continue;
            }
            let Ok(profile) = read_profile(&path) else { continue };
            listed.push(Listed {
                name: profile.name,
                description: profile.description,
                settings: profile.settings.len(),
                files: profile.files.len(),
                path,
            });
        }
        listed.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(listed)
    }

    /// Reads a profile by saved name, or from a file path.
    pub fn load_profile(&self, source: &str) -> Result<Profile, Error> {
        let path = if valid_name(source) {
            self.roots().profiles_dir().join(format!("{source}.json"))
        } else {
            PathBuf::from(source)
        };
        if path.file_name().is_some_and(|name| name == crate::setup::SETUP_FILE) {
            return crate::setup::read_dir(
                path.parent().unwrap_or_else(|| std::path::Path::new(".")),
            )
            .map(|setup| setup.profile);
        }
        read_profile(&path)
    }

    /// Checks a profile whole, writing nothing: its format, that every
    /// setting is one an agent may set with a value its row accepts, that
    /// every file is at a path a part owns and the scan reads, and that no
    /// name or description hides a character. What `use` and a library
    /// import check before a byte is written.
    pub(crate) fn check_profile(&self, profile: &Profile) -> Result<(), Error> {
        first_error(profile_findings(self.roots(), profile), Error::Profile)
    }

    /// Makes a profile live as a draft: nothing is recorded until the person
    /// applies it. The whole profile is checked first (every path is one a
    /// part owns, every setting is one an agent may set and a value its row
    /// accepts, every file validates); one failure writes nothing. A key an
    /// older cmux named differently is taken under its new name first
    /// ([`Profile::migrated`]); a key this cmux does not know is refused.
    pub fn preview_profile(
        &self,
        profile: &Profile,
        origin: &str,
        now_ms: u64,
    ) -> Result<Begun, Error> {
        let (profile, _) = profile.migrated();
        let profile = &profile;
        self.check_profile(profile)?;
        // One import at a time, from the first read to the last write: two
        // that merged into the same settings text would each write theirs
        // and the later one would drop the other's keys, in no generation.
        let _lock = self.store().lock()?;
        self.preview_profile_locked(profile, origin, now_ms)
    }

    /// [`Customize::preview_profile`] for a caller that holds the store's
    /// lock and goes on under it (a try-on applies what this wrote).
    pub(crate) fn preview_profile_locked(
        &self,
        profile: &Profile,
        origin: &str,
        now_ms: u64,
    ) -> Result<Begun, Error> {
        let (profile, _) = profile.migrated();
        let profile = &profile;
        self.check_profile(profile)?;
        let schema = Schema::embedded();
        let mut files: BTreeMap<String, Vec<u8>> = profile
            .files
            .iter()
            .map(|(path, text)| (path.clone(), text.as_bytes().to_vec()))
            .collect();
        // A profile's shortcuts are bindings to add, as its settings are keys
        // to set: they go into the file you have, which keeps your own.
        if let Some(text) = profile.files.get(KEYBINDINGS) {
            let live = tree::read(self.roots(), KEYBINDINGS)?
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
            let merged =
                keys::compose(live.as_deref(), &keys::winners(std::iter::once(text.as_str())))
                    .map_err(|_| {
                        Error::Profile(
                            "your keybindings.json is not a list of bindings; fix its syntax first"
                                .to_owned(),
                        )
                    })?;
            match merged {
                Some(merged) => files.insert(KEYBINDINGS.to_owned(), merged.into_bytes()),
                None => files.remove(KEYBINDINGS),
            };
        }
        let settings_text = if profile.settings.is_empty() {
            None
        } else {
            let current = tree::read(self.roots(), SETTINGS)?.unwrap_or_default();
            let mut text = String::from_utf8_lossy(&current).into_owned();
            if text.trim().is_empty() {
                text = "{}\n".to_owned();
            }
            for (key, value) in &profile.settings {
                let Some(row) = schema.row(key) else { continue };
                text = jsonc::set(&text, &row.path, value).map_err(|error| {
                    let why = redact::text(&error.to_string());
                    Error::Profile(format!("your settings file: {why}"))
                })?;
            }
            files.insert(SETTINGS.to_owned(), text.clone().into_bytes());
            Some(text)
        };
        // Files the profile does not carry still count for validation (a
        // manifest names a script the folder already has).
        let mut check = files.clone();
        let live = tree::scan(self.roots())?.tree;
        // Every place this writes is one the draft's base generation holds,
        // or is empty: a file too large to snapshot, one past the count the
        // scan keeps, or one behind a linked folder is never written over.
        let mut in_the_way: Vec<_> =
            files.keys().filter_map(|path| tree::in_the_way(self.roots(), path, &live)).collect();
        // And what it writes is something the next scan keeps: a file too
        // large, or one past the count a folder keeps, would be live in no
        // generation, so no discard or rollback could take it away.
        in_the_way.extend(tree::not_kept(&files, &live));
        if !in_the_way.is_empty() {
            return Err(Error::Untracked(in_the_way));
        }
        for path in live.keys() {
            if !check.contains_key(path)
                && let Some(bytes) = tree::read(self.roots(), path)?
            {
                check.insert(path.clone(), bytes);
            }
        }
        let problems: Vec<_> = validate::problems(&check)
            .into_iter()
            .filter(|problem| files.contains_key(&problem.path))
            .collect();
        // What the person's own files already hold that the schema refuses
        // (a value an older build wrote) is theirs and stays as written; only
        // what this profile brings stops it. "Already" is what the apply
        // after this will judge by, so a preview never writes what its apply
        // then refuses: with no preview open, the live files (the begin below
        // records them as a generation); with one open, the applied
        // generation (the open preview's edits are not the person's yet).
        let before = if self.store().draft()?.is_some() {
            self.settings_problems_in(&self.current_tree(&self.store().index()?)?)?
        } else {
            self.live_problems(files.keys())?
        };
        let problems = validate::introduced(problems, &before);
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
        }
        // An open draft's files are in no generation yet, and this writes
        // over some of them: they are kept by number first, so rollback
        // brings them back.
        let label = format!("the preview before the profile {}", profile.name);
        self.keep_draft_locked(&label, origin, now_ms)?;
        let begun = self.begin_locked(&format!("profile {}", profile.name), origin, now_ms)?;
        // The library entry this becomes says what the profile says it is.
        let description = profile.description.split_whitespace().collect::<Vec<_>>().join(" ");
        if !description.is_empty()
            && let Some(mut draft) = self.store().draft()?
            && let Some(ask) = draft.asks.last_mut()
        {
            ask.description = Some(description);
            self.store().put_draft(Some(&draft))?;
        }
        let manifest_last = |path: &String| path.starts_with("customize/cmux-app");
        for (path, bytes) in
            files.iter().filter(|(path, _)| !manifest_last(path) && *path != SETTINGS)
        {
            tree::write(self.roots(), path, bytes, false)?;
        }
        for (path, bytes) in files.iter().filter(|(path, _)| manifest_last(path)) {
            tree::write(self.roots(), path, bytes, false)?;
        }
        // Settings last: a theme the profile selects is on disk before the
        // key that selects it.
        if let Some(text) = settings_text {
            tree::write(self.roots(), SETTINGS, text.as_bytes(), false)?;
        }
        Ok(begun)
    }
}

/// The settings of a settings file that may travel in a profile: every key
/// an agent may set whose value carries no credential. Also the keys left
/// out for a credential, and how many set keys only the person may change.
pub(crate) fn shareable_settings(text: &str) -> (BTreeMap<String, Value>, Vec<String>, usize) {
    let file = jsonc::parse(text).unwrap_or(Value::Null);
    let mut settings = BTreeMap::new();
    let mut private = 0;
    let mut credentials = Vec::new();
    for row in &Schema::embedded().rows {
        let url = matches!(row.kind, cmux_config::schema::Kind::Url);
        match cmux_config::value::value_at(&file, &row.path) {
            // A setting an agent may set can still hold a credential (a page
            // URL with a password in it).
            Some(value)
                if row.agent_settable
                    && (redact::sensitive_value(value, url)
                        || find_secret(&value.to_string()).is_some()) =>
            {
                credentials.push(row.key.clone());
            }
            Some(value) if row.agent_settable => {
                settings.insert(row.key.clone(), value.clone());
            }
            Some(_) => private += 1,
            None => {}
        }
    }
    (settings, credentials, private)
}

/// Everything [`Customize::check_profile`] refuses in `profile`, in the order
/// it checks. `roots` only places paths (no file is read).
pub(crate) fn profile_findings(roots: &crate::Roots, profile: &Profile) -> Vec<Finding> {
    // A setup's profile is its `cmux-setup.json` (settings, header) and the
    // files beside it.
    let at = crate::setup::SETUP_FILE;
    let mut findings = Vec::new();
    if profile.version != 1 {
        findings.push(
            Finding::error(
                codes::SETUP_FORMAT,
                at,
                format!("this profile is format {}; this cmux reads format 1", profile.version),
            )
            .key("cmuxProfile"),
        );
    }
    let schema = Schema::embedded();
    for (key, value) in &profile.settings {
        let Some(row) = schema.row(key) else {
            let finding = Finding::error(
                codes::SETTING_UNKNOWN,
                at,
                format!("the setting {key} is not one this cmux has"),
            )
            .key(key.clone());
            findings.push(match crate::setup::check::nearest_key(key) {
                Some(near) => finding.fix(format!("did you mean {near}?")),
                None => finding.fix("`cmux settings list` names every setting"),
            });
            continue;
        };
        if !row.agent_settable {
            findings.push(
                Finding::error(
                    codes::SETTING_PRIVATE,
                    at,
                    format!(
                        "the setting {key} is one only you can change; a profile may not set it"
                    ),
                )
                .key(key.clone())
                .fix(format!("take {key} out; the person sets it on their machine")),
            );
            continue;
        }
        if cmux_config::schema::accepts(row, value, &Default::default()).is_err() {
            // The key says where to look; the refused value (which may be
            // a credential under the wrong key) stays in the file.
            findings.push(
                Finding::error(
                    codes::SETTING_VALUE,
                    at,
                    if key == "workspaceColors.indicatorStyle" {
                        "the profile's value for workspaceColors.indicatorStyle is invalid; use \"dot\", \"leftRail\" or \"fill\" (legacy \"solidFill\" is accepted)".to_owned()
                    } else {
                        format!("the profile's value for {key} is not one that setting accepts")
                    },
                )
                .key(key.clone()),
            );
        }
    }
    for (path, text) in &profile.files {
        // Only a path the scan reads: anything else (a dot file like
        // `customize/.env`) would be overwritten with no generation
        // holding what was there.
        let owned = tree::tracked(roots, path)
            && !matches!(Part::of(path), Part::Settings | Part::Automations);
        if !owned {
            findings.push(
                Finding::error(
                    codes::FILE_PLACE,
                    path,
                    format!("{path}: a profile may not write there"),
                )
                .fix("a setup writes keybindings.json, themes/NAME.json, customize/... and SURFACE/theme.css"),
            );
        } else if path == KEYBINDINGS && !keys::readable(text) {
            findings.push(Finding::error(
                codes::FILE_INVALID,
                path,
                format!(
                    "{path} in the profile is not a list of bindings ([{{ \"key\": ..., \"command\": ... }}])"
                ),
            ));
        }
        // A name that reads as something else is refused by position,
        // never shown: the path would carry the hidden character.
        if let Some(mark) = hidden::first_hidden(path, hidden::Context::ManifestString) {
            findings.push(Finding::error(
                codes::HIDDEN_TEXT,
                at,
                format!(
                    "a file name in the profile has {} ({}) at character {}",
                    mark.describe(),
                    mark.code_point,
                    mark.column
                ),
            ));
        }
    }
    if let Some(mark) = hidden::first_hidden(&profile.description, hidden::Context::ManifestString)
    {
        findings.push(
            Finding::error(
                codes::HIDDEN_TEXT,
                at,
                format!("the profile's description has {} ({})", mark.describe(), mark.code_point),
            )
            .key("description"),
        );
    }
    findings
}

fn read_profile(path: &std::path::Path) -> Result<Profile, Error> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| Error::Profile(format!("{}: {error}", path.display())))?;
    // Parse errors never quote a value, which might contain credentials.
    let invalid = |error: serde_json::Error| {
        Error::Profile(format!(
            "{}: not a cmux profile (line {}, column {})",
            path.display(),
            error.line(),
            error.column()
        ))
    };
    let original_error = match serde_json::from_str::<Profile>(&text) {
        Ok(profile) => return Ok(profile),
        Err(error) => error,
    };
    let mut value: Value = serde_json::from_str(&text).map_err(invalid)?;
    crate::file_refs::resolve(
        &mut value,
        path.parent().unwrap_or_else(|| std::path::Path::new(".")),
    )
    .map_err(Error::Profile)?;
    serde_json::from_value(value).map_err(|_| invalid(original_error))
}

#[cfg(test)]
#[path = "profile_tests.rs"]
mod tests;
