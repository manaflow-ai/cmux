use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// The request `cmux WORDS…` makes, read the way `run_if_requested` reads it.
fn request(words: &[&str]) -> Result<MoveRequest, String> {
    let (global, command) = super::super::parse_globals(&strings(words)).expect("globals parse");
    let (verb, skip) = verb_of(&command).expect("a move verb");
    parse_request(verb, &global, &command[skip..]).map_err(|error| error.0)
}

#[test]
fn the_three_names_and_the_agent_spellings_are_the_verb() {
    for (words, verb) in [
        (&["move", "a"][..], Verb::Move),
        (&["teleport", "a"], Verb::Teleport),
        (&["evacuate"], Verb::Evacuate),
        (&["agent", "move", "a"], Verb::Move),
        (&["agent", "teleport", "a"], Verb::Teleport),
        (&["agent", "evacuate"], Verb::Evacuate),
    ] {
        let command = strings(words);
        assert_eq!(verb_of(&command).map(|(verb, _)| verb), Some(verb), "{words:?}");
    }
    for other in [&["pane", "move"][..], &["agent", "send", "a"], &["moves", "a"], &[]] {
        assert_eq!(verb_of(&strings(other)), None, "{other:?}");
    }
}

#[test]
fn teleport_is_move_word_for_word() {
    for tail in [
        &["chat", "--to", "auto"][..],
        &["a", "b", "--machine", "build-box", "--after-turn", "--dry-run"],
        &["chat", "--to=here", "--from", "build-box", "--cwd", "/srv/w"],
        &["--all-idle", "--to", "auto", "--carry-changes"],
    ] {
        let mut moved = vec!["move"];
        moved.extend(tail);
        let mut teleported = vec!["teleport"];
        teleported.extend(tail);
        let mut agent = vec!["agent", "move"];
        agent.extend(tail);
        let want = request(&moved).expect("move parses");
        assert_eq!(request(&teleported).expect("teleport parses"), want, "{tail:?}");
        assert_eq!(request(&agent).expect("agent move parses"), want, "{tail:?}");
    }
}

#[test]
fn evacuate_selects_every_idle_session_and_goes_auto_by_default() {
    let all = request(&["evacuate"]).unwrap();
    assert_eq!(
        all,
        MoveRequest { sessions: vec![], machine: "auto".into(), all_idle: true, options: vec![] }
    );
    assert_eq!(
        acpmux_words(all),
        strings(&["session", "move", "--machine", "auto", "--all-idle", "--json"])
    );
    let named = request(&["evacuate", "chat", "--dry-run"]).unwrap();
    assert_eq!(named.sessions, vec!["chat"]);
    assert!(!named.all_idle);
    assert_eq!(named.machine, "auto");
    let there = request(&["evacuate", "--to", "build-box", "--after-turn"]).unwrap();
    assert_eq!(there.machine, "build-box");
    assert!(there.all_idle);
    assert_eq!(there.options, vec!["--after-turn"]);
}

#[test]
fn move_needs_a_target_and_a_session() {
    assert!(request(&["move", "chat"]).unwrap_err().contains("--to"));
    assert!(request(&["teleport", "--to", "auto"]).unwrap_err().contains("SESSION"));
    assert!(request(&["move", "a", "--all-idle", "--to", "auto"]).is_err());
    assert!(request(&["move", "a", "--to"]).is_err());
    // `cloud` is the app's Move to Cloud now (agent_move_cloud.rs), not a refusal.
    assert_eq!(request(&["move", "a", "--to", "cloud"]).unwrap().machine, "cloud");
    assert_eq!(
        request(&["move", "a", "--to", "Cloud", "--timings"]).unwrap().options,
        ["--timings"]
    );
    assert!(request(&["move", "a", "--to", "auto", "--bogus-thing"]).is_err());
}

#[test]
fn to_machine_and_host_name_the_same_target() {
    let want = request(&["move", "chat", "--to", "build-box"]).unwrap();
    for words in [
        &["move", "chat", "--machine", "build-box"][..],
        &["move", "--machine=build-box", "chat"],
        &["move", "chat", "--host", "build-box"],
        &["move", "chat", "--to=build-box"],
        &["--machine", "build-box", "move", "chat"],
    ] {
        assert_eq!(request(words).unwrap(), want, "{words:?}");
    }
    assert_eq!(request(&["move", "chat", "--to", "here"]).unwrap().machine, "local");
    assert_eq!(request(&["move", "chat", "--to", "AUTO"]).unwrap().machine, "auto");
}

#[test]
fn forwards_every_move_option_to_acpmux_in_order() {
    let request = request(&[
        "move",
        "chat",
        "--interrupt",
        "--cwd",
        "/tmp/chat",
        "--from",
        "mini",
        "--dry-run",
        "--to",
        "gcp-3",
    ])
    .unwrap();
    assert_eq!(
        acpmux_words(request),
        strings(&[
            "session",
            "move",
            "chat",
            "--machine",
            "gcp-3",
            "--interrupt",
            "--cwd",
            "/tmp/chat",
            "--from",
            "mini",
            "--dry-run",
            "--json",
        ])
    );
}

#[test]
fn a_close_misspelling_means_the_option() {
    for (typed, meant) in [
        ("--dryrun", "--dry-run"),
        ("--dry_run", "--dry-run"),
        ("--Dry-Run", "--dry-run"),
        ("--dry-rn", "--dry-run"),
        ("--afterturn", "--after-turn"),
        ("--after-trun", "--after-turn"),
        ("--leave-drity", "--leave-dirty"),
        ("--carry-change", "--carry-changes"),
        ("--machne", "--to"),
        ("--all", "--all-idle"),
        ("--to", "--to"),
    ] {
        assert_eq!(canonical(typed), Some(meant), "{typed}");
    }
    for unknown in ["--json-ish", "--x", "--zzzzzzzz"] {
        assert_eq!(canonical(unknown), None, "{unknown}");
    }
    assert_eq!(
        request(&["move", "chat", "--to", "auto", "--dryrun"]).unwrap().options,
        vec!["--dry-run"]
    );
}

#[test]
fn each_name_prints_its_own_help_naming_the_others() {
    for verb in [Verb::Move, Verb::Teleport, Verb::Evacuate] {
        let text = help(verb);
        assert!(text.starts_with(&format!("cmux {}:", verb.word())), "{text}");
        for name in ["cmux move", "cmux teleport", "cmux evacuate"] {
            assert!(text.contains(name), "{} help lacks {name}", verb.word());
        }
        for option in ["--to MACHINE|auto|here", "--machine", "--dry-run", "--after-turn", "--cwd"]
        {
            assert!(text.contains(option), "{} help lacks {option}", verb.word());
        }
        assert!(text.contains("EXAMPLES"), "{text}");
    }
    assert!(help(Verb::Teleport).contains("the same verb as `cmux move`"));
    assert!(help(Verb::Evacuate).contains("`--to auto`"));
}

#[test]
fn global_scan_keeps_multiple_sessions_before_move_switches() {
    let args = strings(&[
        "--json",
        "agent",
        "move",
        "first",
        "second",
        "--interrupt",
        "--machine",
        "auto",
    ]);
    let (global, command) = super::super::parse_globals(&args).expect("globals parse");
    assert!(matches!(global.output, super::super::OutputMode::Json));
    assert_eq!(global.machine.as_deref(), Some("auto"));
    assert_eq!(command, vec!["agent", "move", "first", "second", "--interrupt"]);
}
