use super::*;

fn words(line: &str) -> Vec<String> {
    line.split(' ').map(str::to_owned).collect()
}

#[test]
fn each_verb_parses_to_its_frames() {
    let send = parse(&words(
        "send --host host_ab12 --surface 3 --text hello --steer --prompt-id p1 --json",
    ))
    .unwrap();
    assert_eq!(
        frames(&send.verb)[1],
        json!({"cmd":"agent-session-prompt","surface":3,"prompt_id":"p1","text":"hello","steer":true})
    );
    let list = parse(&words("list --host host_ab12 --name Ana")).unwrap();
    assert_eq!(list.name.as_deref(), Some("Ana"));
    assert_eq!(frames(&list.verb), vec![json!({"cmd":"agent-session-team-list"})]);
    let approve = parse(&words(
        "approve --host host_ab12 --surface 3 --prompt-id g1 --turn-id t1 --revision 0",
    ))
    .unwrap();
    assert_eq!(
        frames(&approve.verb)[1],
        json!({"cmd":"agent-session-queue-approve","surface":3,"prompt_id":"g1","turn_id":"t1","revision":0})
    );
}

#[test]
fn help_names_every_verb() {
    for verb in ["list", "read", "send", "approve", "decline"] {
        assert!(USAGE.contains(&format!("cmux link chat {verb} --host ID")), "{verb}");
    }
    assert_eq!(run(&words("--help")), 0);
    assert_eq!(run(&words("send --help")), 0);
    assert!(!asks_for_help(&words("send --host host_ab12 --surface 1 --text --help")));
    assert!(!asks_for_help(&words("send --host host_ab12 --surface 1 --text help")));
}

#[test]
fn bad_usage_is_refused_before_any_dial() {
    for line in [
        "send --host host_ab12 --surface 3",
        "send --host host_ab12 --text hi",
        "read --surface 1",
        "list --host host_ab12 --host host_cd34",
        "approve --host host_ab12 --surface 3 --prompt-id g1",
        "list --host host_ab12 --socket relative.sock",
        "shout --host host_ab12",
    ] {
        assert!(parse(&words(line)).is_err(), "{line}");
    }
}
