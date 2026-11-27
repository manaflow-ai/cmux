use super::*;

fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

#[test]
fn git_gets_the_helper_after_the_entries_it_has() {
    let got = entries(
        &env(&[("GIT_CONFIG_COUNT", "1"), ("PATH", "/usr/bin")]),
        Path::new("/opt/it's/acpmux"),
        Some(Path::new("/h/github-shim")),
    );
    let get = |k: &str| got.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
    assert_eq!(get("GIT_CONFIG_COUNT").as_deref(), Some("3"));
    assert_eq!(get("GIT_CONFIG_KEY_1").as_deref(), Some(HELPER_KEY));
    assert_eq!(
        get("GIT_CONFIG_VALUE_1").as_deref(),
        Some(r"!'/opt/it'\''s/acpmux' __github credential")
    );
    assert_eq!(get("GIT_CONFIG_KEY_2").as_deref(), Some(PATH_KEY));
    assert_eq!(get("GIT_CONFIG_VALUE_2").as_deref(), Some("true"));
    assert_eq!(get("PATH").as_deref(), Some("/h/github-shim:/usr/bin"));
    assert!(get("GIT_CONFIG_KEY_0").is_none(), "the entry it had stays");
}

#[test]
fn with_no_shim_path_stays_and_no_token_is_anywhere() {
    let got = entries(&env(&[("GIT_CONFIG_COUNT", "x")]), Path::new("/a"), None);
    assert!(got.iter().all(|(k, _)| k != "PATH"));
    assert!(got.iter().any(|(k, v)| k == "GIT_CONFIG_COUNT" && v == "2"));
    assert!(got.iter().all(|(_, v)| !v.contains("ghs_")));
}

#[test]
fn the_shim_runs_the_real_gh_and_never_itself() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let shim = root.path().join("github-shim");
    let bin = root.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let real = bin.join("gh");
    std::fs::write(&real, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
    write_shim(&shim, &shim_text(Path::new("/a/acpmux"), &real)).unwrap();
    let path = format!("{}:{}", shim.display(), bin.display());
    assert_eq!(real_gh(&path, &shim), Some(real.clone()));
    assert_eq!(real_gh(&shim.display().to_string(), &shim), None);
    let text = std::fs::read_to_string(shim.join("gh")).unwrap();
    assert!(text.contains("exec '/a/acpmux' __github gh --auto -- \"$@\""));
    assert!(text.contains(&format!("CMUX_GITHUB_GH_REAL='{}'", real.display())));
    let mode = std::fs::metadata(shim.join("gh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o755);
}
