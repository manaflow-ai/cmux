use std::collections::VecDeque;
use std::time::Duration;

use cmux_cloud_start_core::machine_bootstrap::ExecAnswer;

use super::*;

fn no_mint(_: &MintSource, _: &MintSpec, _: bool) -> Result<Secret, String> {
    panic!("an auth key is never minted")
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn join_words_parse_and_a_key_argument_is_refused() {
    let args = parse_join(&words(
        "vm_1 --key-file /k --login-server https://hs.example.com --hostname box --tag cmux-vm --ssh --ephemeral --serve 3000 --funnel 5173:8443 --timeout 60",
    ))
    .unwrap();
    assert_eq!(args.vm_id, "vm_1");
    assert_eq!(args.key, KeySource::File("/k".into()));
    assert_eq!(args.request.serve.len(), 2);
    assert!(args.request.serve[1].funnel && args.request.serve[1].https_port == 8443);
    assert_eq!(args.timeout, Duration::from_secs(60));
    assert!(
        parse_join(&words("vm_1 --auth-key tskey-auth-x")).unwrap_err().contains("shell history")
    );
    assert!(parse_join(&words("vm_1")).is_err());
    assert!(parse_join(&words("--key-stdin")).is_err());
}

/// A VM as the join sees it: answers in order, every write kept.
struct FakeGuest {
    answers: VecDeque<ExecAnswer>,
    writes: Vec<(String, Vec<u8>, u32)>,
    commands: Vec<String>,
}

impl Guest for FakeGuest {
    fn write(&mut self, path: &str, bytes: &[u8], mode: u32) -> Result<(), String> {
        self.writes.push((path.to_owned(), bytes.to_vec(), mode));
        Ok(())
    }
    fn exec(&mut self, command: &str) -> Result<ExecAnswer, String> {
        self.commands.push(command.to_owned());
        self.answers.pop_front().ok_or_else(|| "no answer".to_owned())
    }
    fn pause(&mut self, _: Duration) {}
}

fn said(text: &str) -> ExecAnswer {
    ExecAnswer { exit_code: 0, stdout: text.to_owned(), stderr: String::new() }
}

#[test]
fn a_join_writes_the_key_0600_runs_detached_and_reads_the_node() {
    let args = parse_join(&words("vm_1 --key-stdin --hostname box --ssh")).unwrap();
    let checked = checked(args, |_| Ok("tskey-auth-SECRET\n".to_owned()), no_mint).unwrap();
    let mut guest = FakeGuest {
        answers: [
            said("prepared\n"),
            said("started\n"),
            said("rc=\n"),
            said("rc=0\ncmux-tailnet-joined {\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"box.tail1.ts.net.\",\"TailscaleIPs\":[\"100.64.0.9\"],\"Online\":true}}\ncmux-tailnet-stderr\n"),
        ]
        .into(),
        writes: Vec::new(),
        commands: Vec::new(),
    };
    let node = join(&mut guest, &checked, Duration::from_secs(60)).unwrap();
    assert_eq!(node["dnsName"], "box.tail1.ts.net");
    assert_eq!(guest.writes[0], (KEY_FILE.to_owned(), b"tskey-auth-SECRET".to_vec(), 0o600));
    assert_eq!(guest.writes[1].0, SCRIPT_FILE);
    assert!(guest.commands.iter().all(|c| !c.contains("SECRET")));
    assert!(!String::from_utf8_lossy(&guest.writes[1].1).contains("SECRET"));
}

#[test]
fn another_tailnet_and_failures_come_back_as_words() {
    let args = parse_join(&words("vm_1 --key-stdin")).unwrap();
    let checked = checked(args, |_| Ok("tskey-auth-a".to_owned()), no_mint).unwrap();
    let mut guest = FakeGuest {
        answers: [
            said("prepared\n"),
            said("started\n"),
            said("rc=4\ncmux-tailnet: other-tailnet https://other.example\ncmux-tailnet-stderr\n"),
        ]
        .into(),
        writes: Vec::new(),
        commands: Vec::new(),
    };
    let error = join(&mut guest, &checked, Duration::from_secs(60)).unwrap_err();
    assert!(error.contains("--switch"), "{error}");
}

#[test]
fn the_record_lists_joined_vms_for_rm() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().to_str().unwrap().to_owned();
    let env = move |name: &str| (name == "XDG_STATE_HOME").then(|| path.clone());
    assert!(!joined_here(&env, "vm_1"));
    let mut record = read_record(&env);
    record.insert("vm_1".to_owned(), "box.ts.net".to_owned());
    write_record(&env, &record);
    assert!(joined_here(&env, "vm_1"));
}

#[test]
fn a_joined_vm_is_not_copied_until_it_leaves() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().to_str().unwrap().to_owned();
    let env = move |name: &str| (name == "XDG_STATE_HOME").then(|| path.clone());
    assert_eq!(cloned_vm(&words("fork vm_1")), Some("vm_1"));
    assert_eq!(cloned_vm(&words("snapshot create vm_1 --name x")), Some("vm_1"));
    assert_eq!(cloned_vm(&words("snapshot list")), None);
    assert_eq!(cloned_vm(&words("fork --help")), None);
    assert!(refuse_clone_of_joined("vm_1", &env).is_none());
    let mut record = read_record(&env);
    record.insert("vm_1".to_owned(), "box.ts.net".to_owned());
    write_record(&env, &record);
    let refusal = refuse_clone_of_joined("vm_1", &env).unwrap();
    assert!(refusal.contains("cmux vm tailnet leave vm_1"), "{refusal}");
}

#[test]
fn an_oauth_client_is_traded_on_the_mac_and_only_the_minted_key_goes_to_the_vm() {
    let args = parse_join(&words("vm_1 --key-stdin --oauth --tag cmux --ephemeral")).unwrap();
    let mut asked = None;
    let checked = checked(
        args,
        |_| Ok("tskey-client-kID-LONGLIVED\n".to_owned()),
        |source, spec, _| {
            asked = Some((source.clone(), spec.clone()));
            Ok(Secret::new("tskey-auth-ONEUSE"))
        },
    )
    .unwrap();
    let (source, spec) = asked.unwrap();
    assert!(matches!(source, MintSource::TailscaleOauth { .. }));
    assert!(spec.ephemeral);
    // Raw here; mint_key's check_source gives each tag its tag:NAME form before any call.
    assert_eq!(spec.tags, ["cmux"]);
    assert_eq!(checked.key_file_contents(), "tskey-auth-ONEUSE");
    let script = cmux_tailnet_join::vm_join_script(&checked);
    assert!(!script.contains("LONGLIVED"));
}

#[test]
fn an_oauth_client_without_tags_is_refused_before_any_call() {
    let args = parse_join(&words("vm_1 --key-stdin --oauth")).unwrap();
    let error = checked(args, |_| Ok("tskey-client-kID-x".to_owned()), no_mint).unwrap_err();
    assert!(error.contains("tag"), "{error}");
}

#[test]
fn a_headscale_api_key_mints_for_its_server_and_user() {
    assert!(parse_join(&words("vm_1 --key-stdin --headscale-api --headscale-user 1")).is_err());
    assert!(
        parse_join(&words("vm_1 --key-stdin --headscale-api --login-server https://h")).is_err()
    );
    assert!(parse_join(&words("vm_1 --key-stdin --oauth --headscale-api")).is_err());
    let args = parse_join(&words(
        "vm_1 --key-stdin --headscale-api --login-server http://127.0.0.1:8080 --headscale-user 1 --allow-http",
    ))
    .unwrap();
    let checked = checked(
        args,
        |_| Ok("hsapikey".to_owned()),
        |source, _, allow_http| {
            assert!(allow_http);
            assert_eq!(
                *source,
                MintSource::Headscale {
                    server: "http://127.0.0.1:8080".into(),
                    api_key: Secret::new("hsapikey"),
                    user: "1".into()
                }
            );
            Ok(Secret::new("minted"))
        },
    )
    .unwrap();
    assert_eq!(checked.key_file_contents(), "minted");
}

#[test]
fn mint_key_needs_out_and_a_mint_kind_and_never_overwrites() {
    assert!(parse_mint(&words("--key-stdin --oauth --tag x")).is_err());
    assert!(parse_mint(&words("--key-stdin --out /tmp/k")).is_err());
    let (args, out) = parse_mint(&words("--key-stdin --oauth --tag x --out /tmp/k")).unwrap();
    assert!(args.oauth);
    assert_eq!(out, PathBuf::from("/tmp/k"));
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("key");
    write_new_key_file(&path, &Secret::new("k1")).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "k1");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(dir.path().join("elsewhere"), &link).unwrap();
        assert!(write_new_key_file(&link, &Secret::new("k2")).is_err());
        assert!(!dir.path().join("elsewhere").exists());
    }
    assert!(write_new_key_file(&path, &Secret::new("k2")).is_err());
}

#[test]
fn form_fields_are_escaped() {
    assert_eq!(form_escape("a b&c=d+e"), "a%20b%26c%3Dd%2Be");
}

/// Seeded secrets on the wire (cmux_egress::capture): the OAuth client secret rides only in the Tailscale token
/// call's form body, and a Headscale API key only in `Authorization` to the server the person named.
/// tests/egress_seeded.json names this test for the `cmux_tui::vm_tailnet` gate site.
#[test]
fn seeded_credentials_ride_only_to_the_server_that_mints() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let oauth = Secret::new("tskey-client-SEEDid42-SEEDtailscaleOauthSecret8f3a");
    let api_key = Secret::new("SEEDheadscaleApiKey-5d2c");
    let _ = send(&mint::tailscale_token_call(&oauth).unwrap());
    let server = "https://headscale.seeded-person.example.org";
    cmux_egress::allow_named(server);
    let spec = MintSpec { ephemeral: true, tags: Vec::new() };
    let _ = send(&mint::headscale_key_call(server, &api_key, "7", &spec, 1_700_000_000));

    assert_eq!(cmux_egress::capture::requests_to("api.tailscale.com").len(), 1);
    assert_eq!(cmux_egress::capture::requests_to("headscale.seeded-person.example.org").len(), 1);
    let places = cmux_egress::capture::leaks("SEEDtailscaleOauthSecret8f3a");
    assert_eq!(places, vec!["api.tailscale.com POST /api/v2/oauth/token: body".to_owned()]);
    let places = cmux_egress::capture::leaks("SEEDheadscaleApiKey-5d2c");
    assert_eq!(
        places,
        vec![
            "headscale.seeded-person.example.org POST /api/v1/preauthkey: header authorization"
                .to_owned()
        ]
    );
}
