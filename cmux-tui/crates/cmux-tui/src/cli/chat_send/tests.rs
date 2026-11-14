use std::time::Duration;

use serde_json::{Value, json};

use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn command(words: &[&str]) -> Option<Vec<String>> {
    words_of(&strings(words)).map(<[String]>::to_vec)
}

fn sent(words: &[&str], send_verb: bool) -> Send {
    match parse(&strings(words), send_verb) {
        Ok(Parsed::Run(send)) => send,
        other => panic!("{words:?}: {other:?}"),
    }
}

#[test]
fn a_send_to_a_session_is_this_files_and_a_send_to_a_chief_is_not() {
    assert_eq!(command(&["chat", "send", "s-1", "hi"]), Some(strings(&["s-1", "hi"])));
    assert_eq!(command(&["chat", "send", "--to", "chief", "--text", "hi"]), None);
    assert_eq!(command(&["chat", "send", "--to=chief", "hi"]), None);
    // `cmux chat --help` points at `cmux chat send --help` for the session form; with --to
    // the help is the Chief form's.
    assert_eq!(command(&["chat", "send", "--help"]), Some(strings(&["--help"])));
    assert_eq!(command(&["chat", "send", "-h"]), Some(strings(&["-h"])));
    assert_eq!(command(&["chat", "send", "--to", "chief", "--help"]), None);
    assert_eq!(command(&["chat", "send", "--text", "hi", "-h"]), None);
    assert_eq!(
        command(&["chat", "--resume", "s-1", "go on"]),
        Some(strings(&["--resume", "s-1", "go on"]))
    );
    // `--resume` or `--to` as a value, or after `--`, is text: a start, or a send to a session.
    assert_eq!(command(&["chat", "--prompt", "--resume"]), None);
    assert_eq!(command(&["chat", "--", "--resume"]), None);
    assert_eq!(command(&["chat", "-p", "--resume=x", "hi"]), None);
    assert_eq!(
        command(&["chat", "send", "s-1", "--", "--to"]),
        Some(strings(&["s-1", "--", "--to"]))
    );
    assert_eq!(command(&["chat", "send", "--to", "s-1", "hi"]), None);
    // A start, and the other chat verbs, stay where they are.
    assert_eq!(command(&["chat", "fix the tests"]), None);
    assert_eq!(command(&["chat", "read", "--to", "chief"]), None);
    assert_eq!(command(&["agents", "chat", "send", "s-1", "hi"]), None);
}

#[test]
fn parse_takes_the_session_the_prompt_and_the_wait() {
    let send = sent(&["s-1", "next step", "--wait", "--timeout", "60"], true);
    assert_eq!(
        send,
        Send {
            session: "s-1".into(),
            text: "next step".into(),
            on: None,
            wait: true,
            timeout: Some(Duration::from_secs(60)),
        }
    );
    let resumed = sent(&["--resume=s-2", "--on", "vm:dev", "--prompt", "go on"], false);
    assert_eq!((resumed.session.as_str(), resumed.text.as_str()), ("s-2", "go on"));
    assert_eq!(resumed.on.as_deref(), Some("vm:dev"));
    assert_eq!(sent(&["s-1", "--", "-starts with a dash"], true).text, "-starts with a dash");
    for (words, send_verb) in [
        (vec!["0d4f9a52-8c1e-4b7a-9f3e-2a6b5c7d8e9f"], true),
        (vec!["s-1", "two", "words"], true),
        (vec!["s-1", "  "], true),
        (vec!["s-1", "hi", "--timeout", "soon"], true),
        (vec!["s-1", "hi", "--bogus"], true),
        (vec!["go on"], false),
        (vec!["s-1", "hi", "--resume", "s-2"], true),
    ] {
        assert!(parse(&strings(&words), send_verb).is_err(), "{words:?}");
    }
    assert_eq!(parse(&strings(&["--help"]), true), Ok(Parsed::Help));
}

/// The send `args` makes, and the output it asks for.
fn typed(args: &[&str]) -> (Send, OutputMode) {
    let (mut global, command) = super::super::parse_globals(&strings(args)).ok().unwrap();
    let words = words_of(&command).unwrap();
    let words = cloud_start_chat::lift_output_of(words, &mut global.output, TAKES_VALUE);
    match parse(&words, command.get(1).map(String::as_str) == Some("send")) {
        Ok(Parsed::Run(send)) => (send, global.output),
        other => panic!("{args:?}: {other:?}"),
    }
}

/// An output flag sets the output; after `--` it is the prompt.
#[test]
fn an_output_flag_after_the_separator_is_the_prompt() {
    let (send, output) = typed(&["chat", "send", "s-1", "hi", "--json"]);
    assert_eq!((send.text.as_str(), output), ("hi", OutputMode::Json));
    for flag in ["--json", "--jsonl", "--quiet"] {
        let (send, output) = typed(&["chat", "send", "s-1", "--", flag]);
        assert_eq!((send.text.as_str(), output), (flag, OutputMode::Human), "{flag}");
        let (send, _) = typed(&["chat", "--resume", "s-1", "--", flag]);
        assert_eq!(send.text, flag);
        // `--wait` takes no value: the `--` after it is still the separator.
        let (send, output) = typed(&["chat", "send", "s-1", "--wait", "--", flag]);
        assert_eq!((send.text.as_str(), send.wait, output), (flag, true, OutputMode::Human));
    }
}

/// The app's topology: a chat here, one in a Cloud VM's workspace, one on an SSH host.
fn topology() -> Value {
    let tab = |session: &str| json!({"tabs": [{"kind": "conversation", "agent_session": session}]});
    let screen = |session: &str| json!([{"panes": [tab(session)]}]);
    json!({
        "workspaces": [
            {"id": "ws_here", "session": "home", "screens": screen("s-here")},
            {"id": "ws_vm", "machine": "vm-dev", "session": "cloud-1", "screens": screen("s-vm")},
            {"id": "ws_ssh", "session": "ssh-1", "screens": screen("s-ssh")},
        ],
        "sessions": [
            {"id": "home", "machine": "local", "transport": "local"},
            {"id": "cloud-1", "machine": "vm-dev", "transport": "cloud"},
            {"id": "ssh-1", "machine": "ssh-box", "transport": "ssh"},
        ],
    })
}

fn listed() -> Value {
    json!({"account": {"signed_in": true}, "machines": [
        {"machine_id": "vm-dev", "title": "dev"},
    ]})
}

fn at(session: &str, on: Option<&str>) -> Result<Place, Value> {
    locate(session, on, || Ok(topology()), || Ok(listed()))
}

#[test]
fn the_session_finds_its_chats_machine() {
    assert_eq!(at("s-vm", None), Ok(Place::Vm("vm-dev".into())));
    assert_eq!(at("s-here", None), Ok(Place::Here));
    // Not a VM's (an SSH host's), or not shown: this machine's acpmux says whether it has it.
    assert_eq!(at("s-ssh", None), Ok(Place::Here));
    assert_eq!(at("s-unknown", None), Ok(Place::Here));
    // No app: here.
    let no_app =
        locate("s-vm", None, || Err(json!({"code": "app.unreachable"})), || panic!("listed"));
    assert_eq!(no_app, Ok(Place::Here));
}

#[test]
fn on_names_the_place_without_the_lookup() {
    let no_lookup = |on| locate("s-x", Some(on), || panic!("topology"), || Ok(listed()));
    assert_eq!(no_lookup("here"), Ok(Place::Here));
    assert_eq!(no_lookup("vm:dev"), Ok(Place::Vm("vm-dev".into())));
    assert_eq!(no_lookup("vm:machine:vm-dev"), Ok(Place::Vm("vm-dev".into())));
    assert_eq!(no_lookup("vm:gone").unwrap_err()["code"], "chat_target.unknown_vm");
    assert_eq!(no_lookup("vm:new").unwrap_err()["code"], "chat_target.no_route");
    assert_eq!(no_lookup("cloud").unwrap_err()["code"], "chat_target.no_route");
}

/// `--timeout 0` is refused as `cloud start-chat` refuses it: a send with no time would run on the machine and
/// only then answer that the time ran out (the seventh review of #37159).
#[test]
fn a_zero_timeout_is_refused() {
    for words in [&["s-1", "--timeout", "0", "hi"][..], &["s-1", "--timeout=0", "hi"]] {
        let refused = parse(&strings(words), true);
        assert!(
            matches!(&refused, Err(error) if format!("{error:?}").contains("--timeout")),
            "{words:?}: {refused:?}"
        );
    }
    assert_eq!(sent(&["s-1", "--timeout", "5", "hi"], true).timeout, Some(Duration::from_secs(5)));
}

/// A joined machine's chat: `HOST/NAME` goes to acpmux without the app's lookup, and `--on`
/// with the machine's name qualifies a bare session with its hub host.
#[test]
fn a_joined_machines_chat_goes_to_acpmux() {
    let qualified =
        locate("studio/run-tests-abcd", None, || panic!("topology"), || panic!("listed"));
    assert_eq!(qualified, Ok(Place::Acp("studio/run-tests-abcd".into())));
    let desk = || {
        Some(Ok(JoinedMachine {
            id: Some("m_desk".into()),
            name: "Desk Mac".into(),
            host: "mini-2".into(),
        }))
    };
    let on = |session: &str, on: &str| {
        locate_with(session, Some(on), || panic!("topology"), || panic!("listed"), |_| desk())
    };
    assert_eq!(on("lane-a", "Desk Mac"), Ok(Place::Acp("mini-2/lane-a".into())));
    assert_eq!(on("mini-2/lane-a", "joined:m_desk"), Ok(Place::Acp("mini-2/lane-a".into())));
    // A refused machine says why; reserved selectors never ask for a joined machine.
    let offline = locate_with(
        "lane-a",
        Some("attic"),
        || panic!("topology"),
        || panic!("listed"),
        |_| Some(Err(json!({"code": "chat_target.unavailable"}))),
    );
    assert_eq!(offline.unwrap_err()["code"], "chat_target.unavailable");
    let reserved = locate_with(
        "s",
        Some("cloud"),
        || panic!("topology"),
        || panic!("listed"),
        |_| panic!("asked"),
    );
    assert_eq!(reserved.unwrap_err()["code"], "chat_target.no_route");
    // Not joined: no route, as before.
    let none =
        locate_with("s", Some("nowhere"), || panic!("topology"), || panic!("listed"), |_| None);
    assert_eq!(none.unwrap_err()["code"], "chat_target.no_route");
}

/// Before, `cmux chat read <uuid>` and `cmux chat wait <uuid>` went to the Chief ("the Chief is
/// not running", exit 3), though `cmux chat --help` points agents at `cmux chat read|wait`. A
/// session id as the first word is that chat's.
#[test]
fn read_and_wait_with_a_session_id_are_the_chats() {
    let session = "0d4f9a52-8c1e-4b7a-9f3e-2a6b5c7d8e9f";
    for verb in ["read", "wait"] {
        let command = strings(&["chat", verb, session, "--timeout", "60"]);
        let (found, words) = session_verb(&command).expect(verb);
        assert_eq!((found, words), (verb, &command[2..]));
        let acp = strings(&["chat", verb, &format!("acp:{session}")]);
        assert_eq!(session_verb(&acp).map(|(verb, _)| verb), Some(verb));
        // `--to`, a message ref or nothing: the Chief's (chief/chat_scope.rs).
        assert_eq!(session_verb(&strings(&["chat", verb, "--to", "chief"])), None);
        assert_eq!(session_verb(&strings(&["chat", verb, "#3"])), None);
        assert_eq!(session_verb(&strings(&["chat", verb])), None);
    }
    assert_eq!(session_verb(&strings(&["chat", "list", session])), None);
    assert!(is_session_id(session) && is_session_id("acp:lane-a"));
    assert!(!is_session_id("lane-a") && !is_session_id("msg_1"));
}

#[test]
fn chat_wait_takes_the_session_and_a_timeout_like_send_wait() {
    let parsed = |words: &[&str]| parse_wait(&strings(words));
    assert_eq!(parsed(&["s-1"]).unwrap(), Some(("s-1".to_owned(), Duration::from_secs(900))));
    assert_eq!(
        parsed(&["s-1", "--timeout=30"]).unwrap(),
        Some(("s-1".to_owned(), Duration::from_secs(30)))
    );
    assert_eq!(
        parsed(&["--timeout", "99999", "s-1"]).unwrap(),
        Some(("s-1".to_owned(), Duration::from_secs(4 * 60 * 60)))
    );
    assert_eq!(parsed(&["s-1", "--help"]).unwrap(), None);
    assert!(parsed(&[]).is_err());
    assert!(parsed(&["s-1", "--timeout", "0"]).is_err());
    assert!(parsed(&["s-1", "s-2"]).is_err());
    assert!(parsed(&["s-1", "--after", "3"]).is_err());
}

/// A send here with `--wait` no longer refuses: the help says it waits for any chat.
#[test]
fn send_wait_is_for_a_chat_here_too() {
    assert!(!USAGE.contains("(a chat on a Cloud VM)"), "{USAGE}");
    assert!(USAGE.contains("cmux chat wait SESSION"), "{USAGE}");
    let send = sent(&["s-1", "next", "--wait"], true);
    assert!(send.wait && send.timeout.is_none());
}

/// Leo, 2026-11-10: "We need to keep cleaning up the cli commands so they're nice to type". A
/// follow-up names no session: `chat send TEXT` is the last chat this terminal used.
#[test]
fn a_send_without_a_session_is_to_the_last_chat() {
    let last = super::super::last_chat::LAST;
    let send = sent(&["next step", "-w"], true);
    assert_eq!((send.session.as_str(), send.text.as_str(), send.wait), (last, "next step", true));
    assert_eq!(sent(&["--prompt", "go on"], true).session, last);
    assert_eq!(sent(&["--", "-dash"], true).session, last);
    assert_eq!(sent(&["last", "go on"], true).session, last);
    // Two words are still SESSION TEXT; a session with `--prompt` is that session.
    assert_eq!(sent(&["s-1", "go on"], true).session, "s-1");
    assert_eq!(sent(&["s-1", "--prompt", "go on"], true).session, "s-1");
    assert!(parse(&strings(&["a", "b", "c"]), true).is_err());
    // `chat send TEXT` is this file's, not the Chief's.
    assert_eq!(command(&["chat", "send", "next step"]), Some(strings(&["next step"])));
}

#[test]
fn read_and_wait_take_last() {
    for verb in ["read", "wait"] {
        let command = strings(&["chat", verb, "last"]);
        assert_eq!(session_verb(&command).map(|(found, _)| found), Some(verb));
    }
}

/// cmuxterm-hq#8621: `--timeout` takes a duration in chat and the Chief, as `status wait` and
/// `terminal … screen wait` do; a bare number keeps meaning seconds.
#[test]
fn timeouts_are_durations_and_a_bare_number_is_seconds() {
    assert_eq!(timeout_value("90").unwrap(), Duration::from_secs(90));
    assert_eq!(timeout_value("5m").unwrap(), Duration::from_secs(300));
    assert_eq!(timeout_value("1h").unwrap(), Duration::from_secs(3600));
    assert_eq!(timeout_value("1500ms").unwrap(), Duration::from_millis(1500));
    assert!(timeout_value("0").is_err() && timeout_value("soon").is_err());
    assert_eq!(timeout_secs("0"), Ok(None));
    assert_eq!(timeout_secs("1500ms"), Ok(Some(2)));
    assert_eq!(timeout_secs("2m"), Ok(Some(120)));
    assert_eq!(
        sent(&["s-1", "hi", "-w", "--timeout", "5m"], true).timeout,
        Some(Duration::from_secs(300))
    );
}

/// The account's joined machines and the hub's list, for [`joined::resolve`].
fn account() -> Vec<Value> {
    vec![
        json!({"kind": "joined", "id": "m_studio", "name": "studio", "hostname": "studio",
               "state": "online"}),
        json!({"kind": "joined", "id": "m_attic", "name": "attic", "hostname": "attic",
               "state": "offline"}),
        json!({"kind": "joined", "id": "m_old", "name": "old", "hostname": "old",
               "state": "revoked"}),
    ]
}

fn hub_lists() -> Vec<Value> {
    ["studio", "old", "mini-2"]
        .map(|name| json!({"name": name, "connected": true, "via": "hub"}))
        .to_vec()
}

/// `locate_with` for `session` with the start's own account check (`joined::resolve`); `rows`
/// None: the account's list could not be read.
fn send_to(session: &str, on: Option<&str>, rows: Option<Vec<Value>>) -> Result<Place, Value> {
    locate_with(
        session,
        on,
        || panic!("topology"),
        || panic!("listed"),
        |host| {
            joined::resolve(
                host,
                joined::Sources {
                    hub: hub_lists,
                    rows: || rows.ok_or_else(|| "not signed in".to_owned()),
                },
            )
        },
    )
}

/// #38355 review 2b: a `HOST/NAME` send (`cmux chat send HOST/NAME`, and a bare `cmux chat
/// send` to the last chat, which is one) went to acpmux with no account check, so a revoked
/// machine the hub still listed got the prompt. HOST gets the start's own check now.
#[test]
fn a_send_to_a_revoked_or_unverified_machine_is_refused() {
    let revoked = send_to("old/lane-a", None, Some(account())).unwrap_err();
    assert_eq!(revoked["code"], "chat_target.revoked", "{revoked}");
    let unverified = send_to("mini-2/lane-a", None, None).unwrap_err();
    assert_eq!(unverified["code"], "chat_target.unverified", "{unverified}");
    // A live machine, an offline one (the hub keeps the prompt) and a host no joined machine
    // names (a peer's) still get it.
    assert_eq!(
        send_to("studio/lane-a", None, Some(account())),
        Ok(Place::Acp("studio/lane-a".into()))
    );
    assert_eq!(
        send_to("attic/lane-a", None, Some(account())),
        Ok(Place::Acp("attic/lane-a".into()))
    );
    assert_eq!(send_to("peer/lane-a", None, Some(account())), Ok(Place::Acp("peer/lane-a".into())));
    assert_eq!(send_to("peer/lane-a", None, None), Ok(Place::Acp("peer/lane-a".into())));
}

/// #38355 review 2c: with `--on`, a session that already named its machine kept it, so
/// `cmux chat send attic/x --on studio` checked studio and sent to attic. The two must agree.
#[test]
fn a_session_on_another_machine_than_on_names_is_refused() {
    let mismatch = send_to("old/x", Some("studio"), Some(account())).unwrap_err();
    assert_eq!(mismatch["code"], "chat_target.mismatch", "{mismatch}");
    assert!(mismatch["message"].as_str().unwrap().contains("runs on old"), "{mismatch}");
    // The same machine, in any case, and a bare session qualified with it.
    assert_eq!(
        send_to("STUDIO/x", Some("studio"), Some(account())),
        Ok(Place::Acp("STUDIO/x".into()))
    );
    assert_eq!(send_to("x", Some("studio"), Some(account())), Ok(Place::Acp("studio/x".into())));
}
