//! Reading a shared collection (a file, a link or one profile) before
//! import checks it.

use serde_json::Value;

use super::text::redact_serde;
use super::{COLLECTION_VERSION, Collection, Entry, MAX_COLLECTION_BYTES, Thumbnail};
use crate::profile::Profile;
use crate::{Customize, Error};

impl Customize {
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
                    on_ms: None,
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
}
