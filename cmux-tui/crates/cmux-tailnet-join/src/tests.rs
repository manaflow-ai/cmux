use super::*;

const KEY: &str = "tskey-auth-kSECRETSECRET-abcdef";

fn request(credential: Credential) -> JoinRequest {
    JoinRequest {
        credential,
        control_url: None,
        hostname: Some("Dev-VM-1".to_owned()),
        tags: vec!["cmux-vm".to_owned(), "tag:cmux-vm".to_owned()],
        ssh: true,
        ephemeral: true,
        serve: vec![ServePort { local_port: 3000, https_port: 443, funnel: false }],
        switch_from_other_tailnet: false,
        allow_http: false,
    }
}

fn auth_key() -> Credential {
    Credential::AuthKey { key: Secret::new(KEY) }
}

#[test]
fn the_key_never_leaves_through_debug_serialization_or_the_script() {
    let checked = request(auth_key()).check().unwrap();
    assert!(!format!("{checked:?}").contains("SECRET"));
    assert!(!serde_json::to_string(checked.request()).unwrap().contains("SECRET"));
    let script = vm_join_script(&checked);
    assert!(!script.contains("SECRET"), "{script}");
    assert!(script.contains("--auth-key=file:/run/cmux-tailnet/authkey"));
    assert!(script.contains("trap 'rm -f \"$k\" 2>/dev/null || true' EXIT"));
    assert_eq!(checked.key_file_contents(), KEY);
}

#[test]
fn a_request_deserializes_with_the_key_and_defaults() {
    let r: JoinRequest = serde_json::from_str(&format!(
        r#"{{"credential":{{"kind":"auth_key","key":"{KEY}"}},"hostname":"box"}}"#
    ))
    .unwrap();
    assert_eq!(r.credential, auth_key());
    assert!(!r.ssh && !r.ephemeral && r.tags.is_empty() && r.serve.is_empty());
}

#[test]
fn names_and_tags_are_normalized_and_deduplicated() {
    let checked = request(auth_key()).check().unwrap();
    assert_eq!(checked.request().hostname.as_deref(), Some("dev-vm-1"));
    assert_eq!(checked.request().tags, ["tag:cmux-vm"]);
    let flags = checked.login_flags();
    assert!(flags.contains(&"--hostname=dev-vm-1".to_owned()));
    assert!(flags.contains(&"--advertise-tags=tag:cmux-vm".to_owned()));
    assert!(!flags.iter().any(|f| f.starts_with("--login-server")));
}

#[test]
fn bad_values_are_refused_before_any_script_exists() {
    for name in ["", "-a", "a-", "a b", "a;rm", &"x".repeat(64)] {
        let mut r = request(auth_key());
        r.hostname = Some(name.to_owned());
        assert!(r.check().is_err(), "{name:?}");
    }
    for tag in ["tag:", "tag:1abc", "tag:a b", "tag:a,b", "tag:$(x)"] {
        let mut r = request(auth_key());
        r.tags = vec![tag.to_owned()];
        assert!(r.check().is_err(), "{tag:?}");
    }
    for key in ["", "tskey-auth-a b", "nope"] {
        assert!(request(Credential::AuthKey { key: Secret::new(key) }).check().is_err(), "{key:?}");
    }
}

#[test]
fn headscale_takes_any_key_and_its_own_server() {
    let mut r = request(Credential::AuthKey { key: Secret::new("0123abcd4567") });
    r.control_url = Some("https://hs.example.com/".to_owned());
    let checked = r.check().unwrap();
    assert!(checked.login_flags().contains(&"--login-server=https://hs.example.com".to_owned()));
    assert!(vm_join_script(&checked).contains("'https://hs.example.com'"));
}

#[test]
fn plain_http_only_when_the_user_chose_it() {
    for (url, allow, ok) in [
        ("http://headscale:8080", false, false),
        ("http://10.0.0.5:8080", false, false),
        ("http://10.0.0.5:8080", true, true),
        ("http://hs.example.com", true, true),
        ("https://hs.example.com", false, true),
        ("ftp://hs", true, false),
        ("https://hs.example.com/$(id)", false, false),
        ("https://hs example.com", false, false),
    ] {
        let mut r = request(Credential::AuthKey { key: Secret::new("k") });
        r.control_url = Some(url.to_owned());
        r.allow_http = allow;
        assert_eq!(r.check().is_ok(), ok, "{url} allow={allow}");
    }
}

#[test]
fn the_key_path_is_never_followed_through_a_symlink() {
    assert!(prepare_command("cmux").contains("[ -L /run/cmux-tailnet ]"));
    assert!(prepare_command("cmux").contains("rm -f /run/cmux-tailnet/authkey"));
    assert!(vm_join_script(&request(auth_key()).check().unwrap()).contains("[ -L \"$k\" ]"));
}

#[test]
fn an_oauth_client_needs_tags_and_carries_ephemeral_in_its_query() {
    let secret = Credential::OauthClient { secret: Secret::new("tskey-client-abc-SECRET") };
    let mut r = request(secret.clone());
    r.tags.clear();
    assert!(r.check().is_err());
    let checked = request(secret.clone()).check().unwrap();
    assert_eq!(
        checked.key_file_contents(),
        "tskey-client-abc-SECRET?ephemeral=true&preauthorized=true"
    );
    assert!(!vm_join_script(&checked).contains("SECRET"));
    let mut hs = request(secret);
    hs.control_url = Some("https://hs.example.com".to_owned());
    assert!(hs.check().is_err());
}

#[test]
fn serve_and_funnel_are_only_what_was_asked() {
    let mut r = request(auth_key());
    r.serve = vec![
        ServePort { local_port: 3000, https_port: 443, funnel: false },
        ServePort { local_port: 5173, https_port: 8443, funnel: true },
    ];
    let checked = r.check().unwrap();
    let script = vm_join_script(&checked);
    assert!(script.contains("tailscale serve --bg --https=443 http://127.0.0.1:3000"));
    assert!(script.contains("tailscale funnel --bg --https=8443 http://127.0.0.1:5173"));
    assert!(checked.notes().iter().any(|n| n.contains("Funnel")));
    let mut bad = request(auth_key());
    bad.serve = vec![ServePort { local_port: 1, https_port: 4443, funnel: true }];
    assert!(bad.check().is_err());
}

#[test]
fn the_script_never_touches_routes_or_exit_nodes() {
    let script = vm_join_script(&request(auth_key()).check().unwrap());
    for flag in ["accept-routes", "exit-node", "advertise-routes", "--reset", "accept-dns"] {
        assert!(!script.contains(flag), "{flag}");
    }
}

#[test]
fn another_tailnet_is_refused_unless_the_user_chose_to_switch() {
    let script = vm_join_script(&request(auth_key()).check().unwrap());
    assert!(script.contains("other-tailnet"));
    let mut r = request(auth_key());
    r.switch_from_other_tailnet = true;
    assert!(!vm_join_script(&r.check().unwrap()).contains("other-tailnet"));
    assert_eq!(
        parse_joined("noise\ncmux-tailnet: other-tailnet https://login.example\n"),
        Outcome::OtherTailnet { control_url: "https://login.example".to_owned() }
    );
}

#[test]
fn parse_reads_the_joined_node() {
    let out = r#"cmux-tailnet-joined {"BackendState":"Running","Self":{"DNSName":"dev-vm-1.tail1.ts.net.","TailscaleIPs":["100.64.0.2","fd7a::2"],"Tags":["tag:cmux-vm"],"Online":true}}"#;
    assert_eq!(
        parse_joined(out),
        Outcome::Joined(Joined {
            dns_name: "dev-vm-1.tail1.ts.net".to_owned(),
            ips: vec!["100.64.0.2".to_owned(), "fd7a::2".to_owned()],
            tags: vec!["tag:cmux-vm".to_owned()],
            online: true,
        })
    );
    assert!(matches!(
        parse_joined(r#"cmux-tailnet-joined {"BackendState":"NeedsLogin","Self":{}}"#),
        Outcome::Failed(_)
    ));
    assert!(matches!(parse_joined(""), Outcome::Failed(_)));
}

#[test]
fn leave_signs_out_and_never_fails_the_delete() {
    let script = vm_leave_script();
    assert!(script.contains("tailscale logout"));
    assert!(script.contains("serve reset"));
    assert!(!script.contains("set -e"));
}

#[test]
fn embedded_options_match_the_node_config() {
    let mut r = request(auth_key());
    r.control_url = Some("https://hs.example.com".to_owned());
    let o = embedded_options(&r.check().unwrap());
    assert_eq!(o.auth_key.expose(), KEY);
    assert_eq!(o.control_url.as_deref(), Some("https://hs.example.com"));
    assert_eq!(o.hostname.as_deref(), Some("dev-vm-1"));
    assert!(o.ephemeral);
}

#[test]
fn a_join_runs_detached_and_is_read_back() {
    assert!(prepare_command("cmux").contains("chmod 700 /run/cmux-tailnet"));
    let start = start_command();
    assert!(start.contains("systemd-run") && start.contains("--unit=cmux-tailnet-join"));
    assert!(read_command().contains("/run/cmux-tailnet/rc"));
    assert_eq!(read_answer("rc=\n"), Progress::Running);
    let done = "rc=0\ncmux-tailnet-joined {\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"a.b.\",\"Online\":true}}\ncmux-tailnet-stderr\n";
    assert!(
        matches!(read_answer(done), Progress::Ended(Outcome::Joined(j)) if j.dns_name == "a.b")
    );
    assert_eq!(
        read_answer("rc=1\ncmux-tailnet-stderr\nbackend error: invalid key\n"),
        Progress::Ended(Outcome::Failed(
            "the join exited 1: backend error: invalid key".to_owned()
        ))
    );
    assert!(matches!(
        read_answer("rc=4\ncmux-tailnet: other-tailnet https://x\ncmux-tailnet-stderr\n"),
        Progress::Ended(Outcome::OtherTailnet { .. })
    ));
}
