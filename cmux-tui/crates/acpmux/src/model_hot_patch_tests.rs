use super::*;

fn patches(json: &str) -> Patches {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(FILE);
    std::fs::write(&path, json).expect("write");
    read(&path)
}

/// A patch names any id for any name, under the harness it is filed for, case-insensitively.
#[test]
fn a_patch_reroutes_its_name_on_its_harness_only() {
    let p = patches(r#"{"claude": {"Fable-Latest": "claude-fable-5-2", " ": "x"}}"#);
    assert_eq!(find(&p, ["claude"], "fable-latest").as_deref(), Some("claude-fable-5-2"));
    assert_eq!(
        find(&p, ["claude-code", "claude"], "FABLE-LATEST").as_deref(),
        Some("claude-fable-5-2")
    );
    assert_eq!(find(&p, ["codex"], "fable-latest"), None);
    assert_eq!(find(&p, ["claude"], "opus"), None);
    assert_eq!(p["claude"].len(), 1, "a blank name is dropped");
}

#[test]
fn a_file_that_does_not_parse_is_ignored() {
    assert!(patches("not json").is_empty());
    assert!(patches(r#"{"fable-latest": "claude-fable-5-2"}"#).is_empty(), "flat form is refused");
}

/// Through `canonical_model`: the patch wins and keeps `[1m]`; without one the fold still runs.
#[test]
fn canonical_model_reads_the_hot_patch_first() {
    let p = patches(r#"{"claude": {"fable-latest": "claude-fable-5-2"}}"#);
    let entry = crate::model_catalog::bundled_harness("claude").expect("claude entry");
    let canon = |name: &str| {
        crate::model_catalog::canonical_patched(&entry, name, |keys, base| find(&p, keys, base))
            .expect("one id")
    };
    let c = canon("fable-latest[1m]");
    assert_eq!(c.model, "claude-fable-5-2[1m]");
    assert!(c.changed());
    assert_eq!(canon("fable-5.2").model, "claude-fable-5-2");
    assert!(!canon("opus").changed());
}
