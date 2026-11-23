//! The cases of Swift `ChatFontFacesTests` (CmuxNextSettingsTests), so both
//! readers agree on which faces load.

use std::path::PathBuf;

use serde_json::{Map, Value, json};

use super::*;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-font-faces-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn file_value(path: &Path) -> Value {
    json!(format!("file:{}", path.display()))
}

const WOFF2: &[u8] = b"wOF2\0\x01\0\0rest of the font";

#[test]
fn the_first_bytes_name_the_font_type() {
    assert_eq!(font_kind(b"wOF2...."), Some("woff2"));
    assert_eq!(font_kind(b"wOFF...."), Some("woff"));
    assert_eq!(font_kind(&[0, 1, 0, 0, 9]), Some("ttf"));
    assert_eq!(font_kind(b"true...."), Some("ttf"));
    assert_eq!(font_kind(b"OTTO...."), Some("otf"));
    assert_eq!(font_kind(b"\x89PNG"), None);
    assert_eq!(font_kind(b"wO"), None);
}

#[test]
fn a_key_is_one_family_optionally_italic() {
    assert_eq!(
        parse_key("Inter Display"),
        Ok(FaceKey { family: "Inter Display".into(), italic: false })
    );
    assert_eq!(parse_key(" Lora :italic"), Ok(FaceKey { family: "Lora".into(), italic: true }));
    assert!(parse_key("Lora:bold").is_err());
    assert!(parse_key("Lora, serif").is_err());
    assert!(parse_key("Lo\"ra").is_err());
    assert!(parse_key("a}b").is_err());
    assert!(parse_key("").is_err());
    assert!(parse_key(":italic").is_err());
}

#[test]
fn a_good_face_becomes_a_data_url() {
    let dir = scratch("good");
    let path = dir.join("Lora-Italic.woff2");
    std::fs::write(&path, WOFF2).unwrap();
    let face = load("Lora:italic", &file_value(&path)).unwrap();
    assert_eq!(face.key, "Lora:italic");
    assert!(face.data_url.starts_with("data:font/woff2;base64,d09GMg"), "{}", face.data_url);
    let checked = check("Lora:italic", &file_value(&path)).unwrap();
    assert_eq!((checked.kind, checked.bytes), ("woff2", WOFF2.len() as u64));
}

#[test]
fn bad_files_are_refused_with_a_reason() {
    let dir = scratch("bad");
    let png = dir.join("x.woff2");
    std::fs::write(&png, b"\x89PNG\r\n\x1a\n").unwrap();
    assert!(check("A", &file_value(&png)).unwrap_err().contains("not a font file"));

    let mismatched = dir.join("x.ttf");
    std::fs::write(&mismatched, WOFF2).unwrap();
    assert!(check("A", &file_value(&mismatched)).unwrap_err().contains("woff2 file, not .ttf"));

    let wrong_extension = dir.join("x.svg");
    std::fs::write(&wrong_extension, WOFF2).unwrap();
    assert!(check("A", &file_value(&wrong_extension)).is_err());

    let big = dir.join("big.woff2");
    let mut bytes = WOFF2.to_vec();
    bytes.resize(MAX_FACE_BYTES as usize + 1, 0);
    std::fs::write(&big, bytes).unwrap();
    assert!(check("A", &file_value(&big)).unwrap_err().contains("larger than 2 MiB"));

    assert!(check("A", &file_value(&dir.join("missing.woff2"))).unwrap_err().contains("no file"));
    assert!(check("A", &file_value(&dir)).is_err(), "a folder is no face");
    assert!(check("A", &json!("x.woff2")).is_err(), "no file: prefix");
    assert!(check("A", &json!("file:fonts/x.woff2")).is_err(), "relative outside a theme file");
    assert!(check("A", &json!(3)).is_err());
}

#[cfg(unix)]
#[test]
fn a_symlink_is_refused() {
    let dir = scratch("link");
    let real = dir.join("real.woff2");
    std::fs::write(&real, WOFF2).unwrap();
    let link = dir.join("link.woff2");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert!(check("A", &file_value(&link)).unwrap_err().contains("symbolic link"));
}

#[test]
fn at_most_eight_faces_load_and_bad_ones_are_skipped() {
    let dir = scratch("many");
    let mut map = Map::new();
    for index in 0..10 {
        let path = dir.join(format!("f{index}.woff2"));
        std::fs::write(&path, WOFF2).unwrap();
        map.insert(format!("Face {index}"), file_value(&path));
    }
    map.insert("Face 0:bold".into(), json!("file:/nope.woff2"));
    let (faces, problems) = load_all(&map);
    // Key order: "Face 0", "Face 0:bold" (bad), "Face 1" .. "Face 6" are the first eight.
    assert_eq!(faces.len(), 7);
    assert_eq!(problems.len(), 4, "{problems:?}");
    assert!(problems.iter().any(|p| p.key == "Face 0:bold"));
    assert_eq!(problems.iter().filter(|p| p.message.contains("at most 8")).count(), 3);
    let (checked, check_problems) = check_all(&map);
    assert_eq!((checked.len(), check_problems.len()), (7, 4));
}
