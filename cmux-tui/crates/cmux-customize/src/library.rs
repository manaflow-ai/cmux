//! The library: every customization you kept, saved by itself, each one a
//! small profile you turn on and off, stacked in an order you choose.
//!
//! ```text
//! <state dir>/library.json   the entries, top first, and the base
//! ```
//!
//! How it fills: every apply (an asked-for change, a profile or recipe you
//! used, hand edits you applied, a try-on you kept) is saved as one entry
//! holding only what that apply changed, as a `cmuxProfile` (the same
//! format `save` writes and `use` reads), with the words that asked for it.
//! Nothing is saved by hand.
//!
//! How it stacks: entries are layers, top first. A setting or file that two
//! entries that are on both set takes the value of the higher one;
//! [`Listing::conflicts`] names every such key, which entry wins and which
//! lose. A key no entry that is on sets has its **base** value: what it was
//! before the library first touched it. So turning an entry off puts back
//! what is under it, and turning the last one off puts back your own value.
//!
//! What a toggle writes: only the keys and files whose stacked value the
//! toggle changes, so a setting you changed by hand that no toggle touches
//! stays yours; one you changed by hand that no entry sets becomes its new
//! base. Every toggle is one applied generation, so `rollback` undoes it.
//! A toggle while a preview is open is refused: the preview is someone's
//! ask in progress, and it is applied or discarded first.
//!
//! How it travels: a collection (`{"cmuxCollection": 1, ...}`) is a list of
//! entries, each with its profile, whether it is on, and the words that made
//! it. Import checks every profile whole, as `use` checks one, before it
//! writes anything; a file with one bad entry writes nothing.
//!
//! The thumbnail is a light one: the colors an entry sets (as swatches) and
//! the keys it sets. cmux has no capture of a customization's look to keep.

use std::collections::{BTreeMap, BTreeSet};

use cmux_app_manifest::hidden;
use cmux_config::{Schema, jsonc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::profile::{Profile, shareable_settings, valid_name};
use crate::redact::find_secret;
use crate::store::{Draft, Generation, Kind};
use crate::tree::{self, Part, SETTINGS, Tree};
use crate::{Customize, Error, validate};

pub mod code;
pub mod overlay;
pub mod recover;
mod text;

use code::WebTarget;
pub use code::{CodeKind, CodeLayer, WEB_KEY, WebBase};
pub use overlay::Overlay;
pub use recover::{ActiveLayer, Layers, Recovered};
pub use text::thumbnail;
use text::{one_line, redact_serde, slug, unique_name};

/// The collection format version this cmux reads and writes.
pub const COLLECTION_VERSION: u32 = 1;
/// The most entries one collection or library holds.
pub const MAX_ENTRIES: usize = 500;
/// The largest collection file import reads.
pub const MAX_COLLECTION_BYTES: usize = 8 * 1024 * 1024;
const MAX_WORDS: usize = 20;

/// What a library entry looks like at a glance: the colors it sets and the
/// keys it sets. Computed from the profile, never read from a file.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Thumbnail {
    /// `#rrggbb` (or `#rgb`) colors the entry sets, first seen first.
    #[serde(default)]
    pub swatches: Vec<String>,
    /// The settings keys and file paths it sets.
    #[serde(default)]
    pub keys: Vec<String>,
}

/// One entry: a profile and how it is used.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    #[serde(default)]
    pub on: bool,
    /// How it came in: `ask`, `profile`, `try-on`, `by hand`, `import`.
    #[serde(default)]
    pub source: String,
    /// The words that asked for it, oldest first.
    #[serde(default)]
    pub words: Vec<String>,
    #[serde(default)]
    pub thumbnail: Thumbnail,
    pub profile: Profile,
    /// When it came into this library (local only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added_ms: Option<u64>,
    /// The generation it was saved from (local only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<u32>,
    /// Code not in your build (`source` "pr", "branch", "sha", "dir", "fork"): its web part is the
    /// stack key `code:web` ([`code`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<CodeLayer>,
}

impl Entry {
    pub fn name(&self) -> &str {
        &self.profile.name
    }

    fn same_content(&self, other: &Profile, code: Option<&CodeLayer>) -> bool {
        self.profile.settings == other.settings
            && self.profile.files == other.files
            && match (&self.code, code) {
                (Some(mine), Some(theirs)) => mine.same_source(theirs),
                (None, None) => true,
                _ => false,
            }
    }

    /// The layer folder this entry serves while it is on and on top, when it
    /// has a web part.
    fn web_layer(&self) -> Option<&CodeLayer> {
        self.code.as_ref().filter(|code| code.has_web())
    }
}

/// A shareable set of entries: one file or one link.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Collection {
    #[serde(rename = "cmuxCollection")]
    pub version: u32,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    /// Top first: an entry wins over every entry after it.
    #[serde(default)]
    pub entries: Vec<Entry>,
}

/// What each key the library manages was before the library set it.
/// `None`: it was not there.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Base {
    #[serde(default)]
    pub settings: BTreeMap<String, Option<Value>>,
    #[serde(default)]
    pub files: BTreeMap<String, Option<String>>,
    /// web-dev.json's `overlay` and `enabled` before a code entry came on;
    /// `None` while no code entry is on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub web: Option<WebBase>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
struct LibraryFile {
    version: u32,
    /// Top first.
    entries: Vec<Entry>,
    base: Base,
}

/// One entry as a list shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Listed {
    /// 1 is the top: it wins over every entry below it.
    pub position: usize,
    pub name: String,
    pub on: bool,
    pub source: String,
    pub words: Vec<String>,
    pub description: String,
    pub thumbnail: Thumbnail,
    pub settings: Vec<String>,
    pub files: Vec<String>,
    pub added_ms: Option<u64>,
    /// Keys and files this entry sets that a higher entry that is on sets
    /// too, so this one's value is not the one in use.
    pub overridden: Vec<String>,
    /// The code a code entry is (absent for every other entry, so a
    /// reader that does not know it is unaffected).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<CodeLayer>,
}

/// Two or more entries that are on set the same key or file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Conflict {
    /// `setting`, `file` or `code`.
    pub kind: &'static str,
    pub key: String,
    /// The highest entry that sets it: its value is the one in use.
    pub winner: String,
    /// The others, top first.
    pub losers: Vec<String>,
}

/// The library as every surface shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Listing {
    pub entries: Vec<Listed>,
    pub conflicts: Vec<Conflict>,
}

/// What a change to the library did.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Changed {
    pub library: Listing,
    /// The applied generation the change made; `None` when nothing live
    /// changed (an entry that was off was removed, say).
    pub generation: Option<Generation>,
    /// Unapplied hand edits were kept as this generation first.
    pub by_hand: Option<u32>,
    /// Settings keys and files whose value changed on disk.
    pub changed: Vec<String>,
}

/// What an import did.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Imported {
    pub added: Vec<String>,
    /// Entries the library already had (same settings and files).
    pub already: Vec<String>,
    /// Entries renamed because the library had another entry by that name:
    /// `(from, to)`.
    pub renamed: Vec<(String, String)>,
    pub change: Changed,
}

/// Where an entry moves to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Position {
    Top,
    Bottom,
    /// 1 is the top.
    At(usize),
}

impl Customize {
    fn library_path(&self) -> std::path::PathBuf {
        self.roots().state_dir.join("library.json")
    }

    fn read_library(&self) -> Result<LibraryFile, Error> {
        let path = self.library_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(LibraryFile { version: 1, ..LibraryFile::default() });
            }
            Err(error) => return Err(error.into()),
        };
        serde_json::from_str(&text).map_err(|error| {
            Error::Library(format!(
                "{}: not a cmux library (line {}, column {})",
                path.display(),
                error.line(),
                error.column()
            ))
        })
    }

    fn write_library(&self, library: &mut LibraryFile) -> Result<(), Error> {
        // A key no entry sets any more is no longer the library's.
        let (settings, files) = referenced(&library.entries);
        library.base.settings.retain(|key, _| settings.contains(key));
        library.base.files.retain(|path, _| files.contains(path));
        library.version = 1;
        let mut text = serde_json::to_string_pretty(library).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.library_path(), text.as_bytes())?;
        Ok(())
    }

    /// The entries, top first, and every conflict among those that are on.
    pub fn library(&self) -> Result<Listing, Error> {
        Ok(listing(&self.read_library()?.entries))
    }

    /// Saves what applied generation `generation` changed from its parent as
    /// a new entry on top, turned on (it is live). Called by `apply` with the
    /// draft's words, and by a kept try-on. `None` when it changed nothing a
    /// profile can carry, or the same change is already an entry (moved to
    /// the top and turned on). The caller holds the store's lock.
    pub(crate) fn remember_locked(
        &self,
        generation: &Generation,
        draft: Option<&Draft>,
        now_ms: u64,
    ) -> Result<Option<String>, Error> {
        let words: Vec<String> = match draft {
            Some(draft) if !draft.asks.is_empty() => {
                draft.asks.iter().map(|ask| ask.text.clone()).collect()
            }
            _ => vec![generation.label.clone()],
        };
        let source = match draft {
            None => "by hand",
            Some(draft)
                if draft.asks.first().is_some_and(|ask| ask.text.starts_with("profile ")) =>
            {
                "profile"
            }
            Some(_) => "ask",
        };
        self.remember_generation_locked(generation, source, words, now_ms)
    }

    /// [`Customize::remember_locked`] with the source and words given.
    pub(crate) fn remember_generation_locked(
        &self,
        generation: &Generation,
        source: &str,
        words: Vec<String>,
        now_ms: u64,
    ) -> Result<Option<String>, Error> {
        let new = self.store().tree(generation.n)?;
        let old = match generation.parent {
            Some(parent) => self.store().tree(parent).unwrap_or_default(),
            None => return Ok(None),
        };
        let (profile, base) = self.delta(&old, &new)?;
        if profile.settings.is_empty() && profile.files.is_empty() {
            return Ok(None);
        }
        let mut library = self.read_library()?;
        if let Some(at) =
            library.entries.iter().position(|entry| entry.same_content(&profile, None))
        {
            let mut entry = library.entries.remove(at);
            entry.on = true;
            let name = entry.name().to_owned();
            library.entries.insert(0, entry);
            self.write_library(&mut library)?;
            return Ok(Some(name));
        }
        let words: Vec<String> =
            words.into_iter().map(|word| one_line(&word)).filter(|w| !w.is_empty()).collect();
        let name = unique_name(&library.entries, &slug(words.first().map_or("", String::as_str)));
        let profile = Profile {
            name: name.clone(),
            description: one_line(&words.join("; ")),
            created_ms: now_ms,
            ..profile
        };
        for (key, value) in base.settings {
            library.base.settings.entry(key).or_insert(value);
        }
        for (path, text) in base.files {
            library.base.files.entry(path).or_insert(text);
        }
        library.entries.insert(
            0,
            Entry {
                on: true,
                source: source.to_owned(),
                words: words.into_iter().take(MAX_WORDS).collect(),
                thumbnail: thumbnail(&profile),
                profile,
                added_ms: Some(now_ms),
                generation: Some(generation.n),
                code: None,
            },
        );
        self.write_library(&mut library)?;
        Ok(Some(name))
    }

    /// Turns entry `name` on or off, and makes the stack live.
    pub fn library_set_on(
        &self,
        name: &str,
        on: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let label = format!("library: {} {name}", if on { "on" } else { "off" });
        self.library_change(&label, origin, now_ms, |library| {
            let entry = find(&mut library.entries, name)?;
            if on && let Some(code) = entry.code.as_ref().filter(|code| !code.has_web()) {
                return Err(Error::Library(format!(
                    "{name} has nothing that applies to a running cmux; {}",
                    needs_build_line(code)
                )));
            }
            entry.on = on;
            Ok(())
        })
    }

    /// Puts code layer `layer` on top of the library as entry
    /// [`CodeLayer::name`] (`pr-N`, `branch-NAME`, ...), on when it has a web
    /// part, and makes the stack live. An entry for the same source is
    /// replaced (a newer head, a new base, a rebuilt folder), keeping its words.
    /// The layer's folder must be installed first ([`Customize::layer_dir`]).
    pub fn library_use_code(
        &self,
        layer: CodeLayer,
        words: Vec<String>,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let name = layer.name();
        let label = format!("library: use {name} ({})", short(&layer.head));
        self.library_change(&label, origin, now_ms, |library| {
            let old = library
                .entries
                .iter()
                .position(|entry| entry.code.as_ref().is_some_and(|c| c.same_source(&layer)));
            let mut words: Vec<String> =
                words.iter().map(|word| one_line(word)).filter(|w| !w.is_empty()).collect();
            let (name, added_ms) = match old {
                Some(at) => {
                    let old = library.entries.remove(at);
                    for word in old.words {
                        if !words.contains(&word) {
                            words.push(word);
                        }
                    }
                    (old.profile.name, old.added_ms.or(Some(now_ms)))
                }
                None => (unique_name(&library.entries, &name), Some(now_ms)),
            };
            let profile = Profile {
                version: 1,
                name,
                description: one_line(&layer.label()),
                created_ms: now_ms,
                settings: BTreeMap::new(),
                files: BTreeMap::new(),
            };
            let thumbnail = Thumbnail {
                swatches: Vec::new(),
                keys: if layer.has_web() { vec![WEB_KEY.to_owned()] } else { Vec::new() },
            };
            library.entries.insert(
                0,
                Entry {
                    on: layer.has_web(),
                    source: layer.kind.as_str().to_owned(),
                    words: words.into_iter().take(MAX_WORDS).collect(),
                    thumbnail,
                    profile,
                    added_ms,
                    generation: None,
                    code: Some(layer),
                },
            );
            if library.entries.len() > MAX_ENTRIES {
                return Err(Error::Library(format!(
                    "a library holds at most {MAX_ENTRIES} entries; remove some first"
                )));
            }
            Ok(())
        })
    }

    /// Puts `layer` into the code entry with its source, in place: the entry
    /// keeps its place in the stack, its name, its words and whether it is on
    /// (a refresh or a watch rebuild; `use` is what moves one to the top). One
    /// with nothing a running cmux can take is turned off.
    pub fn library_update_code(
        &self,
        layer: CodeLayer,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let label = format!("library: update {} ({})", layer.name(), short(&layer.head));
        self.library_change(&label, origin, now_ms, |library| {
            let entry = library
                .entries
                .iter_mut()
                .find(|entry| entry.code.as_ref().is_some_and(|c| c.same_source(&layer)))
                .ok_or_else(|| {
                    Error::Library(format!("no library entry is {}", layer.source_label()))
                })?;
            entry.profile.description = one_line(&layer.label());
            entry.thumbnail.keys =
                if layer.has_web() { vec![WEB_KEY.to_owned()] } else { Vec::new() };
            entry.on = entry.on && layer.has_web();
            entry.code = Some(layer);
            Ok(())
        })
    }

    /// Changes what entry `name` knows about its code (a settle's
    /// note) and, with `on`, turns it on or off, making the stack live.
    pub fn library_settle_code(
        &self,
        name: &str,
        note: &str,
        on: Option<bool>,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let label = format!("library: settle {name}");
        self.library_change(&label, origin, now_ms, |library| {
            let entry = find(&mut library.entries, name)?;
            let code = entry
                .code
                .as_mut()
                .ok_or_else(|| Error::Library(format!("{name} is not a code entry")))?;
            code.note = one_line(note);
            if let Some(on) = on {
                entry.on = on && entry.code.as_ref().is_some_and(CodeLayer::has_web);
            }
            Ok(())
        })
    }

    /// Moves entry `name` to `position`, and makes the stack live.
    pub fn library_order(
        &self,
        name: &str,
        position: Position,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let label = format!("library: move {name}");
        self.library_change(&label, origin, now_ms, |library| {
            find(&mut library.entries, name)?;
            let at = library.entries.iter().position(|entry| entry.name() == name).unwrap_or(0);
            let entry = library.entries.remove(at);
            let to = match position {
                Position::Top => 0,
                Position::Bottom => library.entries.len(),
                Position::At(n) => n.saturating_sub(1).min(library.entries.len()),
            };
            library.entries.insert(to, entry);
            Ok(())
        })
    }

    /// Removes entry `name`. One that was on is taken off first, so what is
    /// under it comes back.
    pub fn library_remove(&self, name: &str, origin: &str, now_ms: u64) -> Result<Changed, Error> {
        let label = format!("library: remove {name}");
        self.library_change(&label, origin, now_ms, |library| {
            find(&mut library.entries, name)?;
            library.entries.retain(|entry| entry.name() != name);
            Ok(())
        })
    }

    /// The library (or the entries that are on) as a collection to share.
    pub fn library_export(
        &self,
        name: &str,
        description: &str,
        only_on: bool,
    ) -> Result<Collection, Error> {
        let library = self.read_library()?;
        let entries = library
            .entries
            .into_iter()
            .filter(|entry| !only_on || entry.on)
            .map(|entry| Entry { added_ms: None, generation: None, ..entry })
            .collect();
        Ok(Collection {
            version: COLLECTION_VERSION,
            name: one_line(name),
            description: one_line(description),
            entries,
        })
    }

    /// Adds a collection's entries on top, in its order. They come in off,
    /// unless `turn_on`: then those the collection marks on are turned on
    /// and the stack is made live. Every entry is checked first; one that
    /// fails writes nothing.
    pub fn library_import(
        &self,
        collection: &Collection,
        turn_on: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Imported, Error> {
        self.check_collection(collection)?;
        let mut added = Vec::new();
        let mut already = Vec::new();
        let mut renamed = Vec::new();
        let label = format!(
            "library: import {}",
            if collection.name.is_empty() { "a collection" } else { &collection.name }
        );
        let live_settings = self.live_settings()?;
        let change = self.library_change(&label, origin, now_ms, |library| {
            let mut incoming = Vec::new();
            for entry in &collection.entries {
                let code = entry.code.as_ref();
                if library.entries.iter().any(|have| have.same_content(&entry.profile, code))
                    || incoming.iter().any(|have: &Entry| have.same_content(&entry.profile, code))
                {
                    already.push(entry.name().to_owned());
                    continue;
                }
                let mut taken: Vec<Entry> = library.entries.clone();
                taken.extend(incoming.iter().cloned());
                let name = unique_name(&taken, entry.name());
                if name != entry.name() {
                    renamed.push((entry.name().to_owned(), name.clone()));
                }
                let profile = Profile { name: name.clone(), ..entry.profile.clone() };
                // A key the library does not manage yet starts from what is
                // live now.
                for key in profile.settings.keys() {
                    if !library.base.settings.contains_key(key) {
                        let value = setting_value(&live_settings, key);
                        library.base.settings.insert(key.clone(), value);
                    }
                }
                for path in profile.files.keys() {
                    if !library.base.files.contains_key(path) {
                        let text = tree::read(self.roots(), path)?
                            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
                        library.base.files.insert(path.clone(), text);
                    }
                }
                added.push(name);
                incoming.push(Entry {
                    on: turn_on && entry.on,
                    source: "import".to_owned(),
                    words: entry.words.iter().map(|w| one_line(w)).take(MAX_WORDS).collect(),
                    thumbnail: thumbnail(&profile),
                    profile,
                    added_ms: Some(now_ms),
                    generation: None,
                    code: entry.code.clone(),
                });
            }
            if library.entries.len() + incoming.len() > MAX_ENTRIES {
                return Err(Error::Library(format!(
                    "a library holds at most {MAX_ENTRIES} entries; remove some first"
                )));
            }
            incoming.append(&mut library.entries);
            library.entries = incoming;
            Ok(())
        })?;
        Ok(Imported { added, already, renamed, change })
    }

    /// Reads a collection from its text, checking only its shape; import
    /// checks every profile.
    pub fn parse_collection(text: &str) -> Result<Collection, Error> {
        if text.len() > MAX_COLLECTION_BYTES {
            return Err(Error::Library(format!(
                "a collection is at most {} MiB",
                MAX_COLLECTION_BYTES / 1024 / 1024
            )));
        }
        let probe: Value = serde_json::from_str(text).map_err(|error| {
            Error::Library(format!(
                "not a cmux collection (line {}, column {})",
                error.line(),
                error.column()
            ))
        })?;
        // A single profile is a collection of one.
        if probe.get("cmuxProfile").is_some() {
            let profile: Profile = serde_json::from_value(probe)
                .map_err(|_| Error::Library("not a cmux profile".to_owned()))?;
            return Ok(Collection {
                version: COLLECTION_VERSION,
                name: profile.name.clone(),
                description: String::new(),
                entries: vec![Entry {
                    on: true,
                    source: "import".to_owned(),
                    words: Vec::new(),
                    thumbnail: Thumbnail::default(),
                    profile,
                    added_ms: None,
                    generation: None,
                    code: None,
                }],
            });
        }
        match probe.get("cmuxCollection").and_then(Value::as_u64) {
            Some(1) => {}
            Some(n) => {
                return Err(Error::Library(format!(
                    "this collection is format {n}; this cmux reads format {COLLECTION_VERSION}"
                )));
            }
            None => return Err(Error::Library("not a cmux collection".to_owned())),
        }
        // Where it stops reading, never what it read there.
        serde_json::from_value(probe).map_err(|error| {
            Error::Library(format!("not a cmux collection: {}", redact_serde(&error.to_string())))
        })
    }

    /// Every entry of `collection` is one `use` would take, and the set is
    /// one a library can hold.
    fn check_collection(&self, collection: &Collection) -> Result<(), Error> {
        if collection.version != COLLECTION_VERSION {
            return Err(Error::Library(format!(
                "this collection is format {}; this cmux reads format {COLLECTION_VERSION}",
                collection.version
            )));
        }
        if collection.entries.len() > MAX_ENTRIES {
            return Err(Error::Library(format!(
                "a collection holds at most {MAX_ENTRIES} entries"
            )));
        }
        for (i, entry) in collection.entries.iter().enumerate() {
            let which = format!("entry {} ({:?})", i + 1, entry.name());
            if !valid_name(entry.name()) {
                return Err(Error::Library(format!(
                    "{which}: a name is lowercase letters, digits, '-' and '_'"
                )));
            }
            self.check_profile(&entry.profile)
                .map_err(|error| Error::Library(format!("{which}: {error}")))?;
            for word in &entry.words {
                if let Some(mark) = hidden::first_hidden(word, hidden::Context::ManifestString) {
                    return Err(Error::Library(format!(
                        "{which}: its words have {} ({})",
                        mark.describe(),
                        mark.code_point
                    )));
                }
            }
            for text in entry.profile.files.values() {
                if let Some((line, what)) = find_secret(text) {
                    return Err(Error::Library(format!(
                        "{which}: a file's line {line} looks like a secret ({what})"
                    )));
                }
            }
        }
        Ok(())
    }

    /// Runs `edit` on the library, then makes the new stack live: writes
    /// the keys and files whose stacked value changed and records one
    /// applied generation. Nothing is written when `edit` or a check fails.
    fn library_change(
        &self,
        label: &str,
        origin: &str,
        now_ms: u64,
        edit: impl FnOnce(&mut LibraryFile) -> Result<(), Error>,
    ) -> Result<Changed, Error> {
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        let mut library = self.read_library()?;
        let before = library.entries.clone();
        edit(&mut library)?;
        // The web part: which layer web-dev.json serves after this change.
        let web_was = web_top(&before).map(|code| code.web.clone());
        let web_will = web_top(&library.entries).map(|code| code.web.clone());
        if let Some(key) = &web_will
            && web_was.as_ref() != Some(key)
            && !self.layer_ready(key)
        {
            let (label, again) = web_top(&library.entries)
                .map(|code| (code.source_label(), use_again(code)))
                .unwrap_or_default();
            return Err(Error::Library(format!(
                "{label}'s web layer is not on this computer; `{again}` fetches it"
            )));
        }
        let web_moves = web_was != web_will;
        let schema = Schema::embedded();
        let live_text = tree::read(self.roots(), SETTINGS)?
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
        let live_settings = live_text
            .as_deref()
            .map(|text| jsonc::parse(text).unwrap_or(Value::Null))
            .unwrap_or(Value::Null);
        // A key no entry that is on sets, changed by hand since: that value
        // is the person's own now, so it is what comes back under the stack.
        for (key, base) in library.base.settings.iter_mut() {
            if top(&before, |profile| profile.settings.get(key)).is_none() {
                let live = setting_value(&live_settings, key);
                if live != *base {
                    *base = live;
                }
            }
        }
        for (path, base) in library.base.files.iter_mut() {
            if top(&before, |profile| profile.files.get(path)).is_none() {
                let live = tree::read(self.roots(), path)?
                    .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
                if live != *base {
                    *base = live;
                }
            }
        }
        let was = stacked(&before, &library.base);
        let will = stacked(&library.entries, &library.base);
        let settings: Vec<(&String, &Option<Value>)> = will
            .settings
            .iter()
            .filter(|(key, value)| was.settings.get(*key) != Some(*value))
            .filter(|(key, value)| setting_value(&live_settings, key) != **value)
            .collect();
        let files: Vec<(&String, &Option<String>)> = will
            .files
            .iter()
            .filter(|(path, value)| was.files.get(*path) != Some(*value))
            .collect();
        let mut writes: BTreeMap<String, Option<Vec<u8>>> = BTreeMap::new();
        for (path, text) in &files {
            let now = tree::read(self.roots(), path)?;
            let then = text.as_ref().map(|text| text.as_bytes().to_vec());
            if now != then {
                writes.insert((*path).clone(), then);
            }
        }
        if !settings.is_empty() {
            let mut text = live_text.unwrap_or_default();
            if text.trim().is_empty() {
                text = "{}\n".to_owned();
            }
            for (key, value) in &settings {
                let row = schema.row(key).ok_or_else(|| {
                    Error::Library(format!("the setting {key} is not one this cmux has"))
                })?;
                text = match value {
                    Some(value) => jsonc::set(&text, &row.path, value),
                    None => jsonc::remove(&text, &row.path),
                }
                .map_err(|_| {
                    Error::Library(format!(
                        "your settings file could not take {key}; fix its syntax first"
                    ))
                })?;
            }
            writes.insert(SETTINGS.to_owned(), Some(text.into_bytes()));
        }
        let changed: Vec<String> = settings
            .iter()
            .map(|(key, _)| (*key).clone())
            .chain(writes.keys().filter(|path| *path != SETTINGS).cloned())
            .collect();
        let mut changed = changed;
        if web_moves {
            changed.push(WEB_KEY.to_owned());
        }
        if writes.is_empty() {
            if web_moves {
                self.move_web(&mut library, web_will.as_deref())?;
            }
            self.write_library(&mut library)?;
            return Ok(Changed {
                library: listing(&library.entries),
                generation: None,
                by_hand: None,
                changed,
            });
        }
        // A preview is someone's ask in progress: it is applied or
        // discarded before the library writes over the same files.
        if self.store().draft()?.is_some() {
            return Err(Error::Library(
                "a preview is open: apply or discard it first (`cmux customize apply` or `discard`), then change the library".to_owned(),
            ));
        }
        let scan = tree::scan(self.roots())?;
        let mut in_the_way: Vec<_> = writes
            .iter()
            .filter(|(_, bytes)| bytes.is_some())
            .filter_map(|(path, _)| tree::in_the_way(self.roots(), path, &scan.tree))
            .collect();
        let written: BTreeMap<String, Vec<u8>> = writes
            .iter()
            .filter_map(|(path, bytes)| bytes.clone().map(|bytes| (path.clone(), bytes)))
            .collect();
        in_the_way.extend(tree::not_kept(&written, &scan.tree));
        if !in_the_way.is_empty() {
            return Err(Error::Untracked(in_the_way));
        }
        let mut check = written;
        for path in scan.tree.keys() {
            if !writes.contains_key(path)
                && let Some(bytes) = tree::read(self.roots(), path)?
            {
                check.insert(path.clone(), bytes);
            }
        }
        let problems: Vec<_> = validate::problems(&check)
            .into_iter()
            .filter(|problem| writes.contains_key(&problem.path))
            .collect();
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
        }
        // Hand edits not yet in any generation are kept by number first, as
        // an ask keeps them.
        let mut index = self.store().index()?;
        let mut by_hand = None;
        if scan.tree != self.current_tree(&index)? {
            let tree = self.capture()?;
            by_hand = Some(
                self.record(
                    &mut index,
                    Kind::ByHand,
                    &tree,
                    "user",
                    "changes made by hand",
                    now_ms,
                )?
                .n,
            );
        }
        let manifest_last = |path: &String| path.starts_with("customize/cmux-app");
        let order = writes
            .iter()
            .filter(|(path, _)| !manifest_last(path) && *path != SETTINGS)
            .chain(writes.iter().filter(|(path, _)| manifest_last(path)))
            .chain(writes.iter().filter(|(path, _)| *path == SETTINGS));
        for (path, bytes) in order {
            match bytes {
                Some(bytes) => tree::write(self.roots(), path, bytes, false)?,
                None => tree::remove(self.roots(), path)?,
            }
        }
        if web_moves {
            self.move_web(&mut library, web_will.as_deref())?;
        }
        let tree = self.capture()?;
        let generation = self.record(&mut index, Kind::Applied, &tree, origin, label, now_ms)?;
        self.store().prune(&mut index)?;
        self.write_library(&mut library)?;
        Ok(Changed {
            library: listing(&library.entries),
            generation: Some(generation),
            by_hand,
            changed,
        })
    }

    /// Points web-dev.json at layer `key`, or back at what was there before
    /// the first code entry came on. The base is read when a layer first
    /// goes live and cleared when the last one goes.
    fn move_web(&self, library: &mut LibraryFile, key: Option<&str>) -> Result<(), Error> {
        match key {
            Some(key) => {
                if library.base.web.is_none() {
                    library.base.web = Some(self.web_dev_now()?);
                }
                let base = library.base.web.clone().unwrap_or_default();
                self.write_web_dev(&WebTarget::Layer(self.layer_dir(key)), &base)
            }
            None => {
                let base = library.base.web.take().unwrap_or_default();
                self.write_web_dev(&WebTarget::Base, &base)
            }
        }
    }

    fn live_settings(&self) -> Result<Value, Error> {
        Ok(tree::read(self.roots(), SETTINGS)?
            .map(|bytes| jsonc::parse(&String::from_utf8_lossy(&bytes)).unwrap_or(Value::Null))
            .unwrap_or(Value::Null))
    }

    /// What `new` changed from `old` that a profile can carry, and what
    /// those keys and files were in `old`.
    fn delta(&self, old: &Tree, new: &Tree) -> Result<(Profile, Base), Error> {
        let text = |tree: &Tree, path: &str| -> Result<Option<Vec<u8>>, Error> {
            match tree.get(path) {
                Some(entry) => Ok(Some(self.store().object(&entry.sha)?)),
                None => Ok(None),
            }
        };
        let mut profile = Profile {
            version: 1,
            name: String::new(),
            description: String::new(),
            created_ms: 0,
            settings: BTreeMap::new(),
            files: BTreeMap::new(),
        };
        let mut base = Base::default();
        if old.get(SETTINGS).map(|e| &e.sha) != new.get(SETTINGS).map(|e| &e.sha) {
            let read = |bytes: Option<Vec<u8>>| {
                String::from_utf8_lossy(&bytes.unwrap_or_default()).into_owned()
            };
            let old_text = read(text(old, SETTINGS)?);
            let new_text = read(text(new, SETTINGS)?);
            let (new_settings, _, _) = shareable_settings(&new_text);
            let old_file = jsonc::parse(&old_text).unwrap_or(Value::Null);
            for (key, value) in new_settings {
                let before = setting_value(&old_file, &key);
                if before.as_ref() != Some(&value) {
                    base.settings.insert(key.clone(), before);
                    profile.settings.insert(key, value);
                }
            }
        }
        for (path, entry) in new {
            if matches!(Part::of(path), Part::Settings | Part::Automations) {
                continue;
            }
            if old.get(path).is_some_and(|before| before.sha == entry.sha) {
                continue;
            }
            let Ok(now) = String::from_utf8(self.store().object(&entry.sha)?) else { continue };
            if find_secret(&now).is_some() {
                continue;
            }
            let before = match text(old, path)? {
                Some(bytes) => match String::from_utf8(bytes) {
                    Ok(text) => Some(text),
                    Err(_) => continue,
                },
                None => None,
            };
            base.files.insert(path.clone(), before);
            profile.files.insert(path.clone(), now);
        }
        Ok((profile, base))
    }
}

/// The value of setting `key` in a parsed settings file.
fn setting_value(file: &Value, key: &str) -> Option<Value> {
    let row = Schema::embedded().row(key)?;
    cmux_config::value::value_at(file, &row.path).cloned()
}

/// The highest entry that is on with a web part: the layer web-dev.json serves.
fn web_top(entries: &[Entry]) -> Option<&CodeLayer> {
    entries.iter().filter(|entry| entry.on).find_map(Entry::web_layer)
}

/// The `use` that fetches or builds `code`'s layer again.
fn use_again(code: &CodeLayer) -> String {
    let source = match code.kind {
        CodeKind::Pr => format!("pr:{}", code.pr),
        CodeKind::Branch => format!("branch:{}", code.source),
        CodeKind::Sha => format!("sha:{}", code.source),
        CodeKind::Dir => format!("dir:{}", code.source),
        CodeKind::Fork => code.source.clone(),
    };
    format!("cmux customize use {source}")
}

/// `needs a build: ...` for an entry with no web part.
fn needs_build_line(code: &CodeLayer) -> String {
    if code.needs_build.is_empty() {
        "it needs a build".to_owned()
    } else {
        format!("needs a build: {}", code.needs_build.join("; "))
    }
}

/// The first 12 characters of a commit.
fn short(sha: &str) -> &str {
    sha.get(..12).unwrap_or(sha)
}

/// The highest entry that is on whose profile `get` finds something in.
fn top<'a, T>(
    entries: &'a [Entry],
    get: impl Fn(&'a Profile) -> Option<&'a T>,
) -> Option<(&'a Entry, &'a T)> {
    entries
        .iter()
        .filter(|entry| entry.on)
        .find_map(|entry| get(&entry.profile).map(|v| (entry, v)))
}

/// Every key and file the stack decides: the top on entry's value, or the
/// base.
struct Stacked {
    settings: BTreeMap<String, Option<Value>>,
    files: BTreeMap<String, Option<String>>,
}

fn stacked(entries: &[Entry], base: &Base) -> Stacked {
    let settings = base
        .settings
        .iter()
        .map(|(key, under)| {
            let value = top(entries, |profile| profile.settings.get(key))
                .map(|(_, value)| Some(value.clone()))
                .unwrap_or_else(|| under.clone());
            (key.clone(), value)
        })
        .collect();
    let files = base
        .files
        .iter()
        .map(|(path, under)| {
            let value = top(entries, |profile| profile.files.get(path))
                .map(|(_, text)| Some(text.clone()))
                .unwrap_or_else(|| under.clone());
            (path.clone(), value)
        })
        .collect();
    Stacked { settings, files }
}

fn referenced(entries: &[Entry]) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut settings = BTreeSet::new();
    let mut files = BTreeSet::new();
    for entry in entries {
        settings.extend(entry.profile.settings.keys().cloned());
        files.extend(entry.profile.files.keys().cloned());
    }
    (settings, files)
}

fn listing(entries: &[Entry]) -> Listing {
    // Who sets what, among entries that are on, top first.
    let mut setters: BTreeMap<(&'static str, &str), Vec<&str>> = BTreeMap::new();
    for entry in entries.iter().filter(|entry| entry.on) {
        for key in entry.profile.settings.keys() {
            setters.entry(("setting", key.as_str())).or_default().push(entry.name());
        }
        for path in entry.profile.files.keys() {
            setters.entry(("file", path.as_str())).or_default().push(entry.name());
        }
        if entry.web_layer().is_some() {
            setters.entry(("code", WEB_KEY)).or_default().push(entry.name());
        }
    }
    let conflicts: Vec<Conflict> = setters
        .iter()
        .filter_map(|((kind, key), names)| {
            let (winner, losers) = names.split_first()?;
            (!losers.is_empty()).then(|| Conflict {
                kind,
                key: (*key).to_owned(),
                winner: (*winner).to_owned(),
                losers: losers.iter().map(|name| (*name).to_owned()).collect(),
            })
        })
        .collect();
    let listed = entries
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let overridden = conflicts
                .iter()
                .filter(|conflict| entry.on && conflict.losers.iter().any(|n| n == entry.name()))
                .map(|conflict| conflict.key.clone())
                .collect();
            Listed {
                position: i + 1,
                name: entry.name().to_owned(),
                on: entry.on,
                source: entry.source.clone(),
                words: entry.words.clone(),
                description: entry.profile.description.clone(),
                thumbnail: entry.thumbnail.clone(),
                settings: entry.profile.settings.keys().cloned().collect(),
                files: entry.profile.files.keys().cloned().collect(),
                added_ms: entry.added_ms,
                overridden,
                code: entry.code.clone(),
            }
        })
        .collect();
    Listing { entries: listed, conflicts }
}

fn find<'a>(entries: &'a mut [Entry], name: &str) -> Result<&'a mut Entry, Error> {
    let names: Vec<String> = entries.iter().map(|entry| entry.name().to_owned()).collect();
    entries.iter_mut().find(|entry| entry.name() == name).ok_or_else(|| {
        let hint = if names.is_empty() {
            "the library is empty".to_owned()
        } else {
            "`cmux customize library` lists them".to_owned()
        };
        Error::Library(format!("there is no library entry {name:?}; {hint}"))
    })
}
