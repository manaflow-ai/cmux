//! The first-party wallpapers, embedded in the binary from `wallpapers/<id>/`
//! (build.rs), so the app gets the set without reading files. `smoke` is a
//! test sample: it is embedded but not shipped.

/// The test sample's folder; never shipped.
pub const SMOKE_ID: &str = "smoke";

/// One embedded wallpaper folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FirstParty {
    /// The folder name (the manifest's `id` must equal it).
    pub folder: &'static str,
    /// `wallpaper.json`.
    pub manifest_json: &'static str,
    /// `wallpaper.wgsl` (empty when the folder has none: a test refuses it).
    pub source: &'static str,
}

// `EMBEDDED` (every folder) and `SHIPPED` (without smoke), sorted by folder name.
include!(concat!(env!("OUT_DIR"), "/first_party.rs"));

/// The shipped set, sorted by folder name: every embedded folder but `smoke`.
pub fn first_party() -> &'static [FirstParty] {
    SHIPPED
}

/// The `smoke` sample (tests and the gallery's sanity check).
pub fn smoke() -> Option<&'static FirstParty> {
    EMBEDDED.iter().find(|w| w.folder == SMOKE_ID)
}

/// The shipped wallpaper at `index` in [`first_party`]'s order.
pub fn first_party_at(index: usize) -> Option<&'static FirstParty> {
    SHIPPED.get(index)
}

/// The shipped wallpaper whose folder (id) is `id`.
pub fn first_party_by_id(id: &str) -> Option<&'static FirstParty> {
    SHIPPED.iter().find(|w| w.folder == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Manifest, compile};

    #[test]
    fn smoke_is_embedded_but_not_shipped() {
        let s = smoke().expect("wallpapers/smoke");
        assert!(!s.source.is_empty());
        assert!(first_party().iter().all(|w| w.folder != SMOKE_ID));
        assert_eq!(first_party().len(), EMBEDDED.len() - 1);
    }

    /// Every folder under wallpapers/ (smoke too): the manifest is valid, its
    /// id is the folder's name, its shader is wallpaper.wgsl, and the program
    /// compiles to Metal and GLSL. A wallpaper added later is checked here
    /// without a test of its own.
    #[test]
    fn every_first_party_wallpaper_compiles() {
        let mut failures = Vec::new();
        for w in EMBEDDED {
            let m = match Manifest::parse(w.manifest_json.as_bytes()) {
                Ok(m) => m,
                Err(e) => {
                    failures.push(format!("{}/wallpaper.json: {e}", w.folder));
                    continue;
                }
            };
            if m.id != w.folder {
                failures.push(format!("{}: id {:?} is not the folder's name", w.folder, m.id));
            }
            if m.shader != "wallpaper.wgsl" {
                failures.push(format!(
                    "{}: shader must be wallpaper.wgsl, not {:?}",
                    w.folder, m.shader
                ));
            }
            if w.source.is_empty() {
                failures.push(format!("{}: no wallpaper.wgsl", w.folder));
                continue;
            }
            if let Err(e) = compile(w.source) {
                failures.push(format!("{}/wallpaper.wgsl:{e}", w.folder));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn lookups_agree() {
        for (i, w) in first_party().iter().enumerate() {
            assert_eq!(first_party_at(i), Some(w));
            assert_eq!(first_party_by_id(w.folder), Some(w));
        }
        assert_eq!(first_party_at(first_party().len()), None);
        assert_eq!(first_party_by_id(SMOKE_ID), None);
    }
}
