//! `cmux cloud machine-auth --machine vm_… [--json]`: how a Cloud machine's agents reach models,
//! and whether the machine holds any provider login.
//!
//! It runs `cmux-tui acp --json machine-auth` on the machine (as the machine's work user, whose
//! daemon it reads) and prints that report with `machine_id` added. The command goes through the
//! app's `cloud exec`, or, for a caller with its own credential (`CMUX_CLOUD_ACCESS_TOKEN`, a
//! script or the Cloud self-test, no app), through `machine access exec` (a client session
//! straight to the machine, `--team` from `CMUX_CLOUD_TEAM`).
//! The report has names, verdicts and credential-free base URLs only (acpmux
//! `cli/machine_auth.rs`), never a key or a token. Exit 0 when the report says `ok`, 1 when it
//! does not, 2 for a usage error; a machine that cannot answer is a typed error:
//! `machine_auth.unsupported` (its cmux-tui predates the verb: update the machine),
//! `machine_auth.invalid_reply`, or `cloud exec`'s own code (`vm_not_running`, `vm_not_found`, …).

use serde_json::{Value, json};

use super::cloud_start_chat::{Runner, self_runner, step_result};
use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "usage: cmux cloud machine-auth --machine VM_ID [--json]

How the agents on a Cloud machine reach models: each agent's base URL, whether its
key is the edge's placeholder, and whether the machine holds a provider login
(Claude or Codex login files, a login in Claude's settings, a credential variable in
the agent daemon's environment). Prints names and verdicts only, never a value.

  --machine VM_ID    the machine (also --target machine:VM_ID)

With CMUX_CLOUD_ACCESS_TOKEN set (and no --app-socket) it needs no app: it asks the machine
through a client session (`cmux machine access exec`), in the team CMUX_CLOUD_TEAM names.

JSON: {machine_id, ok, cloud_vm, edge_host, model_plane: {path, state},
       daemon: {running, pid}, agents: {claude|codex: {base_url, base_url_source,
       key_var, key, key_source, edge_routed}}, credential_env: [NAME],
       login_files: [{path, agent, kind, names?}], holds_credential,
       managed_route_files: [{path, agent, present}]}
Exit 0 when ok, 1 when not.
";

/// The machine-side command, as the work user when exec runs as root (shared with the Cloud
/// start's own check, `cmux_cloud_start_core::machine_route`).
const GUEST: &str = cmux_cloud_start_core::machine_route::GUEST;

/// `Some(exit code)` when `args` is `cloud machine-auth …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, rest) = verb_args(args)?;
    let mut output = global.output;
    let machine = match parse(&rest, &mut output) {
        Ok(Some(machine)) => machine,
        Ok(None) => {
            print!("{USAGE}");
            return Some(0);
        }
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}\n{USAGE}"),
                output,
                2,
            ));
        }
    };
    Some(run(&global, output, &machine))
}

/// The globals and the verb's own words when `args` is `cloud machine-auth …`. A `--machine` after
/// the verb is the verb's (the global option would swallow it: "--machine is required"); one
/// before it, `cmux --machine vm_… cloud machine-auth`, names the machine too.
pub(super) fn verb_args(args: &[String]) -> Option<(GlobalArgs, Vec<String>)> {
    let (global, command_args) = super::parse_action_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != "machine-auth" {
        return None;
    }
    let mut rest = rest.to_vec();
    let named = rest.iter().any(|w| {
        ["--machine", "--target"]
            .iter()
            .any(|flag| w == flag || w.strip_prefix(flag).is_some_and(|tail| tail.starts_with('=')))
    });
    if let Some(machine) = global.machine.clone().filter(|_| !named) {
        rest.extend(["--machine".to_owned(), machine]);
    }
    Some((global, rest))
}

/// The machine id, `None` for `--help`.
pub(super) fn parse(words: &[String], output: &mut OutputMode) -> Result<Option<String>, String> {
    let mut machine = None;
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "-h" | "--help" => return Ok(None),
            "--json" => *output = OutputMode::Json,
            "--machine" | "--target" => {
                let value =
                    inline.or_else(|| it.next().cloned()).ok_or(format!("{flag} needs a value"))?;
                let id = value.strip_prefix("machine:").unwrap_or(&value).trim().to_owned();
                if id.is_empty()
                    || !id.chars().all(|c| c.is_ascii_alphanumeric() || "-_".contains(c))
                {
                    return Err(format!("{flag} {value:?}: a machine id such as vm_…"));
                }
                machine = Some(id);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    machine.map(Some).ok_or_else(|| "--machine is required".to_owned())
}

/// How the command reaches the machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Route {
    /// The app's `cloud exec`.
    App,
    /// `machine access exec` with the caller's own credential, in this team.
    Direct { team: Option<String> },
}

impl Route {
    /// Direct when the caller holds its own credential and named no app socket.
    pub(super) fn choose(global: &GlobalArgs, env: impl Fn(&str) -> Option<String>) -> Self {
        let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
        if global.app_socket.is_some() || set("CMUX_CLOUD_ACCESS_TOKEN").is_none() {
            return Self::App;
        }
        Self::Direct { team: set("CMUX_CLOUD_TEAM") }
    }

    fn args(&self, machine: &str) -> Vec<String> {
        let target = format!("machine:{machine}");
        match self {
            Self::App => {
                ["cloud", "exec", "--target", target.as_str(), "--command", GUEST, "--json"]
                    .map(str::to_owned)
                    .to_vec()
            }
            Self::Direct { team } => {
                let mut args: Vec<String> = [
                    "--json",
                    "machine",
                    "access",
                    "exec",
                    "--target",
                    target.as_str(),
                    "--timeout-ms",
                    "60000",
                ]
                .map(str::to_owned)
                .to_vec();
                if let Some(team) = team {
                    args.extend(["--team".to_owned(), team.clone()]);
                }
                args.extend(["--".to_owned(), GUEST.to_owned()]);
                args
            }
        }
    }
}

fn reply_error(code: &str, message: &str, machine: &str) -> Value {
    json!({"code": code, "message": message, "retryable": false, "details": {"machine_id": machine}})
}

/// The machine's report with its id, or the error object.
pub(super) fn ask(runner: &mut dyn Runner, machine: &str, route: &Route) -> Result<Value, Value> {
    let result = step_result(&runner.cmux(&route.args(machine)))?;
    let stdout = result.get("stdout").and_then(Value::as_str).unwrap_or_default();
    use cmux_cloud_start_core::machine_route::{Reported, report};
    match report(stdout) {
        Reported::Report(mut report) => {
            if let Some(fields) = report.as_object_mut() {
                fields.insert("machine_id".to_owned(), json!(machine));
            }
            Ok(report)
        }
        Reported::Nothing => Err(reply_error(
            "machine_auth.unsupported",
            "This machine's cmux-tui does not report its model route yet. Update the machine, then try again.",
            machine,
        )),
        Reported::Other => Err(reply_error(
            "machine_auth.invalid_reply",
            "The machine answered something other than its report.",
            machine,
        )),
    }
}

fn run(global: &GlobalArgs, output: OutputMode, machine: &str) -> i32 {
    let mut runner = self_runner(global);
    let route = Route::choose(global, |key| std::env::var(key).ok());
    match ask(&mut runner, machine, &route) {
        Err(error) => super::wire::print_local_error(&error, output, 1),
        Ok(report) => {
            let ok = report.get("ok").and_then(Value::as_bool) == Some(true);
            if output == OutputMode::Human {
                for name in ["claude", "codex"] {
                    let field = |key: &str| report.get("agents")?.get(name)?.get(key);
                    println!(
                        "{name}: {} (key {}, {})",
                        field("base_url").and_then(Value::as_str).unwrap_or("no base URL"),
                        field("key").and_then(Value::as_str).unwrap_or("?"),
                        if field("edge_routed").and_then(Value::as_bool) == Some(true) {
                            "through the Cloud service"
                        } else {
                            "not through the Cloud service"
                        }
                    );
                }
                let count =
                    |key: &str| report.get(key).and_then(Value::as_array).map_or(0, Vec::len);
                let logins = count("login_files") + count("credential_env");
                println!("provider logins on the machine: {logins}");
                println!("{}", if ok { "ok" } else { "not ok" });
            } else {
                println!("{report}");
            }
            if ok { 0 } else { 1 }
        }
    }
}

#[cfg(test)]
mod tests {
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
            Ran {
                code: self.answer.0,
                stdout: self.answer.1.clone(),
                stderr: self.answer.2.clone(),
            }
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
        assert_eq!(
            parse(&words(&["--machine", "vm_1", "--json"]), &mut out),
            Ok(Some("vm_1".into()))
        );
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
        let (_, rest) =
            verb_args(&words(&["cloud", "machine-auth", "--target=machine:vm_3"])).unwrap();
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

        let global = |app: Option<&str>| GlobalArgs {
            app_socket: app.map(Into::into),
            ..GlobalArgs::default()
        };
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
        assert_eq!(
            Route::choose(&global(None), env(&[("CMUX_CLOUD_ACCESS_TOKEN", " ")])),
            Route::App
        );
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
}
