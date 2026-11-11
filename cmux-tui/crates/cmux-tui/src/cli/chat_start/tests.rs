use std::cell::Cell;

use serde_json::{Value, json};

use super::super::cloud_start_chat::Machine;
use std::time::Duration;

use super::{
    Parsed, Reads, Route, Start, TAKES_VALUE, USAGE, cloud_words, global_words, here_preflight,
    here_wait, here_words, in_environment, names_cloud, new_args, parse, parse_with, pick_target,
    read_setting, route, route_start, setting_stream, start_words,
};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn start(list: &[&str]) -> Start {
    match parse(&words(list), None).unwrap() {
        Parsed::Run(start) => start,
        Parsed::Help => panic!("help"),
    }
}

/// The daemon answers `machine.list` with a bare array (resource_api.rs `MachineList`).
fn catalog() -> Value {
    json!([
        {"id": "machine_mac", "name": "local", "origin": "local",
         "capabilities": ["terminal", "workspace", "agent_session"]},
        {"id": "machine_vm", "name": "dev", "origin": "cloud", "status": "running",
         "capabilities": ["terminal", "agent_session"]},
        {"id": "machine_box", "name": "box", "origin": "ssh", "status": "running",
         "capabilities": ["terminal", "agent_session"]},
        {"id": "machine_term", "name": "term", "origin": "ssh", "status": "running",
         "capabilities": ["terminal"]},
        {"id": "machine_nap", "name": "nap", "origin": "server", "status": "unavailable",
         "capabilities": ["agent_session"]},
        {"id": "machine_twin_a", "name": "twin", "origin": "ssh", "status": "running",
         "capabilities": ["agent_session"]},
        {"id": "machine_twin_b", "name": "twin", "origin": "ssh", "status": "running",
         "capabilities": ["agent_session"]},
        {"id": "machine_cloud_named", "name": "cloud", "origin": "cloud", "status": "running",
         "capabilities": ["agent_session"]},
    ])
}

/// The app's `cloud list-machines` answer.
fn listed() -> Value {
    json!({"account": {"signed_in": true}, "machines": [
        {"machine_id": "vm-dev", "title": "dev"},
        {"machine_id": "vm-a", "title": "twin-title"},
        {"machine_id": "vm-b", "title": "twin-title"},
        {"machine_id": "vm-cloud-named", "title": "cloud"},
    ]})
}

/// `route` with the fixtures, signed in or not.
fn at(on: &str, signed_in: bool) -> Result<Route, Value> {
    route(
        Some(on),
        Reads {
            catalog: || Ok(catalog()),
            signed_in: || signed_in,
            cloud_machines: || Ok(listed()),
        },
    )
}

fn code(result: Result<Route, Value>) -> String {
    let error = result.unwrap_err();
    assert!(error["details"]["next"].as_str().is_some_and(|next| !next.is_empty()), "{error}");
    error["code"].as_str().unwrap().to_owned()
}

#[test]
fn no_target_is_a_chat_here() {
    let parsed = start(&[]);
    assert_eq!(parsed.on, None);
    assert_eq!(start(&["--", "hi there"]).prompt.as_deref(), Some("hi there"));
    assert_eq!(start(&["--agent", "codex", "hi"]).prompt.as_deref(), Some("hi"));
    assert_eq!(
        here_words(&words(&["--socket", "/s"]), &start(&["--agent", "codex", "--cwd", "/w", "hi"]))
            .unwrap(),
        words(&[
            "--socket",
            "/s",
            "agents",
            "chat",
            "new",
            "--harness",
            "codex",
            "--cwd",
            "/w",
            "--",
            "hi"
        ])
    );
    let unread = || -> Result<Value, Value> { panic!("read") };
    let reads = Reads { catalog: unread, signed_in: || panic!("asked"), cloud_machines: unread };
    assert_eq!(route(None, reads), Ok(Route::Here));
    assert_eq!(at("here", false), Ok(Route::Here));
}

#[test]
fn one_flag_names_every_target() {
    assert_eq!(start(&["--on", "machine_box"]).on.as_deref(), Some("machine_box"));
    assert_eq!(start(&["--on=cloud"]).on.as_deref(), Some("cloud"));
    assert_eq!(start(&["--on", "vm:new", "go"]).on.as_deref(), Some("vm:new"));
    assert!(parse(&words(&["--on", " "]), None).is_err());
    assert!(parse(&words(&["--on", "a", "--on", "b"]), None).is_err());
    assert!(parse(&words(&["--on", "vm:"]), None).is_err());
    assert!(parse(&words(&["--prompt", "a", "b"]), None).is_err());
    // The old per-kind flags are not flags.
    assert!(parse(&words(&["--device", "machine_box"]), None).is_err());
    assert!(parse(&words(&["--vm", "new"]), None).is_err());
    assert_eq!(parse(&words(&["--help"]), None).unwrap(), Parsed::Help);
}

#[test]
fn cmux_target_names_the_target_when_on_is_absent() {
    let with_env = |list: &[&str], env: &str| match parse(&words(list), Some(env.into())).unwrap() {
        Parsed::Run(start) => start.on,
        Parsed::Help => panic!(),
    };
    assert_eq!(with_env(&["hi"], "vm:dev").as_deref(), Some("vm:dev"));
    assert_eq!(with_env(&["--on", "here", "hi"], "vm:dev").as_deref(), Some("here"));
    assert_eq!(with_env(&["hi"], "  "), None);
}

/// `--on` > `CMUX_ON` > the `chat.on` setting > here; the setting is read only when both are absent.
#[test]
fn the_target_is_on_then_cmux_on_then_the_setting_then_here() {
    let some = |text: &str| Some(text.to_owned());
    let read = Cell::new(0);
    let setting = |value: Option<&'static str>| {
        let read = &read;
        move || {
            read.set(read.get() + 1);
            value.map(str::to_owned)
        }
    };
    assert_eq!(pick_target(some("box"), some("vm:dev"), setting(Some("cloud"))), some("box"));
    assert_eq!(pick_target(None, some("vm:dev"), setting(Some("cloud"))), some("vm:dev"));
    assert_eq!(read.get(), 0, "the setting is not read when --on or CMUX_ON names a target");
    assert_eq!(pick_target(None, None, setting(Some(" cloud "))), some("cloud"));
    assert_eq!(pick_target(None, some("  "), setting(Some("vm:new"))), some("vm:new"));
    assert_eq!(pick_target(None, None, setting(Some(""))), None);
    assert_eq!(pick_target(None, None, setting(None)), None);
    assert_eq!(read.get(), 4);
}

#[test]
fn cmux_chat_reads_the_setting_only_without_on_and_cmux_on() {
    let read = Cell::new(false);
    let on = |list: &[&str], env: Option<&str>| {
        read.set(false);
        let setting = || {
            read.set(true);
            Some("cloud".to_owned())
        };
        match parse_with(&words(list), env.map(str::to_owned), setting).unwrap() {
            Parsed::Run(start) => (start.on, read.get()),
            Parsed::Help => (None, read.get()),
        }
    };
    assert_eq!(on(&["hi"], None), (Some("cloud".into()), true));
    assert_eq!(on(&["--on", "here", "hi"], None), (Some("here".into()), false));
    assert_eq!(on(&["hi"], Some("vm:dev")), (Some("vm:dev".into()), false));
    assert_eq!(on(&["--help"], None), (None, false));
    assert!(parse_with(&words(&["hi"]), None, || Some("vm:".into())).is_err());
}

#[test]
fn a_vm_chat_is_the_cloud_start_chat_run() {
    let vm =
        start(&["--on", "vm:dev", "--agent", "codex", "--wait", "--timeout", "60", "-p", "go"]);
    assert_eq!(
        cloud_words(&vm, &Machine::Target("vm-dev".into())).unwrap(),
        words(&[
            "--prompt",
            "go",
            "--target",
            "machine:vm-dev",
            "--agent",
            "codex",
            "--timeout",
            "60",
            "--wait"
        ])
    );
    assert_eq!(cloud_words(&start(&["go"]), &Machine::New).unwrap(), words(&["--prompt", "go"]));
    // A Cloud chat needs a prompt, and takes no chat name.
    assert!(cloud_words(&start(&[]), &Machine::New).is_err());
    assert!(cloud_words(&start(&["--name", "n", "go"]), &Machine::New).is_err());
}

/// Leo, 2026-11-10: a Cloud chat runs the Claude model the person asked for. `--model` reaches
/// `cloud start-chat`, which hands it to `cloud start-session --model`.
#[test]
fn a_cloud_chat_takes_the_model_asked_for() {
    let vm = start(&["--on", "vm:dev", "--model", "claude-haiku-5-5", "-p", "go"]);
    let words_out = cloud_words(&vm, &Machine::Target("vm-dev".into())).unwrap();
    assert_eq!(
        words_out,
        words(&["--prompt", "go", "--target", "machine:vm-dev", "--model", "claude-haiku-5-5"])
    );
    let super::super::cloud_start_chat::Parsed::Run(request) =
        super::super::cloud_start_chat::parse(&words_out, || Ok(String::new())).unwrap()
    else {
        panic!("help")
    };
    assert_eq!(request.model.as_deref(), Some("claude-haiku-5-5"));
    assert_eq!(request.agent, "claude");
}

/// Leo, 2026-11-10: "Does it work across every expected possible workspace?" `cmux chat --on
/// vm:new` copied no folder, so a chat started from a project never saw it. `--from-folder DIR`
/// goes to `cloud start-chat --from-folder`, which copies it the way New Cloud chat does.
#[test]
fn from_folder_goes_to_the_cloud_start() {
    let picked = start(&["--on", "vm:new", "--from-folder", ".", "go"]);
    assert_eq!(picked.from_folder.as_deref(), Some("."));
    assert_eq!(
        cloud_words(&picked, &Machine::New).unwrap(),
        words(&["--prompt", "go", "--from-folder", "."])
    );
    assert!(TAKES_VALUE.contains(&"--from-folder"));
    assert!(USAGE.contains("--from-folder DIR"));
    assert!(parse(&words(&["--from-folder", "a", "--from-folder", "b", "go"]), None).is_err());
}

/// The copy-size refusal's recovery, `--allow-large`, works on `cmux chat` too: it goes to the
/// Cloud start with the folder.
#[test]
fn allow_large_goes_to_the_cloud_start() {
    let picked = start(&["--on", "vm:new", "--from-folder", ".", "--allow-large", "go"]);
    assert!(picked.allow_large);
    assert_eq!(
        cloud_words(&picked, &Machine::New).unwrap(),
        words(&["--prompt", "go", "--from-folder", ".", "--allow-large"])
    );
}

/// Leo, 2026-11-06: "Shared chat commands can start in cloud." `cmux chat --on cloud` takes the
/// Environment the composer's chip picks: none is Auto, and one makes the chat's machine in it.
#[test]
fn a_cloud_chat_takes_an_environment_and_auto_is_none() {
    let auto = start(&["--on", "cloud", "go"]);
    assert_eq!(auto.environment, None);
    assert_eq!(
        in_environment(&auto, Route::Cloud(Machine::Target("vm-dev".into()))),
        Ok(Route::Cloud(Machine::Target("vm-dev".into())))
    );
    assert_eq!(in_environment(&start(&["go"]), Route::Here), Ok(Route::Here));

    let picked = start(&["--on", "cloud", "--environment", "staging-db", "go"]);
    assert_eq!(picked.environment.as_deref(), Some("staging-db"));
    assert!(TAKES_VALUE.contains(&"--environment"));
    // cmux Cloud's choice of place: a new machine in the environment, decided before any VM is
    // read, so several VMs of yours (which `--on cloud` alone refuses as `which_vm`) never matter.
    let reads = |signed_in: bool| Reads {
        catalog: || -> Result<Value, Value> { panic!("no catalog read") },
        signed_in: move || signed_in,
        cloud_machines: || -> Result<Value, Value> { panic!("no VM is looked at") },
    };
    assert_eq!(route_start(&picked, reads(true)), Ok(Route::Cloud(Machine::New)));
    let signed_out = route_start(&picked, reads(false)).unwrap_err();
    assert_eq!(signed_out["code"], "chat_target.signed_out");
    assert_eq!(
        cloud_words(&picked, &Machine::New).unwrap(),
        words(&["--prompt", "go", "--environment", "staging-db"])
    );
    let made = start(&["--on", "vm:new", "--environment=env_1", "go"]);
    assert_eq!(in_environment(&made, Route::Cloud(Machine::New)), Ok(Route::Cloud(Machine::New)));
    // Refused, never dropped: a VM that exists has its environment, and a chat here has none.
    let existing = start(&["--on", "vm:dev", "--environment", "env_1", "go"]);
    assert!(in_environment(&existing, Route::Cloud(Machine::Target("vm-dev".into()))).is_err());
    let here = start(&["--environment", "env_1", "go"]);
    assert!(in_environment(&here, Route::Here).is_err());
    assert!(parse(&words(&["--environment", " ", "go"]), None).is_err());
    assert!(USAGE.contains("--environment ENV"));
}

/// Before, `cmux chat --prompt X --wait` here was refused ("--wait and --timeout wait for a Cloud
/// chat; for a chat here, `cmux agents wait`"): a chat here took three commands. Now it waits, as
/// a Cloud chat does, with Cloud's default and cap.
#[test]
fn a_chat_here_waits_for_its_reply_as_a_cloud_chat_does() {
    assert_eq!(here_wait(&start(&["go"])).unwrap(), None);
    assert_eq!(here_wait(&start(&["--wait", "go"])).unwrap(), Some(Duration::from_secs(900)));
    assert_eq!(
        here_wait(&start(&["--wait", "--timeout", "60", "go"])).unwrap(),
        Some(Duration::from_secs(60))
    );
    assert_eq!(
        here_wait(&start(&["--wait", "--timeout", "999999", "go"])).unwrap(),
        Some(Duration::from_secs(4 * 60 * 60))
    );
    // `--timeout` alone bounds nothing, and is seconds, more than none.
    assert!(here_wait(&start(&["--timeout", "60", "go"])).is_err());
    assert!(here_wait(&start(&["--wait", "--timeout", "0", "go"])).is_err());
    assert!(here_wait(&start(&["--wait", "--timeout", "soon", "go"])).is_err());
    // The start it waits on is the `agents chat new` a chat here always was.
    let waits = start(&["--wait", "--agent", "codex", "--name", "n", "--prompt", "go"]);
    assert_eq!(
        new_args(&waits).unwrap(),
        words(&["--harness", "codex", "--name", "n", "--", "go"])
    );
    let mut expected = words(&["agents", "chat", "new"]);
    expected.extend(new_args(&waits).unwrap());
    assert_eq!(here_words(&[], &waits).unwrap(), expected);
    assert!(!USAGE.contains("Wait for a Cloud chat"), "the help says --wait works here too");
}

#[test]
fn vm_targets_are_new_or_an_existing_vm_never_made_for_them() {
    assert_eq!(at("vm:new", true), Ok(Route::Cloud(Machine::New)));
    assert_eq!(at("vm:vm-dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("vm:machine:vm-dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("vm:dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(code(at("vm:nothing", true)), "chat_target.unknown_vm");
    assert_eq!(code(at("vm:twin-title", true)), "chat_target.unknown_vm");
}

#[test]
fn cloud_is_a_selector_and_needs_a_sign_in() {
    // Four VMs, none running: which one is not guessed, for `vm` and for `cloud` (today the same).
    for on in ["cloud", "vm"] {
        assert_eq!(code(at(on, true)), "chat_target.which_vm");
        assert_eq!(code(at(on, false)), "chat_target.signed_out");
    }
    // A device named "cloud" is reached by its id, never by the selector.
    assert_eq!(
        at("machine_cloud_named", true),
        Ok(Route::Cloud(Machine::Target("vm-cloud-named".into())))
    );
}

/// `--on vm` with the app's VM list `listed`.
fn on_vm(listed: Value) -> Result<Route, Value> {
    route(
        Some("vm"),
        Reads {
            catalog: || -> Result<Value, Value> { panic!("catalog") },
            signed_in: || true,
            cloud_machines: || Ok(listed),
        },
    )
}

#[test]
fn vm_reuses_my_vm_and_makes_one_only_when_i_have_none() {
    let vm = |id: &str, status: &str| json!({"machine_id": id, "title": id, "status": status});
    let mine = |rows: Vec<Value>| json!({"account": {"signed_in": true}, "machines": rows});
    // No VMs, or only failed and going ones: a new VM.
    assert_eq!(on_vm(mine(vec![])), Ok(Route::Cloud(Machine::New)));
    let gone = vec![vm("vm-x", "failed"), vm("vm-y", "deleting")];
    assert_eq!(on_vm(mine(gone)), Ok(Route::Cloud(Machine::New)));
    // My one VM, paused too (the app resumes it for the chat).
    let paused = vec![vm("vm-dev", "paused"), vm("vm-x", "failed")];
    assert_eq!(on_vm(mine(paused)), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    // Of several, the one running.
    let several = vec![vm("vm-a", "paused"), vm("vm-b", "running"), vm("vm-c", "paused")];
    assert_eq!(on_vm(mine(several)), Ok(Route::Cloud(Machine::Target("vm-b".into()))));
    // Several and not one running: refused with their names, never a guess or a new VM.
    let unsure = on_vm(mine(vec![vm("vm-a", "paused"), vm("vm-b", "paused")]));
    let error = unsure.clone().unwrap_err();
    assert_eq!(code(unsure), "chat_target.which_vm");
    assert_eq!(error["details"]["names"], json!(["vm-a", "vm-b"]));
    assert!(error["message"].as_str().unwrap().contains("--on vm:new"), "{error}");
    // My only VM is still being made: say to retry, never start a second one.
    let making = json!({"account": {"signed_in": true}, "machines": [],
                        "creating": [{"creation_id": "c-1", "status": "creating"}]});
    let starting = on_vm(making).unwrap_err();
    assert_eq!(
        (starting["code"].as_str(), starting["retryable"].as_bool()),
        (Some("chat_target.vm_starting"), Some(true))
    );
    let failed = json!({"account": {"signed_in": true}, "machines": [],
                        "creating": [{"creation_id": "c-1", "status": "failed"}]});
    assert_eq!(on_vm(failed), Ok(Route::Cloud(Machine::New)));
    // Not loaded yet: say to retry, never make a VM I may already have.
    let unloaded = json!({"account": {"signed_in": true}, "loaded": false, "machines": []});
    assert_eq!(code(on_vm(unloaded)), "chat_target.unavailable");
    // `vm:NAME` too: not loaded is a retry, never an unknown VM.
    let unloaded = json!({"account": {"signed_in": true}, "loaded": false, "machines": []});
    let named = route(
        Some("vm:dev"),
        Reads {
            catalog: || -> Result<Value, Value> { panic!("catalog") },
            signed_in: || true,
            cloud_machines: || Ok(unloaded),
        },
    )
    .unwrap_err();
    assert_eq!(
        (named["code"].as_str(), named["retryable"].as_bool()),
        (Some("chat_target.unavailable"), Some(true))
    );
    // A Cloud VM named as a device too.
    let unloaded = json!({"account": {"signed_in": true}, "loaded": false, "machines": []});
    let device = route(
        Some("machine_vm"),
        Reads { catalog: || Ok(catalog()), signed_in: || true, cloud_machines: || Ok(unloaded) },
    )
    .unwrap_err();
    assert_eq!(
        (device["code"].as_str(), device["retryable"].as_bool()),
        (Some("chat_target.unavailable"), Some(true))
    );
    // Signed out by the list, though the sign-in read said yes.
    let out = json!({"account": {"signed_in": false}, "machines": []});
    assert_eq!(code(on_vm(out)), "chat_target.signed_out");
}

#[test]
fn devices_are_checked_against_the_daemons_catalog() {
    let asked = Cell::new(false);
    let reads = Reads {
        catalog: || Ok(catalog()),
        signed_in: || {
            asked.set(true);
            false
        },
        cloud_machines: || -> Result<Value, Value> { panic!("listed") },
    };
    // The local device needs no sign-in, and is not asked for one.
    assert_eq!(route(Some("machine_mac"), reads), Ok(Route::Here));
    assert!(!asked.get());
    assert_eq!(at("local", false), Ok(Route::Here));
    // A connected Cloud VM by id or name, signed in: the app's existing VM.
    assert_eq!(at("machine_vm", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(at("dev", true), Ok(Route::Cloud(Machine::Target("vm-dev".into()))));
    assert_eq!(code(at("machine_vm", false)), "chat_target.signed_out");
    // Refusals the SDK names, each with what to run next.
    assert_eq!(code(at("machine_gone", true)), "chat_target.unknown_device");
    assert_eq!(code(at("machine_term", true)), "chat_target.not_permitted");
    assert_eq!(code(at("machine_nap", true)), "chat_target.unavailable");
    // A name of two devices names none.
    assert_eq!(code(at("twin", true)), "chat_target.ambiguous_device");
    // An ssh device that passes the check has no CLI route yet: refused, never started elsewhere.
    assert_eq!(code(at("machine_box", true)), "chat_target.no_route");
    let unknown = at("machine_gone", true).unwrap_err();
    assert!(unknown["message"].as_str().unwrap().contains("cmux machine list"), "{unknown}");
}

/// The object form of the catalog reads the same.
#[test]
fn the_object_catalog_reads_like_the_daemons_array() {
    let object = || Ok(json!({"machines": catalog()}));
    for on in ["machine_mac", "dev", "twin", "machine_box", "machine_gone"] {
        let reads = Reads { catalog: object, signed_in: || true, cloud_machines: || Ok(listed()) };
        assert_eq!(route(Some(on), reads), at(on, true), "{on}");
    }
}

/// A connected Cloud device runs on the app's existing VM, by id or by its one title, and is
/// refused when the app lists none or several.
#[test]
fn a_cloud_device_is_an_existing_cloud_vm() {
    let with = |listed: Value| {
        route(
            Some("machine_vm"),
            Reads { catalog: || Ok(catalog()), signed_in: || true, cloud_machines: || Ok(listed) },
        )
    };
    assert_eq!(
        with(json!({"machines": [{"machine_id": "machine_vm", "title": "other"}]})),
        Ok(Route::Cloud(Machine::Target("machine_vm".into())))
    );
    assert_eq!(code(with(json!({"machines": []}))), "chat_target.unavailable");
    let two = json!({"machines": [{"machine_id": "a", "title": "dev"},
                                  {"machine_id": "b", "title": "dev"}]});
    assert_eq!(code(with(two)), "chat_target.unavailable");
}

/// `cmux chat PROMPT` is a start, like `cmux chat new PROMPT`; the other chat verbs are not.
#[test]
fn a_bare_prompt_is_a_start() {
    assert_eq!(start_words(&words(&["fix the tests"])), Some(&words(&["fix the tests"])[..]));
    assert_eq!(start_words(&words(&["new", "hi"])), Some(&words(&["hi"])[..]));
    assert_eq!(
        start_words(&words(&["--on", "cloud", "hi"])),
        Some(&words(&["--on", "cloud", "hi"])[..])
    );
    assert_eq!(start_words(&[]), Some(&[][..]));
    assert_eq!(start_words(&words(&["send", "x"])), None);
    assert_eq!(start_words(&words(&["list"])), None);
}

/// A chat here keeps the global options wherever they were typed, and runs `agents chat new`.
#[test]
fn a_chat_here_keeps_the_globals_typed_after_chat() {
    let here = |args: &[&str]| {
        let (mut global, command) = super::super::parse_globals(&words(args)).ok().unwrap();
        let rest = start_words(&command[1..]).unwrap();
        let lifted =
            super::super::cloud_start_chat::lift_output_of(rest, &mut global.output, TAKES_VALUE);
        let Parsed::Run(start) = parse(&lifted, None).unwrap() else { panic!("help") };
        here_words(&global_words(&global), &start).unwrap()
    };
    assert_eq!(
        here(&["chat", "--prompt", "hi", "--json"]),
        words(&["--json", "agents", "chat", "new", "--", "hi"])
    );
    assert_eq!(
        here(&["chat", "hi", "--socket", "/s"]),
        words(&["--socket", "/s", "agents", "chat", "new", "--", "hi"])
    );
    assert_eq!(
        here(&["--socket", "/s", "chat", "new", "hi"]),
        words(&["--socket", "/s", "agents", "chat", "new", "--", "hi"])
    );
    // After `--`, an output flag is the prompt.
    assert_eq!(here(&["chat", "--", "--json"]), words(&["agents", "chat", "new", "--", "--json"]));
}

/// Signed out, a `vm:` target says to sign in, not that the VM is unknown.
#[test]
fn a_vm_target_signed_out_says_to_sign_in() {
    let reads = Reads {
        catalog: || -> Result<Value, Value> { panic!("catalog") },
        signed_in: || false,
        cloud_machines: || Ok(json!({"account": {"signed_in": false}, "machines": []})),
    };
    assert_eq!(code(route(Some("vm:dev"), reads)), "chat_target.signed_out");
}

/// `cmux config set on …` sets the key `cmux chat` reads: the `on` alias (cli/command/settings.rs,
/// built on every platform) names [`super::TARGET_SETTING`].
#[test]
fn the_on_alias_is_the_chat_target_setting() {
    assert_eq!(super::super::command::resolve_alias("on"), super::TARGET_SETTING);
}

/// `cmux chat --socket <daemon socket>` reads `chat.on` from the app that owns that daemon, the
/// app the chat itself reaches, not nowhere: `--socket` naming a daemon is `socket.wrong_kind` to
/// the app connection (#37485's review at ca9748e1, F1; #37663).
#[test]
fn a_daemon_socket_reads_the_setting_from_its_owning_app() {
    let wrong_kind = || Err(json!({ "code": "socket.wrong_kind", "message": "a daemon socket" }));
    let (owner, _app) = std::os::unix::net::UnixStream::pair().unwrap();
    assert!(setting_stream(wrong_kind, || Ok(owner)).is_some());
    // Another failure (no app, an unreachable socket) reads nothing; the owner is not asked.
    let unreachable = || Err(json!({ "code": "socket.unreachable", "message": "gone" }));
    assert!(
        setting_stream(unreachable, || -> Result<_, String> { panic!("asked the owner") })
            .is_none()
    );
    // A socket that is the app's is read as named.
    let (named, _app) = std::os::unix::net::UnixStream::pair().unwrap();
    assert!(
        setting_stream(|| Ok(named), || -> Result<_, String> { panic!("asked the owner") })
            .is_some()
    );
}

#[test]
fn a_chat_here_takes_a_repository() {
    let parsed = start(&["--repo", "https://gitlab.com/gitlab-org/gitlab-test", "hi"]);
    let repo = parsed.repo.unwrap();
    assert_eq!((repo.host.as_str(), repo.name.as_str()), ("gitlab.com", "gitlab-test"));
    assert!(parse(&words(&["--repo", "nope"]), None).is_err());
    assert!(parse(&words(&["--repo", "o/n", "--repo", "o/m"]), None).is_err());
    assert!(TAKES_VALUE.contains(&"--repo"));
    // The local start matrix reads the usage block for `[--repo` (hq local_chat_probe.py takes_repo).
    assert!(USAGE.split("\n\n").next().unwrap().contains("[--repo URL]"));
    for on in ["cloud", "vm", "vm:new", "vm:dev"] {
        assert!(names_cloud(on), "{on}");
    }
    assert!(!names_cloud("here") && !names_cloud("studio-mac"));
    // Checked before anything is cloned: a bad wait, and `agents chat new`'s own refusals.
    assert!(here_preflight(&start(&["--repo", "o/n", "hi"])).is_ok());
    assert!(here_preflight(&start(&["--repo", "o/n", "--wait", "--timeout", "0", "hi"])).is_err());
    assert!(here_preflight(&start(&["--repo", "o/n", "--attach", "/tmp/note.txt"])).is_err());
    assert!(here_preflight(&start(&["--repo", "o/n", "--cwd", "rel", "hi"])).is_err());
}

/// A fake app for the `chat.on` read: every `settings.get` gets the next of `answers` after its
/// delay, and a plain `ping` on its own connection (the liveness probe) gets `PONG` at once while
/// the app is up. Joins to the `settings.get` requests it read.
fn slow_app(
    answers: Vec<(Duration, Value)>,
) -> (std::path::PathBuf, App, cmux_unix_socket::TestDir) {
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::sync::{Arc, Mutex};
    let dir = cmux_unix_socket::short_test_dir("cmux-chat-on");
    let socket = dir.path().join("app.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let answers = Arc::new(Mutex::new(answers.into_iter()));
    let seen = Arc::new(Mutex::new(Vec::new()));
    let (done, stop) = std::sync::mpsc::channel::<()>();
    let app = {
        let seen = Arc::clone(&seen);
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let mut served = Vec::new();
            loop {
                if !matches!(stop.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)) {
                    break;
                }
                let Ok((stream, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                stream.set_nonblocking(false).unwrap();
                let (answers, seen) = (Arc::clone(&answers), Arc::clone(&seen));
                served.push(std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        if line.trim() == "ping" {
                            let _ = writer.write_all(b"PONG\n");
                            return;
                        }
                        let request: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        seen.lock().unwrap().push(request);
                        let Some((delay, answer)) = answers.lock().unwrap().next() else { return };
                        std::thread::sleep(delay);
                        if writeln!(writer, "{answer}").is_err() {
                            return;
                        }
                    }
                }));
            }
            for one in served {
                let _ = one.join();
            }
            seen.lock().unwrap().clone()
        })
    };
    (socket, App { done, app }, dir)
}

/// A running [`slow_app`]; [`finish`] stops it.
struct App {
    done: std::sync::mpsc::Sender<()>,
    app: std::thread::JoinHandle<Vec<Value>>,
}

fn connected(socket: &std::path::Path) -> std::os::unix::net::UnixStream {
    std::os::unix::net::UnixStream::connect(socket).unwrap()
}

/// Stops `app` and gives back the `settings.get` requests it read.
fn finish(app: App) -> Vec<Value> {
    drop(app.done);
    app.app.join().unwrap()
}

/// The `chat.on` setting decides where the chat runs, so a live app that is only slow is waited
/// for: one that answers after 2 s (20 read windows) is still the setting. With the old 1.5 s hard
/// deadline the read was no setting, and a person's Cloud setting started the chat here.
#[test]
fn a_slow_live_app_still_names_the_chat_target() {
    let value = json!({ "ok": true, "result": { "value": "vm:new" } });
    let (socket, app, _dir) = slow_app(vec![(Duration::from_millis(2_000), value)]);
    let read =
        read_setting(&mut connected(&socket), Duration::from_millis(100), Duration::from_secs(30));
    let seen = finish(app);
    assert_eq!(read, Ok(Some("vm:new".to_owned())));
    assert_eq!(seen.len(), 1, "one ask, never resent while the app answered pings: {seen:?}");
    // The read catches up with the daemon first, so a value `cmux config set on` just wrote is read.
    assert_eq!(seen[0]["params"], json!({ "path": "chat.on", "after": "sync" }), "{seen:?}");
}

/// The app's own request deadline passing on a loaded host (`timeout`, `busy`) is asked again
/// while the app lives, until it answers.
#[test]
fn an_app_that_refuses_while_busy_is_asked_again() {
    let busy = json!({ "ok": false, "error": { "code": "timeout", "message": "no reply within 2.0 seconds" } });
    let value = json!({ "ok": true, "result": { "value": "cloud" } });
    let answers = vec![
        (Duration::ZERO, busy.clone()),
        (Duration::ZERO, busy.clone()),
        (Duration::ZERO, json!({ "ok": false, "error": { "code": "busy", "message": "busy" } })),
        (Duration::ZERO, busy),
        (Duration::ZERO, value),
    ];
    let (socket, app, _dir) = slow_app(answers);
    let read =
        read_setting(&mut connected(&socket), Duration::from_millis(50), Duration::from_secs(30));
    finish(app);
    assert_eq!(read, Ok(Some("cloud".to_owned())));
}

/// An app that keeps refusing past the whole wait starts nothing: the answer is a retryable
/// error, not a chat started here when the person's setting may name a Cloud VM.
#[test]
fn an_app_that_never_answers_starts_nothing() {
    let busy = json!({ "ok": false, "error": { "code": "timeout", "message": "no reply" } });
    let answers = (0..200).map(|_| (Duration::from_millis(10), busy.clone())).collect();
    let (socket, app, _dir) = slow_app(answers);
    let read = read_setting(
        &mut connected(&socket),
        Duration::from_millis(50),
        Duration::from_millis(300),
    );
    finish(app);
    let error = read.unwrap_err();
    assert_eq!(error["code"], "app.setting_unanswered", "{error}");
    assert_eq!(error["retryable"], true, "{error}");
}

/// An app that answers its liveness ping but never this ask is held to the whole wait: the read
/// gives up at `total` with `app.setting_unanswered`, not when (or if) the app replies. Before, a
/// pending ask waited as long as pings were answered, so `cmux chat` could hang forever.
#[test]
fn an_app_that_answers_pings_but_not_the_ask_is_held_to_the_wait() {
    let value = json!({ "ok": true, "result": { "value": "cloud" } });
    let (socket, app, _dir) = slow_app(vec![(Duration::from_secs(3), value)]);
    let began = std::time::Instant::now();
    let read = read_setting(
        &mut connected(&socket),
        Duration::from_millis(50),
        Duration::from_millis(300),
    );
    let took = began.elapsed();
    finish(app);
    let error = read.unwrap_err();
    assert_eq!(error["code"], "app.setting_unanswered", "{error}");
    assert_eq!(error["retryable"], true, "{error}");
    assert!(took < Duration::from_secs(2), "gave up after {took:?}, not at the 300 ms wait");
}

/// A refusal that will not pass (an app with no `settings.get`) and an unset key are no setting.
#[test]
fn a_refused_or_unset_setting_is_no_setting() {
    let unknown = json!({ "ok": false, "error": { "code": "method_not_found", "message": "no" } });
    let (socket, app, _dir) = slow_app(vec![(Duration::ZERO, unknown)]);
    assert_eq!(
        read_setting(&mut connected(&socket), Duration::from_millis(50), Duration::from_secs(30)),
        Ok(None)
    );
    finish(app);
    let unset = json!({ "ok": true, "result": { "value": null } });
    let (socket, app, _dir) = slow_app(vec![(Duration::ZERO, unset)]);
    assert_eq!(
        read_setting(&mut connected(&socket), Duration::from_millis(50), Duration::from_secs(30)),
        Ok(None)
    );
    finish(app);
}
