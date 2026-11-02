//! `cmux setup cloud-machine [--dry-run] [--forget]`: makes sure the person
//! has a cmux Cloud machine for agents, and creates one with their OK.
//!
//! Everything goes through the app: `auth.status` (signed in, and whether
//! Cloud can run in this build), `cloud.machines` (the machines it shows and
//! the creations in flight), and `action.run newCloudMachine`, which from an
//! agent always asks the person first on a card in cmux. The app answers the
//! created machine, or `pending` with a `creation_id` after 30 s (that wait
//! includes the person's answer), or `unavailable` when they declined or
//! there was no window to ask in. A created machine costs money while it
//! runs and does not pause by itself, so the undo kills it.
//!
//! Setup keeps what it asked for in its own state file ([`state`]): the
//! run's idempotency key and the machines and creations cmux showed, written
//! before the create is sent, then the creation or the machine it became.
//! One run at a time decides, under a lock. A rerun reads `cloud.machines`
//! first: the one new machine, or a creation that names its machine, is
//! setup's; a new creation still on its way is waited for; only when nothing
//! new appeared does it send the create again with the same key (the app's
//! answer to a key lives in memory, so a restarted cmux would show a second
//! card and make a second machine). Any machine cmux already shows is
//! enough, and setup leaves it alone. A list cmux could not read, has not
//! loaded, or shows empty while setup has a machine or a request on file,
//! decides nothing. Plan limits are not read beforehand: the app has no read
//! of them on its socket, so a plan that allows no more machines comes back
//! as the create's refusal, with the app's text.

use cmux_json::JsonSet as _;

mod state;

use serde_json::{Value, json};

use self::state::Saved;
use super::super::GlobalArgs;
use super::{Outcome, Refusal};

const TASK: &str = "cloud_machine";

/// The command that runs (and reruns) this task.
const RERUN: &str = "cmux setup cloud-machine";

/// The command that drops what setup keeps, so it asks for a new machine.
const FORGET: &str = "cmux setup cloud-machine --forget";

/// The action that creates a machine; from an agent it asks the person.
const CREATE: &str = "newCloudMachine";

/// What a machine costs, said before it is made.
const COST: &str = "A cmux Cloud machine costs money for every hour it runs, at the rate of the \
                    person's plan, and it does not pause by itself";

/// The app's reason when the person declined the card or dismissed it
/// (`CloudStrings.createDeclined`); any other refusal is the app's to say.
const DECLINED_REASON: &str =
    "No Cloud machine was created: the person declined or dismissed it in cmux.";

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> Result<Outcome, Refusal> {
    let (dry_run, forget_only) = parse(args)?;
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": dry_run,
        "before": Value::Null,
        "after": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
        "machine": Value::Null,
    });
    if forget_only {
        return forget(report, dry_run);
    }
    if !applies(global) {
        report.set("state", json!("not_applicable"));
        return Ok(Outcome { report, failed: false });
    }
    if let Err(action) = signed_in(global) {
        return needs_user(report, action);
    }
    // One run at a time reads the list, decides and creates; a dry run
    // writes nothing, not even the lock.
    let _lock = if dry_run { None } else { Some(Saved::lock()?) };
    let listing = match read(global, "cloud.machines") {
        Ok(listing) => listing,
        Err(action) => return needs_user(report, action),
    };
    let saved = Saved::load();
    let look = look(&listing, &saved);
    if let Some(id) = &look.gone {
        // Killed, or gone from cmux: setup no longer has a machine.
        report.set("before", json!({"id": id, "status": "gone"}));
        if !dry_run {
            Saved::default().save()?;
        }
    }
    match look.step {
        Step::Wait(action) => needs_user(report, action),
        Step::Ended(action) => {
            if !dry_run {
                Saved::default().save()?;
            }
            needs_user(report, action)
        }
        Step::Machine { row, made, inferred } => {
            let id = row["id"].as_str().unwrap_or_default().to_owned();
            report.set("after", row.clone());
            report.set("machine", row.clone());
            if let Some(note) = paused_note(&row) {
                report.set("note", json!(note));
            }
            let ours = (made && !inferred) || saved.machine_id.as_deref() == Some(id.as_str());
            let action = machine_step(&row, ours);
            report.set(
                "state",
                json!(match (&action, made, dry_run) {
                    (Some(_), _, _) => "needs_user",
                    (None, true, true) => "planned",
                    (None, true, false) => "changed",
                    (None, false, _) => "ok",
                }),
            );
            report.set("user_action", action.unwrap_or(Value::Null));
            if inferred {
                report.set("inferred", json!(true));
            }
            if made {
                report.set("undo", json!(undo(&id)));
                if inferred {
                    report.set("undo_note", json!(inferred_note(&id)));
                }
                if !dry_run {
                    keep(&mut report, &Saved { machine_id: Some(id), ..Saved::default() });
                }
            }
            Ok(Outcome { report, failed: false })
        }
        Step::Ask { key, .. } if dry_run => {
            report.set("state", json!("planned"));
            report.set("undo", json!(undo("MACHINE_ID")));
            report.set("cost", json!(COST));
            if key.is_some() {
                report.set(
                    "note",
                    json!(
                        "A create setup sent earlier has no answer and cmux shows nothing new; the \
                     run sends that same create again"
                    ),
                );
            }
            Ok(Outcome { report, failed: false })
        }
        Step::Ask { key, known, known_creations } => {
            create(global, report, key, known, known_creations)
        }
    }
}

/// The check `cmux setup status` reports, by the same rules as the run: a
/// machine cmux shows (setup's own or another) is `ok`; a creation on its
/// way, or a list cmux has not loaded, is `needs_user` (`wait`); no machine
/// is `needs_setup`. It writes nothing.
pub(super) fn status(global: &GlobalArgs) -> Value {
    if !applies(global) {
        return json!({"task": TASK, "state": "not_applicable"});
    }
    let listing = match signed_in(global).and_then(|()| read(global, "cloud.machines")) {
        Ok(listing) => listing,
        Err(action) => {
            return json!({"task": TASK, "state": "needs_user", "user_action": action,
                          "fix": RERUN});
        }
    };
    let saved = Saved::load();
    match look(&listing, &saved).step {
        Step::Wait(action) | Step::Ended(action) => {
            json!({"task": TASK, "state": "needs_user", "user_action": action, "fix": RERUN})
        }
        Step::Machine { row, made, inferred } => {
            let id = row["id"].as_str().unwrap_or_default();
            let ours = (made && !inferred) || saved.machine_id.as_deref() == Some(id);
            let action = machine_step(&row, ours);
            let (state, fix) = match action {
                Some(_) => ("needs_user", Some(RERUN)),
                None => ("ok", None),
            };
            json!({"task": TASK, "state": state, "machine": row, "user_action": action,
                   "fix": fix, "note": paused_note(&row), "inferred": inferred.then_some(true)})
        }
        // The run sends the create (again, with its key): there is no machine yet.
        Step::Ask { key, .. } => json!({"task": TASK, "state": "needs_setup", "fix": RERUN,
            "note": key.map(|_| "A create setup sent earlier has no answer and cmux shows \
                nothing new; the run sends that same create again")}),
    }
}

/// `--forget`: drops what setup keeps (after its machine was killed, or
/// once the person says no machine is on its way), so the next run asks
/// for a new machine. It changes nothing in cmux.
fn forget(mut report: Value, dry_run: bool) -> Result<Outcome, Refusal> {
    let _lock = if dry_run { None } else { Some(Saved::lock()?) };
    let saved = Saved::load();
    if saved.is_empty() {
        report.set("state", json!("ok"));
        return Ok(Outcome { report, failed: false });
    }
    report.set("before", saved.to_json());
    if dry_run {
        report.set("state", json!("planned"));
    } else {
        Saved::default().save()?;
        report.set("state", json!("changed"));
    }
    Ok(Outcome { report, failed: false })
}

/// What the run does next, read from cmux's list and setup's state alone.
struct Look {
    step: Step,
    /// The machine setup kept, when cmux no longer shows it.
    gone: Option<String>,
}

enum Step {
    /// Nothing to decide yet (the list is not loaded, a creation is on its
    /// way); nothing is changed or asked.
    Wait(Value),
    /// Setup's request ended without a machine: what to tell the person.
    Ended(Value),
    /// A machine cmux shows; `made` when it is the one setup asked for and
    /// has not claimed yet, `inferred` when cmux never named it as that
    /// one (setup's own creation never named it: it is the one machine
    /// that appeared since setup asked).
    Machine { row: Value, made: bool, inferred: bool },
    /// No machine and nothing new: ask for one, with the key of a create
    /// whose answer setup never read (sent again), or a new one.
    Ask { key: Option<String>, known: Vec<String>, known_creations: Option<Vec<String>> },
}

impl Step {
    fn wait(text: &str) -> Self {
        Self::Wait(action("wait", text, Some(RERUN)))
    }
}

fn look(listing: &Value, saved: &Saved) -> Look {
    let only = |step| Look { step, gone: None };
    if let Some(error) = listing["last_error"].as_str() {
        return only(Step::wait(&format!(
            "cmux could not read the Cloud machines ({error}); run `cmux setup cloud-machine` \
             again once cmux shows them"
        )));
    }
    if listing["loaded"] == false {
        return only(Step::wait(
            "cmux has not loaded the Cloud machines yet; run `cmux setup cloud-machine` again \
             in a few seconds",
        ));
    }
    if let Some(creation) = &saved.creation_id
        && creations(listing).any(|row| row["id"] == creation.as_str())
    {
        return only(settle(creation, &saved.known, listing));
    }
    if !saved.is_empty() && live_machines(listing).next().is_none() && listing["loaded"] != true {
        // Before its first refresh cmux lists nothing: an empty list says
        // nothing about what setup made or asked for.
        return only(Step::Wait(action(
            "wait",
            &format!(
                "cmux shows no Cloud machine, maybe because it has not loaded them yet; run \
                 `cmux setup cloud-machine` again in a few seconds. If cmux still shows none and \
                 none is on its way, ask the person, then `{FORGET}` lets setup ask for a new one"
            ),
            Some(RERUN),
        )));
    }
    if let Some(creation) = &saved.creation_id {
        return only(settle(creation, &saved.known, listing));
    }
    let mut gone = None;
    if let Some(id) = &saved.machine_id {
        if let Some(row) = machine(listing, id) {
            return only(Step::Machine { row: view(row), made: false, inferred: false });
        }
        gone = Some(id.clone());
    }
    let step = if saved.key.is_some() {
        follow(listing, saved)
    } else if let Some(row) = live_machines(listing).next() {
        // The person's own machine: there is one, and setup leaves it.
        Step::Machine { row: view(row), made: false, inferred: false }
    } else if creations(listing).any(|row| row["stage"] != "failed") {
        // A machine on its way that setup did not ask for (a click in cmux).
        Step::wait(
            "A Cloud machine is on its way in cmux; run `cmux setup cloud-machine` again once \
             it is up, so setup makes no second one",
        )
    } else {
        Step::Ask {
            key: None,
            known: machine_ids(listing),
            known_creations: Some(creation_ids(listing)),
        }
    };
    Look { step, gone }
}

/// A create setup sent and never read the answer to: what cmux shows that
/// was not there when setup asked decides. One new machine (a new
/// creation's, or a new row) is setup's, as inferred: no creation setup
/// recorded names it, so it may be one the person made. More than one is
/// for the person; a new creation on its way is waited for; only when
/// nothing new appeared is the create sent again with its key. A state
/// from before `known_creations` was kept counts every creation as known.
fn follow(listing: &Value, saved: &Saved) -> Step {
    let is_new = |id: &str| {
        saved.known_creations.as_ref().is_some_and(|known| !known.iter().any(|seen| seen == id))
    };
    let new_creations =
        creations(listing).filter(|row| row["id"].as_str().is_some_and(is_new)).collect::<Vec<_>>();
    let mut candidates = new_creations
        .iter()
        .filter_map(|row| row["machine_id"].as_str().map(str::to_owned))
        .chain(new_machines(listing, &saved.known))
        .collect::<Vec<_>>();
    candidates.sort();
    candidates.dedup();
    if candidates.len() > 1 {
        return Step::Ended(many_machines(&candidates));
    }
    if new_creations.iter().any(|row| row["machine_id"].is_null() && row["stage"] != "failed") {
        return Step::Wait(wait_step());
    }
    match (candidates.first(), new_creations.first()) {
        (Some(id), _) => {
            Step::Machine { row: machine_row(listing, id), made: true, inferred: true }
        }
        (None, Some(row)) => Step::Ended(failed_creation(row)),
        (None, None) => Step::Ask {
            key: saved.key.clone(),
            known: saved.known.clone(),
            known_creations: saved.known_creations.clone(),
        },
    }
}

/// Sends the create, with `key` when setup sent it before and never read
/// its answer. The key is kept before the create goes out, and kept after
/// it unless the app says nothing ran or the person declined.
fn create(
    global: &GlobalArgs,
    mut report: Value,
    key: Option<String>,
    known: Vec<String>,
    known_creations: Option<Vec<String>>,
) -> Result<Outcome, Refusal> {
    let key = match key {
        Some(key) => {
            eprintln!("cmux: setup cloud-machine: sending the create it never had an answer to");
            key
        }
        None => {
            let key = super::super::command::random_prefixed("mutation")
                .map_err(|error| Refusal::Failed(format!("cmux: setup cloud-machine: {error}")))?;
            let saved = Saved {
                key: Some(key.clone()),
                known: known.clone(),
                known_creations: known_creations.clone(),
                ..Saved::default()
            };
            saved.save()?;
            key
        }
    };
    eprintln!("cmux: setup cloud-machine: waiting for the person to allow a new Cloud machine");
    report.set("cost", json!(COST));
    let params = Value::Object(super::super::app::action_run_params(
        CREATE,
        super::super::app::ActionName::Any,
        super::super::app::action_origin(),
    ));
    let answer = super::super::mcp::agent_app(
        global,
        "action.run",
        params,
        super::super::app::WAITING_RUN_TIMEOUT,
        Some(&key),
    );
    let result = match answer {
        Ok(run) => run["result"].clone(),
        Err(error) => {
            let code = error["code"].as_str().unwrap_or_default();
            let declined = code == "unavailable" && error["data"]["reason"] == DECLINED_REASON;
            // Nothing ran: the app says so, or the request never left.
            let not_run = code == "busy"
                || error["data"]["not_run"] == true
                || error["details"]["state"] == "not_run";
            if declined || not_run {
                Saved::default().save()?;
            }
            let action =
                if declined {
                    declined_step()
                } else if matches!(code, "app.transport" | "timeout") {
                    // The create may have gone through: the rerun reads the list.
                    wait_step()
                } else if not_run {
                    app_problem(&error)
                } else {
                    let mut action = app_problem(&error);
                    action.set("text", json!(format!(
                    "{}. Setup keeps the request, so a rerun makes no second machine; once the \
                     cause is fixed (a plan with room, say), `{FORGET}` lets setup ask again",
                    action["text"].as_str().unwrap_or_default()
                )));
                    action
                };
            return needs_user(report, action);
        }
    };
    if let Some(id) = result["machine_id"].as_str() {
        let row = view(&result);
        report.set("after", row.clone());
        report.set("machine", row);
        report.set("undo", json!(undo(id)));
        report.set("state", json!("changed"));
        keep(&mut report, &Saved { machine_id: Some(id.to_owned()), ..Saved::default() });
        return Ok(Outcome { report, failed: false });
    }
    // Pending, or an app that answers no machine: the key stays, and with a
    // creation id the rerun follows that creation.
    if let Some(creation) = result["creation_id"].as_str().filter(|id| !id.is_empty()) {
        report.set("after", json!({"creation_id": creation}));
        let saved = Saved {
            creation_id: Some(creation.to_owned()),
            key: Some(key),
            known,
            known_creations,
            ..Saved::default()
        };
        keep(&mut report, &saved);
    }
    needs_user(report, wait_step())
}

/// Saves `saved` after a change already happened: a failure is a `warning`
/// on the result, never a lost `changed`.
fn keep(report: &mut Value, saved: &Saved) {
    if let Err(Refusal::Failed(message) | Refusal::Usage(message)) = saved.save() {
        report["warning"] = json!(format!(
            "{message}; a rerun of `cmux setup cloud-machine` still finds the machine in cmux"
        ));
    }
}

/// The result when the person must do `action` first.
fn needs_user(mut report: Value, action: Value) -> Result<Outcome, Refusal> {
    report.set("state", json!("needs_user"));
    report.set("user_action", action);
    Ok(Outcome { report, failed: false })
}

/// `(--dry-run, --forget)`.
fn parse(args: &[String]) -> Result<(bool, bool), Refusal> {
    let (mut dry_run, mut forget) = (false, false);
    for arg in args {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--forget" => forget = true,
            other => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup cloud-machine: unexpected argument {other:?}"
                )));
            }
        }
    }
    Ok((dry_run, forget))
}

/// Whether there is a cmux app to ask: macOS, or an app socket named by
/// `--app-socket` or `CMUX_SOCKET_PATH`.
fn applies(global: &GlobalArgs) -> bool {
    cfg!(target_os = "macos")
        || global.app_socket.is_some()
        || std::env::var_os("CMUX_SOCKET_PATH").is_some_and(|path| !path.is_empty())
}

/// One app read, or what the person must do because the app did not answer.
fn read(global: &GlobalArgs, method: &str) -> Result<Value, Value> {
    super::super::mcp::agent_app(global, method, json!({}), super::super::app::READ_TIMEOUT, None)
        .map_err(|error| app_problem(&error))
}

/// Ok when the person is signed in to cmux and Cloud can run in this build.
fn signed_in(global: &GlobalArgs) -> Result<(), Value> {
    let auth = read(global, "auth.status")?;
    if let Some(reason) = auth["cloud_unavailable"].as_str() {
        return Err(action("app", &format!("cmux Cloud cannot run here: {reason}"), None));
    }
    if auth["signed_in"] == true {
        return Ok(());
    }
    if auth["restoring"] == true {
        return Err(action(
            "wait",
            "cmux is restoring the person's sign-in; run `cmux setup cloud-machine` again in a \
             few seconds",
            Some(RERUN),
        ));
    }
    Err(action(
        "sign_in",
        "Sign in to cmux: the command opens the sign-in in the browser, where the person \
         finishes it; then run `cmux setup cloud-machine` again",
        Some("cmux cloud sign-in"),
    ))
}

fn declined_step() -> Value {
    action(
        "declined",
        "No Cloud machine was made: the person declined, or cmux had no window to ask in; ask \
         the person before running `cmux setup cloud-machine` again",
        None,
    )
}

/// Follows creation `id`, which the app answered for setup's create. Its
/// row names its machine once there is one; it leaves the list when the
/// person declined it, or once its machine's workspace shows, and then the
/// one machine that was not there before (`known`) is its machine.
fn settle(id: &str, known: &[String], listing: &Value) -> Step {
    if let Some(row) = creations(listing).find(|row| row["id"] == id) {
        if let Some(machine) = row["machine_id"].as_str() {
            return Step::Machine {
                row: machine_row(listing, machine),
                made: true,
                inferred: false,
            };
        }
        if row["stage"] == "failed" {
            return Step::Ended(failed_creation(row));
        }
        return Step::Wait(wait_step());
    }
    match new_machines(listing, known).as_slice() {
        [only] => Step::Machine { row: machine_row(listing, only), made: true, inferred: true },
        [] => Step::Ended(declined_step()),
        many => Step::Ended(many_machines(many)),
    }
}

fn failed_creation(row: &Value) -> Value {
    let detail = row["stage_detail"].as_str().unwrap_or("no reason given");
    action(
        "app",
        &format!("cmux could not make the Cloud machine ({detail}); cmux shows the reason"),
        None,
    )
}

fn many_machines(ids: &[String]) -> Value {
    action(
        "many_machines",
        &format!(
            "More than one Cloud machine appeared ({}); setup cannot tell which is its own and \
             leaves them to the person",
            ids.join(", ")
        ),
        None,
    )
}

fn creations(listing: &Value) -> impl Iterator<Item = &Value> {
    listing["creations"].as_array().map(Vec::as_slice).unwrap_or_default().iter()
}

fn creation_ids(listing: &Value) -> Vec<String> {
    creations(listing).filter_map(|row| row["id"].as_str()).map(str::to_owned).collect()
}

/// The ids of the machines cmux shows that are not destroyed.
fn machine_ids(listing: &Value) -> Vec<String> {
    live_machines(listing).filter_map(|row| row["id"].as_str()).map(str::to_owned).collect()
}

/// The machines cmux shows that are not in `known`.
fn new_machines(listing: &Value, known: &[String]) -> Vec<String> {
    machine_ids(listing).into_iter().filter(|id| !known.contains(id)).collect()
}

fn live_machines(listing: &Value) -> impl Iterator<Item = &Value> {
    listing["machines"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter(|row| row["status"] != "destroyed")
}

/// Machine `id` in `listing`, unless it is gone or destroyed.
fn machine<'a>(listing: &'a Value, id: &str) -> Option<&'a Value> {
    live_machines(listing).find(|row| row["id"] == id)
}

/// Machine `id` as setup reports it, also before cmux lists it.
fn machine_row(listing: &Value, id: &str) -> Value {
    machine(listing, id).map(view).unwrap_or_else(|| {
        json!({"id": id, "title": null, "status": "provisioning",
               "target": format!("machine:{id}")})
    })
}

/// A machine as setup reports it, from a `cloud.machines` row (`id`) or a
/// create's answer (`machine_id`): `{id, title, status, target}`.
fn view(row: &Value) -> Value {
    let id = row["id"].as_str().or_else(|| row["machine_id"].as_str()).unwrap_or_default();
    json!({"id": id, "title": row["title"], "status": row["status"],
           "target": format!("machine:{id}")})
}

/// What the person must know about a machine that failed, or None.
/// `ours` when setup made it (cmux named it for setup's creation, or setup
/// kept it); any other machine is the person's to remove.
fn machine_step(row: &Value, ours: bool) -> Option<Value> {
    let id = row["id"].as_str().unwrap_or_default();
    (row["status"] == "failed").then(|| {
        let text = if ours {
            format!(
                "The Cloud machine {id} failed; cmux shows why. `{}` removes it, and `cmux setup \
                 cloud-machine` then makes a new one",
                undo(id)
            )
        } else {
            format!(
                "The Cloud machine {id} failed; cmux shows why. It is the person's machine, not \
                 one setup made (or setup only inferred it is): ask them before removing it with \
                 `{}`",
                undo(id)
            )
        };
        action("app", &text, None)
    })
}

/// Why the undo of a machine setup only inferred is the person's call.
fn inferred_note(id: &str) -> String {
    format!(
        "cmux never named {id} as the machine setup asked for: it is the one machine that \
         appeared since setup asked. Check with the person that it is not one they made before \
         running the undo"
    )
}

/// How to wake a paused machine; it is still the person's machine.
fn paused_note(row: &Value) -> Option<String> {
    let id = row["id"].as_str().unwrap_or_default();
    (row["status"] == "paused").then(|| {
        format!(
            "The machine is paused: `cmux cloud resume-machine --target machine:{id}` resumes it"
        )
    })
}

/// Kills machine `id`, then drops setup's record of it.
fn undo(id: &str) -> String {
    format!("cmux cloud kill-machine --target machine:{id} --confirm && {FORGET}")
}

/// The creation is on its way, or the person has not answered yet.
fn wait_step() -> Value {
    action(
        "wait",
        "The Cloud machine is on its way (or the person has not answered cmux yet); run `cmux \
         setup cloud-machine` again in a minute: it makes no second machine",
        Some(RERUN),
    )
}

fn action(kind: &str, text: &str, command: Option<&str>) -> Value {
    json!({"kind": kind, "text": text, "command": command, "url": Value::Null})
}

/// What the person does when the app refused or did not answer.
fn app_problem(error: &Value) -> Value {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    let text = match code {
        "app.not_found" | "app.unreachable" => {
            "Open cmux: Cloud machines are made in the cmux app, which is not running; then run \
             `cmux setup cloud-machine` again"
                .to_owned()
        }
        "app.transport" | "timeout" => {
            "cmux did not answer; run `cmux setup cloud-machine` again".to_owned()
        }
        "busy" => "cmux was busy and made nothing; run `cmux setup cloud-machine` again".to_owned(),
        _ => format!("cmux refused ({code}): {message}"),
    };
    action("app", &text, None)
}
