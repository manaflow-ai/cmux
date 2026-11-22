use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use super::*;

/// A Cloud with one person: machines by idempotency key, the probes the machine answers in order
/// (the last one repeats) and every call made.
#[derive(Default)]
struct Fake {
    machines: RefCell<HashMap<String, Value>>,
    chiefs: RefCell<Vec<Value>>,
    probes: RefCell<VecDeque<Value>>,
    calls: RefCell<Vec<String>>,
    status: RefCell<Vec<&'static str>>,
}

impl Fake {
    fn probes(&self, probes: Vec<Value>) {
        *self.probes.borrow_mut() = probes.into();
    }
    fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }
    fn count(&self, prefix: &str) -> usize {
        self.calls().iter().filter(|c| c.starts_with(prefix)).count()
    }
}

impl Cloud for Fake {
    async fn op(&self, op: &str, params: Value, key: &str) -> Result<Value, Failure> {
        self.calls.borrow_mut().push(format!("{op} {key}"));
        match op {
            "cloud.machine.create" => {
                let mut machines = self.machines.borrow_mut();
                let n = machines.len();
                let row = machines.entry(key.to_owned()).or_insert_with(
                    || json!({ "id": format!("vm_{n:020}"), "name": params["name"] }),
                );
                Ok(json!({ "machine": row.clone() }))
            }
            "chief.create" => {
                let chief = json!({
                    "id": "chief_1", "main_conversation": "conv_1",
                    "brain_place": params["brain_place"],
                });
                self.chiefs.borrow_mut().push(chief.clone());
                Ok(chief)
            }
            _ => Ok(json!({})),
        }
    }

    async fn read(&self, op: &str, _params: Value) -> Result<Value, Failure> {
        self.calls.borrow_mut().push(op.to_owned());
        match op {
            "cloud.machine.get" => {
                let status = self.status.borrow_mut().pop().unwrap_or("running");
                let id = self.machines.borrow().values().next().unwrap()["id"].clone();
                Ok(
                    json!({ "machine": { "id": id, "status": status, "host": "host_1", "revision": 3 } }),
                )
            }
            "chief.list" => Ok(json!({ "chiefs": self.chiefs.borrow().clone() })),
            "team.policy.get" => Ok(json!({ "team": "team_1" })),
            _ => Ok(json!({})),
        }
    }

    async fn exec(&self, _machine: &str, command: &str) -> Result<(i64, String, String), Failure> {
        let kind = if command.contains("python3 -I") {
            "probe"
        } else if command.contains("cloud pair") {
            "pair"
        } else if command.contains("enable --now") {
            "host"
        } else {
            "other"
        };
        self.calls.borrow_mut().push(format!("exec {kind}"));
        if kind == "probe" {
            let mut probes = self.probes.borrow_mut();
            let next = if probes.len() > 1 { probes.pop_front() } else { probes.front().cloned() };
            return Ok((0, next.unwrap_or_else(|| json!({})).to_string(), String::new()));
        }
        Ok((0, "ok\n".into(), String::new()))
    }

    async fn pause(&self, _duration: Duration) {}
}

fn start(until_machine: bool) -> Start {
    Start {
        key: "k1".into(),
        chief_name: "Chief".into(),
        machine_name: "chief-k1".into(),
        team: None,
        api: "https://api.example".into(),
        until_machine,
    }
}

fn done() -> Value {
    json!({ "install": "inst_1", "host": "host_1", "chief": "chief_1", "conversation": "conv_1",
            "binary": "/usr/local/bin/optchat-chief", "unit": true, "active": false })
}

#[tokio::test]
async fn a_new_start_makes_pairs_places_and_starts_the_host() {
    let fake = Fake::default();
    fake.probes(vec![
        json!({ "binary": "/usr/local/bin/optchat-chief", "unit": true }),
        json!({ "binary": "/usr/local/bin/optchat-chief", "unit": true, "pairing": true, "code": "ABCD2345" }),
        json!({ "binary": "/usr/local/bin/optchat-chief", "unit": true, "pairing": true,
                "install": "inst_1", "host": "host_1" }),
        done(),
    ]);
    let answer = run(&fake, &start(false)).await.unwrap();
    assert_eq!(answer["stage"], "done");
    assert_eq!(answer["chief"], "chief_1");
    assert_eq!(answer["conversation"], "conv_1");
    assert_eq!(answer["install"], "inst_1");
    assert_eq!(answer["host_unit"], "image");
    let calls = fake.calls();
    assert!(calls.contains(&"cloud.machine.create chief-machine-k1-create".to_owned()));
    assert!(calls.contains(&"cloud.machine.idle_policy.set chief-machine-k1-idle".to_owned()));
    assert!(calls.contains(&"cloud.machine.keep chief-machine-k1-keep".to_owned()));
    assert!(calls.contains(&"server.pair.approve chief-machine-k1-approve-abcd2345".to_owned()));
    assert!(calls.contains(&"chief.create chief-machine-k1-chief".to_owned()));
    assert_eq!(fake.count("exec pair"), 1);
    assert_eq!(fake.count("exec host"), 1);
    // The team came from the person's policy, the Chief is not the default.
    assert_eq!(fake.count("team.policy.get"), 1);
    assert_eq!(fake.chiefs.borrow()[0]["brain_place"]["install"], "inst_1");
}

#[tokio::test]
async fn running_it_again_never_makes_a_second_machine_or_chief() {
    let fake = Fake::default();
    fake.probes(vec![
        json!({ "binary": "/x", "unit": true, "install": "inst_1", "host": "host_1" }),
        done(),
    ]);
    let first = run(&fake, &start(false)).await.unwrap();
    // The half-done second run: the file already names its Chief, the unit already runs.
    fake.probes(vec![json!({ "unit": true, "active": true, "install": "inst_1", "host": "host_1",
                             "chief": "chief_1", "conversation": "conv_1" })]);
    let second = run(&fake, &start(false)).await.unwrap();
    assert_eq!(first["machine"], second["machine"]);
    assert_eq!(fake.machines.borrow().len(), 1);
    assert_eq!(fake.chiefs.borrow().len(), 1);
    assert_eq!(fake.count("exec host"), 1);
    assert_eq!(second["host_unit"], "image");
}

#[tokio::test]
async fn a_paired_install_without_its_chief_finds_the_placed_one() {
    let fake = Fake::default();
    fake.chiefs.borrow_mut().push(json!({ "id": "chief_0", "main_conversation": "conv_0",
                                          "brain_place": { "host": "host_1", "install": "inst_1" } }));
    fake.probes(vec![
        json!({ "binary": "/x", "unit": true, "install": "inst_1", "host": "host_1" }),
        json!({ "binary": "/x", "unit": true, "install": "inst_1", "host": "host_1",
                "chief": "chief_0", "conversation": "conv_0" }),
    ]);
    let answer = run(&fake, &start(false)).await.unwrap();
    assert_eq!(answer["chief"], "chief_0");
    assert_eq!(fake.count("chief.create"), 0);
    assert_eq!(fake.count("server.pair.approve"), 0);
}

#[tokio::test]
async fn until_machine_stops_before_the_machine_is_touched() {
    let fake = Fake::default();
    let answer = run(&fake, &start(true)).await.unwrap();
    assert_eq!(answer["stage"], "machine");
    assert_eq!(fake.count("exec"), 0);
    assert_eq!(fake.count("cloud.machine.idle_policy.set"), 1);
}

#[tokio::test]
async fn a_paused_machine_is_started_again() {
    let fake = Fake::default();
    fake.status.borrow_mut().extend(["running", "paused"]);
    run(&fake, &start(true)).await.unwrap();
    assert_eq!(fake.count("cloud.machine.start"), 1);
}

#[tokio::test]
async fn an_image_without_a_host_is_refused_with_what_to_do() {
    let fake = Fake::default();
    fake.probes(vec![json!({})]);
    let Err(Failure::Http { code, .. }) = run(&fake, &start(false)).await else { panic!() };
    assert_eq!(code.as_deref(), Some("chief.host_missing"));
    assert_eq!(fake.count("server.pair.approve"), 0);
}

#[tokio::test]
async fn an_image_without_the_unit_gets_it_written() {
    let fake = Fake::default();
    let mut file = done();
    file["unit"] = json!(false);
    fake.probes(vec![file]);
    let answer = run(&fake, &start(false)).await.unwrap();
    assert_eq!(answer["host_unit"], "installed");
}

#[test]
fn the_args_are_checked() {
    let request = |args: Value| Request {
        call: "machine.chief_start".into(),
        api: "https://api.example/".into(),
        auth: Auth::Owner,
        credential: "t".into(),
        refresh: None,
        team: None,
        app_version: None,
        local_only: false,
        args: args.as_object().unwrap().clone(),
    };
    let parsed = parse(&request(json!({ "key": "run-7" }))).unwrap();
    assert_eq!(parsed.machine_name, "chief-run-7");
    assert_eq!(parsed.chief_name, "Chief");
    assert_eq!(parsed.api, "https://api.example");
    assert!(parse(&request(json!({ "key": "Bad Key" }))).is_err());
    assert!(parse(&request(json!({}))).is_err());
    assert!(parse(&request(json!({ "key": "a", "until": "pair" }))).is_err());
    assert!(parse(&request(json!({ "key": "a", "machine_name": "x y" }))).is_err());
    let named =
        parse(&request(json!({ "key": "a", "machine_name": "cmux-test-9", "name": " Ops ",
                                       "until": "machine" })))
        .unwrap();
    assert_eq!((named.machine_name.as_str(), named.chief_name.as_str()), ("cmux-test-9", "Ops"));
    assert!(named.until_machine);
}

#[test]
fn shell_quoting_survives_a_quote() {
    assert_eq!(shq("it's"), r"'it'\''s'");
    // Run by sh, as_user's own quoting undone, the name comes back whole.
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("set -- {}; printf %s \"$1\"", shq("n'x")))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "n'x");
    assert!(pair_command("https://a", "n").contains("cloud pair --install"));
    assert!(
        fallback_unit("/b/optchat-chief")
            .contains("ExecStart=/bin/sh -c 'exec /b/optchat-chief host")
    );
}
