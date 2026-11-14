use super::*;

fn session(socket: &Path, home: &Path) -> OwnerSession {
    OwnerSession {
        owner_user: "user_owner".into(),
        owner_team: "team_a".into(),
        socket: socket.to_path_buf(),
        brain_home: home.to_path_buf(),
    }
}

fn peer(user: &str, team: &str) -> LinkPeer {
    LinkPeer { install: "inst_b".into(), user: user.into(), team: team.into() }
}

#[test]
fn only_the_owner_user_in_the_owner_team_is_authorized() {
    let config = session(Path::new("/h/daemon/cmux.sock"), Path::new("/h"));
    assert_eq!(config.authorize(&peer("user_owner", "team_a")), Ok(()));
    assert_eq!(config.authorize(&peer("user_other", "team_a")), Err(OwnerRefused::NotOwner));
    assert_eq!(config.authorize(&peer("user_owner", "team_b")), Err(OwnerRefused::NotOwner));
}

#[test]
fn server_json_block_is_optional_but_never_half_valid() -> io::Result<()> {
    assert_eq!(OwnerSession::parse(r#"{"roles":["session"]}"#)?, None);
    let parsed = OwnerSession::parse(
        r#"{"roles":[],"owner_session":{"owner_user":"user_owner","owner_team":"team_a","socket":"/h/daemon/cmux.sock","brain_home":"/h"}}"#,
    )?;
    assert_eq!(parsed, Some(session(Path::new("/h/daemon/cmux.sock"), Path::new("/h"))));
    for bad in [
        r#"{"owner_session":{"owner_user":"","owner_team":"team_a","socket":"/h/s","brain_home":"/h"}}"#,
        r#"{"owner_session":{"owner_user":"u","owner_team":"t","socket":"relative.sock","brain_home":"/h"}}"#,
        r#"{"owner_session":{"owner_user":"u","owner_team":"t","socket":"/h/s","brain_home":"/h","extra":1}}"#,
    ] {
        assert!(OwnerSession::parse(bad).is_err(), "{bad}");
    }
    Ok(())
}

#[test]
fn the_socket_must_be_a_socket_of_this_uid_inside_the_brain_home() -> io::Result<()> {
    let directory = cmux_unix_socket::short_test_dir("ownses");
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon"))?;
    let socket = home.join("daemon/s.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket)?;
    let uid = unsafe { libc::geteuid() };
    let config = session(&socket, &home);
    assert!(config.check_socket(uid).is_ok());
    assert_eq!(config.check_socket(uid.wrapping_add(1)), Err(OwnerRefused::WrongOwner));
    // A regular file is no socket.
    let file = home.join("daemon/file");
    std::fs::write(&file, b"x")?;
    assert_eq!(session(&file, &home).check_socket(uid), Err(OwnerRefused::NotASocket));
    // A symlink to the real socket is refused (no indirection).
    let link = home.join("daemon/link.sock");
    std::os::unix::fs::symlink(&socket, &link)?;
    assert_eq!(session(&link, &home).check_socket(uid), Err(OwnerRefused::NotASocket));
    // A real socket outside the brain home is refused.
    let outside = directory.path().join("o.sock");
    let _other = std::os::unix::net::UnixListener::bind(&outside)?;
    assert_eq!(session(&outside, &home).check_socket(uid), Err(OwnerRefused::OutsideBrainHome));
    // A symlinked parent directory cannot lead out of the brain home.
    let escape = home.join("escape");
    std::os::unix::fs::symlink(directory.path(), &escape)?;
    assert_eq!(
        session(&escape.join("o.sock"), &home).check_socket(uid),
        Err(OwnerRefused::OutsideBrainHome)
    );
    Ok(())
}

#[test]
fn only_a_cmux_tui_with_the_brain_capabilities_is_a_brain() {
    let brain = r#"{"id":1,"ok":true,"data":{"app":"cmux-tui","capabilities":["x","workspace-registry-v1","agent-session-tabs-v1"]}}"#;
    assert!(is_brain_identity(brain));
    assert!(!is_brain_identity(
        r#"{"id":1,"ok":true,"data":{"app":"cmux-tui","capabilities":["workspace-registry-v1"]}}"#
    ));
    assert!(!is_brain_identity(
        r#"{"id":1,"ok":true,"data":{"app":"other","capabilities":["workspace-registry-v1","agent-session-tabs-v1"]}}"#
    ));
    assert!(!is_brain_identity(r#"{"id":1,"ok":false,"data":{}}"#));
    assert!(!is_brain_identity("not json"));
}
