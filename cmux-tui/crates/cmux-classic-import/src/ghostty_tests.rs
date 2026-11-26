use super::*;

#[test]
fn channel_and_modern_name_win_and_only_nonempty_files_count() {
    let root = tempfile::tempdir().unwrap();
    let support = root.path();
    let stable = support.join(CHANNELS[0]);
    let nightly = support.join(CHANNELS[1]);
    fs::create_dir(&stable).unwrap();
    fs::create_dir(&nightly).unwrap();
    fs::write(stable.join("config"), "stable").unwrap();
    fs::write(nightly.join(LAYER), "").unwrap();
    assert_eq!(source_path(support, CHANNELS[1]), Some(stable.join("config")));
    fs::write(nightly.join("config"), "old nightly").unwrap();
    fs::write(nightly.join(LAYER), "nightly").unwrap();
    assert_eq!(source_path(support, CHANNELS[1]), Some(nightly.join(LAYER)));
    assert_eq!(
        source_path(support, "com.cmuxterm.app.nightly.cmux-next"),
        Some(nightly.join(LAYER))
    );
    assert_eq!(source_path(support, CHANNELS[0]), Some(stable.join("config")));
    assert_eq!(source_path(support, "../outside"), None);
}

#[cfg(unix)]
#[test]
fn resolves_includes_beside_the_original_symlink_and_retries_a_failed_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let support = root.path().join("support");
    let stable = support.join(CHANNELS[0]);
    let config = root.path().join("next");
    let target = root.path().join("dotfiles");
    fs::create_dir_all(&stable).unwrap();
    fs::write(&target, "config-file = linked-config\n").unwrap();
    std::os::unix::fs::symlink(target, stable.join(LAYER)).unwrap();
    let nested = stable.join("linked-config");
    fs::write(&nested, [0xff]).unwrap();
    let run =
        || import(root.path(), &root.path().join("classic-config"), &support, CHANNELS[0], &config);
    assert!(run().is_err());
    assert!(!config.join("classic-ghostty").exists());
    fs::write(nested, "font-size = 20\n").unwrap();
    run().unwrap();
    assert_eq!(
        fs::read_to_string(config.join("classic-ghostty/file-1")).unwrap(),
        "font-size = 20\n"
    );
}

#[test]
fn imports_includes_and_assets_once_and_keeps_external_references() {
    let root = tempfile::tempdir().unwrap();
    let support = root.path().join("support");
    let stable = support.join(CHANNELS[0]);
    let parts = stable.join("parts");
    let config = root.path().join("next");
    let layer = config.join("classic-ghostty");
    let external = root.path().join("dotfiles.ghostty ");
    fs::create_dir_all(&parts).unwrap();
    fs::write(
        stable.join(LAYER),
        format!(
            "config-file = parts/font\nconfig-file = ?\"{}\"\nconfig-file = ?\n",
            external.display()
        ),
    )
    .unwrap();
    fs::write(
        parts.join("font"),
        "font-size = 17\nconfig-file = ../config.ghostty\nbackground-image = ?\"a picture.png\"\n",
    )
    .unwrap();
    fs::write(parts.join("a picture.png"), [123, 42]).unwrap();
    let run =
        || import(root.path(), &root.path().join("classic-config"), &support, CHANNELS[1], &config);
    assert!(!layer.exists());
    run().unwrap();
    let imported = fs::read_to_string(layer.join(LAYER)).unwrap();
    assert_eq!(
        imported,
        format!(
            "config-file = file-1\nconfig-file = ?\"{}\"\nconfig-file = ?\n",
            external.display()
        )
    );
    assert_eq!(
        fs::read_to_string(layer.join("file-1")).unwrap(),
        "font-size = 17\nconfig-file = config.ghostty\nbackground-image = ?file-2.png\n"
    );
    assert_eq!(fs::read(layer.join("file-2.png")).unwrap(), [123, 42]);
    fs::write(stable.join(LAYER), "font-size = 18").unwrap();
    run().unwrap();
    assert_eq!(fs::read_to_string(layer.join(LAYER)).unwrap(), imported);
}
