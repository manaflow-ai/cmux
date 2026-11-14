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
    assert_eq!(command(&["chat", "send", "--help"]), None);
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
        (vec!["s-1"], true),
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
