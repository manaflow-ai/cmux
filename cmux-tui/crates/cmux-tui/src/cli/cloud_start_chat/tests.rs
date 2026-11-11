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

#[path = "clone_wait_tests.rs"]
mod clone_wait;
#[path = "folder_tests.rs"]
mod folder;

/// Leo, 2026-11-10: a Cloud chat runs the Claude model the person asked for. `--model`, or
/// `--agent claude/MODEL` as `acp ensure -m` reads it, is the run's model, asked again with it.
#[test]
fn the_model_is_taken_from_model_or_agent_and_checked() {
    let flag = request(&["--model", "claude-haiku-5-5", "-p", "go"]);
    assert_eq!((flag.agent.as_str(), flag.model.as_deref()), ("claude", Some("claude-haiku-5-5")));
    let joined = request(&["--agent", "claude/claude-sonnet-5-5", "-p", "go"]);
    assert_eq!(
        (joined.agent.as_str(), joined.model.as_deref()),
        ("claude", Some("claude-sonnet-5-5"))
    );
    assert!(
        again_command(&flag, &Machine::Target("vm-1".into())).contains("--model claude-haiku-5-5")
    );
    assert_eq!(request(&["-p", "go"]).model, None);
    for bad in ["", "-x", "a b", "$(id)", "a'b"] {
        assert!(
            parse(&strings(&["--model", bad, "-p", "go"]), || Ok(String::new())).is_err(),
            "{bad:?}"
        );
    }
    assert!(
        parse(&strings(&["--agent", "claude/x", "--model", "y", "-p", "go"]), || Ok(String::new()))
            .is_err()
    );
    assert!(TAKES_VALUE.contains(&"--model"));
}

#[test]
fn parse_takes_the_prompt_and_defaults_to_claude_on_a_new_machine() {
    let parsed = request(&["--prompt", "hi there"]);
    assert_eq!(
        parsed,
        Request {
            prompt: Some("hi there".into()),
            agent: "claude".into(),
            model: None,
            cwd: None,
            from_folder: None,
            login: None,
            environment: None,
            machine: Machine::New,
            wait: false,
            timeout: Duration::from_secs(900),
            make_room: false,
            allow_large: false,
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

/// Leo (2026-11-06): one command line, in conjunction with "login with Claude or login with Codex or login with
/// nothing at all": `--login` takes the words `cloud start-session` takes, in any case.
#[test]
fn parse_takes_the_harness_login() {
    for (word, login) in
        [("pass", "pass"), ("machine", "machine"), ("none", "none"), ("None", "none")]
    {
        assert_eq!(
            request(&["--prompt", "x", "--login", word]).login.as_deref(),
            Some(login),
            "{word}"
        );
    }
    assert_eq!(request(&["--prompt", "x", "--login=machine"]).login.as_deref(), Some("machine"));
    assert_eq!(request(&["--prompt", "x"]).login, None);
}

/// Leo (2026-11-06): "Like with an initial ... prompts. Or not?": with no --prompt the command starts the chat
/// and sends nothing. An empty --prompt is still a mistake, not "no prompt".
#[test]
fn parse_takes_no_prompt() {
    for words in [vec![], vec!["--name", "dev"], vec!["--wait", "--login", "none"]] {
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
    let asked = request(&["--prompt", "x", "--login", "none"]);
    assert_eq!(
        again_command(&asked, &Machine::Target("vm-1".into())),
        "cmux cloud start-chat --target machine:vm-1 --login none --prompt TEXT --json"
    );
}

#[test]
fn the_login_goes_to_start_session() {
    for (agent, login) in [("claude", "pass"), ("codex", "machine"), ("claude", "none")] {
        let mut fake = Fake::new(vec![
            signed_in(),
            started(),
            exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        ]);
        let asked =
            request(&["--prompt", "x", "--name", "dev", "--agent", agent, "--login", login]);
        let Outcome::Done(_) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
        assert_eq!(
            fake.ran[1],
            strings(&[
                "cloud",
                "start-session",
                "--name",
                "dev",
                "--agent",
                agent,
                "--login",
                login,
                "--json"
            ])
        );
    }
    // No --login: start-session gets none, so the app's default holds.
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
    ]);
    let Outcome::Done(_) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"])) else {
        panic!()
    };
    assert!(!fake.ran[1].contains(&"--login".to_owned()));
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
    /// The app's link stream socket (`cloud.machine_stream`); None: no app answers.
    stream: Option<Result<Value, Value>>,
    /// The link waits' answers, in order.
    pushes: VecDeque<Result<Value, link_wait::Failure>>,
    /// The app calls and link waits asked: what and its params.
    called: Vec<(String, Value)>,
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
            stream: None,
            pushes: VecDeque::new(),
            called: Vec::new(),
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
    fn app(
        &mut self,
        method: &str,
        params: Value,
        _timeout: Duration,
    ) -> Option<Result<Value, Value>> {
        self.called.push((method.to_owned(), params));
        self.clock += Duration::from_millis(5);
        self.stream.clone()
    }
    fn observe(
        &mut self,
        socket: &str,
        surface: u64,
        after: u64,
        _wait: Duration,
    ) -> Result<Value, link_wait::Failure> {
        self.called.push((
            "observe".to_owned(),
            json!({"socket": socket, "surface": surface, "after_seq": after}),
        ));
        self.clock += Duration::from_millis(400);
        self.pushes.pop_front().unwrap_or_else(|| Err(link_wait::Failure::Link("no link".into())))
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

fn started() -> Ran {
    ok(started_value())
}

fn started_value() -> Value {
    json!({"machine_id": "vm-1", "machine_name": "chat-fresh", "session_id": "sess-1",
           "host": "registry:x", "agent": "claude", "workspace_id": "ws_1",
           "tab_id": "tab-1", "target": "machine:vm-1"})
}

#[test]
fn a_new_chat_starts_on_a_new_machine_sends_waits_and_answers_the_reply() {
    let mut fake = Fake::new(vec![
        signed_in(),
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
    assert_eq!(answer["new_machine"], true, "its start-session of the fresh name made vm-1");
    assert_eq!(answer["placement"], "vm:vm-1", "the answer names where it ran");
    assert_eq!(answer["follow_up"]["send"], json!("cmux chat send sess-1 'PROMPT' --wait"));
    // A new machine with a fresh name: `start-session --name` makes it.
    assert_eq!(
        fake.ran[1],
        strings(&["cloud", "start-session", "--name", "chat-fresh", "--agent", "claude", "--json"])
    );
    let send = &fake.ran[2];
    assert_eq!(&send[..4], &strings(&["cloud", "exec", "--target", "machine:vm-1"]));
    assert!(send[5].contains("printf '%s' 'What is 2+2?' | \"$c\" acp send --no-wait sess-1 -"));
    assert!(send[5].starts_with(GUEST_PRELUDE));
    assert_eq!(fake.paused, Duration::from_secs(2));
}

fn started_with_surface() -> Ran {
    let mut ran = started();
    let mut answer: Value = serde_json::from_str(&ran.stdout).unwrap();
    answer["result"]["surface_id"] = json!("7");
    ran.stdout = answer.to_string();
    ran
}

/// A fresh chat's turn: pushed over the machine's link (the app's stream socket, then the tab's records read
/// here), not `cloud exec ... acp wait` and `acp last` (Leo, 2026-11-10: "have we figured out where the 26.5
/// seconds were yet?"; the trailing two execs took 1091 + 2590 ms). The reply and the felt times come from the
/// records.
#[test]
fn a_fresh_chats_turn_is_pushed_over_the_link() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started_with_surface(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    fake.stream = Some(Ok(json!({"socket": "/tmp/link.sock"})));
    let update = |seq: u64, at: u64, text: &str| {
        json!({"seq": seq, "at": at, "dir": "in", "kind": "notification",
        "msg": {"method": "session/update", "params": {"sessionId": "s", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}})
    };
    fake.pushes.push_back(Ok(json!({"records": [
        {"seq": 1, "at": 1_000, "dir": "mux", "kind": "user_message", "msg": {"text": "pong"}},
        update(2, 2_100, "po"), update(3, 2_200, "ng"),
    ], "last_seq": 3, "ended": "timeout"})));
    fake.pushes.push_back(Ok(json!({"records": [
        {"seq": 4, "at": 3_000, "dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}},
    ], "last_seq": 4, "ended": "turn_end"})));
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "pong", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "pong");
    assert_eq!(answer["wait_route"], "link");
    assert_eq!(answer["turn"]["status"], "completed");
    assert_eq!(answer["turn_ms"], json!({"first_output": 1_100, "end": 2_000}));
    // No exec after the send; the second wait starts after the first one's newest seq.
    assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);
    assert_eq!(fake.called[0], ("cloud.machine_stream".to_owned(), json!({"machine": "vm-1"})));
    assert_eq!(fake.called[1].1, json!({"socket": "/tmp/link.sock", "surface": 7, "after_seq": 0}));
    assert_eq!(fake.called[2].1["after_seq"], 3);
}

/// A turn that fails writes `turn_error` and no `turn_end` (acpmux `hub/turns.rs`): the pushed wait ends there with
/// the agent's error, not at `--timeout`.
#[test]
fn a_pushed_turn_that_fails_answers_its_error() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started_with_surface(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    fake.stream = Some(Ok(json!({"socket": "/tmp/link.sock"})));
    fake.pushes.push_back(Ok(json!({"records": [
        {"seq": 1, "at": 1_000, "dir": "mux", "kind": "user_message", "msg": {"text": "pong"}},
        {"seq": 2, "at": 1_500, "dir": "mux", "kind": "turn_error", "msg": {"error": "agent process closed", "errorKind": "agent_exited"}},
    ], "last_seq": 2, "ended": "turn_end"})));
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "pong", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], "chat.turn_failed");
    assert_eq!(error["message"], "agent process closed");
    assert_eq!(error["details"]["errorKind"], "agent_exited");
    assert_eq!(error["details"]["turn"]["status"], "failed");
    assert_eq!(error["details"]["wait_route"], "link");
}

/// The link closes mid-turn after some records were read: the turn is read through exec instead.
#[test]
fn a_link_that_closes_mid_turn_falls_back_to_exec() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started_with_surface(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"4\"]}\n@@lastexit 0\n",
        ),
    ]);
    fake.stream = Some(Ok(json!({"socket": "/tmp/link.sock"})));
    fake.pushes.push_back(Ok(json!({"records": [
        {"seq": 1, "at": 1_000, "dir": "mux", "kind": "user_message", "msg": {"text": "x"}},
    ], "last_seq": 1, "ended": "closed"})));
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["wait_route"], "exec");
}

/// No app answers the link's socket (an older app) or the link cannot be observed: the turn is read through the
/// Cloud API's exec as before, and the answer says which route it took.
#[test]
fn without_the_link_the_turn_is_read_through_exec() {
    for stream in [None, Some(Ok(json!({"socket": "/tmp/link.sock"})))] {
        let mut fake = Fake::new(vec![
            signed_in(),
            started_with_surface(),
            exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
            exec_out(
                "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
                 @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"4\"]}\n@@lastexit 0\n",
            ),
        ]);
        fake.stream = stream;
        let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
            panic!("{:?}", fake.ran)
        };
        assert_eq!(answer["reply"], "4");
        assert_eq!(answer["wait_route"], "exec");
    }
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

/// Leo, 2026-11-10: "have we figured out where the 26.5 seconds were yet?". The app's own split of
/// `cloud start-session` (its steps and the machine's start phases) rides under that step as `detail`; an
/// app that reports none leaves the step as it was.
#[test]
fn the_start_sessions_own_split_rides_under_its_step() {
    let split = json!({"steps": [{"step": "machine", "ms": 7100}, {"step": "connect.link", "ms": 2800}],
                       "machine": {"session_new": 1800}, "total": 22_826});
    let mut with_split = started();
    let mut answer: Value = serde_json::from_str(&with_split.stdout).unwrap();
    answer["result"]["stages_detail_ms"] = split.clone();
    with_split.stdout = answer.to_string();
    let mut fake = Fake::new(vec![
        signed_in(),
        with_split,
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"]))
    else {
        panic!()
    };
    let steps = answer["stages_ms"]["steps"].as_array().unwrap();
    assert_eq!(steps[1]["step"], "cloud start-session");
    assert_eq!(steps[1]["detail"], split);
    assert!(steps[0].get("detail").is_none() && steps[2].get("detail").is_none(), "{steps:?}");
}

/// `cloud start-session`'s own split (the app's `stages_ms`) goes under that step's `parts`, so its 20-odd seconds
/// name the machine, the connect, the login, the tab and the start (cmuxterm-hq#8658: "no breakdown of it yet").
#[test]
fn the_start_sessions_own_stages_are_its_parts() {
    let parts = json!([{"step": "machine", "ms": 8_100}, {"step": "connect", "ms": 9_400},
                       {"step": "login", "ms": 2_100}, {"step": "tab", "ms": 700}, {"step": "start", "ms": 2_500}]);
    let mut session = started_value();
    session["stages_ms"] = parts.clone();
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(session),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--name", "dev"]))
    else {
        panic!()
    };
    let steps = answer["stages_ms"]["steps"].as_array().unwrap();
    assert_eq!(steps[1]["step"], "cloud start-session");
    assert_eq!(steps[1]["parts"], parts);
    assert!(steps[0].get("parts").is_none() && steps[2].get("parts").is_none(), "{steps:?}");
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
    // A new machine: `start-session --name` of the fresh name makes it, then the send fails.
    let mut fake = Fake::new(vec![signed_in(), started(), refused()]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(fake.ran[1][..4], strings(&["cloud", "start-session", "--name", "chat-fresh"]));
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

/// No prompt: start-session alone, with or without --wait (there is no turn to wait on). No new-machine
/// first, no exec: the answer is the chat's ids, how long it took to be ready, and how to send
/// the first message.
#[test]
fn without_a_prompt_it_starts_the_chat_and_sends_nothing() {
    for wait in [false, true] {
        let mut fake = Fake::new(vec![
            signed_in(),
            started(),
            exec_out(
                "@@cwd\n{\"sessions\":[{\"sessionId\":\"sess-1\",\"cwd\":\"/home/cmux/chats/peer-7\"}]}\n",
            ),
        ]);
        let mut words = vec!["--login", "machine"];
        if wait {
            words.push("--wait");
        }
        let Outcome::Done(answer) = run(&mut fake, &request(&words)) else {
            panic!("{:?}", fake.ran)
        };
        assert_eq!(
            fake.ran[..2],
            [
                strings(&["cloud", "list-machines", "--json"]),
                strings(&[
                    "cloud",
                    "start-session",
                    "--name",
                    "chat-fresh",
                    "--agent",
                    "claude",
                    "--login",
                    "machine",
                    "--json"
                ]),
            ]
        );
        // A folderless start with no prompt still says where the chat runs (review #39939 F1): one read
        // of the machine's sessions, after the chat is ready, so `ready_ms` does not count it.
        assert_eq!(fake.ran.len(), 3, "{:?}", fake.ran);
        assert!(
            fake.ran[2][5].contains("acp ls --live --machine local --json --fields sessionId,cwd")
        );
        assert!(!fake.ran[2][5].contains("acp send"), "nothing is sent: {}", fake.ran[2][5]);
        assert_eq!(answer["cwd"], "/home/cmux/chats/peer-7");
        assert_eq!(answer["folder"], "fresh");
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
/// --environment`, a fresh name without `--name`), and the chat starts on it with `start-session --target`.
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
    // No prompt: new-machine and start-session, then the read of where the chat runs.
    let mut fake = Fake::new(vec![signed_in(), made(), started(), exec_out("@@cwd\n[]\n")]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--environment", "env_1", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["sent"], false);
    assert_eq!(fake.ran[1], new_machine(&["--name", "chat-fresh", "--environment", "env_1"]));
    assert_eq!(fake.ran[2], on_vm_1);
    assert_eq!(fake.ran.len(), 4);
    assert!(answer.get("cwd").is_none(), "an unread folder is left out: {answer}");
    // --wait with a prompt: the chat on the machine made in the environment, its turn waited on, and no
    // second machine.
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"replies\":[\"4\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    assert_eq!(fake.ran[1], new_machine(&["--name", "chat-fresh", "--environment", "env_1"]));
    assert_eq!(fake.ran[2], on_vm_1);
    assert_eq!(fake.ran.iter().filter(|step| step[1] == "new-machine").count(), 1);
    assert_eq!(fake.ran.len(), 5);
    // --name of no machine yet: that name, in the environment.
    let mut fake = Fake::new(vec![signed_in(), made(), started(), exec_out("@@cwd\n[]\n")]);
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
    // A name no machine has: `start-session --name` makes it.
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
    let mut fake =
        Fake::new(vec![signed_in(), started(), sent(), exec_out(&format!("@@wait 2\n{running}"))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.permission_waiting"), 2));
    assert_eq!(error["details"]["answer"]["session_id"], "sess-1");

    // A --timeout that runs out while the turn runs: 15 s of the 20 list, start the chat and send, so the wait
    // has the 5 s left.
    let mut answers = vec![signed_in(), started(), sent()];
    answers.extend((0..3).map(|_| exec_out(&format!("@@wait 3\n{running}"))));
    let mut fake = Fake::new(answers);
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "20"]);
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
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out("@@wait 4\n@@history\nno such session\n@@last\n\n@@lastexit 1\n"),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!(error["code"], "chat.lost");
    assert_eq!(fake.ran.len(), 4);
}

/// A `cloud exec` the Cloud API did not answer in time, as the app reports it (production probe 2026-11-08 19:06Z).
fn unanswered() -> Ran {
    Ran {
        code: 1,
        stdout: String::new(),
        stderr: json!({"code": "daemon_error", "data": {"action": "cloudExec"},
                       "message": "exec on Cloud machine: cmux Cloud didn't answer in time. Try again; if it \
                                   keeps happening, run `cmux cloud diagnostics`."})
        .to_string(),
    }
}

const SENT: &str = "@@history\n{\"turns\":[]}\n@@send\nqueued for delivery d-1\n@@exit 0\n";
const REPLIED: &str = "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
                       @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"4\"]}\n@@lastexit 0\n";

/// A read of the running turn only reads, so one the Cloud API did not answer is asked again, and the reply that
/// comes is the answer; the answer counts the reads that went unanswered.
#[test]
fn an_unanswered_read_of_the_turn_is_asked_again() {
    let mut fake =
        Fake::new(vec![signed_in(), started(), exec_out(SENT), unanswered(), exec_out(REPLIED)]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["unanswered_reads"], 1);
    assert_eq!(fake.ran.len(), 5, "{:?}", fake.ran);
    // The read asked again is the same read, and the prompt was sent once.
    assert_eq!(fake.ran[3], fake.ran[4]);
    assert_eq!(
        fake.ran.iter().filter(|ran| ran.get(5).is_some_and(|s| s.contains("acp send"))).count(),
        1
    );
    assert_eq!(fake.paused, NOT_STARTED_PAUSE);
}

/// Unanswered reads are asked again, with backoff, until `--timeout` runs out: only then is the chat
/// `chat.unreachable` (a fixed three tries failed a slow-but-working machine with most of the deadline left).
#[test]
fn unanswered_reads_are_asked_again_until_the_deadline() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"running\"}]}\n";
    let mut answers = vec![signed_in(), started(), exec_out(SENT), unanswered(), exec_out(running)];
    answers.extend((0..40).map(|_| unanswered()));
    let mut fake = Fake::new(answers);
    let began = fake.clock;
    let Outcome::Failed { error, exit } =
        run(&mut fake, &request(&["--prompt", "x", "--wait", "--timeout", "120"]))
    else {
        panic!("{:?}", fake.ran)
    };
    // The deadline's own answer: the read that found it passed (`chat.unreachable`) or the wait that had none of it
    // left (`chat.wait_timeout`), whichever came first.
    let code = error["code"].as_str();
    assert!(matches!(code, Some("chat.unreachable" | "chat.wait_timeout")), "{error}");
    assert!(exit == 1 || exit == 3, "{exit}");
    assert_eq!(error["details"]["answer"]["session_id"], "sess-1");
    // Far more than three reads, and the failure comes only once the deadline has passed.
    assert!(fake.ran.len() > 5 + 3, "{:?}", fake.ran);
    assert!(
        fake.clock.duration_since(began) >= Duration::from_secs(120),
        "{:?}",
        fake.clock.duration_since(began)
    );
}

/// The machine's daemon comes back 30 s into the wait (a receiver or acpmux that starts late): every read until then
/// goes unanswered, and the reply is still read back inside `--timeout`.
#[test]
fn a_machine_that_answers_after_30_s_of_unanswered_reads_gets_its_reply_read() {
    let mut answers = vec![signed_in(), started(), exec_out(SENT)];
    // Each fake step takes 5 s; with the pauses between them, these reads span over 30 s.
    answers.extend((0..5).map(|_| unanswered()));
    answers.push(exec_out(REPLIED));
    let mut fake = Fake::new(answers);
    let Outcome::Done(answer) =
        run(&mut fake, &request(&["--prompt", "x", "--wait", "--timeout", "120"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["unanswered_reads"], 5);
    let unanswered_span = Duration::from_secs(5 * 5) + fake.paused;
    assert!(unanswered_span >= Duration::from_secs(30), "{unanswered_span:?}");
}

/// The pauses between unanswered reads grow from 2 s and stop growing at 15 s.
#[test]
fn unanswered_pauses_back_off_to_a_cap() {
    let pauses: Vec<u64> = (1..=6).map(|n| unanswered_pause(n).as_secs()).collect();
    assert_eq!(pauses, [2, 4, 8, 15, 15, 15]);
}

/// A read refused because the machine stopped, is gone or is not the caller's, or for its length, fails at once:
/// another read would be refused the same way. The app reports these as `daemon_error` with the server's text, so
/// both envelopes are refused without a second read.
#[test]
fn a_read_refused_for_the_machine_fails_at_once() {
    let app = |message: &str| {
        json!({"code": "daemon_error", "data": {"action": "cloudExec"},
               "message": format!("exec on Cloud machine: {message}")})
    };
    let refusals = [
        json!({"code": "vm_not_running", "message": "no"}),
        json!({"code": "vm_not_found", "message": "no"}),
        json!({"code": "vm_forbidden", "message": "no"}),
        json!({"code": "vm_command_too_large", "message": "no"}),
        app("This machine is stopped. Start it, then try again. (trace t-1)"),
        app("No Cloud machine vm_1 on this account. (trace t-2)"),
        app("You can't use this machine. (trace t-3)"),
        app("The command is too long (413). (trace t-4)"),
    ];
    for refusal in refusals {
        let code = refusal.to_string();
        let refused = Ran { code: 1, stdout: String::new(), stderr: refusal.to_string() };
        let mut fake = Fake::new(vec![signed_in(), started(), exec_out(SENT), refused]);
        let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
        else {
            panic!("{code}: {:?}", fake.ran)
        };
        assert_eq!(error["code"], "chat.unreachable", "{code}");
        assert_eq!(fake.ran.len(), 4, "{code}: {:?}", fake.ran);
    }
}

/// An unanswered read with no time left is not read again: past `--timeout` the answer is the wait's timeout.
#[test]
fn an_unanswered_read_past_the_deadline_fails() {
    let mut fake = Fake::new(vec![signed_in(), started(), exec_out(SENT), unanswered()]);
    // The read takes the rest of the 60 s.
    fake.slow.push((3, Duration::from_secs(60)));
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "60"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    // Past the deadline it is the wait's timeout, as any step that answers after it.
    assert_eq!(error["code"], "chat.wait_timeout", "{error}");
    assert_eq!(fake.ran.len(), 4, "{:?}", fake.ran);
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

/// `cloud new-machine`'s answer for a create slower than the app's own answer window.
fn creating() -> Ran {
    ok(json!({"pending": true, "status": "creating", "creation_id": "c-1"}))
}

/// `cloud list-machines` while create `c-1` is still on its way.
fn still_creating(status: &str) -> Ran {
    ok(json!({"account": {"signed_in": true}, "machines": [{"machine_id": "vm-0", "title": "dev"}],
              "creating": [{"creation_id": "c-1", "name": null, "status": status, "reason": "no capacity"}]}))
}

/// `--wait` covers a slow create in `--environment`: it reads the app's list until the create's machine is there,
/// then starts the chat on it.
#[test]
fn wait_covers_a_create_slower_than_the_apps_answer() {
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait"]);
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let ended = || {
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"replies\":[\"4\"]}\n@@lastexit 0\n",
        )
    };
    let up = || {
        ok(json!({"account": {"signed_in": true}, "creating": [],
                  "machines": [{"machine_id": "vm-0", "title": "dev"}, {"machine_id": "vm-1", "title": "chat-1"}]}))
    };
    let listed = || {
        ok(
            json!({"account": {"signed_in": true}, "machines": [{"machine_id": "vm-0", "title": "dev"}]}),
        )
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
    let mut fake = Fake::new(vec![
        listed(),
        creating(),
        still_creating("creating"),
        up(),
        started(),
        sent(),
        ended(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["new_machine"], true);
    assert_eq!(fake.ran[4], on_vm_1);

    // A list between the create row and its machine (neither listed) is read past, not the answer.
    let gap = ok(json!({"account": {"signed_in": true}, "creating": [],
                        "machines": [{"machine_id": "vm-0", "title": "dev"}]}));
    let mut fake = Fake::new(vec![listed(), creating(), gap, up(), started(), sent(), ended()]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    assert_eq!(fake.ran[4], on_vm_1);

    // A create that fails says why and sends nothing.
    let mut fake = Fake::new(vec![signed_in(), creating(), still_creating("failed")]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_failed"), 1));
    assert!(error["message"].as_str().unwrap().contains("no capacity"), "{error}");
    assert_eq!(fake.ran.len(), 3);
}

/// `--timeout` is one deadline from the command's start: the machine's create, the start, the send and the wait
/// each get what is left of it, never a new `--timeout` of their own (the review of #37159).
#[test]
fn every_step_fits_in_one_timeout_from_the_start() {
    let sent = || exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n");
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"running\"}]}\n";

    // --environment: 5 s list and 30 s create of a 45 s budget leave 10 s: the chat starts (by 40 s) and the
    // prompt is sent (by 45 s), and its wait has nothing left: no wait past the deadline.
    let mut fake = Fake::new(vec![signed_in(), made(), started(), sent()]);
    fake.costs.push(("new-machine", Duration::from_secs(30)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "45"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert_eq!(fake.ran.len(), 4, "{:?}", fake.ran);

    // --environment with 80 s: the start and the send end at 45 s, and the turn's wait ends at 80 s from the
    // start, its last wait the 5 s left.
    let mut answers = vec![signed_in(), made(), started(), sent()];
    answers.extend((0..8).map(|_| exec_out(running)));
    let mut fake = Fake::new(answers);
    fake.costs.push(("new-machine", Duration::from_secs(30)));
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "80"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert_eq!(fake.ran[2][1], "start-session", "{:?}", fake.ran);
    assert!(fake.ran[4][5].contains("acp wait sess-1 --timeout 20 "), "{:?}", fake.ran[4]);
    assert!(fake.ran[10][5].contains("acp wait sess-1 --timeout 5 "), "{:?}", fake.ran[10]);
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

/// The wait on a machine the command makes itself (no environment, no --target: `start-session --name` of a fresh
/// name) also gets only what is left of the deadline after the start and the send.
#[test]
fn each_wait_on_a_new_machine_is_bounded_by_the_time_left() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":2,\"status\":\"running\"}]}\n";
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(running),
        exec_out(running),
    ]);
    // The list, the start and the send take 15 s of the 22.
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "22"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(error["code"], "chat.wait_timeout");
    assert_eq!(fake.ran[1][..4], strings(&["cloud", "start-session", "--name", "chat-fresh"]));
    assert!(fake.ran[3][5].contains("acp wait sess-1 --timeout 7 "), "{:?}", fake.ran[3]);
    assert!(fake.ran[4][5].contains("acp wait sess-1 --timeout 2 "), "{:?}", fake.ran[4]);
    assert_eq!(fake.ran.len(), 5);
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
}

/// A machine id the steps learn goes into the command to ask again, late or not, so asking again never makes a
/// second machine: a new-machine that answered pending with its id (the fourth review of #37159).
#[test]
fn a_pending_new_machine_with_an_id_is_asked_again_by_that_id() {
    let secs = Duration::from_secs;
    let pending = || ok(json!({"pending": true, "machine_id": "vm-7", "status": "creating"}));
    let cases: [(&str, &[&str], u64); 2] = [
        (
            "--environment's create, late",
            &["--environment", "env_1", "--wait", "--timeout", "30"],
            30,
        ),
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
    let cases: [(&str, &[&str], u64); 3] = [
        (
            "--environment's create, late",
            &["--environment", "env_1", "--wait", "--timeout", "30"],
            30,
        ),
        ("--environment's create, in time, no --wait", &["--environment", "env_1"], 5),
        (
            "--environment's create, waited on until --timeout",
            &["--environment", "env_1", "--wait", "--timeout", "14"],
            5,
        ),
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
fn a_harness_sign_in_failure_is_not_the_cmux_account_signed_out() {
    // acpmux's Cloud text for a Claude with no sign-in (claude_auth.rs `compose_cloud`) and its typed kind:
    // the machine's Claude, never the person's cmux account, so no `cmux cloud sign-in`.
    let claude = "Claude is not signed in here. This Cloud machine has no Claude sign-in (Claude home ~/.claude). \
        Click Set up Claude Code credentials on this message to sign it in from your Mac; the message is sent again. \
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
    assert!(
        message.starts_with(
            "Cloud could not start a new machine: too many machines are running at once"
        ),
        "{message}"
    );
    // A paid plan has no machine count: the guard's number stays in the app's answer, out of the lead.
    assert!(!message.contains("plan allows"), "{message}");
    assert_eq!(error["details"]["app"]["message"], "this plan allows 5 active machines");
    assert!(
        message.contains("api (running): `cmux cloud start-chat --target vm:vm-a --prompt TEXT --json` or `cmux cloud pause-machine --target vm:vm-a`"),
        "{message}"
    );
    assert!(message.contains("web (paused)"), "{message}");
    // A failed machine is no room: never named.
    assert!(!message.contains("broken"), "{message}");
    assert_eq!(error["details"]["cap"], "running");
    assert_eq!(
        error["details"]["machines"][1]["delete"],
        "cmux cloud kill-machine --target vm:vm-b --confirm"
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
    assert!(
        message
            .starts_with("Cloud could not start a new machine: too many machines are kept at once"),
        "{message}"
    );
    assert!(!message.contains("limit of 20"), "{message}");
    assert!(
        message.contains("web (paused): `cmux cloud start-chat --target vm:vm-b --prompt TEXT --json` or `cmux cloud kill-machine --target vm:vm-b --confirm`"),
        "{message}"
    );
    assert_eq!(error["details"]["cap"], "held");
    assert_eq!(error["details"]["reason"], cap);
}

#[test]
fn a_start_the_spending_cap_refuses_says_so_and_names_only_running_machines() {
    let mut fake = Fake::new(vec![
        listed_machines(json!([
            {"machine_id": "vm-a", "title": "api", "status": "running"},
            {"machine_id": "vm-b", "title": "web", "status": "paused"},
        ])),
        Ran {
            code: 1,
            stderr: json!({"code": "cloud.spend_cap.reached",
                           "message": "this team is at its spending cap"})
            .to_string(),
            ..Ran::default()
        },
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "hi"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.spend_cap");
    let message = error["message"].as_str().unwrap();
    assert!(
        message
            .starts_with("Cloud could not start a new machine: your team reached its spending cap"),
        "{message}"
    );
    assert!(message.contains("nothing is lost"), "{message}");
    assert!(message.contains("api (running)"), "{message}");
    // A paused machine cannot start at the cap: never offered.
    assert!(!message.contains("web (paused)"), "{message}");
    assert_eq!(error["details"]["cap"], "spend");
}

#[test]
fn only_a_cap_refusal_reads_as_a_cap() {
    use super::cap::{Cap, cap_of};
    assert_eq!(cap_of("cmux.cloud.quota_exceeded", "x", None), Some(Cap::Running));
    assert_eq!(cap_of("cloud.quota.exceeded", "x", None), Some(Cap::Running));
    assert_eq!(cap_of("", "this plan allows 5 active machines", None), Some(Cap::Running));
    assert_eq!(
        cap_of(
            "cloud.provider.unavailable",
            "VM API: this team has its limit of 20 machines (paused ones count); delete one to make another",
            None
        ),
        Some(Cap::Held)
    );
    assert_eq!(
        cap_of(
            "cloud.quota.exceeded",
            "this plan allows 200 machines in all, paused ones included; delete one first",
            None
        ),
        Some(Cap::Held)
    );
    assert_eq!(cap_of("cloud.spend_cap.reached", "x", None), Some(Cap::Spend));
    assert_eq!(cap_of("cmux.cloud.spend_cap_reached", "x", None), Some(Cap::Spend));
    assert_eq!(cap_of("cloud.provider.unavailable", "VM API: HTTP 429", None), None);
    assert_eq!(cap_of("app.unreachable", "no app", None), None);
    // cmux-platform's `details.resource` decides over its words.
    assert_eq!(cap_of("cloud.quota.exceeded", "any words", Some("machines")), Some(Cap::Held));
    // The VM limit by its own code, whatever its words.
    assert_eq!(cap_of("cloud.quota.vm_limit", "any words", None), Some(Cap::Held));
    assert_eq!(cap_of("cmux.cloud.vm_limit", "any words", None), Some(Cap::Held));
    assert_eq!(cap_of("cloud.quota.exceeded", "any words", Some("active")), Some(Cap::Running));
    assert_eq!(
        cap_of("cloud.quota.exceeded", "this plan keeps 200 saved snapshots", Some("saved")),
        None
    );
    assert_eq!(
        cap_of(
            "cloud.quota.exceeded",
            "a team keeps at most 50 environments",
            Some("environments")
        ),
        None
    );
    assert_eq!(cap_of("cloud.spend_cap.reached", "x", Some("active")), Some(Cap::Spend));
    // The app's string-only failure and a stage's reason carry cmux-platform's words, not its code.
    assert_eq!(
        cap_of(
            "unavailable",
            "could not create machine \"w\": this team has reached its spending cap; an admin can raise it",
            None
        ),
        Some(Cap::Spend)
    );
    assert_eq!(
        cap_of(
            "",
            "this team has spent 40.00 USD of its 40.00 USD spending cap; an admin can raise it",
            None
        ),
        Some(Cap::Spend)
    );
}

/// The held cap's refusal, with the machine the platform offers to free (`details.free_up`).
fn held_refusal(free_up: Value) -> Ran {
    Ran {
        code: 1,
        stderr: json!({"code": "cmux.cloud.quota_exceeded",
                       "message": "VM API: this team has its limit of 3 machines (paused ones count)",
                       "details": {"resource": "machines", "free_up": free_up}})
        .to_string(),
        ..Ran::default()
    }
}

fn three_machines() -> Ran {
    listed_machines(json!([
        {"machine_id": "vm-a", "title": "api", "status": "running"},
        {"machine_id": "vm-b", "title": "web", "status": "paused", "last_active_at": 20},
        {"machine_id": "vm-c", "title": "old", "status": "paused", "last_active_at": 10},
    ]))
}

/// The Cloud app's own records (`cloud.machine.list`): keep and last use on each; the kept one is
/// used longest ago and is never the pick.
fn records() -> Ran {
    ok(json!({"machines": [
        {"id": "vm-a", "name": "api", "status": "running", "keep": false, "last_active_at": 30},
        {"id": "vm-b", "name": "web", "status": "paused", "keep": false, "last_active_at": 20},
        {"id": "vm-c", "name": "old", "status": "paused", "keep": false, "last_active_at": 10},
        {"id": "vm-k", "name": "pinned", "status": "paused", "keep": true, "last_active_at": 1},
    ]}))
}

#[test]
fn a_cap_refusal_offers_make_room_with_the_machine_the_platform_names() {
    let free = json!({"machine": "vm-b", "name": "web", "reason": "never_used"});
    let mut fake = Fake::new(vec![three_machines(), held_refusal(free)]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "hi"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.machine_cap");
    let message = error["message"].as_str().unwrap();
    assert!(
        message.contains(
            "Make room: `cmux cloud start-chat --prompt TEXT --json --make-room` deletes web first"
        ),
        "{message}"
    );
    assert_eq!(error["details"]["make_room"]["how"], "delete");
    assert_eq!(
        error["details"]["make_room"]["command"],
        "cmux vm kill-machine --target vm:vm-b --confirm"
    );
    // Nothing was deleted without --make-room.
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);
}

#[test]
fn make_room_deletes_the_offered_machine_and_starts_again_once() {
    let free = json!({"machine": "vm-b", "name": "web", "reason": "failed_create"});
    let sent = exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n");
    let mut fake = Fake::new(vec![
        three_machines(),
        held_refusal(free),
        ok(json!({"deleted": true})),
        three_machines(),
        started(),
        sent,
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "hi", "--make-room"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(
        fake.ran[2],
        strings(&["cloud", "kill-machine", "--target", "machine:vm-b", "--confirm", "--json"])
    );
}

#[test]
fn make_room_with_nothing_named_archives_the_oldest_paused_machine_and_says_to_ask_again() {
    let mut fake = Fake::new(vec![
        three_machines(),
        held_refusal(Value::Null),
        records(),
        ok(json!({"machine": {}})),
    ]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--prompt", "hi", "--make-room"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.make_room_archiving");
    assert_eq!(fake.ran[2][..4], strings(&["apps", "run", "cmux/cloud", "cloud.machine.list"]));
    assert_eq!(
        fake.ran[3],
        strings(&["cloud", "archive-machine", "--target", "machine:vm-c", "--confirm", "--json"])
    );
    assert!(error["message"].as_str().unwrap().starts_with("archiving old:"), "{error}");
}

#[test]
fn make_room_that_is_refused_says_so_and_starts_nothing() {
    let refused = Ran {
        code: 1,
        stderr: json!({"code": "cloud.gesture_required", "message": "archive and delete needs a person"})
            .to_string(),
        ..Ran::default()
    };
    let mut fake = Fake::new(vec![three_machines(), held_refusal(Value::Null), records(), refused]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--prompt", "hi", "--make-room"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "cloud.make_room_failed");
    assert_eq!(fake.ran.len(), 4, "{:?}", fake.ran);
}

#[test]
fn make_room_deletes_only_a_machine_the_platform_names_by_id() {
    use super::cap::{Cap, room, used_ms};
    let listed = json!({"machines": [
        {"machine_id": "vm-c", "title": "old", "status": "paused", "created_at": "2026-01-02T00:00:00Z"},
        {"machine_id": "vm-s", "title": "scratch", "status": "running"},
    ]});
    // The running cap: only a named free_up.
    assert_eq!(room(Cap::Running, &json!({}), &listed), None);
    let named = room(Cap::Running, &json!({"free_up": {"machine": "vm-c", "name": null}}), &listed);
    assert_eq!(
        named.map(|room| (room.machine, room.name, room.archive)),
        Some(("vm-c".into(), "old".into(), false))
    );
    // Never a delete from the refusal's words: with no id, only an archive is offered, and its
    // machine is picked from the full records when it runs.
    let offered = room(Cap::Held, &json!({}), &listed).unwrap();
    assert!(offered.archive && offered.machine.is_empty(), "{offered:?}");
    // A kept machine is never archived.
    let kept = json!({"machines": [{"machine_id": "vm-c", "status": "paused", "keep": true}]});
    assert_eq!(room(Cap::Held, &json!({}), &kept), None);
    assert_eq!(used_ms(&json!({"created_at": "1970-01-01T00:00:01Z"})), Some(1000));
    assert_eq!(used_ms(&json!({"last_active_at": 5, "created_at": 9})), Some(5));
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
        ("start-session, --wait", &["--prompt", "x", "--wait"]),
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
    let mut runner = SelfRunner { globals: Vec::new(), global: GlobalArgs::default() };
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
        model: None,
        cwd: None,
        from_folder: None,
        login: None,
        environment: None,
        machine: Machine::Target("vm-1".into()),
        wait: true,
        timeout: Duration::from_secs(60),
        make_room: false,
        allow_large: false,
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
        model: None,
        cwd: None,
        from_folder: None,
        login: None,
        environment: None,
        machine: Machine::Target("vm-1".into()),
        wait: true,
        timeout: Duration::from_secs(secs),
        make_room: false,
        allow_large: false,
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
            run(&mut fake, &request(&["--prompt", "x", "--environment", "env_1", "--wait"]))
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
    let asked = request(&["--prompt", "x", "--environment", "env_1", "--wait", "--timeout", "14"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(error["details"]["creation_id"], "c-1", "{error}");
    assert_eq!(error["details"]["machine_name"], "chat-fresh", "{error}");
    assert!(
        error["details"]["again"].as_str().unwrap_or_default().contains("--name chat-fresh"),
        "{error}"
    );
}

/// A read the app could not get to the Cloud API at all is asked again, like one it did not answer in time.
#[test]
fn an_unreachable_read_of_the_turn_is_asked_again() {
    let unreachable = Ran {
        code: 1,
        stdout: String::new(),
        stderr: json!({"code": "daemon_error", "data": {"action": "cloudExec"},
                       "message": "exec on Cloud machine: Couldn't reach cmux Cloud (The network connection was \
                                   lost.). Check your network, then try again."})
        .to_string(),
    };
    let mut fake =
        Fake::new(vec![signed_in(), started(), exec_out(SENT), unreachable, exec_out(REPLIED)]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "x", "--wait"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["unanswered_reads"], 1);
}

/// Leo (2026-11-09): "this no folder selected should be, like, good as well". A start with no
/// `--cwd` and no `--from-folder` is a first-class one: the answer says the chat runs in a fresh
/// folder of its own (`folder: fresh`), names that folder as the machine reports it (`cwd`, read in
/// the send's own exec, so no extra round trip), and gives the way to a repository later
/// (`follow_up.cd`). Nothing waits on a folder: the same steps as any start.
#[test]
fn a_folderless_start_is_fresh_and_reports_the_folder_the_machine_made() {
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out(
            "@@cwd\n{\"sessions\":[{\"sessionId\":\"other\",\"cwd\":\"/home/cmux/work/api\"},\
             {\"sessionId\":\"sess-1\",\"cwd\":\"/home/cmux/chats/peer-7\"}]}\n\
             @@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n",
        ),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "hi"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["folder"], "fresh");
    assert_eq!(answer["cwd"], "/home/cmux/chats/peer-7");
    assert_eq!(answer["follow_up"]["cd"], "cmux chat cd sess-1 DIR|--repo OWNER/NAME");
    // start-session gets no folder, and the send reads where the chat runs in the same exec.
    assert_eq!(
        fake.ran[1],
        strings(&["cloud", "start-session", "--name", "chat-fresh", "--agent", "claude", "--json"])
    );
    assert_eq!(fake.ran.len(), 3, "no step waits on a folder: {:?}", fake.ran);
    assert!(fake.ran[2][5].contains("acp ls --live --machine local --json --fields sessionId,cwd"));
}

#[test]
fn the_folder_kind_and_the_session_folder_read() {
    assert_eq!(folder_kind(None, None), "fresh");
    assert_eq!(folder_kind(Some("/home/cmux/work/api"), None), "given");
    assert_eq!(folder_kind(None, Some("/Users/you/src/cmux")), "copied");
    let rows = "[{\"id\":\"s-2\",\"cwd\":\"/root/chats/s-2\"}]".to_owned();
    assert_eq!(session_cwd(Some(&rows), "s-2").as_deref(), Some("/root/chats/s-2"));
    assert_eq!(session_cwd(Some(&rows), "s-3"), None);
    assert_eq!(session_cwd(Some(&"not json".to_owned()), "s-2"), None);
    assert_eq!(session_cwd(None, "s-2"), None);
    // A start with no read (an older machine's ls) still answers: given keeps its --cwd.
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
    ]);
    let given = request(&["--prompt", "hi", "--cwd", "/home/cmux/work/api"]);
    let Outcome::Done(answer) = run(&mut fake, &given) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["folder"], "given");
    assert_eq!(answer["cwd"], "/home/cmux/work/api");
}
