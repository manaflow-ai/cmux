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

use cmux_config::{Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::redact::{self, find_secret};
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
        let scan = tree::scan(self.roots())?;
        let mut live = BTreeMap::new();
        for path in scan.tree.keys() {
            if let Some(bytes) = tree::read(self.roots(), path)? {
                live.insert(path.clone(), bytes);
            }
        }
        let problems = validate::problems(&live);
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
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
                    let text = String::from_utf8_lossy(bytes);
                    let file = jsonc::parse(&text).unwrap_or(Value::Null);
                    let mut private = 0;
                    let mut credentials = Vec::new();
                    for row in &Schema::embedded().rows {
                        let url = matches!(row.kind, cmux_config::schema::Kind::Url);
                        match cmux_config::value::value_at(&file, &row.path) {
                            // A setting an agent may set can still hold a
                            // credential (a page URL with a password in it).
                            Some(value)
                                if row.agent_settable
                                    && (redact::sensitive_value(value, url)
                                        || find_secret(&value.to_string()).is_some()) =>
                            {
                                credentials.push(row.key.clone());
                            }
                            Some(value) if row.agent_settable => {
                                profile.settings.insert(row.key.clone(), value.clone());
                            }
                            Some(_) => private += 1,
                            None => {}
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
        read_profile(&path)
    }

    /// Makes a profile live as a draft: nothing is recorded until the person
    /// applies it. The whole profile is checked first (every path is one a
    /// part owns, every setting is one an agent may set and a value its row
    /// accepts, every file validates); one failure writes nothing.
    pub fn preview_profile(
        &self,
        profile: &Profile,
        origin: &str,
        now_ms: u64,
    ) -> Result<Begun, Error> {
        if profile.version != 1 {
            return Err(Error::Profile(format!(
                "this profile is format {}; this cmux reads format 1",
                profile.version
            )));
        }
        let schema = Schema::embedded();
        for (key, value) in &profile.settings {
            let row = schema.row(key).ok_or_else(|| {
                Error::Profile(format!("the setting {key} is not one this cmux has"))
            })?;
            if !row.agent_settable {
                return Err(Error::Profile(format!(
                    "the setting {key} is one only you can change; a profile may not set it"
                )));
            }
            if cmux_config::schema::accepts(row, value, &Default::default()).is_err() {
                // The key says where to look; the refused value (which may be
                // a credential under the wrong key) stays in the file.
                return Err(Error::Profile(format!(
                    "the profile's value for {key} is not one that setting accepts"
                )));
            }
        }
        // One import at a time, from the first read to the last write: two
        // that merged into the same settings text would each write theirs
        // and the later one would drop the other's keys, in no generation.
        let _lock = self.store().lock()?;
        let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        for (path, text) in &profile.files {
            // Only a path the scan reads: anything else (a dot file like
            // `customize/.env`) would be overwritten with no generation
            // holding what was there.
            let owned = tree::tracked(self.roots(), path)
                && !matches!(Part::of(path), Part::Settings | Part::Automations);
            if !owned {
                return Err(Error::Profile(format!("{path}: a profile may not write there")));
            }
            files.insert(path.clone(), text.as_bytes().to_vec());
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
        let in_the_way: Vec<_> =
            files.keys().filter_map(|path| tree::in_the_way(self.roots(), path, &live)).collect();
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
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
        }
        // An open draft's files are in no generation yet, and this writes
        // over some of them: they are kept by number first, so rollback
        // brings them back.
        let label = format!("the preview before the profile {}", profile.name);
        self.keep_draft_locked(&label, origin, now_ms)?;
        let begun = self.begin_locked(&format!("profile {}", profile.name), origin, now_ms)?;
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

fn read_profile(path: &std::path::Path) -> Result<Profile, Error> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| Error::Profile(format!("{}: {error}", path.display())))?;
    // Where it stops reading, never what it read there: the parser's own
    // message quotes the value it did not expect.
    serde_json::from_str::<Profile>(&text).map_err(|error| {
        Error::Profile(format!(
            "{}: not a cmux profile (line {}, column {})",
            path.display(),
            error.line(),
            error.column()
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_profile_name_is_a_plain_file_name() {
        assert!(valid_name("compact-night"));
        assert!(valid_name("v2_work"));
        for bad in ["", "../x", "Night", "a b", "-x", "a/b", "x.json"] {
            assert!(!valid_name(bad), "{bad}");
        }
    }
}
