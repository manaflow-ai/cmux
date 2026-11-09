//! `cmux cloud machine-auth --machine vm_… [--json]`: how a Cloud machine's agents reach models,
//! and whether the machine holds any provider login.
//!
//! It runs `cmux-tui acp --json machine-auth` on the machine through `cloud exec` (as the
//! machine's work user, whose daemon it reads) and prints that report with `machine_id` added.
//! The report has names, verdicts and credential-free base URLs only (acpmux
//! `cli/machine_auth.rs`), never a key or a token. Exit 0 when the report says `ok`, 1 when it
//! does not, 2 for a usage error; a machine that cannot answer is a typed error:
//! `machine_auth.unsupported` (its cmux-tui predates the verb: update the machine),
//! `machine_auth.invalid_reply`, or `cloud exec`'s own code (`vm_not_running`, `vm_not_found`, …).

use serde_json::{Value, json};

use super::cloud_start_chat::{Runner, SelfRunner, forwarded_globals, step_result};
use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "usage: cmux cloud machine-auth --machine VM_ID [--json]

How the agents on a Cloud machine reach models: each agent's base URL, whether its
key is the edge's placeholder, and whether the machine holds a provider login
(Claude or Codex login files, a login in Claude's settings, a credential variable in
the agent daemon's environment). Prints names and verdicts only, never a value.

  --machine VM_ID    the machine (also --target machine:VM_ID)

JSON: {machine_id, ok, cloud_vm, edge_host, model_plane: {path, state},
       daemon: {running, pid}, agents: {claude|codex: {base_url, base_url_source,
       key_var, key, key_source, edge_routed}}, credential_env: [NAME],
       login_files: [{path, agent, kind, names?}], holds_credential,
       managed_route_files: [{path, agent, present}]}
Exit 0 when ok, 1 when not.
";

/// The machine-side command: as the work user when exec runs as root.
const GUEST: &str = "c=/home/cmux/.cmux/bin/cmux-tui; [ -x \"$c\" ] || c=cmux-tui; \
if [ \"$(id -u)\" = 0 ] && id cmux >/dev/null 2>&1; then \
set -- setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux; \
else set --; fi; \"$@\" \"$c\" acp --json machine-auth 2>/dev/null; true";

/// `Some(exit code)` when `args` is `cloud machine-auth …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != "machine-auth" {
        return None;
    }
    let mut output = global.output;
    let machine = match parse(rest, &mut output) {
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

fn reply_error(code: &str, message: &str, machine: &str) -> Value {
    json!({"code": code, "message": message, "retryable": false, "details": {"machine_id": machine}})
}

/// The machine's report with its id, or the error object.
pub(super) fn ask(runner: &mut dyn Runner, machine: &str) -> Result<Value, Value> {
    let args = vec![
        "cloud".to_owned(),
        "exec".to_owned(),
        "--target".to_owned(),
        format!("machine:{machine}"),
        "--command".to_owned(),
        GUEST.to_owned(),
        "--json".to_owned(),
    ];
    let result = step_result(&runner.cmux(&args))?;
    let stdout = result.get("stdout").and_then(Value::as_str).unwrap_or_default();
    let report = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok().filter(Value::is_object));
    match report {
        Some(mut report) if report.get("agents").is_some() => {
            report["machine_id"] = json!(machine);
            Ok(report)
        }
        None if stdout.trim().is_empty() => Err(reply_error(
            "machine_auth.unsupported",
            "This machine's cmux-tui does not report its model route yet. Update the machine, then try again.",
            machine,
        )),
        _ => Err(reply_error(
            "machine_auth.invalid_reply",
            "The machine answered something other than its report.",
            machine,
        )),
    }
}

fn run(global: &GlobalArgs, output: OutputMode, machine: &str) -> i32 {
    let mut runner = SelfRunner { globals: forwarded_globals(global) };
    match ask(&mut runner, machine) {
        Err(error) => super::wire::print_local_error(&error, output, 1),
        Ok(report) => {
            let ok = report.get("ok").and_then(Value::as_bool) == Some(true);
            if output == OutputMode::Human {
                for name in ["claude", "codex"] {
                    let a = &report["agents"][name];
                    println!(
                        "{name}: {} (key {}, {})",
                        a["base_url"].as_str().unwrap_or("no base URL"),
                        a["key"].as_str().unwrap_or("?"),
                        if a["edge_routed"] == true {
                            "through the Cloud service"
                        } else {
                            "not through the Cloud service"
                        }
                    );
                }
                let logins = report["login_files"].as_array().map_or(0, Vec::len)
                    + report["credential_env"].as_array().map_or(0, Vec::len);
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
    fn it_returns_the_machine_report_with_its_id() {
        let report = json!({"ok": true, "agents": {"claude": {}, "codex": {}}});
        let mut runner =
            fake(0, json!({"result": {"stdout": format!("noise\n{report}\n"), "exit_code": 0}}));
        let got = ask(&mut runner, "vm_1").unwrap();
        assert_eq!(got["machine_id"], "vm_1");
        assert_eq!(got["ok"], true);
        let args = &runner.asked[0];
        assert_eq!(args[..4], ["cloud", "exec", "--target", "machine:vm_1"]);
        assert!(args[5].contains("acp --json machine-auth"));
    }

    #[test]
    fn an_old_machine_or_an_exec_refusal_is_typed() {
        let mut runner = fake(0, json!({"result": {"stdout": "", "exit_code": 0}}));
        assert_eq!(ask(&mut runner, "vm_1").unwrap_err()["code"], "machine_auth.unsupported");
        let mut runner = fake(0, json!({"result": {"stdout": "{\"x\":1}"}}));
        assert_eq!(ask(&mut runner, "vm_1").unwrap_err()["code"], "machine_auth.invalid_reply");
        let refusal = json!({"code": "vm_not_running", "message": "paused"}).to_string();
        let mut runner = Fake { answer: (1, String::new(), refusal), asked: Vec::new() };
        assert_eq!(ask(&mut runner, "vm_1").unwrap_err()["code"], "vm_not_running");
    }
}
