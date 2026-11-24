use std::collections::VecDeque;

use cmux_cloud_start_core::hybrid::{self, Cloud, Event, Home, Off};
use serde_json::{Value, json};

use super::super::super::GlobalArgs;
use super::super::super::cloud_start_chat::Machine;
use super::super::{Parsed, cloud_words, here_words, parse};
use super::{
    Drive, account, cached_plan, drive, drive_args, drive_words, here_of, move_words, pause_words,
    plan_of, takes, tool_event,
};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn start(list: &[&str]) -> super::Start {
    match parse(&words(list), None).unwrap() {
        Parsed::Run(start) => start,
        Parsed::Help => panic!("help"),
    }
}

#[test]
fn a_plain_cloud_start_is_the_hybrid_ones_and_every_cloud_only_option_is_not() {
    let plain = start(&["--on", "vm:new", "--prompt", "hi"]);
    assert_eq!(takes(&plain, &Machine::New).as_deref(), Some("new"));
    assert_eq!(takes(&plain, &Machine::Target("m1".into())).as_deref(), Some("m1"));
    assert_eq!(takes(&plain, &Machine::Named("dev".into())), None);
    for extra in [
        &["--cwd", "/w"][..],
        &["--from-folder", "."],
        &["--no-folder"],
        &["--environment", "env_1"],
        &["--wait"],
        &["--timings"],
        &["--name", "n"],
        &["--attach", "f.txt"],
        &["--allow-large"],
    ] {
        let mut list = vec!["--on", "vm:new"];
        list.extend_from_slice(extra);
        list.extend(["--prompt", "hi"]);
        assert_eq!(takes(&start(&list), &Machine::New), None, "{extra:?}");
    }
    assert_eq!(takes(&start(&["--on", "vm:new"]), &Machine::New), None);
}

#[test]
fn off_the_cloud_start_has_todays_words_and_on_the_chat_here_has_the_starts_settings() {
    let plain = start(&["--on", "cloud", "--harness", "codex", "--model", "m", "--prompt", "hi"]);
    // Off: the Cloud start's words are what they were.
    assert_eq!(
        cloud_words(&plain, &Machine::New).unwrap()[..2],
        ["--prompt".to_owned(), "hi".to_owned()]
    );
    // On: `agents chat new` here, in the start's fresh folder, with the same settings.
    let here = here_words(&words(&["--json"]), &here_of(&plain, "/state/hybrid-start/f")).unwrap();
    assert_eq!(
        here,
        words(&[
            "--json",
            "agents",
            "chat",
            "new",
            "--harness",
            "codex",
            "--model",
            "m",
            "--cwd",
            "/state/hybrid-start/f",
            "--",
            "hi",
        ])
    );
}

#[test]
fn the_driver_is_spawned_with_its_session_and_machine_and_moves_without_interrupt() {
    let global = GlobalArgs { socket: Some("/s".into()), ..GlobalArgs::default() };
    assert_eq!(
        drive_words(&global, "chat-1", "new", 12),
        words(&["--socket", "/s", "cloud", "hybrid-drive", "chat-1", "new", "--gate-ms", "12"])
    );
    let moved = move_words("chat-1", "m1");
    assert_eq!(moved, words(&["move", "chat-1", "--to", "vm:m1", "--json"]));
    assert!(!moved.iter().any(|word| word == "--interrupt"));
    assert_eq!(
        pause_words("m1"),
        words(&["cloud", "pause-machine", "--target", "machine:m1", "--json"])
    );
}

/// The staging first run: the global parser took `--session` and `--machine` as the daemon's, the
/// driver saw neither and ended on its usage line, and no machine was ever started.
#[test]
fn the_spawned_driver_reads_back_its_own_words_past_the_global_parser() {
    let global = GlobalArgs {
        socket: Some("/s".into()),
        app_socket: Some("/a".into()),
        ..GlobalArgs::default()
    };
    for target in ["new", "vm_091afb1dad8bb63bc43a"] {
        let spawned = drive_words(&global, "01a20aaf-df27-72bc-93c9-2263cfd30106", target, 12);
        let Ok((read, command)) = super::super::super::parse_globals(&spawned) else {
            panic!("the driver's words do not parse: {spawned:?}");
        };
        assert_eq!(
            (read.socket, read.app_socket),
            (global.socket.clone(), global.app_socket.clone())
        );
        assert_eq!((read.session, read.machine), (None, None), "a daemon was named");
        assert_eq!(command[..2], ["cloud", "hybrid-drive"]);
        assert_eq!(
            drive_args(&command[2..]),
            Some(("01a20aaf-df27-72bc-93c9-2263cfd30106".into(), target.into(), "12".into()))
        );
    }
    assert_eq!(drive_args(&words(&["--session", "c", "--machine", "new"])), None);
    assert_eq!(drive_args(&words(&["c"])), None);
}

#[test]
fn the_plan_is_read_at_the_top_or_under_plan() {
    // `cloud.plan.get` over `/v1/read`: `{value: {plan_id, ...}}`.
    let read = json!({"value": {"plan_id": "team", "upgrade_plan": "max", "limits": {}}});
    assert_eq!(plan_of(&read).as_deref(), Some("team"));
    assert_eq!(plan_of(&json!({"plan_id": "next_pro"})).as_deref(), Some("next_pro"));
    assert_eq!(plan_of(&json!({"planId": "pro"})).as_deref(), Some("pro"));
    assert_eq!(plan_of(&json!({"plan": {"id": "next_max"}})).as_deref(), Some("next_max"));
    assert_eq!(plan_of(&json!({"plan": {"planId": "next_pro"}})).as_deref(), Some("next_pro"));
    assert_eq!(plan_of(&json!({"plan": "max"})).as_deref(), Some("max"));
    assert_eq!(plan_of(&json!({"status": "active"})), None);
}

#[test]
fn the_env_flag_and_plan_table_decides_as_hybrid_enabled_says() {
    let signed_in = || Ok(json!({"account": {"signed_in": true}, "machines": []}));
    let decide = |flag, listed: Result<Value, Value>, plan: Option<&str>| {
        hybrid::enabled(&account(flag, listed, || plan.map(str::to_owned)))
    };
    assert_eq!(decide(None, signed_in(), Some("pro")), Ok(()));
    assert_eq!(decide(None, signed_in(), Some("team")), Ok(()));
    assert_eq!(decide(None, signed_in(), Some("next_max")), Ok(()));
    for plan in ["go", "next_plus", "next_intro", "next_taste", "free"] {
        assert_eq!(decide(None, signed_in(), Some(plan)), Err(Off::Plan), "{plan}");
    }
    assert_eq!(decide(None, signed_in(), None), Err(Off::Plan));
    assert_eq!(decide(Some(true), signed_in(), None), Ok(()));
    assert_eq!(decide(Some(false), signed_in(), Some("pro")), Err(Off::Flag));
    let signed_out = Ok(json!({"account": {"signed_in": false}}));
    assert_eq!(decide(Some(true), signed_out, Some("pro")), Err(Off::NoCloud));
    let disabled = Err(json!({"code": "cloud_disabled", "message": "no"}));
    assert_eq!(decide(Some(true), disabled, None), Err(Off::NoCloud));
    // A flag decides: the plan is not read.
    let read = std::cell::Cell::new(false);
    let _ = account(Some(true), signed_in(), || {
        read.set(true);
        None
    });
    assert!(!read.get());
}

/// A driver whose events are scripted and whose effects are recorded.
#[derive(Default)]
struct Fake {
    events: VecDeque<Event>,
    moves: VecDeque<Result<(), (String, bool)>>,
    did: Vec<String>,
    clock: u64,
}

impl Drive for Fake {
    fn now_ms(&mut self) -> u64 {
        self.clock += 10;
        self.clock
    }
    fn create_machine(&mut self) {
        self.did.push("create".into());
    }
    fn next(&mut self) -> Option<Event> {
        self.events.pop_front()
    }
    fn move_chat(&mut self) -> Result<(), (String, bool)> {
        self.did.push("move".into());
        self.moves.pop_front().unwrap_or(Ok(()))
    }
    fn pause_machine(&mut self) {
        self.did.push("pause".into());
    }
    fn show(&mut self, cloud: Cloud, _reason: Option<&str>) {
        self.did.push(format!("show {}", serde_json::to_value(cloud).unwrap().as_str().unwrap()));
    }
    fn log(&mut self, _line: &str) {}
}

fn fake(events: Vec<Event>) -> Fake {
    Fake { events: events.into(), ..Fake::default() }
}

#[test]
fn a_machine_ready_mid_turn_waits_for_the_turns_end_then_moves() {
    let mut driver = fake(vec![Event::MachineReady, Event::TurnEnded]);
    let state = drive(&mut driver);
    assert_eq!(state.home, Home::Cloud);
    assert_eq!(
        driver.did,
        ["create", "show booting", "show ready", "show moving", "move", "show live"]
    );
}

#[test]
fn a_turn_over_before_the_machine_moves_the_chat_as_soon_as_it_is_ready() {
    let mut driver = fake(vec![Event::TurnEnded, Event::MachineReady]);
    let state = drive(&mut driver);
    assert_eq!((state.home, state.cloud), (Home::Cloud, Cloud::Live));
    assert_eq!(driver.did.iter().filter(|did| *did == "move").count(), 1);
}

#[test]
fn a_failed_machine_leaves_the_chat_here_with_nothing_to_pause() {
    let mut driver = fake(vec![Event::MachineFailed { reason: "quota".into() }]);
    let state = drive(&mut driver);
    assert_eq!((state.home, state.cloud), (Home::Here, Cloud::Failed));
    assert_eq!(state.reason.as_deref(), Some("quota"));
    assert!(!driver.did.iter().any(|did| did == "move" || did == "pause"));
}

#[test]
fn a_move_that_fails_for_good_pauses_the_machine_and_one_to_retry_goes_again() {
    let mut driver = fake(vec![Event::TurnEnded, Event::MachineReady]);
    driver.moves =
        VecDeque::from([Err(("busy".to_owned(), true)), Err(("gone".to_owned(), false))]);
    let state = drive(&mut driver);
    assert_eq!((state.home, state.cloud), (Home::Here, Cloud::Failed));
    assert_eq!(driver.did.iter().filter(|did| *did == "move").count(), 2);
    assert_eq!(driver.did.last().map(String::as_str), Some("pause"));
}

#[test]
fn a_chat_closed_or_a_deadline_passed_while_booting_pauses_the_machine_once_it_comes() {
    let mut driver = fake(vec![Event::Stop, Event::MachineReady]);
    let state = drive(&mut driver);
    assert_eq!(state.home, Home::Here);
    assert!(!driver.did.iter().any(|did| did == "move"));
    assert_eq!(driver.did.last().map(String::as_str), Some("pause"));
    // No event before the deadline: stopped, and the drive ends.
    let mut driver = fake(vec![]);
    let state = drive(&mut driver);
    assert!(state.stopped);
    assert!(!driver.did.iter().any(|did| did == "move"));
}

#[test]
fn a_cached_plan_decides_the_start_only_while_it_grants_it_and_is_fresh() {
    let now = 10 * 24 * 60 * 60 * 1000;
    let cache = |plan: &str, read_at: u64| json!({"plan": plan, "read_at_ms": read_at});
    assert_eq!(cached_plan(&cache("team", now - 1000), now).as_deref(), Some("team"));
    // A plan that does not grant it is read again: one just bought counts at once.
    assert_eq!(cached_plan(&cache("go", now - 1000), now), None);
    // Older than a week, or from the future: read again.
    assert_eq!(cached_plan(&cache("pro", now - 8 * 24 * 60 * 60 * 1000), now), None);
    assert_eq!(cached_plan(&cache("pro", now + 1000), now), None);
    assert_eq!(cached_plan(&json!({"plan": "pro"}), now), None);
}

#[test]
fn a_session_update_is_a_tool_start_or_end_once_per_call() {
    let mut open = std::collections::BTreeSet::new();
    let call = |kind: &str, id: &str, status: &str| json!({"sessionId": "s", "update": {"sessionUpdate": kind, "toolCallId": id, "status": status}});
    assert_eq!(tool_event(&call("tool_call", "a", "pending"), &mut open), Some(Event::ToolStarted));
    assert_eq!(tool_event(&call("tool_call", "a", "in_progress"), &mut open), None);
    assert_eq!(tool_event(&call("tool_call_update", "a", "in_progress"), &mut open), None);
    assert_eq!(tool_event(&call("tool_call_update", "b", "completed"), &mut open), None);
    assert_eq!(
        tool_event(&call("tool_call_update", "a", "completed"), &mut open),
        Some(Event::ToolEnded)
    );
    assert_eq!(tool_event(&call("tool_call_update", "a", "failed"), &mut open), None);
    let text = json!({"update": {"sessionUpdate": "agent_message_chunk"}});
    assert_eq!(tool_event(&text, &mut open), None);
}

#[test]
fn a_long_first_turn_moves_at_its_next_tool_boundary_once_the_machine_is_ready() {
    let mut driver = fake(vec![Event::ToolStarted, Event::MachineReady, Event::ToolEnded]);
    let state = drive(&mut driver);
    assert_eq!((state.home, state.cloud), (Home::Cloud, Cloud::Live));
    // Not under the tool: the move runs only after it ended.
    assert_eq!(
        driver.did,
        ["create", "show booting", "show ready", "show moving", "move", "show live"]
    );
}
