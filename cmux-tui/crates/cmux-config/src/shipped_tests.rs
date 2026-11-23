use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use super::*;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// The manifest live_apply.py reads names exactly the folders this module
/// writes, and each folder's `.json` files are exactly the embedded ones, so
/// a file added to Resources without an owner here fails this test.
#[test]
fn manifest_matches_the_embedded_files() {
    let manifest: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("shipped-resources.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let listed: Vec<String> = manifest["folders"]
        .as_array()
        .unwrap()
        .iter()
        .map(|folder| folder.as_str().unwrap().to_string())
        .collect();
    let owned: Vec<String> =
        kinds().iter().map(|(folder, _)| format!("Resources/{folder}")).collect();
    assert_eq!(listed, owned);
    for (folder, files) in kinds() {
        let on_disk: BTreeSet<String> = fs::read_dir(repo().join("Resources").join(folder))
            .unwrap()
            .filter_map(|entry| {
                let name = entry.unwrap().file_name().into_string().unwrap();
                name.strip_suffix(".json").map(str::to_string)
            })
            .collect();
        let embedded: BTreeSet<String> = files.iter().map(|(name, _)| name.to_string()).collect();
        assert_eq!(on_disk, embedded, "Resources/{folder}");
    }
}

#[test]
fn write_materializes_files_drops_stale_and_stamps() {
    let root = std::env::temp_dir().join(format!("cmux-shipped-test-{}", uuid::Uuid::new_v4()));
    let stale = root.join(FOLDER).join("theme-files").join("gone.json");
    fs::create_dir_all(stale.parent().unwrap()).unwrap();
    fs::write(&stale, "{}").unwrap();
    fs::write(root.join(FOLDER).join("theme-files").join("teal.json"), "old").unwrap();

    write(&root).unwrap();

    assert!(!stale.exists());
    for (folder, files) in kinds() {
        for (name, text) in files {
            let path = root.join(FOLDER).join(folder).join(format!("{name}.json"));
            assert_eq!(fs::read_to_string(path).unwrap(), *text);
        }
    }
    assert_eq!(fs::read_to_string(root.join(FOLDER).join(STAMP)).unwrap(), stamp());
    assert_eq!(stamp().len(), 64);

    write(&root).unwrap();
    assert_eq!(fs::read_to_string(root.join(FOLDER).join(STAMP)).unwrap(), stamp());
    fs::remove_dir_all(&root).unwrap();
}
