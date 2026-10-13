//! Value domains only the Mac app knows (theme names, installed font
//! families, sound names). The app publishes them; the owner validates
//! against them. A domain that was never published (a headless host) checks
//! the shape only.

use std::collections::BTreeSet;

use serde::Serialize;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Domains {
    pub themes: Option<BTreeSet<String>>,
    pub font_families: Option<BTreeSet<String>>,
    pub sounds: Option<BTreeSet<String>>,
}

impl Domains {
    /// Domains from published lists. An empty list counts as not published,
    /// so a client that knows nothing cannot make every value invalid.
    pub fn published(
        themes: Vec<String>,
        font_families: Vec<String>,
        sounds: Vec<String>,
    ) -> Domains {
        fn set(values: Vec<String>) -> Option<BTreeSet<String>> {
            (!values.is_empty()).then(|| values.into_iter().collect())
        }
        Domains { themes: set(themes), font_families: set(font_families), sounds: set(sounds) }
    }
}
