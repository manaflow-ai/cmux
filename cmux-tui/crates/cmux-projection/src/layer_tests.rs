use super::*;

#[test]
fn a_state_folder_lists_its_upper_paths_and_whiteouts_and_survives_the_wire() {
    let state = tempfile::tempdir().unwrap();
    let upper = state.path().join("upper");
    fs::create_dir_all(upper.join("src/deep")).unwrap();
    fs::write(upper.join("src/a.rs"), b"edited").unwrap();
    fs::write(upper.join("src/deep/new.rs"), b"new file").unwrap();
    std::os::unix::fs::symlink("src/a.rs", upper.join("link")).unwrap();
    fs::write(state.path().join("whiteouts"), "docs\nsrc/b.rs\n../escape\n").unwrap();

    let layer = Layer::collect(state.path()).unwrap();
    let listed: Vec<(&str, Kind)> =
        layer.upper.iter().map(|entry| (entry.path.as_str(), entry.kind)).collect();
    assert_eq!(
        listed,
        [
            ("link", Kind::Link),
            ("src", Kind::Dir),
            ("src/a.rs", Kind::File),
            ("src/deep", Kind::Dir),
            ("src/deep/new.rs", Kind::File),
        ]
    );
    assert_eq!(layer.upper[0].link.as_deref(), Some("src/a.rs"));
    assert_eq!(layer.upper[2].size, 6);
    assert_eq!(layer.whiteouts, ["docs", "src/b.rs"], "a path that is not plain is dropped");
    assert_eq!(Layer::decode(&layer.encode().unwrap()).unwrap(), layer);
}

#[test]
fn a_projection_that_never_wrote_has_an_empty_layer() {
    let state = tempfile::tempdir().unwrap();
    assert_eq!(Layer::collect(state.path()).unwrap(), Layer::default());
}

#[test]
fn a_listing_with_a_path_out_of_the_folder_is_refused() {
    let layer = Layer { upper: Vec::new(), whiteouts: vec!["a/../../etc".into()] };
    assert!(Layer::decode(&layer.encode().unwrap()).is_err());
}

#[test]
fn only_the_asked_files_cross_and_a_gone_one_is_named_missing() {
    let state = tempfile::tempdir().unwrap();
    let upper = state.path().join("upper");
    fs::create_dir_all(upper.join("src")).unwrap();
    fs::write(upper.join("src/a.rs"), b"edited").unwrap();
    fs::write(upper.join("big.bin"), vec![7u8; 100_000]).unwrap();
    fs::write(upper.join("outside"), b"secret").unwrap();
    std::os::unix::fs::symlink("outside", upper.join("sneaky")).unwrap();

    let asked: Vec<String> =
        vec!["src/a.rs".into(), "gone".into(), "big.bin".into(), "sneaky".into()];
    let mut wire = Vec::new();
    let sent = send_files(state.path(), &asked, &mut wire).unwrap();
    assert_eq!(sent, 100_006);

    let into = tempfile::tempdir().unwrap();
    let arrived = receive_files(&mut wire.as_slice(), &asked, into.path(), u64::MAX).unwrap();
    assert_eq!(arrived, [true, false, true, false], "a symlink is never followed");
    assert_eq!(fs::read(into.path().join("src/a.rs")).unwrap(), b"edited");
    assert_eq!(fs::read(into.path().join("big.bin")).unwrap().len(), 100_000);

    // A file past the limit is refused.
    let mut wire = Vec::new();
    send_files(state.path(), &["big.bin".into()], &mut wire).unwrap();
    let into = tempfile::tempdir().unwrap();
    assert!(receive_files(&mut wire.as_slice(), &["big.bin".into()], into.path(), 10).is_err());
}

#[test]
fn whiteouts_read_as_the_overlay_writes_them_nul_ended() {
    let state = tempfile::tempdir().unwrap();
    fs::write(state.path().join("whiteouts"), "src/m01.rs\0src/m02.rs\0../escape\0").unwrap();
    let layer = Layer::collect(state.path()).unwrap();
    assert_eq!(layer.whiteouts, ["src/m01.rs", "src/m02.rs"]);
}
