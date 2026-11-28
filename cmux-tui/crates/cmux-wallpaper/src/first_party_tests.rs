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
            failures
                .push(format!("{}: shader must be wallpaper.wgsl, not {:?}", w.folder, m.shader));
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
        assert_eq!(crate::compile(w.source).map(|c| c.msl).as_deref(), Ok(w.msl), "{}", w.folder);
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
