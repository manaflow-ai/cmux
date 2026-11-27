//! `cmux hosts`: the hosts declared in cmux-next.json (`machines.hosts`,
//! `cmux_config::hosts`, CMUX-673), and
//! which of them answer from here. Both verbs read the file in process, so
//! they work with cmux quit.

use std::time::{Duration, Instant};

use cmux_config::hosts::{self, HostDecl};
use cmux_config::value::value_at;
use serde_json::json;

use super::OutputMode;
use super::hosts_check::{self, DEFAULT_TIMEOUT, MAX_TIMEOUT, Status};
use super::hosts_edit;
use cmux_config::hosts_edit::HostEdit;

const USAGE: &str = "\
cmux hosts: the computers declared in cmux-next.json (this build's config), under machines.hosts:
  \"machines\": { \"hosts\": [ { \"label\": \"studio\", \"endpoints\": [\"studio.local\", \"ssh://leo@100.64.0.7:2222\"], \"icon\": \"desktopcomputer\" } ] }
  cmux hosts [list] [--json]                         the declared hosts, and any entry that is not one
  cmux hosts check [LABEL...] [--timeout SECS] [--json]
      which hosts answer from here: every endpoint at once, each with up to SECS (default 3)
      reachable: an ssh server answered; down: a machine answered, but not ssh;
      unreachable: nothing answered (it may work from another network); unchecked: ssh goes through a proxy
  cmux hosts add LABEL ENDPOINT... [--icon NAME]     declare a host (endpoints tried in order)
  cmux hosts rename OLD NEW                          give a host another label
  cmux hosts set-endpoints LABEL ENDPOINT...         replace a host's endpoints
  cmux hosts remove LABEL                            stop declaring a host
      an endpoint is ssh://[user@]host[:port], [user@]host or an ~/.ssh/config alias; the edits keep
      the file's comments and other keys, and the person runs them (an agent is refused)";

/// Handles `cmux hosts` before the daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "hosts" {
        return None;
    }
    Some(run(global.output, rest))
}

#[derive(Debug, PartialEq)]
enum Request {
    List,
    Check { labels: Vec<String>, timeout: Duration },
    Edit(HostEdit),
    Help,
}

fn parse(rest: &[String]) -> Result<Request, String> {
    let words: Vec<&str> =
        rest.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    // `--help` anywhere (`cmux hosts check --help`) is the help, never an unknown option.
    if words.iter().any(|word| matches!(*word, "-h" | "--help")) {
        return Ok(Request::Help);
    }
    match words.split_first() {
        None | Some((&"list" | &"ls", [])) => Ok(Request::List),
        Some((&"help" | &"-h" | &"--help", _)) => Ok(Request::Help),
        Some((&"check", args)) => {
            let mut labels = Vec::new();
            let mut timeout = DEFAULT_TIMEOUT;
            let mut args = args.iter();
            while let Some(arg) = args.next() {
                let seconds = match arg.strip_prefix("--timeout=") {
                    Some(value) => Some(value),
                    None if *arg == "--timeout" => {
                        Some(*args.next().ok_or("--timeout needs SECS")?)
                    }
                    None => None,
                };
                match seconds {
                    Some(value) => {
                        let secs: f64 = value
                            .parse()
                            .map_err(|_| format!("--timeout {value}: not a number"))?;
                        if !(secs > 0.0 && secs <= MAX_TIMEOUT.as_secs_f64()) {
                            return Err(format!(
                                "--timeout takes 0 to {} seconds",
                                MAX_TIMEOUT.as_secs()
                            ));
                        }
                        timeout = Duration::from_secs_f64(secs);
                    }
                    None if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
                    None => labels.push((*arg).to_owned()),
                }
            }
            Ok(Request::Check { labels, timeout })
        }
        Some((verb, args)) => match hosts_edit::parse(verb, args) {
            Some(edit) => edit.map(Request::Edit),
            None => Err(format!("unknown verb {verb}")),
        },
    }
}

fn run(output: OutputMode, rest: &[String]) -> i32 {
    let request = match parse(rest) {
        Ok(Request::Help) => {
            println!("{USAGE}");
            return 0;
        }
        Ok(Request::Edit(edit)) => return hosts_edit::run(output, &edit),
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux hosts: {error}\n\n{USAGE}");
            return 2;
        }
    };
    let (declared, problems) = match read_declared() {
        Ok(read) => read,
        Err(error) => {
            eprintln!("cmux hosts: {error}");
            return 1;
        }
    };
    let json = matches!(output, OutputMode::Json | OutputMode::JsonLines);
    match request {
        Request::List => {
            if json {
                println!("{}", json!({ "hosts": declared, "problems": problems }));
            } else {
                print_list(&declared, &problems, output);
            }
            0
        }
        Request::Check { labels, timeout } => {
            let mut chosen = Vec::new();
            for label in &labels {
                match hosts::find(&declared, label) {
                    Some(host) => chosen.push(host.clone()),
                    None => {
                        eprintln!("cmux hosts: no host is called {label:?} (cmux hosts list)");
                        return 2;
                    }
                }
            }
            if labels.is_empty() {
                chosen = declared;
            }
            let started = Instant::now();
            let results = hosts_check::check_all(&chosen, timeout, &hosts_check::ssh_probe());
            let wall_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            if json {
                let timeout_ms = u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX);
                println!(
                    "{}",
                    json!({ "hosts": results, "timeoutMs": timeout_ms, "wallMs": wall_ms })
                );
            } else if output != OutputMode::Quiet {
                print_check(&results);
            }
            0
        }
        Request::Help | Request::Edit(_) => 0,
    }
}

/// The declared hosts and the problems of the entries that are not hosts.
/// No file, or no `machines.hosts`, is no hosts.
fn read_declared() -> Result<(Vec<HostDecl>, Vec<String>), String> {
    let path = cmux_config::config_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), Vec::new()));
        }
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    let root =
        cmux_config::jsonc::parse(&text).map_err(|error| format!("{}: {error}", path.display()))?;
    let at: Vec<String> = hosts::PATH.iter().map(|part| (*part).to_owned()).collect();
    Ok(match value_at(&root, &at) {
        Some(value) => hosts::parse(value),
        None => (Vec::new(), Vec::new()),
    })
}

fn print_list(declared: &[HostDecl], problems: &[String], output: OutputMode) {
    if output != OutputMode::Quiet {
        if declared.is_empty() {
            println!("No hosts. Add one under machines.hosts in cmux-next.json (cmux hosts help).");
        }
        let width = declared.iter().map(|host| host.label.chars().count()).max().unwrap_or(0);
        for host in declared {
            println!("{:width$}  {}", host.label, host.endpoints.join(", "));
        }
    }
    for problem in problems {
        eprintln!("{problem}");
    }
}

fn print_check(results: &[hosts_check::HostResult]) {
    if results.is_empty() {
        println!(
            "No hosts to check. Add one under machines.hosts in cmux-next.json (cmux hosts help)."
        );
        return;
    }
    let label_width = results.iter().map(|r| r.label.chars().count()).max().unwrap_or(5).max(5);
    let endpoint_width =
        results.iter().map(|r| r.endpoint.chars().count()).max().unwrap_or(8).max(8);
    println!("{:label_width$}  {:11}  {:endpoint_width$}  DETAIL", "LABEL", "STATUS", "ENDPOINT");
    for r in results {
        let status = match r.status {
            Status::Reachable => "reachable",
            Status::Down => "down",
            Status::Unchecked => "unchecked",
            Status::Unreachable => "unreachable",
        };
        println!(
            "{:label_width$}  {status:11}  {:endpoint_width$}  {}",
            r.label, r.endpoint, r.detail
        );
    }
}

#[cfg(test)]
#[path = "hosts_tests.rs"]
mod tests;
