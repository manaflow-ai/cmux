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
}
