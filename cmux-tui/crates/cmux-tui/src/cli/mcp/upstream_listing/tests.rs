use super::*;

fn spec(command: &Path, token: &str) -> Spec {
    Spec {
        name: "cmux-cua".into(),
        command: command.to_path_buf(),
        args: vec!["mcp".into()],
        env: vec![("CMUX_CUA_SOCKET_AUTH_TOKEN".into(), token.into())],
        call_timeout: std::time::Duration::from_secs(1),
        shared: None,
    }
}

/// The key names the program `PATH` runs: a same-named file that is not
/// executable, earlier on `PATH`, is skipped, and the server's own `PATH`
/// wins over this process's.
#[cfg(unix)]
#[test]
fn the_key_follows_the_program_the_server_runs() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let (early, late) = (home.path().join("early"), home.path().join("late"));
    for dir in [&early, &late] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(early.join("srv"), "not a program").unwrap();
    std::fs::set_permissions(early.join("srv"), std::fs::Permissions::from_mode(0o644)).unwrap();
    std::fs::write(late.join("srv"), "#!/bin/sh").unwrap();
    std::fs::set_permissions(late.join("srv"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::join_paths([&early, &late]).unwrap().into_string().unwrap();
    let mut named = spec(Path::new("srv"), "t");
    named.env.push(("PATH".into(), path));
    assert_eq!(resolve(&named), Some(late.join("srv")));
    // A path that names a file nobody may run is no program.
    assert_eq!(resolve(&spec(&early.join("srv"), "t")), None);
    // A script an interpreter runs is part of the key: editing it is a new key.
    let script = home.path().join("server.py");
    std::fs::write(&script, "v1").unwrap();
    let mut by_script = spec(&late.join("srv"), "t");
    by_script.args = vec![script.to_string_lossy().into_owned()];
    let before = key(&by_script).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&script, "version two").unwrap();
    assert_ne!(key(&by_script).unwrap(), before);
    assert!(key(&named).is_some());
    // A bare relative script (`python3 server.py`) counts too: the server
    // starts in this process's directory, so the arg names the same file.
    let bare = tempfile::NamedTempFile::new_in(".").unwrap();
    std::fs::write(bare.path(), "v1").unwrap();
    let name = bare.path().file_name().unwrap().to_string_lossy().into_owned();
    assert_eq!(Path::new(&name).components().count(), 1);
    let mut relative = spec(&late.join("srv"), "t");
    relative.args = vec![name];
    let before = key(&relative).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(bare.path(), "version two").unwrap();
    assert_ne!(key(&relative).unwrap(), before);
    // Without the servers own PATH entry, this processs PATH (no `srv`) finds nothing.
    assert_eq!(resolve(&spec(Path::new("srv-not-on-any-path"), "t")), None);
}

#[test]
fn a_list_is_shared_by_chats_and_dropped_when_the_server_changes() {
    let home = tempfile::tempdir().unwrap();
    let binary = home.path().join("cmux-cua");
    std::fs::write(&binary, "v1").unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(&binary, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let a = spec(&binary, "token-a");
    let listing = Listing {
        tools: vec![json!({"name": "look", "inputSchema": {"type": "object"}})],
        instructions: Some("Ask first.".into()),
    };
    let folder = home.path().join("listings");
    assert_eq!(load(&folder, &a), None, "nothing stored yet");
    store(&folder, &a, &key(&a).unwrap(), &listing);
    assert_eq!(load(&folder, &a), Some(listing.clone()));
    // Another chat's spec differs only in its token's value: the same list.
    assert_eq!(load(&folder, &spec(&binary, "token-b")), Some(listing.clone()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&folder).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    // An updated server binary is a new key.
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&binary, "version two").unwrap();
    assert_eq!(load(&folder, &a), None);
    // A torn entry reads as none.
    store(&folder, &a, &key(&a).unwrap(), &listing);
    assert_eq!(load(&folder, &a), Some(listing.clone()));
    for entry in std::fs::read_dir(&folder).unwrap().filter_map(Result::ok) {
        std::fs::write(entry.path(), "{\"tools\": [").unwrap();
    }
    assert_eq!(load(&folder, &a), None);
    // A missing command has no key: nothing is stored or read.
    let gone = spec(&home.path().join("missing"), "t");
    assert_eq!(key(&gone), None);
    assert_eq!(load(&folder, &gone), None);
    // A list read before an update is not stored under the old key.
    let before = key(&a).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&binary, "version three!").unwrap();
    store(&folder, &a, &before, &listing);
    assert_eq!(load(&folder, &a), None);
    store(&folder, &a, &key(&a).unwrap(), &listing);
    assert_eq!(load(&folder, &a), Some(listing));
    // An entry others may read, or a link, is not read.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let entry = folder.join(key(&a).unwrap());
        std::fs::set_permissions(&entry, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(load(&folder, &a), None);
        std::fs::set_permissions(&entry, std::fs::Permissions::from_mode(0o600)).unwrap();
        let elsewhere = home.path().join("elsewhere");
        std::fs::rename(&entry, &elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &entry).unwrap();
        assert_eq!(load(&folder, &a), None);
    }
}
