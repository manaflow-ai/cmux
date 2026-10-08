//! The credential relay (bead cx-wb5.57, app-op-routing.md, APP-R1): a
//! first-party app server that declares `op:cmux.credential.relay` sends its
//! `relay.op` and `relay.session` lines (first-party-apps/cloud/server
//! src/api/relay.rs) to the daemon; the supervisor routes them over the
//! provider channel to the `credential` provider (the Mac app, which adds
//! the install token and calls the Cloud API) and answers the server with
//! `relay.result`, `relay.session` or `relay.error`. No credential is in any
//! line the daemon sees.

use super::*;
use crate::apps::provider::ProviderClaim;

const PROVIDER: u64 = 9;
const MAC_APP: ProviderClaim = ProviderClaim { agent: false, verified_app: true };

/// A server that sends the lines of the file in `$2` once, appends every
/// line it receives to the file in `$1`, and sends the lines of the file in
/// `$3` (when it exists) each time an op line arrives.
fn write_relay_probe(dir: &Path) {
    write_script(
        dir,
        "relay-probe",
        "#!/bin/sh\ncat \"$2\"\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> \"$1\"\n  case \"$line\" in\n    *'\"type\":\"op\"'*) [ -f \"$3\" ] && cat \"$3\" ;;\n  esac\ndone\n",
    );
}

/// One relay probe app `cmux/<dir>` that sends `lines` once it starts;
/// `scoped` adds the server scope `op:cmux.credential.relay`.
struct Probe {
    dir: &'static str,
    scoped: bool,
    lines: Vec<Value>,
    /// Lines it sends while an op runs.
    on_op: Vec<Value>,
}

impl Probe {
    fn new(dir: &'static str, scoped: bool, lines: Vec<Value>) -> Self {
        Self { dir, scoped, lines, on_op: vec![] }
    }
}

/// Writes the probe apps, then the fixture (the catalog loads at start).
/// Returns the fixture and, per probe, the file of the lines it receives.
fn setup(probes: &[Probe]) -> (Fixture, Vec<PathBuf>) {
    let root = temp_dir();
    write_relay_probe(&root.0.join("servers"));
    let outs = probes
        .iter()
        .map(|probe| {
            let out = root.0.join(format!("{}.out", probe.dir));
            let send = root.0.join(format!("{}.send", probe.dir));
            let text: String = probe.lines.iter().map(|l| format!("{l}\n")).collect();
            std::fs::write(&send, text).unwrap();
            let on_op = root.0.join(format!("{}.on-op", probe.dir));
            if !probe.on_op.is_empty() {
                let text: String = probe.on_op.iter().map(|l| format!("{l}\n")).collect();
                std::fs::write(&on_op, text).unwrap();
            }
            let mut server = json!({
                "kind": "native",
                "binaries": { "darwin-arm64": "relay-probe", "darwin-x64": "relay-probe", "linux-arm64": "relay-probe", "linux-x64": "relay-probe" },
                "args": [out.to_string_lossy(), send.to_string_lossy(), on_op.to_string_lossy()],
                "instances": "machine", "hosts": ["local"], "lifecycle": { "start": "always" }
            });
            if probe.scoped {
                server["scopes"] = json!({ "op:cmux.credential.relay": "Call the cmux Cloud API through the cmux app." });
            }
            write_server_app(&root.0.join("bundled"), probe.dir, server);
            out
        })
        .collect();
    (fixture_with(&[], Duration::from_secs(60), root), outs)
}

fn credential_provider(f: &Fixture) -> Receiver<Value> {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor.register_client(
        PROVIDER,
        Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
    );
    f.supervisor.register_provider(PROVIDER, MAC_APP, vec!["credential".into()]).unwrap();
    rx
}

fn next_event(rx: &Receiver<Value>, name: &str) -> Value {
    loop {
        let event = rx.recv_timeout(Duration::from_secs(10)).expect(name);
        if event["event"] == name {
            return event;
        }
    }
}

fn relay_op(id: &str, op: &str) -> Value {
    json!({ "type": "relay.op", "id": id, "op": op, "params": { "machine": "vm_1" }, "idempotency_key": "k1", "origin": "cli" })
}

#[test]
fn relay_lines_reach_the_credential_provider_and_its_answers_reach_the_server() {
    let lines = vec![
        relay_op("r1", "cloud.machine.connect_info"),
        json!({ "type": "relay.session", "id": "r2" }),
    ];
    let (f, outs) = setup(&[Probe::new("relay", true, lines)]);
    let rx = credential_provider(&f);
    f.install("cmux/relay");
    let out = &outs[0];

    let call = next_event(&rx, "apps-provider-request");
    assert_eq!(
        (
            call["app"].clone(),
            call["actor"]["kind"].clone(),
            call["op"].clone(),
            call["params"].clone()
        ),
        (
            json!("cmux/relay"),
            json!("app"),
            json!("credential.relay"),
            json!({ "op": "cloud.machine.connect_info", "params": { "machine": "vm_1" }, "idempotency_key": "k1", "origin": "cli" })
        )
    );
    let session = next_event(&rx, "apps-provider-request");
    assert_eq!(
        (session["op"].clone(), session["params"].clone()),
        (json!("credential.session"), json!({}))
    );

    let call_id = call["request_id"].as_u64().unwrap();
    let session_id = session["request_id"].as_u64().unwrap();
    f.supervisor
        .provider_result(
            PROVIDER,
            call_id,
            true,
            json!({ "value": { "host": "host_1" }, "revision": "5", "replayed": false }),
        )
        .unwrap();
    f.supervisor
        .provider_result(PROVIDER, session_id, true, json!({ "signed_in": true, "team": "team_a" }))
        .unwrap();
    let answers = frames(out, 2);
    assert_eq!(
        answers[0],
        json!({ "type": "relay.result", "id": "r1", "ok": true, "value": { "host": "host_1" }, "revision": "5", "replayed": false })
    );
    assert_eq!(
        answers[1],
        json!({ "type": "relay.session", "id": "r2", "signed_in": true, "team": "team_a" })
    );
}

#[test]
fn relay_errors_keep_the_contract_shapes() {
    let lines = vec![
        relay_op("r1", "cloud.machine.get"),
        relay_op("r2", "cloud.machine.get"),
        relay_op("r3", "cloud.machine.get"),
        json!({ "type": "relay.op", "id": "r4", "params": {} }),
    ];
    let (f, outs) = setup(&[Probe::new("relay", true, lines)]);
    let rx = credential_provider(&f);
    f.install("cmux/relay");
    let out = &outs[0];
    let first = next_event(&rx, "apps-provider-request");
    let second = next_event(&rx, "apps-provider-request");
    let _third = next_event(&rx, "apps-provider-request");
    // An owner error is a relay.result with ok false, as the Cloud API sent it.
    f.supervisor
        .provider_result(
            PROVIDER,
            first["request_id"].as_u64().unwrap(),
            false,
            json!({ "code": "cloud.machine.not_found", "message": "no such machine", "retryable": false, "details": { "machine": "vm_1" } }),
        )
        .unwrap();
    // The app has no session: relay.error not_signed_in.
    f.supervisor
        .provider_result(
            PROVIDER,
            second["request_id"].as_u64().unwrap(),
            false,
            json!({ "code": "not_signed_in", "message": "sign in to cmux", "retryable": false }),
        )
        .unwrap();
    // The third is never answered: the deadline (400 ms here) gives relay.error unavailable.
    let answers = frames(out, 4);
    let by_id = |id: &str| answers.iter().find(|a| a["id"] == id).cloned().unwrap();
    assert_eq!(
        by_id("r1"),
        json!({ "type": "relay.result", "id": "r1", "ok": false, "error": { "code": "cloud.machine.not_found", "message": "no such machine", "retryable": false, "details": { "machine": "vm_1" } } })
    );
    assert_eq!(
        (by_id("r2")["type"].clone(), by_id("r2")["code"].clone()),
        (json!("relay.error"), json!("not_signed_in"))
    );
    assert_eq!(
        (by_id("r3")["type"].clone(), by_id("r3")["code"].clone()),
        (json!("relay.error"), json!("unavailable"))
    );
    // A relay.op without an op is refused at once and never reaches the provider.
    assert_eq!(
        (by_id("r4")["type"].clone(), by_id("r4")["code"].clone()),
        (json!("relay.error"), json!("validation.invalid"))
    );
    assert!(
        rx.recv_timeout(Duration::from_millis(200))
            .iter()
            .all(|e| e["event"] != "apps-provider-request")
    );
}

#[test]
fn relay_needs_the_scope_and_a_provider() {
    let (f, outs) = setup(&[
        Probe::new("lonely", true, vec![relay_op("r1", "cloud.machine.get")]),
        Probe::new("unscoped", false, vec![relay_op("r1", "cloud.machine.get")]),
    ]);
    // No provider connected: unavailable at once.
    f.install("cmux/lonely");
    let answer = &frames(&outs[0], 1)[0];
    assert_eq!(
        (answer["type"].clone(), answer["id"].clone(), answer["code"].clone()),
        (json!("relay.error"), json!("r1"), json!("unavailable"))
    );
    // A server without the scope never reaches the provider.
    let rx = credential_provider(&f);
    f.install("cmux/unscoped");
    let refused = &frames(&outs[1], 1)[0];
    assert_eq!(
        (refused["type"].clone(), refused["code"].clone()),
        (json!("relay.error"), json!("apps.scope_missing"))
    );
    assert!(
        rx.recv_timeout(Duration::from_millis(200))
            .iter()
            .all(|e| e["event"] != "apps-provider-request")
    );
}

#[test]
fn a_stopped_server_cancels_its_relay_calls_and_a_late_answer_goes_nowhere() {
    let (f, _outs) = setup(&[Probe::new("relay", true, vec![relay_op("r1", "cloud.machine.get")])]);
    let rx = credential_provider(&f);
    f.install("cmux/relay");
    let call = next_event(&rx, "apps-provider-request");
    let id = call["request_id"].as_u64().unwrap();
    f.set("rm", "cmux/relay", Origin::User, |o| o.installed = Some(false)).unwrap();
    let cancel = next_event(&rx, "apps-provider-cancel");
    assert_eq!(cancel["request_id"], json!(id));
    assert_eq!(
        f.supervisor.provider_result(PROVIDER, id, true, json!({ "value": 1 })).unwrap_err().code,
        "apps.provider.unknown"
    );
}

fn with_origin(id: &str, origin: &str) -> Value {
    let mut line = relay_op(id, "cloud.machine.start");
    line["origin"] = json!(origin);
    line
}

/// Starts a run of `cmux/<dir>.ping` with `origin` and does not wait for it.
fn start_run(f: &Fixture, dir: &str, origin: Origin) {
    f.supervisor.run(
        run_request(&format!("cmux/{dir}"), &format!("{dir}.ping"), None, origin, None),
        Box::new(|_| {}),
    );
}

#[test]
fn a_relay_claims_origin_user_only_while_a_user_run_is_in_flight() {
    let user_run = Probe {
        on_op: vec![with_origin("r2", "user")],
        ..Probe::new("userrun", true, vec![with_origin("r1", "user")])
    };
    let cli_run =
        Probe { on_op: vec![with_origin("r1", "user")], ..Probe::new("clirun", true, vec![]) };
    let (f, outs) = setup(&[user_run, cli_run]);
    let rx = credential_provider(&f);
    f.install("cmux/userrun");
    // No run in flight: the claim is refused, never downgraded.
    let refused = &frames(&outs[0], 1)[0];
    assert_eq!(
        (refused["id"].clone(), refused["code"].clone()),
        (json!("r1"), json!("apps.origin_forbidden"))
    );
    // During a user run the claim goes to the provider.
    start_run(&f, "userrun", Origin::User);
    let call = next_event(&rx, "apps-provider-request");
    assert_eq!(
        (call["origin"].clone(), call["params"]["origin"].clone()),
        (json!("user"), json!("user"))
    );
    // During a cli run it is refused.
    f.install("cmux/clirun");
    start_run(&f, "clirun", Origin::Cli);
    let lines = frames(&outs[1], 2);
    let answer = lines.iter().find(|l| l["id"] == "r1").cloned().unwrap();
    assert_eq!(answer["code"], json!("apps.origin_forbidden"));
}

#[test]
fn one_server_has_at_most_four_relay_calls_and_ids_are_short_strings() {
    let mut lines: Vec<Value> =
        (1..=6).map(|n| relay_op(&format!("r{n}"), "cloud.machine.get")).collect();
    lines.push(json!({ "type": "relay.session", "id": 5 }));
    let (f, outs) = setup(&[Probe::new("relay", true, lines)]);
    let rx = credential_provider(&f);
    f.install("cmux/relay");
    for _ in 0..4 {
        next_event(&rx, "apps-provider-request");
    }
    let answers = frames(&outs[0], 3);
    let code = |id: Value| answers.iter().find(|a| a["id"] == id).map(|a| a["code"].clone());
    assert_eq!(code(json!("r5")), Some(json!("unavailable")));
    assert_eq!(code(json!("r6")), Some(json!("unavailable")));
    assert_eq!(code(json!(5)), Some(json!("validation.invalid")));
}
