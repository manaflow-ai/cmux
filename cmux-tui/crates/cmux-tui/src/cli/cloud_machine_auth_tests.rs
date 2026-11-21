use super::super::cloud_start_chat::Ran;
use super::*;
use std::time::{Duration, Instant};

struct Fake {
    answer: (i32, String, String),
    asked: Vec<Vec<String>>,
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.asked.push(args.to_vec());
        Ran { code: self.answer.0, stdout: self.answer.1.clone(), stderr: self.answer.2.clone() }
    }
    fn pause(&mut self, _: Duration) {}
    fn now(&mut self) -> Instant {
        Instant::now()
    }
    fn fresh_name(&mut self) -> String {
        String::new()
    }
}

fn fake(code: i32, stdout: Value) -> Fake {
    Fake { answer: (code, stdout.to_string(), String::new()), asked: Vec::new() }
}

#[test]
fn it_parses_the_machine() {
    let mut out = OutputMode::Human;
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(parse(&words(&["--machine", "vm_1", "--json"]), &mut out), Ok(Some("vm_1".into())));
    assert_eq!(out, OutputMode::Json);
    assert_eq!(parse(&words(&["--target=machine:vm_2"]), &mut out), Ok(Some("vm_2".into())));
    assert_eq!(parse(&words(&["--help"]), &mut out), Ok(None));
    assert!(parse(&words(&[]), &mut out).is_err());
    assert!(parse(&words(&["--machine", "vm;rm"]), &mut out).is_err());
}

#[test]
fn the_machine_flag_after_the_verb_is_the_verbs_own() {
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    let (_, rest) =
        verb_args(&words(&["--json", "cloud", "machine-auth", "--machine", "vm_1"])).unwrap();
    assert_eq!(rest, ["--machine", "vm_1"]);
    let (_, rest) = verb_args(&words(&["--machine", "vm_2", "cloud", "machine-auth"])).unwrap();
    assert_eq!(rest, ["--machine", "vm_2"]);
    let (_, rest) = verb_args(&words(&["cloud", "machine-auth", "--target=machine:vm_3"])).unwrap();
    assert_eq!(rest, ["--target=machine:vm_3"]);
    assert!(verb_args(&words(&["cloud", "machine-status"])).is_none());
}

#[test]
fn it_returns_the_machine_report_with_its_id() {
    let report = json!({"ok": true, "agents": {"claude": {}, "codex": {}}});
    let mut runner =
        fake(0, json!({"result": {"stdout": format!("noise\n{report}\n"), "exit_code": 0}}));
    let got = ask(&mut runner, "vm_1", &Route::App).unwrap();
    assert_eq!(got["machine_id"], "vm_1");
    assert_eq!(got["ok"], true);
    let args = &runner.asked[0];
    assert_eq!(args[..4], ["cloud", "exec", "--target", "machine:vm_1"]);
    assert!(args[5].contains("acp --json machine-auth"));
}

#[test]
fn a_caller_with_its_own_credential_asks_the_machine_without_the_app() {
    let report = json!({"ok": false, "holds_credential": true, "agents": {"claude": {}}});
    // `machine access exec --json` answers the command's output at the top, not under `result`.
    let mut runner =
        fake(0, json!({"machine": "vm_1", "exit_code": 0, "stdout": format!("{report}\n")}));
    let route = Route::Direct { team: Some("team_1".into()) };
    let got = ask(&mut runner, "vm_1", &route).unwrap();
    assert_eq!(
        (got["machine_id"].as_str(), got["holds_credential"].as_bool()),
        (Some("vm_1"), Some(true))
    );
    let args = &runner.asked[0];
    assert_eq!(args[..6], ["--json", "machine", "access", "exec", "--target", "machine:vm_1"]);
    assert_eq!(args[8..11], ["--team", "team_1", "--"]);
    assert!(args[11].contains("acp --json machine-auth"));

    let global =
        |app: Option<&str>| GlobalArgs { app_socket: app.map(Into::into), ..GlobalArgs::default() };
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    let token = &[("CMUX_CLOUD_ACCESS_TOKEN", "t"), ("CMUX_CLOUD_TEAM", "team_9")];
    assert_eq!(
        Route::choose(&global(None), env(token)),
        Route::Direct { team: Some("team_9".into()) }
    );
    assert_eq!(
        Route::choose(&global(Some("/s")), env(token)),
        Route::App,
        "an app socket named wins"
    );
    assert_eq!(Route::choose(&global(None), env(&[("CMUX_CLOUD_ACCESS_TOKEN", " ")])), Route::App);
}

#[test]
fn an_old_machine_or_an_exec_refusal_is_typed() {
    let mut runner = fake(0, json!({"result": {"stdout": "", "exit_code": 0}}));
    assert_eq!(
        ask(&mut runner, "vm_1", &Route::App).unwrap_err()["code"],
        "machine_auth.unsupported"
    );
    let mut runner = fake(0, json!({"result": {"stdout": "{\"x\":1}"}}));
    assert_eq!(
        ask(&mut runner, "vm_1", &Route::App).unwrap_err()["code"],
        "machine_auth.invalid_reply"
    );
    let refusal = json!({"code": "vm_not_running", "message": "paused"}).to_string();
    let mut runner = Fake { answer: (1, String::new(), refusal), asked: Vec::new() };
    assert_eq!(ask(&mut runner, "vm_1", &Route::App).unwrap_err()["code"], "vm_not_running");
}
