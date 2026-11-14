use super::*;

#[test]
fn offline_after_a_restore() {
    let argv = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        offline_install(Ecosystem::Cargo, &argv(&["cargo", "fetch", "--locked"])),
        Some(argv(&["cargo", "fetch", "--locked", "--offline"]))
    );
    assert_eq!(
        offline_install(Ecosystem::Npm, &argv(&["npm", "ci", "--prefer-offline", "--no-audit"])),
        Some(argv(&["npm", "ci", "--no-audit", "--offline"]))
    );
    assert_eq!(offline_install(Ecosystem::Bun, &argv(&["bun", "install"])), None);
}

#[test]
fn detects_one_js_manager_and_the_others_beside_it() {
    let dir = tempfile::tempdir().unwrap();
    for name in ["package-lock.json", "bun.lock", "Cargo.lock", "uv.lock"] {
        std::fs::write(dir.path().join(name), b"x").unwrap();
    }
    let found: Vec<_> = detect(dir.path()).iter().map(|p| p.ecosystem).collect();
    assert_eq!(found, [Ecosystem::Bun, Ecosystem::Cargo, Ecosystem::Uv]);
    assert!(detect(&dir.path().join("missing")).is_empty());
}

#[test]
fn key_changes_with_every_input_and_matches_the_platform_pattern() {
    let v = |s: &str| vec![s.to_owned()];
    let base = key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock");
    let pattern = regex::Regex::new("^cargo-[0-9a-f]{64}$").unwrap();
    assert!(pattern.is_match(&base), "{base}");
    assert_eq!(base, key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock"));
    for other in [
        key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.91"), b"lock"),
        key_of(Ecosystem::Cargo, "gzip", &v("cargo 1.90"), b"lock"),
        key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock2"),
    ] {
        assert_ne!(base, other);
    }
    assert!(key_of(Ecosystem::Uv, "zstd", &v("x"), b"lock").starts_with("uv-"));
}

#[test]
fn refuses_a_cache_folder_that_holds_the_home_folder() {
    let plan = |root: &str, rel: &str| Plan {
        root: root.into(),
        include: vec![rel.into()],
        replaces: false,
        install: vec![],
    };
    let home = home().expect("HOME");
    let parent = home.parent().expect("home has a parent");
    let name = home.file_name().expect("home has a name").to_string_lossy().into_owned();
    assert!(too_broad(&plan(&parent.to_string_lossy(), &name)));
    let grand = parent.parent().unwrap_or(Path::new("/"));
    let first = parent.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if !first.is_empty() {
        assert!(too_broad(&plan(&grand.to_string_lossy(), &first)));
    }
    assert!(too_broad(&plan(&home.to_string_lossy(), ".ssh")));
    assert!(!too_broad(&plan(&home.join(".cache").to_string_lossy(), "uv")));
    // A shared cache outside every cache folder (a repo's uv cache-dir).
    assert!(too_broad(&plan(&home.to_string_lossy(), ".config")));
    assert!(too_broad(&plan(&home.join(".cache").to_string_lossy(), "../.config")));
}
