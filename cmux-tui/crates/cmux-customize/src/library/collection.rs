//! A library's collections: export, import, and reading and checking one.

use cmux_app_manifest::hidden;
use serde_json::Value;

use super::text::{one_line, redact_serde, thumbnail, unique_name};
use super::{
    COLLECTION_VERSION, Collection, Entry, Imported, MAX_COLLECTION_BYTES, MAX_ENTRIES, MAX_WORDS,
    Thumbnail,
};
use crate::profile::{Profile, valid_name};
use crate::redact::find_secret;
use crate::tree;
use crate::{Customize, Error};

impl Customize {
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
                let live_file = (!live_settings.is_null()).then_some(&live_settings);
                for key in profile.settings.keys() {
                    if !library.base.settings.contains_key(key) {
                        library.base.note_setting(key, live_file);
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
}
