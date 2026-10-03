use super::*;
use cmux_local_auth::ActorKind;
use serde_json::{Value, json};

/// A fresh directory under the system temp dir, removed on drop.
struct ScratchDir(PathBuf);

impl ScratchDir {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-launch-identity-{name}-{}-{unique}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn mux_with_terminal() -> (Arc<Mux>, TerminalPublicId) {
    let mux = Mux::new_for_test("launch-identity", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("terminal tab");
    (mux, terminal)
}

#[test]
fn a_minted_credential_names_its_live_terminal() {
    let (mux, terminal) = mux_with_terminal();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();
    let CredentialCheck::Verified(actor) = mux.check_launch_credential(&credential) else {
        panic!("credential did not verify");
    };
    assert_eq!(actor.kind, ActorKind::Terminal);
    assert_eq!(actor.id, terminal.as_str());
    assert_eq!(actor.host.as_deref(), Some(mux.session_public_id().as_str()));
    assert_eq!(mux.request_actor(true, Some(&credential)).unwrap(), actor);
    mux.shutdown();
}

#[test]
fn tampered_foreign_and_closed_credentials_are_refused() {
    let (mux, terminal) = mux_with_terminal();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();
    let mut tampered = credential.clone();
    tampered.pop();
    tampered.push(if credential.ends_with('A') { 'B' } else { 'A' });
    assert_eq!(
        mux.check_launch_credential(&tampered),
        CredentialCheck::Refused("credential_invalid")
    );
    assert_eq!(
        mux.check_launch_credential("garbage"),
        CredentialCheck::Refused("credential_malformed")
    );

    let foreign = mux
        .launch_identity
        .mint(&Claims {
            v: 1,
            host: "sess_someone_else".into(),
            terminal: Some(terminal.as_str().into()),
            acp_session: None,
            agent: None,
            iat: 0,
        })
        .unwrap();
    assert_eq!(
        mux.check_launch_credential(&foreign),
        CredentialCheck::Refused("credential_foreign_host")
    );

    let closed = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
    let closed = mux.mint_terminal_credential(&closed).unwrap();
    assert_eq!(mux.check_launch_credential(&closed), CredentialCheck::Refused("credential_closed"));

    // A refused credential refuses the request; it is never the user.
    let error = mux.request_actor(true, Some(&tampered)).unwrap_err();
    assert_eq!(error.code, "validation.invalid");
    mux.shutdown();
}

#[test]
fn a_rotated_away_key_falls_back_to_the_user_and_remote_transports_refuse() {
    let (mux, terminal) = mux_with_terminal();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();
    mux.rotate_launch_keys().unwrap();
    assert!(matches!(mux.check_launch_credential(&credential), CredentialCheck::Verified(_)));
    mux.rotate_launch_keys().unwrap();
    assert_eq!(mux.check_launch_credential(&credential), CredentialCheck::UnknownKey);
    assert_eq!(mux.request_actor(true, Some(&credential)).unwrap(), Actor::local_user());
    assert_eq!(mux.request_actor(true, None).unwrap(), Actor::local_user());
    assert_eq!(mux.request_actor(true, Some("")).unwrap(), Actor::local_user());
    let fresh = mux.mint_terminal_credential(&terminal).unwrap();
    assert!(mux.request_actor(false, Some(&fresh)).is_err());
    mux.shutdown();
}

#[test]
fn keys_persist_owner_only_and_reload() {
    let directory = ScratchDir::new("keys");
    let first = LaunchIdentity::load(Some(directory.path()));
    let path = directory.path().join(KEY_DIRECTORY).join(KEY_FILE);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let directory_mode =
            std::fs::metadata(path.parent().unwrap()).unwrap().permissions().mode() & 0o777;
        assert_eq!(directory_mode, 0o700);
    }
    let claims = Claims {
        v: 1,
        host: "sess_a".into(),
        terminal: Some("term_a".into()),
        acp_session: None,
        agent: None,
        iat: 1,
    };
    let credential = first.mint(&claims).unwrap();
    let second = LaunchIdentity::load(Some(directory.path()));
    assert_eq!(second.verify(&credential), Ok(claims));
    std::fs::write(&path, b"not json").unwrap();
    let replaced = LaunchIdentity::load(Some(directory.path()));
    assert_eq!(replaced.verify(&credential), Err(VerifyError::UnknownKey));
    #[cfg(unix)]
    {
        // A widened directory and a stale staged file are narrowed and
        // replaced by the next write.
        use std::os::unix::fs::PermissionsExt;
        let key_directory = path.parent().unwrap();
        std::fs::set_permissions(key_directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        let staged = key_directory.join(format!("{KEY_FILE}.tmp.{}", std::process::id()));
        std::fs::write(&staged, b"stale").unwrap();
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o644)).unwrap();
        replaced.rotate().unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(key_directory), 0o700);
        assert_eq!(mode(&path), 0o600);
        assert!(!staged.exists());
    }
}

#[test]
fn with_no_keys_nothing_is_minted_and_nothing_verifies() {
    let identity = LaunchIdentity { keys: Mutex::new(None), path: None };
    let claims = Claims {
        v: 1,
        host: "sess_a".into(),
        terminal: Some("term_a".into()),
        acp_session: None,
        agent: None,
        iat: 1,
    };
    assert_eq!(identity.mint(&claims), None);
    let other = LaunchKeys::new("k1", [7u8; 32]);
    let credential = other.mint(&claims).unwrap();
    assert_eq!(identity.verify(&credential), Err(VerifyError::UnknownKey));
    // Rotation makes the first key; minting works after it.
    identity.rotate().unwrap();
    assert!(identity.mint(&claims).is_some());
}

#[test]
fn a_terminal_child_receives_its_credential_and_an_inherited_one_never_wins() {
    let directory = ScratchDir::new("env");
    let output = directory.path().join("credential.txt");
    let script =
        format!("printf %s \"$CMUX_LAUNCH_CREDENTIAL\" > '{}'; exec sleep 30", output.display());
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
        extra_env: vec![(LAUNCH_CREDENTIAL_ENV.into(), "cmuxlc1.forged.value.x".into())],
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test("launch-identity-env", options);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("terminal tab");
    let deadline = Instant::now() + Duration::from_secs(10);
    let seen = loop {
        if let Ok(text) = std::fs::read_to_string(&output)
            && !text.is_empty()
        {
            break text;
        }
        assert!(Instant::now() < deadline, "the child never wrote its credential");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_ne!(seen, "cmuxlc1.forged.value.x");
    let CredentialCheck::Verified(actor) = mux.check_launch_credential(&seen) else {
        panic!("the child's credential did not verify");
    };
    assert_eq!(actor.id, terminal.as_str());
    mux.shutdown();
}

fn stored_actor(mux: &Mux, key: &str) -> Option<String> {
    mux.workspace_registry
        .lock()
        .unwrap()
        .read_state(|connection| {
            Ok(connection.query_row(
                "SELECT actor_json FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get::<_, Option<String>>(0),
            )?)
        })
        .unwrap()
}

fn create_workspace(mux: &Arc<Mux>, key: &str, actor: Actor) -> Value {
    let message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("req-{key}"),
        "operation":"workspace.create",
        "params":{"machine":"current","session":"current","name":"actor","initial_content":"empty"},
        "idempotency_key":key,
    });
    let mut request = crate::resource_router::parse_resource_request(&message.to_string()).unwrap();
    request.actor = actor;
    crate::resource_router::handle_parsed_resource_request(mux, request).unwrap()
}

#[test]
fn the_owner_records_the_actor_and_a_replay_keeps_the_first() {
    let (mux, terminal) = mux_with_terminal();
    let credential = mux.mint_terminal_credential(&terminal).unwrap();
    let agent = mux.request_actor(true, Some(&credential)).unwrap();
    let first = create_workspace(&mux, "actor-create", agent.clone());
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(stored_actor(&mux, "actor-create"), Some(agent.to_json()));

    // The same key with another actor is a replay and keeps the first actor.
    let replay = create_workspace(&mux, "actor-create", Actor::local_user());
    assert_eq!(replay["result"]["replayed"], true, "{replay}");
    assert_eq!(stored_actor(&mux, "actor-create"), Some(agent.to_json()));

    let user = create_workspace(&mux, "user-create", Actor::local_user());
    assert_eq!(user["ok"], true, "{user}");
    assert_eq!(stored_actor(&mux, "user-create"), Some(Actor::local_user().to_json()));
    mux.shutdown();
}
