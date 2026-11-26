//! The first-party wallpapers, embedded in the binary from `wallpapers/<id>/`
//! (build.rs), so the app gets the set without reading files: each one's
//! manifest, its WGSL and its Metal Shading Language, translated at build
//! time (a program the sandbox refuses fails the build). A motion scene
//! (plans/cmux-next/motion-scenes.md) carries its `scene.json` (or Lottie)
//! bytes and the scene engine's program ([`SCENE_ENGINE_MSL`]). `smoke` and
//! `scene-sample` are test samples: embedded but not shipped.

/// The test sample's folder; never shipped.
pub const SMOKE_ID: &str = "smoke";
/// The scene test sample's folder (every shape kind once); never shipped.
pub const SCENE_SAMPLE_ID: &str = "scene-sample";
/// The samples: embedded, never shipped.
pub const SAMPLE_IDS: &[&str] = &[SMOKE_ID, SCENE_SAMPLE_ID];

/// One embedded wallpaper folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FirstParty {
    /// The folder name (the manifest's `id` must equal it).
    pub folder: &'static str,
    /// `wallpaper.json`.
    pub manifest_json: &'static str,
    /// `wallpaper.wgsl`; for a scene, the engine's ([`SCENE_ENGINE_SOURCE`]).
    pub source: &'static str,
    /// The program translated to Metal Shading Language 2.1 at build time:
    /// `vertex vs_main`, `fragment fs_main`, the Frame uniform at buffer 0.
    /// For a scene, [`SCENE_ENGINE_MSL`].
    pub msl: &'static str,
    /// A scene's file, as the manifest names it: `scene.json`, or the Lottie
    /// file (`crate::scene::load` reads either). `None` for a program wallpaper.
    pub scene_json: Option<&'static str>,
}

impl FirstParty {
    /// Whether the scene engine draws it.
    pub fn is_scene(&self) -> bool {
        self.scene_json.is_some()
    }
}

// `SCENE_ENGINE_SOURCE`, `SCENE_ENGINE_MSL`, `SCENE_ENGINE_GLSL`, `EMBEDDED`
// (every folder) and `SHIPPED` (without the samples), sorted by folder name.
include!(concat!(env!("OUT_DIR"), "/first_party.rs"));

/// The shipped set, sorted by folder name: every embedded folder but the samples.
pub fn first_party() -> &'static [FirstParty] {
    SHIPPED
}

/// The `smoke` sample (tests and the gallery's sanity check).
pub fn smoke() -> Option<&'static FirstParty> {
    EMBEDDED.iter().find(|w| w.folder == SMOKE_ID)
}

/// Any embedded folder, samples too (tests and the gallery).
pub fn embedded_by_id(id: &str) -> Option<&'static FirstParty> {
    EMBEDDED.iter().find(|w| w.folder == id)
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
