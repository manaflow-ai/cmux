use super::*;

fn state() -> tempfile::TempDir {
    let state = tempfile::tempdir().unwrap();
    fs::create_dir_all(state.path().join("cache")).unwrap();
    fs::write(state.path().join("cache/manifest-id"), "00ab\n").unwrap();
    for (path, text) in [
        ("upper/cmux/src/main.rs", "edited"),
        ("upper/cmux/src/new/made.rs", "new"),
        ("upper/cmux/.git/index", "index"),
        ("upper/other/notes.md", "elsewhere"),
    ] {
        let at = state.path().join(path);
        fs::create_dir_all(at.parent().unwrap()).unwrap();
        fs::write(at, text).unwrap();
    }
    fs::write(state.path().join("whiteouts"), "cmux/old.rs\ncmux/gone\nother/x\n").unwrap();
    state
}

fn paths(answer: &[u8]) -> (String, Vec<String>) {
    let mut parts =
        answer.split(|byte| *byte == 0).map(|part| String::from_utf8_lossy(part).into_owned());
    let token = parts.next().unwrap();
    let mut paths: Vec<String> = parts.filter(|part| !part.is_empty()).collect();
    paths.sort();
    (token, paths)
}

#[test]
fn a_foreign_token_is_answered_everything_with_ours() {
    let state = state();
    let (token, paths) = paths(&answer(state.path(), "cmux", "builtin:0").unwrap());
    assert_eq!(token, "cmux-projection:00ab");
    assert_eq!(paths, ["/"]);
}

#[test]
fn our_token_is_answered_with_the_repos_upper_files_and_whiteouts_only() {
    let state = state();
    let (token, paths) = paths(&answer(state.path(), "cmux", "cmux-projection:00ab").unwrap());
    assert_eq!(token, "cmux-projection:00ab");
    // The repository's own files and deletions; never `.git`, never another repository's.
    assert_eq!(paths, ["gone", "gone/", "old.rs", "old.rs/", "src/main.rs", "src/new/made.rs"]);
}

#[test]
fn the_folder_itself_as_the_repo_names_paths_from_its_top() {
    let state = state();
    let (_, paths) = paths(&answer(state.path(), "", "cmux-projection:00ab").unwrap());
    assert!(paths.contains(&"other/notes.md".to_owned()), "{paths:?}");
    assert!(paths.contains(&"cmux/src/main.rs".to_owned()), "{paths:?}");
    assert!(!paths.iter().any(|path| path.contains(".git/")), "{paths:?}");
}

#[test]
fn a_new_manifest_is_a_new_token() {
    let state = state();
    fs::write(state.path().join("cache/manifest-id"), "77\n").unwrap();
    let (token, paths) = paths(&answer(state.path(), "cmux", "cmux-projection:00ab").unwrap());
    assert_eq!(token, "cmux-projection:77");
    assert_eq!(paths, ["/"]);
}

#[test]
fn the_hook_finds_its_projection_by_mount_point_and_answers_everything_elsewhere() {
    let projections = tempfile::tempdir().unwrap();
    let mounted = tempfile::tempdir().unwrap();
    let mount = fs::canonicalize(mounted.path()).unwrap();
    fs::create_dir_all(mount.join("cmux")).unwrap();
    let state = state();
    let named = projections.path().join("chat-a");
    fs::rename(state.path(), &named).unwrap();
    fs::write(named.join(MOUNT_POINT_FILE), mount.as_os_str().as_bytes()).unwrap();
    let (_, found) = paths(&hook(projections.path(), &mount.join("cmux"), "cmux-projection:00ab"));
    assert!(found.contains(&"src/main.rs".to_owned()), "{found:?}");
    let elsewhere = tempfile::tempdir().unwrap();
    assert_eq!(
        paths(&hook(projections.path(), elsewhere.path(), "x")),
        (String::new(), vec!["/".to_owned()])
    );
}
