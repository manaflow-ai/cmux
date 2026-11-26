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

const NODE_JSON: &str = "{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"leo-cmux.tail1.ts.net.\",\"TailscaleIPs\":[\"100.64.0.2\"],\"Tags\":[\"tag:cmux\"],\"Online\":true}}";

fn fake(answers: Vec<ExecAnswer>) -> FakeGuest {
    FakeGuest { answers: answers.into(), writes: Vec::new(), commands: Vec::new() }
}

#[test]
fn move_words_parse() {
    let (from, to, timeout) = parse_move(&words("vm_a vm_b --timeout 30")).unwrap();
    assert_eq!((from.as_str(), to.as_str(), timeout), ("vm_a", "vm_b", Duration::from_secs(30)));
    assert!(parse_move(&words("vm_a")).is_err());
    assert!(parse_move(&words("vm_a vm_a")).is_err());
    assert!(parse_move(&words("vm_a vm_b --key x")).is_err());
}

#[test]
fn a_move_stops_the_old_holder_first_hands_the_state_0600_and_forgets_it() {
    let mut from = fake(vec![
        said("cmux-tailnet-stopped-at 1000\ncmux-tailnet-state c3RhdGU=\ncmux-tailnet-released\n"),
        said("cmux-tailnet-forgot\n"),
    ]);
    let mut to = fake(vec![
        said("prepared\n"),
        said("started\n"),
        said("rc=\n"),
        said(&format!(
            "rc=0\ncmux-tailnet-online-at 1800\ncmux-tailnet-joined {NODE_JSON}\ncmux-tailnet-stderr\n"
        )),
    ]);
    let node = move_node(&mut from, &mut to, Duration::from_secs(60)).unwrap();
    assert_eq!(node["dnsName"], "leo-cmux.tail1.ts.net");
    assert_eq!(node["gapMs"], 800);
    assert_eq!(node["oldCopyDeleted"], true);
    // The adopt script is in place before the old holder stops; the state goes 0600.
    assert_eq!(to.writes[0].0, SCRIPT_FILE);
    let state =
        to.writes.iter().find(|w| w.0 == cmux_tailnet_join::handoff::STAGED_STATE_FILE).unwrap();
    assert_eq!((state.1.as_slice(), state.2), (&b"c3RhdGU=\n"[..], 0o600));
    assert!(from.commands[0].contains("pkill -x tailscaled"));
    assert!(from.commands[1].contains("cmux-tailnet-forgot"));
    // The state never shows in the result.
    assert!(!node.to_string().contains("c3RhdGU="));
    assert_eq!(store.lease().unwrap(), vault::Lease { holder: Some("vm_b".into()), epoch: 1 });
    assert_eq!(node["epoch"], 1);
}

#[test]
fn adopt_is_refused_while_another_vm_holds_the_lease() {
    let store = kept("leo-cmux", "c3RhdGU=");
    held(&store, "vm_a", 4);
    let mut vm = fake(vec![]);
    let error = vault::adopt(&mut vm, &store, "vm_b", false, Duration::from_secs(60)).unwrap_err();
    assert!(error.contains("vm_a holds your tailnet node"), "{error}");
    assert!(error.contains("cmux vm tailnet move vm_a vm_b"), "{error}");
    assert!(vm.commands.is_empty() && vm.writes.is_empty(), "nothing reaches the VM");
    assert_eq!(store.lease().unwrap().holder.as_deref(), Some("vm_a"));
}

#[test]
fn take_over_moves_the_lease_at_the_epoch_it_read() {
    let store = kept("leo-cmux", "c3RhdGU=");
    held(&store, "vm_a", 4);
    let mut vm = fake(vec![
        said("prepared\n"),
        said("started\n"),
        said(&format!("rc=0\ncmux-tailnet-online-at 1800\ncmux-tailnet-joined {NODE_JSON}\n")),
    ]);
    vault::adopt(&mut vm, &store, "vm_b", true, Duration::from_secs(60)).unwrap();
    assert_eq!(store.lease().unwrap(), vault::Lease { holder: Some("vm_b".into()), epoch: 5 });
    // A move takes it over from FROM only; a third VM's lease stands.
    assert_eq!(vault::hold(&store, "vm_c", Some("vm_b"), false).unwrap().epoch, 6);
    assert!(vault::hold(&store, "vm_d", Some("vm_b"), false).is_err());
    // The holder claiming again changes nothing.
    assert_eq!(vault::hold(&store, "vm_c", None, false).unwrap().epoch, 6);
}

#[test]
fn a_failed_adopt_gives_the_lease_back() {
    let store = kept("leo-cmux", "c3RhdGU=");
    let mut vm = fake(vec![said("not prepared\n")]);
    assert!(vault::adopt(&mut vm, &store, "vm_b", false, Duration::from_secs(60)).is_err());
    assert_eq!(store.lease().unwrap(), vault::Lease { holder: None, epoch: 2 });
}

#[test]
fn the_lease_answer_reads_a_free_node_and_refuses_junk() {
    let free = vault::parse_lease(&json!({"holder": null, "epoch": 3, "updatedAt": 1})).unwrap();
    assert_eq!(free, vault::Lease { holder: None, epoch: 3 });
    let taken = vault::parse_lease(&json!({"holder": "vm_a", "epoch": 4})).unwrap();
    assert_eq!(taken.holder.as_deref(), Some("vm_a"));
    assert!(vault::parse_lease(&json!({"holder": "vm_a"})).is_err());
    assert!(vault::parse_lease(&json!({"holder": 7, "epoch": 1})).is_err());
}

#[test]
fn a_failed_adopt_restarts_the_node_on_the_old_holder() {
    let mut from = fake(vec![
        said("cmux-tailnet-state c3RhdGU=\ncmux-tailnet-released\n"),
        said("cmux-tailnet-restored\n"),
    ]);
    let mut to = fake(vec![
        said("prepared\n"),
        said("started\n"),
        said(
            "rc=3\ncmux-tailnet-stderr\ncmux-tailnet: the node did not come online on this machine\n",
        ),
    ]);
    let error = move_node(&mut from, &mut to, Duration::from_secs(60)).unwrap_err();
    assert!(error.contains("did not come online"), "{error}");
    assert!(error.contains("back on the old VM"), "{error}");
    assert!(from.commands[1].contains("cmux-tailnet-restored"));
    assert!(!from.commands.iter().any(|c| c.contains("cmux-tailnet-forgot")));
}

#[test]
fn a_move_from_a_vm_with_no_node_changes_nothing() {
    let mut from = fake(vec![ExecAnswer {
        exit_code: 3,
        stdout: String::new(),
        stderr: "cmux-tailnet: no node state on this machine".to_owned(),
    }]);
    let mut to = fake(vec![said("prepared\n")]);
    let error = move_node(&mut from, &mut to, Duration::from_secs(60)).unwrap_err();
    assert!(error.contains("no node state"), "{error}");
    assert_eq!(from.commands.len(), 1);
    assert!(!to.commands.iter().any(|c| c.contains("started")));
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

// MARK: The vault keeps the node (RFD 0169)

use std::cell::RefCell;

/// The user's vault: one node, a revision counter, every call kept.
#[derive(Default)]
struct FakeVault {
    node: RefCell<Option<(String, String)>>,
    revision: RefCell<u64>,
    refuse_put: bool,
    lease: RefCell<vault::Lease>,
}

impl vault::NodeVault for FakeVault {
    fn put(&self, name: &str, state: &Secret) -> Result<u64, String> {
        if self.refuse_put {
            return Err("your vault is unreachable (offline)".to_owned());
        }
        let body = vault::put_body(name, state)?;
        let name = body["name"].as_str().unwrap().to_owned();
        *self.node.borrow_mut() = Some((name, state.expose().to_owned()));
        *self.revision.borrow_mut() += 1;
        Ok(*self.revision.borrow())
    }
    fn get(&self) -> Result<Option<vault::KeptNode>, String> {
        Ok(self.node.borrow().as_ref().map(|(name, state)| vault::KeptNode {
            name: name.clone(),
            revision: *self.revision.borrow(),
            state: Secret::new(state.clone()),
        }))
    }
    fn delete(&self) -> Result<(), String> {
        *self.node.borrow_mut() = None;
        Ok(())
    }
    fn lease(&self) -> Result<vault::Lease, String> {
        Ok(self.lease.borrow().clone())
    }
    // The platform's rules (cmux-platform#2167): compare-and-set on the epoch.
    fn claim(&self, holder: &str, if_epoch: Option<u64>) -> Result<vault::Lease, String> {
        let mut lease = self.lease.borrow_mut();
        match lease.holder.as_deref() {
            Some(h) if h == holder => {}
            Some(_) if if_epoch != Some(lease.epoch) => return Err("conflict".to_owned()),
            None if if_epoch.is_some_and(|e| e != lease.epoch) => {
                return Err("conflict".to_owned());
            }
            _ => *lease = vault::Lease { holder: Some(holder.to_owned()), epoch: lease.epoch + 1 },
        }
        Ok(lease.clone())
    }
    fn release(&self, holder: &str, epoch: u64) -> Result<(), String> {
        let mut lease = self.lease.borrow_mut();
        match lease.holder.as_deref() {
            None => Ok(()),
            Some(h) if h == holder && lease.epoch == epoch => {
                *lease = vault::Lease { holder: None, epoch: lease.epoch + 1 };
                Ok(())
            }
            Some(_) => Err("conflict".to_owned()),
        }
    }
}

fn held(store: &FakeVault, holder: &str, epoch: u64) {
    *store.lease.borrow_mut() = vault::Lease { holder: Some(holder.to_owned()), epoch };
}

fn kept(name: &str, state: &str) -> FakeVault {
    FakeVault {
        node: RefCell::new(Some((name.to_owned(), state.to_owned()))),
        revision: RefCell::new(7),
        refuse_put: false,
        lease: RefCell::new(vault::Lease { holder: None, epoch: 0 }),
    }
}

#[test]
fn keep_copies_the_running_node_into_the_vault_without_stopping_it() {
    let mut vm = fake(vec![said("cmux-tailnet-state c3RhdGU=\ncmux-tailnet-snapshot\n")]);
    let store = FakeVault::default();
    assert_eq!(vault::keep(&mut vm, &store, "leo-cmux.tail1.ts.net").unwrap(), 1);
    assert_eq!(store.node.borrow().clone(), Some(("leo-cmux".to_owned(), "c3RhdGU=".to_owned())));
    assert!(!vm.commands[0].contains("pkill"), "keep never stops tailscaled");
}

#[test]
fn the_put_body_carries_the_sha256_of_the_decoded_bytes() {
    let body = vault::put_body("n", &Secret::new("c3RhdGU=")).unwrap();
    // sha256("state")
    assert_eq!(
        body["fingerprint"],
        "4ba69735ca53765ed6a709edb56c6ea236b7193a3b29a6b390c346f0f4340e4e"
    );
    assert!(vault::put_body("n", &Secret::new("not base64!")).is_err());
    // The vault takes the hostname label, not the tailnet's suffix.
    assert_eq!(
        vault::put_body("leo-cmux.tail1.ts.net.", &Secret::new("c3RhdGU=")).unwrap()["name"],
        "leo-cmux"
    );
    assert!(vault::put_body("", &Secret::new("c3RhdGU=")).is_err());
}

#[test]
fn the_vaults_answer_must_match_its_fingerprint() {
    let body = vault::put_body("leo-cmux", &Secret::new("c3RhdGU=")).unwrap();
    let mut answer = body.clone();
    answer["revision"] = json!(3);
    let node = vault::parse_node(&answer).unwrap();
    assert_eq!(
        (node.name.as_str(), node.revision, node.state.expose()),
        ("leo-cmux", 3, "c3RhdGU=")
    );
    answer["stateBase64"] = json!("b3RoZXI=");
    assert!(vault::parse_node(&answer).unwrap_err().contains("fingerprint"));
    answer["stateBase64"] = json!("");
    assert!(vault::parse_node(&answer).is_err());
}

#[test]
fn adopt_brings_the_vaults_node_up_with_no_key() {
    let store = kept("leo-cmux", "c3RhdGU=");
    let mut vm = fake(vec![
        said("prepared\n"),
        said("started\n"),
        said(&format!("rc=0\ncmux-tailnet-online-at 1800\ncmux-tailnet-joined {NODE_JSON}\n")),
    ]);
    let (node, name) =
        vault::adopt(&mut vm, &store, "vm_b", false, Duration::from_secs(60)).unwrap();
    assert_eq!(name, "leo-cmux");
    assert_eq!(node["dnsName"], "leo-cmux.tail1.ts.net");
    assert_eq!(node["revision"], 7);
    let state =
        vm.writes.iter().find(|w| w.0 == cmux_tailnet_join::handoff::STAGED_STATE_FILE).unwrap();
    assert_eq!((state.1.as_slice(), state.2), (&b"c3RhdGU=\n"[..], 0o600));
    assert!(!vm.writes.iter().any(|w| w.0 == KEY_FILE), "no auth key reaches the VM");
    assert!(!node.to_string().contains("c3RhdGU="));
}

#[test]
fn adopt_with_an_empty_vault_changes_nothing() {
    let mut vm = fake(vec![]);
    let error =
        vault::adopt(&mut vm, &FakeVault::default(), "vm_b", false, Duration::from_secs(60))
            .unwrap_err();
    assert!(error.contains("keeps no tailnet node"), "{error}");
    assert!(vm.commands.is_empty() && vm.writes.is_empty());
}

#[test]
fn adopt_refuses_a_second_holder() {
    let store = kept("leo-cmux", "c3RhdGU=");
    let record = BTreeMap::from([("vm_a".to_owned(), "leo-cmux.tail1.ts.net".to_owned())]);
    let refusal = refuse_second_holder(&record, &store, "vm_b").unwrap();
    assert!(refusal.contains("cmux vm tailnet move vm_a vm_b"), "{refusal}");
    assert!(refuse_second_holder(&BTreeMap::new(), &store, "vm_b").is_none());
    let words = |t: &str| t.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    assert_eq!(
        parse_adopt(&words("vm_b --timeout 9")).unwrap(),
        ("vm_b".to_owned(), false, Duration::from_secs(9))
    );
    assert!(parse_adopt(&words("--take-over vm_b")).unwrap().1);
    assert!(parse_adopt(&words("vm_a vm_b")).is_err());
    assert!(parse_adopt(&words("")).is_err());
}

#[test]
fn rm_hands_the_node_to_the_vault_then_deletes_the_vms_copy() {
    let mut vm = fake(vec![
        said("cmux-tailnet-stopped-at 1000\ncmux-tailnet-state c3RhdGU=\ncmux-tailnet-released\n"),
        said("cmux-tailnet-forgot\n"),
    ]);
    let store = FakeVault::default();
    held(&store, "vm_a", 3);
    assert_eq!(vault::release_to_vault(&mut vm, &store, "vm_a", "leo-cmux").unwrap(), 1);
    assert_eq!(store.lease().unwrap(), vault::Lease { holder: None, epoch: 4 }, "lease let go");
    assert!(vm.commands[0].contains("pkill -x tailscaled"));
    assert!(vm.commands[1].contains("cmux-tailnet-forgot"));
    assert_eq!(store.node.borrow().as_ref().unwrap().1, "c3RhdGU=");
}

#[test]
fn rm_restarts_the_node_when_the_vault_does_not_take_it() {
    let mut vm = fake(vec![
        said("cmux-tailnet-state c3RhdGU=\ncmux-tailnet-released\n"),
        said("cmux-tailnet-restored\n"),
    ]);
    let store = FakeVault { refuse_put: true, ..FakeVault::default() };
    held(&store, "vm_a", 3);
    let error = vault::release_to_vault(&mut vm, &store, "vm_a", "leo-cmux").unwrap_err();
    assert_eq!(store.lease().unwrap().holder.as_deref(), Some("vm_a"), "still up there");
    assert!(error.contains("running on the VM again"), "{error}");
    assert!(!vm.commands.iter().any(|c| c.contains("cmux-tailnet-forgot")));
}

#[test]
fn a_join_never_overwrites_another_kept_node() {
    let store = kept("old-node", "c3RhdGU=");
    let why = keep_unless_other(&store, "new-node", |_| panic!("must not keep")).unwrap_err();
    assert!(why.contains("keeps old-node"), "{why}");
    let node = with_kept(json!({"dnsName": "new-node"}), Err(why));
    assert_eq!(node["keptInVault"], false);
    assert!(node["notes"][0].as_str().unwrap().contains("not kept in your vault"));
    // The same node (a move) is kept again.
    assert_eq!(keep_unless_other(&store, "old-node", |_| Ok(8)), Ok(true));
}

#[test]
fn leave_drops_only_the_signed_out_node_from_the_vault() {
    let store = kept("leo-cmux", "c3RhdGU=");
    held(&store, "vm_b", 2);
    assert_eq!(drop_if_kept(&store, "vm_a", "other"), None);
    assert!(store.node.borrow().is_some());
    assert_eq!(store.lease().unwrap().holder.as_deref(), Some("vm_b"), "not vm_a's lease");
    assert_eq!(drop_if_kept(&store, "vm_b", "leo-cmux"), None);
    assert!(store.node.borrow().is_none());
    assert_eq!(store.lease().unwrap().holder, None);
}

#[test]
fn connect_is_a_join_for_the_one_stable_node() {
    let env = |name: &str| (name == "USER").then(|| "Leo.Smith".to_owned());
    let args = parse_connect(&words("vm_1 --oauth --key-stdin --tag tag:cmux"), &env).unwrap();
    assert!(args.request.ssh && !args.request.ephemeral && args.oauth);
    assert_eq!(args.request.hostname.as_deref(), Some("leo-smith-cmux"));
    let named = parse_connect(&words("vm_1 --key-stdin --hostname box"), &env).unwrap();
    assert_eq!(named.request.hostname.as_deref(), Some("box"));
    let why = parse_connect(&words("vm_1 --key-stdin --ephemeral"), &env).unwrap_err();
    assert!(why.contains("never --ephemeral"), "{why}");
    let why = parse_connect(&words("vm_1"), &env).unwrap_err();
    assert!(why.contains("tailnet connect needs"), "{why}");
}

#[test]
fn the_stable_name_is_a_dns_label() {
    let name = |user: &str| {
        let user = user.to_owned();
        stable_name(&move |key: &str| (key == "USER").then(|| user.clone()))
    };
    assert_eq!(name("leo"), "leo-cmux");
    assert_eq!(name("  Ann_Lee--"), "ann-lee-cmux");
    assert_eq!(name("!!!"), "cmux");
    assert_eq!(stable_name(&|_: &str| None), "cmux");
    assert!(name(&"a".repeat(80)).len() <= 63);
}

#[test]
fn connect_refuses_while_the_vault_keeps_a_node() {
    let store = kept("leo-cmux", "c3RhdGU=");
    let why = may_connect(&store, "vm_2").unwrap_err();
    assert!(why.contains("keeps your node leo-cmux") && why.contains("adopt vm_2"), "{why}");
    let empty = kept("x", "c3RhdGU=");
    *empty.node.borrow_mut() = None;
    assert_eq!(may_connect(&empty, "vm_2"), Ok(()));
}

#[test]
fn the_acl_snippet_owns_reaches_and_lets_ssh_into_the_tag() {
    assert_eq!(parse_acl(&[]).unwrap(), "tag:cmux");
    assert_eq!(parse_acl(&words("--tag tag:dev")).unwrap(), "tag:dev");
    assert_eq!(parse_acl(&words("--tag=dev")).unwrap(), "dev");
    assert!(parse_acl(&words("--tag")).is_err());
    assert!(parse_acl(&words("vm_1")).is_err());

    let acl = cmux_tailnet_join::acl_snippet("dev").unwrap();
    let lines: Vec<&str> = acl.lines().collect();
    assert_eq!(lines.len(), 3, "{acl}");
    assert!(lines[0].starts_with("\"tagOwners\": {\"tag:dev\""), "{acl}");
    assert!(
        lines[1].starts_with("\"grants\": ") && lines[1].contains("\"dst\": [\"tag:dev\"]"),
        "{acl}"
    );
    assert!(
        lines[2].starts_with("\"ssh\": ") && lines[2].contains("\"action\": \"accept\""),
        "{acl}"
    );
    // Each line is one key of a policy file: wrapped in braces, the three parse as JSON.
    let whole = format!("{{{}}}", acl.trim_end_matches(','));
    let policy: serde_json::Value =
        serde_json::from_str(&whole).expect("the snippet is policy JSON");
    assert_eq!(policy["grants"][0]["src"][0], "autogroup:member");
    assert!(cmux_tailnet_join::acl_snippet("tag:9bad").is_err());
}
