use std::collections::VecDeque;
use std::time::Duration;

use cmux_cloud_start_core::machine_bootstrap::ExecAnswer;

use super::*;

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
    let checked = checked(args, |_| Ok("tskey-auth-SECRET\n".to_owned())).unwrap();
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
    let checked = checked(args, |_| Ok("tskey-auth-a".to_owned())).unwrap();
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
