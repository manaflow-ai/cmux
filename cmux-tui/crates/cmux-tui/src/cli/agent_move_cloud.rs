//! `cmux move SESSION --to cloud` and `cmux move SESSION --to here` for a chat tab the app shows:
//! the app's own Move to Cloud and Bring Back Local (actions `cloudMove` and `cloudBringBack`, the
//! ones behind the palette, the chat menu and `cmux cloud move|bring-back`). The app runs the move
//! (`CloudMove.swift`, `CloudBringBack.swift`: it opens the machine's Cloud link, copies the folder
//! with `cmux link seed push`, moves the chat with `cmux link agent move` over `agent-transfer-v1`,
//! and shows it where it landed). This file only picks the route and the machine, runs that one
//! action, and waits until the app shows the chat where it went. It is not a second move.
//!
//! The route, per session ([`route`]):
//!
//! - `--to cloud`: Move to Cloud onto the signed-in account's one Cloud machine. With several the
//!   move names them and asks for `--to NAME`; with none it names `cmux setup cloud-machine`.
//!   Never a new machine: the app's own pick would make one when the account has none.
//! - `--to NAME` (or `vm:ID`) that is one of those machines: Move to Cloud onto it.
//! - `--to here` (`local`) for a chat the app shows on a Cloud machine, with no `--from`: Bring Back
//!   Local.
//! - Everything else (`auto`, an ssh peer, `--from PEER --to here`): `acpmux session move`, as
//!   before ([`super::agent_move`]).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

/// How long the move may take before this command stops waiting for the app to show the chat
/// where it went (the app's move goes on; running the command again finds where it ended).
const ARRIVE_DEADLINE: Duration = Duration::from_secs(20 * 60);
/// The pause between two reads of where the app shows the chat.
const ARRIVE_PAUSE: Duration = Duration::from_secs(2);

/// One Cloud machine of the signed-in account, as `cloud list-machines` lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CloudMachine {
    pub id: String,
    pub title: String,
}

/// The app's chat tab of one session: its tab id, and the Cloud machine its workspace runs on
/// (none for a chat of this Mac or of an ssh machine).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ChatTab {
    pub tab: String,
    pub cloud_machine: Option<String>,
}

/// What the app answered, read once per command.
#[derive(Debug, Default)]
pub(super) struct Facts {
    /// The app's chat tabs by acpmux session id; none when no app answered.
    pub chats: Option<HashMap<String, ChatTab>>,
    /// `cloud list-machines`' `account.signed_in`; none when not read.
    pub signed_in: Option<bool>,
    /// Whether the app has loaded its Cloud machines (`loaded: false` lists none, which says nothing).
    pub loaded: bool,
    /// The account's Cloud machines; none when not read.
    pub machines: Option<Vec<CloudMachine>>,
}

/// Which move a session takes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// `acpmux session move`, unchanged.
    Acpmux,
    /// The app's Move to Cloud of `tab` onto `machine`.
    Cloud { session: String, tab: String, machine: CloudMachine },
    /// The app's Bring Back Local of `tab`, which runs on Cloud machine `machine`.
    BringBack { session: String, tab: String, machine: CloudMachine },
}

/// A move this command will not start, with its next step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Refusal {
    pub code: &'static str,
    pub message: String,
}

fn refuse(code: &'static str, message: impl Into<String>) -> Refusal {
    Refusal { code, message: message.into() }
}

/// The machine a `--to` names when it says it is a Cloud one (`vm:ID`, `machine:ID`, `cloud:NAME`).
fn cloud_word(target: &str) -> Option<&str> {
    ["vm:", "machine:", "cloud:"].iter().find_map(|prefix| target.strip_prefix(prefix))
}

/// Whether `target` (agent_move's `--to`, `here` already read as `local`) needs the app's facts.
pub(super) fn needs_facts(target: &str, from: Option<&str>) -> bool {
    !(target == "auto" || (target == "local" && from.is_some()))
}

/// The machine of `machines` that `name` names: its id or its title, exactly; else a unique
/// case-insensitive title.
fn machine_named<'a>(machines: &'a [CloudMachine], name: &str) -> Option<&'a CloudMachine> {
    if let Some(found) = machines.iter().find(|m| m.id == name || m.title == name) {
        return Some(found);
    }
    let mut close = machines.iter().filter(|m| m.title.eq_ignore_ascii_case(name));
    let first = close.next()?;
    close.next().is_none().then_some(first)
}

/// The app's chat tab of `session`: by its id, else by a unique id prefix.
fn chat_of<'a>(
    chats: &'a HashMap<String, ChatTab>,
    session: &str,
) -> Option<(&'a str, &'a ChatTab)> {
    if let Some((id, chat)) = chats.get_key_value(session) {
        return Some((id, chat));
    }
    if session.len() < 4 {
        return None;
    }
    let mut close = chats.iter().filter(|(id, _)| id.starts_with(session));
    let (id, chat) = close.next()?;
    close.next().is_none().then_some((id.as_str(), chat))
}

fn machine_list(machines: &[CloudMachine]) -> String {
    machines.iter().map(|m| format!("{} ({})", m.title, m.id)).collect::<Vec<_>>().join(", ")
}

/// The route of `session` to `target` (`from`: agent_move's `--from`).
pub(super) fn route(
    target: &str,
    from: Option<&str>,
    session: &str,
    facts: &Facts,
) -> Result<Route, Refusal> {
    if !needs_facts(target, from) {
        return Ok(Route::Acpmux);
    }
    let chat = facts.chats.as_ref().and_then(|chats| chat_of(chats, session));
    let machines = facts.machines.as_deref().unwrap_or_default();
    if target == "local" {
        // A chat of this Mac or of an ssh peer is acpmux's to move here.
        let Some((id, ChatTab { tab, cloud_machine: Some(on) })) = chat else {
            return Ok(Route::Acpmux);
        };
        let machine = machines
            .iter()
            .find(|m| &m.id == on)
            .cloned()
            .unwrap_or_else(|| CloudMachine { id: on.clone(), title: on.clone() });
        return Ok(Route::BringBack { session: id.to_owned(), tab: tab.clone(), machine });
    }
    let named = cloud_word(target);
    let cloud = target == "cloud";
    // A bare name is a Cloud machine only when the account has one by that name.
    let listed = if cloud { None } else { machine_named(machines, named.unwrap_or(target)) };
    if !cloud && named.is_none() && listed.is_none() {
        return Ok(Route::Acpmux);
    }
    if from.is_some() {
        return Err(refuse(
            "move.cloud_from",
            "`--to cloud` moves a chat this Mac's app shows; drop --from (Move to Another Machine \
             in the app's chat menu moves a Cloud chat on)",
        ));
    }
    let Some(chats) = &facts.chats else {
        return Err(refuse(
            "app.unreachable",
            "Move to Cloud runs in the cmux app, and no app answered: open cmux, then run this \
             command again",
        ));
    };
    if facts.signed_in == Some(false) {
        return Err(refuse(
            "cloud.signed_out",
            "cmux is signed out of Cloud: run `cmux login`, then this command again",
        ));
    }
    let Some((id, chat)) = chat_of(chats, session) else {
        return Err(refuse(
            "move.chat_not_shown",
            format!(
                "no chat tab in the app shows session {session}: open the chat in cmux (or name it \
                 by its session id, `cmux acp ls`), then run this command again"
            ),
        ));
    };
    if let Some(on) = &chat.cloud_machine {
        return Err(refuse(
            "move.already_cloud",
            format!(
                "{session} already runs on Cloud machine {on}: `cmux move {session} --to here` \
                 brings it back; Move to Another Machine in the chat menu moves it on"
            ),
        ));
    }
    let found = |machine: &CloudMachine| Route::Cloud {
        session: id.to_owned(),
        tab: chat.tab.clone(),
        machine: machine.clone(),
    };
    if let Some(machine) = listed {
        return Ok(found(machine));
    }
    if !cloud {
        return Err(refuse(
            "cloud.machine_unknown",
            format!(
                "no Cloud machine of this account is {}: {}",
                named.unwrap_or(target),
                if machines.is_empty() {
                    "it has none; `cmux setup cloud-machine` makes one".to_owned()
                } else {
                    format!("name one of {}", machine_list(machines))
                }
            ),
        ));
    }
    match machines {
        [] if !facts.loaded => Err(refuse(
            "cloud.list_unread",
            "the app has not loaded its Cloud machines yet: run this command again in a moment",
        )),
        [] => Err(refuse(
            "cloud.no_machine",
            "this account has no Cloud machine: `cmux setup cloud-machine` makes one (it costs \
             money every hour it runs), then run this command again",
        )),
        [only] => Ok(found(only)),
        several => Err(refuse(
            "cloud.machine_ambiguous",
            format!(
                "this account has {} Cloud machines, {}: name one with `--to NAME`",
                several.len(),
                machine_list(several)
            ),
        )),
    }
}

/// The app's chat tabs by session from its topology (`snapshot.get`): each `kind: conversation`
/// tab with its `agent_session`, and the Cloud machine of its workspace.
pub(super) fn chats_of(topology: &Value) -> HashMap<String, ChatTab> {
    fn visit(value: &Value, out: &mut Vec<(String, String)>) {
        match value {
            Value::Object(object) => {
                if object.get("kind").and_then(Value::as_str) == Some("conversation")
                    && let (Some(id), Some(session)) = (
                        object.get("id").and_then(Value::as_str),
                        object.get("agent_session").and_then(Value::as_str),
                    )
                {
                    out.push((session.to_owned(), id.to_owned()));
                }
                object.values().for_each(|child| visit(child, out));
            }
            Value::Array(values) => values.iter().for_each(|value| visit(value, out)),
            _ => {}
        }
    }
    let mut out = HashMap::new();
    for workspace in topology.get("workspaces").and_then(Value::as_array).into_iter().flatten() {
        let mut tabs = Vec::new();
        visit(workspace, &mut tabs);
        for (session, tab) in tabs {
            let machine = super::chat_send::machine_of(&session, topology)
                .filter(|machine| super::chat_send::is_cloud(machine, topology));
            out.insert(session, ChatTab { tab, cloud_machine: machine });
        }
    }
    out
}

/// The machines and sign-in of a `cloud list-machines` answer.
pub(super) fn read_list(listed: &Value, facts: &mut Facts) {
    facts.signed_in = listed.pointer("/account/signed_in").and_then(Value::as_bool);
    facts.loaded = listed.get("loaded").and_then(Value::as_bool) != Some(false);
    let rows = listed.get("machines").and_then(Value::as_array).into_iter().flatten();
    let machines = rows
        .filter_map(|row| {
            let id = row.get("machine_id").or_else(|| row.get("id")).and_then(Value::as_str)?;
            let title = row.get("title").and_then(Value::as_str).unwrap_or(id);
            Some(CloudMachine { id: id.to_owned(), title: title.to_owned() })
        })
        .collect();
    facts.machines = Some(machines);
}

/// Reads what the routes of `target` need from the app.
fn facts(global: &GlobalArgs, target: &str, from: Option<&str>) -> Facts {
    let mut facts = Facts::default();
    if !needs_facts(target, from) {
        return facts;
    }
    let Ok(topology) = super::chat_send::topology(global) else { return facts };
    facts.chats = Some(chats_of(&topology));
    // `--to here` needs only the chat's machine (its title is a nicety the list may add).
    if let Ok(listed) = super::cloud_start_chat::app_machines(global) {
        read_list(&listed, &mut facts);
    }
    facts
}

/// The `cmux` words of an app route's action.
pub(super) fn action_words(route: &Route) -> Vec<String> {
    match route {
        Route::Acpmux => Vec::new(),
        Route::Cloud { tab, machine, .. } => vec![
            "cloud".into(),
            "move".into(),
            "--target".into(),
            format!("tab:{tab}"),
            "--machine".into(),
            format!("machine:{}", machine.id),
        ],
        Route::BringBack { tab, .. } => {
            vec!["cloud".into(), "bring-back".into(), "--target".into(), format!("tab:{tab}")]
        }
    }
}

/// One route as `--dry-run` and the answer say it.
pub(super) fn describe(route: &Route) -> Value {
    let command = format!("cmux {}", action_words(route).join(" "));
    match route {
        Route::Acpmux => json!({"path": "acpmux"}),
        Route::Cloud { session, tab, machine } => json!({
            "session_id": session, "path": "cloud_move", "tab_id": tab,
            "machine_id": machine.id, "machine": machine.title, "command": command,
        }),
        Route::BringBack { session, tab, machine } => json!({
            "session_id": session, "path": "bring_back", "tab_id": tab,
            "machine_id": machine.id, "machine": machine.title, "command": command,
        }),
    }
}

/// The human line of one described route.
pub(super) fn human_line(described: &Value, dry_run: bool) -> String {
    let text = |key: &str| described.get(key).and_then(Value::as_str).unwrap_or_default();
    let (session, machine, id) = (text("session_id"), text("machine"), text("machine_id"));
    let verb = match (text("path"), dry_run) {
        ("cloud_move", true) => format!("would move to Cloud machine {machine} ({id})"),
        ("cloud_move", false) => format!("moved to Cloud machine {machine} ({id})"),
        ("bring_back", true) => format!("would come back here from Cloud machine {machine} ({id})"),
        (_, _) => format!("came back here from Cloud machine {machine} ({id})"),
    };
    let how = if dry_run {
        format!(
            ": the app's {} (`{}`)",
            if text("path") == "cloud_move" { "Move to Cloud" } else { "Bring Back Local" },
            text("command")
        )
    } else {
        String::new()
    };
    format!("{session}: {verb}{how}")
}

/// Options of acpmux's move that the app's move does not take, with why.
fn app_refuses_option(option: &str) -> Option<&'static str> {
    match option {
        "--after-turn" => Some(
            "the app's move stops a running turn and continues it where the chat lands; drop \
             --after-turn",
        ),
        "--leave-dirty" => {
            Some("the app's move takes the folder's uncommitted changes along; drop --leave-dirty")
        }
        "--cwd" => Some(
            "the app's move runs the chat in the copy of its own folder; drop --cwd (`cmux cloud \
             move --path DIR` copies another folder)",
        ),
        _ => None,
    }
}

/// What agent_move asks of this file.
pub(super) struct Ask<'a> {
    pub sessions: &'a [String],
    pub target: &'a str,
    pub from: Option<&'a str>,
    pub all_idle: bool,
    /// acpmux's options as agent_move read them.
    pub options: &'a [String],
    pub dry_run: bool,
    pub timings: bool,
}

/// Runs the app's move when any session's route is one; `None` when every route is acpmux's.
pub(super) fn run_if_routed(global: &GlobalArgs, ask: &Ask<'_>) -> Option<i32> {
    let began = Instant::now();
    if ask.all_idle {
        // Every idle session is acpmux's selection; Cloud takes chats by name.
        if ask.target == "cloud" || cloud_word(ask.target).is_some() {
            return Some(fail(
                global,
                &refuse(
                    "move.cloud_all_idle",
                    "`--to cloud` moves named chats: name each SESSION (`cmux acp ls`)",
                ),
            ));
        }
        return None;
    }
    let facts = facts(global, ask.target, ask.from);
    let mut routes = Vec::new();
    for session in ask.sessions {
        match route(ask.target, ask.from, session, &facts) {
            Ok(route) => routes.push(route),
            Err(refusal) => return Some(fail(global, &refusal)),
        }
    }
    let app = routes.iter().filter(|route| **route != Route::Acpmux).count();
    if app == 0 {
        return None;
    }
    if app != routes.len() {
        return Some(fail(
            global,
            &refuse(
                "move.mixed_routes",
                "some of these chats move through the app (Cloud) and some through acpmux: move \
                 them in two commands",
            ),
        ));
    }
    let option = ask.options.iter().find_map(|option| app_refuses_option(option));
    if let Some(why) = option {
        return Some(fail(global, &refuse("move.option_unsupported", why)));
    }
    let routed_ms = began.elapsed().as_millis() as u64;
    let described: Vec<Value> = routes.iter().map(describe).collect();
    if ask.dry_run {
        let mut answer = json!({"dry_run": true, "moves": described});
        if ask.timings {
            answer.set("timings", json!({"route_ms": routed_ms}));
        }
        return Some(print(global, &answer, true));
    }
    let mut moved = Vec::new();
    for (index, (route, mut described)) in routes.iter().zip(described).enumerate() {
        let key = match route_key(global, routes.len(), index) {
            Ok(key) => key,
            Err(error) => return Some(super::wire::print_local_error(&error, global.output, 1)),
        };
        let mut route_global = global.clone();
        route_global.idempotency_key = Some(key);
        let started = Instant::now();
        let ran = super::cloud_start_chat::app_step(&route_global, &action_words(route));
        let app_ms = started.elapsed().as_millis() as u64;
        if let Err(error) = &ran {
            if has_not_run(error) || !still_running(error) {
                return Some(super::wire::print_local_error(error, global.output, 1));
            }
        }
        match arrive(&route_global, route) {
            Ok(()) => {}
            Err(ArriveFailure::App(error)) => {
                return Some(super::wire::print_local_error(&error, global.output, 1));
            }
            Err(ArriveFailure::Refusal(refusal)) => return Some(fail(global, &refusal)),
        }
        if ask.timings {
            let total = started.elapsed().as_millis() as u64;
            described.set("timings", json!({"app_ms": app_ms, "arrived_ms": total}));
        }
        moved.push(described);
    }
    let mut answer = json!({"moves": moved});
    if ask.timings {
        answer.set(
            "timings",
            json!({"route_ms": routed_ms,
                                     "total_ms": began.elapsed().as_millis() as u64}),
        );
    }
    Some(print(global, &answer, false))
}

/// Whether the app's answer is a move that goes on past the run's wait (the app bounds a waited
/// run at 40 s; a move takes longer), not a refusal.
fn still_running(error: &Value) -> bool {
    if has_not_run(error) {
        return false;
    }
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    code.contains("timeout") || code.contains("outcome_unknown") || code.contains("deadline")
}

fn has_not_run(error: &Value) -> bool {
    error.pointer("/data/not_run") == Some(&Value::Bool(true))
}

/// A key scoped to one route. A caller key is retained for one move and suffixed when several
/// routes share it so their action fingerprints cannot conflict.
fn route_key(global: &GlobalArgs, route_count: usize, index: usize) -> Result<String, Value> {
    if let Some(key) = &global.idempotency_key {
        return Ok(if route_count == 1 { key.clone() } else { format!("{key}-route-{index}") });
    }
    super::wire::random_idempotency_key()
        .map_err(|error| json!({"code": "app.transport", "message": error.to_string()}))
}

enum ArriveFailure {
    Refusal(Refusal),
    App(Value),
}

fn unknown_join_only(error: &Value) -> bool {
    error.get("code").and_then(Value::as_str) == Some("invalid_params")
        && error
            .get("message")
            .and_then(Value::as_str)
            .is_some_and(|message| message.contains("join_only") || message.contains("join-only"))
}

fn join_keeps_waiting(error: &Value) -> bool {
    still_running(error)
        || error.get("code").and_then(Value::as_str) == Some("idempotency_unknown")
        || unknown_join_only(error)
}

/// Waits until the app shows the chat where its route takes it.
fn arrive(global: &GlobalArgs, route: &Route) -> Result<(), ArriveFailure> {
    let (session, want) = match route {
        Route::Acpmux => return Ok(()),
        Route::Cloud { session, machine, .. } => (session, Some(machine.id.as_str())),
        Route::BringBack { session, .. } => (session, None),
    };
    let deadline = Instant::now() + ARRIVE_DEADLINE;
    loop {
        if let Ok(topology) = super::chat_send::topology(global)
            && let Some(chat) = chats_of(&topology).get(session)
            && chat.cloud_machine.as_deref() == want
        {
            return Ok(());
        }
        match super::cloud_start_chat::app_step_with_options(global, &action_words(route), true) {
            Ok(_) => {}
            Err(error) if join_keeps_waiting(&error) => {}
            Err(error) => return Err(ArriveFailure::App(error)),
        }
        if Instant::now() >= deadline {
            return Err(ArriveFailure::Refusal(refuse(
                "move.not_arrived",
                format!(
                    "the app did not show {session} where it went within {} minutes; its move may \
                     still run or have stopped with a toast: look at the chat, then run this \
                     command again",
                    ARRIVE_DEADLINE.as_secs() / 60
                ),
            )));
        }
        std::thread::sleep(ARRIVE_PAUSE);
    }
}

fn print(global: &GlobalArgs, answer: &Value, dry_run: bool) -> i32 {
    match global.output {
        OutputMode::Human => {
            for described in answer.get("moves").and_then(Value::as_array).into_iter().flatten() {
                println!("{}", human_line(described, dry_run));
            }
            if let Some(timings) = answer.get("timings") {
                println!("timings: {timings}");
            }
            0
        }
        _ => super::wire::print_local_success(answer, global.output),
    }
}

fn fail(global: &GlobalArgs, refusal: &Refusal) -> i32 {
    let error = json!({"code": refusal.code, "message": refusal.message, "details": {},
                       "retryable": false});
    super::wire::print_local_error(&error, global.output, 1)
}

#[cfg(test)]
#[path = "agent_move_cloud_tests.rs"]
mod tests;
