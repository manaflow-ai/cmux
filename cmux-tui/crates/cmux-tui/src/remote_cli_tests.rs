#[test]
fn startup_config_loader_stays_lazy_for_help_and_parse_errors() {
    let load_count = std::cell::Cell::new(0);
    let help_args = ["connect", "--help"].map(str::to_string);
    assert!(
        run_inner(&help_args, "usage", || {
            load_count.set(load_count.get() + 1);
            panic!("remote help must not load startup config");
        })
        .is_ok()
    );

    let invalid_args = ["ssh", "--unknown"].map(str::to_string);
    assert!(
        run_inner(&invalid_args, "usage", || {
            load_count.set(load_count.get() + 1);
            panic!("remote parse errors must not load startup config");
        })
        .is_err()
    );
    assert_eq!(load_count.get(), 0);
}

#[test]
fn probe_capabilities_include_direct_ws_user_agent() {
    assert!(PROBE_CAPABILITIES.contains(&"direct-ws-user-agent"));
    assert!(PROBE_CAPABILITIES.contains(&"wireguard-hub"));
    assert!(PROBE_CAPABILITIES.contains(&"wireguard-hub-token"));
}

#[test]
fn agent_hooks_flag_collects_providers() {
    let args =
        ["host", "--agent-hooks", "claude, codex,", "--agent-hooks", "gemini"].map(str::to_string);
    assert_eq!(direct_ssh_flags(&args).unwrap().agent_hooks, ["claude", "codex", "gemini"]);
    let plain = ["host"].map(str::to_string);
    assert!(direct_ssh_flags(&plain).unwrap().agent_hooks.is_empty());
}

#[test]
fn wireguard_config_and_hub_are_mutually_exclusive() {
    let both = [
        "ws://[fd00::1]:1337/v1/link",
        "--wireguard-config",
        "/tmp/a.conf",
        "--wireguard-hub",
        "/tmp/hub.sock",
    ]
    .map(str::to_string);
    let error = parse_connect_flags(&both).err().expect("both flags must be rejected");
    assert_eq!(error.to_string(), catalog().remote_client.wireguard_hub_conflict);
    let hub_only =
        ["ws://[fd00::1]:1337/v1/link", "--wireguard-hub", "/tmp/hub.sock"].map(str::to_string);
    let flags = parse_connect_flags(&hub_only).unwrap();
    assert_eq!(flags.wireguard_hub, Some(PathBuf::from("/tmp/hub.sock")));
    assert!(flags.wireguard_config.is_none());
    assert!(!flags.exit_with_parent);
    let owned = ["ws://[fd00::1]:1337/v1/link", "--exit-with-parent"].map(str::to_string);
    assert!(parse_connect_flags(&owned).unwrap().exit_with_parent);
}

#[test]
fn only_vm_kind_owner_marks_the_link_as_the_callers_own_vm() {
    let link = "ws://[fd00::1]:1337/v1/link".to_string();
    assert!(!parse_connect_flags(std::slice::from_ref(&link)).unwrap().vm_owner);
    for (kind, owner) in [("owner", true), ("team", false), ("null", false), ("Owner", false)] {
        let args = [link.clone(), "--vm-kind".into(), kind.into()];
        assert_eq!(parse_connect_flags(&args).unwrap().vm_owner, owner, "{kind}");
    }
    assert!(parse_connect_flags(&[link, "--vm-kind".into()]).is_err(), "a value is needed");
}

#[cfg(unix)]
#[test]
fn parent_lifecycle_fence_tracks_the_direct_parent() {
    let parent = current_parent_process_id();
    assert!(parent_process_is(parent));
    assert!(!parent_process_is(parent.wrapping_add(1)));
}

use super::*;

fn seed_legacy_authorization_state(state_dir: &Path) {
    let auth_state_dir = state_dir.join("auth");
    fs::create_dir_all(&auth_state_dir).unwrap();
    fs::write(
        auth_state_dir.join("devices.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "version": 1,
            "revision": 0,
            "revocation_generation": 0,
            "devices": [],
            "invitations": [],
        }))
        .unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn rpc_stdin_wait_stops_when_remote_runtime_finishes_without_eof() {
    let (_stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<io::Result<String>>(1);
    let (finished_tx, mut finished_rx) = tokio::sync::watch::channel(false);
    finished_tx.send_replace(true);

    let event = tokio::time::timeout(
        Duration::from_millis(100),
        next_rpc_input(&mut stdin_rx, &mut finished_rx),
    )
    .await
    .expect("RPC input stayed blocked after the remote runtime finished")
    .unwrap();

    assert!(matches!(event, RpcInputEvent::RuntimeFinished));
}

fn test_provider_registry() -> Arc<cmux_remote::provider::ProviderRegistry> {
    Arc::new(
        client_provider_registry(
            SshProviderConfig::default(),
            BTreeMap::new(),
            IrohPathMode::Auto,
            None,
            false,
        )
        .unwrap(),
    )
}

#[cfg(unix)]
#[tokio::test]
async fn stdio_proxy_rejects_failed_peer_authentication_before_forwarding_data() {
    use cmux_remote::admin::UnixPeerAuthError;
    use tokio::io::AsyncReadExt;
    use tokio::net::UnixListener;

    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("impostor-link.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let responder = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut byte = [0_u8; 1];
        tokio::time::timeout(Duration::from_secs(1), stream.read(&mut byte))
            .await
            .expect("stdio proxy kept the rejected connection open")
            .unwrap()
    });
    let expected_uid = unsafe { libc::geteuid() };
    let peer_uid = expected_uid.wrapping_add(1);

    let error = proxy_stdio_with_io(&socket, tokio::io::empty(), tokio::io::sink(), |_| {
        Err(UnixPeerAuthError::WrongUid { peer_uid, expected_uid })
    })
    .await
    .unwrap_err();

    assert!(matches!(
        error.downcast_ref::<UnixPeerAuthError>(),
        Some(UnixPeerAuthError::WrongUid { .. })
    ));
    assert_eq!(responder.await.unwrap(), 0, "stdio data leaked to the rejected Unix responder");
}

#[test]
fn initial_ssh_bootstrap_uses_startup_budget_not_reconnect_attempt_budget() {
    let startup_timeout = Duration::from_secs(2);
    let flags = ConnectFlags {
        reconnect: ReconnectPolicy {
            attempt_timeout: Duration::from_millis(20),
            ..ReconnectPolicy::default()
        },
        auto_install: true,
        upgrade: true,
        ..ConnectFlags::default()
    };

    let bootstrap = initial_ssh_bootstrap_options(&flags, startup_timeout);
    assert_eq!(bootstrap.attempt_timeout, startup_timeout);
    assert_ne!(bootstrap.attempt_timeout, flags.reconnect.attempt_timeout);
    assert!(bootstrap.auto_install);
    assert!(bootstrap.upgrade);
}

#[test]
fn ssh_forced_command_reaches_the_bootstrap_and_refuses_upgrade() {
    let flags = parse_connect_flags(&["--ssh-forced-command".into()]).unwrap();
    let bootstrap = initial_ssh_bootstrap_options(&flags, Duration::from_secs(2));
    assert!(bootstrap.forced_command);
    assert!(
        !initial_ssh_bootstrap_options(&ConnectFlags::default(), Duration::from_secs(2))
            .forced_command
    );

    let error = parse_connect_flags(&["--ssh-forced-command".into(), "--upgrade".into()])
        .err()
        .expect("--upgrade over a forced-command key must be refused");
    assert!(error.to_string().contains("--ssh-forced-command"), "{error:#}");
}

#[test]
fn iroh_url_query_becomes_non_secret_routing_hints() {
    let mut url =
        Url::parse("iroh://abc?relay=https%3A%2F%2Frelay.example&direct=127.0.0.1%3A1234").unwrap();
    let mut routing = BTreeMap::new();
    extract_iroh_routing(&mut url, &mut routing).unwrap();
    assert_eq!(url.as_str(), "iroh://abc");
    assert_eq!(routing[ROUTING_RELAY_URL], "https://relay.example");
    assert_eq!(routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:1234");
}

#[cfg(feature = "iroh-transport")]
#[test]
fn iroh_route_candidates_keep_query_hints_isolated() {
    let routes = [
        "iroh://first?relay=https%3A%2F%2Ffirst-relay.example&direct=127.0.0.1%3A1111".to_string(),
        "iroh://second?relay=https%3A%2F%2Fsecond-relay.example&direct=127.0.0.1%3A2222"
            .to_string(),
    ];

    let candidates =
        resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry()).unwrap();

    assert_eq!(candidates[0].endpoint.as_str(), "iroh://first");
    assert_eq!(candidates[0].routing[ROUTING_RELAY_URL], "https://first-relay.example");
    assert_eq!(candidates[0].routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:1111");
    assert_eq!(candidates[1].endpoint.as_str(), "iroh://second");
    assert_eq!(candidates[1].routing[ROUTING_RELAY_URL], "https://second-relay.example");
    assert_eq!(candidates[1].routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:2222");
}

#[test]
fn unsupported_future_route_does_not_block_supported_fallback() {
    let routes = [
        "future+quic://user:secret@future.example/capability?ticket=secret".to_string(),
        "wss://supported.example/v1/link".to_string(),
    ];

    let candidates =
        resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry()).unwrap();

    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].endpoint.as_str(), "wss://supported.example/v1/link");
}

#[test]
fn unsupported_routes_report_schemes_without_endpoint_secrets() {
    let routes = [
        "future+quic://user:password@future.example/private-capability?ticket=route-secret"
            .to_string(),
        "next+tcp://other.example/another-secret".to_string(),
    ];

    let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
        .expect_err("unsupported routes should fail");
    let message = error.to_string();

    assert!(message.contains("future+quic"));
    assert!(message.contains("next+tcp"));
    for secret in ["user", "password", "private-capability", "route-secret", "another-secret"] {
        assert!(!message.contains(secret), "{secret:?} leaked in {message:?}");
    }
}

#[test]
fn malformed_route_errors_do_not_echo_credentials() {
    let routes = ["wss://dont-leak-me@[".to_string()];

    let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
        .expect_err("malformed route should fail");

    assert!(!error.to_string().contains("dont-leak-me"));
}

#[test]
fn unsupported_route_parameters_do_not_echo_query_credentials() {
    let routes = ["iroh://node?query-secret-marker=value".to_string()];

    let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
        .expect_err("unsupported route parameter should fail");

    assert!(!error.to_string().contains("query-secret-marker"));
}

#[test]
fn generic_route_resolution_rejects_option_like_ssh_destinations() {
    let routes = ["ssh://-Fvalidation@localhost".to_string()];

    let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
        .expect_err("option-like SSH destination should fail");

    assert!(error.to_string().contains("safe OpenSSH destination"));
}

#[test]
fn parse_lane_policy_and_relay_flags() {
    let args = [
        "relay+wss://host",
        "--lanes",
        "isolated",
        "--relay-slot",
        "slot",
        "--relay-ticket-command",
        "ticket-command",
    ]
    .map(str::to_string);
    let parsed = parse_connect_flags(&args).unwrap();
    assert_eq!(parsed.lanes, LanePolicy::Isolated);
    assert!(parsed.lanes_explicit);
    assert_eq!(parsed.relay_slots, ["slot"]);
    assert_eq!(parsed.relay_credentials.len(), 1);
}

#[test]
fn hub_token_comes_from_stdin_only_with_a_hub() {
    let route = "ws://[fd7a::10]:1337/v1/link".to_string();
    let parse = |extra: &[&str]| {
        let mut args = vec![route.clone()];
        args.extend(extra.iter().map(|value| value.to_string()));
        parse_connect_flags(&args)
    };
    let flags =
        parse(&["--wireguard-hub", "/tmp/hub.sock", "--wireguard-hub-token-stdin"]).unwrap();
    assert!(flags.wireguard_hub_token_stdin);
    let error = parse(&["--wireguard-hub-token-stdin"]).err().unwrap();
    assert_eq!(error.to_string(), catalog().remote_client.wireguard_hub_token_needs_hub);
    let error = parse(&[
        "--wireguard-hub",
        "/tmp/hub.sock",
        "--wireguard-hub-token-stdin",
        "--invite-file",
        "-",
    ])
    .err()
    .unwrap();
    assert_eq!(error.to_string(), catalog().remote_client.stdin_claimed_twice);

    let token = read_hub_token_line(&mut &b"0123abcd\nrest"[..]).unwrap();
    assert_eq!(token.as_str(), "0123abcd");
    assert_eq!(read_hub_token_line(&mut &b"0123abcd\r\n"[..]).unwrap().as_str(), "0123abcd");
    assert!(read_hub_token_line(&mut &b"\n"[..]).is_err(), "an empty token is refused");
    assert!(read_hub_token_line(&mut &[b'a'; 300][..]).is_err(), "over 255 bytes is refused");
}

#[test]
fn invitation_file_parser_is_unambiguous_and_help_safe() {
    let parsed = parse_connect_flags(&[
        "ws://daemon.example/v1/link".into(),
        "--invite-file".into(),
        "-".into(),
    ])
    .unwrap();
    assert!(matches!(
        parsed.invitation,
        Some(InvitationArg::File(path)) if path == Path::new("-")
    ));
    assert!(!remote_help_requested(&["--invite-file".into(), "-h".into()]));

    let args = ["--invite-file", "first", "--invite-file", "second"]
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    assert!(parse_connect_flags(&args).is_err(), "unexpectedly accepted {args:?}");
}

#[test]
fn positional_invitations_are_rejected_before_loading_or_connecting() {
    let error = parse_connect_flags(&["cmux://enroll/positional-secret".into()])
        .err()
        .expect("positional invitation should fail");
    assert!(!error.to_string().contains("positional-secret"));
}

#[test]
fn invitation_input_accepts_one_lf_or_crlf_and_preserves_following_stdin() {
    for input in [b"cmux://enroll/value\n".as_slice(), b"cmux://enroll/value\r\n"] {
        let mut input = io::Cursor::new(input);
        assert_eq!(&*read_invitation_uri_to_end(&mut input).unwrap(), "cmux://enroll/value");
    }

    let mut input = io::Cursor::new(b"cmux://enroll/value\nrpc-request\n");
    assert_eq!(&*read_invitation_uri_line(&mut input).unwrap(), "cmux://enroll/value");
    let mut remaining = String::new();
    input.read_to_string(&mut remaining).unwrap();
    assert_eq!(remaining, "rpc-request\n");
}

#[test]
fn invitation_input_rejects_malformed_data_without_echoing_it() {
    let secret = "do-not-echo-this-secret";
    let malformed = [
        Vec::new(),
        format!("cmux://enroll/{secret}\nsecond").into_bytes(),
        vec![0xff, 0xfe, 0xfd],
        vec![b'x'; MAX_INVITATION_URI_BYTES + 1],
    ];
    for bytes in malformed {
        let error = read_invitation_uri_to_end(&mut io::Cursor::new(bytes))
            .expect_err("malformed invitation should fail");
        assert!(!error.to_string().contains(secret));
    }
}

#[cfg(unix)]
#[test]
fn invitation_file_requires_owner_only_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().unwrap();
    let invitation = directory.path().join("invitation");
    fs::write(&invitation, "cmux://enroll/value\n").unwrap();
    fs::set_permissions(&invitation, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(&*read_invitation_uri(&invitation).unwrap(), "cmux://enroll/value");

    fs::set_permissions(&invitation, fs::Permissions::from_mode(0o640)).unwrap();
    assert!(read_invitation_uri(&invitation).is_err());
}

#[cfg(unix)]
#[test]
fn invitation_file_rejects_non_regular_paths_without_blocking() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let directory = tempfile::tempdir().unwrap();
    let fifo = directory.path().join("invitation.fifo");
    let fifo_path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);

    let started = Instant::now();
    let error = read_invitation_uri(&fifo).unwrap_err().to_string();
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(error.contains("regular file"));
}

#[test]
fn carrier_flag_is_off_by_default_and_needs_no_value() {
    let default = parse_connect_flags(&["ws://10.0.0.5:1337/v1/link".into()]).unwrap();
    assert!(!default.carrier);
    let carrier =
        parse_connect_flags(&["ws://10.0.0.5:1337/v1/link".into(), "--carrier".into()]).unwrap();
    assert!(carrier.carrier);
    assert_eq!(carrier.route.as_deref(), Some("ws://10.0.0.5:1337/v1/link"));
    let registry = client_provider_registry(
        SshProviderConfig::default(),
        BTreeMap::new(),
        IrohPathMode::Auto,
        None,
        true,
    )
    .unwrap();
    assert_eq!(
        registry.supported_client_auth("ws").unwrap(),
        SupportedClientAuthModes::DeviceOrCarrier
    );
    let registry = client_provider_registry(
        SshProviderConfig::default(),
        BTreeMap::new(),
        IrohPathMode::Auto,
        None,
        false,
    )
    .unwrap();
    assert_eq!(registry.supported_client_auth("ws").unwrap(), SupportedClientAuthModes::DeviceOnly);
}

#[test]
fn ssh_can_distinguish_transport_default_from_an_explicit_lane_policy() {
    let default = parse_connect_flags(&["host".into()]).unwrap();
    assert!(!default.lanes_explicit);
    let explicit =
        parse_connect_flags(&["host".into(), "--lanes".into(), "isolated".into()]).unwrap();
    assert!(explicit.lanes_explicit);
}

#[tokio::test]
async fn explicit_daemon_pins_carrier_routes_while_unpinned_routes_discover() {
    let directory = tempfile::tempdir().unwrap();
    let store = ClientIdentityStore::load_or_create(directory.path()).unwrap();
    let key = cmux_remote::crypto::StaticIdentity::generate().unwrap().public_key();
    let known = store
        .pin_carrier_daemon("remote".into(), key, vec!["ssh://remote.example".into()])
        .await
        .unwrap();

    for route in ["ssh://remote.example", "unix:///tmp/cmux-remote.sock"] {
        let pinned = select_explicit_route_identity(
            &store,
            Some(&known.fingerprint),
            route,
            SupportedClientAuthModes::DeviceOrCarrier,
        )
        .await
        .unwrap();
        assert!(matches!(pinned.auth, ClientAuthMode::Carrier));
        assert_eq!(pinned.expected_daemon, Some(key));
        assert_eq!(
            pinned.known.as_ref().map(|daemon| &daemon.fingerprint),
            Some(&known.fingerprint)
        );
        assert!(!pinned.carrier_discovery);

        let unpinned = select_explicit_route_identity(
            &store,
            None,
            route,
            SupportedClientAuthModes::DeviceOrCarrier,
        )
        .await
        .unwrap();
        assert!(matches!(unpinned.auth, ClientAuthMode::Carrier));
        assert!(unpinned.expected_daemon.is_none());
        assert!(unpinned.known.is_none());
        assert!(unpinned.carrier_discovery);
    }

    assert!(
        select_explicit_route_identity(
            &store,
            Some("unknown"),
            "ssh://remote.example",
            SupportedClientAuthModes::DeviceOrCarrier,
        )
        .await
        .is_err()
    );
}

#[test]
fn remote_mux_socket_flag_reaches_the_ssh_provider() {
    let flags = parse_connect_flags(&[
        "ssh://server.example".into(),
        "--remote-mux-socket".into(),
        "~/.cmux/brains/chief/daemon/cmux.sock".into(),
    ])
    .unwrap();
    assert_eq!(flags.remote_mux_socket.as_deref(), Some("~/.cmux/brains/chief/daemon/cmux.sock"));
}

#[test]
fn connection_json_diagnostics_require_headless_mode() {
    assert!(parse_connect_flags(&["unix:///tmp/cmux.sock".into(), "--json".into()]).is_err());
    let flags = parse_connect_flags(&[
        "unix:///tmp/cmux.sock".into(),
        "--headless".into(),
        "--json".into(),
    ])
    .unwrap();
    assert!(flags.headless);
    assert!(flags.json);
}

#[test]
fn parses_explicit_iroh_path_policy() {
    for (value, expected) in [
        ("auto", IrohPathMode::Auto),
        ("direct-only", IrohPathMode::DirectOnly),
        ("relay-only", IrohPathMode::RelayOnly),
    ] {
        let flags =
            parse_connect_flags(&["iroh://node".into(), "--iroh-path".into(), value.into()])
                .unwrap();
        assert_eq!(flags.iroh_path, expected);
    }
    assert!(
        parse_connect_flags(&["iroh://node".into(), "--iroh-path".into(), "direct".into(),])
            .is_err()
    );
}

#[test]
fn help_detection_does_not_consume_ssh_argument_values() {
    assert!(!remote_help_requested(&["host".into(), "--ssh-arg".into(), "-h".into()]));
    assert!(!remote_help_requested(&["--invite-file".into(), "-h".into()]));
    assert!(remote_help_requested(&["host".into(), "--help".into()]));
    assert!(!remote_help_requested(&["--invite".into(), "inline-secret".into(), "--help".into(),]));
    assert!(!remote_help_requested(&[
        "--relay-ticket".into(),
        "inline-secret".into(),
        "--help".into(),
    ]));
    assert!(!remote_help_requested(&["--help".into(), "--invite".into(), "inline-secret".into(),]));
    assert!(!remote_help_requested(&["--invite=inline-secret".into(), "--help".into(),]));
    assert!(!remote_help_requested(&["--relay-ticket=inline-secret".into(), "--help".into(),]));
    assert!(
        parse_connect_flags(&["--help".into(), "--invite".into(), "inline-secret".into(),])
            .is_err()
    );
}

#[test]
fn reconnect_backoff_is_configurable() {
    let args = [
        "ws://host/v1/link",
        "--reconnect-attempts",
        "7",
        "--reconnect-initial-ms",
        "25",
        "--reconnect-max-ms",
        "400",
        "--reconnect-attempt-timeout-ms",
        "2000",
        "--reconnect-jitter",
        "none",
        "--heartbeat-interval-ms",
        "1000",
        "--heartbeat-timeout-ms",
        "3000",
    ]
    .map(str::to_string);
    let parsed = parse_connect_flags(&args).unwrap();
    // Accepted for old apps, but no cap: the link keeps redialing while it is held.
    assert_eq!(parsed.reconnect.maximum_attempts, None);
    assert_eq!(parsed.reconnect.initial_delay, Duration::from_millis(25));
    assert_eq!(parsed.reconnect.maximum_delay, Duration::from_millis(400));
    assert_eq!(parsed.reconnect.attempt_timeout, Duration::from_secs(2));
    assert!(!parsed.reconnect.full_jitter);
    assert_eq!(parsed.reconnect.heartbeat_interval, Some(Duration::from_secs(1)));
    assert_eq!(parsed.reconnect.heartbeat_timeout, Duration::from_secs(3));
}

#[test]
fn every_remote_subcommand_help_exits_without_running_the_command() {
    for command in ["connect", "ssh", "forward", "dial-tcp", "rpc", "enroll", "remote-probe"] {
        let args = [command.to_string(), "--help".to_string()];
        assert!(
            run_inner(&args, "unused", || panic!("help must not load TUI config")).is_ok(),
            "{command}"
        );
        assert!(remote_help(Some(command)).starts_with("USAGE:"));
    }
}

#[test]
fn rpc_stdin_rejects_an_oversized_line_without_consuming_the_whole_line() {
    let mut input = io::Cursor::new(vec![b'x'; 4_096]);
    let error =
        read_rpc_stdin_line(&mut input, 64).expect_err("oversized RPC input should be rejected");

    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert!(
        input.position() <= 65,
        "RPC reader consumed {} bytes before enforcing a 64-byte limit",
        input.position()
    );
}

#[test]
fn rpc_stdin_accepts_exact_limit_for_lf_crlf_and_eof() {
    for input in [b"1234\n".as_slice(), b"1234\r\n", b"1234"] {
        let mut input = io::Cursor::new(input);
        assert_eq!(read_rpc_stdin_line(&mut input, 4).unwrap().as_deref(), Some("1234"));
        assert_eq!(read_rpc_stdin_line(&mut input, 4).unwrap(), None);
    }
}

#[test]
fn rpc_stdin_rejects_invalid_utf8_within_the_limit() {
    let mut input = io::Cursor::new([0xff, b'\n']);
    let error = read_rpc_stdin_line(&mut input, 4).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
}

#[cfg(unix)]
#[test]
fn local_unix_route_is_promoted_and_remote_unix_route_is_demoted() {
    let directory = tempfile::tempdir().unwrap();
    let local_path = directory.path().join("remote.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&local_path).unwrap();
    let local = Url::parse(&format!("unix://{}", local_path.display())).unwrap();
    let missing =
        Url::parse(&format!("unix://{}", directory.path().join("missing.sock").display())).unwrap();
    let websocket = Url::parse("wss://daemon.example/v1/link").unwrap();
    let providers = test_provider_registry();
    let candidate =
        |endpoint| ResolvedRouteCandidate::resolve(endpoint, BTreeMap::new(), &providers).unwrap();
    let mut routes =
        vec![candidate(missing.clone()), candidate(websocket.clone()), candidate(local.clone())];

    promote_reachable_unix_routes(&mut routes);

    assert_eq!(routes, [candidate(local), candidate(websocket), candidate(missing)]);
}

#[test]
fn sidecar_mux_monitor_detects_the_connected_server_closing() {
    let directory = tempfile::tempdir().unwrap();
    let mux = directory.path().join("mux.sock");
    let listener = std::os::unix::net::UnixListener::bind(&mux).unwrap();
    let (accepted_tx, accepted_rx) = std::sync::mpsc::sync_channel(1);
    let (close_tx, close_rx) = std::sync::mpsc::sync_channel(1);
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        accepted_tx.send(()).unwrap();
        close_rx.recv().unwrap();
        drop(stream);
    });
    let mut monitor = open_mux_monitor(&mux).unwrap();
    accepted_rx.recv().unwrap();

    assert!(!mux_monitor_disconnected(&mut monitor, &mux).unwrap());
    close_tx.send(()).unwrap();
    server.join().unwrap();
    assert!(mux_monitor_disconnected(&mut monitor, &mux).unwrap());
}

#[cfg(unix)]
#[test]
fn daemon_state_files_are_private_and_existing_permissions_are_tightened() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let directory = tempfile::tempdir().unwrap();
    let log_path = directory.path().join("daemon.log");
    fs::write(&log_path, b"old log\n").unwrap();
    fs::set_permissions(&log_path, fs::Permissions::from_mode(0o644)).unwrap();

    let mut log = open_private_daemon_file(&log_path, true).unwrap();
    log.write_all(b"new log\n").unwrap();
    let metadata = fs::metadata(&log_path).unwrap();
    assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(metadata.nlink(), 1);
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::read_to_string(&log_path).unwrap(), "old log\nnew log\n");

    let lock_path = directory.path().join("start.lock");
    let lock = open_private_daemon_file(&lock_path, false).unwrap();
    assert_eq!(fs::metadata(&lock_path).unwrap().permissions().mode() & 0o777, 0o600);
    drop(lock);
}

#[cfg(unix)]
#[test]
fn daemon_state_files_refuse_symlinks_without_touching_target() {
    let directory = tempfile::tempdir().unwrap();
    let target = directory.path().join("target.log");
    let link = directory.path().join("daemon.log");
    fs::write(&target, b"keep\n").unwrap();
    std::os::unix::fs::symlink(&target, &link).unwrap();

    let error = open_private_daemon_file(&link, true).unwrap_err();
    assert_eq!(error.raw_os_error(), Some(libc::ELOOP));
    assert_eq!(fs::read_to_string(&target).unwrap(), "keep\n");
}

#[cfg(unix)]
#[test]
fn daemon_state_fifo_is_rejected_without_blocking() {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
    use std::sync::mpsc;

    let directory = tempfile::tempdir().unwrap();
    let fifo = directory.path().join("daemon.log");
    let fifo_bytes = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    let result = unsafe { libc::mkfifo(fifo_bytes.as_ptr(), 0o600) };
    assert_eq!(result, 0, "mkfifo failed: {}", io::Error::last_os_error());

    let (sender, receiver) = mpsc::channel();
    let path = fifo.clone();
    let worker = thread::spawn(move || {
        sender.send(open_private_daemon_file(&path, true).map(|_| ())).unwrap();
    });

    let outcome = receiver.recv_timeout(Duration::from_secs(1));
    if outcome.is_err() {
        // Release a writer that used blocking open in an unfixed build so
        // this regression test fails promptly instead of leaking a thread.
        let reader =
            OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&fifo).unwrap();
        let _ = receiver.recv_timeout(Duration::from_secs(1));
        drop(reader);
        worker.join().unwrap();
        panic!("opening a daemon FIFO blocked before type validation");
    }
    worker.join().unwrap();
    let error = outcome.unwrap().unwrap_err();
    assert!(
        error.kind() == io::ErrorKind::InvalidInput || error.raw_os_error() == Some(libc::ENXIO),
        "unexpected FIFO rejection: {error}"
    );
    assert!(fs::symlink_metadata(&fifo).unwrap().file_type().is_fifo());
}

#[cfg(unix)]
#[test]
fn daemon_state_lock_rejects_insecure_parent_before_creation() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().unwrap();
    let shared = directory.path().join("shared");
    fs::create_dir(&shared).unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o777)).unwrap();
    let state = shared.join("sessions").join("main");

    let error = lock_daemon_start(&state).unwrap_err();
    assert!(error.to_string().contains("secure daemon state directory"));
    assert!(!state.exists());
}

#[cfg(unix)]
#[test]
fn daemon_state_lock_rejects_symlink_parent_before_creation() {
    let directory = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let alias = directory.path().join("alias");
    std::os::unix::fs::symlink(target.path(), &alias).unwrap();
    let state = alias.join("sessions").join("main");

    let error = lock_daemon_start(&state).unwrap_err();
    assert!(error.to_string().contains("secure daemon state directory"));
    assert!(!target.path().join("sessions").exists());
}

/// `/bin/sh -c script` in its own process group, as the mux owner starts.
#[cfg(unix)]
fn spawn_detached_shell(script: &str) -> Child {
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(script);
    configure_detached_process(&mut command);
    command.spawn().unwrap()
}

/// A mux owner that exits says why, from its own last log line: a session
/// another daemon owns names the way out instead of only the log path.
#[cfg(unix)]
#[test]
fn owner_that_exits_on_an_owned_session_says_the_session_is_in_use() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("missing.sock");
    let log = directory.path().join("daemon.log");
    fs::write(&log, "cmux-tui: an older run's line\n").unwrap();
    let mut child = spawn_detached_shell(&format!(
        "echo 'cmux-tui: workspace session is already owned by another daemon: /s/main-1f.lock: try_lock failed' >> '{}'; exit 1",
        log.display()
    ));

    let error = wait_for_detached_socket(
        &mut child,
        &socket,
        Duration::from_secs(10),
        "remote mux owner",
        &log,
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("in use by another cmux daemon"), "{error}");
    assert!(error.contains("--session"), "{error}");
    assert!(error.contains(&log.display().to_string()), "{error}");
}

#[cfg(unix)]
#[test]
fn owner_that_exits_names_its_last_log_line() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("missing.sock");
    let log = directory.path().join("daemon.log");
    let mut child = spawn_detached_shell(&format!(
        "echo 'cmux-tui: cannot open session \"main\": its saved state is incompatible' >> '{}'; exit 1",
        log.display()
    ));

    let error = wait_for_detached_socket(
        &mut child,
        &socket,
        Duration::from_secs(10),
        "remote mux owner",
        &log,
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("its saved state is incompatible"), "{error}");
}

#[cfg(unix)]
#[test]
fn timed_out_detached_child_is_killed_and_reaped() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("missing.sock");
    let log = directory.path().join("daemon.log");
    let mut child = spawn_detached_shell("exec /bin/sleep 30");
    let pid = child.id() as libc::pid_t;

    let error = wait_for_detached_socket(
        &mut child,
        &socket,
        Duration::from_millis(100),
        "test detached child",
        &log,
    )
    .unwrap_err();
    let survived_timeout = child.try_wait().unwrap().is_none();
    if survived_timeout {
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
        child.wait().unwrap();
    }

    assert!(error.to_string().contains("did not create"), "{error:#}");
    assert!(!survived_timeout, "timed-out detached child was left running");
}

#[test]
fn enrollment_startup_covers_invitation_and_approval_windows() {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let invitation = EnrollmentInvitation {
        version: 1,
        id: "id".into(),
        secret: "secret".into(),
        daemon_public_key: "key".into(),
        daemon_fingerprint: "fingerprint".into(),
        daemon_name: "daemon".into(),
        expires_at_unix: now + 120,
        route_hints: vec![],
        relay_access: vec![],
        approval_required: true,
    };

    assert!(
        invitation_timeout(&invitation) >= Duration::from_secs(120) + ENROLLMENT_APPROVAL_TIMEOUT
    );
}

#[test]
fn relay_credentials_support_exact_route_scoped_forms() {
    let routes = client_relay_options(
        Some("relay+wss://native.example"),
        vec![],
        vec!["slot".into()],
        vec![ClientRelayCredentialArg::File("ticket".into())],
    )
    .unwrap();
    let native_route = Url::parse("relay+wss://native.example").unwrap().to_string();
    assert_eq!(routes[&native_route].slot, "slot");

    let routes = client_relay_options(
        None,
        vec!["relay+wss://native.example".into(), "relay+do://worker.example".into()],
        vec!["native-slot".into(), "do-slot".into()],
        vec![
            ClientRelayCredentialArg::Command { program: "native-ticket".into(), args: vec![] },
            ClientRelayCredentialArg::File("do-ticket".into()),
        ],
    )
    .unwrap();
    let durable_object_route = Url::parse("relay+do://worker.example").unwrap().to_string();
    assert_eq!(routes[&native_route].slot, "native-slot");
    assert_eq!(routes[&durable_object_route].slot, "do-slot");

    assert!(
        client_relay_options(
            Some("relay+wss://native.example"),
            vec![],
            vec!["slot".into(), "extra".into()],
            vec![
                ClientRelayCredentialArg::File("ticket".into()),
                ClientRelayCredentialArg::File("extra".into()),
            ],
        )
        .is_err()
    );
    assert!(
        client_relay_options(
            None,
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        )
        .is_err()
    );
    assert!(
        client_relay_options(
            Some("wss://not-a-relay.example/v1/link"),
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        )
        .is_err()
    );
}

#[test]
fn connect_rejects_inline_invitation_and_ticket_arguments() {
    let marker = "inline-secret-marker";
    for args in [
        vec!["--invite".to_string(), marker.to_string()],
        vec!["--relay-ticket".to_string(), marker.to_string()],
        vec![format!("--invite={marker}")],
        vec![format!("--relay-ticket={marker}")],
    ] {
        let Err(error) = parse_connect_flags(&args) else {
            panic!("inline secret arguments were accepted: {args:?}");
        };
        assert!(!error.to_string().contains(marker));
    }
}

#[test]
fn enroll_create_rejects_inline_relay_ticket() {
    let marker = "inline-enrollment-secret-marker";
    for args in [
        vec![
            "create".to_string(),
            "--relay-route".to_string(),
            "relay+wss://relay.example".to_string(),
            "--relay-slot".to_string(),
            "slot".to_string(),
            "--relay-ticket".to_string(),
            marker.to_string(),
        ],
        vec!["create".to_string(), format!("--relay-ticket={marker}")],
    ] {
        let Err(error) = parse_enroll_admin_args(&args) else {
            panic!("inline enrollment relay ticket was accepted");
        };
        assert!(!error.to_string().contains(marker));
    }
}

#[test]
fn enrollment_positionals_ignore_owner_options() {
    let args = [
        "disconnect",
        "--session",
        "dev",
        "device-id",
        "--json",
        "0123456789abcdef0123456789abcdef",
    ]
    .map(str::to_string);
    let parsed = parse_enroll_admin_args(&args).unwrap();
    assert_eq!(parsed.positionals, ["device-id", "0123456789abcdef0123456789abcdef"]);
    assert_eq!(parsed.session, "dev");
    assert!(parsed.json);
}

#[test]
fn enrollment_positionals_accept_url_safe_identifiers_beginning_with_hyphen() {
    let approve =
        ["approve", "-mRUA1nkvEa07LQJx8XtvQ", "--admin-socket", "/tmp/cmux-admin.sock", "--json"]
            .map(str::to_string);
    assert_eq!(parse_enroll_admin_args(&approve).unwrap().positionals, ["-mRUA1nkvEa07LQJx8XtvQ"]);

    let deny = ["deny", "--admin-socket", "/tmp/cmux-admin.sock", "-another-url-safe-id", "--json"]
        .map(str::to_string);
    assert_eq!(parse_enroll_admin_args(&deny).unwrap().positionals, ["-another-url-safe-id"]);

    let disconnect = ["disconnect", "--session", "dev", "-device-id", "-session-id", "--json"]
        .map(str::to_string);
    assert_eq!(
        parse_enroll_admin_args(&disconnect).unwrap().positionals,
        ["-device-id", "-session-id"]
    );
}

#[test]
fn enrollment_admin_parser_rejects_unknown_duplicate_missing_and_inapplicable_arguments() {
    for args in [
        vec!["status", "--wat"],
        vec!["status", "--json", "--json"],
        vec!["status", "--state-dir"],
        vec!["status", "--ttl", "60"],
        vec!["status", "unexpected"],
        vec!["approve"],
        vec!["approve", "id", "extra"],
        vec!["disconnect", "device-only"],
        vec!["disconnect", "device", "session", "extra"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert!(parse_enroll_admin_args(&args).is_err(), "unexpectedly accepted {args:?}");
    }
}

#[test]
fn known_daemon_parser_is_strict_and_supports_forget() {
    let parsed = parse_known_daemons_args(
        &["forget", "fingerprint", "--state-dir", "/tmp/client-state", "--json"]
            .map(str::to_string),
    )
    .unwrap();
    assert_eq!(parsed.action, KnownDaemonsAction::Forget("fingerprint".into()));
    assert_eq!(parsed.state_dir, Some("/tmp/client-state".into()));
    assert!(parsed.json);

    for args in [
        vec!["forget"],
        vec!["forget", "fingerprint", "extra"],
        vec!["list", "extra"],
        vec!["--json", "--json"],
        vec!["--state-dir"],
        vec!["--unknown"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert!(parse_known_daemons_args(&args).is_err(), "unexpectedly accepted {args:?}");
    }
}

#[test]
fn remote_stop_parser_rejects_ambiguous_admin_arguments() {
    let parsed = parse_remote_stop_args(
        &["--session", "dev", "--state-dir", "/tmp/remote-state"].map(str::to_string),
    )
    .unwrap();
    assert_eq!(parsed.session, "dev");
    assert_eq!(parsed.state_dir, Some("/tmp/remote-state".into()));
    assert!(!parsed.acknowledge_failed_finalization);
    assert!(!parsed.acknowledge_legacy_finalization);
    assert!(
        parse_remote_stop_args(&["--acknowledge-failed-finalization".into()])
            .unwrap()
            .acknowledge_failed_finalization
    );
    assert!(
        parse_remote_stop_args(&["--acknowledge-legacy-finalization".into()])
            .unwrap()
            .acknowledge_legacy_finalization
    );

    for args in [
        vec!["--session"],
        vec!["--session", "dev", "--session", "other"],
        vec!["--state-dir"],
        vec!["--acknowledge-failed-finalization", "--acknowledge-failed-finalization"],
        vec!["--acknowledge-legacy-finalization", "--acknowledge-legacy-finalization"],
        vec!["--acknowledge-failed-finalization", "--acknowledge-legacy-finalization"],
        vec!["--unknown"],
        vec!["unexpected"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert!(parse_remote_stop_args(&args).is_err(), "unexpectedly accepted {args:?}");
    }
}

#[test]
fn remote_stop_recovery_copy_uses_selected_locale() {
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "remote_cli::tests::remote_stop_recovery_copy_locale_fixture",
            "--nocapture",
        ])
        .env("CMUX_TEST_REMOTE_STOP_LOCALE_FIXTURE", "1")
        .env("LC_ALL", "ja_JP.UTF-8")
        .status()
        .unwrap();

    assert!(status.success(), "Japanese remote-stop recovery copy was not localized");
}

#[test]
fn remote_client_help_and_parser_errors_use_selected_locale() {
    let status = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "remote_cli::tests::remote_client_locale_fixture", "--nocapture"])
        .env("CMUX_TEST_REMOTE_CLIENT_LOCALE_FIXTURE", "1")
        .env("LC_ALL", "ja_JP.UTF-8")
        .status()
        .unwrap();

    assert!(status.success(), "remote client help or parser errors were not localized");
}

#[test]
fn remote_client_locale_fixture() {
    if std::env::var_os("CMUX_TEST_REMOTE_CLIENT_LOCALE_FIXTURE").is_none() {
        return;
    }

    fn assert_japanese(value: &str) {
        assert!(
            value.chars().any(|character| {
                matches!(
                    character,
                    '\u{3040}'..='\u{30ff}' | '\u{3400}'..='\u{9fff}'
                )
            }),
            "expected Japanese text, got {value:?}"
        );
    }

    struct FailingInvitationReader;

    impl Read for FailingInvitationReader {
        fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("fixture read failure"))
        }
    }

    for command in [
        "connect",
        "ssh",
        "forward",
        "dial-tcp",
        "rpc",
        "enroll",
        "known-daemons",
        "remote-probe",
        "remote-link",
        "install-self",
    ] {
        assert_japanese(remote_help(Some(command)));
    }

    for args in [
        vec!["--lanes", "invalid"],
        vec!["--reconnect-attempts", "0"],
        vec!["--reconnect-jitter", "invalid"],
        vec!["--relay-ticket-command-arg", "value"],
        vec!["--iroh-path", "invalid"],
        vec!["--port", "invalid"],
        vec!["--unknown"],
        vec!["first", "second"],
        vec!["--json"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        let error =
            parse_connect_flags(&args).err().expect("invalid connect arguments were accepted");
        assert_japanese(&error.to_string());
    }
    assert_japanese(
        &run_ssh(&[], || panic!("invalid SSH arguments must not load TUI config"))
            .unwrap_err()
            .to_string(),
    );
    assert_japanese(&ssh_url("invalid destination").unwrap_err().to_string());
    assert_japanese(&run_forward(&[]).unwrap_err().to_string());
    assert_japanese(&run_rpc(&["--request".into()]).unwrap_err().to_string());
    let missing_invitation = tempfile::tempdir().unwrap().path().join("missing-invitation");
    assert_japanese(&read_invitation_uri(&missing_invitation).unwrap_err().to_string());
    assert_japanese(
        &read_invitation_uri_line(&mut FailingInvitationReader).unwrap_err().to_string(),
    );
    for bytes in [
        Vec::new(),
        b"cmux://enroll/value\nsecond".to_vec(),
        vec![0xff, 0xfe, 0xfd],
        vec![b'x'; MAX_INVITATION_URI_BYTES + 1],
    ] {
        assert_japanese(
            &read_invitation_uri_to_end(&mut io::Cursor::new(bytes)).unwrap_err().to_string(),
        );
    }
    let mut oversized = io::Cursor::new(vec![b'x'; 128]);
    assert_japanese(&read_rpc_stdin_line(&mut oversized, 8).unwrap_err().to_string());
    assert_japanese(
        &client_relay_options(
            None,
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        )
        .unwrap_err()
        .to_string(),
    );
    assert_japanese(
        &client_relay_options(
            Some("wss://not-a-relay.example/v1/link"),
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        )
        .unwrap_err()
        .to_string(),
    );
    for result in [
        client_relay_options(None, vec![], vec!["slot".into()], vec![]),
        client_relay_options(
            None,
            vec![],
            vec!["one".into(), "two".into()],
            vec![
                ClientRelayCredentialArg::File("one".into()),
                ClientRelayCredentialArg::File("two".into()),
            ],
        ),
        client_relay_options(None, vec!["relay+wss://one.example".into()], vec![], vec![]),
        client_relay_options(
            None,
            (0..5).map(|index| format!("relay+wss://relay-{index}.example")).collect(),
            (0..5).map(|index| format!("slot-{index}")).collect(),
            (0..5)
                .map(|index| ClientRelayCredentialArg::File(format!("ticket-{index}").into()))
                .collect(),
        ),
        client_relay_options(
            None,
            vec!["wss://not-a-relay.example".into()],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        ),
        client_relay_options(
            None,
            vec!["relay+wss://relay.example".into(), "relay+wss://relay.example".into()],
            vec!["one".into(), "two".into()],
            vec![
                ClientRelayCredentialArg::File("one".into()),
                ClientRelayCredentialArg::File("two".into()),
            ],
        ),
    ] {
        assert_japanese(&result.unwrap_err().to_string());
    }

    let directory = tempfile::tempdir().unwrap();
    let store = ClientIdentityStore::load_or_create(directory.path()).unwrap();
    let key = cmux_remote::crypto::StaticIdentity::generate().unwrap().public_key();
    let known = tokio_runtime()
        .unwrap()
        .block_on(store.pin_carrier_daemon(
            "remote".into(),
            key,
            vec!["ssh://remote.example".into()],
        ))
        .unwrap();
    let error = tokio_runtime()
        .unwrap()
        .block_on(select_explicit_route_identity(
            &store,
            Some(&known.fingerprint),
            "wss://remote.example/v1/link",
            SupportedClientAuthModes::DeviceOnly,
        ))
        .err()
        .expect("carrier-only daemon unexpectedly accepted a device-auth route");
    assert_japanese(&error.to_string());

    for args in [
        vec!["unknown"],
        vec!["status", "--unknown"],
        vec!["status", "--json", "--json"],
        vec!["status", "--state-dir"],
        vec!["status", "--ttl", "60"],
        vec!["approve"],
        vec!["disconnect", "device-only"],
        vec!["create", "--ttl", "invalid"],
        vec!["create", "--ttl", "0"],
        vec!["create", "--relay-ticket", "secret"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        let error = parse_enroll_admin_args(&args)
            .err()
            .expect("invalid enrollment arguments were accepted");
        assert_japanese(&error.to_string());
    }

    for args in [
        vec!["forget"],
        vec!["forget", "fingerprint", "extra"],
        vec!["list", "extra"],
        vec!["--json", "--json"],
        vec!["--state-dir"],
        vec!["--unknown"],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert_japanese(&parse_known_daemons_args(&args).unwrap_err().to_string());
    }
}

#[test]
fn remote_stop_recovery_copy_locale_fixture() {
    if std::env::var_os("CMUX_TEST_REMOTE_STOP_LOCALE_FIXTURE").is_none() {
        return;
    }

    let help = remote_help(Some("remote-stop"));
    assert!(help.contains("使用方法"), "{help}");
    assert!(help.contains("停止済み"), "{help}");

    let error = parse_remote_stop_args(
        &["--acknowledge-failed-finalization", "--acknowledge-legacy-finalization"]
            .map(str::to_string),
    )
    .err()
    .expect("mutually exclusive recovery flags were accepted")
    .to_string();
    assert!(error.contains("同時に指定できません"), "{error}");

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let authorization = cmux_remote::identity::AuthDatabase::load_or_create(
        directory.path().join("auth"),
        "localized-stop",
        true,
    )
    .unwrap();
    let error = tokio_runtime()
        .unwrap()
        .block_on(complete_verified_daemon_stop(directory.path(), "localized-stop"))
        .expect_err("stopped-daemon authorization lease unexpectedly had two owners")
        .to_string();
    assert!(error.contains("停止済みデーモンの認可リース"), "{error}");
    drop(authorization);
}

#[test]
fn modern_shutdown_request_binds_the_inspected_lifecycle() {
    let request = shutdown_request_for_lifecycle(Some("inspected-lifecycle"));
    let encoded = serde_json::to_value(request).unwrap();

    assert_eq!(encoded["method"], "shutdown-lifecycle");
    assert_eq!(encoded["lifecycle_id"], "inspected-lifecycle");
    assert_eq!(
        shutdown_request_for_lifecycle(None),
        AdminRequest::Shutdown,
        "legacy runtime metadata must retain its compatible shutdown request"
    );
}

#[cfg(unix)]
#[test]
fn remote_stop_refuses_embedded_server_with_canonical_owner_command() {
    let directory = tempfile::tempdir().unwrap();
    let session = "embedded-owner";
    let (state_dir, link_socket, admin_socket) =
        daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(
        state_dir.join("runtime.json"),
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir,
            link_socket,
            admin_socket,
            daemon_fingerprint: "embedded-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some("embedded-lifecycle".into()),
            replaceable_sidecar: false,
        })
        .unwrap(),
    )
    .unwrap();

    let error = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .expect_err("remote stop terminated an embedded server");

    assert!(error.to_string().contains("cmux daemon stop"), "{error:#}");
    assert!(error.to_string().contains("SSH"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn legacy_sidecar_process_fixture() {
    use std::os::unix::net::UnixListener;

    let Some(state_dir) = std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_STATE") else {
        return;
    };
    let state_dir = PathBuf::from(state_dir);
    let link_socket = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_LINK").unwrap());
    let admin_socket = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_ADMIN").unwrap());
    let ready = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_READY").unwrap());
    let cleanup = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_CLEANUP").unwrap());
    let release = std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_RELEASE").map(PathBuf::from);
    let final_write =
        PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE").unwrap());
    let session = std::env::var("CMUX_TEST_LEGACY_SIDECAR_SESSION")
        .unwrap_or_else(|_| "legacy-handoff".into());
    let lifecycle_id = std::env::var("CMUX_TEST_LEGACY_SIDECAR_LIFECYCLE_ID").ok();
    fs::create_dir_all(&state_dir).unwrap();
    let link_listener = UnixListener::bind(&link_socket).unwrap();
    let admin_listener = UnixListener::bind(&admin_socket).unwrap();
    let runtime = crate::remote_runtime::DaemonRuntimeInfo {
        session,
        state_dir: state_dir.clone(),
        link_socket: link_socket.clone(),
        admin_socket: admin_socket.clone(),
        daemon_fingerprint: "legacy-daemon".into(),
        routes: vec![format!("unix://{}", link_socket.display())],
        direct_websocket: None,
        iroh_node_id: None,
        lifecycle_id: lifecycle_id.clone(),
        replaceable_sidecar: true,
    };
    fs::write(state_dir.join("runtime.json"), serde_json::to_vec_pretty(&runtime).unwrap())
        .unwrap();
    fs::write(&ready, b"ready").unwrap();

    let (stream, _) = admin_listener.accept().unwrap();
    let mut stream = io::BufReader::new(stream);
    let mut request = String::new();
    stream.read_line(&mut request).unwrap();
    let expected_request = match &lifecycle_id {
        Some(lifecycle_id) => {
            AdminRequest::ShutdownLifecycle { lifecycle_id: lifecycle_id.clone() }
        }
        None => AdminRequest::Shutdown,
    };
    assert_eq!(serde_json::from_str::<AdminRequest>(&request).unwrap(), expected_request);
    serde_json::to_writer(
        stream.get_mut(),
        &AdminResponse { ok: true, result: Some(serde_json::json!({})), error: None },
    )
    .unwrap();
    stream.get_mut().write_all(b"\n").unwrap();
    stream.get_mut().flush().unwrap();
    drop(stream);
    drop(admin_listener);
    drop(link_listener);
    fs::remove_file(&admin_socket).unwrap();
    fs::remove_file(&link_socket).unwrap();
    if let Some(lifecycle_id) = lifecycle_id {
        fs::write(
            state_dir.join("shutdown.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "version": 1,
                "lifecycle_id": lifecycle_id,
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();
    }
    fs::remove_file(state_dir.join("runtime.json")).unwrap();
    fs::write(&cleanup, b"legacy-cleanup-published").unwrap();

    if let Some(release) = release {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !release.exists() {
            assert!(Instant::now() < deadline, "legacy sidecar finalization was never released");
            thread::sleep(Duration::from_millis(1));
        }
    }
    fs::write(final_write, b"legacy-final-auth-write").unwrap();
}

#[cfg(unix)]
#[test]
fn remote_stop_waits_for_legacy_sidecar_process_exit_before_upgrade_handoff() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let session = "legacy-handoff";
    let (state_dir, link_socket, admin_socket) =
        daemon_paths(session, Some(directory.path())).unwrap();
    seed_legacy_authorization_state(&state_dir);
    let ready = directory.path().join("legacy-ready");
    let cleanup = directory.path().join("legacy-cleanup-published");
    let release = directory.path().join("release-legacy-finalization");
    let final_write = directory.path().join("legacy-final-auth-write");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "remote_cli::tests::legacy_sidecar_process_fixture", "--nocapture"])
        .env("CMUX_TEST_LEGACY_SIDECAR_STATE", &state_dir)
        .env("CMUX_TEST_LEGACY_SIDECAR_LINK", &link_socket)
        .env("CMUX_TEST_LEGACY_SIDECAR_ADMIN", &admin_socket)
        .env("CMUX_TEST_LEGACY_SIDECAR_READY", &ready)
        .env("CMUX_TEST_LEGACY_SIDECAR_CLEANUP", &cleanup)
        .env("CMUX_TEST_LEGACY_SIDECAR_RELEASE", &release)
        .env("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE", &final_write)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let ready_deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("legacy sidecar fixture exited before startup: {status}");
        }
        assert!(Instant::now() < ready_deadline, "legacy sidecar fixture did not start");
        thread::sleep(Duration::from_millis(1));
    }

    let state_root = directory.path().to_string_lossy().into_owned();
    let stopper = thread::spawn(move || {
        run_remote_stop(
            &["--session", session, "--state-dir", state_root.as_str()].map(str::to_string),
        )
    });
    let cleanup_deadline = Instant::now() + Duration::from_secs(5);
    while !cleanup.exists() {
        assert!(
            !stopper.is_finished(),
            "remote-stop returned before the legacy daemon published lifecycle cleanup"
        );
        assert!(
            Instant::now() < cleanup_deadline,
            "legacy daemon did not publish lifecycle cleanup"
        );
        thread::sleep(Duration::from_millis(1));
    }
    let early_return_deadline = Instant::now() + Duration::from_millis(500);
    while !stopper.is_finished() && Instant::now() < early_return_deadline {
        thread::sleep(Duration::from_millis(1));
    }
    let returned_before_process_exit = stopper.is_finished();

    fs::write(&release, b"release").unwrap();
    let stop_result = stopper.join().unwrap();
    let child_status = child.wait().unwrap();
    assert!(stop_result.is_ok(), "remote-stop failed: {stop_result:?}");
    assert!(child_status.success(), "legacy sidecar fixture failed: {child_status}");
    assert!(final_write.exists(), "legacy sidecar did not complete its final authorization write");
    assert!(
        !returned_before_process_exit,
        "remote-stop returned after runtime.json removal but before legacy process exit"
    );
    assert!(
        state_dir.join("lifecycle-fence.json").exists(),
        "process-fenced legacy shutdown did not publish a lifecycle fence"
    );
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        Some(cmux_remote::identity::AUTH_STATE_VERSION),
        "process-fenced legacy shutdown did not publish its rollback fence"
    );
}

#[cfg(unix)]
#[test]
fn remote_stop_rejects_failed_authorization_finalization() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let session = "failed-finalization";
    let lifecycle_id = "failed-finalization-instance";
    let (state_dir, link_socket, admin_socket) =
        daemon_paths(session, Some(directory.path())).unwrap();
    let ready = directory.path().join("failed-finalization-ready");
    let cleanup = directory.path().join("failed-finalization-cleanup");
    let final_write = directory.path().join("failed-finalization-auth-write");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "remote_cli::tests::legacy_sidecar_process_fixture", "--nocapture"])
        .env("CMUX_TEST_LEGACY_SIDECAR_STATE", &state_dir)
        .env("CMUX_TEST_LEGACY_SIDECAR_LINK", &link_socket)
        .env("CMUX_TEST_LEGACY_SIDECAR_ADMIN", &admin_socket)
        .env("CMUX_TEST_LEGACY_SIDECAR_READY", &ready)
        .env("CMUX_TEST_LEGACY_SIDECAR_CLEANUP", &cleanup)
        .env("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE", &final_write)
        .env("CMUX_TEST_LEGACY_SIDECAR_SESSION", session)
        .env("CMUX_TEST_LEGACY_SIDECAR_LIFECYCLE_ID", lifecycle_id)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let ready_deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("failed-finalization fixture exited before startup: {status}");
        }
        assert!(Instant::now() < ready_deadline, "failed-finalization fixture did not start");
        thread::sleep(Duration::from_millis(1));
    }

    let stop_result = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    );
    let child_status = child.wait().unwrap();
    assert!(child_status.success(), "failed-finalization fixture failed: {child_status}");
    assert!(final_write.exists(), "fixture did not complete its final authorization write");
    let error = stop_result.expect_err("failed authorization finalization reported success");
    assert!(error.to_string().contains("authorization finalization"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn shutdown_outcome_requires_exact_lifecycle_and_success() {
    let directory = tempfile::tempdir().unwrap();
    let outcome = directory.path().join("shutdown.json");
    let missing = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
    assert!(missing.to_string().contains("authorization finalization"), "{missing:#}");

    fs::write(&outcome, b"{not-json").unwrap();
    let malformed = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
    assert!(malformed.to_string().contains("authorization finalization"), "{malformed:#}");

    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "stale",
            "status": "succeeded",
        }))
        .unwrap(),
    )
    .unwrap();
    let stale = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
    assert!(stale.to_string().contains("different daemon lifecycle"), "{stale:#}");

    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "current",
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();
    let failed = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
    assert!(failed.to_string().contains("authorization finalization failed"), "{failed:#}");

    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "current",
            "status": "succeeded",
        }))
        .unwrap(),
    )
    .unwrap();
    verify_shutdown_outcome(directory.path(), "current").unwrap();
}

#[cfg(unix)]
#[test]
fn remote_stop_without_runtime_rejects_failed_authorization_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let session = "inactive-failed-finalization";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(
        state_dir.join("shutdown.json"),
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "failed-lifecycle",
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    let error = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .expect_err("inactive failed authorization finalization was treated as clean");
    assert!(error.to_string().contains("authorization finalization"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn remote_stop_without_runtime_rejects_malformed_authorization_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let session = "inactive-malformed-finalization";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(state_dir.join("shutdown.json"), b"{not-json").unwrap();

    let error = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .expect_err("inactive malformed authorization finalization was treated as clean");
    assert!(error.to_string().contains("authorization finalization"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn remote_stop_explicitly_acknowledges_inactive_failed_authorization_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-failed-finalization";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    let outcome = state_dir.join("shutdown.json");
    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "failed-lifecycle",
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!outcome.exists());
    run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .unwrap();
}

#[cfg(unix)]
#[test]
fn remote_stop_explicitly_acknowledges_inactive_legacy_authorization_state() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-inactive-legacy";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    seed_legacy_authorization_state(&state_dir);
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    let error = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .expect_err("inactive legacy state migrated without explicit acknowledgement");
    assert!(error.to_string().contains("--acknowledge-legacy-finalization"), "{error:#}");

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-legacy-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(state_dir.join("lifecycle-fence.json").exists());
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        Some(cmux_remote::identity::AUTH_STATE_VERSION)
    );
    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(directory.path().to_path_buf()),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("acknowledged legacy state remained blocked");
    runtime.shutdown().unwrap();
}

#[cfg(unix)]
#[test]
fn remote_stop_failed_acknowledgement_does_not_create_empty_authorization_state() {
    let directory = tempfile::tempdir().unwrap();
    let session = "empty-failed-acknowledgement";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .expect_err("empty failed-finalization acknowledgement succeeded");

    assert!(
        !state_dir.join("auth").exists(),
        "rejected acknowledgement created authorization state"
    );
}

#[cfg(unix)]
#[test]
fn remote_stop_acknowledges_matching_stale_runtime_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-stale-runtime";
    let lifecycle_id = "stale-runtime-lifecycle";
    let (state_dir, link_socket, admin_socket) =
        daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    fs::write(
        &runtime_path,
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket,
            admin_socket,
            daemon_fingerprint: "stopped-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some(lifecycle_id.into()),
            replaceable_sidecar: true,
        })
        .unwrap(),
    )
    .unwrap();
    let outcome = state_dir.join("shutdown.json");
    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": lifecycle_id,
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!runtime_path.exists());
    assert!(!outcome.exists());
}

#[cfg(unix)]
#[test]
fn remote_stop_acknowledgement_uses_recorded_custom_sockets() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let session = "acknowledge-custom-sockets";
    let lifecycle_id = "custom-socket-lifecycle";
    let (state_dir, default_link, _) = daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    let _unrelated_default_listener =
        std::os::unix::net::UnixListener::bind(&default_link).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    fs::write(
        &runtime_path,
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket: state_dir.join("custom-link.sock"),
            admin_socket: state_dir.join("custom-admin.sock"),
            daemon_fingerprint: "stopped-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some(lifecycle_id.into()),
            replaceable_sidecar: true,
        })
        .unwrap(),
    )
    .unwrap();
    let outcome = state_dir.join("shutdown.json");
    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": lifecycle_id,
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!runtime_path.exists());
    assert!(!outcome.exists());
}

#[cfg(unix)]
#[test]
fn remote_stop_acknowledges_stale_failed_runtime_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-stale-failed-runtime";
    let (state_dir, link_socket, admin_socket) =
        daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    fs::write(
        &runtime_path,
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket,
            admin_socket,
            daemon_fingerprint: "stopped-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some("runtime-lifecycle".into()),
            replaceable_sidecar: true,
        })
        .unwrap(),
    )
    .unwrap();
    let outcome = state_dir.join("shutdown.json");
    fs::write(
        &outcome,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "different-lifecycle",
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!runtime_path.exists());
    assert!(!outcome.exists());
}

#[cfg(unix)]
#[test]
fn remote_stop_refuses_recovery_while_recorded_socket_is_active() {
    let directory = tempfile::tempdir().unwrap();
    let session = "reject-active-recovery";
    let (state_dir, _, admin_socket) = daemon_paths(session, Some(directory.path())).unwrap();
    let link_socket = directory.path().join("recorded-active-link.sock");
    fs::create_dir_all(&state_dir).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(&link_socket).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    fs::write(
        &runtime_path,
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket,
            admin_socket,
            daemon_fingerprint: "active-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some("active-lifecycle".into()),
            replaceable_sidecar: true,
        })
        .unwrap(),
    )
    .unwrap();

    let error = run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .expect_err("active daemon recovery was acknowledged");

    assert!(error.to_string().contains("daemon socket"), "{error:#}");
    assert!(runtime_path.exists());
    assert!(
        !state_dir.join("auth").exists(),
        "rejected recovery created authorization state before probing the active socket"
    );
    drop(listener);
}

#[cfg(unix)]
#[test]
fn remote_stop_refuses_legacy_acknowledgement_while_recorded_socket_is_active() {
    let directory = tempfile::tempdir().unwrap();
    let session = "reject-active-legacy-acknowledgement";
    let (state_dir, _, admin_socket) = daemon_paths(session, Some(directory.path())).unwrap();
    let link_socket = directory.path().join("recorded-active-legacy-link.sock");
    seed_legacy_authorization_state(&state_dir);
    let listener = std::os::unix::net::UnixListener::bind(&link_socket).unwrap();
    fs::write(
        state_dir.join("runtime.json"),
        serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket,
            admin_socket,
            daemon_fingerprint: "active-legacy-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: None,
            replaceable_sidecar: true,
        })
        .unwrap(),
    )
    .unwrap();

    let error = run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-legacy-finalization",
        ]
        .map(str::to_string),
    )
    .expect_err("active legacy daemon was acknowledged");

    assert!(error.to_string().contains("daemon socket"), "{error:#}");
    assert!(!state_dir.join("lifecycle-fence.json").exists());
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        Some(1),
        "rejected recovery migrated authorization state before probing the active socket"
    );
    drop(listener);
}

#[cfg(unix)]
#[test]
fn remote_stop_explicitly_removes_malformed_inactive_runtime_metadata() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-malformed-runtime";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    drop(
        cmux_remote::identity::AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
            .unwrap(),
    );
    persist_daemon_lifecycle_fence(&state_dir).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    fs::write(&runtime_path, b"{not-json").unwrap();

    let error = run_remote_stop(
        &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
            .map(str::to_string),
    )
    .expect_err("malformed runtime metadata was reported as stopped");
    assert!(error.to_string().contains("--acknowledge-legacy-finalization"), "{error:#}");

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-legacy-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!runtime_path.exists());
}

#[cfg(unix)]
#[test]
fn malformed_runtime_and_failed_outcome_have_a_complete_recovery_path() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-malformed-runtime-and-failure";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    drop(
        cmux_remote::identity::AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
            .unwrap(),
    );
    persist_daemon_lifecycle_fence(&state_dir).unwrap();
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    fs::write(&runtime_path, b"{not-json").unwrap();
    fs::write(
        &outcome_path,
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "lifecycle_id": "failed-lifecycle",
            "status": "failed",
        }))
        .unwrap(),
    )
    .unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-legacy-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();
    assert!(!runtime_path.exists());
    assert!(outcome_path.exists(), "legacy recovery discarded failed shutdown evidence");

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();
    assert!(!outcome_path.exists());
}

#[cfg(unix)]
#[test]
fn remote_stop_acknowledges_malformed_outcome_without_runtime_metadata() {
    let directory = tempfile::tempdir().unwrap();
    let session = "acknowledge-malformed-outcome";
    let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    let outcome = state_dir.join("shutdown.json");
    fs::write(&outcome, b"{not-json").unwrap();

    run_remote_stop(
        &[
            "--session",
            session,
            "--state-dir",
            directory.path().to_string_lossy().as_ref(),
            "--acknowledge-failed-finalization",
        ]
        .map(str::to_string),
    )
    .unwrap();

    assert!(!outcome.exists());
}

#[cfg(unix)]
#[test]
fn remote_stop_acknowledges_unclean_runtime_without_current_failure_outcome() {
    for case in ["missing", "stale-success", "malformed"] {
        let directory = tempfile::tempdir().unwrap();
        let session = format!("acknowledge-unclean-{case}");
        let lifecycle_id = format!("unclean-runtime-{case}");
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(&session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(
            &runtime_path,
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.clone(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "unclean-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some(lifecycle_id),
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();
        let outcome = state_dir.join("shutdown.json");
        match case {
            "missing" => {}
            "stale-success" => fs::write(
                &outcome,
                serde_json::to_vec(&serde_json::json!({
                    "version": 1,
                    "lifecycle_id": "prior-lifecycle",
                    "status": "succeeded",
                }))
                .unwrap(),
            )
            .unwrap(),
            "malformed" => fs::write(&outcome, b"{not-json").unwrap(),
            _ => unreachable!(),
        }

        run_remote_stop(
            &[
                "--session",
                session.as_str(),
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap_or_else(|error| panic!("{case}: {error:#}"));

        assert!(!runtime_path.exists(), "{case}");
        assert!(!outcome.exists(), "{case}");
    }
}

#[test]
fn relay_invitation_access_reads_owner_supplied_ticket_file() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let ticket = directory.path().join("ticket");
    fs::write(&ticket, "short-lived-ticket\n").unwrap();
    fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();
    let args = vec![
        "create".into(),
        "--relay-route".into(),
        "relay+do://relay.example".into(),
        "--relay-slot".into(),
        "slot".into(),
        "--relay-ticket-file".into(),
        ticket.to_string_lossy().into_owned(),
    ];
    let parsed = parse_enroll_admin_args(&args).unwrap();
    let access = invitation_relay_access(&parsed).unwrap();
    assert_eq!(access[0].ticket, "short-lived-ticket");
    assert!(!format!("{:?}", access[0]).contains("short-lived-ticket"));
}

#[cfg(unix)]
#[test]
fn invitation_relay_ticket_file_requires_owner_only_permissions() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let ticket = directory.path().join("ticket");
    fs::write(&ticket, "short-lived-ticket\n").unwrap();
    fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read_invitation_ticket_file(&ticket).unwrap(), "short-lived-ticket");

    fs::set_permissions(&ticket, fs::Permissions::from_mode(0o640)).unwrap();
    assert!(read_invitation_ticket_file(&ticket).is_err());
}

#[cfg(unix)]
#[test]
fn invitation_relay_ticket_file_accepts_maximum_ticket_with_newline() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let ticket = directory.path().join("ticket");
    let mut contents = vec![b'x'; 4 * 1024];
    contents.push(b'\n');
    fs::write(&ticket, contents).unwrap();
    fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();

    assert_eq!(read_invitation_ticket_file(&ticket).unwrap().len(), 4 * 1024);
}

#[cfg(unix)]
#[test]
fn invitation_relay_ticket_file_rejects_symlinks() {
    use std::os::unix::fs::{PermissionsExt as _, symlink};

    let directory = tempfile::tempdir().unwrap();
    let target = directory.path().join("target");
    let link = directory.path().join("ticket");
    fs::write(&target, "short-lived-ticket\n").unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
    symlink(&target, &link).unwrap();

    assert!(read_invitation_ticket_file(&link).is_err());
}

#[cfg(unix)]
#[test]
fn install_self_does_not_follow_predictable_staging_symlink() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let sentinel = directory.path().join("sentinel");
    let destination = directory.path().join("cmux-tui");
    let predictable = directory.path().join(format!(".cmux-tui-install-{}", std::process::id()));
    fs::write(&sentinel, b"keep").unwrap();
    symlink(&sentinel, &predictable).unwrap();

    run_install_self(&["--destination".into(), destination.to_string_lossy().into_owned()])
        .unwrap();

    assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
    assert!(fs::symlink_metadata(&destination).unwrap().file_type().is_file());
}

#[cfg(unix)]
#[test]
fn install_self_atomically_replaces_destination_symlink() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let sentinel = directory.path().join("sentinel");
    let destination = directory.path().join("cmux-tui");
    fs::write(&sentinel, b"keep").unwrap();
    symlink(&sentinel, &destination).unwrap();

    run_install_self(&["--destination".into(), destination.to_string_lossy().into_owned()])
        .unwrap();

    assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
    assert!(fs::symlink_metadata(&destination).unwrap().file_type().is_file());
}

#[cfg(unix)]
#[test]
fn install_self_rejects_group_or_world_writable_parent() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let parent = directory.path().join("shared");
    fs::create_dir(&parent).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
    let destination = parent.join("cmux-tui");

    assert!(
        run_install_self(&["--destination".into(), destination.to_string_lossy().into_owned(),])
            .is_err()
    );
    assert!(!destination.exists());
}

#[test]
fn relay_invitation_access_supports_native_and_durable_object_fallbacks() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let native_ticket = directory.path().join("native-ticket");
    let durable_object_ticket = directory.path().join("do-ticket");
    for (path, contents) in
        [(&native_ticket, "native-ticket\n"), (&durable_object_ticket, "do-ticket\n")]
    {
        fs::write(path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let args = vec![
        "create".into(),
        "--relay-route".into(),
        "relay+wss://relay.example".into(),
        "--relay-slot".into(),
        "native-slot".into(),
        "--relay-ticket-file".into(),
        native_ticket.to_string_lossy().into_owned(),
        "--relay-route".into(),
        "relay+do://worker.example".into(),
        "--relay-slot".into(),
        "do-slot".into(),
        "--relay-ticket-file".into(),
        durable_object_ticket.to_string_lossy().into_owned(),
    ];

    let parsed = parse_enroll_admin_args(&args).unwrap();
    let access = invitation_relay_access(&parsed).unwrap();
    assert_eq!(access.len(), 2);
    assert_eq!(access[0].slot, "native-slot");
    assert_eq!(access[1].slot, "do-slot");
}

#[test]
fn relay_invitation_access_rejects_incomplete_groups() {
    let args = ["create", "--relay-route", "relay+do://worker.example"].map(str::to_string);
    let parsed = parse_enroll_admin_args(&args).unwrap();
    assert!(invitation_relay_access(&parsed).is_err());
}

#[test]
fn browser_proxy_accepts_private_ipv4_and_ipv6_authorities() {
    assert_eq!(
        remote_browser_proxy::parse_connect_authority_with_loopback("10.42.0.7:8000", false)
            .unwrap(),
        ("10.42.0.7".into(), 8000)
    );
    assert_eq!(
        remote_browser_proxy::parse_connect_authority_with_loopback("[fd12::7]:8443", false)
            .unwrap(),
        ("fd12::7".into(), 8443)
    );
    assert!(
        remote_browser_proxy::parse_connect_authority_with_loopback("192.0.2.7:8000", false)
            .is_err()
    );
    assert!(
        remote_browser_proxy::parse_connect_authority_with_loopback("127.0.0.1:8000", false)
            .is_err()
    );
}

#[test]
fn browser_proxy_parser_keeps_connection_flags_and_repeats_allowed_hosts() {
    let parsed = parse_browser_proxy_args(&[
        "wss://daemon.example/link".into(),
        "--allowed-host".into(),
        "10.0.0.4".into(),
        "--allowed-host".into(),
        "10.0.0.5".into(),
        "--workspace-root".into(),
        "/".into(),
        "--wireguard-hub".into(),
        "/tmp/cmux-wg.sock".into(),
        "--carrier".into(),
    ])
    .unwrap();
    assert_eq!(parsed.allowed_hosts, ["10.0.0.4", "10.0.0.5"]);
    assert_eq!(parsed.workspace_root, "/");
    assert!(parsed.connect.windows(2).any(|pair| pair == ["--wireguard-hub", "/tmp/cmux-wg.sock"]));
    assert!(parsed.connect.iter().any(|flag| flag == "--carrier"));
}

#[test]
fn browser_proxy_loopback_is_opt_in_for_ssh_carriers() {
    let rejected = parse_browser_proxy_args(&[
        "ssh://host".into(),
        "--workspace-root".into(),
        "/".into(),
        "--allowed-host".into(),
        "127.0.0.1".into(),
    ]);
    assert!(rejected.is_err());

    let parsed = parse_browser_proxy_args(&[
        "ssh://host".into(),
        "--workspace-root".into(),
        "/".into(),
        "--allow-loopback".into(),
        "--allowed-host".into(),
        "localhost".into(),
        "--allowed-host".into(),
        "::1".into(),
    ])
    .unwrap();
    assert!(parsed.allow_loopback);
    assert_eq!(parsed.allowed_hosts, vec!["127.0.0.1", "::1"]);
    assert_eq!(
        remote_browser_proxy::parse_connect_authority_with_loopback("localhost:3000", true)
            .unwrap(),
        ("127.0.0.1".into(), 3000)
    );
    assert!(
        remote_browser_proxy::parse_connect_authority_with_loopback("127.0.0.1:3000", false)
            .is_err()
    );
}
