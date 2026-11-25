//! `library_put`: one named profile into the library as one change (the
//! community installs of themes and snippets use it).

use super::{
    COLLECTION_VERSION, Changed, Collection, Entry, MAX_ENTRIES, MAX_WORDS, one_line, thumbnail,
    tree,
};
use crate::profile::Profile;
use crate::{Customize, Error};

impl Customize {
    /// Puts `profile` in the library as the entry of its name, with `source`
    /// and `words`, and makes the stack live: one applied generation, so
    /// `rollback` and `library off`/`remove` undo it. An entry by that name
    /// is replaced (an update): it keeps its place and whether it is on,
    /// unless `top`, which moves it to the top, on. A new entry comes in on
    /// top, on. The profile is checked as an import checks one.
    pub fn library_put(
        &self,
        profile: Profile,
        source: &str,
        words: Vec<String>,
        top: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let name = profile.name.clone();
        let words: Vec<String> =
            words.iter().map(|w| one_line(w)).filter(|w| !w.is_empty()).take(MAX_WORDS).collect();
        let entry = Entry {
            on: true,
            source: source.to_owned(),
            words,
            thumbnail: thumbnail(&profile),
            profile,
            added_ms: Some(now_ms),
            generation: None,
            on_ms: Some(now_ms),
            until_ms: None,
            code: None,
        };
        self.check_collection(&Collection {
            version: COLLECTION_VERSION,
            name: String::new(),
            description: String::new(),
            entries: vec![entry.clone()],
        })?;
        let live_settings = self.live_settings()?;
        let label = format!("library: put {name}");
        self.library_change(&label, origin, now_ms, |library| {
            let live_file = (!live_settings.is_null()).then_some(&live_settings);
            for key in entry.profile.settings.keys() {
                if !library.base.settings.contains_key(key) {
                    library.base.note_setting(key, live_file);
                }
            }
            for path in entry.profile.files.keys() {
                if !library.base.files.contains_key(path) {
                    let text = tree::read(self.roots(), path)?
                        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
                    library.base.files.insert(path.clone(), text);
                }
            }
            match library.entries.iter().position(|have| have.name() == name) {
                Some(at) if !top => {
                    if let Some(have) = library.entries.get_mut(at) {
                        *have = Entry { on: have.on, ..entry };
                    }
                }
                Some(at) => {
                    library.entries.remove(at);
                    library.entries.insert(0, entry);
                }
                None if library.entries.len() >= MAX_ENTRIES => {
                    return Err(Error::Library(format!(
                        "a library holds at most {MAX_ENTRIES} entries; remove some first"
                    )));
                }
                None => library.entries.insert(0, entry),
            }
            Ok(())
        })
    }

    /// The names of the library's entries now.
    pub(crate) fn library_names(&self) -> Result<Vec<String>, Error> {
        Ok(self.read_library()?.entries.iter().map(|entry| entry.name().to_owned()).collect())
    }

    /// `library_remove` or `library_set_on(name, false)` for a caller that
    /// holds the store lock: what was under the entry comes back.
    pub(crate) fn library_take_off_locked(
        &self,
        name: &str,
        delete: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        let verb = if delete { "remove" } else { "off" };
        let label = format!("library: {verb} {name}");
        self.library_change_locked(&label, origin, now_ms, |library| {
            if delete {
                library.entries.retain(|entry| entry.name() != name);
            } else if let Some(entry) = library.entries.iter_mut().find(|e| e.name() == name) {
                entry.on = false;
            }
            Ok(())
        })
    }

    /// `library_set_on` for a caller that holds the store lock. An entry
    /// that is gone already is no change.
    pub(crate) fn library_set_on_locked(
        &self,
        name: &str,
        on: bool,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        self.library_change_locked(label, origin, now_ms, |library| {
            if let Some(entry) = library.entries.iter_mut().find(|e| e.name() == name) {
                entry.on = on;
            }
            Ok(())
        })
    }

    /// Puts the entries `order` names (top first) in that order among the
    /// places they hold now; every other entry keeps its place. For a
    /// caller that holds the store lock.
    pub(crate) fn library_reorder_locked(
        &self,
        order: &[String],
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        self.library_change_locked(label, origin, now_ms, |library| {
            let rank = |name: &str| order.iter().position(|named| named == name);
            let mut held: Vec<_> = library
                .entries
                .iter()
                .filter(|entry| rank(entry.name()).is_some())
                .cloned()
                .collect();
            held.sort_by_key(|entry| rank(entry.name()));
            let slots = library.entries.iter_mut().filter(|entry| rank(entry.name()).is_some());
            for (slot, entry) in slots.zip(held) {
                *slot = entry;
            }
            Ok(())
        })
    }

    /// Moves entry `name` to index `at` (0 is the top), for a caller that
    /// holds the store lock: an update keeps its setup's place.
    pub(crate) fn library_move_locked(
        &self,
        name: &str,
        at: usize,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        self.library_change_locked(label, origin, now_ms, |library| {
            if let Some(from) = library.entries.iter().position(|e| e.name() == name) {
                let entry = library.entries.remove(from);
                let to = at.min(library.entries.len());
                library.entries.insert(to, entry);
            }
            Ok(())
        })
    }

    /// The library file as it is now (`None`: there is none), to write back
    /// with [`Customize::library_write_back`] when a change made of several
    /// steps fails after one of them. Its entries and the base under them
    /// come back exactly, which removing and adding an entry again would not.
    pub(crate) fn library_snapshot(&self) -> Result<Option<Vec<u8>>, Error> {
        match std::fs::read(self.library_path()) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// Writes a [`Customize::library_snapshot`] back. The caller makes what
    /// is live match it (a generation restore).
    pub(crate) fn library_write_back(&self, snapshot: Option<&[u8]>) -> Result<(), Error> {
        let path = self.library_path();
        match snapshot {
            Some(bytes) => cmux_config::fsio::write_atomic(&path, bytes)?,
            None => match std::fs::remove_file(&path) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(error.into());
                }
                _ => {}
            },
        }
        Ok(())
    }

    /// The file paths entry `name`'s profile holds (`None`: no such entry).
    pub(crate) fn library_entry_files(&self, name: &str) -> Result<Option<Vec<String>>, Error> {
        Ok(self
            .read_library()?
            .entries
            .iter()
            .find(|entry| entry.name() == name)
            .map(|entry| entry.profile.files.keys().cloned().collect()))
    }

    /// The value entry `name`'s profile gives setting `key` (`None`: no such
    /// entry, or it does not set it).
    pub(crate) fn library_entry_setting(
        &self,
        name: &str,
        key: &str,
    ) -> Result<Option<serde_json::Value>, Error> {
        Ok(self
            .read_library()?
            .entries
            .iter()
            .find(|entry| entry.name() == name)
            .and_then(|entry| entry.profile.settings.get(key).cloned()))
    }

    /// Sets `key` to `value` inside entry `name`'s own profile, for a caller
    /// that holds the store lock: the entry's layer carries it, so turning
    /// the entry off (or removing it) takes it off with the rest. One
    /// applied generation, as any toggle.
    pub(crate) fn library_entry_set_locked(
        &self,
        name: &str,
        key: &str,
        value: serde_json::Value,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Changed, Error> {
        self.library_change_locked(label, origin, now_ms, |library| {
            let entry = library
                .entries
                .iter_mut()
                .find(|entry| entry.name() == name)
                .ok_or_else(|| Error::Library(format!("there is no library entry {name}")))?;
            entry.profile.settings.insert(key.to_owned(), value);
            Ok(())
        })
    }
}
