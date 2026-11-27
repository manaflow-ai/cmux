use super::*;
use zeroize::Zeroizing;

fn given(name: &str, value: &str, proxy: Option<&[&str]>) -> Given {
    Given {
        name: name.to_owned(),
        value: Zeroizing::new(value.to_owned()),
        proxy: proxy.map(|h| h.iter().map(|s| (*s).to_owned()).collect()),
    }
}

fn running() -> Running {
    Running {
        port: 41234,
        epoch: "e1".to_owned(),
        node_ca: PathBuf::from("/h/vault-egress/node-extra-ca.pem"),
        bundle: Some(PathBuf::from("/h/vault-egress/ca-bundle.pem")),
    }
}

fn get<'a>(env: &'a [(String, String)], name: &str) -> Option<&'a str> {
    env.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

#[test]
fn proxy_entries_are_placeholders_and_env_entries_are_values() {
    let env = child_env_with(
        vec![
            given("GITHUB_TOKEN", "ghp_secret_value", Some(&["api.github.com"])),
            given("DATABASE_URL", "postgres://u:pw@db/x", None),
        ],
        Some(&running()),
        &|_| None,
    );
    assert_eq!(get(&env, "GITHUB_TOKEN"), Some("cmux-secret://GITHUB_TOKEN"));
    assert_eq!(get(&env, "DATABASE_URL"), Some("postgres://u:pw@db/x"));
    assert_eq!(get(&env, "HTTPS_PROXY"), Some("http://127.0.0.1:41234"));
    assert_eq!(get(&env, "https_proxy"), Some("http://127.0.0.1:41234"));
    assert_eq!(get(&env, "NO_PROXY"), Some("localhost,127.0.0.1,::1,.cmux.internal"));
    assert_eq!(get(&env, "NODE_EXTRA_CA_CERTS"), Some("/h/vault-egress/node-extra-ca.pem"));
    assert_eq!(get(&env, "SSL_CERT_FILE"), Some("/h/vault-egress/ca-bundle.pem"));
    assert_eq!(get(&env, EPOCH_VAR), Some("e1"));
    assert!(!env.iter().any(|(_, v)| v.contains("ghp_secret_value")));
}

#[test]
fn the_port_outlives_the_daemon_and_moves_only_when_taken() {
    // The port is an ephemeral one, so between the drop and the rebind a parallel test's
    // `bind(0)` can be handed it (base, 2026-11-22: 42109 for 33863). Then the move is right;
    // the test tries again on a new port, and fails only when the port was free to take.
    let mut tries = 0;
    // `_second` (not `_`) keeps the restarted listener, so the port stays taken for `third`.
    let (dir, port, _second) = loop {
        tries += 1;
        let dir = tempfile::tempdir().unwrap();
        let first = bind_stable(dir.path(), true).unwrap();
        let port = first.local_addr().unwrap().port();
        let kept = std::fs::read_to_string(dir.path().join(PORT_FILE)).unwrap();
        assert_eq!(kept.trim(), port.to_string());
        // The daemon restarts: its listener is gone, the next one takes the same port.
        drop(first);
        let second = bind_stable(dir.path(), true).unwrap();
        if second.local_addr().unwrap().port() == port {
            break (dir, port, second);
        }
        assert!(
            std::net::TcpListener::bind(("127.0.0.1", port)).is_err(),
            "port {port} was free, yet the restart moved to {:?}",
            second.local_addr()
        );
        assert!(tries < 5, "another process took the freed port {tries} times in a row");
    };
    // Another process holds it: a new port, written down for the next start.
    let third = bind_stable(dir.path(), true).unwrap();
    let moved = third.local_addr().unwrap().port();
    assert_ne!(moved, port);
    let kept = std::fs::read_to_string(dir.path().join(PORT_FILE)).unwrap();
    assert_eq!(kept.trim(), moved.to_string());
}

#[test]
fn the_ca_outlives_the_daemon() {
    let dir = tempfile::tempdir().unwrap();
    private_folder(dir.path()).unwrap();
    let first = kept_or_new_authority(dir.path()).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(dir.path().join(CA_KEY_FILE)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    // The daemon restarts: the next one serves the same CA, under the same epoch.
    let second = kept_or_new_authority(dir.path()).unwrap();
    assert_eq!(second.pem(), first.pem());
    assert_eq!(ca_epoch(second.pem()), ca_epoch(first.pem()));
    // An agent the first daemon started is not stale under the second.
    let node_ca = dir.path().join("node-extra-ca.pem");
    let env: Vec<(String, String)> = vec![
        ("HTTPS_PROXY".to_owned(), "http://127.0.0.1:4000".to_owned()),
        ("NODE_EXTRA_CA_CERTS".to_owned(), node_ca.display().to_string()),
        (EPOCH_VAR.to_owned(), ca_epoch(first.pem())),
    ];
    assert!(!stale_proxy_env(&env, &node_ca, Some(&ca_epoch(second.pem()))));
    // A key that is not the certificate's: a new CA, kept, and a new epoch.
    std::fs::write(dir.path().join(CA_KEY_FILE), "nope").unwrap();
    let third = kept_or_new_authority(dir.path()).unwrap();
    assert_ne!(third.pem(), first.pem());
    assert!(stale_proxy_env(&env, &node_ca, Some(&ca_epoch(third.pem()))));
    let fourth = kept_or_new_authority(dir.path()).unwrap();
    assert_eq!(fourth.pem(), third.pem());
}

#[test]
fn a_kept_port_file_that_is_not_a_port_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(PORT_FILE), "nope").unwrap();
    let listener = bind_stable(dir.path(), true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let kept = std::fs::read_to_string(dir.path().join(PORT_FILE)).unwrap();
    assert_eq!(kept.trim(), port.to_string());
}

#[test]
fn only_an_agent_on_another_start_of_our_proxy_is_stale() {
    let ca = Path::new("/h/vault-egress/node-extra-ca.pem");
    let env = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    };
    let ours = |epoch: Option<&str>| {
        let mut e = env(&[
            ("HTTPS_PROXY", "http://127.0.0.1:43007"),
            ("NODE_EXTRA_CA_CERTS", "/h/vault-egress/node-extra-ca.pem"),
        ]);
        if let Some(epoch) = epoch {
            e.push((EPOCH_VAR.to_owned(), epoch.to_owned()));
        }
        e
    };
    // This start's agent.
    assert!(!stale_proxy_env(&ours(Some("e2")), ca, Some("e2")));
    // The incident: an agent the previous daemon started, its proxy gone.
    assert!(stale_proxy_env(&ours(Some("e1")), ca, Some("e2")));
    assert!(stale_proxy_env(&ours(Some("e1")), ca, None));
    // An older build's agent named no start: it is ours, so it is stale.
    assert!(stale_proxy_env(&ours(None), ca, Some("e2")));
    // No proxy, or a proxy of the person's own: never ours to restart.
    assert!(!stale_proxy_env(&env(&[("PATH", "/bin")]), ca, Some("e2")));
    let corp = env(&[
        ("HTTPS_PROXY", "http://corp:3128"),
        ("NODE_EXTRA_CA_CERTS", "/h/vault-egress/node-extra-ca.pem"),
    ]);
    assert!(!stale_proxy_env(&corp, ca, None));
    let other_ca =
        env(&[("HTTPS_PROXY", "http://127.0.0.1:43007"), ("NODE_EXTRA_CA_CERTS", "/etc/corp.pem")]);
    assert!(!stale_proxy_env(&other_ca, ca, None));
}

/// The judgment reads a live process's environment: an agent process started on a gone
/// proxy start is stale, one started without our proxy is not.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_running_agent_is_judged_by_the_env_it_was_started_with() {
    let node_ca = crate::config::home().join("vault-egress").join("node-extra-ca.pem");
    let spawn = |proxied: bool| {
        let mut cmd = std::process::Command::new("sleep");
        cmd.arg("30");
        if proxied {
            cmd.env("HTTPS_PROXY", "http://127.0.0.1:43007")
                .env("NODE_EXTRA_CA_CERTS", &node_ca)
                .env(EPOCH_VAR, "an-earlier-daemons-start");
        } else {
            cmd.env_remove("HTTPS_PROXY").env_remove("NODE_EXTRA_CA_CERTS");
        }
        cmd.spawn().unwrap()
    };
    let (mut stale, mut fresh) = (spawn(true), spawn(false));
    let judged = (stale_proxy_pid(stale.id()), stale_proxy_pid(fresh.id()));
    for child in [&mut stale, &mut fresh] {
        let _ = child.kill();
        let _ = child.wait();
    }
    assert_eq!(judged, (true, false));
}

#[test]
fn a_spawn_carries_the_start_its_stamp_names() {
    let env =
        child_env_with(vec![given("T", "s", Some(&["x.example.com"]))], Some(&running()), &|_| {
            None
        });
    let node_ca = running().node_ca;
    assert!(!stale_proxy_env(&env, &node_ca, Some("e1")));
    assert!(stale_proxy_env(&env, &node_ca, Some("e9")));
}

#[test]
fn no_proxy_entry_means_no_proxy_settings() {
    let env = child_env_with(vec![given("A", "a", None)], Some(&running()), &|_| None);
    assert_eq!(env, vec![("A".to_owned(), "a".to_owned())]);
}

#[test]
fn a_proxy_that_did_not_start_still_withholds_the_value() {
    let env = child_env_with(vec![given("T", "secret", Some(&["x.example.com"]))], None, &|_| None);
    assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
}

#[test]
fn an_existing_https_proxy_is_kept_and_the_value_still_withheld() {
    let inherited = |n: &str| (n == "HTTPS_PROXY").then(|| "http://corp:3128".to_owned());
    let env = child_env_with(
        vec![given("T", "secret", Some(&["x.example.com"]))],
        Some(&running()),
        &inherited,
    );
    assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
}

#[test]
fn no_proxy_keeps_what_the_launch_had() {
    assert_eq!(
        no_proxy(Some(" corp.lan, localhost ,".into())),
        "corp.lan,localhost,127.0.0.1,::1,.cmux.internal"
    );
}

#[test]
fn policy_holds_only_proxy_entries_with_their_valid_hosts() {
    let policy = policy_of(vec![
        given("T", "secret", Some(&["api.github.com", "not a host"])),
        given("E", "env-value", None),
    ]);
    assert_eq!(policy.secrets().len(), 1);
    assert_eq!(policy.secrets()[0].name(), "T");
    assert_eq!(policy.secrets()[0].hosts().len(), 1);
    assert!(policy.intercepts("api.github.com", 443));
}

#[test]
fn trust_files_extend_what_the_launch_trusted() {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().join("base.pem");
    std::fs::write(&base, "-----BEGIN CERTIFICATE-----\nBASE\n-----END CERTIFICATE-----").unwrap();
    let node = dir.path().join("node.pem");
    std::fs::write(&node, "-----BEGIN CERTIFICATE-----\nNODE\n-----END CERTIFICATE-----\n")
        .unwrap();
    let (b, n) = (base.display().to_string(), node.display().to_string());
    let inherited = move |name: &str| match name {
        "SSL_CERT_FILE" => Some(b.clone()),
        "NODE_EXTRA_CA_CERTS" => Some(n.clone()),
        _ => None,
    };
    let ca = "-----BEGIN CERTIFICATE-----\nOURS\n-----END CERTIFICATE-----\n";
    let out = dir.path().join("egress");
    let (node_ca, bundle) = write_trust(&out, ca, &inherited).unwrap();
    let node_text = std::fs::read_to_string(node_ca).unwrap();
    assert!(node_text.contains("NODE") && node_text.ends_with(ca));
    let bundle_text = std::fs::read_to_string(bundle.unwrap()).unwrap();
    assert!(
        bundle_text.starts_with("-----BEGIN CERTIFICATE-----\nBASE") && bundle_text.ends_with(ca)
    );
}

#[test]
fn only_the_daemon_writes_the_port_down() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = bind_stable(dir.path(), true).unwrap();
    let port = daemon.local_addr().unwrap().port();
    // Another acpmux process starts a proxy while the daemon holds the port.
    let other = bind_stable(dir.path(), false).unwrap();
    assert_ne!(other.local_addr().unwrap().port(), port);
    let kept = std::fs::read_to_string(dir.path().join(PORT_FILE)).unwrap();
    assert_eq!(kept.trim(), port.to_string());
}

#[test]
fn the_trust_files_do_not_grow_when_the_launch_names_ours() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("egress");
    let ca = "-----BEGIN CERTIFICATE-----\nOURS\n-----END CERTIFICATE-----\n";
    let (node_ca, bundle) = write_trust(&out, ca, &|_| None).unwrap();
    // A process an agent of ours started inherits our files, and starts the proxy again.
    let (n, b) = (node_ca.display().to_string(), bundle.as_ref().map(|b| b.display().to_string()));
    let inherited = move |name: &str| match name {
        "NODE_EXTRA_CA_CERTS" => Some(n.clone()),
        "SSL_CERT_FILE" => b.clone(),
        _ => None,
    };
    let first_bundle = bundle.as_ref().map(|b| std::fs::read_to_string(b).unwrap());
    for _ in 0..3 {
        write_trust(&out, ca, &inherited).unwrap();
    }
    assert_eq!(std::fs::read_to_string(&node_ca).unwrap(), ca);
    assert_eq!(bundle.as_ref().map(|b| std::fs::read_to_string(b).unwrap()), first_bundle);
    if let Some(text) = first_bundle {
        assert_eq!(text.matches("OURS").count(), 1);
    }
}

#[test]
fn an_expired_or_corrupt_kept_ca_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    private_folder(dir.path()).unwrap();
    let first = kept_or_new_authority(dir.path()).unwrap();
    // A certificate that is not one: a new CA, kept for the next daemon.
    std::fs::write(dir.path().join(CA_CERT_FILE), "-----BEGIN CERTIFICATE-----\nnope").unwrap();
    let second = kept_or_new_authority(dir.path()).unwrap();
    assert_ne!(second.pem(), first.pem());
    assert_eq!(kept_or_new_authority(dir.path()).unwrap().pem(), second.pem());
    // A CA within 45 days of its end is replaced too.
    let old = Authority::generate_for(30).unwrap();
    std::fs::write(dir.path().join(CA_KEY_FILE), old.key_pem().as_bytes()).unwrap();
    std::fs::write(dir.path().join(CA_CERT_FILE), old.pem()).unwrap();
    let third = kept_or_new_authority(dir.path()).unwrap();
    assert_ne!(third.pem(), old.pem());
}
