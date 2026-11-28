use super::*;

#[test]
fn stems() {
    assert_eq!(stem("assets/index-Bx3k9aQz.js").as_deref(), Some("assets/index-*.js"));
    assert_eq!(stem("a/b/chunk.4f9a0c12.css").as_deref(), Some("a/b/chunk-*.css"));
    assert_eq!(
        stem("agent-pane/chunks/FactsCard-5IPAB2BO.js").as_deref(),
        Some("agent-pane/chunks/FactsCard-*.js")
    );
    assert_eq!(stem("main-DQOHYIGE.mjs.map").as_deref(), Some("main-*.mjs.map"));
    assert_eq!(stem("index.html"), None);
    assert_eq!(stem("assets/vendor-react.js"), None);
    assert_eq!(stem("-12345678.js"), None);
}

#[test]
fn a_patch_round_trips_and_a_wrong_base_is_refused() {
    let base: Vec<u8> = (0..200_000u32).flat_map(|i| (i * 7).to_le_bytes()).collect();
    let mut file = base.clone();
    file.splice(1000..1000, b"inserted".iter().copied());
    file[500_000] ^= 0xff;
    let patch = make(&base, &file).unwrap().unwrap();
    assert!(patch.len() < 1000, "{}", patch.len());
    let to = Id::of(&file);
    assert_eq!(apply(&base, &patch, &to, file.len() as u64).unwrap(), file);
    let mut other = base.clone();
    other[10] ^= 1;
    assert!(apply(&other, &patch, &to, file.len() as u64).is_err());
    assert!(apply(&base, &patch, &to, file.len() as u64 - 1).is_err());
}
