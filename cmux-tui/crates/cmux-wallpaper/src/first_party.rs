//! The first-party wallpapers, embedded in the binary from `wallpapers/<id>/`
//! (build.rs), so the app gets the set without reading files: each one's
//! manifest, its WGSL and its Metal Shading Language, translated at build
//! time (a program the sandbox refuses fails the build). `smoke` is a test
//! sample: it is embedded but not shipped.

/// The test sample's folder; never shipped.
pub const SMOKE_ID: &str = "smoke";

/// One embedded wallpaper folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FirstParty {
    /// The folder name (the manifest's `id` must equal it).
    pub folder: &'static str,
    /// `wallpaper.json`.
    pub manifest_json: &'static str,
    /// `wallpaper.wgsl`.
    pub source: &'static str,
    /// The program translated to Metal Shading Language 2.1 at build time:
    /// `vertex vs_main`, `fragment fs_main`, the Frame uniform at buffer 0.
    pub msl: &'static str,
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
#[path = "first_party_tests.rs"]
mod tests;
