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
            prompt: "hi there".into(),
            agent: "claude".into(),
            cwd: None,
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
    assert_eq!(request(&["--prompt", "-"]).prompt, "from stdin");
}

#[test]
fn parse_refuses_what_start_session_would() {
    for words in [
        vec![],
        vec!["--prompt", "  "],
        vec!["--prompt", "x", "--cwd", "relative"],
        vec!["--prompt", "x", "--agent", "Claude Code"],
        vec!["--prompt", "x", "--name", "a", "--target", "machine:b"],
        vec!["--prompt", "x", "--timeout", "soon"],
        vec!["--prompt", "x", "--bogus"],
        vec!["--prompt"],
    ] {
        assert!(parse(&strings(&words), || Ok(String::new())).is_err(), "{words:?}");
    }
    assert_eq!(parse(&strings(&["--help"]), || Ok(String::new())), Ok(Parsed::Help));
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
    let mut asked = request(&["--prompt", "it's done", "--cwd", "/a b", "--wait"]);
    asked.agent = "codex".into();
    assert_eq!(
        again_command(&asked, &Machine::Named("chat-1".into())),
        "cmux cloud start-chat --name chat-1 --agent codex --cwd '/a b' --prompt 'it'\\''s done' --wait --json"
    );
}

/// A fake app: answers each step from a queue and records what ran.
struct Fake {
    answers: VecDeque<Ran>,
    ran: Vec<Vec<String>>,
    clock: Instant,
    paused: Duration,
}

impl Fake {
    fn new(answers: Vec<Ran>) -> Self {
        Self {
            answers: answers.into(),
            ran: Vec::new(),
            clock: Instant::now(),
            paused: Duration::ZERO,
        }
    }
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.ran.push(args.to_vec());
        // Each step takes a few seconds of the wait.
        self.clock += Duration::from_secs(5);
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
    assert_eq!(
        answer["follow_up"]["send"],
        "cmux cloud chat send --target machine:vm-1 --session sess-1 --prompt 'PROMPT'"
    );
    assert_eq!(
        answer["follow_up"]["last"],
        "cmux cloud chat last --target machine:vm-1 --session sess-1"
    );
    assert_eq!(fake.ran[1], strings(&["cloud", "new-machine", "--json"]));
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
    assert_eq!(fake.ran[1][3], "dev");
    assert_eq!(fake.ran.len(), 3);
}

#[test]
fn a_signed_out_app_says_how_to_sign_in() {
    let mut fake = Fake::new(vec![ok(json!({"account": {"signed_in": false}, "machines": []}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x"])) else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.signed_out"), 1));
    assert!(error["message"].as_str().unwrap().contains("cmux cloud sign-in"));
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
        "cmux cloud start-chat --name chat-fresh --prompt x --wait --json"
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

    // A --timeout shorter than the relay's answer window goes the link way.
    let mut answers = vec![signed_in(), made(), started(), sent()];
    answers.extend((0..3).map(|_| exec_out(&format!("@@wait 3\n{running}"))));
    let mut fake = Fake::new(answers);
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "10"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert!(
        error["message"].as_str().unwrap().contains(
            "cmux cloud chat status --target machine:vm-1 --session sess-1 --after 0 --wait 20"
        ),
        "{error}"
    );
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
        made(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n"),
        exec_out(running),
        exec_out(running),
    ]);
    let asked = request(&["--prompt", "x", "--wait", "--timeout", "7"]);
    let Outcome::Failed { error, .. } = run(&mut fake, &asked) else { panic!() };
    assert_eq!(error["code"], "chat.wait_timeout");
    assert!(fake.ran[4][5].contains("acp wait sess-1 --timeout 7 "), "{:?}", fake.ran[4]);
    assert!(fake.ran[5][5].contains("acp wait sess-1 --timeout 2 "), "{:?}", fake.ran[5]);
}

#[test]
fn output_flags_are_lifted_but_a_flag_value_stays() {
    let mut output = OutputMode::Human;
    let words = lift_output(&strings(&["--prompt", "--json", "--wait", "--json"]), &mut output);
    assert_eq!(words, strings(&["--prompt", "--json", "--wait"]));
    assert_eq!(output, OutputMode::Json);
    assert_eq!(request(&["--prompt", "--json", "--wait"]).prompt, "--json");
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
                       "first_text_ms": 2100, "total_ms": 2500})),
    ]);
    let asked = request(&["--prompt", "What is 2+2?", "--cwd", "/home/cmux/w", "--wait"]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "4");
    assert_eq!(answer["path"], "relay");
    assert_eq!(answer["session_id"], "relay-1");
    assert_eq!(answer["first_text_ms"], 2100);
    assert_eq!(answer["stop_reason"], "end_turn");
    assert_eq!(
        answer["follow_up"]["status"],
        "cmux cloud chat status --target machine:vm-1 --session relay-1 --wait 20"
    );
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

    let mut fake = Fake::new(vec![signed_in(), ok(json!({"pending": true, "status": "creating"}))]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!()
    };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(fake.ran.len(), 2);
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
    // The relay step took 5 s of the 47: waits of 20 s while 20 s are left, then the rest, down to 2 s.
    let asked =
        request(&["--prompt", "x", "--target", "machine:vm-1", "--wait", "--timeout", "47"]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!((error["code"].as_str(), exit), (Some("chat.wait_timeout"), 3));
    assert!(fake.ran[2][5].contains("acp wait relay-1 --timeout 20 "), "{:?}", fake.ran[2]);
    assert!(fake.ran[10][5].contains("acp wait relay-1 --timeout 2 "), "{:?}", fake.ran[10]);
    assert_eq!(fake.ran.len(), 11);
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
