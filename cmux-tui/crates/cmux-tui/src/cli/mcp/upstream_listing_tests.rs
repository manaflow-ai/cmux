use super::super::upstream::upstream_http::Http;
use super::*;

/// A DEV build's `cmux mcp serve` keeps its tool lists in the build's own caches
/// (`CMUX_NEXT_MCP_UPSTREAMS_DIR`, BuildStatePaths), never in `~/.cache/cmux`, which NIGHTLY shares.
#[test]
fn dev_build_own_mcp_upstreams_dir() {
    let env = |name: &str| match name {
        "HOME" => Some("/Users/me".into()),
        "CMUX_NEXT_MCP_UPSTREAMS_DIR" => Some("/tmp/dev-build/mcp-upstreams".into()),
        _ => None,
    };
    assert_eq!(dir_from(env), Some(PathBuf::from("/tmp/dev-build/mcp-upstreams")));
    let shared = |name: &str| (name == "HOME").then(|| "/Users/me".into());
    assert_eq!(dir_from(shared), Some(PathBuf::from("/Users/me/.cache/cmux/mcp-upstreams")));
    let blank = |name: &str| match name {
        "HOME" => Some("/Users/me".into()),
        "CMUX_NEXT_MCP_UPSTREAMS_DIR" => Some("".into()),
        _ => None,
    };
    assert_eq!(dir_from(blank), Some(PathBuf::from("/Users/me/.cache/cmux/mcp-upstreams")));
}

fn spec(command: &Path, token: &str) -> Spec {
    Spec {
        name: "cmux-secrets".into(),
        command: command.to_path_buf(),
        args: vec!["mcp".into()],
        env: vec![("ACPMUX_SECRET_SESSION".into(), token.into())],
        call_timeout: std::time::Duration::from_secs(1),
        shared: None,
        http: None,
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

/// acpmux's gateway serves each chat's own servers at `/mcp/<session>/tools`: two chats' specs
/// differ in that session, the port and the token, and must still share one stored list, or every
/// new chat starts each server to list it before the harness's first turn (cmux#57487). Another
/// path (another server) is another list.
#[test]
fn chats_behind_the_gateway_share_one_list() {
    let home = tempfile::tempdir().unwrap();
    let binary = home.path().join("acpmux");
    std::fs::write(&binary, "v1").unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(&binary, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let at = |port: u16, session: &str, tail: &str| {
        let mut spec = spec(&binary, session);
        spec.http = Some(Http {
            url: format!("http://127.0.0.1:{port}/mcp/{session}/tools{tail}"),
            headers: vec![("Authorization".into(), format!("Bearer {session}-token"))],
        });
        spec
    };
    let a = at(64438, "01a215d2-467a-7207-b972-50269f6313fd", "");
    let b = at(51001, "01a215d2-6c49-7753-825e-c30eaa14be94", "");
    assert_eq!(key(&a), key(&b));
    assert_ne!(key(&a), key(&at(64438, "01a215d2-467a-7207-b972-50269f6313fd", "/cmux-forum")));
    let listing = Listing { tools: vec![json!({"name": "ls"})], instructions: None };
    let folder = home.path().join("listings");
    store(&folder, &a, &key(&a).unwrap(), &listing);
    assert_eq!(load(&folder, &b), Some(listing));
    assert_eq!(std::fs::read_dir(&folder).unwrap().count(), 1);
    assert_eq!(http_path("http://127.0.0.1:1/mcp/s1/tools/x"), "mcp/{session}/tools/x");
    assert_eq!(http_path("http://127.0.0.1:1/other/s1"), "other/s1");
    assert_eq!(http_path("http://127.0.0.1:1"), "");
}

#[test]
fn a_list_is_shared_by_chats_and_dropped_when_the_server_changes() {
    let home = tempfile::tempdir().unwrap();
    let binary = home.path().join("cmux-secrets");
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
