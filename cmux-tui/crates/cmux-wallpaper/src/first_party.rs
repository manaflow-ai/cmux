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
mod tests {
    use super::*;
    use crate::Manifest;

    #[test]
    fn samples_are_embedded_but_not_shipped() {
        let s = smoke().expect("wallpapers/smoke");
        assert!(!s.source.is_empty());
        for id in SAMPLE_IDS {
            assert!(embedded_by_id(id).is_some(), "{id} is embedded");
            assert!(first_party().iter().all(|w| w.folder != *id), "{id} is not shipped");
        }
        assert_eq!(first_party().len(), EMBEDDED.len() - SAMPLE_IDS.len());
    }

    /// Every folder under wallpapers/ (samples too): the manifest is valid,
    /// its id is the folder's name, its shader is wallpaper.wgsl (or it names
    /// a scene and carries the engine), and build.rs translated the program
    /// to Metal. A wallpaper added later is checked here without a test of
    /// its own.
    #[test]
    fn every_first_party_wallpaper_is_valid_and_translated() {
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
            let names_scene = m.scene.is_some() || m.lottie.is_some();
            if names_scene != w.is_scene() {
                failures.push(format!("{}: scene file embedded: {}", w.folder, w.is_scene()));
            }
            if w.is_scene() {
                if w.msl != SCENE_ENGINE_MSL || w.source != SCENE_ENGINE_SOURCE {
                    failures.push(format!("{}: a scene must carry the engine", w.folder));
                }
            } else if m.shader != "wallpaper.wgsl" {
                failures.push(format!(
                    "{}: shader must be wallpaper.wgsl, not {:?}",
                    w.folder, m.shader
                ));
            }
            if !(w.msl.contains("vs_main") && w.msl.contains("fs_main")) {
                failures.push(format!("{}: no Metal entry points", w.folder));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    /// Every embedded scene's file parses (scene.json, or a Lottie file
    /// translated with nothing refused).
    #[test]
    fn every_embedded_scene_parses() {
        let mut failures = Vec::new();
        for w in EMBEDDED {
            let Some(bytes) = w.scene_json else { continue };
            let m = match Manifest::parse(w.manifest_json.as_bytes()) {
                Ok(m) => m,
                Err(e) => {
                    failures.push(format!("{}/wallpaper.json: {e}", w.folder));
                    continue;
                }
            };
            if let Err(e) = crate::scene::load(&m, bytes.as_bytes()) {
                failures.push(format!("{}: {e}", w.folder));
            }
        }
        assert!(EMBEDDED.iter().any(FirstParty::is_scene), "no scene sample embedded");
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn the_scene_engine_is_embedded() {
        assert!(SCENE_ENGINE_MSL.contains("fs_main"));
        assert!(SCENE_ENGINE_MSL.contains("[[buffer(1)]]"));
        assert!(SCENE_ENGINE_GLSL.starts_with("#version 300 es"));
    }

    /// The embedded Metal is what the run-time translator writes today.
    #[cfg(feature = "compile")]
    #[test]
    fn embedded_metal_matches_the_translator() {
        assert_eq!(
            crate::program::compile_scene_engine(SCENE_ENGINE_SOURCE)
                .map(|c| (c.msl, c.glsl))
                .as_ref()
                .map(|(m, g)| (m.as_str(), g.as_str())),
            Ok((SCENE_ENGINE_MSL, SCENE_ENGINE_GLSL)),
        );
        for w in EMBEDDED.iter().filter(|w| !w.is_scene()) {
            assert_eq!(
                crate::compile(w.source).map(|c| c.msl).as_deref(),
                Ok(w.msl),
                "{}",
                w.folder
            );
        }
    }

    #[test]
    fn lookups_agree() {
        for (i, w) in first_party().iter().enumerate() {
            assert_eq!(first_party_at(i), Some(w));
            assert_eq!(first_party_by_id(w.folder), Some(w));
        }
        assert_eq!(first_party_at(first_party().len()), None);
        for id in SAMPLE_IDS {
            assert_eq!(first_party_by_id(id), None);
        }
    }
}
