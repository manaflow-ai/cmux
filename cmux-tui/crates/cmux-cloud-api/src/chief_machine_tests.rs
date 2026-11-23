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
    /// What `cloud.plan.get` answers: `None` is a failed read.
    plan: RefCell<Option<Value>>,
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
                let row = machines.entry(key.to_owned()).or_insert_with(|| {
                    json!({ "id": format!("vm_{n:020}"), "name": params["name"],
                            "size": params["size"] })
                });
                // The same key with another request: refused, as the platform does.
                if row["size"] != params["size"] {
                    return Err(Failure::http(409, Some("idempotency.conflict".into()), None));
                }
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
            "cloud.plan.get" => self.plan.borrow().clone().ok_or_else(|| {
                Failure::http(503, Some("cloud.unavailable".into()), Some("plan read".into()))
            }),
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
    // Its own acpmux home: the machine's not-dumpable daemon would be refused as its peer.
    assert!(
        fallback_unit("/b/x").contains("Environment=ACPMUX_HOME=/home/cmux/.cmux/chief/acpmux\n")
    );
    assert!(
        fallback_unit("/b/x").contains("Environment=ACPMUX_BIN=/opt/cmux/current/bin/acpmux\n")
    );
}

#[test]
fn the_plan_gives_the_included_chief_unless_it_names_an_add_on() {
    // Every paid plan's Chief: 2 vCPU / 4 GiB / 32 GiB (RFD 0037), not the old 4/8/32.
    assert_eq!(chief_size_for(None), ChiefSize::Included);
    assert_eq!(ChiefSize::Included.shape(), (2, 4096, 32768));
    assert_eq!(chief_size_for(Some("chief_m")).shape(), (2, 8192, 32768));
    assert_eq!(chief_size_for(Some("chief_l")).shape(), (4, 16384, 65536));
    assert_eq!(chief_size_for(Some("chief_xl")).shape(), (8, 32768, 131_072));
    // A name this build does not know is never a paid size.
    assert_eq!(chief_size_for(Some("chief_xxl")), ChiefSize::Included);
    assert_eq!(chief_size_for(Some("")), ChiefSize::Included);
}

#[test]
fn the_plans_chief_size_names_the_size() {
    // cmux-platform#1685: exactly one of included, M, L, XL.
    assert_eq!(chief_size_for(Some("included")), ChiefSize::Included);
    assert_eq!(chief_size_for(Some("M")), ChiefSize::M);
    assert_eq!(chief_size_for(Some("L")), ChiefSize::L);
    assert_eq!(chief_size_for(Some("XL")), ChiefSize::Xl);
    assert_eq!(chief_size_for(Some("XXL")), ChiefSize::Included);
    assert_eq!(plan_chief_size(&json!({ "plan_id": "pro", "chief_size": "L" })), ChiefSize::L);
    assert_eq!(plan_chief_size(&json!({ "plan": { "chief_size": "XL" } })), ChiefSize::Xl);
    assert_eq!(plan_chief_size(&json!({ "chief_size": "chief_m" })), ChiefSize::M);
    // Missing, null or not text: the included size.
    assert_eq!(plan_chief_size(&json!({ "plan_id": "pro" })), ChiefSize::Included);
    assert_eq!(plan_chief_size(&json!({ "chief_size": null })), ChiefSize::Included);
    assert_eq!(plan_chief_size(&json!({ "chief_size": 3 })), ChiefSize::Included);
    assert_eq!(plan_chief_size(&json!(null)), ChiefSize::Included);
}

#[test]
fn the_create_asks_for_the_size_it_was_given() {
    let params = create_params(&start(false), ChiefSize::L);
    assert_eq!(
        params,
        json!({ "name": "chief-k1", "size": { "cpu": 4, "memory_mb": 16384, "disk_mb": 65536 } })
    );
}

/// The Cloud a start sees, keeping every create's params.
#[derive(Default)]
struct Recording {
    fake: Fake,
    creates: RefCell<Vec<Value>>,
}

impl Cloud for Recording {
    async fn op(&self, op: &str, params: Value, key: &str) -> Result<Value, Failure> {
        if op == "cloud.machine.create" {
            self.creates.borrow_mut().push(params.clone());
        }
        self.fake.op(op, params, key).await
    }
    async fn read(&self, op: &str, params: Value) -> Result<Value, Failure> {
        self.fake.read(op, params).await
    }
    async fn exec(&self, machine: &str, command: &str) -> Result<(i64, String, String), Failure> {
        self.fake.exec(machine, command).await
    }
    async fn pause(&self, duration: Duration) {
        self.fake.pause(duration).await;
    }
}

fn included_create() -> Vec<Value> {
    vec![json!({ "name": "chief-k1", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 32768 } })]
}

#[tokio::test]
async fn a_start_creates_the_included_chief() {
    let cloud = Recording::default();
    *cloud.fake.plan.borrow_mut() = Some(json!({ "plan_id": "pro", "chief_size": "included" }));
    run(&cloud, &start(true)).await.unwrap();
    assert_eq!(*cloud.creates.borrow(), included_create());
}

#[tokio::test]
async fn a_start_creates_the_size_the_plan_names() {
    let cloud = Recording::default();
    *cloud.fake.plan.borrow_mut() = Some(json!({ "plan_id": "max", "chief_size": "XL" }));
    run(&cloud, &start(true)).await.unwrap();
    assert_eq!(
        *cloud.creates.borrow(),
        vec![json!({ "name": "chief-k1",
                     "size": { "cpu": 8, "memory_mb": 32768, "disk_mb": 131_072 } })]
    );
    // The plan is read once, before the create.
    let calls = cloud.fake.calls();
    let plan = calls.iter().position(|c| c == "cloud.plan.get").unwrap();
    let create = calls.iter().position(|c| c.starts_with("cloud.machine.create")).unwrap();
    assert!(plan < create);
    assert_eq!(cloud.fake.count("cloud.plan.get"), 1);
}

#[tokio::test]
async fn a_plan_that_names_no_size_starts_the_included_chief() {
    let cloud = Recording::default();
    *cloud.fake.plan.borrow_mut() = Some(json!({ "plan_id": "pro", "limits": {} }));
    run(&cloud, &start(true)).await.unwrap();
    assert_eq!(*cloud.creates.borrow(), included_create());
}

#[tokio::test]
async fn a_failed_plan_read_still_starts_the_included_chief() {
    let cloud = Recording::default();
    // No plan answer: the read fails, and the start goes on at the included size.
    let answer = run(&cloud, &start(true)).await.unwrap();
    assert_eq!(answer["stage"], "machine");
    assert_eq!(*cloud.creates.borrow(), included_create());
}

#[tokio::test]
async fn a_rerun_whose_plan_read_fails_finds_the_machine_the_first_run_made() {
    let cloud = Recording::default();
    *cloud.fake.plan.borrow_mut() = Some(json!({ "chief_size": "L" }));
    let first = run(&cloud, &start(true)).await.unwrap();
    // The rerun's plan read fails: its included-size create conflicts with the first run's key,
    // and the create at the other sizes replays the L machine.
    *cloud.fake.plan.borrow_mut() = None;
    let second = run(&cloud, &start(true)).await.unwrap();
    assert_eq!(first["machine"], second["machine"]);
    assert_eq!(cloud.fake.machines.borrow().len(), 1);
    assert_eq!(cloud.fake.machines.borrow().values().next().unwrap()["size"]["cpu"], 4);
    // An upgrade between the runs finds it the same way.
    *cloud.fake.plan.borrow_mut() = Some(json!({ "chief_size": "XL" }));
    let third = run(&cloud, &start(true)).await.unwrap();
    assert_eq!(first["machine"], third["machine"]);
    assert_eq!(cloud.fake.machines.borrow().len(), 1);
}
