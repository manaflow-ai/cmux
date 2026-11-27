use super::*;

fn dir() -> std::path::PathBuf {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let dir =
        std::env::temp_dir().join(format!("cmux-manifest-limit-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A manifest past 64 KiB is refused on its size alone: nothing past
/// the limit is parsed, so a broken far end reports no JSON error, and
/// no manifest comes back (base red: the whole file was read and parsed,
/// and a valid oversize manifest came back parsed).
#[test]
fn an_oversize_manifest_is_refused_without_parsing_it() {
    let dir = dir();
    let pad = "x".repeat(MANIFEST_LIMIT as usize);
    std::fs::write(dir.join("cmux-app.json"), format!(r#"{{"name":"{pad}"}}"#)).unwrap();
    let valid_json = validate_package(&dir);
    std::fs::write(dir.join("cmux-app.json"), format!(r#"{{"name":"{pad}" BROKEN"#)).unwrap();
    let broken_tail = validate_package(&dir);
    let _ = std::fs::remove_dir_all(&dir);
    for report in [valid_json, broken_tail] {
        assert!(report.manifest.is_none(), "an oversize manifest is not parsed");
        let codes: Vec<&str> = report.issues.iter().map(|i| i.code).collect();
        assert_eq!(codes, ["limit.manifest"], "{:?}", report.issues);
    }
}

/// A catalog that is a symlink to a file outside the package is refused
/// and not kept (base of this PR: the fragment was read through the
/// link and handed to the catalog).
#[cfg(unix)]
#[test]
fn a_catalog_symlinked_outside_the_package_is_refused() {
    let root = dir();
    let pkg = root.join("pkg");
    std::fs::create_dir_all(&pkg).unwrap();
    std::fs::write(root.join("outside.json"), r#"{"ops":{}}"#).unwrap();
    std::os::unix::fs::symlink(root.join("outside.json"), pkg.join("catalog.json")).unwrap();
    let m = serde_json::json!({ "catalog": "catalog.json" });
    let (fragment, issues) = catalog_file(&pkg, &m);
    let _ = std::fs::remove_dir_all(&root);
    assert!(fragment.is_none(), "an escaped catalog is not kept");
    let codes: Vec<&str> = issues.iter().map(|i| i.code).collect();
    assert_eq!(codes, ["catalog.json"], "{issues:?}");
}

#[test]
fn read_limited_stops_one_byte_past_the_limit() {
    let dir = dir();
    let path = dir.join("big");
    std::fs::write(&path, vec![b'a'; 1 << 20]).unwrap();
    let raw = read_limited(&path, 1024);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(raw.map(|r| r.len()), Some(1025));
}
