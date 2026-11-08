use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn request(words: &[&str]) -> Request {
    match parse(&strings(words), || Ok("from stdin".to_owned())) {
        Ok(Parsed::Run(request)) => request,
        other => panic!("{words:?}: {other:?}"),
    }
}

#[test]
fn parse_takes_the_prompt_and_defaults_to_claude_on_a_new_machine() {
    let parsed = request(&["--prompt", "hi there"]);
    assert_eq!(
        parsed,
        Request {
            prompt: Some("hi there".into()),
            agent: "claude".into(),
            cwd: None,
            environment: None,
            machine: Machine::New,
            wait: false,
            timeout: Duration::from_secs(900),
        }
    );
    let parsed = request(&[
        "--prompt=go",
        "--agent",
        "codex",
        "--cwd",
        "/home/cmux/work",
        "--name",
        "dev",
        "--wait",
        "--timeout",
        "60",
    ]);
    assert_eq!(parsed.machine, Machine::Named("dev".into()));
    assert_eq!(parsed.agent, "codex");
    assert_eq!(parsed.cwd.as_deref(), Some("/home/cmux/work"));
    assert!(parsed.wait);
    assert_eq!(parsed.timeout, Duration::from_secs(60));
    assert_eq!(
        request(&["--target", "machine:vm-1", "-p", "x"]).machine,
        Machine::Target("vm-1".into())
    );
    assert_eq!(request(&["--prompt", "-"]).prompt.as_deref(), Some("from stdin"));
    // After `--`, the prompt is text: an output flag or `-` is what it says.
    assert_eq!(request(&["--wait", "--", "--json"]).prompt.as_deref(), Some("--json"));
    assert_eq!(request(&["--", "-"]).prompt.as_deref(), Some("-"));
}

/// `cmux cloud start-chat -- --json` (cmuxterm-hq#7487 item 4): the global scan and the output
/// lift leave `-- --json` to the parser, whose prompt it is.
#[test]
fn an_output_flag_after_the_separator_is_the_prompt() {
    for typed in [&["--"][..], &["--wait", "--"], &["--no-wait", "--"]] {
        let mut args = vec!["cloud", "start-chat"];
        args.extend_from_slice(typed);
        args.push("--json");
        let (mut global, command) = super::super::parse_globals(&strings(&args)).ok().unwrap();
        let words = lift_output(&command[2..], &mut global.output);
        assert_eq!(global.output, OutputMode::Human, "{args:?}");
        assert!(
            matches!(
                parse(&words, || Ok(String::new())),
                Ok(Parsed::Run(run)) if run.prompt.as_deref() == Some("--json")
            ),
            "{args:?}: {words:?}"
        );
    }
}

#[test]
fn parse_refuses_what_start_session_would() {
    for words in [
        vec!["--prompt", ""],
        vec!["--prompt", "  "],
        vec!["--prompt", "x", "--cwd", "relative"],
        vec!["--prompt", "x", "--agent", "Claude Code"],
        vec!["--prompt", "x", "--name", "a", "--target", "machine:b"],
        vec!["--prompt", "x", "--timeout", "soon"],
        vec!["--prompt", "x", "--bogus"],
        vec!["--prompt"],
        // A Cloud machine's agents use its model route: no login flag to pass one.
        vec!["--prompt", "x", "--login", "pass"],
        vec!["--prompt", "x", "--login", "none"],
        vec!["--prompt", "x", "--environment", " "],
        vec!["--prompt", "x", "--environment"],
        vec!["--environment", "env_1", "--target", "machine:vm-1"],
        vec!["--prompt", "x", "--", "y"],
        vec!["--", "two", "words"],
        vec!["--"],
    ] {
        assert!(parse(&strings(&words), || Ok(String::new())).is_err(), "{words:?}");
    }
    assert_eq!(parse(&strings(&["--help"]), || Ok(String::new())), Ok(Parsed::Help));
}

/// Leo (2026-11-06): "Like with an initial ... prompts. Or not?": with no --prompt the command starts the chat
/// and sends nothing. An empty --prompt is still a mistake, not "no prompt".
#[test]
fn parse_takes_no_prompt() {
    for words in [vec![], vec!["--name", "dev"], vec!["--wait"]] {
        assert!(
            matches!(parse(&strings(&words), || Ok(String::new())), Ok(Parsed::Run(_))),
            "{words:?}"
        );
    }
    assert!(parse(&strings(&["--prompt", ""]), || Ok(String::new())).is_err());
    assert!(parse(&strings(&["--prompt", "-"]), || Ok(" \n".to_owned())).is_err());
    assert_eq!(
        again_command(&request(&["--agent", "codex"]), &Machine::Named("chat-1".into())),
        "cmux cloud start-chat --name chat-1 --agent codex --json"
    );
}

/// Leo (2026-11-06): "Like with a ... environment": `--environment` takes an environment's id or its name, for a
/// new machine only.
#[test]
fn parse_takes_an_environment_for_a_new_machine() {
    for word in ["env_abc123", "python-dev"] {
        assert_eq!(request(&["--environment", word]).environment.as_deref(), Some(word));
    }
    assert_eq!(request(&["--environment=py", "--name", "n"]).environment.as_deref(), Some("py"));
    let refused =
        parse(&strings(&["--environment", "py", "--target", "machine:vm-1"]), || Ok(String::new()));
    assert!(refused.unwrap_err().0.contains("--target"));
    // The again command of a machine already made names it, so it leaves the environment out.
    let asked = request(&["--environment", "py", "--prompt", "x"]);
    assert_eq!(
        again_command(&asked, &Machine::Target("vm-1".into())),
        "cmux cloud start-chat --target machine:vm-1 --prompt TEXT --json"
    );
    assert_eq!(
        again_command(&asked, &Machine::New),
        "cmux cloud start-chat --environment py --prompt TEXT --json"
    );
}

#[test]
fn step_result_reads_the_app_answer_or_its_error() {
    let ok = Ran { code: 0, stdout: r#"{"action":"x","result":{"a":1}}"#.into(), ..Ran::default() };
    assert_eq!(step_result(&ok), Ok(json!({"a": 1})));
    let refused = Ran {
        code: 1,
        stdout: String::new(),
        stderr: "{\"code\":\"app.unreachable\",\"message\":\"no app\"}\n".into(),
    };
    assert_eq!(step_result(&refused).unwrap_err()["code"], "app.unreachable");
    let plain = Ran { code: 1, stdout: String::new(), stderr: "boom\n".into() };
    assert_eq!(step_result(&plain).unwrap_err(), json!({"code": "step.failed", "message": "boom"}));
}

#[test]
fn sections_split_the_scripts_output() {
    let out = "@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n";
    let got = sections(out);
    assert_eq!(got["history"], "{\"turns\":[]}");
    assert_eq!(got["send"], "delivery-1");
    assert_eq!(got["exit"], "0");
}

#[test]
fn the_reply_is_the_newest_of_acp_last() {
    let last = r#"{"sessionId":"s","replies":["older","The answer is 4."]}"#.to_owned();
    assert_eq!(reply(Some(&last)).as_deref(), Some("The answer is 4."));
    assert_eq!(reply(Some(&"not json".to_owned())), None);
    let history = r#"{"turns":[{"seq":7,"status":"completed","endedAt":10}]}"#.to_owned();
    let turn = last_turn(Some(&history)).unwrap();
    assert_eq!((turn.seq, turn.ended, turn.failed()), (7, true, false));
    let running = r#"{"turns":[{"seq":9,"status":"running"}]}"#.to_owned();
    assert!(!last_turn(Some(&running)).unwrap().ended);
    let failed = r#"{"turns":[{"seq":9,"status":"failed","endedAt":3}]}"#.to_owned();
    assert!(last_turn(Some(&failed)).unwrap().failed());
}

#[test]
fn again_command_quotes_every_word() {
    // The prompt is never repeated in the command (it may be private): TEXT stands for it.
    let mut asked = request(&["--prompt", "it's done", "--cwd", "/a b", "--wait"]);
    asked.agent = "codex".into();
    assert_eq!(
        again_command(&asked, &Machine::Named("chat-1".into())),
        "cmux cloud start-chat --name chat-1 --agent codex --cwd '/a b' --prompt TEXT --wait --json"
    );
    let asked = request(&["--prompt", "x"]);
    assert_eq!(
        again_command(&asked, &Machine::Target("vm-1".into())),
        "cmux cloud start-chat --target machine:vm-1 --prompt TEXT --json"
    );
}

/// Neither step is told about a login: the machine reaches models through its edge, and the app copies none.
#[test]
fn no_login_goes_to_start_session_or_the_relay_chat() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
    ]);
    let Outcome::Done(_) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"])) else {
        panic!()
    };
    assert_eq!(
        fake.ran[1],
        strings(&["cloud", "start-session", "--name", "dev", "--agent", "claude", "--json"])
    );
    let mut fake = Fake::new(vec![signed_in(), made(), relayed(json!({"session_id": "r-1"}))]);
    let Outcome::Done(_) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(&fake.ran[2][..2], &strings(&["cloud", "relay-chat"]));
    assert!(!fake.ran.iter().flatten().any(|word| word == "--login"), "{:?}", fake.ran);
}

/// A fake app: answers each step from a queue and records what ran.
struct Fake {
    answers: VecDeque<Ran>,
    ran: Vec<Vec<String>>,
    clock: Instant,
    paused: Duration,
    /// How long a verb (`cloud VERB`) takes, for one that takes longer than the 5 s every other step takes.
    costs: Vec<(&'static str, Duration)>,
    /// How long the step at this index of `ran` takes, before `costs`.
    slow: Vec<(usize, Duration)>,
}

impl Fake {
    fn new(answers: Vec<Ran>) -> Self {
        Self {
            answers: answers.into(),
            ran: Vec::new(),
            clock: Instant::now(),
            paused: Duration::ZERO,
            costs: Vec::new(),
            slow: Vec::new(),
        }
    }
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        let index = self.ran.len();
        self.ran.push(args.to_vec());
        // Each step takes a few seconds of the wait, or what `slow` says for it, or `costs` for its verb.
        let verb = args.get(1).map(String::as_str);
        let cost = self.slow.iter().find(|(at, _)| *at == index).map(|(_, cost)| *cost);
        let cost = cost.or_else(|| {
            self.costs.iter().find(|(name, _)| Some(*name) == verb).map(|(_, cost)| *cost)
        });
        self.clock += cost.unwrap_or(Duration::from_secs(5));
        self.answers.pop_front().expect("an answer for every step")
    }
    fn pause(&mut self, duration: Duration) {
        self.paused += duration;
        self.clock += duration;
    }
    fn now(&mut self) -> Instant {
        self.clock
    }
    fn fresh_name(&mut self) -> String {
        "chat-fresh".into()
    }
    fn prompt_id(&mut self) -> String {
        "p-1".into()
    }
}

fn ok(result: Value) -> Ran {
    Ran { code: 0, stdout: json!({"result": result}).to_string(), ..Ran::default() }
}

fn exec_out(stdout: &str) -> Ran {
    ok(json!({"exit_code": 0, "stdout": stdout, "stderr": ""}))
}

fn signed_in() -> Ran {
    ok(json!({"account": {"signed_in": true}, "machines": [{"title": "dev"}]}))
}

/// `cloud new-machine`'s answer: the new machine.
fn made() -> Ran {
    ok(
        json!({"machine_id": "vm-1", "title": "chat-fresh", "status": "running", "target": "machine:vm-1"}),
    )
}

/// An app without `cloud relay-chat`: the link path runs.
fn no_relay() -> Ran {
    Ran {
        code: 1,
        stderr: json!({"code": "action.not_found", "message": "unknown action"}).to_string(),
        ..Ran::default()
    }
}

fn started() -> Ran {
    ok(json!({"machine_id": "vm-1", "machine_name": "chat-fresh", "session_id": "sess-1",
              "host": "registry:x", "agent": "claude", "workspace_id": "ws_1",
              "tab_id": "tab-1", "target": "machine:vm-1"}))
}

#[test]
fn a_new_chat_starts_on_a_new_machine_sends_waits_and_answers_the_reply() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        no_relay(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
        // Not started yet: the wait answered at once.
        exec_out("@@wait 0\n@@history\n{\"turns\":[]}\n@@last\n{\"replies\":[]}\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"4\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = request(&["--prompt", "What is 2+2?", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    for (key, value) in [
        ("machine_id", "vm-1"),
        ("session_id", "sess-1"),
        ("workspace_id", "ws_1"),
        ("tab_id", "tab-1"),
        ("target", "machine:vm-1"),
    ] {
        assert_eq!(answer[key], value, "{key}");
    }
    assert_eq!(answer["sent"], true);
    assert_eq!(answer["new_machine"], true, "its own new-machine made vm-1");
    assert_eq!(answer["placement"], "vm:vm-1", "the answer names where it ran");
    assert_eq!(answer["follow_up"]["send"], json!("cmux chat send sess-1 'PROMPT' --wait"));
    assert_eq!(fake.ran[1], strings(&["cloud", "new-machine", "--name", "chat-fresh", "--json"]));
    assert_eq!(&fake.ran[2][..4], &strings(&["cloud", "relay-chat", "--target", "machine:vm-1"]));
    // The app had no relay chat: the link path, on the machine just made.
    assert_eq!(
        fake.ran[3],
        strings(&[
            "cloud",
            "start-session",
            "--target",
            "machine:vm-1",
            "--agent",
            "claude",
            "--json"
        ])
    );
    let send = &fake.ran[4];
    assert_eq!(&send[..4], &strings(&["cloud", "exec", "--target", "machine:vm-1"]));
    assert!(send[5].contains("printf '%s' 'What is 2+2?' | \"$c\" acp send --no-wait sess-1 -"));
    assert!(send[5].starts_with(GUEST_PRELUDE));
    assert_eq!(fake.paused, Duration::from_secs(2));
}

#[test]
fn the_answer_times_each_step_it_ran() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"]))
    else {
        panic!()
    };
    // Each fake step takes 5 s.
    let stages = &answer["stages_ms"];
    assert_eq!(stages["total"], 15_000);
    assert_eq!(stages["more_steps"], 0);
    let steps: Vec<(&str, u64, u64)> = stages["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (s["step"].as_str().unwrap(), s["at"].as_u64().unwrap(), s["ms"].as_u64().unwrap())
        })
        .collect();
    assert_eq!(
        steps,
        [
            ("cloud list-machines", 0, 5_000),
            ("cloud start-session", 5_000, 5_000),
            ("cloud exec", 10_000, 5_000)
        ]
    );
}

#[test]
fn a_failure_carries_the_steps_it_ran() {
    let mut fake = Fake::new(vec![ok(json!({"account": {"signed_in": false}, "machines": []}))]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!(error["details"]["stages_ms"]["steps"][0]["step"], "cloud list-machines");
}

/// A run that made its machine and then failed still names it, so its caller can delete what it
/// made (the start matrix, `cmux chat --on vm:new`); a failure on a machine it did not make does not.
#[test]
fn a_failure_after_making_the_machine_names_it() {
    let refused = || Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": "Machine didn't connect"}).to_string(),
        ..Ran::default()
    };
    // `--wait` makes the machine first (`cloud new-machine`), then starts the session there.
    let mut fake = Fake::new(vec![signed_in(), made(), no_relay(), refused()]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(fake.ran[1], strings(&["cloud", "new-machine", "--name", "chat-fresh", "--json"]));
    assert_eq!(error["details"]["machine_id"], "vm-1");
    assert_eq!(error["details"]["new_machine"], true);

    let mut fake = Fake::new(vec![signed_in(), refused()]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--prompt", "x", "--target", "machine:vm-9"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert!(error["details"].get("new_machine").is_none(), "{error}");
}

#[test]
fn without_wait_it_answers_once_the_prompt_is_sent() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"]))
    else {
        panic!()
    };
    assert_eq!(answer["delivery"], "delivery-1");
    assert!(answer.get("reply").is_none());
    assert!(answer.get("new_machine").is_none(), "a named machine may be one that was there");
    assert_eq!(fake.ran[1][3], "dev");
    assert_eq!(fake.ran.len(), 3);
}

/// No prompt: start-session alone, with or without --wait (there is no turn to wait on). No relay chat, no
/// new-machine first, no exec: the answer is the chat's ids, how long it took to be ready, and how to send
/// the first message.
#[test]
fn without_a_prompt_it_starts_the_chat_and_sends_nothing() {
    for wait in [false, true] {
        let mut fake = Fake::new(vec![signed_in(), started()]);
        let mut words = vec![];
        if wait {
            words.push("--wait");
        }
        let Outcome::Done(answer) = run(&mut fake, &request(&words)) else {
            panic!("{:?}", fake.ran)
        };
        assert_eq!(
            fake.ran,
            vec![
                strings(&["cloud", "list-machines", "--json"]),
                strings(&[
                    "cloud",
                    "start-session",
                    "--name",
                    "chat-fresh",
                    "--agent",
                    "claude",
                    "--json"
                ]),
            ]
        );
        for (key, value) in [
            ("machine_id", "vm-1"),
            ("machine_name", "chat-fresh"),
            ("target", "machine:vm-1"),
            ("session_id", "sess-1"),
            ("workspace_id", "ws_1"),
            ("tab_id", "tab-1"),
            ("agent", "claude"),
        ] {
            assert_eq!(answer[key], value, "{key}");
        }
        assert_eq!(answer["sent"], false);
        // Two steps of the fake's five seconds each, from the command's start.
        assert_eq!(answer["ready_ms"], 10_000);
        assert!(answer.get("reply").is_none());
        // The first message, by the chat's session (#37477's `cmux chat send`).
        assert_eq!(answer["follow_up"]["send"], json!("cmux chat send sess-1 'PROMPT' --wait"));
    }
}

/// With `--environment` the chat's machine is made first, in that environment (`cloud new-machine --name
/// --environment`, a fresh name without `--name`), and the chat starts on it: over the link without --wait or without a prompt, over the
/// relay with both.
#[test]
fn an_environment_makes_the_chats_machine_in_it_first() {
    let new_machine = |extra: &[&str]| {
        let mut words = strings(&["cloud", "new-machine"]);
        words.extend(strings(extra));
        words.push("--json".to_owned());
        words
    };
    let on_vm_1 = strings(&[
        "cloud",
        "start-session",
        "--target",
        "machine:vm-1",
        "--agent",
        "claude",
        "--json",
    ]);
    // No --wait: new-machine, then start-session on it, then the send.
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
    ]);
    let asked = request(&["--prompt", "x", "--environment", "python-dev"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(fake.ran[1], new_machine(&["--name", "chat-fresh", "--environment", "python-dev"]));
    assert_eq!(fake.ran[2], on_vm_1);
    assert_eq!(fake.ran.len(), 4);
    // No prompt: new-machine and start-session only.
    let mut fake = Fake::new(vec![signed_in(), made(), started()]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--environment", "env_1", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["sent"], false);
    assert_eq!(fake.ran[1], new_machine(&["--name", "chat-fresh", "--environment", "env_1"]));
    assert_eq!(fake.ran[2], on_vm_1);
    assert_eq!(fake.ran.len(), 3);
    // --wait with a prompt: the relay chat on the machine made in the environment, and no second machine.
    let mut fake = Fake::new(vec![signed_in(), made(), relayed(json!({"session_id": "r-1"}))]);
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait"]);
    let Outcome::Done(_) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.ran[1], new_machine(&["--name", "chat-fresh", "--environment", "env_1"]));
    assert_eq!(&fake.ran[2][..4], &strings(&["cloud", "relay-chat", "--target", "machine:vm-1"]));
    assert_eq!(fake.ran.len(), 3);
    // --name of no machine yet: that name, in the environment.
    let mut fake = Fake::new(vec![signed_in(), made(), started()]);
    let asked = request(&["--name", "py-1", "--environment", "env_1"]);
    let Outcome::Done(_) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.ran[1], new_machine(&["--name", "py-1", "--environment", "env_1"]));
}

#[test]
fn an_environment_for_a_machine_that_exists_or_is_still_being_made_says_so() {
    // `dev` exists already: its environment is set, so nothing runs.
    let mut fake = Fake::new(vec![signed_in()]);
    let asked = request(&["--name", "dev", "--environment", "env_1", "--prompt", "x"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("usage.invalid"), 2));
    assert_eq!(fake.ran.len(), 1);
    // The app's create answered pending: no second machine, and how to go on.
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "name": "chat-9", "status": "creating"})),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--environment", "env_1"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(fake.ran.len(), 2);
    // The app refused the environment (an unknown name): its refusal is the answer.
    let refused = Ran {
        code: 1,
        stderr: json!({"code": "invalid_params", "message": "No Cloud environment is named nope."})
            .to_string(),
        ..Ran::default()
    };
    let mut fake = Fake::new(vec![signed_in(), refused]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--environment", "nope"])) else {
        panic!()
    };
    assert!(error["message"].as_str().unwrap().contains("nope"));
    assert_eq!(fake.ran.len(), 2);
}

/// `--environment` with `--name` makes a machine of that name only when the app's list says none exists
/// and none is on its way: a list the app has not loaded yet says nothing, and a create of that name still
/// in flight (a first run that answered pending, or another start) is joined as pending or refused, never
/// made a second time.
#[test]
fn an_environment_never_makes_a_second_machine_of_its_name() {
    let asked = request(&["--name", "py-1", "--environment", "env_1", "--prompt", "x"]);
    // The list is not loaded: no create.
    let mut fake = Fake::new(vec![ok(
        json!({"account": {"signed_in": true}, "loaded": false, "machines": [], "creating": []}),
    )]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.list_unread"), 75));
    assert_eq!(error["details"]["machine_name"], "py-1");
    assert_eq!(fake.ran.len(), 1, "no new-machine on a list that says nothing");
    // A create of that name is on its way: pending, and no second create.
    let mut fake = Fake::new(vec![ok(json!({"account": {"signed_in": true}, "loaded": true,
        "machines": [{"title": "dev"}], "creating": [{"name": "py-1", "status": "creating"}]}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert!(error["message"].as_str().unwrap().contains("py-1"));
    assert_eq!(fake.ran.len(), 1);
    // Its create failed and waits in cmux for Retry: refused, not made again beside it.
    let mut fake =
        Fake::new(vec![ok(json!({"account": {"signed_in": true}, "loaded": true, "machines": [],
        "creating": [{"name": "py-1", "status": "failed", "reason": "quota"}]}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1));
    assert!(error["message"].as_str().unwrap().contains("quota"));
    assert_eq!(fake.ran.len(), 1);
    // Another name's create on its way, on a loaded list: this one is made.
    let mut fake = Fake::new(vec![
        ok(json!({"account": {"signed_in": true}, "loaded": true, "machines": [],
            "creating": [{"name": "other", "status": "creating"}]})),
        made(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
    ]);
    let Outcome::Done(_) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(&fake.ran[1][..2], &strings(&["cloud", "new-machine"]));
}

#[test]
fn a_signed_out_app_says_how_to_sign_in() {
    let mut fake = Fake::new(vec![ok(json!({"account": {"signed_in": false}, "machines": []}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.signed_out"), 1));
    assert!(error["message"].as_str().unwrap().contains("cmux login"));
}

#[test]
fn a_pending_machine_names_the_command_that_waits_on() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_name": "chat-fresh", "text": "still starting"})),
        ok(
            json!({"machines": [{"title": "chat-fresh", "machine_id": "vm-9", "status": "provisioning"}]}),
        ),
    ]);
    // A name no machine has: `start-session --name` makes it, so no relay chat first.
    let asked = request(&["--prompt", "x", "--name", "chat-fresh", "--wait"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(
        error["details"]["again"],
        "cmux cloud start-chat --name chat-fresh --prompt TEXT --wait --json"
    );
    assert_eq!(error["details"]["machine_id"], "vm-9");
    assert_eq!(error["details"]["stage"]["status"], "provisioning");
    assert!(error["message"].as_str().unwrap().contains("stuck at: the machine is provisioning"));
    assert_eq!(fake.ran.last().unwrap(), &strings(&["cloud", "list-machines", "--json"]));
}

#[test]
fn a_pending_start_on_a_running_machine_names_the_link_wait() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_id": "vm-9", "text": "still starting"})),
        ok(
            json!({"machines": [{"title": "chat-fresh", "machine_id": "vm-9", "status": "running"}]}),
        ),
    ]);
    let Outcome::Failed { error, exit } =
        run(&mut fake, &request(&["--prompt", "x", "--target", "machine:vm-9"]))
    else {
        panic!()
    };
    assert_eq!(exit, 75);
    assert!(
        error["message"].as_str().unwrap().contains("waiting for the link to its agent daemon")
    );
}

#[test]
fn a_pending_start_on_a_machine_not_listed_yet_says_so() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_name": "chat-fresh", "text": "still starting"})),
        ok(
            json!({"machines": [], "creating": [{"creation_id": "c-1", "name": "chat-fresh", "status": "creating"}]}),
        ),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert!(error["message"].as_str().unwrap().contains("the create request is still in flight"));
    assert_eq!(error["details"]["stage"]["listed"], false);
}

#[test]
fn a_pending_start_whose_machine_failed_is_final() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_name": "chat-fresh", "text": "still starting"})),
        ok(
            json!({"machines": [], "creating": [{"creation_id": "c-1", "name": "chat-fresh", "status": "failed",
                                                "reason": "snapshot capture is still being confirmed"}]}),
        ),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1));
    assert!(
        error["message"].as_str().unwrap().contains("snapshot capture is still being confirmed")
    );
}

#[test]
fn a_pending_start_whose_list_fails_still_answers_pending() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_name": "chat-fresh", "text": "still starting"})),
        Ran {
            code: 1,
            stderr: "{\"code\":\"app.down\",\"message\":\"no app\"}".into(),
            ..Ran::default()
        },
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!(exit, 75);
    assert!(error["message"].as_str().unwrap().contains("machine list could not be read"));
}

#[test]
fn a_pending_start_whose_listed_machine_failed_is_final() {
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_id": "vm-9", "text": "still starting"})),
        ok(
            json!({"machines": [{"title": "chat-fresh", "machine_id": "vm-9", "status": "failed"}]}),
        ),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1));
    assert_eq!(error["details"]["machine_id"], "vm-9");
}

#[test]
fn a_permission_question_and_a_timeout_say_what_to_do() {
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let running = "@@history\n{\"turns\":[{\"seq\":2,\"status\":\"running\"}]}\n@@last\n{}\n";
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        no_relay(),
        started(),
        sent(),
        exec_out(&format!("@@wait 2\n{running}")),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.permission_waiting"), 2));
    assert_eq!(error["details"]["answer"]["session_id"], "sess-1");

    // A --timeout shorter than the relay's answer window goes the link way: 20 s of the 25 make the machine and
    // start the chat, so the wait has the 5 s left.
    let mut answers = vec![signed_in(), made(), started(), sent()];
    answers.extend((0..3).map(|_| exec_out(&format!("@@wait 3\n{running}"))));
    let mut fake = Fake::new(answers);
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "25"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert!(error["message"].as_str().unwrap().contains("acp wait sess-1"));
}

#[test]
fn a_send_the_machine_refused_keeps_the_chat_ids() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n\n@@send\nno such session\n@@exit 1\n"),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!(error["code"], "chat.send_failed");
    assert_eq!(error["details"]["answer"]["machine_id"], "vm-1");
}

#[test]
fn shell_quote_leaves_plain_words_and_quotes_the_rest() {
    assert_eq!(shell_quote("sess-1"), "sess-1");
    assert_eq!(shell_quote("a b"), "'a b'");
    assert_eq!(shell_quote(""), "''");
    assert_eq!(shell_quote("$(x)"), "'$(x)'");
}

#[test]
fn a_reply_that_cannot_be_read_is_an_error_not_an_empty_reply() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        no_relay(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"endedAt\":9}]}\n\
             @@last\nno such session\n@@lastexit 1\n",
        ),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!(error["code"], "chat.read_failed");
}

#[test]
fn each_wait_is_bounded_by_the_time_left() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":2,\"status\":\"running\"}]}\n";
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(running),
        exec_out(running),
    ]);
    // The list, the start and the send take 15 s of the 22, counted from the command's start.
    let asked =
        request(&["--prompt", "x", "--target", "machine:vm-1", "--wait", "--timeout", "22"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!() };
    assert_eq!(error["code"], "chat.wait_timeout");
    assert!(fake.ran[3][5].contains("acp wait sess-1 --timeout 7 "), "{:?}", fake.ran[3]);
    assert!(fake.ran[4][5].contains("acp wait sess-1 --timeout 2 "), "{:?}", fake.ran[4]);
    assert_eq!(fake.ran.len(), 5);
}

#[test]
fn output_flags_are_lifted_but_a_flag_value_stays() {
    let mut output = OutputMode::Human;
    let words = lift_output(&strings(&["--prompt", "--json", "--wait", "--json"]), &mut output);
    assert_eq!(words, strings(&["--prompt", "--json", "--wait"]));
    assert_eq!(output, OutputMode::Json);
    assert_eq!(request(&["--prompt", "--json", "--wait"]).prompt.as_deref(), Some("--json"));
}

#[test]
fn a_session_that_stops_answering_fails_at_once() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        no_relay(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out("@@wait 4\n@@history\nno such session\n@@last\n\n@@lastexit 1\n"),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!(error["code"], "chat.lost");
    assert_eq!(fake.ran.len(), 6);
}

/// A machine here: `cloud exec` runs its script with bash in a home of its own, whose
/// `~/.cmux/bin/cmux-tui` keeps what `acp send` reads; every other step answers from a queue.
/// `command_cap` refuses a longer command as the cmux API does (nothing of it runs).
struct Guest {
    home: tempfile::TempDir,
    command_cap: Option<usize>,
    answers: VecDeque<Ran>,
    execs: Vec<String>,
}

impl Guest {
    fn new(command_cap: Option<usize>) -> Self {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join(".cmux/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let tool = bin.join("cmux-tui");
        std::fs::write(
            &tool,
            "#!/bin/bash\n\
             case \"$2\" in\n\
             history) echo '{\"turns\":[]}' ;;\n\
             send) cat > \"$HOME/received\"; echo delivery-1 ;;\n\
             *) exit 9 ;;\n\
             esac\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { home, command_cap, answers: vec![signed_in(), started()].into(), execs: Vec::new() }
    }

    fn received(&self) -> Option<Vec<u8>> {
        std::fs::read(self.home.path().join("received")).ok()
    }

    fn prompts_left(&self) -> usize {
        std::fs::read_dir(self.home.path().join(".cmux/prompts")).map_or(0, |dir| dir.count())
    }
}

impl Runner for Guest {
    fn cmux(&mut self, args: &[String]) -> Ran {
        if args.get(1).map(String::as_str) != Some("exec") {
            return self.answers.pop_front().expect("an answer for every step");
        }
        let script = args.get(5).cloned().unwrap_or_default();
        self.execs.push(script.clone());
        if self.command_cap.is_some_and(|cap| script.len() > cap) {
            return Ran {
                code: 1,
                stdout: String::new(),
                stderr: json!({"code": "vm_command_too_large",
                               "message": "the command is over 65536 bytes"})
                .to_string(),
            };
        }
        // The script from a file, as no single argument here may be that long.
        let file = self.home.path().join("script.sh");
        std::fs::write(&file, &script).unwrap();
        let out = std::process::Command::new("bash")
            .arg(&file)
            .env("HOME", self.home.path())
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        exec_out(&String::from_utf8_lossy(&out.stdout))
    }
    fn pause(&mut self, _duration: Duration) {}
    fn now(&mut self) -> Instant {
        Instant::now()
    }
    fn fresh_name(&mut self) -> String {
        "chat-fresh".into()
    }
    fn prompt_id(&mut self) -> String {
        "p-1".into()
    }
}

/// A prompt of several MiB, every byte value a prompt can hold (multi-byte text, quotes, `$`,
/// newlines), not a repeat a piece boundary could hide in.
fn big_prompt(bytes: usize) -> String {
    let words = ["naïve ", "'quoted' ", "$HOME ", "`tick` ", "日本語 ", "\\back ", "line\n", "🙂 "];
    let mut text = String::with_capacity(bytes + 16);
    let mut n: u64 = 7;
    while text.len() < bytes {
        n = n.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        text.push_str(words[(n >> 61) as usize]);
        text.push_str(&(n % 100_000).to_string());
    }
    text
}

#[test]
fn a_prompt_of_several_mib_reaches_the_chat_whole() {
    let prompt = big_prompt(5 * 1024 * 1024);
    let mut machine = Guest::new(None);
    let asked = request(&["--prompt", prompt.as_str(), "--name", "dev"]);
    let Outcome::Done(answer) = run(&mut machine, &asked) else { panic!("not sent") };
    assert_eq!(answer["sent"], true);
    assert_eq!(answer["delivery"], "delivery-1");
    assert_eq!(machine.received().as_deref(), Some(prompt.as_bytes()), "the prompt, byte for byte");
    // Large pieces, then the send; no command held the whole prompt.
    let pieces = prompt.len().div_ceil(PROMPT_PIECE_BYTES);
    assert_eq!(machine.execs.len(), pieces + 1);
    assert!(machine.execs.iter().all(|script| script.len() < 600 * 1024));
    assert_eq!(machine.prompts_left(), 0, "the prompt file is removed after the send");
}

#[test]
fn a_route_that_takes_64_kib_commands_gets_small_pieces_and_the_whole_prompt() {
    let prompt = big_prompt(3 * 1024 * 1024 + 17);
    let mut machine = Guest::new(Some(64 * 1024));
    let asked = request(&["--prompt", prompt.as_str(), "--name", "dev"]);
    let Outcome::Done(answer) = run(&mut machine, &asked) else { panic!("not sent") };
    assert_eq!(answer["sent"], true);
    assert_eq!(machine.received().as_deref(), Some(prompt.as_bytes()));
    // One refused large piece (nothing of it ran), then small ones.
    let refused = machine.execs.iter().filter(|script| script.len() > 64 * 1024).count();
    assert_eq!(refused, 1);
    assert_eq!(machine.execs.len(), 1 + prompt.len().div_ceil(SMALL_PROMPT_PIECE_BYTES) + 1);
    assert_eq!(machine.prompts_left(), 0);
}

#[test]
fn a_short_prompt_still_goes_inside_the_send() {
    let mut machine = Guest::new(Some(64 * 1024));
    let asked = request(&["--prompt", "What is 2+2? It's $5 `now`", "--name", "dev"]);
    let Outcome::Done(_) = run(&mut machine, &asked) else { panic!("not sent") };
    assert_eq!(machine.execs.len(), 1);
    assert_eq!(machine.received().as_deref(), Some(&b"What is 2+2? It's $5 `now`"[..]));
}

#[test]
fn a_prompt_the_machine_did_not_take_whole_fails_with_the_chat_ids() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        // The first piece landed short.
        exec_out("@@size 12\n"),
        // The cleanup.
        exec_out(""),
    ]);
    let prompt = "x".repeat(200 * 1024);
    let Outcome::Failed { error, exit } =
        run(&mut fake, &request(&["--prompt", prompt.as_str(), "--name", "dev"]))
    else {
        panic!()
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], "chat.send_failed");
    assert_eq!(error["details"]["answer"]["session_id"], "sess-1");
    assert!(fake.ran[3][5].contains("rm -f \"$f\""));
}

#[test]
fn a_send_refused_after_the_upload_removes_the_prompt_file() {
    let prompt = "x".repeat(200 * 1024);
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out(&format!("@@size {}\n", prompt.len())),
        // The send: refused before it started.
        Ran {
            code: 1,
            stdout: String::new(),
            stderr: json!({"code": "vm_busy", "message": "retry shortly"}).to_string(),
        },
        // The cleanup.
        exec_out(""),
    ]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--prompt", prompt.as_str(), "--name", "dev"]))
    else {
        panic!()
    };
    assert_eq!(error["code"], "chat.unreachable");
    assert_eq!(fake.ran.len(), 5);
    let upload = &fake.ran[2][5];
    let cleanup = &fake.ran[4][5];
    assert!(cleanup.ends_with("rm -f \"$f\""));
    // The same file the upload wrote.
    let file = |script: &str| {
        script.split("f=").nth(1).and_then(|s| s.split(';').next()).map(str::to_owned)
    };
    assert_eq!(file(cleanup), file(upload));
}

#[test]
fn a_send_with_no_answer_keeps_the_prompt_file_for_a_send_still_reading_it() {
    let prompt = "x".repeat(200 * 1024);
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out(&format!("@@size {}\n", prompt.len())),
        Ran {
            code: 1,
            stdout: String::new(),
            stderr: json!({"code": "vm_unavailable", "message": "the machine did not answer"})
                .to_string(),
        },
    ]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--prompt", prompt.as_str(), "--name", "dev"]))
    else {
        panic!()
    };
    assert_eq!(error["code"], "chat.unreachable");
    assert_eq!(fake.ran.len(), 4, "no cleanup exec");
}

/// The relay chat's answer for `cloud relay-chat --json`.
fn relayed(fields: Value) -> Ran {
    let mut answer = json!({"machine_id": "vm-1", "reply": "", "queued": false, "ended": true, "delivered": true});
    for (key, value) in fields.as_object().unwrap() {
        answer[key] = value.clone();
    }
    ok(answer)
}

#[test]
fn the_relay_answers_a_new_chat_with_no_link_to_the_machine() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        relayed(json!({"session_id": "relay-1", "reply": "4", "stop_reason": "end_turn",
                       "first_text_ms": 2100, "total_ms": 2500, "link_login_ms": 300, "sent_ms": 900,
                       "platform_stages_ms": {"socket": 700}})),
    ]);
    let asked = request(&["--prompt", "What is 2+2?", "--cwd", "/home/cmux/w", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["path"], "relay");
    assert_eq!(answer["session_id"], "relay-1");
    assert_eq!(answer["first_text_ms"], 2100);
    // The app's stage times pass on; one it did not report is left out.
    assert_eq!((&answer["link_login_ms"], &answer["sent_ms"]), (&json!(300), &json!(900)));
    assert_eq!(answer["platform_stages_ms"], json!({"socket": 700}));
    assert!(answer.get("queued_ms").is_none());
    assert_eq!(answer["stop_reason"], "end_turn");
    assert!(answer["follow_up"]["wait"].as_str().unwrap().contains("acp wait relay-1"));
    assert_eq!(
        fake.ran[2],
        strings(&[
            "cloud",
            "relay-chat",
            "--target",
            "machine:vm-1",
            "--agent",
            "claude",
            "--prompt",
            "What is 2+2?",
            "--cwd",
            "/home/cmux/w",
            "--prompt-id",
            "p-1",
            "--json",
        ])
    );
    assert_eq!(fake.ran.len(), 3);
}

#[test]
fn a_relay_turn_still_running_is_waited_on_in_its_session() {
    let mut fake = Fake::new(vec![
        ok(json!({"account": {"signed_in": true},
                  "machines": [{"title": "dev", "machine_id": "vm-7", "status": "running"}]})),
        relayed(json!({"session_id": "relay-1", "reply": "wor", "ended": false})),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"replies\":[\"working on it\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = request(&["--prompt", "x", "--name", "dev", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "working on it");
    assert_eq!(answer["machine_id"], "vm-7");
    assert_eq!(&fake.ran[1][..4], &strings(&["cloud", "relay-chat", "--target", "machine:vm-7"]));
    assert!(fake.ran[2][5].contains("acp wait relay-1"));
}

#[test]
fn a_relay_turn_that_stops_says_why_with_the_exit_code() {
    for (code, exit) in
        [("chat.permission_waiting", 2), ("cloud.relay.timeout", 3), ("chat.failed", 1)]
    {
        let mut fake = Fake::new(vec![
            signed_in(),
            relayed(json!({"session_id": "relay-1", "error_code": code, "error_message": "m"})),
        ]);
        let asked = request(&["--prompt", "x", "--target", "machine:vm-1", "--wait"]);
        let Outcome::Failed { error, exit: got } = run(&mut fake, &asked) else { panic!() };
        assert_eq!((error["code"].as_str(), got), (Some(code), exit));
        assert_eq!(error["details"]["answer"]["session_id"], "relay-1");
    }
}

#[test]
fn a_chat_the_machine_never_took_goes_the_link_path_once() {
    // An image without the relay: no session, so nothing ran there.
    let mut fake = Fake::new(vec![
        signed_in(),
        relayed(json!({"error_code": "cloud.relay.machine_offline", "error_message": "down",
                       "delivered": false})),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"endedAt\":9}]}\n\
             @@last\n{\"replies\":[\"ok\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = request(&["--prompt", "x", "--target", "machine:vm-1", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "ok");
    assert!(answer.get("path").is_none());
    assert_eq!(fake.ran[2][1], "start-session");
    // Cancelled by the app before the platform sent it: the same.
    let not_taken =
        json!({"error_code": "cloud.relay.not_taken", "delivered": false, "queued": true});
    let mut fake = Fake::new(vec![signed_in(), relayed(not_taken), no_relay()]);
    let _ = run(&mut fake, &asked);
    assert_eq!(fake.ran[2][1], "start-session");
}

#[test]
fn no_relay_chat_without_wait_for_a_big_prompt_or_a_machine_still_being_made() {
    let mut fake = Fake::new(vec![signed_in(), no_relay()]);
    let _ = run(&mut fake, &request(&["--prompt", "x", "--target", "machine:vm-1"]));
    assert_eq!(fake.ran[1][1], "start-session");

    let big = "y".repeat(RELAY_PROMPT_BYTES + 1);
    let mut fake = Fake::new(vec![signed_in(), no_relay()]);
    let _ =
        run(&mut fake, &request(&["--prompt", big.as_str(), "--target", "machine:vm-1", "--wait"]));
    assert_eq!(fake.ran[1][1], "start-session");

    // A create still pending at `--timeout` is the answer; nothing is sent. The one deadline counts from the
    // start: the list and the create take 10 s of it, one read of the list the rest.
    let mut fake = Fake::new(vec![signed_in(), creating(), still_creating("creating")]);
    let Outcome::Failed { error, exit } =
        run(&mut fake, &request(&["--prompt", "x", "--wait", "--timeout", "14"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(fake.ran.len(), 3);
}

/// `cloud new-machine`'s answer for a create slower than the app's own answer window.
fn creating() -> Ran {
    ok(json!({"pending": true, "status": "creating", "creation_id": "c-1"}))
}

/// `cloud list-machines` while create `c-1` is still on its way.
fn still_creating(status: &str) -> Ran {
    ok(json!({"account": {"signed_in": true}, "machines": [{"machine_id": "vm-0", "title": "dev"}],
              "creating": [{"creation_id": "c-1", "name": null, "status": status, "reason": "no capacity"}]}))
}

/// `--wait` covers a slow create: it reads the app's list until the create's machine is there, then chats on it.
#[test]
fn wait_covers_a_create_slower_than_the_apps_answer() {
    let up = ok(json!({"account": {"signed_in": true}, "creating": [],
                       "machines": [{"machine_id": "vm-0", "title": "dev"}, {"machine_id": "vm-1", "title": "chat-1"}]}));
    let listed = ok(
        json!({"account": {"signed_in": true}, "machines": [{"machine_id": "vm-0", "title": "dev"}]}),
    );
    let mut fake = Fake::new(vec![
        listed,
        creating(),
        still_creating("creating"),
        up,
        relayed(json!({"session_id": "relay-1", "reply": "4"})),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["new_machine"], true);
    assert_eq!(&fake.ran[4][..4], &strings(&["cloud", "relay-chat", "--target", "machine:vm-1"]));

    // A list between the create row and its machine (neither listed) is read past, not the answer.
    let gap = ok(json!({"account": {"signed_in": true}, "creating": [],
                        "machines": [{"machine_id": "vm-0", "title": "dev"}]}));
    let up = ok(json!({"account": {"signed_in": true}, "creating": [],
                       "machines": [{"machine_id": "vm-0", "title": "dev"}, {"machine_id": "vm-1", "title": "chat-1"}]}));
    let listed = ok(
        json!({"account": {"signed_in": true}, "machines": [{"machine_id": "vm-0", "title": "dev"}]}),
    );
    let mut fake = Fake::new(vec![
        listed,
        creating(),
        gap,
        up,
        relayed(json!({"session_id": "relay-1", "reply": "4"})),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "4");
    assert_eq!(&fake.ran[4][..4], &strings(&["cloud", "relay-chat", "--target", "machine:vm-1"]));

    // A create that fails says why and sends nothing.
    let mut fake = Fake::new(vec![signed_in(), creating(), still_creating("failed")]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1));
    assert!(error["message"].as_str().unwrap().contains("no capacity"), "{error}");
}

#[test]
fn a_relay_chat_that_may_have_reached_the_machine_is_never_sent_again() {
    let asked = request(&["--prompt", "x", "--target", "machine:vm-1", "--wait"]);
    // The app's run failed after the request went out.
    let broke = Ran {
        code: 1,
        stderr: json!({"code": "action.failed", "message": "cloud relay chat: connection lost"})
            .to_string(),
        ..Ran::default()
    };
    let mut fake = Fake::new(vec![signed_in(), broke]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.relay_failed"), 1));
    assert!(error["message"].as_str().unwrap().contains("acp ls"));
    assert_eq!(fake.ran.len(), 2);

    // Sent, but the machine has not started it: never resent.
    let mut fake = Fake::new(vec![signed_in(), relayed(json!({"ended": false, "queued": true}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.relay_pending"), 75));
    assert_eq!(fake.ran.len(), 2);

    // Sent, and it failed on the machine before a session: its error, not a resend.
    let failed = json!({"error_code": "chat.failed", "error_message": "no such harness"});
    let mut fake = Fake::new(vec![signed_in(), relayed(failed)]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!() };
    assert_eq!(error["code"], "chat.failed");
    assert_eq!(fake.ran.len(), 2);
}

#[test]
fn the_relay_time_counts_against_the_timeout() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"running\"}]}\n";
    let mut answers = vec![signed_in(), relayed(json!({"session_id": "relay-1", "ended": false}))];
    answers.extend((0..9).map(|_| exec_out(running)));
    let mut fake = Fake::new(answers);
    // The list and the relay step took 10 s of the 47: waits of 20 s while 20 s are left, then the rest,
    // down to 2 s.
    let asked =
        request(&["--prompt", "x", "--target", "machine:vm-1", "--wait", "--timeout", "47"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert!(fake.ran[2][5].contains("acp wait relay-1 --timeout 20 "), "{:?}", fake.ran[2]);
    assert!(fake.ran[9][5].contains("acp wait relay-1 --timeout 2 "), "{:?}", fake.ran[9]);
    assert_eq!(fake.ran.len(), 10);
}

/// `--timeout` is one deadline from the command's start: the machine's create, the start, the relay and the wait
/// each get what is left of it, never a new `--timeout` of their own (the review of #37159).
#[test]
fn every_step_fits_in_one_timeout_from_the_start() {
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"running\"}]}\n";
    let relay_calls =
        |ran: &[Vec<String>]| ran.iter().filter(|step| step[1] == "relay-chat").count();

    // --environment: 5 s list and 30 s create of a 45 s budget leave the relay 10 s, less than its answer
    // window, so the link path starts the chat (by 40 s) and sends (by 45 s), and its wait has nothing left: no
    // wait past the deadline.
    let mut fake = Fake::new(vec![signed_in(), made(), started(), sent()]);
    fake.costs.push(("new-machine", Duration::from_secs(30)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "45"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert_eq!(relay_calls(&fake.ran), 0, "{:?}", fake.ran);
    assert_eq!(fake.ran.len(), 4, "{:?}", fake.ran);

    // --environment with 80 s: the relay runs (45 s left), and its turn's wait ends at 80 s from the start, its
    // last wait the 5 s left.
    let mut answers =
        vec![signed_in(), made(), relayed(json!({"session_id": "relay-1", "ended": false}))];
    answers.extend((0..8).map(|_| exec_out(running)));
    let mut fake = Fake::new(answers);
    fake.costs.push(("new-machine", Duration::from_secs(30)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "80"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert_eq!(relay_calls(&fake.ran), 1);
    assert!(fake.ran[10][5].contains("acp wait relay-1 --timeout 5 "), "{:?}", fake.ran[10]);
    assert_eq!(fake.ran.len(), 11);

    // --environment whose create took the whole 40 s: nothing is started; the machine is there for the same
    // ask again.
    let mut fake = Fake::new(vec![signed_in(), made()]);
    fake.costs.push(("new-machine", Duration::from_secs(40)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "40"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert!(
        error["details"]["again"].as_str().unwrap().contains("--target machine:vm-1"),
        "{error}"
    );
    assert_eq!(fake.ran.len(), 2);

    // No environment: a machine `start-session --name` makes in 30 s of the 40 leaves the wait what is left.
    let mut fake = Fake::new(vec![signed_in(), started(), sent()]);
    fake.costs.push(("start-session", Duration::from_secs(30)));
    let asked = request(&["--prompt", "x", "--name", "py-new", "--wait", "--timeout", "40"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);
}

/// Every step that does I/O or pauses fits in the one deadline: past it nothing more runs, and a step that answers
/// late is a timeout, never a success (the second re-review of #37159). Before the send that is
/// `cloud.start_pending` (75) with the command to ask again; after it, `chat.wait_timeout` (3).
#[test]
fn a_step_that_overruns_the_deadline_ends_the_command() {
    let secs = Duration::from_secs;
    let on_vm_1 = |timeout: &str| {
        request(&["--prompt", "x", "--target", "machine:vm-1", "--wait", "--timeout", timeout])
    };
    let pending = |fake: &Fake, outcome: Outcome| {
        let Outcome::Failed { error, exit } = outcome else { panic!("{:?}", fake.ran) };
        assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
        error
    };

    // The list took the whole 30 s: no machine is made in the environment.
    let mut fake = Fake::new(vec![signed_in()]);
    fake.costs.push(("list-machines", secs(30)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "30"]);
    let outcome = run(&mut fake, &asked);
    pending(&fake, outcome);
    assert_eq!(fake.ran.len(), 1, "{:?}", fake.ran);

    // start-session answered the chat after the deadline: nothing is uploaded or sent.
    let mut fake = Fake::new(vec![signed_in(), started()]);
    fake.costs.push(("start-session", secs(30)));
    let outcome = run(&mut fake, &on_vm_1("30"));
    let error = pending(&fake, outcome);
    assert!(
        error["details"]["again"].as_str().unwrap().contains("--target machine:vm-1"),
        "{error}"
    );
    assert_eq!(error["details"]["answer"]["session_id"], "sess-1");
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);

    // start-session answered pending after the deadline: the machine list is not read for its stage.
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_name": "chat-fresh", "text": "still starting"})),
    ]);
    fake.costs.push(("start-session", secs(30)));
    let outcome = run(&mut fake, &on_vm_1("30"));
    pending(&fake, outcome);
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);

    // The relay's turn ended, but its answer came after the deadline: a timeout, not a reply.
    let mut fake =
        Fake::new(vec![signed_in(), relayed(json!({"session_id": "relay-1", "reply": "4"}))]);
    fake.costs.push(("relay-chat", secs(45)));
    let Outcome::Failed { error, exit } = run(&mut fake, &on_vm_1("45")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3), "{error}");
    assert_eq!(error["details"]["answer"]["session_id"], "relay-1");
    assert_eq!(fake.ran.len(), 2);

    // A prompt that goes to a file in pieces: the first piece took the time left, so no second piece and no send.
    let big = "a".repeat(400 * 1024);
    let mut fake = Fake::new(vec![signed_in(), started(), exec_out("@@size 393216\n")]);
    fake.costs.push(("exec", secs(25)));
    let asked =
        request(&["--prompt", &big, "--target", "machine:vm-1", "--wait", "--timeout", "30"]);
    let outcome = run(&mut fake, &asked);
    pending(&fake, outcome);
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);

    // The pause before asking again for a turn not started yet is what is left (1 s), not its own 2 s.
    let not_started = "@@wait 3\n@@history\n{\"turns\":[]}\n";
    let sent = exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let mut fake = Fake::new(vec![signed_in(), started(), sent, exec_out(not_started)]);
    let Outcome::Failed { error, exit } = run(&mut fake, &on_vm_1("21")) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3), "{error}");
    assert_eq!(fake.paused, secs(1));
    assert_eq!(fake.ran.len(), 4, "{:?}", fake.ran);
}

/// The wait on a machine the command makes itself (no environment, no --target) also gets only what is left
/// of the deadline after the create, the start and the send.
#[test]
fn each_wait_on_a_new_machine_is_bounded_by_the_time_left() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":2,\"status\":\"running\"}]}\n";
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(running),
        exec_out(running),
    ]);
    // The list, the create, the start and the send take 20 s of the 27.
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "27"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(error["code"], "chat.wait_timeout");
    assert_eq!(fake.ran[1][1], "new-machine");
    assert!(fake.ran[4][5].contains("acp wait sess-1 --timeout 7 "), "{:?}", fake.ran[4]);
    assert!(fake.ran[5][5].contains("acp wait sess-1 --timeout 2 "), "{:?}", fake.ran[5]);
    assert_eq!(fake.ran.len(), 6);
}

/// A step that answers after the deadline is that phase's timeout whatever it answered, an error included (the
/// third re-review of #37159): `cloud.start_pending` (75) before the prompt may have reached the machine,
/// `chat.wait_timeout` (3) once it was sent.
#[test]
fn a_late_answer_of_any_step_is_its_phases_timeout() {
    let secs = Duration::from_secs;
    let refused = |code: &str| Ran {
        code: 1,
        stderr: json!({"code": code, "message": "the step failed late"}).to_string(),
        ..Ran::default()
    };
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let asked = |words: &[&str]| {
        let mut all = vec!["--prompt", "x", "--wait"];
        all.extend_from_slice(words);
        request(&all)
    };
    // (case, request, answers, the slow step's index and cost, code, exit, steps run)
    type Case<'a> = (&'a str, Request, Vec<Ran>, (usize, u64), &'a str, i32, usize);
    let big = "a".repeat(400 * 1024);
    let cases: Vec<Case<'_>> = vec![
        (
            "start-session errs late",
            asked(&["--target", "machine:vm-1", "--timeout", "30"]),
            vec![signed_in(), refused("app.failed")],
            (1, 30),
            "cloud.start_pending",
            75,
            2,
        ),
        (
            "--environment's new-machine errs late",
            asked(&["--environment", "env_1", "--timeout", "30"]),
            vec![signed_in(), refused("app.failed")],
            (1, 30),
            "cloud.start_pending",
            75,
            2,
        ),
        (
            "the relay's new-machine errs late",
            asked(&["--timeout", "60"]),
            vec![signed_in(), refused("app.failed")],
            (1, 60),
            "cloud.start_pending",
            75,
            2,
        ),
        (
            "the relay errs late",
            asked(&["--target", "machine:vm-1", "--timeout", "50"]),
            vec![signed_in(), refused("app.failed")],
            (1, 50),
            "cloud.start_pending",
            75,
            2,
        ),
        (
            "the pending start's stage list answers late",
            asked(&["--target", "machine:vm-1", "--timeout", "30"]),
            vec![
                signed_in(),
                ok(json!({"pending": true, "machine_id": "vm-1", "machine_name": "dev"})),
                ok(
                    json!({"machines": [{"machine_id": "vm-1", "title": "dev", "status": "failed"}]}),
                ),
            ],
            (2, 30),
            "cloud.start_pending",
            75,
            3,
        ),
        (
            "the send's exec errs late",
            asked(&["--target", "machine:vm-1", "--timeout", "30"]),
            vec![signed_in(), started(), refused("app.timeout")],
            (2, 30),
            "chat.wait_timeout",
            3,
            3,
        ),
        (
            "the turn's wait answers it ended, late",
            asked(&["--target", "machine:vm-1", "--timeout", "30"]),
            vec![
                signed_in(),
                started(),
                sent(),
                exec_out(
                    "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"endedAt\":9}]}\n@@last\n\"4\"\n@@lastexit 0\n",
                ),
            ],
            (3, 30),
            "chat.wait_timeout",
            3,
            4,
        ),
    ];
    for (case, asked, answers, (index, cost), code, exit, steps) in cases {
        let mut fake = Fake::new(answers);
        fake.slow.push((index, secs(cost)));
        let Outcome::Failed { error, exit: got } = run(&mut fake, &asked) else {
            panic!("{case}: {:?}", fake.ran)
        };
        assert_eq!((error["code"].as_str(), got), (Some(code), exit), "{case}: {error}");
        assert_eq!(fake.ran.len(), steps, "{case}: {:?}", fake.ran);
    }

    // The upload's first piece errs late: no send, and no cleanup past the deadline (the run's own 0600 file
    // stays; see a_cleanup_never_holds_the_command_past_its_deadline).
    let mut fake = Fake::new(vec![signed_in(), started(), refused("app.failed")]);
    fake.slow.push((2, secs(30)));
    let asked =
        request(&["--prompt", &big, "--target", "machine:vm-1", "--wait", "--timeout", "30"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);

    // A relay that may have reached the machine says so, and the command to ask again leaves the prompt out.
    let mut fake = Fake::new(vec![signed_in(), refused("app.failed")]);
    fake.slow.push((1, secs(50)));
    let asked =
        request(&["--prompt", "secret", "--target", "machine:vm-1", "--wait", "--timeout", "50"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("may have reached"), "{message}");
    assert!(message.contains("acp ls"), "{message}");
    assert!(!error.to_string().contains("secret"), "{error}");
}

/// A machine id the steps learn goes into the command to ask again, late or not, so asking again never makes a
/// second machine: a new-machine that answered pending with its id (the fourth review of #37159).
#[test]
fn a_pending_new_machine_with_an_id_is_asked_again_by_that_id() {
    let secs = Duration::from_secs;
    let pending = || ok(json!({"pending": true, "machine_id": "vm-7", "status": "creating"}));
    let cases: [(&str, &[&str], u64); 3] = [
        (
            "--environment's create, late",
            &["--environment", "env_1", "--wait", "--timeout", "30"],
            30,
        ),
        ("the relay's create, late", &["--wait", "--timeout", "60"], 60),
        ("--environment's create, in time, no --wait", &["--environment", "env_1"], 5),
    ];
    for (case, words, cost) in cases {
        let mut all = vec!["--prompt", "x"];
        all.extend_from_slice(words);
        let mut fake = Fake::new(vec![signed_in(), pending()]);
        fake.slow.push((1, secs(cost)));
        let Outcome::Failed { error, exit } = run(&mut fake, &request(&all)) else {
            panic!("{case}: {:?}", fake.ran)
        };
        assert_eq!(
            (error["code"].as_str(), exit),
            (Some("cloud.start_pending"), 75),
            "{case}: {error}"
        );
        let again = error["details"]["again"].as_str().unwrap_or_default();
        assert!(again.contains("--target machine:vm-7"), "{case}: {error}");
        assert!(
            !again.contains("--environment"),
            "{case}: the machine has its environment: {again}"
        );
        assert_eq!(error["details"]["machine_id"], "vm-7", "{case}: {error}");
        assert_eq!(fake.ran.len(), 2, "{case}: {:?}", fake.ran);
    }
}

/// A create the app answers pending with no machine id yet (only its `creation_id`) is asked again by the name the
/// run gave it, and asking again while it is still on its way (`list-machines` lists it as `creating`) never makes a
/// second machine: the fifth review of #37159.
#[test]
fn a_pending_create_with_no_id_is_asked_again_by_its_name_and_never_made_twice() {
    let secs = Duration::from_secs;
    let pending = || ok(json!({"pending": true, "status": "creating", "creation_id": "c-1"}));
    let cases: [(&str, &[&str], u64); 4] = [
        (
            "--environment's create, late",
            &["--environment", "env_1", "--wait", "--timeout", "30"],
            30,
        ),
        ("the relay's create, late", &["--wait", "--timeout", "60"], 60),
        ("--environment's create, in time, no --wait", &["--environment", "env_1"], 5),
        ("the relay's create, waited on until --timeout", &["--wait", "--timeout", "14"], 5),
    ];
    for (case, words, cost) in cases {
        let mut all = vec!["--prompt", "x"];
        all.extend_from_slice(words);
        let mut fake = Fake::new(vec![signed_in(), pending(), still_creating("creating")]);
        fake.slow.push((1, secs(cost)));
        let Outcome::Failed { error, exit } = run(&mut fake, &request(&all)) else {
            panic!("{case}: {:?}", fake.ran)
        };
        assert_eq!(
            (error["code"].as_str(), exit),
            (Some("cloud.start_pending"), 75),
            "{case}: {error}"
        );
        let steps: Vec<&str> = fake.ran.iter().map(|words| words[1].as_str()).collect();
        assert_eq!(
            steps.iter().filter(|step| **step == "new-machine").count(),
            1,
            "{case}: {steps:?}"
        );
        assert!(
            steps.iter().all(|step| ["list-machines", "new-machine"].contains(step)),
            "{case}: nothing started or sent: {steps:?}"
        );
        let create = &fake.ran[1];
        let at = create
            .iter()
            .position(|w| w == "--name")
            .unwrap_or_else(|| panic!("{case}: {create:?}"));
        assert_eq!(create[at + 1], "chat-fresh", "{case}: the run names its own create");
        let again = error["details"]["again"].as_str().unwrap_or_default();
        assert!(again.contains("--name chat-fresh"), "{case}: {error}");
        assert!(
            !again.contains("--environment"),
            "{case}: the create has its environment: {again}"
        );
        assert_eq!(error["details"]["creation_id"], "c-1", "{case}: {error}");

        // Asked again while the create is still on its way, or after it failed: no second machine.
        let rerun: Vec<&str> =
            again.split_whitespace().skip(3).filter(|word| *word != "--json").collect();
        for (status, code, exit) in
            [("creating", "cloud.start_pending", 75), ("failed", "cloud.start_failed", 1)]
        {
            let listed = ok(json!({"account": {"signed_in": true}, "loaded": true,
                "machines": [{"title": "dev", "machine_id": "vm-0"}],
                "creating": [{"creation_id": "c-1", "name": "chat-fresh", "status": status,
                              "reason": "no capacity"}]}));
            let mut fake = Fake::new(vec![listed]);
            let Outcome::Failed { error, exit: got } = run(&mut fake, &request(&rerun)) else {
                panic!("{case}, {status}: {:?}", fake.ran)
            };
            assert_eq!(
                (error["code"].as_str(), got),
                (Some(code), exit),
                "{case}, {status}: {error}"
            );
            assert_eq!(fake.ran.len(), 1, "{case}, {status}: nothing made: {:?}", fake.ran);
        }
    }
}

/// The removal of the run's own prompt file after a failed upload or send is never a step past `--timeout`: with a
/// deadline it is left (mode 0600, in ~/.cmux/prompts on the person's own machine), however slow `cloud exec`
/// would be; without one it runs as before.
#[test]
fn a_cleanup_never_holds_the_command_past_its_deadline() {
    let secs = Duration::from_secs;
    let refused = |code: &str| Ran {
        code: 1,
        stderr: json!({"code": code, "message": "no"}).to_string(),
        ..Ran::default()
    };
    let big = "a".repeat(400 * 1024);
    let on_vm_1 = |words: &[&str]| {
        let mut all = vec!["--prompt", big.as_str(), "--target", "machine:vm-1"];
        all.extend_from_slice(words);
        request(&all)
    };

    // The upload fails in time with 45 s left; the cleanup would take 120 s.
    let mut fake = Fake::new(vec![signed_in(), started(), refused("app.failed"), exec_out("")]);
    fake.slow.push((3, secs(120)));
    let began = fake.clock;
    let Outcome::Failed { error, .. } = run(&mut fake, &on_vm_1(&["--wait", "--timeout", "60"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "chat.send_failed", "{error}");
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);
    assert!(fake.clock <= began + secs(60), "ran {:?} past the deadline", fake.clock - began);

    // The send was refused before it started, after the upload; the cleanup would take 120 s.
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@size 393216\n"),
        exec_out("@@size 409600\n"),
        refused("vm_busy"),
        exec_out(""),
    ]);
    fake.slow.push((5, secs(120)));
    let began = fake.clock;
    let Outcome::Failed { error, .. } = run(&mut fake, &on_vm_1(&["--wait", "--timeout", "60"]))
    else {
        panic!("{:?}", fake.ran)
    };
    // A refused send is the machine not answering (sent_failure), as before this change.
    assert_eq!(error["code"], "chat.unreachable", "{error}");
    assert_eq!(fake.ran.len(), 5, "{:?}", fake.ran);
    assert!(fake.clock <= began + secs(60), "ran {:?} past the deadline", fake.clock - began);

    // No --wait, so no deadline: the failed upload's file is removed as before.
    let mut fake = Fake::new(vec![signed_in(), started(), refused("app.failed"), exec_out("")]);
    let Outcome::Failed { error, .. } = run(&mut fake, &on_vm_1(&[])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "chat.send_failed", "{error}");
    assert!(fake.ran[3][5].contains("rm -f"), "{:?}", fake.ran[3]);
    assert_eq!(fake.ran.len(), 4);
}

#[test]
fn a_timeout_shorter_than_the_relay_window_goes_the_link_way() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        // The send fails on the machine, so the link path ends without a wait.
        exec_out("@@history\n\n@@send\nno such session\n@@exit 1\n"),
    ]);
    let asked =
        request(&["--prompt", "x", "--target", "machine:vm-1", "--wait", "--timeout", "30"]);
    let _ = run(&mut fake, &asked);
    assert_eq!(fake.ran[1][1], "start-session", "{:?}", fake.ran);
    assert!(fake.ran.iter().all(|step| step.get(1).map(String::as_str) != Some("relay-chat")));
}

/// The words `cmux cloud start-chat --prompt "What is 2+2?" --cwd /home/cmux/w --wait` hands the app's
/// `cloud relay-chat` on a new machine, as the CLI's own code builds them (the action argument contract's
/// cmux-tui/spec/fixtures/cli-action-requests.json carries their `action.run` request, which the app's
/// ArgumentActionContractTests validate against its catalog).
pub(in crate::cli) fn contract_relay_words() -> Vec<String> {
    let mut fake = Fake::new(vec![signed_in(), made(), relayed(json!({"session_id": "relay-1"}))]);
    let asked = request(&["--prompt", "What is 2+2?", "--cwd", "/home/cmux/w", "--wait"]);
    let Outcome::Done(_) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    let words = fake.ran[2].clone();
    assert_eq!(&words[..2], &strings(&["cloud", "relay-chat"]), "{:?}", fake.ran);
    words
}

#[test]
fn a_harness_sign_in_failure_is_not_the_cmux_account_signed_out() {
    // acpmux's Cloud text for a Claude with no sign-in (claude_auth.rs `compose_cloud`) and its typed kind:
    // the machine's Claude, never the person's cmux account, so no `cmux cloud sign-in`.
    let claude = "Claude is not signed in here. This Cloud machine has no Claude sign-in (Claude home ~/.claude). \
        Set one up with `cmux inference setup`, then send the message again. \
        (Claude said: Not logged in · Please run /login)";
    for error in [
        json!({"code": "cloud_start_failed", "message": claude}),
        json!({"code": "runtime", "errorKind": "auth.signed_out", "message": "Not logged in · Please run /login"}),
        json!({"code": "chat.failed", "error_kind": "auth.expired", "message": "sign in again"}),
        json!({"code": "auth.signed_out", "message": "Not logged in"}),
    ] {
        assert!(!signed_out(&error), "{error}");
    }
    // The cmux account's own refusals stay signed out.
    for error in [
        json!({"code": "unavailable", "message": "Sign in to use Cloud machines: run Sign In from the command palette, or `cmux cloud sign-in`."}),
        json!({"code": "not_signed_in", "message": "x"}),
        json!({"code": "auth.required", "message": "x"}),
        json!({"code": "cloud_signed_out", "message": "x"}),
    ] {
        assert!(signed_out(&error), "{error}");
    }
}

#[test]
fn a_relay_turn_error_keeps_the_machines_type() {
    let relayed = json!({"machine_id": "vm-1", "session_id": "s-1", "ended": true, "delivered": true,
        "error_code": "chat.failed", "error_message": "daemon connection closed", "error_detail": "daemon_closed",
        "error_cause": "panicked", "error_kind": "auth.signed_out", "error_retryable": true, "error_recovery": "Run acpmux again.", "reply": ""});
    let typed = typed_error(&relayed);
    assert_eq!(
        typed,
        json!({"detail": "daemon_closed", "cause": "panicked", "kind": "auth.signed_out", "recovery": "Run acpmux again.", "retryable": true})
    );
    // An older app's answer has none: nothing is made up.
    assert_eq!(typed_error(&json!({"error_code": "chat.failed"})), json!({}));
}

/// The account's machines, as `cloud list-machines` lists them.
fn listed_machines(rows: Value) -> Ran {
    ok(json!({"account": {"signed_in": true}, "machines": rows}))
}

#[test]
fn a_start_the_plans_running_cap_refuses_names_the_machines_and_how_to_make_room() {
    let mut fake = Fake::new(vec![
        listed_machines(json!([
            {"machine_id": "vm-a", "title": "api", "status": "running"},
            {"machine_id": "vm-b", "title": "web", "status": "paused"},
            {"machine_id": "vm-x", "title": "broken", "status": "failed"},
        ])),
        Ran {
            code: 1,
            stderr: json!({"code": "cmux.cloud.quota_exceeded",
                           "message": "this plan allows 5 active machines"})
            .to_string(),
            ..Ran::default()
        },
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "hi"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.machine_cap");
    let message = error["message"].as_str().unwrap();
    assert!(message.starts_with("this plan allows 5 active machines: "), "{message}");
    assert!(
        message.contains("api (running): `cmux cloud start-chat --target machine:vm-a --prompt TEXT --json` or `cmux cloud pause-machine --target machine:vm-a`"),
        "{message}"
    );
    assert!(message.contains("web (paused)"), "{message}");
    // A failed machine is no room: never named.
    assert!(!message.contains("broken"), "{message}");
    assert_eq!(error["details"]["cap"], "running");
    assert_eq!(
        error["details"]["machines"][1]["delete"],
        "cmux cloud kill-machine --target machine:vm-b --confirm"
    );
}

#[test]
fn a_new_machine_the_vm_apis_cap_failed_names_the_machines_and_how_to_delete_one() {
    let cap = "VM API: this team has its limit of 20 machines (paused ones count); delete one to make another";
    let mut fake = Fake::new(vec![
        listed_machines(json!([{"machine_id": "vm-b", "title": "web", "status": "paused"}])),
        ok(json!({"pending": true, "machine_id": "vm-new", "machine_name": "chat-fresh"})),
        listed_machines(json!([
            {"machine_id": "vm-b", "title": "web", "status": "paused"},
            {"machine_id": "vm-new", "title": "chat-fresh", "status": "failed",
             "error": {"code": "cloud.provider.unavailable", "message": cap}},
        ])),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "hi"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.machine_cap");
    let message = error["message"].as_str().unwrap();
    assert!(message.starts_with(cap), "{message}");
    assert!(
        message.contains("web (paused): `cmux cloud start-chat --target machine:vm-b --prompt TEXT --json` or `cmux cloud kill-machine --target machine:vm-b --confirm`"),
        "{message}"
    );
    assert_eq!(error["details"]["cap"], "held");
}

#[test]
fn only_a_cap_refusal_reads_as_a_cap() {
    use super::cap::{Cap, cap_of};
    assert_eq!(cap_of("cmux.cloud.quota_exceeded", "x"), Some(Cap::Running));
    assert_eq!(cap_of("cloud.quota.exceeded", "x"), Some(Cap::Running));
    assert_eq!(cap_of("", "this plan allows 5 active machines"), Some(Cap::Running));
    assert_eq!(
        cap_of(
            "cloud.provider.unavailable",
            "VM API: this team has its limit of 20 machines (paused ones count); delete one to make another"
        ),
        Some(Cap::Held)
    );
    assert_eq!(cap_of("cloud.provider.unavailable", "VM API: HTTP 429"), None);
    assert_eq!(cap_of("app.unreachable", "no app"), None);
}

#[test]
fn a_start_with_no_machine_named_says_the_machine_is_new_only_when_it_has_the_fresh_name() {
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n");
    let mut fake = Fake::new(vec![signed_in(), started(), sent()]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x"])) else { panic!() };
    assert_eq!(&fake.ran[1][..4], &strings(&["cloud", "start-session", "--name", "chat-fresh"]));
    assert_eq!(answer["new_machine"], true);

    // start-session answered another machine than the fresh name's: nothing says this run made it.
    let other = ok(json!({"machine_id": "vm-2", "machine_name": "dev", "session_id": "sess-1"}));
    let mut fake = Fake::new(vec![signed_in(), other, sent()]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x"])) else { panic!() };
    assert!(answer.get("new_machine").is_none());
}

/// A name the run makes up is never one a machine or a create has, and never one the list could not say about:
/// a fresh name that is taken, or a list the app has not loaded, ends the run with a typed error before any
/// `start-session` or `new-machine`, so the run never attaches to a person's machine or makes a second of its
/// name (the sixth review of #37159).
#[test]
fn a_fresh_name_that_is_taken_or_unread_never_reaches_a_start_or_a_create() {
    let lists = [
        (
            "a machine has it",
            json!({"machines": [{"title": "chat-fresh", "machine_id": "vm-9"}]}),
            "cloud.name_taken",
        ),
        (
            "a create has it",
            json!({"machines": [], "creating": [{"name": "chat-fresh", "status": "creating"}]}),
            "cloud.name_taken",
        ),
        ("the list is not loaded", json!({"loaded": false, "machines": []}), "cloud.list_unread"),
    ];
    let paths: [(&str, &[&str]); 4] = [
        ("start-session, no --wait", &["--prompt", "x"]),
        ("no prompt", &["--wait"]),
        ("the relay's new-machine", &["--prompt", "x", "--wait"]),
        ("--environment's new-machine", &["--prompt", "x", "--environment", "env_1"]),
    ];
    for (list, mut listed, code) in lists {
        listed["account"] = json!({"signed_in": true});
        for (path, words) in paths {
            let mut fake = Fake::new(vec![ok(listed.clone())]);
            let Outcome::Failed { error, exit } = run(&mut fake, &request(words)) else {
                panic!("{list}, {path}: {:?}", fake.ran)
            };
            assert_eq!((error["code"].as_str(), exit), (Some(code), 75), "{list}, {path}: {error}");
            assert_eq!(
                fake.ran.len(),
                1,
                "{list}, {path}: nothing started or made: {:?}",
                fake.ran
            );
        }
    }
}

/// The real runner's fresh name: the run's prefix and 16 hex characters from the OS's random source, so two runs
/// (or a person's own machine) share one only by a negligible chance.
#[test]
fn a_fresh_name_has_sixteen_random_hex_characters() {
    let mut runner = SelfRunner { globals: Vec::new() };
    let names: Vec<String> = (0..64).map(|_| runner.fresh_name()).collect();
    for name in &names {
        let hex = name.strip_prefix("chat-").unwrap_or_else(|| panic!("{name}"));
        assert!(hex.len() >= 16 && hex.chars().all(|c| c.is_ascii_hexdigit()), "{name}");
    }
    let mut unique = names.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), names.len());
}

#[test]
fn a_prompt_to_a_running_chat_on_a_vm_sends_and_waits_without_a_start() {
    let mut fake = Fake::new(vec![
        exec_out(
            "@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n@@send\nd-2\n@@exit 0\n",
        ),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":4,\"status\":\"completed\",\"endedAt\":12}]}\n\
             @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"5\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = Request {
        prompt: Some("And 2+3?".into()),
        agent: String::new(),
        cwd: None,
        environment: None,
        machine: Machine::Target("vm-1".into()),
        wait: true,
        timeout: Duration::from_secs(60),
    };
    let Outcome::Done(answer) = send_to(&mut fake, &asked, "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    // The reply of the turn after the one before the send, never the older one.
    assert_eq!(answer["reply"], "5");
    assert_eq!(
        (answer["session_id"].as_str(), answer["sent"].as_bool()),
        (Some("sess-1"), Some(true))
    );
    // No list, no start: only the two runs on the machine.
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);
    assert!(
        fake.ran
            .iter()
            .all(|ran| ran[..4] == strings(&["cloud", "exec", "--target", "machine:vm-1"]))
    );
}

/// `cmux chat send SESSION --wait` with its deadline gone before the send sends nothing, and the command to ask
/// again is that send to that session, never a `start-chat` (which would start another session): with no time
/// at all, and when the upload of a big prompt took the rest of it (the seventh review of #37159).
#[test]
fn a_send_to_a_running_chat_past_its_deadline_sends_nothing_and_says_how_to_send_again() {
    let asked = |prompt: String, secs: u64| Request {
        prompt: Some(prompt),
        agent: String::new(),
        cwd: None,
        environment: None,
        machine: Machine::Target("vm-1".into()),
        wait: true,
        timeout: Duration::from_secs(secs),
    };
    let big = big_prompt(200 * 1024);
    let piece = exec_out(&format!("@@size {}\n", big.len()));
    let cases = [
        ("no time at all", asked("hi".into(), 0), vec![]),
        ("the upload took the rest", asked(big, 3), vec![piece]),
    ];
    for (case, request, answers) in cases {
        let uploads = answers.len();
        let mut fake = Fake::new(answers);
        let Outcome::Failed { error, exit } = send_to(&mut fake, &request, "vm-1", "sess-1") else {
            panic!("{case}: {:?}", fake.ran)
        };
        assert_eq!(
            (error["code"].as_str(), exit),
            (Some("cloud.start_pending"), 75),
            "{case}: {error}"
        );
        assert_eq!(fake.ran.len(), uploads, "{case}: no send: {:?}", fake.ran);
        let again = error["details"]["again"].as_str().unwrap_or_default();
        assert!(again.starts_with("cmux chat send sess-1 --on vm:vm-1 "), "{case}: {again}");
        assert!(again.contains("--wait") && !again.contains("start-chat"), "{case}: {again}");
        assert!(
            !again.contains("hi") && !again.contains("naïve"),
            "{case}: the prompt stays out: {again}"
        );
    }
}

/// A create the app answered pending for and that then fails is answered as an immediate refusal is: a cap
/// reason is the cap answer (the account's machines and the commands that free one), whether the failure is
/// on the create's row or on a machine row the create became; a failed machine is never the chat's machine
/// (the eighth review of #37159).
#[test]
fn a_pending_create_that_fails_later_is_answered_as_a_refusal_never_started_on() {
    let held = "VM API: this team has its limit of 20 machines (paused ones count); delete one to make another";
    let running = "this plan allows 5 active machines";
    let web = json!({"machine_id": "vm-b", "title": "web", "status": "paused"});
    let first = || ok(json!({"account": {"signed_in": true}, "machines": [web.clone()]}));
    let row_failed = |reason: &str| {
        ok(json!({"account": {"signed_in": true}, "machines": [web.clone()],
                  "creating": [{"creation_id": "c-1", "name": "chat-fresh", "status": "failed",
                                "reason": reason}]}))
    };
    let machine_failed = |message: &str| {
        ok(json!({"account": {"signed_in": true}, "creating": [], "machines": [web.clone(),
                  {"machine_id": "vm-1", "title": "chat-fresh", "status": "failed",
                   "error": {"code": "cloud.provider.unavailable", "message": message}}]}))
    };
    let cases = [
        ("the create's row, the team's cap", row_failed(held), Some("held")),
        ("the create's row, the plan's cap", row_failed(running), Some("running")),
        ("a failed machine, the team's cap", machine_failed(held), Some("held")),
        ("a failed machine, no cap", machine_failed("the machine did not boot"), None),
    ];
    for (case, later, cap) in cases {
        let mut fake = Fake::new(vec![first(), creating(), later]);
        let Outcome::Failed { error, exit } =
            run(&mut fake, &request(&["--prompt", "x", "--wait"]))
        else {
            panic!("{case}: {:?}", fake.ran)
        };
        let steps: Vec<&str> = fake.ran.iter().map(|words| words[1].as_str()).collect();
        assert_eq!(
            steps,
            ["list-machines", "new-machine", "list-machines"],
            "{case}: nothing started"
        );
        match cap {
            Some(cap) => {
                assert_eq!(
                    (error["code"].as_str(), exit),
                    (Some("cloud.machine_cap"), 1),
                    "{case}: {error}"
                );
                assert_eq!(error["details"]["cap"], cap, "{case}: {error}");
                let message = error["message"].as_str().unwrap_or_default();
                assert!(message.contains("vm-b"), "{case}: the account's machines: {message}");
            }
            None => {
                assert_eq!(
                    (error["code"].as_str(), exit),
                    (Some("cloud.start_failed"), 1),
                    "{case}: {error}"
                );
                assert!(
                    error["message"].as_str().unwrap_or_default().contains("did not boot"),
                    "{case}: {error}"
                );
            }
        }
    }
}

/// A create still on its way when `--timeout` runs out answers with the name the rerun uses (`machine_name`)
/// beside its `creation_id`, as every other pending answer does (the eighth review of #37159).
#[test]
fn a_late_creation_timeout_names_the_machine_to_ask_again_by() {
    let mut fake = Fake::new(vec![signed_in(), creating(), still_creating("creating")]);
    let Outcome::Failed { error, exit } =
        run(&mut fake, &request(&["--prompt", "x", "--wait", "--timeout", "14"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(error["details"]["creation_id"], "c-1", "{error}");
    assert_eq!(error["details"]["machine_name"], "chat-fresh", "{error}");
    assert!(
        error["details"]["again"].as_str().unwrap_or_default().contains("--name chat-fresh"),
        "{error}"
    );
}
