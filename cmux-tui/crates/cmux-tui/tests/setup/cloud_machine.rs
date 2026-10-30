//! `cmux setup cloud-machine` driven the way an agent drives it, against a
//! fake cmux app that shows Cloud machines and asks its person on a card.

use std::collections::HashMap;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::{World, serve_app, shell_words};

/// The app's reason when the person declines the card.
const DECLINED: &str = "No Cloud machine was created: the person declined or \
                        dismissed it in cmux.";

const FORGET: &str = "cmux setup cloud-machine --forget";

/// How the fake app's person answers the New Cloud Machine card.
#[derive(Clone, Copy, PartialEq)]
enum Card {
    Allow,
    Decline,
    /// Allowed, and the machine is not there within the app's 30 s.
    Slow,
    /// The plan allows no more machines: the app's create fails with the
    /// backend's reason (a `daemon_error`).
    Refuse,
    /// Allowed, and the connection drops before the answer: the machine is
    /// made and setup never reads it.
    Drop,
    /// The connection drops before the app took the request: nothing made.
    Lost,
    /// Allowed, and the app answers no `result` (an app before #23155):
    /// the creation is on its way.
    Null,
}

/// A fake cmux app that serves what `cmux setup cloud-machine` and `cmux
/// cloud kill-machine` ask: `auth.status`, `cloud.machines` (its
/// `machines`, `creations`, `last_error`, and `loaded` when set), and
/// `action.run` of `newCloudMachine` (the person's card answers as `card`;
/// a run with a key it answered before gets the same answer until a
/// `restart`, as the app's in-memory cache does) and of `cloud
/// kill-machine`, whose machine leaves the list. Every request is kept.
struct FakeCloud {
    signed_in: Arc<AtomicBool>,
    /// The `loaded` field; None leaves it out, as the app does today.
    loaded: Arc<Mutex<Option<bool>>>,
    last_error: Arc<Mutex<Value>>,
    card: Arc<Mutex<Card>>,
    machines: Arc<Mutex<Vec<Value>>>,
    creations: Arc<Mutex<Vec<Value>>>,
    /// Each card's answer, by the run's idempotency key.
    answers: Arc<Mutex<HashMap<String, Result<Value, Value>>>>,
    /// Cards the person was shown.
    shown: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeCloud {
    fn start(world: &mut World) -> Self {
        let socket = world.home.parent().unwrap().join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        world.app = Some(socket);
        let cloud = Self {
            signed_in: Arc::new(AtomicBool::new(true)),
            loaded: Arc::new(Mutex::new(None)),
            last_error: Arc::new(Mutex::new(Value::Null)),
            card: Arc::new(Mutex::new(Card::Allow)),
            machines: Arc::new(Mutex::new(Vec::new())),
            creations: Arc::new(Mutex::new(Vec::new())),
            answers: Arc::new(Mutex::new(HashMap::new())),
            shown: Arc::new(AtomicUsize::new(0)),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let (signed_in, loaded, last_error, card) = (
            cloud.signed_in.clone(),
            cloud.loaded.clone(),
            cloud.last_error.clone(),
            cloud.card.clone(),
        );
        let (machines, creations, answers, shown) = (
            cloud.machines.clone(),
            cloud.creations.clone(),
            cloud.answers.clone(),
            cloud.shown.clone(),
        );
        serve_app(listener, cloud.requests.clone(), move |method, params| match method {
            "auth.status" => Some(Ok(json!({"signed_in": signed_in.load(Ordering::SeqCst),
                "restoring": false, "cloud_unavailable": null}))),
            "cloud.machines" => {
                let (rows, creations) =
                    (machines.lock().unwrap().clone(), creations.lock().unwrap().clone());
                let mut listing = json!({"machines": rows, "creations": creations,
                    "last_error": *last_error.lock().unwrap()});
                if let Some(loaded) = *loaded.lock().unwrap() {
                    listing["loaded"] = json!(loaded);
                }
                Some(Ok(listing))
            }
            "action.run" if params["action"] == "newCloudMachine" => {
                let key = params["idempotency_key"].as_str().unwrap_or_default().to_owned();
                let mut answers = answers.lock().unwrap();
                if let Some(answer) = answers.get(&key) {
                    return Some(answer.clone());
                }
                let card = *card.lock().unwrap();
                if card == Card::Lost {
                    return None;
                }
                let n = shown.fetch_add(1, Ordering::SeqCst) + 1;
                let refusal = |reason: &str| {
                    Err(json!({"code": "unavailable",
                        "message": format!("newCloudMachine unavailable: {reason}"),
                        "data": {"action": "newCloudMachine", "reason": reason}}))
                };
                let answer = match card {
                    Card::Decline => refusal(DECLINED),
                    Card::Refuse => Err(json!({"code": "daemon_error",
                        "message": "new Cloud machine: Your plan allows no more Cloud machines.",
                        "data": {"action": "newCloudMachine"}})),
                    Card::Allow | Card::Drop | Card::Lost => {
                        let id = format!("vm-{n}");
                        let row = json!({"id": id, "title": "cmux", "status": "running"});
                        machines.lock().unwrap().push(row);
                        Ok(json!({"action": "newCloudMachine", "ran": true, "result": {
                            "machine_id": id, "title": "cmux", "status": "provisioning",
                            "target": format!("machine:{id}")}}))
                    }
                    Card::Slow | Card::Null => {
                        let id = format!("cr-{n}");
                        let row = json!({"id": id, "machine_id": null, "stage": "creating"});
                        creations.lock().unwrap().push(row);
                        let result = match card {
                            Card::Slow => {
                                json!({"pending": true, "status": "creating", "creation_id": id})
                            }
                            _ => Value::Null,
                        };
                        Ok(json!({"action": "newCloudMachine", "ran": true, "result": result}))
                    }
                };
                answers.insert(key, answer.clone());
                (card != Card::Drop).then_some(answer)
            }
            "action.run" if params["action"] == "cloud kill-machine" && params["cli"] == true => {
                if params["args"]["confirm"] != true {
                    return Some(Err(
                        json!({"code": "confirmation_required", "message": "pass --confirm"}),
                    ));
                }
                let id =
                    params["target"].as_str().unwrap_or_default().trim_start_matches("machine:");
                let mut machines = machines.lock().unwrap();
                let before = machines.len();
                // The app lists no destroyed machine.
                machines.retain(|row| row["id"] != id);
                Some(if machines.len() < before {
                    Ok(json!({"action": "cloud kill-machine", "ran": true, "result": {}}))
                } else {
                    Err(json!({"code": "not_found", "message": "no such machine"}))
                })
            }
            _ => Some(Err(json!({"code": "method_not_found", "message": "unknown"}))),
        });
        cloud
    }

    /// How many cards the person was shown.
    fn cards(&self) -> usize {
        self.shown.load(Ordering::SeqCst)
    }

    /// cmux restarts: it forgets every answer it gave a key.
    fn restart(&self) {
        self.answers.lock().unwrap().clear();
    }

    /// The idempotency key of every `newCloudMachine` run, in order.
    fn create_keys(&self) -> Vec<Value> {
        let requests = self.requests.lock().unwrap();
        requests
            .iter()
            .filter(|r| r["params"]["action"] == "newCloudMachine")
            .map(|r| r["params"]["idempotency_key"].clone())
            .collect()
    }
}

impl World {
    /// Runs each command of a `&&` line the way the agent's shell does,
    /// expecting each to succeed.
    fn run_line(&self, line: &str) {
        for command in line.split(" && ") {
            let words = shell_words(command);
            assert_eq!(words.first().map(String::as_str), Some("cmux"), "{line}");
            let args = words[1..].iter().map(String::as_str).collect::<Vec<_>>();
            let output = self.run(&args);
            assert!(
                output.status.success(),
                "{command}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    /// Where setup keeps its Cloud machine state and lock.
    fn setup_state(&self) -> PathBuf {
        self.home.parent().unwrap().join("state").join("setup")
    }

    fn cloud_check(&self) -> Value {
        self.json(&["setup", "status"])["checks"][5].clone()
    }
}

/// A Cloud machine driven the way an agent drives it: signed out is the
/// person's sign-in, a dry run asks nothing, the person declines and then
/// allows the machine on cmux's card, a rerun makes no second one, the
/// undo kills it and forgets it, and a run after that makes a new one.
#[test]
fn cmux_setup_cloud_machine_makes_one_with_the_persons_ok_and_never_a_second() {
    let mut world = World::new("cloud");
    let app = FakeCloud::start(&mut world);

    let check = world.cloud_check();
    assert_eq!(check["task"], "cloud_machine", "{check}");
    assert_eq!(check["state"], "needs_setup", "{check}");
    let fix = check["fix"].as_str().expect("status names its fix").to_owned();
    assert_eq!(fix, "cmux setup cloud-machine");

    app.signed_in.store(false, Ordering::SeqCst);
    let signed_out = world.follow(&fix);
    assert_eq!(signed_out["state"], "needs_user", "{signed_out}");
    assert_eq!(signed_out["user_action"]["kind"], "sign_in", "{signed_out}");
    assert_eq!(signed_out["user_action"]["command"], "cmux cloud sign-in");
    app.signed_in.store(true, Ordering::SeqCst);

    let planned = world.json(&["setup", "cloud-machine", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert!(planned["cost"].is_string(), "{planned}");
    assert!(app.create_keys().is_empty(), "a dry run asked the person");
    // A dry run writes nothing, not even its lock or folder.
    assert!(!world.setup_state().exists(), "a dry run wrote setup's state");
    let forget = world.json(&["setup", "cloud-machine", "--forget", "--dry-run"]);
    assert_eq!(forget["state"], "ok", "{forget}");
    assert!(!world.setup_state().exists(), "--forget --dry-run wrote setup's state");

    // The person declines: nothing made, and the agent asks before trying again.
    *app.card.lock().unwrap() = Card::Decline;
    let declined = world.follow(&fix);
    assert_eq!(declined["state"], "needs_user", "{declined}");
    assert_eq!(declined["user_action"]["kind"], "declined", "{declined}");
    assert_eq!(declined["undo"], Value::Null);

    // The person allows it: one machine, and its undo.
    *app.card.lock().unwrap() = Card::Allow;
    let made = world.follow(&fix);
    assert_eq!(made["state"], "changed", "{made}");
    let machine = json!({"id": "vm-2", "title": "cmux", "status": "provisioning",
        "target": "machine:vm-2"});
    assert_eq!(made["machine"], machine, "{made}");
    assert_eq!(made["inferred"], Value::Null, "{made}");
    let undo = made["undo"].as_str().expect("a change names its undo").to_owned();
    assert_eq!(
        undo,
        format!("cmux cloud kill-machine --target machine:vm-2 --confirm && {FORGET}")
    );
    assert_eq!(app.cards(), 2);

    // A rerun reads the machine it made, in the same shape, and asks nothing.
    let again = world.follow(&fix);
    assert_eq!(again["state"], "ok", "{again}");
    let running = json!({"id": "vm-2", "title": "cmux", "status": "running",
        "target": "machine:vm-2"});
    assert_eq!(again["machine"], running, "{again}");
    assert_eq!(app.cards(), 2, "a rerun made a second machine");
    let check = world.cloud_check();
    assert_eq!(
        (&check["state"], &check["machine"]["id"]),
        (&json!("ok"), &json!("vm-2")),
        "{check}"
    );

    // The undo, as the agent's shell runs it: the machine is killed and forgotten.
    world.run_line(&undo);
    assert!(app.machines.lock().unwrap().is_empty());
    assert_eq!(world.cloud_check()["state"], "needs_setup");
    let remade = world.follow(&fix);
    assert_eq!(remade["state"], "changed", "{remade}");
    assert_eq!(remade["machine"]["id"], "vm-3", "{remade}");
    assert_eq!(app.cards(), 3);

    let output = world.run(&["setup", "cloud-machine", "now"]);
    assert_eq!(output.status.code(), Some(2));
}

/// A machine that takes longer than the app's wait: setup keeps the
/// creation, reruns wait for it without asking again, a dry run reads it
/// without claiming it, and the machine it becomes is setup's own.
#[test]
fn cmux_setup_cloud_machine_waits_for_a_slow_creation_instead_of_a_second() {
    let mut world = World::new("cloudslow");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Slow;
    let pending = world.json(&["setup", "cloud-machine"]);
    assert_eq!(pending["state"], "needs_user", "{pending}");
    assert_eq!(pending["user_action"]["kind"], "wait", "{pending}");
    assert_eq!(pending["after"]["creation_id"], "cr-1", "{pending}");
    let rerun = pending["user_action"]["command"].as_str().unwrap().to_owned();

    let still = world.follow(&rerun);
    assert_eq!(still["user_action"]["kind"], "wait", "{still}");
    assert_eq!(world.cloud_check()["user_action"]["kind"], "wait");
    assert_eq!(app.create_keys().len(), 1, "a rerun asked for a second machine");

    // The machine comes up; the creation names it.
    app.machines.lock().unwrap().push(json!({"id": "vm-9", "title": "cmux", "status": "running"}));
    app.creations.lock().unwrap()[0]["machine_id"] = json!("vm-9");
    let looked = world.json(&["setup", "cloud-machine", "--dry-run"]);
    assert_eq!(looked["state"], "planned", "a dry run claimed a change: {looked}");
    assert_eq!(looked["before"], Value::Null, "{looked}");
    let undo = format!("cmux cloud kill-machine --target machine:vm-9 --confirm && {FORGET}");
    assert_eq!(looked["undo"], undo, "{looked}");
    let made = world.follow(&rerun);
    assert_eq!(made["state"], "changed", "{made}");
    assert_eq!((&made["machine"]["id"], &made["inferred"]), (&json!("vm-9"), &Value::Null));
    assert_eq!(
        made["undo"],
        format!("cmux cloud kill-machine --target machine:vm-9 --confirm && {FORGET}")
    );
    assert_eq!(world.follow(&rerun)["state"], "ok");
    assert_eq!(app.cards(), 1);

    // A creation that left the list once its workspace showed: the one new
    // machine is its, and setup says it inferred that.
    let mut world = World::new("cloudgone");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Slow;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    app.creations.lock().unwrap().clear();
    app.machines.lock().unwrap().push(json!({"id": "vm-5", "title": "cmux", "status": "running"}));
    let made = world.json(&["setup", "cloud-machine"]);
    assert_eq!(made["state"], "changed", "{made}");
    assert_eq!((&made["machine"]["id"], &made["inferred"]), (&json!("vm-5"), &json!(true)));
    assert!(made["undo_note"].is_string(), "{made}");
    assert_eq!(app.cards(), 1);
}

/// A list cmux could not read, has not loaded, or shows empty while setup
/// has a machine on file, decides nothing: the machine setup made is kept
/// and nothing is asked. Only a list that shows other machines says setup's
/// is gone. A machine on its way that setup did not ask for is waited for.
#[test]
fn cmux_setup_cloud_machine_decides_nothing_off_a_list_cmux_has_not_loaded() {
    let mut world = World::new("cloudload");
    let app = FakeCloud::start(&mut world);
    assert_eq!(world.json(&["setup", "cloud-machine"])["state"], "changed");

    // Before cmux's first refresh the list is empty, and says no more.
    let rows = std::mem::take(&mut *app.machines.lock().unwrap());
    let early = world.json(&["setup", "cloud-machine"]);
    assert_eq!(early["state"], "needs_user", "{early}");
    assert_eq!(early["user_action"]["kind"], "wait", "{early}");
    assert!(early["user_action"]["text"].as_str().unwrap().contains(FORGET), "{early}");
    assert_eq!(world.cloud_check()["user_action"]["kind"], "wait");
    *app.loaded.lock().unwrap() = Some(false);
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    *app.loaded.lock().unwrap() = None;

    // A refresh that failed leaves the list as it was, and says so.
    *app.machines.lock().unwrap() = rows;
    *app.last_error.lock().unwrap() = json!("The network connection was lost.");
    let failed = world.json(&["setup", "cloud-machine"]);
    assert_eq!(failed["user_action"]["kind"], "wait", "{failed}");
    assert_eq!(app.cards(), 1, "setup made a machine off a list it could not trust");

    // Read again: setup's machine is still its own.
    *app.last_error.lock().unwrap() = Value::Null;
    let back = world.json(&["setup", "cloud-machine"]);
    assert_eq!((&back["state"], &back["machine"]["id"]), (&json!("ok"), &json!("vm-1")), "{back}");

    // A list with another machine and not setup's: setup's is gone, and the
    // person's machine is enough.
    *app.machines.lock().unwrap() = vec![json!({"id": "mine", "title": "x", "status": "paused"})];
    let other = world.json(&["setup", "cloud-machine"]);
    assert_eq!(other["state"], "ok", "{other}");
    assert_eq!(other["before"], json!({"id": "vm-1", "status": "gone"}), "{other}");
    assert_eq!(other["machine"]["id"], "mine", "{other}");
    let note = other["note"].as_str().expect("a paused machine names its resume");
    assert!(note.contains("cmux cloud resume-machine --target machine:mine"), "{note}");
    assert_eq!(app.cards(), 1);

    // The person's machine failed: removing it is theirs to say.
    app.machines.lock().unwrap()[0]["status"] = json!("failed");
    let failed = world.json(&["setup", "cloud-machine"]);
    assert_eq!(failed["user_action"]["kind"], "app", "{failed}");
    let text = failed["user_action"]["text"].as_str().unwrap();
    assert!(text.contains("the person's machine") && text.contains("ask them"), "{text}");

    // A machine the person started in cmux is on its way: no second one.
    let mut world = World::new("cloudtheirs");
    let app = FakeCloud::start(&mut world);
    app.creations.lock().unwrap().push(json!({"id": "c", "machine_id": null, "stage": "booting"}));
    let theirs = world.json(&["setup", "cloud-machine"]);
    assert_eq!(theirs["user_action"]["kind"], "wait", "{theirs}");
    assert_eq!(world.cloud_check()["user_action"]["kind"], "wait");
    assert_eq!(app.cards(), 0);
}

/// A create whose answer never came back is decided from the list first:
/// a machine made while cmux then restarted (and forgot the key) is
/// adopted, never made twice; only when nothing new appeared, on a list cmux
/// says it loaded, is the create sent again with its key.
#[test]
fn cmux_setup_cloud_machine_reads_the_list_before_sending_a_create_again() {
    // The answer was lost and cmux restarted: the new machine is setup's.
    let mut world = World::new("clouddrop");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Drop;
    let lost = world.json(&["setup", "cloud-machine"]);
    assert_eq!(lost["user_action"]["kind"], "wait", "{lost}");
    // Status already reads the machine that appeared, and writes nothing.
    assert_eq!(world.cloud_check()["machine"]["id"], "vm-1");
    app.restart();
    *app.card.lock().unwrap() = Card::Allow;
    let adopted = world.json(&["setup", "cloud-machine"]);
    assert_eq!(adopted["state"], "changed", "{adopted}");
    assert_eq!((&adopted["machine"]["id"], &adopted["inferred"]), (&json!("vm-1"), &json!(true)));
    assert_eq!(app.create_keys().len(), 1, "the create was sent again");
    assert_eq!(app.cards(), 1, "the person saw a second card");
    assert_eq!(world.json(&["setup", "cloud-machine"])["state"], "ok");

    // No result at all, and a restart: the creation it started is waited for.
    let mut world = World::new("cloudnull");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Null;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    app.restart();
    let on_its_way = world.json(&["setup", "cloud-machine"]);
    assert_eq!(on_its_way["user_action"]["kind"], "wait", "{on_its_way}");
    app.machines.lock().unwrap().push(json!({"id": "vm-7", "title": "cmux", "status": "running"}));
    app.creations.lock().unwrap()[0]["machine_id"] = json!("vm-7");
    let made = world.json(&["setup", "cloud-machine"]);
    assert_eq!(made["state"], "changed", "{made}");
    // No creation setup recorded names it, so setup says it inferred it.
    assert_eq!((&made["machine"]["id"], &made["inferred"]), (&json!("vm-7"), &json!(true)));
    assert_eq!(app.create_keys().len(), 1, "the create was sent again");
    assert_eq!(app.cards(), 1);

    // The request never reached cmux: on an empty list setup waits; once
    // cmux says it loaded the list, the create goes again with its key.
    let mut world = World::new("cloudlost");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Lost;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    *app.card.lock().unwrap() = Card::Allow;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    assert_eq!(app.create_keys().len(), 1, "sent again off an empty list");
    *app.loaded.lock().unwrap() = Some(true);
    let made = world.json(&["setup", "cloud-machine"]);
    assert_eq!(made["state"], "changed", "{made}");
    let keys = app.create_keys();
    assert_eq!(keys.len(), 2, "{keys:?}");
    assert!(keys[0].is_string() && keys[0] == keys[1], "a new key: {keys:?}");
    assert_eq!(app.cards(), 1);
}

/// A refusal that is not the person's decline (a plan with no room) is the
/// app's to say; setup keeps the request, so reruns make nothing, and
/// `--forget` lets it ask afresh.
#[test]
fn cmux_setup_cloud_machine_names_a_plan_refusal_as_the_apps() {
    let mut world = World::new("cloudplan");
    let app = FakeCloud::start(&mut world);
    *app.card.lock().unwrap() = Card::Refuse;
    let refused = world.json(&["setup", "cloud-machine"]);
    assert_eq!(refused["state"], "needs_user", "{refused}");
    let action = &refused["user_action"];
    assert_eq!(action["kind"], "app", "{refused}");
    let text = action["text"].as_str().unwrap();
    assert!(text.contains("Your plan allows no more Cloud machines."), "{text}");
    assert!(text.contains(FORGET), "{text}");
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    assert_eq!(app.create_keys().len(), 1);

    *app.card.lock().unwrap() = Card::Allow;
    let forgot = world.json(&["setup", "cloud-machine", "--forget"]);
    assert_eq!(forgot["state"], "changed", "{forgot}");
    assert!(forgot["before"]["key"].is_string(), "{forgot}");
    assert_eq!(world.json(&["setup", "cloud-machine", "--forget"])["state"], "ok");
    assert_eq!(world.json(&["setup", "cloud-machine"])["state"], "changed");
    let keys = app.create_keys();
    assert_ne!(keys[0], keys[1], "the refused create was sent again: {keys:?}");
}

/// A create whose answer never came, then a machine the person made
/// themselves: setup may only infer it is its own, says so, and names the
/// check before the undo; with two new machines it claims neither.
#[test]
fn cmux_setup_cloud_machine_says_when_it_only_inferred_its_machine() {
    let mut world = World::new("cloudguess");
    let app = FakeCloud::start(&mut world);
    *app.loaded.lock().unwrap() = Some(true);
    // Setup's create never reaches cmux (or the person declines it and its
    // row leaves); then the person makes a machine of their own in cmux.
    *app.card.lock().unwrap() = Card::Lost;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    let theirs = json!({"id": "theirs", "machine_id": "vm-p", "stage": "ready"});
    app.creations.lock().unwrap().push(theirs);
    app.machines.lock().unwrap().push(json!({"id": "vm-p", "title": "mine", "status": "running"}));
    let looked = world.json(&["setup", "cloud-machine", "--dry-run"]);
    assert_eq!((&looked["state"], &looked["inferred"]), (&json!("planned"), &json!(true)));
    assert!(looked["undo_note"].is_string(), "{looked}");
    let claimed = world.json(&["setup", "cloud-machine"]);
    assert_eq!(claimed["state"], "changed", "{claimed}");
    assert_eq!((&claimed["machine"]["id"], &claimed["inferred"]), (&json!("vm-p"), &json!(true)));
    let note = claimed["undo_note"].as_str().expect("an inferred machine names the check");
    assert!(note.contains("vm-p"), "{note}");
    assert_eq!(app.create_keys().len(), 1, "the create was sent again");

    // Two new machines: setup claims neither and leaves them to the person.
    let mut world = World::new("cloudmany");
    let app = FakeCloud::start(&mut world);
    *app.loaded.lock().unwrap() = Some(true);
    *app.card.lock().unwrap() = Card::Lost;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    for id in ["vm-a", "vm-b"] {
        let creation = format!("c-{id}");
        let row = json!({"id": creation, "machine_id": id, "stage": "ready"});
        app.creations.lock().unwrap().push(row);
        app.machines.lock().unwrap().push(json!({"id": id, "title": id, "status": "running"}));
    }
    let many = world.json(&["setup", "cloud-machine"]);
    assert_eq!(many["state"], "needs_user", "{many}");
    assert_eq!(many["user_action"]["kind"], "many_machines", "{many}");
    assert_eq!((&many["machine"], &many["undo"]), (&Value::Null, &Value::Null), "{many}");
    let after = world.json(&["setup", "cloud-machine"]);
    assert_eq!((&after["state"], &after["inferred"]), (&json!("ok"), &Value::Null), "{after}");
    assert_eq!(app.create_keys().len(), 1);
    assert_eq!(app.machines.lock().unwrap().len(), 2);
}

/// A state from before setup kept the creations it saw counts every listed
/// creation as known: none of them is claimed or waited for, and the create
/// goes again with the kept key.
#[test]
fn cmux_setup_cloud_machine_reads_an_older_state_without_known_creations() {
    let mut world = World::new("cloudold");
    let app = FakeCloud::start(&mut world);
    let state = world.setup_state();
    std::fs::create_dir_all(&state).unwrap();
    let old = json!({"key": "mutation_old", "known": ["m0"]});
    std::fs::write(state.join("cloud-machine.json"), format!("{old}\n")).unwrap();
    app.machines.lock().unwrap().push(json!({"id": "m0", "title": "x", "status": "running"}));
    let row = json!({"id": "earlier", "machine_id": null, "stage": "creating"});
    app.creations.lock().unwrap().push(row);
    assert_eq!(world.cloud_check()["state"], "needs_setup");
    let made = world.json(&["setup", "cloud-machine"]);
    assert_eq!(made["state"], "changed", "{made}");
    assert_eq!(app.create_keys(), [json!("mutation_old")]);
}

/// A kept create, then one new machine while a new creation is still on
/// its way: setup waits; once that creation is a second machine, it claims
/// neither.
#[test]
fn cmux_setup_cloud_machine_waits_on_a_new_creation_before_claiming() {
    let mut world = World::new("cloudtwo");
    let app = FakeCloud::start(&mut world);
    *app.loaded.lock().unwrap() = Some(true);
    *app.card.lock().unwrap() = Card::Lost;
    assert_eq!(world.json(&["setup", "cloud-machine"])["user_action"]["kind"], "wait");
    app.machines.lock().unwrap().push(json!({"id": "vm-a", "title": "a", "status": "running"}));
    let row = json!({"id": "c-b", "machine_id": null, "stage": "creating"});
    app.creations.lock().unwrap().push(row);
    let waiting = world.json(&["setup", "cloud-machine"]);
    assert_eq!(waiting["user_action"]["kind"], "wait", "{waiting}");
    assert_eq!(waiting["machine"], Value::Null, "{waiting}");

    app.creations.lock().unwrap()[0]["machine_id"] = json!("vm-b");
    app.machines.lock().unwrap().push(json!({"id": "vm-b", "title": "b", "status": "running"}));
    let many = world.json(&["setup", "cloud-machine"]);
    assert_eq!(many["user_action"]["kind"], "many_machines", "{many}");
    assert_eq!(many["machine"], Value::Null, "{many}");
    assert_eq!(app.create_keys().len(), 1);
}
