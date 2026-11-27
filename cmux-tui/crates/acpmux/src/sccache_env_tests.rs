use super::*;

fn file() -> String {
    serde_json::json!({"env": {
        "RUSTC_WRAPPER": "sccache",
        "SCCACHE_ENDPOINT": "https://platform.example/v1/cloud/sccache",
        "SCCACHE_SKIP_CACHE_CHECK": "true",
        "SCCACHE_CACHE_READ_TIMEOUT_SECS": "5",
        "SCCACHE_ALLOW_INCREMENTAL": "1",
    }})
    .to_string()
}

fn unset(_: &str) -> bool {
    false
}

#[test]
fn with_sccache_on_path_every_variable_is_added() {
    let vars = parse(&file()).unwrap();
    let add = plan(&vars, unset, true);
    assert_eq!(add, vars);
    assert!(add.iter().any(|(k, v)| k == "RUSTC_WRAPPER" && v == "sccache"));
}

#[test]
fn without_sccache_on_path_nothing_is_added() {
    let vars = parse(&file()).unwrap();
    assert!(plan(&vars, unset, false).is_empty());
}

#[test]
fn a_rustc_wrapper_the_person_set_wins_and_none_are_added() {
    let vars = parse(&file()).unwrap();
    assert!(plan(&vars, |k| k == "RUSTC_WRAPPER", true).is_empty());
}

#[test]
fn a_sccache_variable_the_person_set_is_kept() {
    let vars = parse(&file()).unwrap();
    let add = plan(&vars, |k| k == "SCCACHE_CACHE_READ_TIMEOUT_SECS", true);
    assert_eq!(add.len(), vars.len() - 1);
    assert!(add.iter().all(|(k, _)| k != "SCCACHE_CACHE_READ_TIMEOUT_SECS"));
}

#[test]
fn a_file_with_a_name_outside_the_allow_list_is_refused_whole() {
    for name in ["PATH", "LD_PRELOAD", "AWS_SECRET_ACCESS_KEY", "SCCACHE_", "sccache_x", "HOME"] {
        let text = serde_json::json!({"env": {"RUSTC_WRAPPER": "sccache", name: "hidden-value"}})
            .to_string();
        let why = parse(&text).unwrap_err();
        assert!(why.contains(name), "{why}");
        assert!(!why.contains("hidden-value"), "a refusal never shows a value: {why}");
    }
}

#[test]
fn malformed_files_are_refused() {
    for text in [
        "",
        "not json",
        "[]",
        "{}",
        r#"{"env": []}"#,
        r#"{"env": {}}"#,
        r#"{"env": {"RUSTC_WRAPPER": "sccache"}, "more": 1}"#,
        r#"{"env": {"RUSTC_WRAPPER": 1}}"#,
        r#"{"env": {"RUSTC_WRAPPER": ""}}"#,
        r#"{"env": {"SCCACHE_ENDPOINT": "a\nb"}}"#,
    ] {
        assert!(parse(text).is_err(), "{text}");
    }
}

#[cfg(unix)]
#[test]
fn on_path_finds_an_executable_sccache_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-sccache-{}", uuid::Uuid::now_v7()));
    let (with, plain) = (dir.join("with"), dir.join("plain"));
    std::fs::create_dir_all(&with).unwrap();
    std::fs::create_dir_all(&plain).unwrap();
    let bin = with.join("sccache");
    std::fs::write(&bin, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(plain.join("sccache"), "not executable").unwrap();
    let join = |dirs: &[&Path]| std::env::join_paths(dirs).unwrap();
    assert!(on_path(Some(&join(&[&plain, &with]))));
    assert!(!on_path(Some(&join(&[&plain]))));
    assert!(!on_path(None));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[cfg(unix)]
#[test]
fn a_missing_file_is_off_and_a_kept_one_reads_back() {
    let dir = std::env::temp_dir().join(format!("acpmux-sccache-file-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    assert_eq!(read(&dir.join("sccache-env.json")).unwrap(), None);
    let kept = dir.join("kept.json");
    std::fs::write(&kept, file()).unwrap();
    assert_eq!(read(&kept).unwrap(), Some(parse(&file()).unwrap()));
    let link = dir.join("link.json");
    std::os::unix::fs::symlink(&kept, &link).unwrap();
    assert!(read(&link).is_err(), "a symlink is refused");
    std::fs::remove_dir_all(&dir).unwrap();
}

/// What `apply_at` set on a fresh command, in name order.
#[cfg(unix)]
fn applied(env: &[(String, String)], cloud: bool, file: &Path) -> Vec<(String, String)> {
    let mut cmd = tokio::process::Command::new("true");
    apply_at(&mut cmd, env, cloud, file);
    let mut set: Vec<(String, String)> = cmd
        .as_std()
        .get_envs()
        .map(|(k, v)| {
            (
                k.to_string_lossy().into_owned(),
                v.map(|v| v.to_string_lossy().into_owned()).unwrap_or_default(),
            )
        })
        .collect();
    set.sort();
    set
}

#[cfg(unix)]
#[test]
fn apply_changes_nothing_unless_cloud_file_and_sccache_all_hold() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-sccache-apply-{}", uuid::Uuid::now_v7()));
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("sccache");
    std::fs::write(&bin, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    let kept = dir.join("sccache-env.json");
    std::fs::write(&kept, file()).unwrap();
    let bad = dir.join("bad.json");
    std::fs::write(&bad, r#"{"env": {"RUSTC_WRAPPER": "sccache", "LD_PRELOAD": "/x.so"}}"#)
        .unwrap();
    let path = |p: &Path| vec![("PATH".to_owned(), p.display().to_string())];
    let with_bin = path(&bin_dir);

    // On: every variable of the file.
    assert_eq!(applied(&with_bin, true, &kept), parse(&file()).unwrap());
    // Not a Cloud VM, no file, a refused file, no sccache on PATH: nothing at all.
    assert!(applied(&with_bin, false, &kept).is_empty());
    assert!(applied(&with_bin, true, &dir.join("missing.json")).is_empty());
    assert!(applied(&with_bin, true, &bad).is_empty());
    assert!(applied(&path(&dir), true, &kept).is_empty());
    assert!(applied(&[], true, &kept).is_empty());
    // The person's RUSTC_WRAPPER (even an empty one) wins: nothing is added.
    for theirs in ["", "/usr/bin/other-wrapper"] {
        let mut env = with_bin.clone();
        env.push(("RUSTC_WRAPPER".to_owned(), theirs.to_owned()));
        assert!(applied(&env, true, &kept).is_empty(), "{theirs:?}");
    }
    std::fs::remove_dir_all(&dir).unwrap();
}
