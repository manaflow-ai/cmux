//! headless.rs: with no app, a Cloud chat starts, is listed, paused and messaged on a fake cmux API, with the
//! same answers the app path gives.

use std::cell::RefCell;
use std::rc::Rc;

use super::super::{Outcome, Parsed, Request, parse, read_on, run, send_to};
use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn request(words: &[&str]) -> Request {
    match parse(&strings(words), || Ok(String::new())) {
        Ok(Parsed::Run(request)) => *request,
        other => panic!("{words:?}: {other:?}"),
    }
}

fn machine(id: &str, name: &str, status: &str) -> Row {
    Row {
        id: id.into(),
        name: Some(name.into()),
        status: status.into(),
        host: status == "running",
        created_at: 1,
        keep: None,
    }
}

/// What the fake cmux API holds and was asked.
#[derive(Default)]
struct State {
    machines: Vec<Row>,
    /// Reads of a new machine before it runs.
    boots: u32,
    calls: Vec<String>,
    execs: Vec<String>,
}

#[derive(Clone, Default)]
struct FakeApi(Rc<RefCell<State>>);

impl FakeApi {
    fn with(machines: Vec<Row>) -> Self {
        let fake = Self::default();
        fake.0.borrow_mut().machines = machines;
        fake
    }

    fn find(&self, id: &str) -> Result<Row, Value> {
        self.0
            .borrow()
            .machines
            .iter()
            .find(|row| row.id == id)
            .cloned()
            .ok_or_else(|| json!({"code": "cloud.machine.not_found", "message": id}))
    }

    fn set(&self, id: &str, status: &str) -> Result<Row, Value> {
        let mut state = self.0.borrow_mut();
        let row = state
            .machines
            .iter_mut()
            .find(|row| row.id == id)
            .ok_or_else(|| json!({"code": "cloud.machine.not_found", "message": id}))?;
        row.status = status.into();
        row.host = status == "running";
        Ok(row.clone())
    }
}

impl Api for FakeApi {
    fn list(&mut self) -> Result<Vec<Row>, Value> {
        self.0.borrow_mut().calls.push("list".into());
        Ok(self.0.borrow().machines.clone())
    }

    fn create(&mut self, name: &str) -> Result<Row, Value> {
        let mut state = self.0.borrow_mut();
        state.calls.push(format!("create {name}"));
        let mut row = machine("vm-new", name, "creating");
        row.host = false;
        state.machines.push(row.clone());
        Ok(row)
    }

    fn get(&mut self, id: &str) -> Result<Row, Value> {
        self.0.borrow_mut().calls.push(format!("get {id}"));
        let boots = {
            let mut state = self.0.borrow_mut();
            state.boots += 1;
            state.boots
        };
        if boots >= 2 && self.find(id)?.status == "creating" {
            return self.set(id, "running");
        }
        self.find(id)
    }

    fn pause(&mut self, id: &str) -> Result<Row, Value> {
        self.0.borrow_mut().calls.push(format!("pause {id}"));
        self.set(id, "pausing")
    }

    fn resume(&mut self, id: &str) -> Result<Row, Value> {
        self.0.borrow_mut().calls.push(format!("resume {id}"));
        self.set(id, "running")
    }

    fn delete(&mut self, id: &str) -> Result<(), Value> {
        self.0.borrow_mut().calls.push(format!("delete {id}"));
        self.0.borrow_mut().machines.retain(|row| row.id != id);
        Ok(())
    }

    fn exec(&mut self, id: &str, command: &str, _timeout_ms: u64) -> Result<Executed, Value> {
        let row = self.find(id)?;
        assert_eq!((row.status.as_str(), row.host), ("running", true), "exec on {id}");
        self.0.borrow_mut().execs.push(command.to_owned());
        let stdout = if command.contains("'session/new'") {
            "@@session sess-1\n".to_owned()
        } else if command.contains("acp send --no-wait") {
            "@@history\n@@send\n@@exit 0\n".to_owned()
        } else if command.contains("acp tail") {
            "@@events\n{\"seq\":1,\"kind\":\"user\",\"text\":\"hi\"}\n@@exit 0\n".to_owned()
        } else {
            String::new()
        };
        Ok(Executed { exit_code: 0, stdout, stderr: String::new() })
    }
}

fn runner(fake: &FakeApi) -> HeadlessRunner {
    HeadlessRunner::new(Box::new(fake.clone()), OutputMode::Json)
}

/// L10: with no app, `cloud start-chat` makes a new machine, waits for it to run and starts the chat's agent on
/// its acpmux, answering the app path's ids and follow-ups.
#[test]
fn a_start_with_no_app_makes_the_machine_and_starts_the_chat() {
    let fake = FakeApi::default();
    let outcome = run(&mut runner(&fake), &request(&["--agent", "claude"]));
    let Outcome::Done(answer) = outcome else { panic!("{outcome:?}") };
    assert_eq!(answer["machine_id"], "vm-new");
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(answer["target"], "machine:vm-new");
    assert_eq!(answer["sent"], false);
    assert!(answer["follow_up"].is_object(), "{answer}");
    let state = fake.0.borrow();
    let made: Vec<_> = state.calls.iter().filter(|c| c.starts_with("create ")).collect();
    assert_eq!(made.len(), 1, "{:?}", state.calls);
    assert_eq!(answer["machine_name"].as_str(), made[0].strip_prefix("create "));
    // The agent starts through acpmux's session/new, with no launch credential in the command.
    let start = state.execs.iter().find(|c| c.contains("'session/new'")).expect("the start");
    assert!(start.contains("\\\"harness\\\":\\\"claude\\\""), "{start}");
    assert!(!start.contains("credentials"), "{start}");
}

/// A start with a prompt sends it to the new chat with the same `acp send` the app path's exec runs.
#[test]
fn a_start_with_a_prompt_sends_it_on_a_named_machine() {
    let fake = FakeApi::with(vec![machine("vm-1", "dev", "paused")]);
    let outcome = run(&mut runner(&fake), &request(&["--name", "dev", "-p", "hello there"]));
    let Outcome::Done(answer) = outcome else { panic!("{outcome:?}") };
    assert_eq!(
        (answer["machine_id"].as_str(), answer["sent"].as_bool()),
        (Some("vm-1"), Some(true))
    );
    let state = fake.0.borrow();
    assert!(state.calls.contains(&"resume vm-1".to_owned()), "{:?}", state.calls);
    assert!(!state.calls.iter().any(|c| c.starts_with("create ")), "{:?}", state.calls);
    let send = state.execs.iter().find(|c| c.contains("acp send --no-wait")).expect("the send");
    assert!(send.contains("hello there") && send.contains("sess-1"), "{send}");
}

/// The list answers in the app's shape: signed in, loaded, a row per machine with `machine_id` and `title`.
#[test]
fn list_and_pause_answer_in_the_apps_shape() {
    let mut fake = FakeApi::with(vec![machine("vm-1", "dev", "running")]);
    let listed = super::super::step_result(&answer(
        &mut fake,
        &strings(&["cloud", "list-machines", "--json"]),
        &mut |_| {},
    ))
    .unwrap();
    assert_eq!(listed["account"]["signed_in"], true);
    assert_eq!(listed["loaded"], true);
    assert_eq!(listed["machines"][0]["machine_id"], "vm-1");
    assert_eq!(listed["machines"][0]["title"], "dev");
    assert_eq!(listed["machines"][0]["status"], "running");

    let paused = super::super::step_result(&answer(
        &mut fake,
        &strings(&["cloud", "pause-machine", "--target", "machine:vm-1", "--json"]),
        &mut |_| {},
    ))
    .unwrap();
    assert_eq!(
        (paused["machine_id"].as_str(), paused["status"].as_str()),
        (Some("vm-1"), Some("pausing"))
    );
    let missing = super::super::step_result(&answer(
        &mut fake,
        &strings(&["cloud", "pause-machine", "--target", "machine:vm-9", "--json"]),
        &mut |_| {},
    ))
    .unwrap_err();
    assert_eq!(missing["code"], "cloud.machine.not_found");
}

/// `cmux chat send|read SESSION --on vm:ID` with no app: the prompt and the read reach the running chat.
#[test]
fn an_existing_chat_is_messaged_and_read_with_no_app() {
    let fake = FakeApi::with(vec![machine("vm-1", "dev", "running")]);
    let mut request = request(&["--target", "machine:vm-1", "-p", "next step"]);
    request.agent = String::new();
    let outcome = send_to(&mut runner(&fake), &request, "vm-1", "sess-1");
    let Outcome::Done(answer) = outcome else { panic!("{outcome:?}") };
    assert_eq!(
        (answer["session_id"].as_str(), answer["sent"].as_bool()),
        (Some("sess-1"), Some(true))
    );
    let page = read_on(&mut runner(&fake), "vm-1", "sess-1", 0, 10);
    assert!(matches!(page, Outcome::Done(ref page) if page["machine_id"] == "vm-1"), "{page:?}");
}

/// A verb the app alone answers says so and names the verbs that run with no app; a folder copy too.
#[test]
fn a_verb_with_no_headless_answer_names_the_app() {
    let mut fake = FakeApi::default();
    let error = super::super::step_result(&answer(
        &mut fake,
        &strings(&["cloud", "new-machine", "--name", "x", "--json"]),
        &mut |_| {},
    ))
    .unwrap_err();
    assert_eq!(error["code"], UNSUPPORTED);
    assert!(error["message"].as_str().unwrap().contains("cloud start-session"), "{error}");
    let start =
        strings(&["cloud", "start-session", "--name", "x", "--from-folder", "/tmp/p", "--json"]);
    let error = super::super::step_result(&answer(&mut fake, &start, &mut |_| {})).unwrap_err();
    assert_eq!(error["code"], UNSUPPORTED);
    assert!(fake.0.borrow().calls.is_empty());
}

/// The login flags are taken off the command line before its own parse; the rest stays as typed.
#[test]
fn the_login_flags_are_taken_and_the_rest_kept() {
    let (rest, login) = take_login(&strings(&[
        "--cloud-token-file",
        "/run/t",
        "--cloud-api=https://api.example",
        "-p",
        "hi",
        "--",
        "--team",
        "x",
    ]));
    assert_eq!(rest, strings(&["-p", "hi", "--", "--team", "x"]));
    assert_eq!(login.token_file.as_deref(), Some(std::path::Path::new("/run/t")));
    assert_eq!(login.api.as_deref(), Some("https://api.example"));
    assert_eq!(login.team, None);
}

/// The not-signed-in refusal names what to do and never the login.
#[test]
fn not_signed_in_names_the_next_step() {
    let error = not_signed_in("the --cloud-token-file could not be read (NotFound)");
    assert_eq!(error["code"], "cloud.signed_out");
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("CMUX_CLOUD_ACCESS_TOKEN") && message.contains("--cloud-token-file"));
}
