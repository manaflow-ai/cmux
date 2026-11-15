use super::as_seed;

#[test]
fn a_bundle_header_names_seed_refs_and_its_pack_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let bundle = dir.path().join("x.bundle");
    let header = "# v2 git bundle\n\
                      1111111111111111111111111111111111111111 refs/cmux-back/main\n\
                      2222222222222222222222222222222222222222 refs/cmux-move/a\n\
                      3333333333333333333333333333333333333333 refs/cmux-back/b\n\n";
    std::fs::write(&bundle, format!("{header}PACK refs/cmux-back/not-a-ref")).unwrap();

    as_seed(&bundle).unwrap();

    let text = std::fs::read_to_string(&bundle).unwrap();
    assert_eq!(
        text,
        "# v2 git bundle\n\
             1111111111111111111111111111111111111111 refs/cmux-seed/main\n\
             2222222222222222222222222222222222222222 refs/cmux-seed/a\n\
             3333333333333333333333333333333333333333 refs/cmux-seed/b\n\n\
             PACK refs/cmux-back/not-a-ref"
    );
}
